import Foundation

/// Durations for display (same rules as the iOS `Format`).
enum DurationFormat {
    /// 8040 s → [("2", "小時"), ("14", "分")]. Under a minute shows seconds; under ten minutes
    /// shows minutes and seconds.
    static func parts(seconds: Double) -> [(value: String, unit: String)] {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return minutes > 0 && hours < 100 ? [("\(hours)", "小時"), ("\(minutes)", "分")] : [("\(hours)", "小時")]
        }
        if minutes >= 10 { return [("\(minutes)", "分")] }
        if minutes > 0 { return secs > 0 ? [("\(minutes)", "分"), ("\(secs)", "秒")] : [("\(minutes)", "分")] }
        return [("\(secs)", "秒")]
    }

    static func text(seconds: Double) -> String {
        parts(seconds: seconds).map { "\($0.value) \($0.unit)" }.joined(separator: " ")
    }
}
