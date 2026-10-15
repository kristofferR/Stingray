import Foundation
import CoreMedia

// These doubles never open media, contact a server or configure the host's audio session.
public enum JSONError: Error {
    case missingKey(String, String)
    case missingContainer(String, String)
    case failedJSONDecode(String, any Error)
}
public enum Log {
    public static func warning(_ message: String) {}
    public static func info(_ message: String) {}
}
enum SpatialAudioError: Error {
    case decoding(String), source(String), encoding(String), coreMedia(Int32)
    var description: String { String(describing: self) }
}
public struct SpatialAudioContent {}
final class AVAudioSession {
    enum Category { case playback }
    enum Mode { case moviePlayback }
    static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    func setCategory(_ category: Category, mode: Mode) throws {}
}
public final class AVPlayer {
    var rate: Float = 0
    var preventsDisplaySleepDuringVideoPlayback = false
    var lastSeek: CMTime?
    func pause() { rate = 0 }
    func play() { rate = 1 }
    func replaceCurrentItem(with item: Int?) {}
    func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) { lastSeek = time }
}
final class Progress {
    let player: AVPlayer
    var source: any MediaSourceProtocol
    var pendingPosition: TimeInterval = 930
    var videoID = "0"
    var audioID = "2"
    var subtitleID: String?
    var bitrate = 128_000
    init(player: AVPlayer, source: any MediaSourceProtocol) { self.player = player; self.source = source }
    func stop() { source.startPoint = pendingPosition }
}
final class StreamingService {
    var playerProgress: Progress?
    var receivedPosition: CMTime?
    func playbackEnd() { playerProgress?.stop(); playerProgress = nil }
    func playbackStart(mediaSource: any MediaSourceProtocol, videoID: String, audioID: String, subtitleID: String?,
                       bitrate: Int?, title: String, subtitle: String?, startTime: CMTime, player: AVPlayer) {
        receivedPosition = startTime
        playerProgress = Progress(player: player, source: mediaSource)
    }
}
struct Title { var title = "test" }
struct Episode { var mediaSources: [any MediaSourceProtocol]; var title = "episode"; var episodeNumber = 1 }
struct Season { var episodes: [Episode] = []; var title = "season" }
final class Settings { var usesSubtitles = false }
class PlayerHost {
    let player = AVPlayer()
    var mediaSource: any MediaSourceProtocol
    var playerProgress: Progress?
    let streamingService = StreamingService()
    var media = Title()
    var seasons: [Season] = []
    let settingsModel = Settings()
    init(source: MediaSource, saved: TimeInterval) {
        mediaSource = source
        let progress = Progress(player: player, source: source)
        progress.pendingPosition = saved
        playerProgress = progress
        streamingService.playerProgress = progress
    }
    func setupPlaybackEndObserver() {}
}
protocol Switching {
    func newPlayer(startTime: CMTime, videoID: StreamTransitionType, audioID: StreamTransitionType,
                   subtitleID: StreamTransitionType, bitrate: Int?)
}

