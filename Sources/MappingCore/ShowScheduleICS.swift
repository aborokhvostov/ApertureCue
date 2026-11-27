import Foundation

/// Local iCalendar import for start triggers. Stored entries contain only the
/// event name, UID, supported timing fields and the explicitly chosen scene.
public enum ShowScheduleICS {
    public static let maximumBytes = 256 * 1024

    public static func parse(_ data: Data, cueID: UUID, floatingTimeZoneID: String) throws -> [ShowScheduleEntry] {
        _ = try ScheduleCalendar.zone(floatingTimeZoneID)
        let lines = try unfoldedLines(data)
        var result: [ShowScheduleEntry] = []
        var calendar = false
        var ended = false
        var version = false
        var event: Event?
        var alarm = false
        for line in lines {
            let property = try Property(line)
            if property.name == "BEGIN" || property.name == "END" {
                guard property.parameters.isEmpty else { throw failure("component parameters are unsupported") }
                let begin = property.name == "BEGIN"
                switch (begin, property.value.uppercased()) {
                case (true, "VCALENDAR") where !calendar && !ended: calendar = true
                case (false, "VCALENDAR") where calendar && event == nil && !alarm:
                    calendar = false
                    ended = true
                case (true, "VEVENT") where calendar && event == nil && !alarm:
                    guard result.count < ShowSchedule.maximumEntries else { throw failure("too many calendar events") }
                    event = Event()
                case (false, "VEVENT") where calendar && event != nil && !alarm:
                    guard let complete = event else { throw failure("missing event") }
                    result.append(try complete.entry(cueID: cueID, floatingZone: floatingTimeZoneID))
                    event = nil
                case (true, "VALARM") where event != nil && !alarm: alarm = true
                case (false, "VALARM") where alarm: alarm = false
                default: throw failure("unsupported or unbalanced calendar component")
                }
                continue
            }
            guard calendar else { throw failure("expected a VCALENDAR container") }
            if alarm { continue }
            if event != nil {
                try event?.add(property)
            } else {
                switch property.name {
                case "VERSION":
                    guard !version, property.parameters.isEmpty, property.value == "2.0" else {
                        throw failure("calendar VERSION must be 2.0")
                    }
                    version = true
                case "CALSCALE":
                    guard property.parameters.isEmpty, property.value.uppercased() == "GREGORIAN" else {
                        throw failure("unsupported calendar scale")
                    }
                case "METHOD":
                    guard property.parameters.isEmpty, property.value.uppercased() == "PUBLISH" else {
                        throw failure("calendar invitation/update methods are unsupported")
                    }
                default: break // Calendar metadata is not stored or acted upon.
                }
            }
        }
        guard ended, version, !result.isEmpty else { throw failure("expected a complete iCalendar 2.0 file with events") }
        try ShowSchedule(entries: result).validate(cueIDs: [cueID])
        return result
    }

    public static func parseRecurrence(_ value: String) throws -> ShowScheduleRecurrence {
        try recurrenceRule(Property("RRULE:" + value))
    }

    public static func formatRecurrence(_ rule: ShowScheduleRecurrence) -> String {
        var fields = ["FREQ=" + rule.frequency.rawValue.uppercased()]
        if rule.interval != 1 { fields.append("INTERVAL=\(rule.interval)") }
        if let count = rule.count { fields.append("COUNT=\(count)") }
        if let until = rule.until { fields.append("UNTIL=" + ScheduleCalendar.format(until) + "Z") }
        if !rule.weekdays.isEmpty { fields.append("BYDAY=" + rule.weekdays.map(\.rawValue).joined(separator: ",")) }
        return fields.joined(separator: ";")
    }

    /// Supplies a zone-relative default when starting a new schedule entry.
    public static func localStart(for date: Date, timeZoneID: String) throws -> String {
        let zone = try ScheduleCalendar.zone(timeZoneID)
        guard ScheduleCalendar.supportedAbsolute.contains(date) else { throw failure("invalid schedule date") }
        return ScheduleCalendar.format(date.addingTimeInterval(Double(zone.secondsFromGMT(for: date))))
    }

