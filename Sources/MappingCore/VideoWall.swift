import Foundation

public struct VideoWallConfiguration: Codable, Equatable, Sendable {
    public var columns:Int, rows:Int
    /// Fractions of the complete source hidden by each bezel between screens.
    public var bezelX:Double, bezelY:Double
    /// Fractions of a tile covered by the adjacent projector, mutually exclusive
    /// with bezel on that axis. Use matching edge-blend widths for projectors.
    public var overlapX:Double, overlapY:Double
    public init(columns:Int=2,rows:Int=1,bezelX:Double=0,bezelY:Double=0,overlapX:Double=0,overlapY:Double=0) {
        self.columns=columns;self.rows=rows;self.bezelX=bezelX;self.bezelY=bezelY;self.overlapX=overlapX;self.overlapY=overlapY
    }
}

public struct VideoWallTile: Equatable, Sendable {
    public var index:Int, column:Int, row:Int
    public var input:[Point2]
    public var output:[Point2]
    public var edgeBlend:EdgeBlendSettings
}

public enum VideoWall {
    public static func tiles(_ configuration:VideoWallConfiguration) throws -> [VideoWallTile] {
        let c=configuration
        guard (1...16).contains(c.columns),(1...16).contains(c.rows),c.columns*c.rows<=64,
              [c.bezelX,c.bezelY].allSatisfy({$0.isFinite && (0...0.25).contains($0)}),
              [c.overlapX,c.overlapY].allSatisfy({$0.isFinite && (0...0.5).contains($0)}),
              (c.bezelX==0 || c.overlapX==0),(c.bezelY==0 || c.overlapY==0),
              c.bezelX*Double(c.columns-1)<1,c.bezelY*Double(c.rows-1)<1 else {
            throw ProjectError.invalid("video wall needs 1...64 tiles, valid bezels and mutually exclusive overlap/bezel axes")
        }
        func span(_ count:Int,_ bezel:Double,_ overlap:Double) -> (size:Double,step:Double) {
            if overlap>0 {
                let size=1/(Double(count)-Double(count-1)*overlap)
                return (size,size*(1-overlap))
            }
            let size=(1-Double(count-1)*bezel)/Double(count)
            return (size,size+bezel)
        }
        let x=span(c.columns,c.bezelX,c.overlapX),y=span(c.rows,c.bezelY,c.overlapY)
        var result:[VideoWallTile]=[]
        for row in 0..<c.rows {for column in 0..<c.columns {
            let left=Double(column)*x.step,top=Double(row)*y.step
            let right=column==c.columns-1 ? 1 : left+x.size
            let bottom=row==c.rows-1 ? 1 : top+y.size
            let blend=EdgeBlendSettings(left:column>0 ? c.overlapX : 0,right:column<c.columns-1 ? c.overlapX : 0,
                                       top:row>0 ? c.overlapY : 0,bottom:row<c.rows-1 ? c.overlapY : 0)
            result.append(VideoWallTile(index:row*c.columns+column,column:column,row:row,
                                        input:[Point2(left,top),Point2(right,top),Point2(right,bottom),Point2(left,bottom)],
                                        output:Point2.unitQuad,edgeBlend:blend))
        }}
        return result
    }
}
