#if os(macOS)
import AVFoundation
import CoreVideo
import CoreGraphics
import MappingCore

/// Main-thread leases can invalidate work, but AVAssetReader cancellation and
/// sample reads are serialized together on their reader queue.
final class MontageDecodeLease:@unchecked Sendable {
    private let lock=NSLock()
    private var value:UInt64=0
    func advance()->UInt64 {lock.lock();defer {lock.unlock()};value &+= 1;return value}
    func matches(_ generation:UInt64)->Bool {lock.lock();defer {lock.unlock()};return value==generation}
}
struct MontageVideoEpoch:Equatable,Sendable {
    let document:UUID
    let assetRevision:UUID
    let url:URL
    let clip:MontageClip
    let montageCycle:Int
    let clipCycle:Int
}
struct MontageDecodeRequest:Sendable {
    let epoch:MontageVideoEpoch
    let time:Double
    let generation:UInt64
    let lease:MontageDecodeLease
}
final class MontageDecodedFrame:@unchecked Sendable {
    let buffer:CVPixelBuffer
    let pts:Double
    let end:Double
    let allowLag:Bool
    let transform:CGAffineTransform
    let naturalSize:CGSize
    init(buffer:CVPixelBuffer,pts:Double,end:Double,allowLag:Bool,transform:CGAffineTransform,naturalSize:CGSize) {
        self.buffer=buffer;self.pts=pts;self.end=end;self.allowLag=allowLag;self.transform=transform;self.naturalSize=naturalSize
    }
}
struct MontageDecodeResult:Sendable {
    var frame:MontageDecodedFrame?
    var videoStart=0.0
    var videoEnd=0.0
    var message=""
    var needsMore=false
}

/// Async metadata remains on an actor. Blocking reader operations run on a
/// dedicated serial Dispatch queue, leaving Swift's cooperative executor free.
actor MontageVideoDecoder {
    private let worker=MontageVideoReader()
    private var epoch:MontageVideoEpoch?
    func clear() async {epoch=nil;await worker.clear()}
    func decode(_ request:MontageDecodeRequest) async->MontageDecodeResult {
        guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
        do {
            if epoch != request.epoch {
                await clear()
                guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
                let source=AVURLAsset(url:request.epoch.url,options:[AVURLAssetPreferPreciseDurationAndTimingKey:true])
                let tracks=try await source.loadTracks(withMediaType:.video)
                guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
                guard let video=tracks.first else {throw ProjectError.invalid("clip source has no video track")}
                let range=try await video.load(.timeRange)
                guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
                let matrix=try await video.load(.preferredTransform)
                guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
                let size=try await video.load(.naturalSize)
                guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
                let start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
                guard start.isFinite,end.isFinite,start>=0,end>start,size.width.isFinite,size.height.isFinite,
                      size.width>0,size.height>0,size.width<=8192,size.height<=8192,size.width*size.height<=16777216 else {
                    throw ProjectError.invalid("unsupported video extent or dimensions (maximum 16 megapixels)")
                }
                let duration=try await source.load(.duration)
                guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
                guard duration.isNumeric,duration.seconds.isFinite,duration.seconds>0 else {throw ProjectError.invalid("invalid asset duration")}
                await worker.configure(MontageVideoMetadata(asset:source,track:video,start:start,end:end,transform:matrix,size:size))
                guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
                epoch=request.epoch
            }
            let result=await worker.decode(request)
            guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
            return result
        } catch {await clear();return MontageDecodeResult(message:"Montage video: "+error.localizedDescription)}
    }
}

/// Loaded immutable metadata is handed to one serial reader owner.
private struct MontageVideoMetadata:@unchecked Sendable {
    let asset:AVURLAsset
    let track:AVAssetTrack
    let start:Double,end:Double
    let transform:CGAffineTransform
    let size:CGSize
}
private final class MontageVideoReader:@unchecked Sendable {
    private let queue=DispatchQueue(label:"org.aperturecue.montage-reader",qos:.userInitiated)
    private let state=State()
    func configure(_ metadata:MontageVideoMetadata) async {
        await withCheckedContinuation {continuation in queue.async {self.state.configure(metadata);continuation.resume()}}
    }
    func clear() async {
        await withCheckedContinuation {continuation in queue.async {self.state.clear();continuation.resume()}}
    }
    func decode(_ request:MontageDecodeRequest) async->MontageDecodeResult {
        await withCheckedContinuation {continuation in queue.async {continuation.resume(returning:self.state.decode(request))}}
    }
    /// Only the owning queue reads or cancels this state.
    private final class State {
        private struct Sample {
            let buffer:CVPixelBuffer
            let pts:Double
            let duration:Double?
        }
        private var asset:AVURLAsset?
        private var track:AVAssetTrack?
        private var reader:AVAssetReader?
        private var output:AVAssetReaderTrackOutput?
        private var videoStart=0.0,videoEnd=0.0
        private var transform=CGAffineTransform.identity,naturalSize=CGSize.zero
        private var past:Sample?,future:Sample?
        private var eof=false,seekStart=0.0,preroll=1.0

