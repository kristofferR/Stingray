//
//  SpatialAudioModel.swift
//  Stingray
//
//  Created by kristofferR on 10/11/26.
//

import AVFoundation
import SpatialAudioBridge
import SpatialAudioPlayback

/// Spatial audio playback that can be held and stopped below tvOS 26
public protocol SpatialAudioProtocol: AnyObject {
    /// Stops the stream, its player item, and the Atmos output
    func stop()
}

/// Plays a TrueHD Atmos or DTS:X track as APAC, Apple's spatial audio format, beside the server's video.
///
/// SpatialAudioBridge reads the track from the original file, converts it on demand, and serves it from a loopback HLS server as the only
/// audio of the server's video playlist. `AtmosOutputActivator` keeps the HDMI output in Dolby Atmos while it plays.
@available(tvOS 26, *)
public final class SpatialAudioModel: SpatialAudioProtocol {
    /// Why a stream didn't start
    public enum StartError: Error {
        /// SpatialAudioBridge can't play the track, so another try would fail too
        case refused
        /// The server or network failed or was too slow, which may pass
        case unavailable
    }

    /// Loopback stream serving the converted audio
    private let stream: APACStream
    /// The stream's playlist, with the server's video
    private let playlist: URL
    /// Authenticate the server's video that the playlist references
    private let headers: [String: String]
    /// Keeps the HDMI output in Dolby Atmos
    private let atmos = AtmosOutputActivator()
    /// Player the stream plays through
    private let player: AVPlayer
    /// Where playback starts
    private let startTime: CMTime
    /// Plays the usual audio from the given time
    private let fallback: (CMTime) -> Void
    /// The stream's player item
    private var item: AVPlayerItem?
    /// Watches the item failing to load
    private var statusObservation: NSKeyValueObservation?
    /// Watches the item failing partway through playback
    private var failureObserver: NSObjectProtocol?
    /// Set once stopped, so a failure already on its way can't fall back over a newer session
    private var isStopped = false
    /// Reads files and fetches video playlists over its own connections, so the app's other requests to the server can't hold them up
    private static let session = URLSession(configuration: .default)

    // AI Generated
    /// Wraps a started stream
    /// - Parameters:
    ///   - stream: Loopback stream serving the converted audio
    ///   - playlist: The stream's playlist, with the server's video
    ///   - headers: Authenticate the server's video
    ///   - player: Player to play through
    ///   - startTime: Where playback starts
    ///   - fallback: Plays the usual audio from the given time
    private init(
        stream: APACStream,
        playlist: URL,
        headers: [String: String],
        player: AVPlayer,
        startTime: CMTime,
        fallback: @escaping (CMTime) -> Void
    ) {
        self.stream = stream
        self.playlist = playlist
        self.headers = headers
        self.player = player
        self.startTime = startTime
        self.fallback = fallback
    }

    // AI Generated
    /// Whether to try SpatialAudioBridge for an audio stream. Starting the stream verifies Atmos or DTS:X, and fails for anything else.
    /// - Parameter audioStream: Audio stream to check
    /// - Returns: True for TrueHD Atmos and DTS-HD MA inside the media source's own file
    public static func converts(_ audioStream: any MediaStreamProtocol) -> Bool {
        !audioStream.isExternal && Self.codec(of: audioStream) != nil
    }

    // AI Generated
    /// The codec SpatialAudioBridge would convert an audio stream with, judging by the server's label
    /// - Parameter audioStream: Audio stream to check
    /// - Returns: The codec, or `nil` for streams it doesn't convert
    private static func codec(of audioStream: any MediaStreamProtocol) -> SpatialAudioCodec? {
        switch audioStream.codec {
        case "truehd" where audioStream.profile.contains("Atmos"): return .trueHDAtmos
        // The server doesn't label every DTS:X track, so try every DTS-HD MA track
        case "dts" where audioStream.profile.hasPrefix("DTS-HD MA"): return .dtsX
        default: return nil
        }
    }

