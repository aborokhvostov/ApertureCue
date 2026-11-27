import Foundation

public enum ShowScheduleFrequency: String, Codable, CaseIterable, Sendable {
    case daily, weekly
}

public enum ShowScheduleWeekday: String, Codable, CaseIterable, Sendable {
    case mo = "MO", tu = "TU", we = "WE", th = "TH", fr = "FR", sa = "SA", su = "SU"

    fileprivate var mondayIndex: Int {
        switch self {
        case .mo: return 0
        case .tu: return 1
        case .we: return 2
        case .th: return 3
        case .fr: return 4
        case .sa: return 5
        case .su: return 6
        }
    }
}

public struct ShowScheduleRecurrence: Codable, Equatable, Sendable {
    public var frequency: ShowScheduleFrequency
    public var interval: Int
    public var count: Int?
    public var until: Date?
    public var weekdays: [ShowScheduleWeekday]

    public init(frequency: ShowScheduleFrequency, interval: Int = 1, count: Int? = nil,
                until: Date? = nil, weekdays: [ShowScheduleWeekday] = []) {
        self.frequency = frequency
        self.interval = interval
        self.count = count
        self.until = until
        self.weekdays = weekdays
    }
}

public struct ShowScheduleEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var cueID: UUID
    /// Basic local date-time, `YYYYMMDDTHHMMSS`, with a separate explicit zone.
    public var localStart: String
    public var timeZoneID: String
    public var recurrence: ShowScheduleRecurrence?
    public var excludedStarts: [Date]
    public var sourceUID: String?

    public init(id: UUID = UUID(), name: String, cueID: UUID, localStart: String,
                timeZoneID: String, recurrence: ShowScheduleRecurrence? = nil,
                excludedStarts: [Date] = [], sourceUID: String? = nil) {
        self.id = id
        self.name = name
        self.cueID = cueID
        self.localStart = localStart
        self.timeZoneID = timeZoneID
        self.recurrence = recurrence
        self.excludedStarts = excludedStarts
        self.sourceUID = sourceUID
    }

    public func startDate() throws -> Date {
        let wall = try ScheduleCalendar.parse(localStart)
        let zone = try ScheduleCalendar.zone(timeZoneID)
        guard let result = ScheduleCalendar.resolve(wall, zone: zone) else {
            throw ProjectError.invalid("schedule start is in a skipped local time")
        }
        return result
    }
}

public struct ShowSchedule: Codable, Equatable, Sendable {
    public static let maximumEntries = 128
    public var entries: [ShowScheduleEntry]

    public init(entries: [ShowScheduleEntry] = []) { self.entries = entries }

    public func validate(cueIDs: Set<UUID>) throws {
        guard entries.count <= Self.maximumEntries, Set(entries.map(\.id)).count == entries.count else {
            throw ProjectError.invalid("schedule requires unique IDs and at most 128 entries")
        }
        var sourceIDs = Set<String>()
        for entry in entries {
            guard cueIDs.contains(entry.cueID), !entry.name.isEmpty, entry.name.utf8.count <= 256 else {
                throw ProjectError.invalid("each schedule entry requires a name and a saved scene")
            }
            if let uid = entry.sourceUID {
                guard !uid.isEmpty, uid.utf8.count <= 512, sourceIDs.insert(uid).inserted else {
                    throw ProjectError.invalid("schedule calendar UIDs must be unique and at most 512 bytes")
                }
            }
            try ScheduleRule.validate(entry)
        }
    }
}

/// UTC-linear civil arithmetic keeps recurrence at a fixed local clock time.
/// The UTC-like civil timestamp is separate from each resolved UTC instant.
enum ScheduleCalendar {
    static let day = 86_400.0
    static let earliest = Date(timeIntervalSince1970: 0)
    static let end = Date(timeIntervalSince1970: 7_258_118_400) // 2200-01-01 UTC
    static let supportedAbsolute = earliest.addingTimeInterval(-2 * day)..<end.addingTimeInterval(2 * day)
    static let utc: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()

    static func zone(_ identifier: String) throws -> TimeZone {
        guard identifier.utf8.count <= 128, let zone = TimeZone(identifier: identifier) else {
            throw ProjectError.invalid("unknown schedule time zone")
        }
        return zone
    }

