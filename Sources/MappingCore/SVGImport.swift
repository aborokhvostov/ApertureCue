import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum SVGFillRule:String,Codable,Sendable { case nonZero,evenOdd }
public struct SVGOpacityGroup:Codable,Equatable,Sendable {
    public var id:Int
    public var opacity:Double
}
public struct SVGPath: Codable,Equatable,Sendable {
    public var nodes:[StrokeNode]
    public var closed:Bool
    public init(nodes:[StrokeNode],closed:Bool) {self.nodes=nodes;self.closed=closed}
}
/// Subpaths remain grouped so nonzero/even-odd compound holes are not lost.
public struct SVGShape: Codable,Equatable,Sendable {
    public var name:String
    public var paths:[SVGPath]
    public var fill:[Double]?
    public var stroke:[Double]?
    public var strokeWidth:Double
    public var fillRule:SVGFillRule
    public var lineCap:String
    public var lineJoin:String
    public var miterLimit:Double
    public var opacityGroups:[SVGOpacityGroup] = []
}
public struct SVGDocument: Codable,Equatable,Sendable {
    /// min-x, min-y, width, height; path coordinates below are normalized.
    public var viewBox:[Double]
    public var shapes:[SVGShape]
}

public enum SVGImport {
    public static let maximumBytes=1024*1024
    public static func validate(_ document:SVGDocument) throws {
        guard document.viewBox.count==4,document.viewBox.allSatisfy({$0.isFinite && abs($0)<=1e7}),
              document.viewBox[2]>=1e-9,document.viewBox[3]>=1e-9,(1...256).contains(document.shapes.count) else {
            throw ProjectError.invalid("invalid SVG document geometry")
        }
        var total=0,groupOpacity:[Int:Double]=[:]
        for shape in document.shapes {
            guard shape.name.utf8.count<=4096,(1...32).contains(shape.paths.count),
                  shape.strokeWidth.isFinite,(0...10000).contains(shape.strokeWidth),
                  shape.miterLimit.isFinite,(1...1000).contains(shape.miterLimit),
                  ["butt","round","square"].contains(shape.lineCap),["miter","round","bevel"].contains(shape.lineJoin) else {
                throw ProjectError.invalid("invalid SVG paint or path budget")
            }
            for color in [shape.fill,shape.stroke] {if let color {
                guard color.count==4,color.allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw ProjectError.invalid("invalid SVG color")}
            }}
            guard shape.opacityGroups.count<=32,Set(shape.opacityGroups.map(\.id)).count==shape.opacityGroups.count else {throw ProjectError.invalid("invalid SVG opacity group nesting")}
            for group in shape.opacityGroups {
                guard group.id>0,group.opacity.isFinite,(0...1).contains(group.opacity),groupOpacity[group.id]==nil || groupOpacity[group.id]==group.opacity else {throw ProjectError.invalid("invalid SVG group opacity")}
                groupOpacity[group.id]=group.opacity
            }
            for path in shape.paths {
                total+=path.nodes.count
                guard (1...128).contains(path.nodes.count),total<=8192,path.nodes.allSatisfy({node in
                    [node.anchor,node.incoming,node.outgoing].allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=10000 && abs($0.y)<=10000})
                }) else {throw ProjectError.invalid("invalid SVG path coordinates or budget")}
            }
        }
    }
    public static func parse(_ data:Data) throws -> SVGDocument {
        guard data.count<=maximumBytes,let source=String(data:data,encoding:.utf8),!source.contains("\0") else {
            throw ProjectError.invalid("SVG must be UTF-8 and no larger than 1 MiB")
        }
        let lower=source.lowercased()
        guard !lower.contains("<!doctype"),!lower.contains("<!entity") else {
            throw ProjectError.invalid("SVG DTDs and entity declarations are unsupported")
        }
        let delegate=SVGImportDelegate()
        let parser=XMLParser(data:data); parser.delegate=delegate
        parser.shouldProcessNamespaces=true; parser.shouldResolveExternalEntities=false
        let parsed=parser.parse()
        if let error=delegate.failure {throw error}
        guard parsed,delegate.rootSeen,delegate.frames.isEmpty,let box=delegate.box else {
            throw ProjectError.invalid("malformed SVG XML")
        }
        guard !delegate.shapes.isEmpty else {throw ProjectError.invalid("SVG contains no supported visible paths")}
        let document=SVGDocument(viewBox:box,shapes:delegate.shapes)
        try validate(document);return document
    }
}

