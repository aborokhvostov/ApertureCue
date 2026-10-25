#if os(macOS)
import Foundation
import AppKit
import AVFoundation
import CoreVideo
import MappingCore

enum DemoGenerator {
    static func generate(at directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let png = directory.appendingPathComponent("calibration.png"), mov = directory.appendingPathComponent("motion.mov")
        let width = 960, height = 540
        guard let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32),let pixels = image.bitmapData else { throw SystemFailure(message:"Demo image allocation") }
        for y in 0..<height { for x in 0..<width {
            let i = (y*width+x)*4, grid = x % 60 < 2 || y % 60 < 2, bright = (x/60+y/60)%2 == 0
            pixels[i] = grid ? 255 : UInt8(x*255/width); pixels[i+1] = grid ? 255 : UInt8(y*255/height); pixels[i+2] = grid ? 255 : (bright ? 140 : 40); pixels[i+3] = 255
        } }
        guard let data = image.representation(using:.png,properties:[:]) else { throw SystemFailure(message:"Demo image encoding") }; try data.write(to:png,options:.atomic)
        if !FileManager.default.fileExists(atPath:mov.path) { try makeMovie(at:mov) }
        var p = Project.demo()
        let a = MediaAsset(name:"Calibration grid",path:png.path,kind:"image")
        let v = MediaAsset(name:"Moving bars · H.264",path:mov.path,kind:"video")
        p.assets = [a,v]; p.surfaces[0].mediaID = a.id; p.surfaces[1].mediaID = v.id
        for i in p.cues.indices { for j in p.cues[i].surfaces.indices { p.cues[i].surfaces[j].mediaID = j == 0 ? a.id : v.id } }
        try ProjectStore.save(p,to:directory.appendingPathComponent("Demo.aperturecue.json"))
    }
    private static func makeMovie(at url:URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".encoding-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at:temporary) }
        let writer = try AVAssetWriter(outputURL:temporary,fileType:.mov)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:640,AVVideoHeightKey:360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:640,kCVPixelBufferHeightKey as String:360])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? SystemFailure(message:"Video writer unavailable") }; writer.startSession(atSourceTime:.zero)
        let deadline = Date().addingTimeInterval(30)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { guard Date() < deadline, writer.status == .writing else { throw writer.error ?? SystemFailure(message:"Demo encoder timeout") }; Thread.sleep(forTimeInterval:0.002) }
            var optional:CVPixelBuffer?; CVPixelBufferCreate(kCFAllocatorDefault,640,360,kCVPixelFormatType_32ARGB,nil,&optional)
            guard let pixel = optional else { throw SystemFailure(message:"Video buffer allocation") }
            CVPixelBufferLockBaseAddress(pixel,[])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<360 { for x in 0..<640 { let n = y*stride+x*4; let bright = ((x+frame*8)/60)%2 == 0; bytes[n] = 255; bytes[n+1] = bright ? 230 : 20; bytes[n+2] = UInt8(y*255/360); bytes[n+3] = UInt8((x+frame*3)%256) } }
            CVPixelBufferUnlockBaseAddress(pixel,[])
            guard adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else { throw writer.error ?? SystemFailure(message:"Video append failed") }
        }
        input.markAsFinished(); let semaphore = DispatchSemaphore(value:0); writer.finishWriting { semaphore.signal() }
        guard semaphore.wait(timeout:.now()+30) == .success, writer.status == .completed else { throw writer.error ?? SystemFailure(message:"Video completion failed") }
        try FileManager.default.moveItem(at:temporary,to:url)
    }
}
#endif
