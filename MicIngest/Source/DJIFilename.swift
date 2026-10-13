import Foundation

/// Parsed form of a DJI recorder filename such as `TX01_MIC002_20261001_204349_orig.wav`.
struct DJIFilename: Equatable {
    let transmitter: String
    let sequence: Int
    /// Trailing tag such as `orig`. Files with different tags are different renditions and never merge.
    let variant: String
    /// Wall-clock recording start as written by the recorder (no time zone on the device).
    let startComponents: DateComponents

    private static let pattern = try! NSRegularExpression(
        pattern: #"^([A-Za-z]+[0-9]+)_MIC([0-9]+)_([0-9]{8})_([0-9]{6})((?:_[A-Za-z0-9]+)*)\.wav$"#,
        options: [.caseInsensitive])

    init?(_ filename: String) {
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = Self.pattern.firstMatch(in: filename, range: range) else { return nil }
        func group(_ i: Int) -> String { String(filename[Range(match.range(at: i), in: filename)!]) }
        guard let sequence = Int(group(2)) else { return nil }

        let date = group(3), time = group(4)
        func int(_ s: String, _ from: Int, _ length: Int) -> Int {
            let start = s.index(s.startIndex, offsetBy: from)
            return Int(s[start..<s.index(start, offsetBy: length)]) ?? -1
        }
        var components = DateComponents()
        components.year = int(date, 0, 4)
        components.month = int(date, 4, 2)
        components.day = int(date, 6, 2)
        components.hour = int(time, 0, 2)
        components.minute = int(time, 2, 2)
        components.second = int(time, 4, 2)
        // Reject impossible timestamps (month 13, 25:61:61, 30 February) instead of letting Calendar roll them over.
        // Validated in UTC so that a wall-clock time inside a DST gap is not mistaken for a malformed name.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard components.isValidDate(in: utc) else { return nil }

        self.transmitter = group(1).uppercased()
        self.sequence = sequence
        self.variant = group(5).dropFirst().lowercased()
        self.startComponents = components
    }

    func startDate(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: startComponents)
    }
}