    static func parse(_ text: String) throws -> Date {
        let bytes = Array(text.utf8)
        let failure = ProjectError.invalid("expected a valid local date-time in YYYYMMDDTHHMMSS form, 1970–2199")
        guard bytes.count == 15, bytes[8] == 84,
              bytes.indices.allSatisfy({ $0 == 8 || (48...57).contains(bytes[$0]) }) else { throw failure }
        func digits(_ bounds: Range<Int>) -> Int {
            bytes[bounds].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        let parts = DateComponents(year: digits(0..<4), month: digits(4..<6), day: digits(6..<8),
                                   hour: digits(9..<11), minute: digits(11..<13), second: digits(13..<15))
        guard let date = utc.date(from: parts), (earliest..<end).contains(date) else { throw failure }
        let checked = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard checked == parts else { throw failure }
        return date
    }

    static func format(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d", parts.year ?? 0, parts.month ?? 0,
                      parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    static func resolve(_ wall: Date, zone: TimeZone) -> Date? {
        // Try the offsets immediately before and after the civil day, then
        // round-trip each candidate. A repeated wall time picks its first instant.
        let probes = [-2 * day, 0, 2 * day]
        return Set(probes.map { zone.secondsFromGMT(for: wall.addingTimeInterval($0)) }).compactMap { offset -> Date? in
            let candidate = wall.addingTimeInterval(-Double(offset))
            return zone.secondsFromGMT(for: candidate) == offset ? candidate : nil
        }.min()
    }

    static func dayNumber(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / day)) }
    static func weekday(_ date: Date) -> Int { (utc.component(.weekday, from: date) + 5) % 7 }
}

private struct ScheduleRule {
    let entry: ShowScheduleEntry
    let start: Date
    let wall: Date
    let zone: TimeZone
    let exclusions: Set<Date>
    let anchorWeekday: Int
    let days: [Int]
    let finiteStarts: [Date]?

    static func validate(_ entry: ShowScheduleEntry) throws {
        let start = try entry.startDate()
        guard entry.excludedStarts.count <= 256, Set(entry.excludedStarts).count == entry.excludedStarts.count,
              entry.excludedStarts.allSatisfy({ ScheduleCalendar.supportedAbsolute.contains($0) }) else {
            throw ProjectError.invalid("schedule exclusions require at most 256 unique supported start times")
        }
        guard let repeatRule = entry.recurrence else { return }
        guard (1...52).contains(repeatRule.interval), (repeatRule.count.map { (1...512).contains($0) } ?? true),
              repeatRule.count == nil || repeatRule.until == nil,
              Set(repeatRule.weekdays).count == repeatRule.weekdays.count,
              repeatRule.frequency == .weekly || repeatRule.weekdays.isEmpty else {
            throw ProjectError.invalid("schedule recurrence requires DAILY/WEEKLY, interval 1–52, and COUNT 1–512 or UNTIL")
        }
        if let until = repeatRule.until, !ScheduleCalendar.supportedAbsolute.contains(until) || until < start {
            throw ProjectError.invalid("schedule recurrence end must be within the supported range and at or after its start")
        }
        if !repeatRule.weekdays.isEmpty {
            let weekday = ScheduleCalendar.weekday(try ScheduleCalendar.parse(entry.localStart))
            guard repeatRule.weekdays.contains(where: { $0.mondayIndex == weekday }) else {
                throw ProjectError.invalid("weekly BYDAY must include the start weekday")
            }
        }
    }

    init(_ entry: ShowScheduleEntry) throws {
        self.entry = entry
        start = try entry.startDate()
        wall = try ScheduleCalendar.parse(entry.localStart)
        zone = try ScheduleCalendar.zone(entry.timeZoneID)
        let excluded = Set(entry.excludedStarts)
        exclusions = excluded
        let weekday = ScheduleCalendar.weekday(wall)
        anchorWeekday = weekday
        if let recurrence = entry.recurrence, !recurrence.weekdays.isEmpty {
            days = recurrence.weekdays.map(\.mondayIndex).sorted()
        } else {
            days = [weekday]
        }
        if let rule = entry.recurrence, let count = rule.count {
            finiteStarts = Self.firstStarts(count, rule: rule, wall: wall, zone: zone, weekday: weekday, days: days)
                .filter { !excluded.contains($0) }
        } else {
            finiteStarts = nil
        }
    }

    private static func firstStarts(_ count: Int, rule: ShowScheduleRecurrence, wall: Date, zone: TimeZone,
                                    weekday: Int, days: [Int]) -> [Date] {
        var result: [Date] = []
        // Fixed upper bound, including missing days during time-zone transitions.
        for period in 0..<(count + 512) {
            let offsets = rule.frequency == .daily
                ? [period * rule.interval]
                : days.map { period * rule.interval * 7 + $0 - weekday }
            for offset in offsets where offset >= 0 {
                let candidateWall = wall.addingTimeInterval(Double(offset) * ScheduleCalendar.day)
                if candidateWall >= ScheduleCalendar.end { return result }
                guard let candidate = ScheduleCalendar.resolve(candidateWall, zone: zone) else { continue }
                result.append(candidate)
                if result.count == count { return result }
            }
        }
        return result
    }