private enum SVGNumberToken { case command(Character),number(Double) }
private enum SVGNumbers {
    static func tokens(_ string:String,commands:Bool) throws -> [SVGNumberToken] {
        let bytes=Array(string.utf8); var i=0,result:[SVGNumberToken]=[],canComma=false
        func whitespace(_ b:UInt8)->Bool {[9,10,13,32].contains(b)}
        func digit(_ b:UInt8)->Bool {(48...57).contains(b)}
        while i<bytes.count {
            if whitespace(bytes[i]) {i+=1;continue}
            if bytes[i]==44 {
                guard canComma else {throw ProjectError.invalid("malformed SVG comma separator")}
                i+=1;while i<bytes.count,whitespace(bytes[i]) {i+=1}
                guard i<bytes.count,bytes[i] != 44,!(65...90).contains(bytes[i]),!(97...122).contains(bytes[i]) else {
                    throw ProjectError.invalid("malformed SVG comma separator")
                }
                canComma=false;continue
            }
            if (65...90).contains(bytes[i]) || (97...122).contains(bytes[i]) {
                guard commands else {throw ProjectError.invalid("SVG number has unsupported units or syntax")}
                result.append(.command(Character(UnicodeScalar(Int(bytes[i]))!)));i+=1;canComma=false
            } else {
                let start=i
                if bytes[i]==43 || bytes[i]==45 {i+=1}
                var digits=0
                while i<bytes.count,digit(bytes[i]) {i+=1;digits+=1}
                if i<bytes.count,bytes[i]==46 {
                    i+=1;while i<bytes.count,digit(bytes[i]) {i+=1;digits+=1}
                }
                guard digits>0 else {throw ProjectError.invalid("invalid SVG numeric token")}
                if i<bytes.count,bytes[i]==101 || bytes[i]==69 {
                    i+=1;if i<bytes.count,bytes[i]==43 || bytes[i]==45 {i+=1}
                    let exponent=i;while i<bytes.count,digit(bytes[i]) {i+=1}
                    guard i>exponent else {throw ProjectError.invalid("invalid SVG exponent")}
                }
                guard let value=Double(String(decoding:bytes[start..<i],as:UTF8.self)),value.isFinite,abs(value)<=1e9 else {
                    throw ProjectError.invalid("SVG coordinate exceeds finite working range")
                }
                result.append(.number(value));canComma=true
            }
            guard result.count<=32768 else {throw ProjectError.invalid("too many SVG path tokens")}
        }
        return result
    }
    static func list(_ string:String) throws -> [Double] {
        try tokens(string,commands:false).map { token in
            guard case .number(let value)=token else {throw ProjectError.invalid("expected SVG number")};return value
        }
    }
    static func scalar(_ string:String) throws -> Double {
        var text=string.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasSuffix("px") {text=String(text.dropLast(2))}
        let values=try list(text)
        guard values.count==1 else {throw ProjectError.invalid("expected one SVG number")};return values[0]
    }
}

