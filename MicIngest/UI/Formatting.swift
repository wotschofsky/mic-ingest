import Foundation

/// Compact display strings used across the UI.
enum Format {
    /// `2h 09m`, `54m`, `1m`, `32s`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes)m" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// Length of a session as read off its clock times: `20:43–22:52` is `2h 09m`.
    /// Under a minute the exact number of seconds is shown instead.
    static func span(_ start: Date, _ end: Date) -> String {
        let seconds = end.timeIntervalSince(start)
        if seconds < 60 { return duration(seconds) }
        let minutes = Int(end.timeIntervalSinceReferenceDate / 60) - Int(start.timeIntervalSinceReferenceDate / 60)
        return minutes < 60 ? "\(max(minutes, 1))m" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// `about 40 s left`, `about 3 min left`.
    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return "a few seconds left" }
        if seconds < 55 { return "about \(Int((seconds / 10).rounded()) * 10) s left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }

    /// `1:02:03` or `2:03`, for the playback position.
    static func position(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `Oct 1`, in the given zone.
    static func day(_ date: Date, in timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle().month(.abbreviated).day()
        style.timeZone = timeZone
        style.locale = Locale(identifier: "en_US")
        return date.formatted(style)
    }

    /// `20:43–22:52`.
    static func timeRange(_ start: Date, _ end: Date, in timeZone: TimeZone = .current) -> String {
        "\(SessionTimeline.clock(start, in: timeZone, seconds: false))–\(SessionTimeline.clock(end, in: timeZone, seconds: false))"
    }

    /// `Oct 1 · 20:43–22:52`.
    static func sessionTitle(_ start: Date, _ end: Date, in timeZone: TimeZone = .current) -> String {
        "\(day(start, in: timeZone)) · \(timeRange(start, end, in: timeZone))"
    }

    /// `UTC+8`, `UTC−3`, `UTC+5:30`.
    static func utcOffset(_ zone: TimeZone) -> String {
        let seconds = zone.secondsFromGMT()
        let hours = abs(seconds) / 3600, minutes = abs(seconds) % 3600 / 60
        return "UTC\(seconds < 0 ? "−" : "+")\(hours)" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }

    static func sourceFiles(_ count: Int) -> String {
        count == 1 ? "1 source file" : "\(count) source files"
    }

    /// `~/Documents/Recordings` instead of the full home path.
    static func path(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
