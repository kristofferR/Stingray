//
//  SpatialAudioModel.swift
//  Stingray
//
//  Created by kristofferR on 10/11/26.
//

import AVFoundation
import SpatialAudioBridge
import SpatialAudioPlayback

/// Spatial audio playback that can be held and stopped on any tvOS version
public protocol SpatialAudioProtocol: AnyObject {
    /// Records the target of a skip or scrub from the remote, so a stalled stream resumes there
    /// - Parameter target: Where the viewer is seeking to
    func noteSeek(to target: CMTime)
    /// Stops the stream, along with its player item and Atmos output
    func stop()
}

/// Plays a TrueHD Atmos or DTS:X track as APAC, Apple's spatial audio format, beside the server's HLS video.
///
/// SpatialAudioBridge reads the track from the original file, converts it on demand, and serves it from a loopback HLS server as the only
/// audio of the server's video playlist. `AtmosOutputActivator` keeps the HDMI output in Dolby Atmos while it plays.
/// Stall recovery is adapted from SpatialAudioBridge's StreamPlayer example.
@available(tvOS 26, *)
public final class SpatialAudioModel: SpatialAudioProtocol {
    /// Loopback stream serving the converted audio with the server's video
    private let stream: APACStream
    /// The stream's playlist, offering the server's video with the converted audio
    private let playlist: URL
    /// Keeps the HDMI output in Dolby Atmos while APAC plays
    private let atmos = AtmosOutputActivator()
    /// Player the stream plays through
    private let player: AVPlayer
    /// Creates a player item for the stream's playlist
    private let makeItem: (URL) -> AVPlayerItem
    /// Plays the usual audio from the given time, after the stream failed
    private let fallback: (CMTime) -> Void
    /// The stream's current item, replaced when recovering a stall
    private var item: AVPlayerItem?
    /// Watches the current item failing partway through playback, which can leave its status ready
    private var failureObserver: NSObjectProtocol?
    /// Starts playback, then recovers stalls and catches failures until stopped
    private var monitor: Task<Void, Never>?
    /// The latest seek target and when it was requested, until playback resumes after it
    private var pendingSeek: (target: CMTime, since: ContinuousClock.Instant)?
    /// Set once stopped, so a failure notification that was already queued can't fall back over a newer session
    private var isStopped = false

    /// Wraps a started stream
    /// - Parameters:
    ///   - stream: Loopback stream serving the converted audio
    ///   - playlist: The stream's playlist with the server's video
    ///   - player: Player to play through
    ///   - makeItem: Creates a player item for the stream's playlist
    ///   - fallback: Plays the usual audio from the given time
    private init(
        stream: APACStream,
        playlist: URL,
        player: AVPlayer,
        makeItem: @escaping (URL) -> AVPlayerItem,
        fallback: @escaping (CMTime) -> Void
    ) {
        self.stream = stream
        self.playlist = playlist
        self.player = player
        self.makeItem = makeItem
        self.fallback = fallback
    }

    /// Whether to try SpatialAudioBridge for this audio stream: TrueHD or DTS-HD MA inside the media source's own file. Starting the stream
    /// verifies Atmos or DTS:X, and fails for anything else, so plain tracks fall back to the usual audio.
    /// - Parameter audioStream: Audio stream to check
    /// - Returns: True when the stream should try SpatialAudioBridge
    public static func converts(_ audioStream: any MediaStreamProtocol) -> Bool {
        !audioStream.isExternal && Self.codec(of: audioStream) != nil
    }

    /// The codec SpatialAudioBridge would convert an audio stream with, judging by what the server reports
    /// - Parameter audioStream: Audio stream to check
    /// - Returns: The codec, or `nil` for streams that can't carry Atmos or DTS:X
    private static func codec(of audioStream: any MediaStreamProtocol) -> SpatialAudioCodec? {
        switch audioStream.codec {
        case "truehd": return .trueHDAtmos
        // The server doesn't label every DTS:X track, but only DTS-HD MA carries it, not DTS core, HRA, or Express
        case "dts" where audioStream.profile.hasPrefix("DTS-HD MA"): return .dtsX
        default: return nil
        }
    }