    // AI Generated
    /// Starts converting an audio stream, without touching the player yet. Gives up after 25 seconds, as a busy server can make the
    /// start slow.
    /// - Parameters:
    ///   - content: The server's file, video playlist, and headers
    ///   - audioStream: Audio stream to convert
    ///   - mediaSource: Media source the audio stream belongs to
    ///   - startTime: Where playback will start, which is converted first
    ///   - player: Player to play through
    ///   - fallback: Plays the usual audio from the given time, if the stream fails during playback
    /// - Returns: A stream ready to play
    public static func start(
        content: SpatialAudioContent,
        audioStream: any MediaStreamProtocol,
        mediaSource: any MediaSourceProtocol,
        startTime: CMTime,
        player: AVPlayer,
        fallback: @escaping (CMTime) -> Void
    ) async throws(StartError) -> SpatialAudioModel {
        let starting = Task {
            try await Self.open(
                content: content,
                audioStream: audioStream,
                mediaSource: mediaSource,
                startTime: startTime,
                player: player,
                fallback: fallback
            )
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(25))
            starting.cancel()
        }
        defer { deadline.cancel() }
        do { return try await withTaskCancellationHandler { try await starting.value } onCancel: { starting.cancel() } }
        catch {
            if Task.isCancelled { throw .unavailable } // The caller has moved on
            if starting.isCancelled {
                Log.warning("Spatial audio took too long to start, so playing the usual audio")
                throw .unavailable
            }
            Log.warning("Spatial audio failed to start: \((error as? SpatialAudioError)?.description ?? error.localizedDescription)")
            // SpatialAudioBridge refuses with its own errors, and fails like the network when the server or network does
            throw error is SpatialAudioError ? .refused : .unavailable
        }
    }

    // AI Generated
    /// Opens the server's file and starts converting an audio stream. See `start`.
    private static func open(
        content: SpatialAudioContent,
        audioStream: any MediaStreamProtocol,
        mediaSource: any MediaSourceProtocol,
        startTime: CMTime,
        player: AVPlayer,
        fallback: @escaping (CMTime) -> Void
    ) async throws -> SpatialAudioModel {
        try AtmosOutputActivator.configureAudioSession()
        var step = ContinuousClock.now
        let file = try await MatroskaFile.open(HTTPByteSource(url: content.file, headers: content.headers, session: Self.session))
        let opened = (ContinuousClock.now - step).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
        Log.info("Opened the file for SpatialAudioBridge in \(opened)") // Shows where a slow start waits

        // The server numbers streams its own way, but lists the file's audio tracks in the file's order
        let audioStreams = mediaSource.audioStreams.filter { !$0.isExternal }
        guard let codec = Self.codec(of: audioStream),
              let index = audioStreams.firstIndex(where: { $0.id == audioStream.id }),
              file.audioTracks.indices.contains(index),
              file.audioTracks[index].codec == codec
        else { throw SpatialAudioError.source("The file's audio tracks don't match the server's") }
        let track = file.audioTracks[index]

        var options = APACStream.Options()
        options.session = Self.session
        // Only the stream copy: AVPlayer switches to the server's SDR transcodes when a segment is slow
        options.includesVideoVariant = { $0.query?.range(of: "allowVideoStreamCopy=false", options: .caseInsensitive) == nil }
        step = .now
        let stream = try await APACStream.start(
            file: file,
            track: track,
            videoMaster: content.videoPlaylist,
            videoHeaders: content.headers,
            startTime: startTime,
            options: options
        )
        guard let playlist = stream.masterPlaylistURL else { // Set whenever a video playlist was given
            await stream.stop()
            throw SpatialAudioError.source("The stream has no video")
        }
        let started = (ContinuousClock.now - step).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
        Log.info("Playing \(track.codecID) track \(track.number) through SpatialAudioBridge, whose stream started in \(started)")
        return SpatialAudioModel(
            stream: stream,
            playlist: playlist,
            headers: content.headers,
            player: player,
            startTime: startTime,
            fallback: fallback
        )
    }

    // AI Generated
    /// Puts the stream's item in the player at the start time. The player keeps the rate the caller set, or a pause.
    /// - Parameters:
    ///   - title: Main title of the content to be shown
    ///   - subtitle: An optional descriptor of the content (ex. season 2, episode 4)
    public func play(title: String, subtitle: String?) {
        let item = AVPlayerItem(asset: AVURLAsset(url: self.playlist, options: ["AVURLAssetHTTPHeaderFieldsKey": self.headers]))
        item.setTitle(title, subtitle: subtitle)
        item.audioTimePitchAlgorithm = .spectral
        self.statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { self?.fail(item.error) }
        }
        self.failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            self?.fail(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
        }
        self.item = item

        self.atmos.attach(to: self.player) // The playlist offers only APAC audio, so every item plays it
        self.player.replaceCurrentItem(with: item)
        self.player.seek(to: self.startTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // AI Generated
    /// Plays the usual audio instead, from where playback was, once the stream has failed
    /// - Parameter error: Why it failed, if known
    private func fail(_ error: Error?) {
        guard !self.isStopped else { return }
        Log.warning("Spatial audio failed, so playing the usual audio: \(error?.localizedDescription ?? "Unknown error")")
        let current = self.player.currentTime() // Zero until the first seek lands
        self.fallback(current.isNumeric && current > .zero ? current : self.startTime)
    }

    // AI Generated
    public func stop() {
        self.isStopped = true
        self.statusObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        // Leave the player alone if it has moved on to another item
        if self.player.currentItem === self.item { self.player.replaceCurrentItem(with: nil) }
        self.atmos.detach()
        Task { [stream] in await stream.stop() }
    }
}