private struct SVGPathReader {
    var tokens:[SVGNumberToken]
    var index=0
    var nodes:[StrokeNode]=[]
    var paths:[SVGPath]=[]
    var current=Point2(0,0)
    mutating func read(_ count:Int) throws -> [Double] {
        guard index+count<=tokens.count else {throw ProjectError.invalid("incomplete SVG path command")}
        var result:[Double]=[]
        for _ in 0..<count {
            guard case .number(let n)=tokens[index] else {throw ProjectError.invalid("incomplete SVG path command")}
            result.append(n);index+=1
        }
        return result
    }
    mutating func finish(_ closed:Bool) throws {
        if closed,nodes.count>1,nodes.last!.anchor==nodes[0].anchor {
            nodes[0].incoming=nodes.last!.incoming;nodes.removeLast()
        }
        if nodes.count>=2 || (closed && nodes.contains(where:{$0.incoming != $0.anchor || $0.outgoing != $0.anchor})) {
            paths.append(SVGPath(nodes:nodes,closed:closed))
        }
        nodes=[]
    }
    mutating func line(_ point:Point2) throws {try curve(point,incoming:point,outgoing:current)}
    mutating func curve(_ point:Point2,incoming:Point2,outgoing:Point2) throws {
        guard !nodes.isEmpty else {throw ProjectError.invalid("SVG path must start with moveto")}
        nodes[nodes.count-1].outgoing=outgoing
        nodes.append(StrokeNode(anchor:point,incoming:incoming));current=point
        guard nodes.count<=128 else {throw ProjectError.invalid("SVG subpath exceeds 128 anchors")}
    }
    mutating func parse() throws -> [SVGPath] {
        var command:Character?
        while index<tokens.count {
            if case .command(let c)=tokens[index] {command=c;index+=1}
            guard let c=command else {throw ProjectError.invalid("SVG path requires a command")}
            let upper=Character(String(c).uppercased()),relative=String(c)==String(c).lowercased()
            func point(_ x:Double,_ y:Double)->Point2 {relative ? Point2(current.x+x,current.y+y) : Point2(x,y)}
            switch upper {
            case "M":
                let v=try read(2),p=point(v[0],v[1]);try finish(false)
                current=p;nodes=[StrokeNode(anchor:p)];command=relative ? "l" : "L"
            case "L":let v=try read(2);try line(point(v[0],v[1]))
            case "H":let v=try read(1);try line(Point2(relative ? current.x+v[0] : v[0],current.y))
            case "V":let v=try read(1);try line(Point2(current.x,relative ? current.y+v[0] : v[0]))
            case "C":
                let v=try read(6),a=point(v[0],v[1]),b=point(v[2],v[3]),p=point(v[4],v[5]);try curve(p,incoming:b,outgoing:a)
            case "Q":
                let v=try read(4),q=point(v[0],v[1]),p=point(v[2],v[3])
                try curve(p,incoming:Point2.interpolate(p,q,t:2.0/3.0),outgoing:Point2.interpolate(current,q,t:2.0/3.0))
            case "Z":
                guard let first=nodes.first else {throw ProjectError.invalid("closepath without moveto")}
                let start=first.anchor;try finish(true);current=start;command=nil
            default:throw ProjectError.invalid("unsupported SVG path command \(c); supported: M L H V C Q Z")
            }
            guard paths.count<=32 else {throw ProjectError.invalid("SVG shape exceeds 32 subpaths")}
        }
        try finish(false);return paths
    }
}

private struct SVGStyle {
    var fill:[Double]?=[0,0,0,1],stroke:[Double]?
    var width=1.0,fillOpacity=1.0,strokeOpacity=1.0,miter=4.0
    var rule:SVGFillRule = .nonZero
    var cap="butt",join="miter"
}
private struct SVGFrame {var name:String;var matrix:Affine2D;var style:SVGStyle;var textOnly:Bool;var opacityGroups:[SVGOpacityGroup]}