    /// Starts converting an audio stream, without touching the player yet
    /// - Parameters:
    ///   - file: Original file, read with range requests
    ///   - videoPlaylist: HLS multivariant playlist for the video, whose own audio is replaced
    ///   - audioStream: Audio stream to convert
    ///   - mediaSource: Media source the audio stream belongs to
    ///   - startTime: Where playback will start, which is converted first
    ///   - player: Player to play through
    ///   - makeItem: Creates a player item for the stream's playlist
    ///   - fallback: Plays the usual audio from the given time, if the stream fails during playback
    /// - Returns: A stream ready to play, or `nil` when SpatialAudioBridge can't play the track. Play the usual audio then.
    public static func start(
        file: URL,
        videoPlaylist: URL,
        audioStream: any MediaStreamProtocol,
        mediaSource: any MediaSourceProtocol,
        startTime: CMTime,
        player: AVPlayer,
        makeItem: @escaping (URL) -> AVPlayerItem,
        fallback: @escaping (CMTime) -> Void
    ) async -> SpatialAudioModel? {
        do {
            try AtmosOutputActivator.configureAudioSession()
            let file = try await MatroskaFile.open(HTTPByteSource(url: file))

            // The server numbers streams its own way, but lists the file's audio tracks in the file's order
            let audioStreams = mediaSource.audioStreams.filter { !$0.isExternal }
            guard let codec = Self.codec(of: audioStream),
                  let index = audioStreams.firstIndex(where: { $0.id == audioStream.id }),
                  file.audioTracks.indices.contains(index),
                  file.audioTracks[index].codec == codec
            else { throw SpatialAudioError.source("The file's audio tracks don't match the server's") }
            let track = file.audioTracks[index]

            var options = APACStream.Options()
            // Only offer the stream copy: AVPlayer switches to the server's SDR transcodes when a segment is slow
            options.includesVideoVariant = { $0.query?.range(of: "allowVideoStreamCopy=false", options: .caseInsensitive) == nil }
            let stream = try await APACStream.start(
                file: file,
                track: track,
                videoMaster: videoPlaylist,
                startTime: startTime,
                options: options
            )
            // Always set when started with a video playlist; the start throws if no video variant remains
            guard let playlist = stream.masterPlaylistURL else {
                await stream.stop()
                throw SpatialAudioError.source("The stream has no video")
            }
            Log.info("Playing \(track.codecID) track \(track.number) through SpatialAudioBridge")
            return SpatialAudioModel(stream: stream, playlist: playlist, player: player, makeItem: makeItem, fallback: fallback)
        }
        catch {
            // Interpolating a URL error would print its failing URL, which carries the access token
            let reason = (error as? SpatialAudioError)?.description ?? error.localizedDescription
            if !Task.isCancelled { Log.warning("Spatial audio failed to start, so playing the usual audio: \(reason)") }
            return nil
        }
    }

    /// Plays the stream
    /// - Parameter startTime: Where to start, matching the start time the stream was started with
    public func play(from startTime: CMTime) {
        // The playlist offers only APAC audio, so the activator plays along with every item
        self.atmos.attach(to: self.player)
        self.monitor = Task { [weak self] in await self?.run(from: startTime) }
    }

    /// Starts playback, then recovers stalls and falls back to the usual audio if the stream fails.
    ///
    /// AVPlayer can wait indefinitely after rapid seeks, when Jellyfin aborts a video segment or AVPlayer drops a connection, and seeking
    /// again doesn't help. A fresh item does: at the pending seek target if playback never reached it, otherwise where it stopped. Seeks
    /// took up to 15 seconds to resume on titles with long keyframe intervals, so 20 seconds of waiting means it's stuck.
    /// - Parameter startTime: Where to start
    private func run(from startTime: CMTime) async {
        guard await self.load(at: startTime) else { return }
        if self.player.rate == 0 { self.player.play() } // Unless a playback speed was set while the stream started

        var status = self.player.timeControlStatus
        var changed = ContinuousClock.now
        while (try? await Task.sleep(for: .milliseconds(250))) != nil {
            if let item = self.item, item.status == .failed {
                self.fail(item.error)
                return
            }
            if self.player.timeControlStatus != status {
                status = self.player.timeControlStatus
                changed = .now
            }
            // Five seconds of playback since the seek mean it resolved, wherever it landed
            if let seek = self.pendingSeek, status == .playing, ContinuousClock.now - max(changed, seek.since) > .seconds(5) {
                self.pendingSeek = nil
            }
            // A seek starts the wait over
            let waitingSince = max(changed, self.pendingSeek?.since ?? changed)
            guard status == .waitingToPlayAtSpecifiedRate, ContinuousClock.now - waitingSince > .seconds(20) else { continue }

            let position = self.pendingSeek?.target ?? self.player.currentTime()
            Log.warning("Spatial audio stalled, so reloading at \(String(format: "%.0f", position.seconds)) seconds")
            guard await self.load(at: position) else { return }
            changed = .now
        }
    }

    /// Puts a fresh item for the stream in the player and seeks it to `time`. The player keeps its rate, so its playback speed, or a pause
    /// while seeking, carries over.
    /// - Parameter time: Where to play from
    /// - Returns: False if the stream stopped meanwhile
    private func load(at time: CMTime) async -> Bool {
        guard !Task.isCancelled else { return false }
        self.pendingSeek = (time, .now) // Until playback gets going, `currentTime()` may not reach it yet
        let item = self.makeItem(self.playlist)
        self.item = item
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        self.failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            self?.fail(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
        }
        self.player.replaceCurrentItem(with: item)

        await self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        return !Task.isCancelled
    }

    /// Plays the usual audio instead, once the stream has failed, from where the viewer was or was seeking to
    /// - Parameter error: Why it failed, if known
    private func fail(_ error: Error?) {
        guard !self.isStopped else { return }
        // Only the domain and code: the item's error may carry its URL, which carries the access token
        let reason = (error as NSError?).map { "\($0.domain) \($0.code)" } ?? "Unknown error"
        Log.warning("Spatial audio failed, so playing the usual audio: \(reason)")
        self.fallback(self.pendingSeek?.target ?? self.player.currentTime())
    }

    public func noteSeek(to target: CMTime) {
        self.pendingSeek = (target, .now)
    }

    public func stop() {
        self.isStopped = true
        self.monitor?.cancel()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        self.failureObserver = nil
        // Leave the player alone if it has already moved on to another item
        if self.player.currentItem === self.item { self.player.replaceCurrentItem(with: nil) }
        self.atmos.detach()
        Task { [stream] in await stream.stop() }
    }
}
