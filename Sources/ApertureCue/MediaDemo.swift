#if os(macOS)
import AppKit
import MappingCore

/// Original, reproducible stage-3 media. A fresh folder is required; no existing
/// project/media is overwritten by this generator.
@MainActor enum MediaDemo {
    static func generate(at directory:URL)throws {
        let fm=FileManager.default
        guard !fm.fileExists(atPath:directory.path) else {throw ProjectError.invalid("media demo needs a new destination folder")}
        let parent=directory.deletingLastPathComponent()
        try fm.createDirectory(at:parent,withIntermediateDirectories:true)
        let staging=parent.appendingPathComponent(".media-demo-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:false)
        defer {try? fm.removeItem(at:staging)}
        let frames=staging.appendingPathComponent("Frames",isDirectory:true);try fm.createDirectory(at:frames,withIntermediateDirectories:false)
        let palette:[[UInt8]]=[[230,20,20],[20,230,20],[20,20,230],[230,230,20]]
        let names=["frame1.png","frame2.png","frame10.png","frame11.png"]
        for i in names.indices {
            guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:160,pixelsHigh:96,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bitmapFormat:.alphaNonpremultiplied,bytesPerRow:640,bitsPerPixel:32),let bytes=bitmap.bitmapData else {throw ProjectError.invalid("media demo bitmap unavailable")}
            for y in 0..<96 {for x in 0..<160 {
                let edge=x<4 || y<4 || x>=156 || y>=92
                for c in 0..<3 {bytes[y*640+x*4+c]=edge ? 255 : palette[i][c]};bytes[y*640+x*4+3]=255
            }}
            guard let data=bitmap.representation(using:.png,properties:[:]) else {throw ProjectError.invalid("media demo PNG encoding failed")}
            try data.write(to:frames.appendingPathComponent(names[i]))
        }
        let video=staging.appendingPathComponent("original-time-colors.mov")
        try MontageSelfTest.makeMovie(at:video,fps:30)
        let audio=staging.appendingPathComponent("original-stereo-tones.wav")
        try wave().write(to:audio)
        var sequence=MediaAsset(name:"01 · frozen numeric image sequence",path:frames.path,kind:"sequence",volume:0)
        sequence.sequence=MediaSequenceSettings(frames:names,fps:2)
        let forward=MediaAsset(name:"02 · ordinary H.264 transport",path:video.path,kind:"video",volume:0)
        var reverse=MediaAsset(name:"03 · reverse ping-pong trim",path:video.path,kind:"video",volume:0)
        reverse.playback=MediaPlaybackSettings(trimIn:0.25,trimOut:3.75,rate:-1,mode:.pingPong)
        let tone=MediaAsset(name:"04 · original stereo tones (unassigned, volume 0)",path:audio.path,kind:"audio",volume:0)
        let s0=Surface(name:"Sequence · 2 FPS / frozen gaps",mediaID:sequence.id,output:[Point2(0.05,0.1),Point2(0.47,0.1),Point2(0.47,0.46),Point2(0.05,0.46)])
        let s1=Surface(name:"Ordinary video · independent transport",mediaID:forward.id,output:[Point2(0.53,0.1),Point2(0.95,0.1),Point2(0.95,0.46),Point2(0.53,0.46)])
        let s2=Surface(name:"Reverse ping-pong video",mediaID:reverse.id,output:[Point2(0.28,0.55),Point2(0.72,0.55),Point2(0.72,0.94),Point2(0.28,0.94)])
        let project=Project(name:"ApertureCue Media · original playback demo",assets:[sequence,forward,reverse,tone],surfaces:[s0,s1,s2],outputs:[OutputConfig()])
        try ProjectStore.save(project,to:staging.appendingPathComponent("Media.aperturecue.json"))
        // The saved paths are relative to staging, so renaming the completed
        // package preserves every resource reference without relinking.
        try fm.moveItem(at:staging,to:directory)
    }
    static func wave()->Data {
        let rate=48000,count=rate*4,byteCount=count*4
        var data=Data()
        func text(_ s:String) {data.append(contentsOf:s.utf8)}
        func word(_ value:UInt16) {var v=value.littleEndian;withUnsafeBytes(of:&v) {data.append(contentsOf:$0)}}
        func integer(_ value:UInt32) {var v=value.littleEndian;withUnsafeBytes(of:&v) {data.append(contentsOf:$0)}}
        text("RIFF");integer(UInt32(36+byteCount));text("WAVEfmt ");integer(16);word(1);word(2);integer(UInt32(rate));integer(UInt32(rate*4));word(4);word(16);text("data");integer(UInt32(byteCount))
        for frame in 0..<count {
            for frequency in [220.0,330.0] {
                let sample=Int16((sin(2*Double.pi*frequency*Double(frame)/Double(rate))*0.15*32767).rounded())
                word(UInt16(bitPattern:sample))
            }
        }
        return data
    }
}
#endif