    private static func failure(_ reason: String) -> ProjectError { .invalid("ICS import: \(reason)") }

    private static func unfoldedLines(_ data: Data) throws -> [String] {
        guard !data.isEmpty, data.count <= maximumBytes, !data.contains(0) else {
            throw failure("file must be UTF-8 and at most 256 KiB")
        }
        var logical: [Data] = []
        let physical = data.split(separator: 10, omittingEmptySubsequences: false)
        guard physical.count <= 8192 else { throw failure("too many calendar lines") }
        for (index, bytes) in physical.enumerated() {
            let line = bytes.last == 13 ? bytes.dropLast() : bytes[...]
            guard line.count <= 8192, line.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else {
                throw failure("invalid or oversized calendar line")
            }
            if line.isEmpty, index == physical.count - 1 { continue }
            guard let first = line.first else { throw failure("empty calendar line") }
            if first == 32 || first == 9 {
                guard let last = logical.indices.last, logical[last].count + line.count - 1 <= 8192 else {
                    throw failure("invalid or oversized folded calendar line")
                }
                logical[last].append(contentsOf: line.dropFirst())
            } else {
                logical.append(Data(line))
            }
        }
        return try logical.map {
            guard let text = String(data: $0, encoding: .utf8) else { throw failure("invalid UTF-8 calendar line") }
            return text
        }
    }

    private struct Property {
        let name: String
        let parameters: [String: String]
        let value: String

