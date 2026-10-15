#!/bin/bash
# Cloud-only host checks. Compile production method slices with inert player/network doubles, without media or a test target.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/stingray-playback-checks.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

ruby - "$project_dir" "$probe_dir/Production.swift" <<'RUBY'
root, output = ARGV
def block(text, marker)
  start = text.index(marker) or abort("Missing production declaration: #{marker}")
  opening = text.index('{', start) or abort('Missing opening brace')
  depth = 1
  finish = opening + 1
  while depth > 0 && finish < text.length
    depth += 1 if text[finish] == '{'
    depth -= 1 if text[finish] == '}'
    finish += 1
  end
  abort("Unbalanced declaration: #{marker}") unless depth == 0
  text[start...finish]
end
model = File.read(File.join(root, 'Stingray/Models/MediaModel.swift'))
spatial = File.read(File.join(root, 'Stingray/Models/SpatialAudioModel.swift'))
service = File.read(File.join(root, 'Stingray/Models/StreamingServiceModel.swift'))
parts = ['import Foundation', 'import CoreMedia']
['public protocol MediaSourceProtocol', 'public protocol MediaStreamProtocol',
 'public final class MediaSource:', 'public final class MediaStream:', 'public enum StreamType:'].each do |marker|
  parts << block(model, marker)
end
['Movie', 'TV'].each do |kind|
  directory = kind == 'Movie' ? 'Movies' : 'TV Shows'
  text = File.read(File.join(root, "Stingray/Views/Player/#{directory}/#{kind}PlayerViewModel.swift"))
  parts << "final class #{kind}Case: PlayerHost, Switching {\n" +
    block(text, 'public func newPlayer(') + "\n" + block(text, 'public func stopPlayer()') + "\n}"
end
parts << "public final class SpatialAudioModel {\n" + block(spatial, 'public enum StartError:') + "\n" +
  block(spatial, 'public static func start(') + <<~SWIFT
  static var nextError: (any Error)?
  var played = false
  static func open(content: SpatialAudioContent, audioStream: any MediaStreamProtocol,
                   mediaSource: any MediaSourceProtocol, startTime: CMTime, player: AVPlayer,
                   fallback: @escaping (CMTime) -> Void) async throws -> SpatialAudioModel {
      if let error = nextError { throw error }
      return SpatialAudioModel()
  }
  func play(title: String, subtitle: String?) { played = true }
  func stop() {}
  }
SWIFT
parts << "final class FailureHost {\n" + block(service, 'private func startSpatialAudio(') + <<~SWIFT
  var spatialAudioStart: Task<Void, Never>?
  var spatialAudio: SpatialAudioModel?
  var spatialAudioFailures: Set<SpatialAudioRefusalKey> = []
  var fallbackTimes: [CMTime] = []
  func attempt(source: MediaSource, audio: MediaStream, key: SpatialAudioRefusalKey) async {
      startSpatialAudio(content: SpatialAudioContent(), audioStream: audio, mediaSource: source,
                        title: "test", subtitle: nil, startTime: CMTime(seconds: 930, preferredTimescale: 600),
                        player: AVPlayer(), fallback: { self.fallbackTimes.append($0) }, failureKey: key)
      await spatialAudioStart?.value
  }
  }
SWIFT
File.write(output, parts.join("\n\n"))
RUBY

xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  "$project_dir/Stingray/Models/SpatialAudioRefusalKey.swift" \
  "$project_dir/Stingray/Extensions/TimeIntervalExtension.swift" \
  "$project_dir/Stingray/Views/Player/Components/StreamTransitionType.swift" \
  "$probe_dir/Production.swift" "$project_dir/Tests/PlaybackStateChecks.swift" \
  -o "$probe_dir/PlaybackStateChecks"
"$probe_dir/PlaybackStateChecks"
