import XCTest
import Foundation
@testable import MappingCore

final class CompositionUtilityTests:XCTestCase {
    func testComplementaryEdgeBlendPowerRampsAndColorCalibration() throws {
        for power in [0.1,0.5,1,2,10] {
            var previous=0.0
            for i in 0...1000 {
                let t=Double(i)/1000,left=EdgeBlend.ramp(t,power:power),right=EdgeBlend.ramp(1-t,power:power)
                XCTAssertEqual(left+right,1,accuracy:1e-12)
                XCTAssertTrue(left>=previous);previous=left
            }
        }
        let a=EdgeBlendSettings(right:0.2,power:2),b=EdgeBlendSettings(left:0.2,power:2)
        for i in 0...100 {
            let t=Double(i)/100
            XCTAssertEqual(EdgeBlend.gain(at:Point2(0.8+0.2*t,0.5),settings:a)+EdgeBlend.gain(at:Point2(0.2*t,0.5),settings:b),1,accuracy:1e-12)
        }
        XCTAssertEqual(EdgeBlend.ramp(0.5,power:Double.greatestFiniteMagnitude),0)
        let corrected=EdgeBlendSettings(gamma:2,blackLevel:0.1)
        XCTAssertEqual(EdgeBlend.channel(0.25,at:Point2(0.5,0.5),settings:corrected),0.55,accuracy:1e-12)
        XCTAssertEqual(EdgeBlend.channel(0,at:Point2(0.5,0.5),settings:corrected),0.1)
        for invalid in [EdgeBlendSettings(left:Double.nan),EdgeBlendSettings(left:0.6,right:0.6),EdgeBlendSettings(power:0),EdgeBlendSettings(gamma:6)] {
            XCTAssertThrowsError(try EdgeBlend.validate(invalid));XCTAssertEqual(EdgeBlend.gain(at:Point2(0.5,0.5),settings:invalid),0)
        }
        let round=try JSONDecoder().decode(EdgeBlendSettings.self,from:JSONEncoder().encode(corrected))
        XCTAssertEqual(round,corrected)
    }

    func testVideoWallUniqueTilesCoverageBezelsOverlapAndBounds() throws {
        let configuration=VideoWallConfiguration(columns:4,rows:3)
        let tiles=try VideoWall.tiles(configuration)
        XCTAssertEqual(tiles.map(\.index),Array(0..<12))
        XCTAssertEqual(tiles[0].input[0],Point2(0,0));XCTAssertEqual(tiles[11].input[2],Point2(1,1))
        for tile in tiles {
            XCTAssertEqual(tile.index,tile.row*4+tile.column);XCTAssertEqual(tile.output,Point2.unitQuad)
            let middle=Point2((tile.input[0].x+tile.input[2].x)/2,(tile.input[0].y+tile.input[2].y)/2)
            XCTAssertEqual(tiles.filter { Geometry.contains(middle,polygon:$0.input) }.count,1)
        }
        let bezels=try VideoWall.tiles(.init(columns:2,rows:2,bezelX:0.1,bezelY:0.2))
        XCTAssertEqual(bezels[0].input[1].x,0.45,accuracy:1e-12)
        XCTAssertEqual(bezels[1].input[0].x,0.55,accuracy:1e-12)
        XCTAssertFalse(bezels.contains {Geometry.contains(Point2(0.5,0.5),polygon:$0.input)})
        let overlaps=try VideoWall.tiles(.init(columns:2,rows:1,overlapX:0.2))
        XCTAssertTrue(overlaps[0].input[1].x>overlaps[1].input[0].x)
        XCTAssertEqual(overlaps[0].edgeBlend.right,0.2);XCTAssertEqual(overlaps[1].edgeBlend.left,0.2)
        let projectors=try VideoWall.tiles(.init(columns:2,rows:2,overlapX:0.25,overlapY:0.3))
        for y in 0...40 {for x in 0...40 {
            let point=Point2(Double(x)/40,Double(y)/40)
            let gain=projectors.reduce(0.0) { result,tile in
                let local=Point2((point.x-tile.input[0].x)/(tile.input[2].x-tile.input[0].x),
                                 (point.y-tile.input[0].y)/(tile.input[2].y-tile.input[0].y))
                return result+EdgeBlend.gain(at:local,settings:tile.edgeBlend)
            }
            XCTAssertEqual(gain,1,accuracy:1e-12)
        }}
        for config in [VideoWallConfiguration(columns:0),.init(columns:Int.max),.init(columns:16,rows:16),.init(bezelX:0.1,overlapX:0.1),.init(overlapX:Double.nan),.init(columns:6,bezelX:0.2)] {
            XCTAssertThrowsError(try VideoWall.tiles(config))
        }
        XCTAssertEqual(try JSONDecoder().decode(VideoWallConfiguration.self,from:JSONEncoder().encode(configuration)),configuration)
    }

