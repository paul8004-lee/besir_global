import Foundation

/// SPEC-BOOKCARD-001 (card t89) REQ-011: the check of what the model fills in. The model passes a value together with a quote;
/// a value is kept only when the quote is the user's own words and the value is read back from the quote. Foundation only: no
/// session, no toolbox and no view. The kept values are the ones the card shows as stated; everything else stays blank, and the
/// model is told nothing about what was dropped.
enum AgentPrefill {
    static let maxEntries = 8
    static let maxQuoteLength = 200
    static let maxTextLength = 120
    static let maxNumberDigits = 9
    /// The allowed window for a time: from the current minute to this many days ahead.
    static let windowDays = 366

    /// `fieldsText` is a JSON array of objects with the string members `key`, `value` and `quote`. Returns the kept values by
    /// key. `userLines` are the lines the user wrote in this chat; `now` and `calendar` (with its zone) decide what a time means.
    static func values(fieldsText: String?, fields: [PartnerField], userLines: [String], now: Date,
                       calendar: Calendar) -> [String: AgentFieldValue] {
        guard let fieldsText, let data = fieldsText.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [:] }
        var kinds: [String: PartnerFieldKind] = [:]
        for field in fields { kinds[field.key] = field.kind }
        var claimed: Set<String> = []
        var kept: [String: AgentFieldValue] = [:]
        for element in list.prefix(maxEntries) {
            // An entry that is not an object of three strings is skipped alone and claims no key.
            guard let entry = element as? [String: Any], let key = entry["key"] as? String, let value = entry["value"] as? String,
                  let quote = entry["quote"] as? String else { continue }
            // A switch or a chip field is never filled; an unknown key is skipped; the first entry for a key is the only one.
            guard let kind = kinds[key], kind != .pickOne, kind != .onOff, !claimed.contains(key) else { continue }
            claimed.insert(key)
            guard let cleanQuote = cleaned(quote, limit: maxQuoteLength),
                  userLines.contains(where: { contains($0, cleanQuote) }) else { continue }
            if let read = read(value, kind: kind, quote: cleanQuote, now: now, calendar: calendar) { kept[key] = read }
        }
        return kept
    }

    // MARK: Reading a value back from its quote

    private static func read(_ value: String, kind: PartnerFieldKind, quote: String, now: Date, calendar: Calendar) -> AgentFieldValue? {
        switch kind {
        case .text, .place:
            guard let text = cleaned(value, limit: maxTextLength), contains(quote, text) else { return nil }
            return .text(text)
        case .number:
            let scalars = Array(value.unicodeScalars)
            guard (1...maxNumberDigits).contains(scalars.count), scalars.allSatisfy(isDigit), let number = Int(value),
                  numbers(in: quote).contains(number) else { return nil }
            return .number(number)
        case .time:
            return time(value, quote: quote, now: now, calendar: calendar)
        case .pickOne, .onOff:
            return nil
        }
    }

    /// Cleaned as the card cleans typing, then trimmed; nil when nothing is left.
    private static func cleaned(_ text: String, limit: Int) -> String? {
        let result = AgentDelivery.cleanedTyped(text, limit: limit).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Character for character, with the case and the spaces as written.
    private static func contains(_ text: String, _ part: String) -> Bool {
        text.range(of: part, options: [.literal]) != nil
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { (0x30...0x39).contains(scalar.value) }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool { (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) }

    // MARK: Numbers

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12]

    /// The digit runs of the quote and the numbers named by a whole English word from one to twelve (any case).
    private static func numbers(in quote: String) -> Set<Int> {
        var found: Set<Int> = []
        var digits = String.UnicodeScalarView()
        var letters = String.UnicodeScalarView()
        func flushDigits() {
            if !digits.isEmpty, digits.count <= maxNumberDigits, let number = Int(String(digits)) { found.insert(number) }
            digits = String.UnicodeScalarView()
        }
        func flushLetters() {
            if let number = numberWords[String(letters).lowercased()] { found.insert(number) }
            letters = String.UnicodeScalarView()
        }
        for scalar in quote.unicodeScalars {
            if isDigit(scalar) {
                flushLetters()
                digits.append(scalar)
            } else if isLetter(scalar) {
                flushDigits()
                letters.append(scalar)
            } else {
                flushDigits()
                flushLetters()
            }
        }
        flushDigits()
        flushLetters()
        return found
    }

    // MARK: Times

    private struct Day: Equatable {
        let year: Int
        let month: Int
        let day: Int
    }

    private struct Clock: Equatable {
        let hour: Int
        let minute: Int
    }

    /// The value is kept only when the quote writes exactly one clock time and exactly one date and both equal the value's.
    private static func time(_ value: String, quote: String, now: Date, calendar: Calendar) -> AgentFieldValue? {
        guard PartnerForm.minuteOfDay(value) != nil, let year = Int(value.prefix(4)), let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.dropFirst(8).prefix(2)), let hour = Int(value.dropFirst(11).prefix(2)),
              let minute = Int(value.dropFirst(14).prefix(2)) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard back.year == year, back.month == month, back.day == day, back.hour == hour, back.minute == minute else { return nil }
        let floor = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        guard date.timeIntervalSince1970 >= floor, date.timeIntervalSince1970 <= floor + Double(windowDays) * 24 * 3600 else { return nil }

        let (clocks, masked) = clockTimes(in: quote)
        let days = dates(in: masked, now: now, calendar: calendar)
        guard clocks.count == 1, days.count == 1, clocks[0] == Clock(hour: hour, minute: minute),
              days[0] == Day(year: year, month: month, day: day) else { return nil }
        return .time(date)
    }

    private static let clockPattern = try? NSRegularExpression(
        pattern: "(?<![0-9:])(?:(1[0-2]|0?[1-9])(?::([0-5][0-9]))?[ ]*(am|pm)(?![a-z])|([01][0-9]|2[0-3]):([0-5][0-9])(?![0-9:])|\\bnoon\\b)",
        options: [.caseInsensitive])

    /// The clock times the quote writes (`H am/pm`, `H:MM am/pm`, `HH:MM`, `noon`) and the quote with their text blanked out,
    /// so a later token cannot read the same characters again. A bare `7` is not a clock time.
    private static func clockTimes(in quote: String) -> (clocks: [Clock], masked: String) {
        guard let pattern = clockPattern else { return ([], quote) }
        let text = quote as NSString
        var clocks: [Clock] = []
        var masked = quote
        let matches = pattern.matches(in: quote, range: NSRange(location: 0, length: text.length))
        for match in matches {
            let word = text.substring(with: match.range).lowercased()
            if word.hasPrefix("noon") {
                clocks.append(Clock(hour: 12, minute: 0))
            } else if match.range(at: 1).location != NSNotFound {
                let hour12 = Int(text.substring(with: match.range(at: 1))) ?? 0
                let minute = match.range(at: 2).location == NSNotFound ? 0 : Int(text.substring(with: match.range(at: 2))) ?? 0
                let afternoon = text.substring(with: match.range(at: 3)).lowercased() == "pm"
                clocks.append(Clock(hour: hour12 % 12 + (afternoon ? 12 : 0), minute: minute))
            } else {
                clocks.append(Clock(hour: Int(text.substring(with: match.range(at: 4))) ?? 0, minute: Int(text.substring(with: match.range(at: 5))) ?? 0))
            }
            masked = (masked as NSString).replacingCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        return (clocks, masked)
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]

    private static let datePattern = try? NSRegularExpression(
        pattern: "(?<![0-9-])([0-9]{4})-([0-9]{2})-([0-9]{2})(?![0-9])"
            + "|\\b(today|tonight|tomorrow)\\b"
            + "|\\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)[ ]+([0-9]{1,2})(?:st|nd|rd|th)?(?![0-9a-z])"
            + "|\\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b",
        options: [.caseInsensitive])

    /// The dates the quote writes, each resolved to a day (nil when it names no real day inside the window): `today`,
    /// `tonight`, `tomorrow`, `YYYY-MM-DD`, a month with a day (the nearest such day on or after today) and a weekday name (the
    /// next such day on or after today). A weekday after the word `next` is not read.
    private static func dates(in text: String, now: Date, calendar: Calendar) -> [Day?] {
        guard let pattern = datePattern else { return [] }
        let source = text as NSString
        let today = calendar.startOfDay(for: now)
        var found: [Day?] = []
        func part(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            match.range(at: index).location == NSNotFound ? nil : source.substring(with: match.range(at: index)).lowercased()
        }
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if let year = part(match, 1).flatMap({ Int($0) }), let month = part(match, 2).flatMap({ Int($0) }),
               let day = part(match, 3).flatMap({ Int($0) }) {
                found.append(realDay(year, month, day, calendar: calendar))
            } else if let word = part(match, 4) {
                found.append(shifted(by: word == "tomorrow" ? 1 : 0, from: today, calendar: calendar))
            } else if let name = part(match, 5), let month = months[String(name.prefix(3))], let day = part(match, 6).flatMap({ Int($0) }) {
                found.append(nearest(month: month, day: day, today: today, calendar: calendar))
            } else if let name = part(match, 7), let target = weekdays[name] {
                let before = source.substring(to: match.range.location).trimmingCharacters(in: .whitespaces).lowercased()
                // A weekday after the whole word next is a phrase this check does not read.
                if before.hasSuffix("next"), before.dropLast(4).unicodeScalars.last.map({ !isLetter($0) }) ?? true { continue }
                let current = calendar.component(.weekday, from: today)
                found.append(shifted(by: (target - current + 7) % 7, from: today, calendar: calendar))
            }
        }
        return found
    }

    private static func shifted(by count: Int, from start: Date, calendar: Calendar) -> Day? {
        guard let date = calendar.date(byAdding: .day, value: count, to: start) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return Day(year: year, month: month, day: day)
    }

    /// A day that exists in the calendar, or nil.
    private static func realDay(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Day? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day ? Day(year: year, month: month, day: day) : nil
    }

    /// The first day on or after today, inside the window, with this month and day; nil when there is none.
    private static func nearest(month: Int, day: Int, today: Date, calendar: Calendar) -> Day? {
        let thisYear = calendar.component(.year, from: today)
        guard let limit = calendar.date(byAdding: .day, value: windowDays, to: today) else { return nil }
        for year in thisYear...(thisYear + 4) {
            guard let candidate = realDay(year, month, day, calendar: calendar) else { continue }
            var components = DateComponents()
            components.year = candidate.year
            components.month = candidate.month
            components.day = candidate.day
            guard let date = calendar.date(from: components), date >= today else { continue }
            return date <= limit ? candidate : nil
        }
        return nil
    }
}