        func clear() {
            reader?.cancelReading();reader=nil;output=nil;asset=nil;track=nil;past=nil;future=nil;eof=false
        }
        func configure(_ metadata:MontageVideoMetadata) {
            clear();asset=metadata.asset;track=metadata.track;videoStart=metadata.start;videoEnd=metadata.end
            transform=metadata.transform;naturalSize=metadata.size;preroll=1
        }
        func decode(_ request:MontageDecodeRequest)->MontageDecodeResult {
            guard request.lease.matches(request.generation) else {return MontageDecodeResult()}
            do {
                guard request.epoch.clip.sourceOut<=videoEnd+1e-6 else {return result(message:"Source Out exceeds actual video extent")}
                let target=request.time
                guard target>=videoStart,target<videoEnd else {return result(message:"No video sample at the requested source time")}
                if reader==nil || target<(past?.pts ?? seekStart)-1e-9 || target>(future?.pts ?? past?.pts ?? seekStart)+0.75 {
                    preroll=1;try startReader(at:max(videoStart,target-preroll))
                }
                var budget=64,retries=0
                while budget>0 {
                    guard request.lease.matches(request.generation) else {clear();return MontageDecodeResult()}
                    if future==nil && !eof {future=try nextSample();budget-=1}
                    if let next=future,next.pts<=target+1e-9 {
                        past=next;future=nil;continue
                    }
                    if past==nil,let next=future,next.pts>target,seekStart>videoStart+1e-9 {
                        // A fixed preroll can omit the covering frame in low-FPS/VFR
                        // media. Expand backwards until a predecessor or track start.
                        preroll *= 2;retries+=1
                        guard retries<=32 else {throw ProjectError.invalid("video predecessor search exceeded its budget")}
                        try startReader(at:max(videoStart,target-preroll));continue
                    }
                    guard let sample=past else {return result(message:"Video begins after the requested source time")}
                    let nextPTS=future?.pts
                    let explicitEnd=sample.duration.map {sample.pts+$0}
                    let end=min(videoEnd,explicitEnd ?? nextPTS ?? videoEnd,nextPTS ?? videoEnd)
                    guard end>target,end>sample.pts else {return result(message:"Video sample gap at the requested source time")}
                    let adjacent=nextPTS.map {abs($0-end)<1e-6} ?? false
                    return result(frame:MontageDecodedFrame(buffer:sample.buffer,pts:sample.pts,end:end,allowLag:adjacent,transform:transform,naturalSize:naturalSize))
                }
                return result(message:"Decoding clip frames",needsMore:true)
            } catch {clear();return MontageDecodeResult(message:"Montage video: "+error.localizedDescription)}
        }
        private func result(frame:MontageDecodedFrame?=nil,message:String="",needsMore:Bool=false)->MontageDecodeResult {
            MontageDecodeResult(frame:frame,videoStart:videoStart,videoEnd:videoEnd,message:message,needsMore:needsMore)
        }
        private func startReader(at start:Double)throws {
            guard let asset,let track else {throw ProjectError.invalid("video metadata is not ready")}
            reader?.cancelReading()
            let next=try AVAssetReader(asset:asset)
            let trackOutput=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                                                                              kCVPixelBufferMetalCompatibilityKey as String:true])
            trackOutput.alwaysCopiesSampleData=false
            guard next.canAdd(trackOutput) else {throw ProjectError.invalid("video reader cannot add its decoded output")}
            next.add(trackOutput)
            next.timeRange=CMTimeRange(start:CMTime(seconds:start,preferredTimescale:60000),end:CMTime(seconds:videoEnd,preferredTimescale:60000))
            guard next.startReading() else {throw next.error ?? ProjectError.invalid("video reader failed to start")}
            reader=next;output=trackOutput;past=nil;future=nil;eof=false;seekStart=start
        }
        private func nextSample()throws->Sample? {
            guard let output,let reader else {throw ProjectError.invalid("missing montage reader")}
            guard let sample=output.copyNextSampleBuffer() else {
                if reader.status == .failed {throw reader.error ?? ProjectError.invalid("video sample decode failed")}
                if reader.status == .cancelled {throw ProjectError.invalid("video reader cancelled")}
                eof=true;return nil
            }
            let time=CMSampleBufferGetPresentationTimeStamp(sample),length=CMSampleBufferGetDuration(sample)
            guard time.isValid,time.isNumeric,time.seconds.isFinite,time.seconds>=0,
                  let buffer=CMSampleBufferGetImageBuffer(sample) else {throw ProjectError.invalid("video sample has no finite presentation timestamp or image")}
            let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer)
            guard width>0,height>0,width<=8192,height<=8192,CVPixelBufferGetBytesPerRow(buffer)*height<=67108864 else {
                throw ProjectError.invalid("decoded clip frame exceeds its memory budget")
            }
            let duration=length.isValid && length.isNumeric && length.seconds.isFinite && length.seconds>0 ? length.seconds : nil
            return Sample(buffer:buffer,pts:time.seconds,duration:duration)
        }
    }
}
#endif
