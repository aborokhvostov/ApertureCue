import Foundation

/// A bounded command history. A drag is one commit, not one commit per pointer event.
public final class EditHistory {
    public struct Entry {
        public let before: Project
        public let after: Project
        public let label: String
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    public let capacity: Int
    public init(capacity: Int = 100) { self.capacity = max(1,capacity) }
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var undoLabel: String? { past.last?.label }
    public var redoLabel: String? { future.last?.label }
    public func commit(before: Project, after: Project, label: String) {
        guard before != after else { return }
        past.append(Entry(before:before, after:after, label:label))
        if past.count > capacity { past.removeFirst(past.count-capacity) }
        future.removeAll(keepingCapacity:true)
    }
    public func undo(current: Project) -> Project? {
        guard let entry = past.popLast() else { return nil }
        // Retain any external state changes made since the command in the redo snapshot.
        future.append(Entry(before:entry.before, after:current, label:entry.label))
        return entry.before
    }
    public func redo(current: Project) -> Project? {
        guard let entry = future.popLast() else { return nil }
        past.append(Entry(before:current, after:entry.after, label:entry.label))
        return entry.after
    }
    public func clear() { past.removeAll(); future.removeAll() }
}