        init(_ line: String) throws {
            var quoted = false
            var headFields: [Substring] = []
            var start = line.startIndex
            var delimiter: String.Index?
            for i in line.indices {
                if line[i] == "\"" { quoted.toggle() }
                if !quoted && (line[i] == ":" || line[i] == ";") {
                    headFields.append(line[start..<i])
                    start = line.index(after: i)
                    if line[i] == ":" { delimiter = i; break }
                }
            }
            guard delimiter != nil, let head = headFields.first, !head.isEmpty,
                  head.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                throw failure("malformed calendar property")
            }
            name = head.uppercased()
            value = String(line[start...])
            var parsed: [String: String] = [:]
            for field in headFields.dropFirst() {
                let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw failure("malformed calendar parameter") }
                let key = parts[0].uppercased()
                let raw = parts[1]
                let unquoted = raw.first == "\"" && raw.last == "\"" ? raw.dropFirst().dropLast() : raw
                guard !unquoted.isEmpty, !unquoted.contains("\""), parsed.updateValue(String(unquoted), forKey: key) == nil else {
                    throw failure("invalid or duplicate calendar parameter")
                }
            }
            parameters = parsed
        }
    }

    private struct Event {
        var properties: [String: Property] = [:]
        var exclusions: [Property] = []

        mutating func add(_ property: Property) throws {
            switch property.name {
            case "UID", "SUMMARY", "DTSTART", "RRULE", "STATUS":
                guard properties.updateValue(property, forKey: property.name) == nil else {
                    throw failure("duplicate event property \(property.name)")
                }
            case "EXDATE":
                guard exclusions.count < 256 else { throw failure("too many recurrence exclusions") }
                exclusions.append(property)
            case "RDATE", "EXRULE", "RECURRENCE-ID":
                throw failure("unsupported recurrence property \(property.name)")
            default: break // End times and descriptive metadata do not trigger actions.
            }
        }

        func entry(cueID: UUID, floatingZone: String) throws -> ShowScheduleEntry {
            guard let uid = properties["UID"], uid.parameters.isEmpty, !uid.value.isEmpty,
                  let start = properties["DTSTART"] else { throw failure("each event requires UID and DTSTART") }
            if let status = properties["STATUS"], status.value.uppercased() != "CONFIRMED" {
                throw failure("only confirmed calendar events can trigger scenes")
            }
            let stamp = try datetime(start.value, parameters: start.parameters, floatingZone: floatingZone)
            let recurrence = try properties["RRULE"].map(recurrenceRule)
            var excluded = Set<Date>()
            for property in exclusions {
                for item in property.value.split(separator: ",", omittingEmptySubsequences: false) {
                    let exclusion = try datetime(String(item), parameters: property.parameters, floatingZone: stamp.zone)
                    let zone = try ScheduleCalendar.zone(exclusion.zone)
                    let wall = try ScheduleCalendar.parse(exclusion.local)
                    guard let instant = ScheduleCalendar.resolve(wall, zone: zone) else {
                        throw failure("EXDATE is in a skipped local time")
                    }
                    excluded.insert(instant)
                    guard excluded.count <= 256 else { throw failure("too many recurrence exclusions") }
                }
            }
            let name = try properties["SUMMARY"].map { try calendarText($0.value) } ?? "Calendar event"
            return ShowScheduleEntry(name: name.isEmpty ? "Calendar event" : name, cueID: cueID,
                                     localStart: stamp.local, timeZoneID: stamp.zone, recurrence: recurrence,
                                     excludedStarts: excluded.sorted(), sourceUID: uid.value)
        }
    }

    private static func datetime(_ value: String, parameters: [String: String], floatingZone: String) throws -> (local: String, zone: String) {
        guard parameters.keys.allSatisfy({ $0 == "TZID" || $0 == "VALUE" }),
              parameters["VALUE"].map({ $0.uppercased() == "DATE-TIME" }) ?? true else {
            throw failure("only date-time events with explicit TZID, UTC, or the selected floating zone are supported")
        }
        let stamp = value.uppercased()
        if stamp.hasSuffix("Z") {
            guard parameters["TZID"] == nil else { throw failure("UTC event cannot also specify TZID") }
            return (String(stamp.dropLast()), "UTC")
        }
        return (stamp, parameters["TZID"] ?? floatingZone)
    }

    private static func recurrenceRule(_ property: Property) throws -> ShowScheduleRecurrence {
        guard property.parameters.isEmpty else { throw failure("RRULE parameters are unsupported") }
        var parts: [String: String] = [:]
        let supported = Set(["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "WKST"])
        for piece in property.value.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[1].isEmpty else { throw failure("malformed RRULE") }
            let name = pair[0].uppercased()
            guard supported.contains(name), parts.updateValue(pair[1].uppercased(), forKey: name) == nil else {
                throw failure("unsupported or duplicate RRULE field \(name)")
            }
        }
        guard let raw = parts["FREQ"], let frequency = ShowScheduleFrequency(rawValue: raw.lowercased()),
              parts["WKST"].map({ $0 == "MO" }) ?? true else {
            throw failure("RRULE supports DAILY/WEEKLY and Monday week starts")
        }
        func integer(_ value: String) throws -> Int {
            guard value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value) else {
                throw failure("invalid RRULE integer")
            }
            return number
        }
        let interval = try parts["INTERVAL"].map(integer) ?? 1
        let count = try parts["COUNT"].map(integer)
        let until = try parts["UNTIL"].map { value -> Date in
            guard value.hasSuffix("Z") else { throw failure("RRULE UNTIL requires UTC with the Z suffix") }
            return try ScheduleCalendar.parse(String(value.dropLast()))
        }
        let weekdays = try parts["BYDAY"].map { value in
            try value.split(separator: ",", omittingEmptySubsequences: false).map { day -> ShowScheduleWeekday in
                guard let weekday = ShowScheduleWeekday(rawValue: String(day)) else {
                    throw failure("BYDAY requires non-ordinal weekday names")
                }
                return weekday
            }
        } ?? []
        return ShowScheduleRecurrence(frequency: frequency, interval: interval, count: count, until: until, weekdays: weekdays)
    }

    private static func calendarText(_ value: String) throws -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n", "N": result.append(" ")
                case ",", ";", "\\": result.append(character)
                default: throw failure("invalid SUMMARY text escape")
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        guard !escaped else { throw failure("incomplete SUMMARY text escape") }
        return result
    }
}
