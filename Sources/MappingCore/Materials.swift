import Foundation

public enum MaterialInputType: String, Codable, CaseIterable, Sendable {
    case float, bool, point2D, color
    public var componentCount: Int { self == .point2D ? 2 : (self == .color ? 4 : 1) }
}

public struct MaterialInput: Codable, Equatable, Sendable {
    public var name: String
    public var label: String
    public var kind: MaterialInputType
    public var defaultValue: [Double]
    public var minimum: [Double]
    public var maximum: [Double]
    public init(name: String, label: String = "", kind: MaterialInputType = .float,
                defaultValue: [Double] = [0.5], minimum: [Double] = [0], maximum: [Double] = [1]) {
        self.name=name; self.label=label; self.kind=kind; self.defaultValue=defaultValue
        self.minimum=minimum; self.maximum=maximum
    }
}

public struct MaterialDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// A single RGBA expression, not an unrestricted shader program.
    public var expression: String
    public var inputs: [MaterialInput]
    /// User-supplied attribution is retained; it is not a redistribution license.
    public var credit: String
    public init(id: UUID = UUID(), name: String = "Material", expression: String = "sample(uv)",
                inputs: [MaterialInput] = [], credit: String = "") {
        self.id=id; self.name=name; self.expression=expression; self.inputs=inputs; self.credit=credit
    }
}

/// Bounded expression compiler shared by the native material editor and declared
/// ISF subset. Generated MSL contains only compiler-owned operators/functions;
/// user identifiers are mapped to indexed float4 uniforms, never injected as code.
public struct MaterialProgram: Sendable {
    public static let maximumInputs=16
    public static let maximumExpressionBytes=4096
    public let definition: MaterialDefinition
    public let metalExpression: String
    private let root: MaterialNode
    public init(definition: MaterialDefinition) throws {
        try Self.validateDefinition(definition)
        var parser=try MaterialParser(definition:definition)
        let root=try parser.parse()
        guard root.width == 4 else { throw ProjectError.invalid("a material expression must produce vec4/RGBA") }
        let expression=root.metal()
        guard expression.utf8.count <= 32768 else { throw ProjectError.invalid("generated material expression budget exceeded") }
        self.definition=definition; self.root=root; self.metalExpression=expression
    }

    public static func validateDefinition(_ definition: MaterialDefinition) throws {
        guard definition.name.utf8.count <= 4096, definition.credit.utf8.count <= 4096,
              definition.expression.utf8.count <= maximumExpressionBytes,
              !definition.expression.isEmpty, definition.inputs.count <= maximumInputs else {
            throw ProjectError.invalid("material name, expression or input budget exceeded")
        }
        var names=Set<String>()
        for input in definition.inputs {
            let width=input.kind.componentCount
            guard validIdentifier(input.name), !reservedNames.contains(input.name), names.insert(input.name).inserted,
                  input.label.utf8.count <= 4096,
                  input.defaultValue.count == width, input.minimum.count == width, input.maximum.count == width else {
                throw ProjectError.invalid("invalid, reserved or duplicate material input name/type")
            }
            for i in 0..<width {
                let value=input.defaultValue[i], low=input.minimum[i], high=input.maximum[i]
                guard [value,low,high].allSatisfy({ $0.isFinite && abs($0) <= 1e6 }), low <= value, value <= high else {
                    throw ProjectError.invalid("material input defaults/ranges must be finite and ordered")
                }
                if input.kind == .bool, !(low == 0 && high == 1 && (value == 0 || value == 1)) {
                    throw ProjectError.invalid("Boolean material inputs use 0/1 and range 0...1")
                }
            }
        }
    }

    /// Unknown overrides and nonfinite/out-of-range values fail, rather than
    /// silently targeting another input. The returned array always has 16 rows.
    public func parameterVectors(values: [String:[Double]] = [:]) throws -> [[Double]] {
        let known=Set(definition.inputs.map(\.name))
        guard Set(values.keys).isSubset(of:known) else { throw ProjectError.invalid("unknown material parameter") }
        var result=Array(repeating:Array(repeating:0.0,count:4),count:Self.maximumInputs)
        for (index,input) in definition.inputs.enumerated() {
            let value=values[input.name] ?? input.defaultValue
            guard value.count == input.kind.componentCount else { throw ProjectError.invalid("material parameter component count changed") }
            for i in value.indices {
                guard value[i].isFinite, value[i] >= input.minimum[i], value[i] <= input.maximum[i],
                      input.kind != .bool || value[i] == 0 || value[i] == 1 else {
                    throw ProjectError.invalid("material parameter is outside its declared range")
                }
                result[index][i]=value[i]
            }
        }
        return result
    }