    func latest(after lower: Date, through upper: Date) -> Date? {
        if let dates = finiteStarts {
            var left = 0
            var right = dates.count
            while left < right {
                let middle = (left + right) / 2
                if dates[middle] <= upper { left = middle + 1 } else { right = middle }
            }
            return left > 0 && dates[left - 1] > lower ? dates[left - 1] : nil
        }
        guard let rule = entry.recurrence else {
            return start > lower && start <= upper && !exclusions.contains(start) ? start : nil
        }
        guard upper >= start, ScheduleCalendar.supportedAbsolute.contains(upper) else { return nil }
        let localUpper = upper.addingTimeInterval(Double(zone.secondsFromGMT(for: upper)))
        let upperOffset = ScheduleCalendar.dayNumber(localUpper) - ScheduleCalendar.dayNumber(wall)
        // The poll window is at most 30 seconds. Neighboring civil days also
        // cover a midnight crossing and time-zone transitions across midnight.
        var latest: Date?
        for offset in max(0, upperOffset - 2)...max(0, upperOffset + 2) {
            if rule.frequency == .daily {
                guard offset % rule.interval == 0 else { continue }
            } else {
                let weekdayOffset = anchorWeekday + offset
                guard (weekdayOffset / 7) % rule.interval == 0, days.contains(weekdayOffset % 7) else { continue }
            }
            let candidateWall = wall.addingTimeInterval(Double(offset) * ScheduleCalendar.day)
            guard candidateWall < ScheduleCalendar.end,
                  let candidate = ScheduleCalendar.resolve(candidateWall, zone: zone),
                  candidate > lower, candidate <= upper, candidate >= start,
                  rule.until.map({ candidate <= $0 }) ?? true, !exclusions.contains(candidate) else { continue }
            latest = max(latest ?? candidate, candidate)
        }
        return latest
    }
}

public struct ShowScheduleTrigger: Equatable, Sendable {
    public let entryID: UUID
    public let cueID: UUID
    public let time: Date
}

/// Explicitly armed, forward-only calendar crossings. A clock step or edit
/// cannot replay an instant already passed in this open document session.
public final class ShowScheduleRuntime {
    public static let graceSeconds = 30.0
    public private(set) var isArmed = false
    private var highWater: Date?
    private var schedule = ShowSchedule()
    private var rules: [ScheduleRule] = []

    public init() {}

    public func isConfigured(for schedule: ShowSchedule) -> Bool { self.schedule == schedule }

    public func arm(_ schedule: ShowSchedule, cueIDs: Set<UUID>, at time: Date) throws {
        try configure(schedule, cueIDs: cueIDs, at: time)
        highWater = max(highWater ?? time, time)
        isArmed = true
    }

    public func configure(_ newSchedule: ShowSchedule, cueIDs: Set<UUID>, at time: Date) throws {
        guard ScheduleCalendar.supportedAbsolute.contains(time) else {
            throw ProjectError.invalid("schedule clock date is outside the supported range")
        }
        if newSchedule == schedule {
            guard newSchedule.entries.allSatisfy({ cueIDs.contains($0.cueID) }) else {
                throw ProjectError.invalid("schedule references a missing scene")
            }
            return
        }
        try newSchedule.validate(cueIDs: cueIDs)
        let compiled = try newSchedule.entries.map(ScheduleRule.init)
        rules = compiled
        schedule = newSchedule
        highWater = max(highWater ?? time, time)
    }

    public func disarm() { isArmed = false }

    public func reset() {
        disarm()
        highWater = nil
        schedule = ShowSchedule()
        rules = []
    }

    public func poll(at time: Date) -> ShowScheduleTrigger? {
        guard isArmed, ScheduleCalendar.supportedAbsolute.contains(time), let previous = highWater, time > previous else { return nil }
        highWater = time
        guard floor(time.timeIntervalSinceReferenceDate) > floor(previous.timeIntervalSinceReferenceDate) else { return nil }
        let cutoff = time.timeIntervalSinceReferenceDate - Self.graceSeconds
        let lower = max(previous, Date(timeIntervalSinceReferenceDate: cutoff.nextDown))
        var selected: ShowScheduleTrigger?
        // On a delayed poll, use the latest due start. For equal times the first
        // schedule entry owns that instant, so simultaneous recalls are explicit.
        for rule in rules {
            guard let date = rule.latest(after: lower, through: time), selected.map({ date > $0.time }) ?? true else { continue }
            selected = ShowScheduleTrigger(entryID: rule.entry.id, cueID: rule.entry.cueID, time: date)
        }
        return selected
    }
}
