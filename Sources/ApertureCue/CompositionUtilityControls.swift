#if os(macOS)
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import MappingCore

enum SVGImageRenderer {
    /// Renders the declared imported subset, retaining compound subpaths/rules.
    static func bitmap(_ document:SVGDocument,maximumDimension:Int=1024) throws -> NSBitmapImageRep {
        try SVGImport.validate(document)
        guard (16...4096).contains(maximumDimension),document.viewBox.count==4 else {throw ProjectError.invalid("invalid SVG raster dimensions")}
        let aspect=document.viewBox[2]/document.viewBox[3]
        guard aspect.isFinite,(1.0/4096...4096).contains(aspect) else {throw ProjectError.invalid("SVG raster aspect ratio must be within 1:4096…4096:1")}
        let width=max(1,aspect>=1 ? maximumDimension : Int((Double(maximumDimension)*aspect).rounded()))
        let height=max(1,aspect>=1 ? Int((Double(maximumDimension)/aspect).rounded()) : maximumDimension)
        let layerDepth=document.shapes.map { $0.opacityGroups.count }.max() ?? 0
        guard (layerDepth+3)*width*height*4<=256*1024*1024 else {throw ProjectError.invalid("SVG transparency layers exceed the 256 MiB raster working budget; use a smaller raster size")}
        guard let rgbSpace=CGColorSpace(name:CGColorSpace.sRGB),let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,
                                          hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32),
              let bytes=bitmap.bitmapData,
              let context=CGContext(data:bytes,width:width,height:height,bitsPerComponent:8,bytesPerRow:bitmap.bytesPerRow,
                                    space:rgbSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ProjectError.invalid("could not create SVG raster context")
        }
        context.clear(CGRect(x:0,y:0,width:width,height:height))
        context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
        func point(_ p:Point2)->CGPoint {CGPoint(x:p.x*Double(width),y:p.y*Double(height))}
        func color(_ rgba:[Double])->CGColor {CGColor(colorSpace:rgbSpace,components:rgba.map {CGFloat($0)})!}
        var opacityGroups:[SVGOpacityGroup]=[]
        for shape in document.shapes {
            var shared=0
            while shared<opacityGroups.count,shared<shape.opacityGroups.count,opacityGroups[shared]==shape.opacityGroups[shared] {shared+=1}
            while opacityGroups.count>shared {context.endTransparencyLayer();context.restoreGState();opacityGroups.removeLast()}
            for group in shape.opacityGroups.dropFirst(shared) {
                context.saveGState();context.setAlpha(group.opacity);context.beginTransparencyLayer(auxiliaryInfo:nil);context.setAlpha(1)
                opacityGroups.append(group)
            }
            let path=CGMutablePath()
            for subpath in shape.paths {
                guard let first=subpath.nodes.first else {continue};path.move(to:point(first.anchor))
                let segments=subpath.closed ? subpath.nodes.count : max(0,subpath.nodes.count-1)
                for i in 0..<segments {
                    let a=subpath.nodes[i],b=subpath.nodes[(i+1)%subpath.nodes.count]
                    path.addCurve(to:point(b.anchor),control1:point(a.outgoing),control2:point(b.incoming))
                }
                if subpath.closed {path.closeSubpath()}
            }
            if let fill=shape.fill {
                context.addPath(path);context.setFillColor(color(fill));context.fillPath(using:shape.fillRule == .evenOdd ? .evenOdd : .winding)
            }
            if let stroke=shape.stroke,shape.strokeWidth>0 {
                context.addPath(path);context.setStrokeColor(color(stroke));context.setLineWidth(shape.strokeWidth*Double(height))
                context.setLineCap(shape.lineCap=="round" ? .round : (shape.lineCap=="square" ? .square : .butt))
                context.setLineJoin(shape.lineJoin=="round" ? .round : (shape.lineJoin=="bevel" ? .bevel : .miter))
                context.setMiterLimit(shape.miterLimit);context.strokePath()
            }
        }
        while !opacityGroups.isEmpty {context.endTransparencyLayer();context.restoreGState();opacityGroups.removeLast()}
        guard let tagged=bitmap.retagging(with:NSColorSpace.sRGB) else {throw ProjectError.invalid("could not tag SVG raster as sRGB")}
        return tagged
    }
}

