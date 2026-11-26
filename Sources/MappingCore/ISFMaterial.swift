import Foundation

/// Explicit single-pass expression subset of the ISF 2 JSON + GLSL format.
/// Unsupported GLSL/statements, buffers, passes and external files fail before
/// any filesystem access or backend compilation. No source includes are read.
public enum ISFMaterial {
    public static func importSource(_ source: String, name: String = "ISF material") throws -> MaterialDefinition {
        guard source.utf8.count <= 65536 else { throw ProjectError.invalid("ISF source exceeds 64 KiB") }
        let text=source.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.hasPrefix("/*"), let end=text.range(of:"*/") else { throw ProjectError.invalid("ISF must begin with a JSON block comment") }
        let header=String(text[text.index(text.startIndex,offsetBy:2)..<end.lowerBound])
        guard header.utf8.count <= 16384,let data=header.data(using:.utf8),
              let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            throw ProjectError.invalid("invalid ISF JSON header")
        }
        guard let version=json["ISFVSN"] as? String,["2","2.0","2.0.0"].contains(version) else {
            throw ProjectError.invalid("only the declared ISF 2 expression subset is supported")
        }
        if let imported=json["IMPORTED"] {
            guard let dictionary=imported as? [String:Any],dictionary.isEmpty else {
                throw ProjectError.invalid("ISF external imported images are unsupported")
            }
        }
        if let passes=json["PASSES"] {
            guard let array=passes as? [[String:Any]], array.count <= 1, array.allSatisfy(\.isEmpty) else {
                throw ProjectError.invalid("ISF multiple passes, targets, persistence and custom pass sizes are unsupported")
            }
        }
        let inputObjects: [[String:Any]]
        if let value=json["INPUTS"] {
            guard let entries=value as? [[String:Any]] else { throw ProjectError.invalid("ISF INPUTS must be an array of objects") }
            inputObjects=entries
        } else { inputObjects=[] }
        guard inputObjects.count <= MaterialProgram.maximumInputs+1 else { throw ProjectError.invalid("ISF input budget exceeded") }
        var names=Set<String>(), inputs:[MaterialInput]=[], imageName:String?
        for object in inputObjects {
            guard let variable=object["NAME"] as? String,MaterialProgram.validIdentifier(variable),
                  !MaterialProgram.reservedNames.contains(variable), !variable.hasPrefix("gl_"), names.insert(variable).inserted,
                  let type=object["TYPE"] as? String else { throw ProjectError.invalid("invalid or duplicate ISF input") }
            if type == "image" {
                guard imageName == nil,object["DEFAULT"] == nil,object["MIN"] == nil,object["MAX"] == nil else {
                    throw ProjectError.invalid("only one ISF image bound to the surface source is supported")
                }
                imageName=variable;continue
            }
            guard let kind=MaterialInputType(rawValue:type) else { throw ProjectError.invalid("unsupported ISF input type \(type)") }
            let width=kind.componentCount
            let defaultValue: [Double], minimum: [Double], maximum: [Double]
            if kind == .bool {
                guard object["MIN"] == nil,object["MAX"] == nil else { throw ProjectError.invalid("ISF bool ranges are implicit") }
                if let value=object["DEFAULT"] {
                    let data=try JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed)
                    guard let boolean=try? JSONDecoder().decode(Bool.self,from:data) else { throw ProjectError.invalid("ISF bool DEFAULT must be Boolean") }
                    defaultValue=[boolean ? 1 : 0]
                } else { defaultValue=[0] }
                minimum=[0];maximum=[1]
            } else {
                minimum=try components(object["MIN"],width:width,fallback:Array(repeating:0,count:width))
                maximum=try components(object["MAX"],width:width,fallback:Array(repeating:1,count:width))
                let preferred=kind == .color ? [1.0,1.0,1.0,1.0] : Array(repeating:0.0,count:width)
                let fallback=(0..<width).map { min(maximum[$0],max(minimum[$0],preferred[$0])) }
                defaultValue=try components(object["DEFAULT"],width:width,fallback:fallback)
            }
            let label: String
            if let value=object["LABEL"] { guard let string=value as? String else { throw ProjectError.invalid("ISF LABEL must be text") };label=string }
            else { label="" }
            inputs.append(MaterialInput(name:variable,label:label,kind:kind,defaultValue:defaultValue,minimum:minimum,maximum:maximum))
        }
        let body=try stripComments(String(text[end.upperBound...]))
        let expressionPattern="\\A\\s*void\\s+main\\s*\\(\\s*(?:void\\s*)?\\)\\s*\\{\\s*gl_FragColor\\s*=\\s*(.*?)\\s*;\\s*\\}\\s*\\z"
        let regex=try NSRegularExpression(pattern:expressionPattern,options:[.dotMatchesLineSeparators])
        let range=NSRange(body.startIndex..<body.endIndex,in:body)
        guard let match=regex.firstMatch(in:body,range:range),let expressionRange=Range(match.range(at:1),in:body) else {
            throw ProjectError.invalid("ISF subset requires void main() { gl_FragColor = oneExpression; }")
        }
        var expression=String(body[expressionRange])
        let nativeAliases=try NSRegularExpression(pattern:"\\b(?:uv|time|size|pi|sample|isfSample)\\b")
        guard nativeAliases.firstMatch(in:expression,range:NSRange(expression.startIndex..<expression.endIndex,in:expression)) == nil else {
            throw ProjectError.invalid("native expression aliases are not ISF variables/functions")
        }
        if let imageName {
            let escaped=NSRegularExpression.escapedPattern(for:imageName)
            expression=try replacing("\\bIMG_NORM_PIXEL\\s*\\(\\s*"+escaped+"\\s*,",in:expression,with:"isfSample(")
            expression=try replacing("\\bIMG_NORM_THIS_PIXEL\\s*\\(\\s*"+escaped+"\\s*\\)",in:expression,with:"isfSample(isf_FragNormCoord)")
        }
        let credit: String
        if let value=json["CREDIT"] { guard let string=value as? String else { throw ProjectError.invalid("ISF CREDIT must be text") };credit=string }
        else { credit="" }
        let definition=MaterialDefinition(name:name,expression:expression,inputs:inputs,credit:credit)
        _=try MaterialProgram(definition:definition)
        return definition
    }

    private static func components(_ value: Any?, width: Int, fallback: [Double]) throws -> [Double] {
        guard let value else { return fallback }
        let data=try JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed)
        let values:[Double]
        if width == 1,let number=try? JSONDecoder().decode(Double.self,from:data) { values=[number] }
        else if width > 1,let vector=try? JSONDecoder().decode([Double].self,from:data),vector.count == width { values=vector }
        else { throw ProjectError.invalid("ISF attributes need the declared finite numeric component count") }
        guard values.allSatisfy(\.isFinite) else { throw ProjectError.invalid("ISF attributes must be finite") }
        return values
    }

    private static func replacing(_ pattern: String,in string: String,with replacement: String) throws -> String {
        let regex=try NSRegularExpression(pattern:pattern)
        return regex.stringByReplacingMatches(in:string,range:NSRange(string.startIndex..<string.endIndex,in:string),withTemplate:replacement)
    }
    private static func stripComments(_ text: String) throws -> String {
        let bytes=Array(text.utf8);var result:[UInt8]=[],i=0
        while i < bytes.count {
            if bytes[i] == 47,i+1 < bytes.count,bytes[i+1] == 47 {
                while i < bytes.count && bytes[i] != 10 { i += 1 }
                result.append(32)
            } else if bytes[i] == 47,i+1 < bytes.count,bytes[i+1] == 42 {
                i += 2
                while i+1 < bytes.count && !(bytes[i] == 42 && bytes[i+1] == 47) { i += 1 }
                guard i+1 < bytes.count else { throw ProjectError.invalid("unterminated ISF comment") };i += 2;result.append(32)
            } else { result.append(bytes[i]);i += 1 }
        }
        return String(decoding:result,as:UTF8.self)
    }
}
