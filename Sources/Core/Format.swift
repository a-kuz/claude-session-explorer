// Display formatting helpers. Dates, numbers and pluralization follow the
// user's current locale via the system formatters.

import Foundation

enum Format {
    /// Relative time like "2 min", "5 h", "3 d", or an absolute date for old items.
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(date)
        let min = 60.0, hour = 3600.0, day = 86400.0
        if diff < min { return String(localized: "now") }
        if diff < hour { return relative(Int(diff / min), .minute) }
        if diff < day { return relative(Int(diff / hour), .hour) }
        if diff < 7 * day { return relative(Int(diff / day), .day) }
        return dateFormatted(date, format: "d MMM")
    }

    private static func relative(_ value: Int, _ unit: NSCalendar.Unit) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [unit]
        f.maximumUnitCount = 1
        let interval: TimeInterval
        switch unit {
        case .minute: interval = Double(value) * 60
        case .hour: interval = Double(value) * 3600
        default: interval = Double(value) * 86400
        }
        return f.string(from: interval) ?? "\(value)"
    }

    /// List timestamp in the mail style: today → time ("11:30"), yesterday →
    /// "Yesterday", this year → "15 Jul", older → "15 Jul 25". The word-month
    /// form matches the "Yesterday" register; a full numeric date ("15.07.2026")
    /// next to it read as two different systems.
    static func mailTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return timeOnly(date) }
        if cal.isDateInYesterday(date) {
            return RelativeDateTimeFormatter.named.localizedString(from: DateComponents(day: -1))
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return dateFormatted(date, format: "d MMM")
        }
        return dateFormatted(date, format: "d MMM yy")
    }

    /// Time only, e.g. "14:25" / "2:25 PM" depending on locale.
    static func timeOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Time if the date is today, otherwise date + time.
    static func timeOrDate(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return timeOnly(date) }
        return dateFormatted(date, format: "d MMM HH:mm")
    }

    /// Long date with time, e.g. "16 June 2026, 14:25".
    static func longDateTime(_ date: Date) -> String {
        dateFormatted(date, format: "d MMMM yyyy, HH:mm")
    }

    /// Compact "16 June".
    static func shortDate(_ date: Date) -> String {
        dateFormatted(date, format: "d MMMM")
    }

    /// Span across a session: same day → "16 June 2026"; across days → "16 → 17 June 2026".
    static func dateRange(_ first: Date?, _ last: Date?) -> String {
        guard let last = last else { return "" }
        guard let first = first, !Calendar.current.isDate(first, inSameDayAs: last) else {
            return dateFormatted(last, format: "d MMMM yyyy")
        }
        let cal = Calendar.current
        // Same month/year → "16 → 17 June 2026"
        if cal.isDate(first, equalTo: last, toGranularity: .month) {
            return "\(dateFormatted(first, format: "d")) → \(dateFormatted(last, format: "d MMMM yyyy"))"
        }
        return "\(dateFormatted(first, format: "d MMMM yyyy")) → \(dateFormatted(last, format: "d MMMM yyyy"))"
    }

    /// Session span with times: same day → "16 June 14:25 → 18:40";
    /// across days → "16 June 22:11 → 17 June 00:40". Empty if no end time.
    static func activitySpan(_ first: Date?, _ last: Date?) -> String {
        guard let last = last else { return "" }
        guard let first = first else { return dateFormatted(last, format: "d MMMM HH:mm") }
        let lhs = dateFormatted(first, format: "d MMMM HH:mm")
        let rhs = Calendar.current.isDate(first, inSameDayAs: last)
            ? dateFormatted(last, format: "HH:mm")
            : dateFormatted(last, format: "d MMMM HH:mm")
        return "\(lhs) → \(rhs)"
    }

    /// Locale-aware date formatting from a template (reorders fields per locale).
    private static func dateFormatted(_ date: Date, format template: String) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// Human file size via the system byte-count formatter ("12 KB", "3.4 MB").
    static func byteSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Very coarse size for the session list: "110K", "1.8M", "23M".
    /// Decimal units; megabytes get one decimal below 10, none above.
    static func compactBytes(_ bytes: Int) -> String {
        let m = Double(bytes) / 1_000_000
        if m >= 10 { return "\(Int(m.rounded()))M" }
        if m >= 1 {
            let s = String(format: "%.1f", m)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "M"
        }
        return "\(max(1, Int((Double(bytes) / 1_000).rounded())))K"
    }

    /// Message count with English pluralization, e.g. "1 message" / "5 messages".
    static func messagesWord(_ n: Int) -> String {
        "\(n) " + (n == 1 ? "message" : "messages")
    }

    /// Section bucket for the list (Today / Yesterday / This Week / older month).
    enum Bucket: Int { case today, yesterday, week, older }

    static func bucket(_ date: Date, now: Date = Date()) -> (Bucket, String) {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return (.today, String(localized: "TODAY")) }
        if cal.isDateInYesterday(date) { return (.yesterday, String(localized: "YESTERDAY")) }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), date > weekAgo {
            return (.week, String(localized: "THIS WEEK"))
        }
        return (.older, dateFormatted(date, format: "LLLL yyyy").uppercased())
    }
}

private extension RelativeDateTimeFormatter {
    static let named: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = .current
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f
    }()
}
