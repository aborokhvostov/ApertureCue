import Foundation

public struct ConductorCell: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var duration: Double
    public var loops: Bool
    public var tracks: [AutomationTrack]

    public init(id: UUID = UUID(), name: String, duration: Double, loops: Bool = false, tracks: [AutomationTrack]) {
        self.id = id
        self.name = name
        self.duration = duration
        self.loops = loops
        self.tracks = tracks
    }
}

public struct ConductorRow: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var cells: [ConductorCell]

    public init(id: UUID = UUID(), name: String, cells: [ConductorCell] = []) {
        self.id = id
        self.name = name
        self.cells = cells
    }
}

public struct ConductorBank: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rows: [ConductorRow]

    public init(id: UUID = UUID(), name: String, rows: [ConductorRow] = []) {
        self.id = id
        self.name = name
        self.rows = rows
    }
}

public enum ShowSignalKind: String, Codable, CaseIterable, Sendable {
    case sine, triangle, square, add, multiply
    var inputCount: Int { self == .add || self == .multiply ? 2 : 0 }
}

public struct ShowSignal: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ShowSignalKind
    public var frequency: Double
    public var phase: Double
    public var inputs: [UUID]

    public init(id: UUID = UUID(), name: String, kind: ShowSignalKind, frequency: Double = 1,
                phase: Double = 0, inputs: [UUID] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.frequency = frequency
        self.phase = phase
        self.inputs = inputs
    }
}

public struct ShowSignalBinding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var signalID: UUID
    public var surfaceID: UUID
    public var parameter: String
    public var minimum: Double
    public var maximum: Double

    public init(id: UUID = UUID(), signalID: UUID, surfaceID: UUID, parameter: String,
                minimum: Double, maximum: Double) {
        self.id = id
        self.signalID = signalID
        self.surfaceID = surfaceID
        self.parameter = parameter
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct Conductor: Codable, Equatable, Sendable {
    public var banks: [ConductorBank]
    public var signals: [ShowSignal]
    public var bindings: [ShowSignalBinding]

    public init(banks: [ConductorBank] = [], signals: [ShowSignal] = [], bindings: [ShowSignalBinding] = []) {
        self.banks = banks
        self.signals = signals
        self.bindings = bindings
    }

    public func validate(surfaces: [Surface]) throws {
        guard banks.count <= 16, Set(banks.map(\.id)).count == banks.count,
              signals.count <= 64, bindings.count <= 128,
              Set(bindings.map(\.id)).count == bindings.count else {
            throw ProjectError.invalid("Conductor bank or signal capacity exceeded, or duplicate ID")
        }
        var rowIDs = Set<UUID>()
        var cellIDs = Set<UUID>()
        var totalKeys = 0
        for bank in banks {
            guard Self.validName(bank.name), bank.rows.count <= 8 else {
                throw ProjectError.invalid("Conductor banks need a name and may contain up to eight rows")
            }
            for row in bank.rows {
                guard rowIDs.insert(row.id).inserted, Self.validName(row.name), row.cells.count <= 8 else {
                    throw ProjectError.invalid("Conductor rows need a unique ID, name and at most eight cells")
                }
                for cell in row.cells {
                    guard cellIDs.insert(cell.id).inserted, Self.validName(cell.name),
                          cell.duration.isFinite, (0.001...ShowRuntime.maximumTime).contains(cell.duration),
                          cell.tracks.count <= 64 else {
                        throw ProjectError.invalid("Invalid Conductor cell ID, name, duration or track count")
                    }
                    for track in cell.tracks {
                        totalKeys += track.keyframes.count
                        guard totalKeys <= 65536, track.keyframes.allSatisfy({ $0.time <= cell.duration }) else {
                            throw ProjectError.invalid("Conductor key budget exceeded or a key lies past its cell duration")
                        }
                    }
                    try TimelineEngine.validate(tracks: cell.tracks, surfaces: surfaces)
                }
            }
        }
        _ = try SignalProgram(signals)
        let signalIDs = Set(signals.map(\.id))
        let surfaceIDs = Set(surfaces.map(\.id))
        var targets: [UUID: Set<String>] = [:]
        for binding in bindings {
            guard let range = try? TimelineEngine.parameterRange(binding.parameter),
                  signalIDs.contains(binding.signalID), surfaceIDs.contains(binding.surfaceID),
                  range.contains(binding.minimum), range.contains(binding.maximum),
                  binding.minimum <= binding.maximum,
                  targets[binding.surfaceID, default: []].insert(binding.parameter).inserted else {
                throw ProjectError.invalid("Invalid or duplicate signal output binding")
            }
        }
    }

    public mutating func pruneTargets(_ surfaceIDs: Set<UUID>) {
        bindings.removeAll { !surfaceIDs.contains($0.surfaceID) }
        for bank in banks.indices {
            for row in banks[bank].rows.indices {
                for cell in banks[bank].rows[row].cells.indices {
                    banks[bank].rows[row].cells[cell].tracks.removeAll { !surfaceIDs.contains($0.surfaceID) }
                }
            }
        }
    }

    fileprivate static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 128
    }
}

private struct SignalProgram {
    private var ordered: [ShowSignal] = []