    /// uv and sample() use the application's y-down normalized source space.
    /// ISF aliases use y-up coordinates; isfSample converts back before lookup.
    public func evaluate(uv: Point2, time: Double = 0, renderSize: Point2 = Point2(1,1),
                         values: [String:[Double]] = [:], sample: @escaping (Point2) -> [Double] = { _ in [0,0,0,1] }) throws -> [Double] {
        guard uv.x.isFinite, uv.y.isFinite, time.isFinite, abs(time) <= 31536000,
              renderSize.x.isFinite,renderSize.y.isFinite,renderSize.x > 0,renderSize.y > 0,
              renderSize.x <= 16384,renderSize.y <= 16384 else { throw ProjectError.invalid("invalid material coordinates/time/size") }
        let vectors=try parameterVectors(values:values)
        let context=MaterialEvaluation(uv:uv,time:time,size:renderSize,parameters:vectors,sample:sample)
        let result=try root.evaluate(context)
        guard result.count == 4,result.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) else {
            throw ProjectError.invalid("material expression produced a nonfinite or overflowing value")
        }
        return result
    }

    public static let metalFunctions = """
    float apertureMaterialMod(float x,float y) { return x-y*floor(x/y); }
    float2 apertureMaterialMod(float2 x,float2 y) { return x-y*floor(x/y); }
    float3 apertureMaterialMod(float3 x,float3 y) { return x-y*floor(x/y); }
    float4 apertureMaterialMod(float4 x,float4 y) { return x-y*floor(x/y); }
    """

    static func validIdentifier(_ name: String) -> Bool {
        let bytes=Array(name.utf8)
        guard (1...64).contains(bytes.count), let first=bytes.first, asciiLetter(first) || first == 95 else { return false }
        return bytes.allSatisfy { asciiLetter($0) || (48...57).contains($0) || $0 == 95 }
    }
    static let functionNames:Set<String>=["vec2","vec3","vec4","sin","cos","abs","floor","ceil","fract","sqrt","min","max","clamp","mix","step","smoothstep","pow","mod","length","dot","sample","isfSample"]
    static let reservedNames=Set(["uv","time","size","pi","TIME","RENDERSIZE","isf_FragNormCoord","true","false"]).union(functionNames)
}

private func asciiLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
private func materialNumber(_ value: Double) -> String { String(value) }
private func materialBroadcast(_ values: [Double], _ width: Int) -> [Double] {
    values.count == 1 ? Array(repeating:values[0],count:width) : values
}
private struct MaterialEvaluation {
    var uv: Point2; var time: Double; var size: Point2; var parameters: [[Double]]
    var sample: (Point2) -> [Double]
}

