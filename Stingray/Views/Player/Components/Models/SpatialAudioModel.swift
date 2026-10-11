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
    /// Starts playback, then recovers stalls and catches failures until stopped
    private var monitor: Task<Void, Never>?
    /// The latest seek target and when it was requested, until playback resumes after it
    private var pendingSeek: (target: CMTime, since: ContinuousClock.Instant)?

    /// Wraps a started stream
    /// - Parameters:
    ///   - stream: Loopback stream serving the converted audio
    ///   - player: Player to play through
    ///   - makeItem: Creates a player item for the stream's playlist
    ///   - fallback: Plays the usual audio from the given time
    private init(stream: APACStream, player: AVPlayer, makeItem: @escaping (URL) -> AVPlayerItem, fallback: @escaping (CMTime) -> Void) {
        self.stream = stream
        self.player = player
        self.makeItem = makeItem
        self.fallback = fallback
    }

    /// Whether SpatialAudioBridge converts this audio stream: TrueHD Atmos or DTS:X inside the media source's own file
    /// - Parameter audioStream: Audio stream to check
    /// - Returns: True when the stream should play through SpatialAudioBridge
    public static func converts(_ audioStream: any MediaStreamProtocol) -> Bool {
        !audioStream.isExternal && Self.codec(of: audioStream) != nil
    }

    /// The codec SpatialAudioBridge converts an audio stream with, judging by what the server reports
    /// - Parameter audioStream: Audio stream to check
    /// - Returns: The codec, or `nil` for streams it doesn't convert
    private static func codec(of audioStream: any MediaStreamProtocol) -> SpatialAudioCodec? {
        switch (audioStream.codec, audioStream.spatialFormat) {
        case ("truehd", .dolbyAtmos): return .trueHDAtmos
        case ("dts", .dtsX): return .dtsX
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
            Log.info("Playing \(track.codecID) track \(track.number) through SpatialAudioBridge")
            return SpatialAudioModel(stream: stream, player: player, makeItem: makeItem, fallback: fallback)
        }
        catch {
            // A URL error's description could include the URL, which carries the access token
            let reason = (error as? SpatialAudioError)?.description ?? error.localizedDescription
            if !Task.isCancelled { Log.warning("Spatial audio failed to start, so playing the usual audio: \(reason)") }
            return nil
        }
    }

    /// Plays the stream, keeping any playback speed set while it started
    /// - Parameter startTime: Where to start, matching the start time the stream was started with
    public func play(from startTime: CMTime) {
        let rate = self.player.rate
        self.player.pause() // Don't play from the beginning while seeking
        // The playlist offers only APAC audio, so the activator plays along with every item
        self.atmos.attach(to: self.player)
        self.replaceItem()
        self.monitor = Task { [weak self] in await self?.run(from: startTime, rate: rate) }
    }

    /// Starts playback, then recovers stalls and falls back to the usual audio if the stream fails.
    ///
    /// AVPlayer can wait indefinitely after rapid seeks, when Jellyfin aborts a video segment or AVPlayer drops a connection, and seeking
    /// again doesn't help. A fresh item does: at the pending seek target if playback never reached it, otherwise where it stopped. Seeks
    /// took up to 15 seconds to resume on titles with long keyframe intervals, so 20 seconds of waiting means it's stuck.
    /// - Parameters:
    ///   - startTime: Where to start
    ///   - rate: Playback speed to start at. `0` plays at the default rate
    private func run(from startTime: CMTime, rate: Float) async {
        await self.player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        guard !Task.isCancelled else { return }
        if rate > 0 { self.player.rate = rate }
        else { self.player.play() }

        var status = self.player.timeControlStatus
        var changed = ContinuousClock.now
        while (try? await Task.sleep(for: .milliseconds(250))) != nil {
            if let item = self.item, item.status == .failed {
                Log.warning("Spatial audio failed, so playing the usual audio: \(item.error?.localizedDescription ?? "Unknown error")")
                self.fallback(self.player.currentTime())
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
            guard status == .waitingToPlayAtSpecifiedRate, ContinuousClock.now - changed > .seconds(20) else { continue }

            let position = self.pendingSeek?.target ?? self.player.currentTime()
            Log.warning("Spatial audio stalled, so reloading at \(Int(position.seconds)) seconds")
            self.replaceItem()
            await self.player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            self.player.play()
            changed = .now
        }
    }

    /// Puts a fresh item for the stream in the player
    private func replaceItem() {
        let item = self.makeItem(self.stream.masterPlaylistURL ?? self.stream.audioPlaylistURL)
        self.item = item
        self.player.replaceCurrentItem(with: item)
    }

    public func noteSeek(to target: CMTime) {
        self.pendingSeek = (target, .now)
    }

    public func stop() {
        self.monitor?.cancel()
        // Leave the player alone if it has already moved on to another item
        if self.player.currentItem === self.item { self.player.replaceCurrentItem(with: nil) }
        self.atmos.detach()
        Task { [stream] in await stream.stop() }
    }
}
