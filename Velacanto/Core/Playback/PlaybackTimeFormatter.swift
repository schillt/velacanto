import Foundation

enum PlaybackTimeFormatter {
    static func format(seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }

        let totalSeconds = max(Int(seconds.rounded(.down)), 0)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
