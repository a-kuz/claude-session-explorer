// Display formatting helpers (Russian locale).

import Foundation

enum Format {
    static let ru = Locale(identifier: "ru_RU")

    /// Relative time like "2 мин", "5 ч", "3 д", or an absolute date for old items.
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(date)
        let min = 60.0, hour = 3600.0, day = 86400.0
        if diff < min { return "сейчас" }
        if diff < hour { return "\(Int(diff / min)) мин" }
        if diff < day { return "\(Int(diff / hour)) ч" }
        if diff < 7 * day { return "\(Int(diff / day)) д" }
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    /// List timestamp in the mail style: today → time ("11:30"), yesterday →
    /// "Вчера", the day before → "Позавчера", older → "18.06.2026".
    static func mailTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return timeOnly(date) }
        if cal.isDateInYesterday(date) { return "Вчера" }
        if let twoAgo = cal.date(byAdding: .day, value: -2, to: now),
           cal.isDate(date, inSameDayAs: twoAgo) { return "Позавчера" }
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: date)
    }

    /// Time only, e.g. "14:25".
    static func timeOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Time if the date is today, otherwise date + time: "14:25" / "16 июн 14:25".
    static func timeOrDate(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return timeOnly(date) }
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }

    /// Long date with time, e.g. "16 июня 2026, 14:25".
    static func longDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return f.string(from: date)
    }

    /// Compact "16 июня".
    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = "d MMMM"
        return f.string(from: date)
    }

    /// Span across a session: same day → "16 июня 2026"; across days → "16 → 17 июня 2026".
    static func dateRange(_ first: Date?, _ last: Date?) -> String {
        guard let last = last else { return "" }
        guard let first = first, !Calendar.current.isDate(first, inSameDayAs: last) else {
            let f = DateFormatter(); f.locale = ru; f.dateFormat = "d MMMM yyyy"
            return f.string(from: last)
        }
        let cal = Calendar.current
        let dayF = DateFormatter(); dayF.locale = ru; dayF.dateFormat = "d"
        let fullF = DateFormatter(); fullF.locale = ru; fullF.dateFormat = "d MMMM yyyy"
        // Same month/year → "16 → 17 июня 2026"
        if cal.isDate(first, equalTo: last, toGranularity: .month) {
            return "\(dayF.string(from: first)) → \(fullF.string(from: last))"
        }
        return "\(fullF.string(from: first)) → \(fullF.string(from: last))"
    }

    /// Session span with times, like the mock: same day → "16 июня 14:25 → 18:40";
    /// across days → "16 июня 22:11 → 17 июня 00:40". Empty if no end time.
    static func activitySpan(_ first: Date?, _ last: Date?) -> String {
        guard let last = last else { return "" }
        let timeF = DateFormatter(); timeF.locale = ru; timeF.dateFormat = "HH:mm"
        let dayTimeF = DateFormatter(); dayTimeF.locale = ru; dayTimeF.dateFormat = "d MMMM HH:mm"
        guard let first = first else { return dayTimeF.string(from: last) }
        let lhs = dayTimeF.string(from: first)
        let rhs = Calendar.current.isDate(first, inSameDayAs: last)
            ? timeF.string(from: last)
            : dayTimeF.string(from: last)
        return "\(lhs) → \(rhs)"
    }

    /// Human file size: "12 КБ", "3.4 МБ".
    static func byteSize(_ bytes: Int) -> String {
        let kb = 1024.0, mb = kb * 1024
        if Double(bytes) < kb { return "\(bytes) Б" }
        if Double(bytes) < mb { return "\(Int((Double(bytes) / kb).rounded())) КБ" }
        let m = Double(bytes) / mb
        return m < 10 ? String(format: "%.1f МБ", m) : "\(Int(m.rounded())) МБ"
    }

    /// Pluralize "сообщение/сообщения/сообщений".
    static func messagesWord(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "\(n) сообщение" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) сообщения" }
        return "\(n) сообщений"
    }

    /// Section bucket for the list (Сегодня / Вчера / На этой неделе / older month).
    enum Bucket: Int { case today, yesterday, week, older }

    static func bucket(_ date: Date, now: Date = Date()) -> (Bucket, String) {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return (.today, "СЕГОДНЯ") }
        if cal.isDateInYesterday(date) { return (.yesterday, "ВЧЕРА") }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), date > weekAgo {
            return (.week, "НА ЭТОЙ НЕДЕЛЕ")
        }
        let f = DateFormatter(); f.locale = ru; f.dateFormat = "LLLL yyyy"
        return (.older, f.string(from: date).uppercased())
    }
}