    func testSVGPathCommandsQuadraticConversionTransformsAndCompoundFill() throws {
        let data=Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <g transform="translate(10,20) scale(2)" opacity="0.5">
            <path id="compound" fill="#f00" fill-rule="evenodd" d="M0 0 L20 0 L20 20 L0 20 Z M5 5 h10 v10 h-10z"/>
          </g>
          <path id="curve" fill="none" stroke="blue" stroke-width="2" d="M10 20l10 0h10v10q10 20 20 0c10-10 20-10 30 0z"/>
        </svg>
        """.utf8)
        let svg=try SVGImport.parse(data)
        XCTAssertEqual(svg.shapes.count,2)
        let shape=svg.shapes[0]
        XCTAssertEqual(shape.paths.count,2);XCTAssertEqual(shape.fillRule,.evenOdd)
        XCTAssertEqual(shape.fill,[1,0,0,1]);XCTAssertEqual(shape.opacityGroups.map(\.opacity),[0.5]);XCTAssertEqual(shape.paths[0].nodes[0].anchor,Point2(0.1,0.2))
        XCTAssertEqual(shape.paths[0].nodes[2].anchor,Point2(0.5,0.6))
        let curve=svg.shapes[1]
        XCTAssertNil(curve.fill);XCTAssertEqual(curve.stroke,[0,0,1,1]);XCTAssertEqual(curve.strokeWidth,0.02)
        XCTAssertEqual(curve.paths[0].nodes.count,6);XCTAssertTrue(curve.paths[0].closed)
        XCTAssertEqual(curve.paths[0].nodes[3].outgoing.x,0.3666666666666667,accuracy:1e-12)
        XCTAssertEqual(curve.paths[0].nodes[4].incoming.y,0.43333333333333335,accuracy:1e-12)
        XCTAssertEqual(try JSONDecoder().decode(SVGDocument.self,from:JSONEncoder().encode(svg)),svg)
    }

    func testSVGBasicShapesCircleControlPointsAndViewport() throws {
        let source="""
        <svg width="200px" height="100px">
          <rect x="10" y="20" width="30" height="40"/>
          <circle cx="100" cy="50" r="20" fill="#0f08"/>
          <ellipse cx="160" cy="50" rx="20" ry="10"/>
          <line x1="1" y1="2" x2="3" y2="4" stroke="black"/>
          <polyline points="0,0 20,10 40,0" fill="none" stroke="red"/>
          <polygon points="0 0 20 0 10 10"/>
        </svg>
        """
        let svg=try SVGImport.parse(Data(source.utf8))
        XCTAssertEqual(svg.shapes.count,6);XCTAssertEqual(svg.viewBox,[0,0,200,100])
        XCTAssertEqual(svg.shapes[0].paths[0].nodes[2].anchor,Point2(0.2,0.6))
        XCTAssertEqual(svg.shapes[1].paths[0].nodes[0].anchor,Point2(0.6,0.5))
        XCTAssertEqual(svg.shapes[1].fill?[3],8.0/15)
        let nodes=svg.shapes[1].paths[0].nodes
        // Independent dense radial oracle for the declared quarter-circle cubic.
        for i in nodes.indices {for sample in 0...100 {
            let a=nodes[i],b=nodes[(i+1)%nodes.count],t=Double(sample)/100,u=1-t
            let x=u*u*u*a.anchor.x+3*u*u*t*a.outgoing.x+3*u*t*t*b.incoming.x+t*t*t*b.anchor.x
            let y=u*u*u*a.anchor.y+3*u*u*t*a.outgoing.y+3*u*t*t*b.incoming.y+t*t*t*b.anchor.y
            let normalized=hypot((x-0.5)/0.1,(y-0.5)/0.2)
            XCTAssertTrue(abs(normalized-1)<0.00028)
        }}
    }

    func testSVGMalformedUnsafeUnsupportedAndBudgetsRejectAtomically() throws {
        let bad=[
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg viewBox='0 0 1 1'><path d='M0 0L1 1'/></svg>",
            "<svg viewBox='0 0 1 1'><script>alert(1)</script></svg>",
            "<svg viewBox='0 0 1 1'><image href='https://example.invalid/a.png'/></svg>",
            "<svg viewBox='0 0 1 1'><path style='fill:red' d='M0 0L1 1'/></svg>",
            "<svg viewBox='0 0 1 1'><path d='M0 0A1 1 0 0 0 1 1'/></svg>",
            "<svg viewBox='0 0 1 1'><path d='M0,,0L1 1'/></svg>",
            "<svg viewBox='0 0 1 1'><path d='M0 0L1e999 1'/></svg>",
            "<svg viewBox='0 0 1 1'><rect width='NaN' height='1'/></svg>",
            "<svg viewBox='0 0 0 1'><rect width='1' height='1'/></svg>",
            "<svg viewBox='0 0 1 1'><path d='M0 0L1'/></svg>",
            "<svg viewBox='0 0 1 1'><path transform='scale(2,1)' stroke='red' d='M0 0L1 1'/></svg>",
            "<svg viewBox='0 0 1 1'><path d='M0 0L1 1'/><rect width='-1' height='1'/></svg>"
        ]
        for source in bad {XCTAssertThrowsError(try SVGImport.parse(Data(source.utf8)))}
        XCTAssertThrowsError(try SVGImport.parse(Data(repeating:32,count:SVGImport.maximumBytes+1)))
        let deep="<svg viewBox='0 0 1 1'>"+String(repeating:"<g>",count:33)+"<path d='M0 0L1 1'/>"+String(repeating:"</g>",count:33)+"</svg>"
        XCTAssertThrowsError(try SVGImport.parse(Data(deep.utf8)))
        let tooMany="<svg viewBox='0 0 1 1'><path d='M0 0 "+String(repeating:"L1 1 ",count:129)+"'/></svg>"
        XCTAssertThrowsError(try SVGImport.parse(Data(tooMany.utf8)))
    }
}
