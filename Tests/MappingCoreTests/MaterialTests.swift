import XCTest
import Foundation
@testable import MappingCore

final class MaterialTests: XCTestCase {
    private func near(_ got: [Double],_ expected: [Double],file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertEqual(got.count,expected.count,file:file,line:line)
        for (a,b) in zip(got,expected) { XCTAssertEqual(a,b,accuracy:1e-10,file:file,line:line) }
    }
    func testMaterialArithmeticVectorParametersAndUniformPacking() throws {
        let gradient=try MaterialProgram(definition:MaterialDefinition(expression:"vec4(uv, 0.5+0.5*sin(time), 1)"))
        near(try gradient.evaluate(uv:Point2(0.2,0.3)),[0.2,0.3,0.5,1])
        near(try gradient.evaluate(uv:Point2(0.2,0.3),time:Double.pi/2),[0.2,0.3,1,1])
        let tint=MaterialInput(name:"tint",kind:.color,defaultValue:[1,0,0,1],minimum:[0,0,0,0],maximum:[1,1,1,1])
        let amount=MaterialInput(name:"amount",defaultValue:[0.25])
        let program=try MaterialProgram(definition:MaterialDefinition(expression:"mix(sample(uv), tint, amount)",inputs:[tint,amount]))
        near(try program.evaluate(uv:Point2(0.2,0.4),sample:{ _ in [0.2,0.4,0.6,0.8] }),[0.4,0.3,0.45,0.85])
        let vectors=try program.parameterVectors(values:["amount":[0.75]])
        XCTAssertEqual(vectors.count,16);near(vectors[0],[1,0,0,1]);near(vectors[1],[0.75,0,0,0]);near(vectors[15],[0,0,0,0])
        XCTAssertTrue(program.metalExpression.contains("materialParams[0]"))
        XCTAssertTrue(program.metalExpression.contains("float4(materialParams[1].x)"))
        XCTAssertThrowsError(try program.parameterVectors(values:["absent":[1]]))
        XCTAssertThrowsError(try program.parameterVectors(values:["amount":[1.1]]))
        XCTAssertThrowsError(try program.parameterVectors(values:["tint":[1,0,0]]))
        let math=try MaterialProgram(definition:MaterialDefinition(expression:"vec4(mod(-0.25,1),length(vec2(3,4)),dot(vec2(2,3),vec2(4,5)),1)"))
        near(try math.evaluate(uv:Point2(0,0)),[0.75,5,23,1])
        XCTAssertTrue(math.metalExpression.contains("apertureMaterialMod"))
    }
    func testMaterialSwizzlesFunctionsBoundsAndMalformedSyntax() throws {
        let program=try MaterialProgram(definition:MaterialDefinition(expression:"vec4(clamp(uv.yx,0,1),fract(-0.25),step(0.5,0.75))"))
        near(try program.evaluate(uv:Point2(1.2,-0.3)),[0,1,0.75,1])
        let smooth=try MaterialProgram(definition:MaterialDefinition(expression:"vec4(smoothstep(0,1,uv.x))"))
        near(try smooth.evaluate(uv:Point2(0.25,0.5)),[0.15625,0.15625,0.15625,0.15625])
        for expression in ["vec4(uv.z)","vec4(uv.xr,0,1)","vec4(1); while(true){}","#include <metal_stdlib>","vec4(buffer[0])","vec4(unknown)","texture2D(image,uv)","vec3(1)","vec4(mix(vec2(1),vec3(0),0.5),1)","vec4(1e999)","vec4(1e)","vec4(1) /*unterminated"] {
            XCTAssertThrowsError(try MaterialProgram(definition:MaterialDefinition(expression:expression)),expression)
        }
        XCTAssertThrowsError(try MaterialProgram(definition:MaterialDefinition(expression:String(repeating:"(",count:34)+"vec4(1)"+String(repeating:")",count:34))))
        XCTAssertThrowsError(try MaterialProgram(definition:MaterialDefinition(expression:Array(repeating:"sample(uv)",count:17).joined(separator:"+"))))
        XCTAssertThrowsError(try MaterialProgram(definition:MaterialDefinition(expression:String(repeating:" ",count:4096)+"vec4(1)")))
        let divide=try MaterialProgram(definition:MaterialDefinition(expression:"vec4(1/uv.x)"))
        XCTAssertThrowsError(try divide.evaluate(uv:Point2(0,0)))
        XCTAssertThrowsError(try program.evaluate(uv:Point2(Double.nan,0)))
        XCTAssertThrowsError(try program.evaluate(uv:Point2(0,0),time:Double.infinity))
    }
    func testMaterialInputValidationAndCodableRoundTrip() throws {
        let flag=MaterialInput(name:"enabled",kind:.bool,defaultValue:[1])
        let offset=MaterialInput(name:"offset",kind:.point2D,defaultValue:[0.1,0.2],minimum:[-1,-1],maximum:[1,1])
        let definition=MaterialDefinition(name:"Original",expression:"vec4(uv+offset,enabled,1)",inputs:[flag,offset],credit:"ApertureCue contributors")
        let program=try MaterialProgram(definition:definition)
        near(try program.evaluate(uv:Point2(0.2,0.3)),[0.3,0.5,1,1])
        XCTAssertEqual(try JSONDecoder().decode(MaterialDefinition.self,from:JSONEncoder().encode(definition)),definition)
        XCTAssertThrowsError(try program.parameterVectors(values:["enabled":[0.5]]))
        for bad in [MaterialInput(name:"uv"),MaterialInput(name:"sample"),MaterialInput(name:"not-valid"),MaterialInput(name:"a",defaultValue:[Double.nan]),MaterialInput(name:"a",minimum:[1],maximum:[0]),MaterialInput(name:"a",kind:.point2D)] {
            XCTAssertThrowsError(try MaterialProgram(definition:MaterialDefinition(expression:"vec4(1)",inputs:[bad])))
        }
        XCTAssertThrowsError(try MaterialProgram(definition:MaterialDefinition(expression:"vec4(1)",inputs:[flag,flag])))
        let many=(0..<17).map { MaterialInput(name:"p\($0)") }
        XCTAssertThrowsError(try MaterialProgram(definition:MaterialDefinition(expression:"vec4(1)",inputs:many)))
    }
    func testISFTypedInputsOrientationNormalizedSamplingAndPersistence() throws {
        let source="""
        /*{"ISFVSN":"2.0","CREDIT":"Original test","INPUTS":[{"NAME":"inputImage","TYPE":"image"},{"NAME":"gain","TYPE":"float","DEFAULT":0.5,"MIN":0,"MAX":1},{"NAME":"colorValue","TYPE":"color","DEFAULT":[1,0.5,0.25,1]},{"NAME":"flag","TYPE":"bool","DEFAULT":true},{"NAME":"offset","TYPE":"point2D","DEFAULT":[0.1,0.2],"MIN":[-1,-1],"MAX":[1,1]}]}*/
        // A single bounded source expression.
        void main(void) {
            gl_FragColor = IMG_NORM_PIXEL(inputImage,isf_FragNormCoord) * colorValue * gain;
        }
        """
        let definition=try ISFMaterial.importSource(source,name:"Tint")
        XCTAssertEqual(definition.credit,"Original test");XCTAssertEqual(definition.inputs.count,4)
        let program=try MaterialProgram(definition:definition)
        near(try program.evaluate(uv:Point2(0.2,0.3),sample:{ [$0.x,$0.y,0.8,1] }),[0.1,0.075,0.1,0.5])
        XCTAssertTrue(program.metalExpression.contains("sampleMaterialISF"))
        let generator=try ISFMaterial.importSource("/*{\"ISFVSN\":\"2\"}*/ void main(){gl_FragColor=vec4(isf_FragNormCoord,0.5+0.5*sin(TIME),1);}")
        near(try MaterialProgram(definition:generator).evaluate(uv:Point2(0.2,0.3)),[0.2,0.7,0.5,1])
        let thisPixel=try ISFMaterial.importSource("/*{\"ISFVSN\":\"2\",\"INPUTS\":[{\"NAME\":\"inputImage\",\"TYPE\":\"image\"}]}*/ void main(){gl_FragColor=IMG_NORM_THIS_PIXEL(inputImage);}")
        near(try MaterialProgram(definition:thisPixel).evaluate(uv:Point2(0.2,0.3),sample:{ [$0.x,$0.y,0,1] }),[0.2,0.3,0,1])
        XCTAssertEqual(try JSONDecoder().decode(MaterialDefinition.self,from:JSONEncoder().encode(definition)),definition)
        let ranged=try ISFMaterial.importSource("/*{\"ISFVSN\":\"2\",\"INPUTS\":[{\"NAME\":\"level\",\"TYPE\":\"float\",\"MIN\":2,\"MAX\":4}]}*/ void main(){gl_FragColor=vec4(level);}")
        near(try MaterialProgram(definition:ranged).evaluate(uv:Point2(0,0)),[2,2,2,2])
    }
    func testISFRejectsUnsafeAndUnsupportedFeaturesAtomically() throws {
        let bodies=["void main(){float v=0.5;gl_FragColor=vec4(v);}","void main(){for(int i=0;i<4;i++){}gl_FragColor=vec4(1);}","#include \"../secret\"\nvoid main(){gl_FragColor=vec4(1);}","void main(){gl_FragColor=sample(uv);}","void main(){gl_FragColor=IMG_NORM_PIXEL(missing,isf_FragNormCoord);}"]
        for body in bodies { XCTAssertThrowsError(try ISFMaterial.importSource("/*{\"ISFVSN\":\"2\"}*/"+body)) }
        for json in ["{}","{\"ISFVSN\":\"1\"}","{\"ISFVSN\":\"2.1\"}","{\"ISFVSN\":\"2\",\"PASSES\":[{},{}]}","{\"ISFVSN\":\"2\",\"PASSES\":[{\"TARGET\":\"history\",\"PERSISTENT\":true}]}","{\"ISFVSN\":\"2\",\"IMPORTED\":{\"image\":{\"PATH\":\"../private.png\"}}}","{\"ISFVSN\":\"2\",\"INPUTS\":[{\"NAME\":\"sound\",\"TYPE\":\"audio\"}]}","{\"ISFVSN\":\"2\",\"INPUTS\":[{\"NAME\":\"level\",\"TYPE\":\"float\",\"DEFAULT\":true}]}","{\"ISFVSN\":\"2\",\"INPUTS\":[{\"NAME\":\"flag\",\"TYPE\":\"bool\",\"DEFAULT\":1}]}"] {
            XCTAssertThrowsError(try ISFMaterial.importSource("/*"+json+"*/void main(){gl_FragColor=vec4(1);}"))
        }
        XCTAssertThrowsError(try ISFMaterial.importSource(String(repeating:" ",count:65537)))
    }
    func testChromaLumaSpillAndColorEffectsNumericalOracle() throws {
        let settings=EffectsSettings(keyMode:.chroma,threshold:0.1,softness:0.2)
        near(try Effects.evaluate([0,1,0,1],settings:settings),[0,1,0,0])
        let distance=0.3/sqrt(3.0),u=(distance-0.1)/0.2
        near(try Effects.evaluate([0.3,1,0,0.8],settings:settings),[0.3,1,0,0.8*u*u*(3-2*u)])
        near(try Effects.evaluate([0.2,0.8,0.1,0.75],settings:.init(keyMode:.chroma,threshold:0,softness:0,spill:1)),[0.2,0.2,0.1,0.75])
        near(try Effects.evaluate([0.25,0.25,0.25,0.8],settings:.init(keyMode:.luma,threshold:0.2,softness:0.1)),[0.25,0.25,0.25,0.4])
        near(try Effects.evaluate([0.2,0.6,0.8,0.7],settings:.init(saturation:0,inverted:true,posterizeLevels:3)),[0.5,0.5,0.5,0.7])
        near(try Effects.evaluate([0.2,0.6,0.8,0.7],settings:.init()),[0.2,0.6,0.8,0.7])
        near(try Effects.evaluate([0,0,0,1],settings:.init(keyMode:.luma,threshold:0,softness:0)),[0,0,0,0])
        XCTAssertThrowsError(try Effects.validate(.init(softness:Double.nan)))
        XCTAssertThrowsError(try Effects.validate(.init(keyColor:[0,1])))
        XCTAssertThrowsError(try Effects.validate(.init(posterizeLevels:1)))
        XCTAssertThrowsError(try Effects.validate(.init(spill:1.1)))
        XCTAssertThrowsError(try Effects.evaluate([0,0,0,Double.infinity],settings:.init()))
    }
}
