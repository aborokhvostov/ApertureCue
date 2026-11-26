import Foundation

/// Atomic, document-level geometry commands. Editor adapters own gesture/history
/// coordination; locks are also checked here so direct command calls stay safe.
public enum SurfaceEditing {
    public static func creatingBezierWarp(surfaceID: UUID,columns: Int = 1,rows: Int = 1,in project: Project) throws -> Project {
        guard let index=editableIndex(surfaceID,in:project) else {return project}
        var result=project,surface=result.surfaces[index]
        surface.bezierWarp=try BezierWarp.regular(quad:Point2.unitQuad,columns:columns,rows:rows)
        surface.warpTransform=try transform(from:Point2.unitQuad,to:surface.output)
        surface.mesh=[];surface.meshColumns=0;surface.meshRows=0;surface.meshWeights=[]
        surface.inputMesh=[];surface.inputWarp=nil;surface.inputWarpTransform = .identity;surface.meshLinked=false
        result.surfaces[index]=surface;try ProjectStore.validate(result);return result
    }

    public static func preparingInputWarp(surfaceID: UUID,in project: Project) throws -> Project {
        guard let index=editableIndex(surfaceID,in:project) else {return project}
        var result=project
        if result.surfaces[index].bezierWarp == nil {result=try creatingBezierWarp(surfaceID:surfaceID,in:result)}
        guard let output=result.surfaces[index].bezierWarp else {return result}
        if result.surfaces[index].inputWarp == nil {
            result.surfaces[index].inputWarp=try BezierWarp.regular(quad:Point2.unitQuad,columns:output.columns,rows:output.rows)
            result.surfaces[index].inputWarpTransform=try transform(from:Point2.unitQuad,to:result.surfaces[index].input)
        }
        try ProjectStore.validate(result);return result
    }

    public static func resettingBezierWarp(surfaceID: UUID,in project: Project) throws -> Project {
        guard let index=editableIndex(surfaceID,in:project),project.surfaces[index].bezierWarp != nil else {return project}
        var result=project
        result.surfaces[index].bezierWarp=nil;result.surfaces[index].warpTransform = .identity
        result.surfaces[index].inputWarp=nil;result.surfaces[index].inputWarpTransform = .identity
        result.surfaces[index].meshLinked=false
        try ProjectStore.validate(result);return result
    }

    public static func settingMeshLink(surfaceID: UUID,enabled: Bool,in project: Project) throws -> Project {
        guard let index=editableIndex(surfaceID,in:project) else {return project}
        var result=project
        if enabled {
            if result.surfaces[index].bezierWarp != nil {result=try preparingInputWarp(surfaceID:surfaceID,in:result)}
            else {
                let s=result.surfaces[index]
                guard SurfaceWarpGeometry.validRegularMesh(s) else {throw ProjectError.invalid("create a regular or Bezier mesh before enabling the source link")}
                if s.inputMesh.isEmpty {result.surfaces[index].inputMesh=try Geometry.regularMesh(quad:s.input,columns:s.meshColumns,rows:s.meshRows)}
            }
        }
        result.surfaces[index].meshLinked=enabled
        try ProjectStore.validate(result);return result
    }

