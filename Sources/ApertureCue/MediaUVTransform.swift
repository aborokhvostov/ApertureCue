#if os(macOS)
import CoreGraphics
import MappingCore

/// Upright media coordinates to encoded texture coordinates. Surface crop/mask
/// stay in upright source space; only the final texture lookup is transformed.
struct MediaUVTransform:Equatable,Sendable {
    var x=SIMD4<Float>(1,0,0,0)
    var y=SIMD4<Float>(0,1,0,0)
    static let identity=MediaUVTransform()
    static func video(_ transform:CGAffineTransform,size:CGSize,pixelWidth:Int,pixelHeight:Int)throws->MediaUVTransform {
        let values=[transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty,size.width,size.height]
        guard values.allSatisfy(\.isFinite),size.width>0,size.height>0,pixelWidth>0,pixelHeight>0,
              abs(transform.a*transform.d-transform.b*transform.c)>1e-12 else {throw ProjectError.invalid("invalid video presentation transform")}
        let bounds=CGRect(origin:.zero,size:size).applying(transform).standardized
        guard bounds.width>0,bounds.height>0 else {throw ProjectError.invalid("empty video presentation bounds")}
        let inverse=transform.inverted()
        func point(_ u:CGFloat,_ v:CGFloat)->CGPoint {
            CGPoint(x:bounds.minX+u*bounds.width,y:bounds.minY+v*bounds.height).applying(inverse)
        }
        let p=point(0,0),a=point(1,0),b=point(0,1)
        return MediaUVTransform(x:SIMD4(Float((a.x-p.x)/CGFloat(pixelWidth)),Float((b.x-p.x)/CGFloat(pixelWidth)),Float(p.x/CGFloat(pixelWidth)),0),
                                y:SIMD4(Float((a.y-p.y)/CGFloat(pixelHeight)),Float((b.y-p.y)/CGFloat(pixelHeight)),Float(p.y/CGFloat(pixelHeight)),0))
    }
}
#endif
