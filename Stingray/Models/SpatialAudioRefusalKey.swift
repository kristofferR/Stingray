import Foundation

/// A decoder refusal belongs to one server, loaded source snapshot and selected internal audio input.
public struct SpatialAudioRefusalKey: Hashable {
    /// Server identity, including its endpoint when a server connection changes
    private let serverID: String
    /// Endpoint serving the source
    private let serviceURL: URL
    /// Metadata load that supplied the audio mapping
    private let snapshotID: UUID
    /// Source within that server
    private let sourceID: String
    /// Selected server stream
    private let audioID: String
    /// Position among internal audio tracks, which SpatialAudioModel uses to select the Matroska track
    private let ordinal: Int
    /// Codec reported for this input
    private let codec: String
    /// Decoder profile reported for this input
    private let profile: String

    /// Identifies the same audio input regardless of video, subtitle and target bitrate selections.
    /// - Parameters:
    ///   - serverID: Server identity
    ///   - serviceURL: Endpoint serving the source
    ///   - source: Loaded source snapshot
    ///   - audio: Selected internal audio stream
    public init?(serverID: String, serviceURL: URL, source: any MediaSourceProtocol, audio: any MediaStreamProtocol) {
        guard !audio.isExternal,
              let ordinal = source.audioStreams.filter({ !$0.isExternal }).firstIndex(where: { $0.id == audio.id })
        else { return nil }
        self.serverID = serverID
        self.serviceURL = serviceURL
        self.snapshotID = source.snapshotID
        self.sourceID = source.id
        self.audioID = audio.id
        self.ordinal = ordinal
        self.codec = audio.codec
        self.profile = audio.profile
    }
}
