#if os(macOS)
import Foundation
import MappingCore

/// Bounds requested intermediate/color/buffer payloads across all in-flight
/// compositor commands. Driver overhead and source decoder buffering are separate.
final class CompositionGPUBudget:@unchecked Sendable {
    static let shared=CompositionGPUBudget()
    private let lock=NSLock()
    private var used=0
    private let maximum=256*1024*1024
    final class Lease:@unchecked Sendable {
        let bytes:Int
        private let budget:CompositionGPUBudget
        init(_ bytes:Int,_ budget:CompositionGPUBudget){self.bytes=bytes;self.budget=budget}
        deinit {budget.release(bytes)}
    }
    func reserve(_ bytes:Int) throws -> Lease {
        lock.lock();defer {lock.unlock()}
        guard bytes>=0,bytes<=maximum-used else {throw ProjectError.invalid("composition GPU payload budget is busy; lower resolution or isolated groups")}
        used+=bytes;return Lease(bytes,self)
    }
    private func release(_ bytes:Int){lock.lock();used-=bytes;lock.unlock()}
}
final class CompositionGPULeases:@unchecked Sendable {
    var tokens:[CompositionGPUBudget.Lease]=[]
    func reserve(_ bytes:Int) throws {tokens.append(try CompositionGPUBudget.shared.reserve(bytes))}
}
#endif