private indirect enum MaterialNode: Sendable {
    case number(Double)
    case variable(String,Int,Int) // symbol, uniform index (-1 for builtin), width
    case unary(String,MaterialNode)
    case binary(String,MaterialNode,MaterialNode,Int)
    case call(String,[MaterialNode],Int)
    case swizzle(MaterialNode,[Int])
    var width: Int {
        switch self {
        case .number:return 1
        case .variable(_,_,let w),.binary(_,_,_,let w),.call(_,_,let w):return w
        case .unary(_,let x):return x.width
        case .swizzle(_,let components):return components.count
        }
    }
    func metal() -> String {
        switch self {
        case .number(let value):return materialNumber(value)
        case .variable(let name,let index,let width):
            if index >= 0 { return "materialParams[\(index)]" + (width == 1 ? ".x" : (width == 2 ? ".xy" : "")) }
            switch name {
            case "uv":return "materialUV"
            case "isf_FragNormCoord":return "float2(materialUV.x,1.0-materialUV.y)"
            case "time","TIME":return "materialTime"
            case "size","RENDERSIZE":return "materialSize"
            default:return "3.141592653589793"
            }
        case .unary(let op,let x):return "(\(op)(\(x.metal())))"
        case .binary(let op,let a,let b,_):return "((\(a.metal()))\(op)(\(b.metal())))"
        case .swizzle(let x,let indices):return "(\(x.metal()))."+indices.map { String(Array("xyzw")[$0]) }.joined()
        case .call(let name,let args,let width):
            let values=args.map { $0.metal() }
            if name.hasPrefix("vec") { return "float\(width)("+values.joined(separator:",")+")" }
            if name == "sample" { return "sampleMaterial(\(values[0]))" }
            if name == "isfSample" { return "sampleMaterialISF(\(values[0]))" }
            let arguments=args.enumerated().map { index,arg in
                width > 1 && arg.width == 1 ? "float\(width)(\(values[index]))" : values[index]
            }
            let function=name == "mod" ? "apertureMaterialMod" : name
            return function+"("+arguments.joined(separator:",")+")"
        }
    }
    func evaluate(_ context: MaterialEvaluation) throws -> [Double] {
        func finite(_ value: [Double]) throws -> [Double] {
            guard value.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) else { throw ProjectError.invalid("material arithmetic is nonfinite or overflows") }
            return value
        }
        switch self {
        case .number(let value):return [value]
        case .variable(let name,let index,let width):
            if index >= 0 { return Array(context.parameters[index].prefix(width)) }
            switch name {
            case "uv":return [context.uv.x,context.uv.y]
            case "isf_FragNormCoord":return [context.uv.x,1-context.uv.y]
            case "time","TIME":return [context.time]
            case "size","RENDERSIZE":return [context.size.x,context.size.y]
            default:return [Double.pi]
            }
        case .unary(let op,let x):let value=try x.evaluate(context);return op == "-" ? value.map { -$0 } : value
        case .swizzle(let x,let indices):let value=try x.evaluate(context);return indices.map { value[$0] }
        case .binary(let op,let x,let y,let width):
            let a=materialBroadcast(try x.evaluate(context),width),b=materialBroadcast(try y.evaluate(context),width)
            return try finite(zip(a,b).map { x,y in
                switch op { case "+":return x+y;case "-":return x-y;case "*":return x*y;default:return x/y }
            })
        case .call(let name,let nodes,let width):
            let args=try nodes.map { try $0.evaluate(context) }
            if name.hasPrefix("vec") {
                let flattened=args.flatMap { $0 }
                return flattened.count == 1 ? Array(repeating:flattened[0],count:width) : flattened
            }
            if name == "sample" || name == "isfSample" {
                let point=Point2(args[0][0],name == "sample" ? args[0][1] : 1-args[0][1])
                let sampled=context.sample(point)
                guard sampled.count == 4 else { throw ProjectError.invalid("material sampler must return RGBA") }
                return try finite(sampled)
            }
            if name == "length" { return try finite([sqrt(args[0].reduce(0) { $0+$1*$1 })]) }
            if name == "dot" { return try finite([zip(args[0],args[1]).reduce(0) { $0+$1.0*$1.1 }]) }
            let expanded=args.map { materialBroadcast($0,width) }
            var result:[Double]=[]
            for i in 0..<width {
                let a=expanded[0][i],b=expanded.count > 1 ? expanded[1][i] : 0,c=expanded.count > 2 ? expanded[2][i] : 0
                let value: Double
                switch name {
                case "sin":value=sin(a)
                case "cos":value=cos(a)
                case "abs":value=abs(a)
                case "floor":value=floor(a)
                case "ceil":value=ceil(a)
                case "fract":value=a-floor(a)
                case "sqrt":value=sqrt(a)
                case "min":value=min(a,b)
                case "max":value=max(a,b)
                case "pow":value=pow(a,b)
                case "mod":value=a-b*floor(a/b)
                case "clamp":value=min(c,max(b,a))
                case "mix":value=a+(b-a)*c
                case "step":value=b < a ? 0 : 1
                case "smoothstep":let t=min(1,max(0,(c-a)/(b-a)));value=t*t*(3-2*t)
                default:throw ProjectError.invalid("unsupported material function")
                }
                result.append(value)
            }
            return try finite(result)
        }
    }
}