    init(_ signals: [ShowSignal]) throws {
        let ids = Set(signals.map(\.id))
        guard ids.count == signals.count, signals.allSatisfy({
            Conductor.validName($0.name) && $0.frequency.isFinite && (0...30).contains($0.frequency)
                && $0.phase.isFinite && (0...1).contains($0.phase)
                && $0.inputs.count == $0.kind.inputCount && $0.inputs.allSatisfy(ids.contains)
        }) else { throw ProjectError.invalid("Invalid signal node or missing signal input") }

        var available = Set<UUID>()
        var pending = signals
        while !pending.isEmpty {
            let ready = pending.filter { $0.inputs.allSatisfy(available.contains) }
            guard !ready.isEmpty else { throw ProjectError.invalid("Signal graph contains a cycle") }
            ordered.append(contentsOf: ready)
            available.formUnion(ready.map(\.id))
            pending.removeAll { available.contains($0.id) }
        }
    }

    func values(at time: Double) -> [UUID: Double] {
        var result: [UUID: Double] = [:]
        for node in ordered {
            let cycle = (time * node.frequency + node.phase).truncatingRemainder(dividingBy: 1)
            let value: Double
            switch node.kind {
            case .sine: value = (sin(cycle * 2 * .pi) + 1) / 2
            case .triangle: value = 1 - abs(2 * cycle - 1)
            case .square: value = cycle < 0.5 ? 1 : 0
            case .add: value = min(1, result[node.inputs[0], default: 0] + result[node.inputs[1], default: 0])
            case .multiply: value = result[node.inputs[0], default: 0] * result[node.inputs[1], default: 0]
            }
            result[node.id] = value
        }
        return result
    }
}

/// Session-only. Each running row has its own host anchor. A later row wins
/// conflicts, with signal bindings applied before rows for consistent priority.
public final class ConductorRuntime {
    private struct Activation {
        let cell: ConductorCell
        let hostTime: Double
    }

    private var definition = Conductor()
    private var surfaceIDs = Set<UUID>()
    private var programs: [UUID: TimelineProgram] = [:]
    private var signalProgram = try! SignalProgram([])
    private var active: [UUID: Activation] = [:]
    public private(set) var bankID: UUID?
    public var activeCellIDs: Set<UUID> { Set(active.values.map { $0.cell.id }) }
    public var affectsRender: Bool { !active.isEmpty || !definition.bindings.isEmpty }

    public init() {}

    public func configure(_ next: Conductor, surfaces: [Surface]) throws {
        let ids = Set(surfaces.map(\.id))
        guard next != definition || ids != surfaceIDs else { return }
        try next.validate(surfaces: surfaces)
        var compiled: [UUID: TimelineProgram] = [:]
        for bank in next.banks {
            for row in bank.rows {
                for cell in row.cells {
                    compiled[cell.id] = try TimelineProgram(tracks: cell.tracks, surfaces: surfaces)
                }
            }
        }
        let signals = try SignalProgram(next.signals)
        definition = next
        surfaceIDs = ids
        programs = compiled
        signalProgram = signals
        if let bank = next.banks.first(where: { $0.id == bankID }) {
            let rows = Dictionary(uniqueKeysWithValues: bank.rows.map { ($0.id, $0) })
            active = active.filter { rowID, activation in
                rows[rowID]?.cells.contains(activation.cell) == true
            }
        } else {
            stopAll()
            bankID = nil
        }
    }

    public func launch(bankID: UUID, cellID: UUID, at time: Double) throws {
        guard time.isFinite, let bank = definition.banks.first(where: { $0.id == bankID }),
              let row = bank.rows.first(where: { $0.cells.contains(where: { $0.id == cellID }) }),
              let cell = row.cells.first(where: { $0.id == cellID }) else {
            throw ProjectError.invalid("Select an existing Conductor cell")
        }
        if self.bankID != bankID { stopAll(); self.bankID = bankID }
        if active[row.id]?.cell.id == cellID { return }
        active[row.id] = Activation(cell: cell, hostTime: time)
    }

    public func stop(rowID: UUID) { active.removeValue(forKey: rowID) }
    public func stopAll() { active.removeAll() }
    public func reset() {
        definition = Conductor()
        surfaceIDs.removeAll()
        programs.removeAll()
        signalProgram = try! SignalProgram([])
        bankID = nil
        stopAll()
    }

    public func apply(to surfaces: [Surface], hostTime: Double, showTime: Double) throws -> [Surface] {
        guard affectsRender, hostTime.isFinite, showTime.isFinite else { return surfaces }
        var result = surfaces
        if !definition.bindings.isEmpty {
            let values = signalProgram.values(at: min(ShowRuntime.maximumTime, max(0, showTime)))
            var indices: [UUID: Int] = [:]
            for index in surfaces.indices {
                guard indices.updateValue(index, forKey: surfaces[index].id) == nil else {
                    throw ProjectError.invalid("Duplicate signal surface ID")
                }
            }
            for binding in definition.bindings {
                guard let index = indices[binding.surfaceID], let input = values[binding.signalID] else { continue }
                let value = binding.minimum + (binding.maximum - binding.minimum) * input
                try TimelineProgram.set(value, parameter: binding.parameter, on: &result[index])
            }
        }
        if let bank = definition.banks.first(where: { $0.id == bankID }) {
            for row in bank.rows {
                guard let activation = active[row.id], let program = programs[activation.cell.id] else { continue }
                let elapsed = min(ShowRuntime.maximumTime, max(0, hostTime - activation.hostTime))
                let duration = activation.cell.duration
                let position = activation.cell.loops ? elapsed.truncatingRemainder(dividingBy: duration) : min(elapsed, duration)
                result = try program.apply(time: position, surfaces: result)
            }
        }
        return result
    }
}