@main struct PlaybackStateChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static func source() throws -> MediaSource {
        let json = #"{"Id":"source","Name":"fixture","RunTimeTicks":20000000000,"MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc"},{"Index":2,"Type":"Audio","Codec":"dts","Profile":"DTS-HD MA"},{"Index":3,"Type":"Audio","Codec":"dts","Profile":"DTS-HD MA"}]}"#
        return try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
    }
    static func main() async throws {
        try positions()
        try keys()
        try await failures()
        print("PASS \(checks) focused playback-state checks; no media or device operations")
    }
    static func positions() throws {
        let cases: [(String, CMTime, TimeInterval, TimeInterval)] = [
            ("pending startup", .invalid, 930, 930),
            ("valid seek", CMTime(seconds: 146, preferredTimescale: 600), 930, 146),
            ("explicit zero", .zero, 930, 0),
            ("indefinite", .indefinite, 930, 930),
            ("infinite request", .positiveInfinity, 930, 930),
            ("nonfinite saved position", .invalid, .infinity, 0),
            ("NaN saved position", .invalid, .nan, 0)
        ]
        for (label, requested, saved, expected) in cases {
            let hosts: [PlayerHost & Switching] = [MovieCase(source: try source(), saved: saved),
                                                   TVCase(source: try source(), saved: saved)]
            for host in hosts {
                host.mediaSource.startPoint = 7 // stopPlayer must refresh this before normalization.
                host.newPlayer(startTime: requested, videoID: .keep, audioID: .newID("3"), subtitleID: .keep, bitrate: 128_000)
                check(host.streamingService.receivedPosition?.isNumeric == true, "\(label): startup must be finite")
                check(host.player.lastSeek?.isNumeric == true, "\(label): seek must be finite")
                check(host.streamingService.receivedPosition?.seconds == expected, "\(label): wrong startup time")
                check(host.player.lastSeek?.seconds == expected, "\(label): caller sought a different time")
            }
        }
        print("PASS movie/TV caller positions: seven cases each, including saved progress refreshed by stop")
    }
    static func keys() throws {
        let s = try source()
        let audio = s.audioStreams[0] as! MediaStream
        let endpoint = URL(string: "https://server.example")!
        func key(_ server: String = "server", _ url: URL? = nil, _ selected: MediaStream? = nil) -> SpatialAudioRefusalKey? {
            SpatialAudioRefusalKey(serverID: server, serviceURL: url ?? endpoint, source: s, audio: selected ?? audio)
        }
        let original = key()!
        let refused: Set = [original]
        let video = s.videoStreams[0] as! MediaStream
        video.bitrate += 1
        video.id = "another-video"
        s.subtitleStreams = [s.audioStreams[1]]
        check(refused.contains(key()!), "Unrelated video/subtitle choices must retain the refusal")
        check(!refused.contains(key("other-server")!), "Different server must retry")
        check(!refused.contains(key("server", URL(string: "https://other.example")!)!), "Different endpoint must retry")
        check(!refused.contains(key("server", nil, s.audioStreams[1] as? MediaStream)!), "Different audio must retry")
        s.audioStreams.reverse()
        check(!refused.contains(key()!), "Changed Matroska ordinal must retry")
        s.audioStreams.reverse()
        audio.codec = "truehd"
        check(!refused.contains(key()!), "Changed codec must retry")
        audio.codec = "dts"
        audio.profile = "DTS-HD MA + DTS:X"
        check(!refused.contains(key()!), "Changed profile must retry")
        audio.profile = "DTS-HD MA"
        s.id = "another-source"
        check(!refused.contains(key()!), "Changed source must retry")
        s.id = "source"
        let refreshed = try source()
        check(s.snapshotID != refreshed.snapshotID, "A metadata reload needs a fresh generation")
        let newKey = SpatialAudioRefusalKey(serverID: "server", serviceURL: endpoint, source: refreshed, audio: refreshed.audioStreams[0])!
        check(!refused.contains(newKey), "A fresh snapshot with identical server IDs must retry")
        let external = try source().audioStreams[0] as! MediaStream
        external.id = "external"
        external.isExternal = true
        s.audioStreams.insert(external, at: 0)
        check(refused.contains(key()!), "External tracks must not change internal ordinal")
        check(key("server", nil, external) == nil, "External audio is not a convertible source input")
        audio.id = "not-in-source"
        let missing = try source().audioStreams[0] as! MediaStream
        check(key("server", nil, missing) == nil, "A missing audio mapping cannot inherit a refusal")
        print("PASS snapshot/server/source/audio/ordinal/codec/profile refusal identities")
    }
    static func failures() async throws {
        let s = try source()
        let audio = s.audioStreams[0] as! MediaStream
        let key = SpatialAudioRefusalKey(serverID: "server", serviceURL: URL(string: "https://server.example")!, source: s, audio: audio)!
        let cases: [(String, any Error, Bool)] = [
            ("decoding", SpatialAudioError.decoding("no DTS:X"), true),
            ("source", SpatialAudioError.source("playlist unavailable"), false),
            ("encoding", SpatialAudioError.encoding("temporary encoder failure"), false),
            ("CoreMedia", SpatialAudioError.coreMedia(-1), false),
            ("network", URLError(.timedOut), false)
        ]
        for (label, error, permanent) in cases {
            SpatialAudioModel.nextError = error
            let host = FailureHost()
            await host.attempt(source: s, audio: audio, key: key)
            check(host.spatialAudioFailures.contains(key) == permanent, "\(label): incorrect refusal caching")
            check(host.fallbackTimes.count == 1 && host.fallbackTimes[0].seconds == 930, "\(label): fallback must preserve the pending position")
        }
        SpatialAudioModel.nextError = nil
        let success = FailureHost()
        await success.attempt(source: s, audio: audio, key: key)
        check(success.spatialAudioFailures.isEmpty && success.fallbackTimes.isEmpty, "Success must not record a refusal")
        check(success.spatialAudio?.played == true, "Success must publish the ready spatial player")
        print("PASS actual startup classification/cache insertion with injected errors; no decoder or network activity")
    }
}
