import Foundation

enum DurationFormatter {
    static func string(from seconds: TimeInterval) -> String {
        guard
            seconds.isFinite,
            seconds >= 0,
            seconds <= TimeInterval(Int.max / 2)
        else {
            return "-"
        }

        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