private enum MaterialToken: Equatable { case number(Double),identifier(String),symbol(String),end }
private struct MaterialParser {
    var tokens:[MaterialToken]=[]
    var position=0
    var nodeCount=0
    var sampleCount=0
    let inputs:[MaterialInput]
    init(definition: MaterialDefinition) throws {
        inputs=definition.inputs
        let bytes=Array(definition.expression.utf8)
        var i=0
        while i < bytes.count {
            let byte=bytes[i]
            if [9,10,13,32].contains(byte) { i += 1;continue }
            if byte == 47,i+1 < bytes.count,bytes[i+1] == 47 {
                while i < bytes.count && bytes[i] != 10 { i += 1 };continue
            }
            if byte == 47,i+1 < bytes.count,bytes[i+1] == 42 {
                i += 2
                while i+1 < bytes.count && !(bytes[i] == 42 && bytes[i+1] == 47) { i += 1 }
                guard i+1 < bytes.count else { throw ProjectError.invalid("unterminated material comment") };i += 2;continue
            }
            if asciiLetter(byte) || byte == 95 {
                let start=i;i += 1
                while i < bytes.count && (asciiLetter(bytes[i]) || (48...57).contains(bytes[i]) || bytes[i] == 95) { i += 1 }
                tokens.append(.identifier(String(decoding:bytes[start..<i],as:UTF8.self)))
            } else if (48...57).contains(byte) || (byte == 46 && i+1 < bytes.count && (48...57).contains(bytes[i+1])) {
                let start=i
                while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
                if i < bytes.count && bytes[i] == 46 { i += 1;while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 } }
                if i < bytes.count && (bytes[i] == 69 || bytes[i] == 101) {
                    i += 1;if i < bytes.count && (bytes[i] == 43 || bytes[i] == 45) { i += 1 }
                    let exponent=i;while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
                    guard i > exponent else { throw ProjectError.invalid("invalid material exponent") }
                }
                guard let value=Double(String(decoding:bytes[start..<i],as:UTF8.self)),value.isFinite,abs(value) <= 1e6 else { throw ProjectError.invalid("invalid material number") }
                tokens.append(.number(value))
            } else if [40,41,43,45,42,47,44,46].contains(byte) {
                tokens.append(.symbol(String(UnicodeScalar(byte))));i += 1
            } else { throw ProjectError.invalid("unsupported material syntax; only bounded expressions are accepted") }
            guard tokens.count <= 512 else { throw ProjectError.invalid("material token budget exceeded") }
        }
        tokens.append(.end)
    }
    mutating func parse() throws -> MaterialNode {
        let result=try expression(depth:0)
        guard tokens[position] == .end else { throw ProjectError.invalid("unexpected material token") }
        return result
    }
    mutating func node(_ node: MaterialNode) throws -> MaterialNode {
        nodeCount += 1
        guard nodeCount <= 256 else { throw ProjectError.invalid("material expression node budget exceeded") }
        return node
    }
    mutating func take(_ symbol: String) -> Bool {
        guard tokens[position] == .symbol(symbol) else { return false };position += 1;return true
    }
    mutating func require(_ symbol: String) throws {
        guard take(symbol) else { throw ProjectError.invalid("expected \(symbol) in material expression") }
    }
    mutating func expression(depth: Int) throws -> MaterialNode {
        var result=try product(depth:depth)
        while tokens[position] == .symbol("+") || tokens[position] == .symbol("-") {
            let op=tokens[position] == .symbol("+") ? "+" : "-";position += 1
            let rhs=try product(depth:depth)
            result=try node(.binary(op,result,rhs,try compatible([result.width,rhs.width])))
        }
        return result
    }
    mutating func product(depth: Int) throws -> MaterialNode {
        var result=try unary(depth:depth)
        while tokens[position] == .symbol("*") || tokens[position] == .symbol("/") {
            let op=tokens[position] == .symbol("*") ? "*" : "/";position += 1
            let rhs=try unary(depth:depth)
            result=try node(.binary(op,result,rhs,try compatible([result.width,rhs.width])))
        }
        return result
    }
    mutating func unary(depth: Int) throws -> MaterialNode {
        guard depth <= 32 else { throw ProjectError.invalid("material expression depth exceeded") }
        if take("+") { return try node(.unary("+",unary(depth:depth+1))) }
        if take("-") { return try node(.unary("-",unary(depth:depth+1))) }
        var result:MaterialNode
        switch tokens[position] {
        case .number(let value):position += 1;result=try node(.number(value))
        case .identifier(let name):
            position += 1
            if take("(") {
                guard MaterialProgram.functionNames.contains(name) else { throw ProjectError.invalid("unknown material function \(name)") }
                var args:[MaterialNode]=[]
                if !take(")") {
                    repeat { args.append(try expression(depth:depth+1)) } while take(",")
                    try require(")")
                }
                result=try call(name,args)
            } else if let index=inputs.firstIndex(where:{$0.name == name}) {
                result=try node(.variable(name,index,inputs[index].kind.componentCount))
            } else {
                let widths=["uv":2,"time":1,"size":2,"pi":1,"TIME":1,"RENDERSIZE":2,"isf_FragNormCoord":2]
                if name == "true" || name == "false" { result=try node(.number(name == "true" ? 1 : 0)) }
                else {
                    guard let width=widths[name] else { throw ProjectError.invalid("unknown material symbol \(name)") }
                    result=try node(.variable(name,-1,width))
                }
            }
        case .symbol("("):position += 1;result=try expression(depth:depth+1);try require(")")
        default:throw ProjectError.invalid("expected a material value")
        }
        while take(".") {
            guard case .identifier(let swizzle)=tokens[position],(1...4).contains(swizzle.count) else { throw ProjectError.invalid("invalid material swizzle") }
            position += 1
            let xyzw=Array("xyzw"),rgba=Array("rgba"),characters=Array(swizzle)
            let alphabet=characters.allSatisfy { xyzw.contains($0) } ? xyzw : rgba
            guard characters.allSatisfy({ alphabet.contains($0) }) else { throw ProjectError.invalid("mixed or unknown material swizzle") }
            let indices=characters.map { alphabet.firstIndex(of:$0)! }
            guard indices.allSatisfy({ $0 < result.width }) else { throw ProjectError.invalid("material swizzle exceeds vector width") }
            result=try node(.swizzle(result,indices))
        }
        return result
    }
    func compatible(_ widths:[Int]) throws -> Int {
        let width=widths.max() ?? 1
        guard widths.allSatisfy({ $0 == 1 || $0 == width }) else { throw ProjectError.invalid("incompatible material vector sizes") }
        return width
    }
    mutating func call(_ name: String,_ args:[MaterialNode]) throws -> MaterialNode {
        let unary:Set<String>=["sin","cos","abs","floor","ceil","fract","sqrt","length"]
        let binary:Set<String>=["min","max","step","pow","mod","dot"]
        let ternary:Set<String>=["clamp","mix","smoothstep"]
        let width:Int
        if name.hasPrefix("vec"),let w=Int(name.suffix(1)) {
            guard !args.isEmpty, args.count <= 4, args.reduce(0,{$0+$1.width}) == w || (args.count == 1 && args[0].width == 1) else { throw ProjectError.invalid("invalid material vector constructor") }
            width=w
        } else if name == "sample" || name == "isfSample" {
            guard args.count == 1,args[0].width == 2 else { throw ProjectError.invalid("sample requires one vec2 coordinate") }
            sampleCount += 1
            guard sampleCount <= 16 else { throw ProjectError.invalid("material texture sample budget exceeded") }
            width=4
        } else if unary.contains(name) {
            guard args.count == 1 else { throw ProjectError.invalid("material unary function expects one argument") }
            width=name == "length" ? 1 : args[0].width
        } else if binary.contains(name) {
            guard args.count == 2 else { throw ProjectError.invalid("material binary function expects two arguments") }
            if name == "dot" {
                guard args[0].width == args[1].width else { throw ProjectError.invalid("dot needs matching vector sizes") };width=1
            } else { width=try compatible(args.map(\.width)) }
        } else if ternary.contains(name) {
            guard args.count == 3 else { throw ProjectError.invalid("material ternary function expects three arguments") }
            width=try compatible(args.map(\.width))
        } else { throw ProjectError.invalid("unknown material function") }
        return try node(.call(name,args,width))
    }
}
