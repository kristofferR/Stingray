//
//  AVPlayerItemExtension.swift
//  Stingray
//
//  Created by kristofferR on 10/11/26.
//

import AVKit

/// Extend the AVPlayerItem type to share how streams are presented and buffered
extension AVPlayerItem {
    /// Shows the title on the player, and buffers generously while streaming
    /// - Parameters:
    ///   - title: Main title of the content to be shown
    ///   - subtitle: An optional descriptor of the content (ex. season 2, episode 4)
    public func setupForStreaming(title: String, subtitle: String?) {
        // Set the title metadata
        let titleMetadata = AVMutableMetadataItem()
        titleMetadata.identifier = .commonIdentifierTitle
        titleMetadata.value = title as NSString
        titleMetadata.extendedLanguageTag = "und"

        // Set the subtitle/description metadata
        let subtitleMetadata = AVMutableMetadataItem()
        subtitleMetadata.identifier = .iTunesMetadataTrackSubTitle
        subtitleMetadata.value = (subtitle ?? "") as NSString // Empty string for no subtitle
        subtitleMetadata.extendedLanguageTag = "und"

        self.externalMetadata = [titleMetadata, subtitleMetadata]
        self.audioTimePitchAlgorithm = .spectral

        // Setup streaming buffering
        self.preferredForwardBufferDuration = TimeInterval(600) // 10 minutes
        self.canUseNetworkResourcesForLiveStreamingWhilePaused = true // Allow buffering while paused
    }
}