    public static func editingWarpControl(surfaceID: UUID,index: Int,world: Point2,input: Bool,in project: Project) throws -> Project {
        guard let surfaceIndex=editableIndex(surfaceID,in:project) else {return project}
        guard SurfaceWarpGeometry.finite(world) else {throw ProjectError.invalid("enter a finite warp control point")}
        var result=project
        if input || result.surfaces[surfaceIndex].meshLinked {result=try preparingInputWarp(surfaceID:surfaceID,in:result)}
        var surface=result.surfaces[surfaceIndex]
        guard var output=surface.bezierWarp,output.controls.indices.contains(index) else {throw ProjectError.invalid("choose an existing Bezier control point")}
        let outputFrame=surface.warpTransform,inputFrame=surface.inputWarpTransform
        if input {
            guard var source=surface.inputWarp,source.controls.indices.contains(index) else {throw ProjectError.invalid("create the Bezier source lattice before editing it")}
            let original=try source.controls.map {try inputFrame.applying($0)}
            source.controls[index]=try inputFrame.inverse().applying(world)
            if surface.meshLinked {
                let destination=try output.controls.map {try outputFrame.applying($0)}
                let linked=try MeshLinkGeometry.movingOutputVertex(output:original,input:destination,index:index,to:world,outputQuad:surface.input,inputQuad:surface.output,linked:true)
                output.controls[index]=try outputFrame.inverse().applying(linked.input[index])
            }
            surface.inputWarp=source
        } else {
            let group=try GroupEngine.worldTransform(for:surface.groupID,groups:project.groups)
            let destination=try group.inverse().applying(world),original=try output.controls.map {try outputFrame.applying($0)}
            output.controls[index]=try outputFrame.inverse().applying(destination)
            if surface.meshLinked {
                guard var source=surface.inputWarp else {throw ProjectError.invalid("linked Bezier source lattice is missing")}
                let sourcePoints=try source.controls.map {try inputFrame.applying($0)}
                let linked=try MeshLinkGeometry.movingOutputVertex(output:original,input:sourcePoints,index:index,to:destination,outputQuad:surface.output,inputQuad:surface.input,linked:true)
                source.controls[index]=try inputFrame.inverse().applying(linked.input[index]);surface.inputWarp=source
            }
        }
        surface.bezierWarp=output;result.surfaces[surfaceIndex]=surface
        try ProjectStore.validate(result);return result
    }

    public static func applyingWorldTransform(surfaceID: UUID,transform delta: Affine2D,in project: Project) throws -> Project {
        guard let index=editableIndex(surfaceID,in:project) else {return project}
        try delta.validate()
        let group=try GroupEngine.worldTransform(for:project.surfaces[index].groupID,groups:project.groups)
        let local=try group.inverse().concatenating(delta).concatenating(group)
        var result=project,surface=result.surfaces[index]
        let cageWeights=surface.output.map {local.px*$0.x+local.py*$0.y+local.pw}
        guard cageWeights.allSatisfy({$0>1e-12}) || cageWeights.allSatisfy({$0 < -1e-12}) else {
            throw ProjectError.invalid("surface transform crosses the cage horizon")
        }
        surface.output=try surface.output.map {try local.applying($0)}
        if !surface.mesh.isEmpty {
            guard SurfaceWarpGeometry.validRegularMesh(surface) else {throw ProjectError.invalid("invalid surface mesh") }
            let weights=surface.mesh.enumerated().map {index,point in
                (surface.meshWeights.isEmpty ? 1 : surface.meshWeights[index])*(local.px*point.x+local.py*point.y+local.pw)
            }
            guard weights.allSatisfy({$0>1e-12}) || weights.allSatisfy({$0 < -1e-12}),let scale=weights.map(abs).max(),scale>1e-12 else {
                throw ProjectError.invalid("surface transform crosses the mesh horizon")
            }
            let normalized=weights.map {abs($0)/scale}
            surface.meshWeights=normalized.allSatisfy({abs($0-1)<1e-14}) ? [] : normalized
            surface.mesh=try surface.mesh.map {try local.applying($0)}
        }
        if surface.bezierWarp != nil {surface.warpTransform=local.concatenating(surface.warpTransform)}
        result.surfaces[index]=surface;try ProjectStore.validate(result);return result
    }