extension EditorController {
    func importSVG() {
        let generation=documentGeneration,selected=selectedID
        let panel=NSOpenPanel();panel.allowedContentTypes=[.svg];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url,generation==documentGeneration,selected==selectedID else {return}
        do {
            let handle=try FileHandle(forReadingFrom:url);defer {try? handle.close()}
            let data=try handle.read(upToCount:SVGImport.maximumBytes+1) ?? Data()
            _ = try importSVG(data:data,name:url.deletingPathExtension().lastPathComponent)
        } catch {showError(error)}
    }

    /// A persistent PNG asset, not a temporary renderer override. Tests may use
    /// a private destination; production imports live in application support.
    @discardableResult
    func importSVG(data:Data,name:String,directory:URL?=nil,maximumDimension:Int=1024) throws -> UUID {
        let document=try SVGImport.parse(data)
        let bitmap=try SVGImageRenderer.bitmap(document,maximumDimension:maximumDimension)
        guard let png=bitmap.representation(using:.png,properties:[:]) else {throw ProjectError.invalid("could not encode imported SVG image")}
        guard name.utf8.count<=4096 else {throw ProjectError.invalid("SVG name is too long")}
        let parent=try directory ?? FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("ApertureCue/ImportedSVG",isDirectory:true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let id=UUID(),folder=parent.appendingPathComponent(id.uuidString,isDirectory:true),url=folder.appendingPathComponent("image.png")
        let asset=MediaAsset(id:id,name:name+".svg → PNG",path:url.path,kind:"image")
        var candidate=project;candidate.assets.append(asset)
        let target:UUID
        if let i=selectedIndex {candidate.surfaces[i].mediaID=id;candidate.surfaces[i].feedbackOutputID=nil;target=candidate.surfaces[i].id}
        else {let surface=Surface(name:name,mediaID:id);candidate.surfaces.append(surface);target=surface.id}
        try ProjectStore.validate(candidate)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        do {try png.write(to:url,options:.atomic)} catch {try? FileManager.default.removeItem(at:folder);throw error}
        mutate("Import SVG") {$0=candidate}
        selectedMediaID=id;selectedID=target;refresh()
        return id
    }

    @discardableResult
    func createVideoWall(_ configuration:VideoWallConfiguration) throws -> [UUID] {
        guard let index=selectedIndex else {throw ProjectError.invalid("select a source surface before creating a video wall")}
        let source=project.surfaces[index],tiles=try VideoWall.tiles(configuration)
        let sourceMap=try Homography.solve(from:Point2.unitQuad,to:source.input)
        var candidate=project,newIDs:[UUID]=[],firstSurface:UUID?
        candidate.surfaces[index].enabled=false
        for tile in tiles {
            var output=OutputConfig(name:"Wall \(tile.row+1) / \(tile.column+1)")
            output.edgeBlend=tile.edgeBlend;candidate.outputs.append(output);newIDs.append(output.id)
            var surface=source;surface.id=UUID();surface.name="\(source.name) · \(tile.row+1)/\(tile.column+1)"
            surface.input=try tile.input.map {try sourceMap.applying($0)};surface.output=tile.output
            surface.outputID=output.id;surface.groupID=nil;surface.group="";surface.shape = .quad
            surface.mesh=[];surface.meshColumns=0;surface.meshRows=0;surface.inputMesh=[];surface.meshWeights=[];surface.meshLinked=false
            surface.bezierWarp=nil;surface.inputWarp=nil;surface.warpTransform = .identity;surface.inputWarpTransform = .identity
            surface.mask=[];surface.masks=[];surface.maskSettings = .init();surface.feather=0
            surface.stroke = .line;surface.triangleVertices=TriangleGeometry.canonical
            candidate.surfaces.append(surface);if firstSurface==nil {firstSurface=surface.id}
        }
        try ProjectStore.validate(candidate)
        overlay.finishDrag();mutate("Create video wall") {$0=candidate}
        selectedID=firstSurface;refresh();return newIDs
    }

    func configureVideoWall() {
        guard let index=selectedIndex else {showError(ProjectError.invalid("select a source surface before creating a video wall"));return}
        let generation=documentGeneration,source=project.surfaces[index]
        let cols=ActionField("2",action:{_ in}),rows=ActionField("1",action:{_ in})
        let bx=ActionField("0",action:{_ in}),by=ActionField("0",action:{_ in}),ox=ActionField("0",action:{_ in}),oy=ActionField("0",action:{_ in})
        let controls=[cols,rows,bx,by,ox,oy]
        let view=stack([label("Columns / rows · at most 64 outputs"),stack([cols,rows],vertical:false),
                        label("Source bezel gaps x / y (0…0.25)"),stack([bx,by],vertical:false),
                        label("Projector overlap x / y (0…0.5, no bezel on same axis)"),stack([ox,oy],vertical:false)])
        view.frame=NSRect(x:0,y:0,width:440,height:190)
        for field in controls {field.widthAnchor.constraint(equalToConstant:210).isActive=true}
        let alert=NSAlert();alert.messageText="Video wall from selected source"
        alert.informativeText="Create cropped tile clones and new unassigned outputs, and hide the original source in one Undo step. Source color/material/media are retained; tile geometry/groups/masks reset. Assign fullscreen displays explicitly in Outputs."
        alert.accessoryView=view;alert.addButton(withTitle:"Create wall");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {return}
        do {
            guard generation==documentGeneration,let current=selectedIndex,project.surfaces[current]==source else {throw ProjectError.invalid("source changed while configuring wall; reopen the dialog")}
            guard let columns=Int(cols.stringValue),let countRows=Int(rows.stringValue),
                  let bezelX=Double(bx.stringValue),let bezelY=Double(by.stringValue),let overlapX=Double(ox.stringValue),let overlapY=Double(oy.stringValue) else {
                throw ProjectError.invalid("enter valid wall counts and finite fractions")
            }
            try createVideoWall(.init(columns:columns,rows:countRows,bezelX:bezelX,bezelY:bezelY,overlapX:overlapX,overlapY:overlapY))
        } catch {showError(error)}
    }

    func saveEdgeBlend(outputID:UUID,settings:EdgeBlendSettings) throws {
        try EdgeBlend.validate(settings)
        guard let index=project.outputs.firstIndex(where:{$0.id==outputID}) else {throw ProjectError.invalid("output no longer exists")}
        var candidate=project;candidate.outputs[index].edgeBlend=settings
        try ProjectStore.validate(candidate);mutate("Output edge blend") {$0=candidate}
    }

    func configureEdgeBlend() {
        let generation=documentGeneration,outputs=project.outputs
        guard !outputs.isEmpty else {showError(ProjectError.invalid("create a logical output before editing edge blend"));return}
        let selected=selectedIndex.flatMap {project.surfaces[$0].outputID}.flatMap {id in outputs.firstIndex(where:{$0.id==id})} ?? 0
        let picker=ActionPopUp(items:outputTitles(outputs),selected:selected,action:{_ in})
        let fields=(0..<7).map {_ in ActionField("",action:{_ in})}
        func load(_ index:Int) {
            guard outputs.indices.contains(index) else {return};let s=outputs[index].edgeBlend
            for (field,value) in zip(fields,[s.left,s.right,s.top,s.bottom,s.power,s.gamma,s.blackLevel]) {field.stringValue=String(value)}
        }
        picker.actionBlock=load;load(selected)
        let view=stack([label("Output"),picker,label("Left / right width (0…1)"),stack(Array(fields[0...1]),vertical:false),
                        label("Top / bottom width (0…1)"),stack(Array(fields[2...3]),vertical:false),
                        label("Ramp power / source gamma"),stack(Array(fields[4...5]),vertical:false),label("Black lift (0…1)"),fields[6]])
        view.frame=NSRect(x:0,y:0,width:420,height:270)
        picker.widthAnchor.constraint(equalToConstant:410).isActive=true
        for field in fields {field.widthAnchor.constraint(equalToConstant:200).isActive=true}
        let alert=NSAlert();alert.messageText="Output edge blend"
        alert.informativeText="Widths use normalized output coordinates. Use matching overlap/power on adjacent outputs. Gamma and black lift are manual calibration; no physical projector calibration is implied. Blackout remains black."
        alert.accessoryView=view;alert.addButton(withTitle:"Save output");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {return}
        do {
            let index=picker.indexOfSelectedItem
            guard generation==documentGeneration,outputs.indices.contains(index),project.outputs.contains(outputs[index]) else {throw ProjectError.invalid("output changed while editing; reopen edge blend")}
            let v=try fields.map {field -> Double in guard let value=Double(field.stringValue),value.isFinite else {throw ProjectError.invalid("enter finite blend values")};return value}
            try saveEdgeBlend(outputID:outputs[index].id,settings:.init(left:v[0],right:v[1],top:v[2],bottom:v[3],power:v[4],gamma:v[5],blackLevel:v[6]))
        } catch {showError(error)}
    }
}
#endif