private final class SVGImportDelegate:NSObject,XMLParserDelegate {
    var frames:[SVGFrame]=[],box:[Double]?,shapes:[SVGShape]=[]
    var rootSeen=false,failure:Error?
    private var elementCount=0,totalNodes=0
    private func abort(_ parser:XMLParser,_ error:Error) {if failure==nil {failure=error};parser.abortParsing()}
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        do {try start(elementName,namespace:namespaceURI,attributes:attributes)} catch {abort(parser,error)}
    }
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName:String?) {
        guard frames.last?.name==elementName else {abort(parser,ProjectError.invalid("mismatched SVG element"));return}
        frames.removeLast()
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) {
        if frames.last?.textOnly != true,!string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            abort(parser,ProjectError.invalid("text content is unsupported outside SVG title/desc"))
        }
    }
    func parser(_ parser:XMLParser,foundCDATA CDATABlock:Data) {abort(parser,ProjectError.invalid("SVG CDATA is unsupported"))}
    func parser(_ parser:XMLParser,foundProcessingInstructionWithTarget target:String,data:String?) {abort(parser,ProjectError.invalid("SVG processing instructions are unsupported"))}
    func parser(_ parser:XMLParser,resolveExternalEntityName name:String,systemID:String?) -> Data? {abort(parser,ProjectError.invalid("external SVG entities are unsupported"));return nil}
    private func start(_ name:String,namespace:String?,attributes a:[String:String]) throws {
        guard namespace==nil || namespace=="" || namespace=="http://www.w3.org/2000/svg" else {throw ProjectError.invalid("foreign SVG namespaces are unsupported")}
        elementCount+=1
        guard elementCount<=4096,frames.count<32,a.count<=32 else {throw ProjectError.invalid("SVG element/depth budget exceeded")}
        let supported:Set<String>=["svg","g","path","rect","circle","ellipse","line","polyline","polygon","title","desc"]
        guard supported.contains(name),frames.last?.textOnly != true else {throw ProjectError.invalid("unsupported SVG element \(name)")}
        if frames.isEmpty {
            guard !rootSeen,name=="svg" else {throw ProjectError.invalid("SVG requires one root svg element")};rootSeen=true
            let values: [Double]
            if let view=a["viewBox"] {values=try SVGNumbers.list(view)}
            else {
                guard let width=a["width"],let height=a["height"] else {throw ProjectError.invalid("SVG requires viewBox or numeric width/height")}
                values=[0,0,try SVGNumbers.scalar(width),try SVGNumbers.scalar(height)]
            }
            guard values.count==4,values[2]>=1e-9,values[3]>=1e-9,values.allSatisfy({$0.isFinite && abs($0)<=1e7}) else {throw ProjectError.invalid("invalid SVG viewBox")}
            box=values
        } else {guard name != "svg",frames.last?.name=="svg" || frames.last?.name=="g" else {throw ProjectError.invalid("unsupported SVG nesting")}}
        let common:Set<String>=["id","transform","fill","stroke","stroke-width","opacity","fill-opacity","stroke-opacity","fill-rule","stroke-linecap","stroke-linejoin","stroke-miterlimit","xmlns","version"]
        let attributesByElement:[String:Set<String>]=["svg":["viewBox","width","height","preserveAspectRatio"],"g":[],"title":[],"desc":[],"path":["d"],"rect":["x","y","width","height"],"circle":["cx","cy","r"],"ellipse":["cx","cy","rx","ry"],"line":["x1","y1","x2","y2"],"polyline":["points"],"polygon":["points"]]
        guard a.keys.allSatisfy({common.contains($0) || attributesByElement[name,default:[]].contains($0)}) else {throw ProjectError.invalid("unsupported SVG attribute, CSS or external reference")}
        if let aspect=a["preserveAspectRatio"],aspect != "none",aspect != "xMidYMid meet" {throw ProjectError.invalid("unsupported preserveAspectRatio; geometry imports the viewBox directly")}
        var style=frames.last?.style ?? SVGStyle(),opacityGroups=frames.last?.opacityGroups ?? []
        if let fill=a["fill"] {style.fill=try color(fill)}
        if let stroke=a["stroke"] {style.stroke=try color(stroke)}
        if let width=a["stroke-width"] {style.width=try SVGNumbers.scalar(width);guard style.width>=0 else {throw ProjectError.invalid("negative SVG stroke width")}}
        for key in ["opacity","fill-opacity","stroke-opacity"] {if let text=a[key] {
            let value=try SVGNumbers.scalar(text);guard (0...1).contains(value) else {throw ProjectError.invalid("SVG opacity outside 0...1")}
            if key=="opacity" {
                if value != 1 {opacityGroups.append(SVGOpacityGroup(id:elementCount,opacity:value))}
            } else if key=="fill-opacity" {style.fillOpacity=value} else {style.strokeOpacity=value}
        }}
        if let rule=a["fill-rule"] {
            guard ["nonzero","evenodd"].contains(rule) else {throw ProjectError.invalid("unsupported SVG fill rule")};style.rule=rule=="evenodd" ? .evenOdd : .nonZero
        }
        if let cap=a["stroke-linecap"] {guard ["butt","round","square"].contains(cap) else {throw ProjectError.invalid("unsupported SVG linecap")};style.cap=cap}
        if let join=a["stroke-linejoin"] {guard ["miter","round","bevel"].contains(join) else {throw ProjectError.invalid("unsupported SVG linejoin")};style.join=join}
        if let miter=a["stroke-miterlimit"] {style.miter=try SVGNumbers.scalar(miter);guard (1...1000).contains(style.miter) else {throw ProjectError.invalid("invalid SVG miter limit")}}
        let local=try a["transform"].map(transform) ?? .identity
        let matrix=(frames.last?.matrix ?? .identity).concatenating(local)
        guard [matrix.a,matrix.b,matrix.c,matrix.d,matrix.tx,matrix.ty].allSatisfy({$0.isFinite && abs($0)<=1e9}) else {throw ProjectError.invalid("SVG transform exceeds working range")}
        frames.append(SVGFrame(name:name,matrix:matrix,style:style,textOnly:name=="title" || name=="desc",opacityGroups:opacityGroups))
        if ["svg","g","title","desc"].contains(name) {return}
        let paths=try geometry(name,attributes:a)
        guard !paths.isEmpty else {return}
        guard let box else {throw ProjectError.invalid("missing SVG viewBox")}
        func mapped(_ point:Point2) throws -> Point2 {
            let p=try matrix.applying(point),q=Point2((p.x-box[0])/box[2],(p.y-box[1])/box[3])
            guard q.x.isFinite,q.y.isFinite,abs(q.x)<=10000,abs(q.y)<=10000 else {throw ProjectError.invalid("SVG normalized coordinates exceed working range")};return q
        }
        let normalized=try paths.map { path in
            SVGPath(nodes:try path.nodes.map {node in try StrokeNode(anchor:mapped(node.anchor),incoming:mapped(node.incoming),outgoing:mapped(node.outgoing))},closed:path.closed)
        }
        totalNodes += normalized.reduce(0,{$0+$1.nodes.count})
        guard shapes.count<256,totalNodes<=8192 else {throw ProjectError.invalid("SVG exceeds 256 shapes or 8192 anchors")}
        let sx=hypot(matrix.a,matrix.b),sy=hypot(matrix.c,matrix.d)
        if style.stroke != nil,style.width>0 {
            guard sx>0,abs(sx-sy)<=1e-9*max(1,sx,sy),abs(matrix.a*matrix.c+matrix.b*matrix.d)<=1e-9*max(1,sx*sy) else {
                throw ProjectError.invalid("SVG stroked paths require a uniform transform; nonuniform fill transforms are supported")
            }
        }
        func paint(_ color:[Double]?,_ alpha:Double)->[Double]? {
            guard var color else {return nil};color[3] *= alpha;return color
        }
        let strokeWidth=style.width*sx/box[3]
        guard strokeWidth.isFinite,strokeWidth<=10000 else {throw ProjectError.invalid("SVG stroke width exceeds normalized working range")}
        shapes.append(SVGShape(name:a["id"] ?? name,paths:normalized,fill:paint(style.fill,style.fillOpacity),stroke:paint(style.stroke,style.strokeOpacity),
                               strokeWidth:strokeWidth,fillRule:style.rule,lineCap:style.cap,lineJoin:style.join,miterLimit:style.miter,opacityGroups:opacityGroups))
    }
    private func geometry(_ name:String,attributes a:[String:String]) throws -> [SVGPath] {
        func n(_ key:String,_ fallback:Double?=nil) throws -> Double {
            if let value=a[key] {return try SVGNumbers.scalar(value)}
            if let fallback {return fallback};throw ProjectError.invalid("SVG \(name) requires \(key)")
        }
        func linePath(_ points:[Point2],closed:Bool)->[SVGPath] {[SVGPath(nodes:points.map {StrokeNode(anchor:$0)},closed:closed)]}
        switch name {
        case "path":var reader=SVGPathReader(tokens:try SVGNumbers.tokens(a["d"] ?? "",commands:true));return try reader.parse()
        case "line":return linePath([Point2(try n("x1",0),try n("y1",0)),Point2(try n("x2",0),try n("y2",0))],closed:false)
        case "polyline","polygon":
            let values=try SVGNumbers.list(a["points"] ?? "")
            guard values.count%2==0,((name=="polygon" ? 6 : 4)...256).contains(values.count) else {throw ProjectError.invalid("SVG polygon/polyline requires 2...128 point pairs (3 when closed)")}
            return linePath(stride(from:0,to:values.count,by:2).map {Point2(values[$0],values[$0+1])},closed:name=="polygon")
        case "rect":
            let x=try n("x",0),y=try n("y",0),w=try n("width"),h=try n("height")
            guard w>=0,h>=0 else {throw ProjectError.invalid("negative SVG rectangle size")};if w==0 || h==0 {return []}
            return linePath([Point2(x,y),Point2(x+w,y),Point2(x+w,y+h),Point2(x,y+h)],closed:true)
        case "circle","ellipse":
            let x=try n("cx",0),y=try n("cy",0),rx=try n(name=="circle" ? "r" : "rx"),ry=try n(name=="circle" ? "r" : "ry")
            guard rx>=0,ry>=0 else {throw ProjectError.invalid("negative SVG radius")};if rx==0 || ry==0 {return []}
            let k=0.5522847498307936
            let nodes=[StrokeNode(anchor:Point2(x+rx,y),incoming:Point2(x+rx,y-k*ry),outgoing:Point2(x+rx,y+k*ry)),
                       StrokeNode(anchor:Point2(x,y+ry),incoming:Point2(x+k*rx,y+ry),outgoing:Point2(x-k*rx,y+ry)),
                       StrokeNode(anchor:Point2(x-rx,y),incoming:Point2(x-rx,y+k*ry),outgoing:Point2(x-rx,y-k*ry)),
                       StrokeNode(anchor:Point2(x,y-ry),incoming:Point2(x-k*rx,y-ry),outgoing:Point2(x+k*rx,y-ry))]
            return [SVGPath(nodes:nodes,closed:true)]
        default:return []
        }
    }
    private func color(_ text:String) throws -> [Double]? {
        if text=="none" {return nil}
        let names:[String:[Double]]=["black":[0,0,0,1],"white":[1,1,1,1],"red":[1,0,0,1],"green":[0,128.0/255,0,1],"blue":[0,0,1,1],"yellow":[1,1,0,1],"cyan":[0,1,1,1],"magenta":[1,0,1,1],"transparent":[0,0,0,0]]
        if let c=names[text] {return c}
        guard text.hasPrefix("#") else {throw ProjectError.invalid("SVG paint supports none, basic color names or hexadecimal colors")}
        let chars=Array(text.dropFirst());guard [3,4,6,8].contains(chars.count) else {throw ProjectError.invalid("invalid SVG hexadecimal paint")}
        var result:[Double]=[]
        if chars.count<=4 {
            for char in chars {guard let v=Int(String(char),radix:16) else {throw ProjectError.invalid("invalid SVG paint")};result.append(Double(v)/15)}
        } else {
            for i in stride(from:0,to:chars.count,by:2) {guard let v=Int(String(chars[i...i+1]),radix:16) else {throw ProjectError.invalid("invalid SVG paint")};result.append(Double(v)/255)}
        }
        if result.count==3 {result.append(1)};return result
    }
    private func transform(_ source:String) throws -> Affine2D {
        let bytes=Array(source.utf8);var i=0,result=Affine2D.identity,count=0
        func skip(){while i<bytes.count,[9,10,13,32].contains(bytes[i]) {i+=1}}
        while i<bytes.count {
            skip();if i==bytes.count {break}
            if bytes[i]==44 {
                guard count>0 else {throw ProjectError.invalid("leading SVG transform comma")}
                i+=1;skip();guard i<bytes.count,bytes[i] != 44 else {throw ProjectError.invalid("invalid SVG transform separator")}
            }
            let start=i;while i<bytes.count,(65...90).contains(bytes[i]) || (97...122).contains(bytes[i]) {i+=1}
            let name=String(decoding:bytes[start..<i],as:UTF8.self);skip()
            guard !name.isEmpty,i<bytes.count,bytes[i]==40 else {throw ProjectError.invalid("invalid SVG transform")};i+=1
            let arguments=i;while i<bytes.count,bytes[i] != 41 {i+=1}
            guard i<bytes.count else {throw ProjectError.invalid("unterminated SVG transform")}
            let v=try SVGNumbers.list(String(decoding:bytes[arguments..<i],as:UTF8.self));i+=1
            let next:Affine2D
            switch name {
            case "matrix":guard v.count==6 else {throw ProjectError.invalid("SVG matrix requires six numbers")};next=Affine2D(a:v[0],b:v[1],c:v[2],d:v[3],tx:v[4],ty:v[5])
            case "translate":guard (1...2).contains(v.count) else {throw ProjectError.invalid("invalid SVG translate")};next = .translation(x:v[0],y:v.count==2 ? v[1] : 0)
            case "scale":guard (1...2).contains(v.count) else {throw ProjectError.invalid("invalid SVG scale")};next=Affine2D(a:v[0],d:v.count==2 ? v[1] : v[0])
            case "rotate":guard v.count==1 || v.count==3 else {throw ProjectError.invalid("invalid SVG rotate")};next = .rotation(degrees:v[0],around:v.count==3 ? Point2(v[1],v[2]) : Point2(0,0))
            case "skewX","skewY":
                guard v.count==1,abs(v[0])<89 else {throw ProjectError.invalid("SVG skew must be within ±89 degrees")}
                let t=tan(v[0]*Double.pi/180);next=name=="skewX" ? Affine2D(c:t) : Affine2D(b:t)
            default:throw ProjectError.invalid("unsupported SVG transform \(name)")
            }
            result=result.concatenating(next);count+=1
            guard count<=32 else {throw ProjectError.invalid("too many SVG transforms")}
        }
        return result
    }
}
