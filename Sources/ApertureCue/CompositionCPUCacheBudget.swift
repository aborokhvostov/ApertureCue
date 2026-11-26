#if os(macOS)
import Foundation
import MappingCore

/// Requested retained CPU cache payloads, shared by editor, output and feedback
/// renderers. Transient preparation arrays, allocator capacity and driver/GPU
/// allocations have separate lifetimes and are not represented as resident RAM.
final class CompositionCPUCacheBudget: @unchecked Sendable {
    static let shared=CompositionCPUCacheBudget(maximumBytes:64*1024*1024)
    let maximumBytes:Int
    private let lock=NSLock()
    private var used=0
    var usedBytes:Int {lock.lock();defer {lock.unlock()};return used}

    final class Lease: @unchecked Sendable {
        let bytes:Int
        private let budget:CompositionCPUCacheBudget
        fileprivate init(bytes:Int,budget:CompositionCPUCacheBudget) {self.bytes=bytes;self.budget=budget}
        deinit {budget.release(bytes)}
    }

    init(maximumBytes:Int) {self.maximumBytes=max(0,maximumBytes)}
    func reserve(_ bytes:Int) -> Lease? {
        lock.lock();defer {lock.unlock()}
        guard bytes>=0,bytes<=maximumBytes-used else {return nil}
        used+=bytes;return Lease(bytes:bytes,budget:self)
    }
    private func release(_ bytes:Int) {lock.lock();used-=bytes;lock.unlock()}
}

/// Small main-thread LRU. The entry owns both value and shared-budget lease, so
/// eviction releases the cached arrays before their payload is available again.
/// Refusing an insertion only loses reuse; the caller retains its prepared value
/// for the current frame. No successful render depends on cache admission.
final class CompositionCPUCache<Value> {
    private struct Entry {let value:Value;let lease:CompositionCPUCacheBudget.Lease}
    private var entries:[UUID:Entry]=[:]
    private var order:[UUID]=[]
    private let budget:CompositionCPUCacheBudget
    let maximumBytes:Int
    let maximumEntries:Int
    private(set) var usedBytes=0
    var count:Int {entries.count}
    init(maximumBytes:Int,maximumEntries:Int=256,budget:CompositionCPUCacheBudget = .shared) {
        self.maximumBytes=max(0,maximumBytes);self.maximumEntries=max(0,maximumEntries);self.budget=budget
    }
    subscript(_ key:UUID) -> Value? {
        guard let entry=entries[key] else {return nil}
        touch(key);return entry.value
    }
    @discardableResult func insert(_ value:Value,for key:UUID,bytes:Int) -> Bool {
        remove(key)
        guard bytes>=0,bytes<=maximumBytes,maximumEntries>0 else {return false}
        while usedBytes>maximumBytes-bytes || entries.count>=maximumEntries {
            guard evictOldest() else {return false}
        }
        var lease=budget.reserve(bytes)
        while lease==nil,evictOldest() {lease=budget.reserve(bytes)}
        guard let lease else {return false}
        entries[key]=Entry(value:value,lease:lease);order.append(key);usedBytes+=bytes;return true
    }
    func retain(keys:Set<UUID>) {
        for key in Array(entries.keys) where !keys.contains(key) {remove(key)}
    }
    func removeAll() {entries.removeAll();order.removeAll();usedBytes=0}
    private func touch(_ key:UUID) {order.removeAll {$0==key};order.append(key)}
    private func remove(_ key:UUID) {
        if let entry=entries.removeValue(forKey:key) {usedBytes-=entry.lease.bytes}
        order.removeAll {$0==key}
    }
    @discardableResult private func evictOldest() -> Bool {
        guard let key=order.first else {return false};remove(key);return true
    }
}

enum CompositionCPUCachePayload {
    /// Charge retained model collections too: a cached old surface can otherwise
    /// keep a previous document generation's control/mask arrays alive via COW.
    static func surface(_ s:Surface) -> Int {
        let pointCount=s.input.count+s.output.count+s.mask.count+s.inputMesh.count+s.mesh.count+s.triangleVertices.count
        var bytes=MemoryLayout<Surface>.stride+pointCount*MemoryLayout<Point2>.stride
        bytes+=(s.color.count+s.meshWeights.count+s.effects.keyColor.count)*MemoryLayout<Double>.stride
        bytes+=s.stroke.nodes.count*MemoryLayout<StrokeNode>.stride
        bytes+=(s.bezierWarp?.controls.count ?? 0)*MemoryLayout<Point2>.stride
        bytes+=(s.inputWarp?.controls.count ?? 0)*MemoryLayout<Point2>.stride
        bytes+=s.name.utf8.count+s.blendMode.utf8.count+s.group.utf8.count+s.generator.utf8.count
        for (name,values) in s.materialValues {bytes+=64+name.utf8.count+values.count*MemoryLayout<Double>.stride}
        for mask in s.masks {
            bytes+=MemoryLayout<CompositionMask>.stride+mask.name.utf8.count+mask.points.count*MemoryLayout<Point2>.stride
            bytes+=(mask.curve?.nodes.count ?? 0)*MemoryLayout<StrokeNode>.stride
        }
        return bytes
    }
}
#endif