    /// Cage edits carry the existing lattice through the old-to-new homography.
    /// Output points are in world canvas coordinates; input points are source UV.
    /// With the link disabled the opposite geometry remains bit-for-bit unchanged.
    public static func editingCage(surfaceID: UUID,points: [Point2],input: Bool,in project: Project) throws -> Project {
        guard let index=editableIndex(surfaceID,in:project) else {return project}
        try ProjectStore.validate(project)
        try Geometry.validateQuad(points)
        guard points.allSatisfy(SurfaceWarpGeometry.finite) else {throw ProjectError.invalid("cage edit exceeds the finite working range")}
        let surface=project.surfaces[index]
        let parent=try GroupEngine.worldTransform(for:surface.groupID,groups:project.groups)
        let worldCage=try surface.output.map {try parent.applying($0)}
        let oldCage=input ? surface.input : worldCage
        if points==oldCage {return project}
        let delta=try transform(from:oldCage,to:points)
        var result=project
        if input {
            if surface.meshLinked {
                let sourceToWorld=try transform(from:surface.input,to:worldCage)
                let worldDelta=try sourceToWorld.concatenating(delta).concatenating(sourceToWorld.inverse())
                result=try applyingWorldTransform(surfaceID:surfaceID,transform:worldDelta,in:result)
            }
            try applySourceTransform(delta,to:&result.surfaces[index])
            result.surfaces[index].input=points
        } else {
            result=try applyingWorldTransform(surfaceID:surfaceID,transform:delta,in:result)
            // Carry the lattice through H, but store the explicitly supplied
            // cage rather than a numerically round-tripped copy of its corners.
            let inverse=try parent.inverse()
            result.surfaces[index].output=try points.map {try inverse.applying($0)}
            if surface.meshLinked {
                let worldToSource=try transform(from:worldCage,to:surface.input)
                let sourceDelta=try worldToSource.concatenating(delta).concatenating(worldToSource.inverse())
                try applySourceTransform(sourceDelta,to:&result.surfaces[index])
            }
        }
        try ProjectStore.validate(result)
        return result
    }

    private static func applySourceTransform(_ delta: Affine2D,to surface: inout Surface) throws {
        try delta.validate()
        let weights=(surface.input+surface.inputMesh).map {delta.px*$0.x+delta.py*$0.y+delta.pw}
        guard weights.allSatisfy({$0>1e-12}) || weights.allSatisfy({$0 < -1e-12}) else {
            throw ProjectError.invalid("source cage transform crosses the mesh horizon")
        }
        surface.input=try surface.input.map {try delta.applying($0)}
        surface.inputMesh=try surface.inputMesh.map {try delta.applying($0)}
        if surface.inputWarp != nil {surface.inputWarpTransform=delta.concatenating(surface.inputWarpTransform)}
    }

    public static func addingFreehand(points: [Point2],name: String = "Freehand",in project: Project,tolerance: Double = 0.001) throws -> (project: Project,surfaceID: UUID) {
        let samples=try FreehandPath.fit(points:points,tolerance:tolerance)
        let minX=samples.map(\.x).min()!-0.01,maxX=samples.map(\.x).max()!+0.01
        let minY=samples.map(\.y).min()!-0.01,maxY=samples.map(\.y).max()!+0.01
        let nodes=samples.map {StrokeNode(anchor:Point2(($0.x-minX)/(maxX-minX),($0.y-minY)/(maxY-minY)))}
        var surface=Surface(name:name,output:[Point2(minX,minY),Point2(maxX,minY),Point2(maxX,maxY),Point2(minX,maxY)],generator:"solid",shape:.line)
        surface.stroke=StrokePath(nodes:nodes,width:0.08)
        var result=project;result.surfaces.append(surface);try ProjectStore.validate(result)
        return (result,surface.id)
    }

    private static func editableIndex(_ id: UUID,in project: Project) -> Int? {
        guard !project.geometryLockedSurfaceIDs.contains(id) else {return nil}
        return project.surfaces.firstIndex(where:{$0.id==id})
    }
    private static func transform(from source: [Point2],to target: [Point2]) throws -> Affine2D {
        let h=try Homography.solve(from:source,to:target).values
        return Affine2D(a:h[0],b:h[3],c:h[1],d:h[4],tx:h[2],ty:h[5],px:h[6],py:h[7],pw:h[8])
    }
}
