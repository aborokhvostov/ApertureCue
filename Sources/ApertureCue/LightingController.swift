#if os(macOS)
import AppKit
import Darwin
import MappingCore

/// Explicit unicast output. Only the newest sampled frame may be in flight.
@MainActor final class LightingController {
    enum WireProtocol:String { case artnet = "Art-Net", sacn = "sACN" }
    var fixtures:[Fixture] = []
    var isSampling = false
    var isSending = false
    private(set) var lastUniverses:[Int:[UInt8]] = [:]
    private(set) var errorDescription = ""
    var destination = "127.0.0.1"
    var wireProtocol:WireProtocol = .artnet
    private var sequences:[String:UInt8] = [:]
    private let cid = UUID()
    private var samplerBusy = false
    private var senderBusy = false
    private var generation:UInt64 = 0
    private let queue = DispatchQueue(label:"org.aperturecue.lighting",qos:.userInitiated)
    private var simulator:NSWindow?
    private var swatches:FixturePreview?
    var renderer:MetalRenderer!

    func update(surfaces:[Surface]) {
        guard isSampling, !samplerBusy, !fixtures.isEmpty else { return }
        samplerBusy = true; renderer.surfaces = surfaces
        let requestGeneration = generation, sampledFixtures = fixtures
        renderer.snapshotAsync(width:320,height:180) { [weak self] image in
            guard let self else { return }; self.samplerBusy = false
            guard self.isSampling, self.generation == requestGeneration else { return }
            guard let image,let data = image.bitmapData else { return }
            do {
                let universes = try FixtureSampler.sample(fixtures:sampledFixtures) { point in
                    let x = max(0,min(image.pixelsWide-1,Int(point.x*Double(image.pixelsWide))))
                    let y = max(0,min(image.pixelsHigh-1,Int(point.y*Double(image.pixelsHigh))))
                    let i = y*image.bytesPerRow+x*4
                    return RGBColor(Double(data[i])/255,Double(data[i+1])/255,Double(data[i+2])/255)
                }
                self.lastUniverses = universes; self.swatches?.universes = universes
                if self.isSending { try self.transmit(universes) }
            } catch { self.errorDescription = error.localizedDescription; self.isSending = false }
        }
    }
    func validateDestination() throws {
        var address = in_addr(); guard inet_pton(AF_INET,destination,&address) == 1 else { throw SystemFailure(message:"Enter a numeric IPv4 destination") }
    }
    func stop(completion:(()->Void)? = nil) {
        generation &+= 1; isSampling = false
        if isSending, !lastUniverses.isEmpty {
            let black = lastUniverses.mapValues { Array(repeating:UInt8(0),count:$0.count) }
            try? transmit(black,terminating:wireProtocol == .sacn,force:true)
        }
        isSending = false; lastUniverses = [:]; swatches?.universes = [:]
        if let completion { queue.async { DispatchQueue.main.async(execute:completion) } }
    }
    private func transmit(_ universes:[Int:[UInt8]],terminating:Bool = false,force:Bool = false) throws {
        guard !senderBusy || force else { return }; try validateDestination()
        var packets:[Data] = []
        func nextSequence(_ universe:Int) -> UInt8 {
            let key = wireProtocol.rawValue + ":" + String(universe), previous = sequences[wireProtocol.rawValue + ":" + String(universe)] ?? 0
            let next:UInt8 = wireProtocol == .artnet && previous == 255 ? 1 : previous &+ 1
            sequences[key] = next; return next
        }
        for universe in universes.keys.sorted() {
            let channels = universes[universe]!
            if wireProtocol == .artnet { packets.append(try ArtNetCodec.encode(ArtDMX(universe:universe,sequence:nextSequence(universe),channels:channels))) }
            else {
                packets.append(try SACNCodec.encode(SACNPacket(universe:universe,sequence:nextSequence(universe),sourceName:"ApertureCue",cid:cid,channels:channels)))
                if terminating { for _ in 0..<3 {
                    packets.append(try SACNCodec.encode(SACNPacket(universe:universe,sequence:nextSequence(universe),sourceName:"ApertureCue",cid:cid,channels:channels,options:0x40)))
                }
                }
            }
        }
        let target = destination, isArtNet = wireProtocol == .artnet, port:UInt16 = wireProtocol == .artnet ? 6454 : 5568
        senderBusy = true
        queue.async { [weak self] in
            let fd = socket(AF_INET,SOCK_DGRAM,0)
            var error:String?
            if fd >= 0 {
                defer { close(fd) }; var yes:Int32 = 1
                _ = fcntl(fd,F_SETFL,O_NONBLOCK)
                setsockopt(fd,SOL_SOCKET,SO_BROADCAST,&yes,socklen_t(MemoryLayout<Int32>.size))
                if isArtNet {
                    setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(fd,SOL_SOCKET,SO_REUSEPORT,&yes,socklen_t(MemoryLayout<Int32>.size))
                    var local = sockaddr_in(); local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); local.sin_family = sa_family_t(AF_INET); local.sin_port = UInt16(6454).bigEndian
                    let bound = withUnsafePointer(to:&local) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                    if bound != 0 { error = "Art-Net source port 6454 unavailable: \(String(cString:strerror(errno)))" }
                }
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
                inet_pton(AF_INET,target,&address.sin_addr)
                for data in packets where error == nil {
                    let count = data.withUnsafeBytes { b in withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { sendto(fd,b.baseAddress,data.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
                    if count != data.count { error = String(cString:strerror(errno)); break }
                }
            } else { error = "Cannot create lighting UDP socket" }
            DispatchQueue.main.async { self?.senderBusy = false; if let error { self?.errorDescription = error; self?.isSending = false } }
        }
    }
    func showSimulator() {
        if let simulator { simulator.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect:NSRect(x:100,y:100,width:760,height:300),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = "ApertureCue · LED simulator · No hardware verification"; w.isReleasedWhenClosed = false
        let preview = FixturePreview(); fill(preview,in:w.contentView!); preview.universes = lastUniverses
        simulator = w; swatches = preview; w.center(); w.makeKeyAndOrderFront(nil)
    }
}

final class FixturePreview:NSView {
    var universes:[Int:[UInt8]] = [:] { didSet { needsDisplay = true } }
    override var isFlipped:Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.setFill(); bounds.fill()
        var y:CGFloat = 12
        for universe in universes.keys.sorted() {
            ("Universe \(universe) · raw RGB channel triplets" as NSString).draw(at:NSPoint(x:12,y:y),withAttributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:12)])
            y += 24; let channels = universes[universe]!
            for i in stride(from:0,to:min(channels.count,180),by:3) {
                let cell = i/3, x = CGFloat(cell%30)*24+12, row = CGFloat(cell/30)*24
                let c = NSColor(calibratedRed:Double(channels[i])/255,green:Double(channels[i+1])/255,blue:Double(channels[i+2])/255,alpha:1)
                c.setFill(); NSBezierPath(roundedRect:NSRect(x:x,y:y+row,width:20,height:20),xRadius:3,yRadius:3).fill()
            }; y += 58
        }
    }
}
#endif
