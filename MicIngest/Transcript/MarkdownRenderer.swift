import Foundation

/// Deterministic Markdown transcript: same transcript + metadata in, same bytes out.
/// No LLM involved; the transcript text is written exactly as transcribed.
enum MarkdownRenderer {
    private static let months = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]

    /// `1 October 2026`, fixed English so output does not depend on the system locale.
    static func longDate(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.day ?? 1) \(months[(parts.month ?? 1) - 1]) \(parts.year ?? 0)"
    }

    /// `2026-10-01`, in the given zone.
    static func isoDay(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A YAML scalar: plain when that is unambiguous, double-quoted otherwise.
    private static func yaml(_ value: String) -> String {
        let plain = value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || " .-_".unicodeScalars.contains($0) }
        guard !plain || value.isEmpty || value != value.trimmingCharacters(in: .whitespaces) else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Front matter first (date, times, duration, speakers, audio file), so a reader, human or LLM,
    /// knows what the recording is before reading it; then one heading per turn with its clock time.
    static func render(transcript: Transcript, metadata: SessionMetadata) -> String {
        let timeline = metadata.timeline
        let zone = timeline.timeZone
        let session = metadata.session
        let startDay = isoDay(session.start, in: zone), endDay = isoDay(session.end, in: zone)
        var seen = Set<String>()
        let speakers = transcript.speakers.map(metadata.displayName(for:)).filter { seen.insert($0).inserted }

        var lines = ["---",
                     "date: \(startDay)",
                     "start: \"\(SessionTimeline.clock(session.start, in: zone))\"",
                     "end: \"\(SessionTimeline.clock(session.end, in: zone))\""]
        if endDay != startDay { lines.append("end_date: \(endDay)") }
        // The actual audio length. The import list shows the clock span instead (20:43–22:52 is "2h 09m"),
        // so the two can differ by a minute; here the precise value is the more useful one.
        lines += ["duration: \(Format.duration(session.durationSeconds))",
                  "speakers: [\(speakers.map(yaml).joined(separator: ", "))]",
                  "audio: \(LibraryFolder.dataFolderName)/\(metadata.audio.filename)",
                  "---",
                  "",
                  "# Recording · \(longDate(session.start, in: zone))"]

        if transcript.utterances.isEmpty {
            lines += ["", "_No speech was detected in this recording._"]
        }
        for utterance in transcript.utterances {
            lines += ["",
                      "## \(timeline.clockTime(atMs: utterance.startMs)) · \(metadata.displayName(for: utterance.speaker))",
                      "",
                      utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
