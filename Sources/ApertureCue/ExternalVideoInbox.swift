#if os(macOS)
import Darwin
import Foundation
import MappingCore

/// Same-user, local-only frame inbox. Writers publish by atomic replacement.
enum ExternalVideoInbox {
    static let suffix = ".acframe"
    static let prefix = "ApertureCue-video-"
    static let markerName = ".aperturecue-video-v1"

    static func create() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try Data("ApertureCue video inbox v1\n".utf8)
                .write(to: root.appendingPathComponent(markerName), options: .withoutOverwriting)
            return root
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    static func verifyProducerDirectory(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let temporary = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let directory = try fm.attributesOfItem(atPath: root.path)
        guard root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix(prefix),
              directory[.type] as? FileAttributeType == .typeDirectory,
              (directory[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (directory[.posixPermissions] as? NSNumber)?.uint16Value == 0o700,
              let marker = try read(root.appendingPathComponent(markerName), maximumBytes: 64),
              marker.bytes == Data("ApertureCue video inbox v1\n".utf8) else {
            throw SystemFailure(message: "Choose an active private ApertureCue video inbox")
        }
        return root
    }

    static func publish(_ frame: ExternalVideoFrame, name: String, in root: URL) throws {
        guard ExternalVideoFrame.isValidName(name) else { throw ProjectError.invalid("Invalid feed name") }
        try frame.serialized().write(to: root.appendingPathComponent(name + suffix), options: .atomic)
    }

    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let seconds: Int
        let nanos: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            seconds = info.st_mtimespec.tv_sec
            nanos = info.st_mtimespec.tv_nsec
        }
    }

    static func read(_ url: URL, maximumBytes: Int = ExternalVideoFrame.maximumFileBytes,
                     after last: Identity? = nil) throws -> (bytes: Data, identity: Identity)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), (1...Int64(maximumBytes)).contains(before.st_size) else { return nil }
        let identity = Identity(before)
        guard identity != last else { return nil }
        let count = Int(before.st_size)
        var data = Data(count: count)
        let consumed = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return offset }
                offset += n
            }
            return offset
        }
        var after = stat()
        guard consumed == count, fstat(fd, &after) == 0, identity == Identity(after),
              after.st_size == before.st_size else { return nil }
        return (data, identity)
    }

    static func names(in root: URL) -> [String] {
        let directory = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        var found: Set<String> = []
        for _ in 0..<256 {
            guard let url = directory?.nextObject() as? URL else { break }
            let file = url.lastPathComponent
            guard file.hasSuffix(suffix) else { continue }
            let name = String(file.dropLast(suffix.count))
            if ExternalVideoFrame.isValidName(name) { found.insert(name) }
            if found.count == 64 { break }
        }
        return found.sorted()
    }
}

final class ExternalVideoWorker {
    struct Frame {
        let frame: ExternalVideoFrame
        let arrivedAt: Double
    }

    struct Snapshot {
        var names: [String] = []
        var frames: [String: Frame] = [:]
    }

    private struct Stream {
        var order = ExternalFrameOrder()
        var identity: ExternalVideoInbox.Identity?
        var frame: Frame?
    }

    private let root: URL
    private let queue = DispatchQueue(label: "org.aperturecue.external-video")
    private let lock = NSLock()
    private var result = Snapshot()
    private var timer: DispatchSourceTimer?
    private var streams: [String: Stream] = [:]
    private var lastDiscovery = -Double.infinity

    init(root: URL) {
        self.root = root
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    func observe(_ names: Set<String>) {
        queue.async { [weak self] in
            guard let self, timer != nil else { return }
            let selected = Set(names.sorted().prefix(4))
            streams = streams.filter { selected.contains($0.key) }
            for name in selected where streams[name] == nil { streams[name] = Stream() }
        }
    }

    func snapshot() -> Snapshot { lock.withLock { result } }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            streams.removeAll()
            lock.withLock { result = Snapshot() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func poll() {
        guard timer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let names: [String]?
        if now - lastDiscovery >= 0.25 {
            names = ExternalVideoInbox.names(in: root)
            lastDiscovery = now
        } else {
            names = nil
        }
        var next: [String: Frame] = [:]
        for name in Array(streams.keys) {
            guard var stream = streams[name] else { continue }
            let url = root.appendingPathComponent(name + ExternalVideoInbox.suffix)
            if let read = try? ExternalVideoInbox.read(url, after: stream.identity) {
                stream.identity = read.identity
                let writtenAt = Double(read.identity.seconds) + Double(read.identity.nanos) / 1_000_000_000
                let age = Date().timeIntervalSince1970 - writtenAt
                if (-0.25...1.0).contains(age),
                   let frame = try? ExternalVideoFrame(serialized: read.bytes), stream.order.admit(frame, at: now) {
                    stream.frame = Frame(frame: frame, arrivedAt: now)
                }
            }
            if !stream.order.isFresh(at: now) { stream.frame = nil }
            next[name] = stream.frame
            streams[name] = stream
        }
        lock.withLock {
            if let names { result.names = names }
            result.frames = next
        }
    }
}
#endif
