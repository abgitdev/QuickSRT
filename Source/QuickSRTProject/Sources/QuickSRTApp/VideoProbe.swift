import Foundation

struct VideoInfo: Equatable, Sendable {
    let duration: TimeInterval
    let hasAudio: Bool
}

enum VideoProbe {
    static func parse(_ data: Data) throws -> VideoInfo {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let streams = root["streams"] as? [[String: Any]]
        else {
            throw QuickSRTError.invalidVideo(.invalidDescription)
        }

        let hasAudio = streams.contains { stream in
            (stream["codec_type"] as? String) == "audio"
        }

        guard hasAudio else {
            throw QuickSRTError.invalidVideo(.noAudioTrack)
        }

        let duration = parseDuration(root: root, streams: streams)
        guard let duration, duration.isFinite, duration > 0 else {
            throw QuickSRTError.invalidVideo(.durationUnavailable)
        }
        guard duration <= PipelineResourcePreflight.maximumVideoDuration else {
            throw QuickSRTError.videoDurationLimitExceeded(
                maximum: PipelineResourcePreflight.maximumVideoDuration
            )
        }

        return VideoInfo(duration: duration, hasAudio: true)
    }

    private static func parseDuration(root: [String: Any], streams: [[String: Any]]) -> TimeInterval? {
        if
            let format = root["format"] as? [String: Any],
            let duration = number(from: format["duration"])
        {
            return duration
        }

        return streams.compactMap { number(from: $0["duration"]) }.max()
    }

    private static func number(from value: Any?) -> TimeInterval? {
        if let string = value as? String {
            return TimeInterval(string)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

}
