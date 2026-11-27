#if os(macOS)
import AppKit
import MetalKit
import UniformTypeIdentifiers
import AVFoundation
import MappingCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: EditorController!
    var waitingForTermination = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        editor = EditorController(); editor.showWindow(nil)
        installMenu()
        let arguments = Array(CommandLine.arguments.dropFirst())
        let armSchedule = arguments.contains("--arm-schedule")
        if let path = arguments.first(where: { $0 != "--arm-schedule" }), !path.hasPrefix("--") {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            editor.openProject(url)
            if armSchedule, editor.projectURL == url {
                do { try editor.setShowScheduleArmed(true, at: Date()) }
                catch { editor.workMessage = error.localizedDescription; editor.refresh() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        editor?.reconcileOutputWindows()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard editor.confirmDiscard() else { return .terminateCancel }
        editor.showRuntime.pause()
        editor.resetShowControlSessions()
        editor.media.reset()
        editor.montagePool.reset()
        editor.resetControlMappings()
        waitingForTermination = true
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.waitingForTermination else { return }
            self.waitingForTermination = false; sender.reply(toApplicationShouldTerminate:true)
        }
        editor.lighting.stop(completion:finish)
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { finish() }
        return .terminateLater
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let file = filenames.first { editor.openProject(URL(fileURLWithPath: file)) }
    }
    private func item(_ name: String, _ selector: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: name, action: selector, keyEquivalent: key); i.target = target ?? editor; return i
    }
    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenu(); app.addItem(item("About ApertureCue", #selector(EditorController.about), "")); app.addItem(.separator())
        app.addItem(item("Quit ApertureCue", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        let file = NSMenu(); file.addItem(item("New Project", #selector(EditorController.newProject), "n"))
        file.addItem(item("Open…", #selector(EditorController.openDialog), "o")); file.addItem(item("Save", #selector(EditorController.save), "s"))
        file.addItem(item("Save As…", #selector(EditorController.saveAs), "S")); file.addItem(.separator())
        file.addItem(item("Import Media…", #selector(EditorController.importMedia), "i")); file.addItem(item("Import Image Sequence…", #selector(EditorController.importSequence), "")); file.addItem(item("Export PNG…", #selector(EditorController.exportPNG), "e"))
        file.addItem(item("Import projected OBJ…", #selector(EditorController.importOBJ), ""))
        file.addItem(item("Collect portable project…", #selector(EditorController.collectProject), ""))
        let edit = NSMenu(); edit.addItem(item("Undo", #selector(EditorController.undoEdit), "z")); edit.addItem(item("Redo", #selector(EditorController.redoEdit), "Z"))
        edit.addItem(.separator()); edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x", target: nil)); edit.items.last?.target = nil
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c", target: nil)); edit.items.last?.target = nil
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v", target: nil)); edit.items.last?.target = nil
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil)); edit.items.last?.target = nil
        let show = NSMenu()
        show.addItem(item("Conductor…", #selector(EditorController.showConductor), ""))
        show.addItem(item("Schedule…", #selector(EditorController.openShowSchedule), ""))
        show.addItem(item("OSC / MIDI Tracks and Clock…", #selector(EditorController.openShowControlTools), ""))
        show.addItem(item("Control mappings…", #selector(EditorController.configureControl), ""))
        show.addItem(item("Lighting network…", #selector(EditorController.showLightingNetwork), ""))
        for (title, submenu) in [("ApertureCue",app),("File",file),("Edit",edit),("Show",show)] {
            let i = NSMenuItem(); i.title = title; i.submenu = submenu; menu.addItem(i)
        }
        NSApp.mainMenu = menu
    }
}

@MainActor final class EditorController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var project = Project.demo()
    var projectURL: URL?
    var recoveryBaseline:RecoveryBaseline?
    var recoveryDecision:((RecoveryStatus)->Bool)?
    var sourceWindow:MediaSourceWindow?
    var documentGeneration = UUID()
    var workMessage = ""
    var selectedID: UUID?
    var selectedMediaID: UUID?
    var selectedGroupID: UUID?
    var resolvedBaseSurfaces: [Surface] = []
    var renderError = ""
    var editError = ""
    var dirty = false
    let history = EditHistory()
    let showRuntime = ShowRuntime()
    let conductorRuntime = ConductorRuntime()
    var conductorWindow: ConductorWindow?
    var conductorHostTime = ProcessInfo.processInfo.systemUptime
    let showScheduleRuntime = ShowScheduleRuntime()
    var showScheduleWindow: ShowScheduleWindow?
    let showControlSession = NativeShowControlSession()
    let recording = AutomationRecordingState()
    var timelineWindow: TimelineWindowController?
    var cueWindow: CueWindowController?
    var cueMessage = ""
    var showConfigurationError = ""
    var timelineEventWarning = ""
    var montageWindow: MontageWindowController?
    var montagePool: MontagePool!
    var montageSerial: UInt64 = 0
    var media: MediaPool!
    var renderer: MetalRenderer!
    let metalView = MTKView()
    let overlay = CanvasOverlay()
    let layerTable = NSTableView(), mediaTable = NSTableView()
    let inspector = FlippedStackView()
    let status = label("Starting Metal…", size: 11)
    let timeLabel = label("00:00 / 00:00", size: 11)
    var seekSlider: ActionSlider!
    var modePicker: ActionPopUp!
    var cuePicker: ActionPopUp!
    var playButton: ActionButton!
    var outputWindows: [ProjectionWindowKey: (ProjectionWindow, MetalRenderer, displayUUID: UUID?)] = [:]
    var outputMessage = ""
    var timer: Timer?
    var dragBefore: Project?
    var cueFrom: [Surface] = [], cueTarget: Cue?, cueStart: Double = 0
    let cueEngine = CueEngine()
    var cueBefore: Project?
    var lastRecovery: Double = 0
    var network: NetworkController?
    var midi: MIDIControlAdapter?
    let controlMapping = ControlMappingSession()
    var lighting: LightingController!
    var lightingView: MTKView!
    var feedback:FeedbackComposition?
    var lastLighting: Double = 0
    var effectiveSurfaces: [Surface] {
        do {
            guard showConfigurationError.isEmpty else { throw ProjectError.invalid(showConfigurationError) }
            let master = try showRuntime.apply(surfaces: project.surfaces)
            let conducted = try conductorRuntime.apply(to: master, hostTime: conductorHostTime, showTime: showRuntime.time)
            let timed = applyRecordingOverride(to: conducted)
            let resolved = try GroupEngine.resolveForComposition(surfaces:montagePool.apply(to:timed),groups:project.groups)
            renderError = ""; return resolved
        } catch {
            renderError = "Group/automation: \(error.localizedDescription)"
            return []
        }
    }
    var blackout = false
    var baseURL: URL { projectURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true) }
    var selectedIndex: Int? { project.surfaces.firstIndex { $0.id == selectedID } }
    var editableGeometryIndex: Int? {
        guard let i = selectedIndex, !project.geometryLockedSurfaceIDs.contains(project.surfaces[i].id) else { return nil }
        return i
    }
    var inputMode: Bool { modePicker?.indexOfSelectedItem == 1 }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 870), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        super.init(window: window); window.minSize = NSSize(width: 1050, height: 700); window.center(); window.delegate = self
        selectedID = project.surfaces.first?.id
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("ApertureCue requires Metal") }
        metalView.device = device; media = MediaPool(device: device)
        montagePool = MontagePool(device:device,media:media); media.virtualSources = montagePool
        renderer = MetalRenderer(view: metalView, media: media)
        feedback=FeedbackComposition(media:media)
        feedback?.onUpdate = { [weak self] in self?.updateFeedbackTextures() }
        makeUI(); bindOverlay(); reconcile(); refresh(); startTick()
        network = NetworkController(rawOSC: true) { [weak self] command in self?.remote(command) }
        midi = MIDIControlAdapter { [weak self] event in self?.receiveMappedMIDI(event) }
        midi?.onEndpointsChanged = { [weak self] in self?.controlEndpointsChanged() }
        lighting = LightingController(); lightingView = MTKView(frame:.zero,device:device)
        lighting.renderer = MetalRenderer(view:lightingView,media:media); lightingView.isPaused = true
        updateCompositionConfiguration()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func makeUI() {
        guard let content = window?.contentView else { return }
        let brand = label("APERTURECUE", size: 16, bold: true); brand.textColor = .systemCyan
        let top = stack([brand,
            ActionButton("Open…") { [weak self] in self?.openDialog() },
            ActionButton("Save") { [weak self] in self?.save() },
            ActionButton("Import…") { [weak self] in self?.importMedia() },
            ActionButton("Undo") { [weak self] in self?.undoEdit() },
            ActionButton("Redo") { [weak self] in self?.redoEdit() },
            ActionButton("Outputs…") { [weak self] in self?.configureOutputs() },
            ActionButton("Camera…") { [weak self] in self?.addCamera() },
            ActionButton("Groups…") { [weak self] in self?.configureGroups() },
            ActionButton("Timeline…") { [weak self] in self?.showTimelineWindow() },
            ActionButton("LED…") { [weak self] in self?.configureLighting() },
            ActionButton("Blackout") { [weak self] in self?.toggleBlackout() }], vertical: false)
        let left = makeLibrary(); left.widthAnchor.constraint(equalToConstant: 210).isActive = true
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 9; inspector.edgeInsets = NSEdgeInsets(top: 14,left: 12,bottom: 14,right: 12)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        let inspectorScroll = scroll(inspector); inspectorScroll.widthAnchor.constraint(equalToConstant: 265).isActive = true
        inspector.widthAnchor.constraint(equalTo: inspectorScroll.widthAnchor).isActive = true
        let canvas = NSView(); canvas.wantsLayer = true; canvas.layer?.backgroundColor = NSColor.black.cgColor
        // Keep AppKit's drawing cache out of the CAMetalLayer's backing surface.
        // A shared implicit backing can leave black holes after a modal closes.
        overlay.wantsLayer = true; overlay.layer?.backgroundColor = NSColor.clear.cgColor; overlay.layer?.isOpaque = false
        fill(metalView, in: canvas); fill(overlay, in: canvas)
        modePicker = ActionPopUp(items:["Output geometry", "Input region"], action: { [weak self] _ in self?.overlay.maskMode = false; self?.overlay.meshMode = false; self?.overlay.pathMode = false; self?.overlay.warpMode=false;self?.overlay.drawMode=false; self?.updateRender(); self?.refreshInspector() })
        let help = label("Drag corners · Shift: snap 5% · Layer order: back → front", size: 11)
        let canvasContainer = NSView(); canvasContainer.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false; canvasContainer.addSubview(canvas)
        let fitWidth = canvas.widthAnchor.constraint(equalTo:canvasContainer.widthAnchor); fitWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([fitWidth,
            canvas.widthAnchor.constraint(lessThanOrEqualTo:canvasContainer.widthAnchor),
            canvas.heightAnchor.constraint(lessThanOrEqualTo:canvasContainer.heightAnchor),
            canvas.heightAnchor.constraint(equalTo:canvas.widthAnchor,multiplier:9.0/16.0),
            canvas.centerXAnchor.constraint(equalTo:canvasContainer.centerXAnchor),
            canvas.centerYAnchor.constraint(equalTo:canvasContainer.centerYAnchor)])
        let center = stack([stack([modePicker,help],vertical:false),canvasContainer]); center.alignment = .leading
        canvasContainer.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true
        canvasContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        let work = stack([left,center,inspectorScroll],vertical:false,spacing:12); work.alignment = .top
        left.heightAnchor.constraint(equalTo:work.heightAnchor).isActive = true
        center.heightAnchor.constraint(equalTo:work.heightAnchor).isActive = true
        inspectorScroll.heightAnchor.constraint(equalTo:work.heightAnchor).isActive = true
        playButton = ActionButton("▶ Play") { [weak self] in self?.togglePlayback() }
        seekSlider = ActionSlider(value: 0,min:0,max:1) { [weak self] value in self?.seekShow(to:value) }
        seekSlider.widthAnchor.constraint(greaterThanOrEqualToConstant:150).isActive = true
        let transport = stack([playButton,ActionButton("Stop") { [weak self] in self?.stopShow() },seekSlider,timeLabel],vertical:false)
        let cueRow = stack([label("SCENES",bold:true),ActionButton("Capture") { [weak self] in self?.captureCue() }],vertical:false)
        let cuesContainer = NSView(); cuePicker = ActionPopUp(items:[], action:{ _ in })
        fill(cuePicker,in:cuesContainer)
        cueRow.addArrangedSubview(cuesContainer); cuesContainer.widthAnchor.constraint(greaterThanOrEqualToConstant:150).isActive = true
        cueRow.addArrangedSubview(ActionButton("GO") { [weak self] in self?.goCue() })
        cueRow.addArrangedSubview(ActionButton("Delete") { [weak self] in self?.deleteCue() })
        cueRow.addArrangedSubview(ActionButton("Scenes…") { [weak self] in self?.showCueWindow() })
        cueRow.addArrangedSubview(ActionButton("Control…") { [weak self] in self?.configureControl() })
        let compositionTools=stack([
            ActionButton("Materials…") {[weak self] in self?.configureMaterial()},
            ActionButton("Key / FX…") {[weak self] in self?.configureEffects()},
            ActionButton("Scoped masks…") {[weak self] in self?.configureScopedMasks()},
            ActionButton("Group composition…") {[weak self] in self?.configureGroupComposition()},
            ActionButton("Group perspective…") {[weak self] in self?.configureGroupPerspective()},
            ActionButton("SVG…") {[weak self] in self?.importSVG()},
            ActionButton("Video wall…") {[weak self] in self?.configureVideoWall()},
            ActionButton("Edge blend…") {[weak self] in self?.configureEdgeBlend()},
            ActionButton("Feedback…") {[weak self] in self?.configureFeedback()}],vertical:false,spacing:6)
        let root = stack([top,compositionTools,work,transport,cueRow,status],spacing:10)
        root.edgeInsets = NSEdgeInsets(top:12,left:14,bottom:12,right:14); fill(root,in:content)
        for v in [top,compositionTools,work,transport,cueRow,status] { v.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-28).isActive = true }
        top.heightAnchor.constraint(equalToConstant:32).isActive = true
        compositionTools.heightAnchor.constraint(equalToConstant:28).isActive=true
        transport.heightAnchor.constraint(equalToConstant:28).isActive = true
        cueRow.heightAnchor.constraint(equalToConstant:28).isActive = true
        work.setContentHuggingPriority(.defaultLow,for:.vertical)
        canvasContainer.setContentHuggingPriority(.defaultLow,for:.vertical)
        center.setContentHuggingPriority(.defaultLow,for:.horizontal)
    }
    private func makeTable(_ table: NSTableView) -> NSScrollView {
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("name")); column.width = 200
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 27
        table.dataSource = self; table.delegate = self; table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        return scroll(table)
    }
    private func makeLibrary() -> NSView {
        let assets = makeTable(mediaTable), layers = makeTable(layerTable)
        assets.heightAnchor.constraint(equalToConstant:180).isActive = true
        let s = stack([label("MEDIA",bold:true),assets,
            ActionButton("Assign to surface") { [weak self] in self?.assignMedia() },
            ActionButton("Sources…") {[weak self] in self?.showSources()},
            ActionButton("Montage sources…") { [weak self] in self?.showMontageWindow() },
            label("SURFACES · back → front",bold:true),layers,
            stack([ActionButton("+ Quad") { [weak self] in self?.addSurface() },ActionButton("Duplicate") { [weak self] in self?.duplicateSurface() }],vertical:false),
            stack([ActionButton("+ Triangle") { [weak self] in self?.addSurface(shape:.triangle) },ActionButton("+ Ellipse") { [weak self] in self?.addSurface(shape:.ellipse) }],vertical:false),
            stack([ActionButton("+ Line") { [weak self] in self?.addSurface(shape:.line) },ActionButton("+ Bézier") { [weak self] in self?.addSurface(shape:.bezier) }],vertical:false),
            stack([ActionButton("↓") { [weak self] in self?.moveLayer(-1) },ActionButton("↑") { [weak self] in self?.moveLayer(1) },ActionButton("Delete") { [weak self] in self?.deleteSurface() }],vertical:false)])
        for v in [assets,layers] { v.widthAnchor.constraint(equalTo:s.widthAnchor).isActive = true }
        layers.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive = true
        return s
    }
    func numberOfRows(in tableView:NSTableView) -> Int { tableView === layerTable ? project.surfaces.count : project.assets.count + project.montages.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        if tableView === layerTable {
            let s = project.surfaces[row]
            let visible = resolvedBaseSurfaces.first(where:{$0.id == s.id})?.enabled ?? s.enabled
            let prefix = s.groupID.flatMap { id in project.groups.first(where:{$0.id == id})?.name }.map { "[\($0)] " } ?? ""
            let lock = project.geometryLockedSurfaceIDs.contains(s.id) ? " · Locked" : ""
            return label((visible ? "◈ " : "○ ") + prefix + s.name + lock)
        }
        if row >= project.assets.count { return label("▤ " + project.montages[row-project.assets.count].name) }
        let a = project.assets[row]; return label((a.kind == "video" ? "▶ " : "▧ ") + a.name)
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === layerTable, project.surfaces.indices.contains(table.selectedRow) {
            selectedID = project.surfaces[table.selectedRow].id; refreshInspector(); updateRender()
        } else if table === mediaTable {
            let ids = project.assets.map(\.id) + project.montages.map(\.id)
            if ids.indices.contains(table.selectedRow) { selectedMediaID = ids[table.selectedRow] }
        }
    }
    private func bindOverlay() {
        overlay.onNudge = { [weak self] x,y in guard let self else {return};if self.inputMode {self.nudgeInput(dx:x,dy:y)} else {self.nudgeSurface(dx:x,dy:y)} }
        overlay.onFreehand = { [weak self] points in
            guard let self else {return}
            do {try self.createFreehandSurface(points:points)} catch {self.showError(error)}
        }
        overlay.onWarpDrag = { [weak self] id,index,point,input in
            guard let self else {return}
            do {try self.editWarpHandle(surfaceID:id,index:index,world:point,input:input)} catch {self.editError=error.localizedDescription}
        }
        overlay.onSelect = { [weak self] id in self?.selectedID = id; self?.refresh() }
        overlay.onBegin = { [weak self] in
            guard let self, self.editableGeometryIndex != nil else { return }
            self.stopAutomationRecording(reason:"Canvas edit"); self.commitInterruptedCue(); self.dragBefore = self.project
        }
        overlay.onChange = { [weak self] id,points,input,mesh in
            guard let self, self.dragBefore != nil, let i = self.editableGeometryIndex, self.project.surfaces[i].id == id else { return }
            do {
                var edited = self.project.surfaces[i]
                if self.overlay.pathMode && !input && edited.shape.isStroke { try self.editStrokeHandles(surfaceID:id,world:points); return }
                if self.overlay.maskMode { edited.mask = points }
                else if !mesh {
                    self.project=try SurfaceEditing.editingCage(surfaceID:id,points:points,input:input,in:self.project)
                    self.editError="";self.updateRender();return
                } else if input {
                    guard points.count==edited.mesh.count else {throw ProjectError.invalid("input mesh topology changed")}
                    if edited.meshLinked {
                        var output=edited.mesh
                        let previous=edited.inputMesh.isEmpty ? try Geometry.regularMesh(quad:edited.input,columns:edited.meshColumns,rows:edited.meshRows) : edited.inputMesh
                        for vertex in points.indices where points[vertex] != previous[vertex] {
                            output=try MeshLinkGeometry.movingOutputVertex(output:previous,input:output,index:vertex,to:points[vertex],outputQuad:edited.input,inputQuad:edited.output,linked:true).input
                        }
                        edited.mesh=output
                    }
                    edited.inputMesh=points
                } else {
                    let inverse=try GroupEngine.worldTransform(for:edited.groupID,groups:self.project.groups).inverse()
                    let local=try points.map {try inverse.applying($0)}
                    guard local.count==edited.mesh.count,local.allSatisfy({abs($0.x)<=10000 && abs($0.y)<=10000}) else {throw ProjectError.invalid("mesh edit exceeds its topology or finite working range")}
                    if edited.meshLinked {
                        var input=edited.inputMesh.isEmpty ? try Geometry.regularMesh(quad:edited.input,columns:edited.meshColumns,rows:edited.meshRows) : edited.inputMesh
                        for vertex in local.indices where local[vertex] != edited.mesh[vertex] {
                            input=try MeshLinkGeometry.movingOutputVertex(output:edited.mesh,input:input,index:vertex,to:local[vertex],outputQuad:edited.output,inputQuad:edited.input,linked:true).input
                        }
                        edited.inputMesh=input
                    }
                    edited.mesh=local
                }
                self.project.surfaces[i] = edited; self.editError = ""
            } catch { self.editError = error.localizedDescription; return }
            self.updateRender()
        }
        overlay.onTriangleDrag = { [weak self] id,vertex,world in
            guard let self, self.dragBefore != nil, let i = self.editableGeometryIndex,
                  self.project.surfaces[i].id == id, let frame = self.resolvedBaseSurfaces.first(where: { $0.id == id }),
                  frame.shape == .triangle, self.overlay.pathMode, !self.inputMode,
                  frame.triangleVertices.indices.contains(vertex) else { return }
            do {
                var vertices = frame.triangleVertices
                vertices[vertex] = try SurfaceGeometry.localPoint(output:world,surface:frame)
                _ = try TriangleGeometry(vertices:vertices)
                self.project.surfaces[i].triangleVertices = vertices
                self.editError = ""
                self.updateRender()
            } catch { self.editError = error.localizedDescription }
        }
        overlay.onEnd = { [weak self] in
            guard let self, let before = self.dragBefore else { return }
            self.dragBefore = nil
            do {
                try ProjectStore.validate(self.project)
                if before != self.project { self.history.commit(before:before,after:self.project,label:"Move control point"); self.dirty = true }
            } catch { self.project = before; self.editError = error.localizedDescription }
            self.refresh()
        }
    }
    func commitInterruptedCue() {
        if let before = cueBefore, before != project {
            history.commit(before:before,after:project,label:"Recall scene")
            dirty = true; window?.isDocumentEdited = true
        }
        cueTarget = nil; cueBefore = nil; cueEngine.cancel()
    }
    func mutate(_ name:String,_ body:(inout Project)->Void) {
        let before=project,selection=(selectedID,selectedGroupID,selectedMediaID)
        body(&project);let candidate=project;project=before
        do {try ProjectStore.validate(candidate)} catch {
            selectedID=selection.0;selectedGroupID=selection.1;selectedMediaID=selection.2
            editError=error.localizedDescription;refresh();return
        }
        stopAutomationRecording(reason:"Document edit: "+name);commitInterruptedCue()
        guard before != candidate else {return}
        project=candidate;history.commit(before:before,after:candidate,label:name);dirty=true
        reconcile();refresh()
    }
    func editSurface(_ name:String,_ body:(inout Surface)->Void) {
        guard let i = selectedIndex else { return }; mutate(name) { body(&$0.surfaces[i]) }
    }
    func toggleGeometryLock(for id:UUID) {
        guard project.surfaces.contains(where: { $0.id == id }) else { return }
        overlay.finishDrag()
        let locked = project.geometryLockedSurfaceIDs.contains(id)
        if !locked && selectedID == id {
            overlay.maskMode = false; overlay.meshMode = false; overlay.pathMode = false;overlay.warpMode=false;overlay.drawMode=false
        }
        mutate(locked ? "Unlock geometry" : "Lock geometry") { project in
            if locked { project.geometryLockedSurfaceIDs.remove(id) }
            else { project.geometryLockedSurfaceIDs.insert(id) }
        }
    }
    func reconcile() {
        reconcileOutputWindows()
        updateActiveMedia()
        media.reconcile(assets:project.assets,baseURL:baseURL)
        do { try montagePool.reconcile(montages:project.montages,assets:project.assets,baseURL:baseURL) }
        catch { editError=error.localizedDescription }
    }
    func refresh() {
        let currentIDs=Set(project.surfaces.map(\.id))
        recording.armed.formIntersection(Set(project.timeline.filter {$0.enabled && currentIDs.contains($0.surfaceID)}.map(\.id)))
        configureShow(); reconcileShowSchedule(); updateRender()
        layerTable.reloadData(); mediaTable.reloadData(); sourceWindow?.refresh()
        if let i = selectedIndex { layerTable.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
        cuePicker.removeAllItems(); cuePicker.addItems(withTitles:project.cues.map(\.name))
        window?.title = "\(project.name)\(dirty ? " •" : "") — ApertureCue 0.1"
        window?.isDocumentEdited = dirty; refreshInspector(); timelineWindow?.refresh(); cueWindow?.refresh(); montageWindow?.refresh(); conductorWindow?.refresh(); showScheduleWindow?.refresh(); refreshShowControls(); refreshControlMappings()
    }
    func updateRender() {
        updateActiveMedia()
        montagePool.update(time:showRuntime.time,playing:showRuntime.isPlaying,used:Set(project.surfaces.compactMap(\.mediaID)),serial:montageSerial,baseURL:baseURL)
        let effective = effectiveSurfaces
        do { resolvedBaseSurfaces = try GroupEngine.resolve(surfaces:project.surfaces,groups:project.groups) }
        catch { resolvedBaseSurfaces = []; renderError = error.localizedDescription }
        if overlay.maskMode, let i = selectedIndex {
            modePicker.selectItem(at:project.surfaces[i].maskSettings.space == .sourceUV ? 1 : 0)
        }
        if inputMode, let i = selectedIndex {
            var s = project.surfaces[i]; s.input = Point2.unitQuad; s.output = Point2.unitQuad
            s.masks=[];s.effects = .init();s.materialID=nil;s.materialValues=[:];s.groupID=nil
            s.bezierWarp=nil;s.inputWarp=nil;s.inputMesh=[];s.meshWeights=[];s.warpTransform = .identity;s.inputWarpTransform = .identity
            s.shape = .quad; s.mesh = []; s.meshColumns = 0; s.meshRows = 0; s.mask = []; s.feather = 0; s.opacity = 1; s.brightness = 1; s.gamma = 1; s.color = [1,1,1]; s.enabled = true
            renderer.surfaces = [s]
        } else { renderer.surfaces = effective }
        if let i = selectedIndex {
            let shape = project.surfaces[i].shape
            if !shape.isStroke && shape != .triangle { overlay.pathMode=false }
        } else { overlay.pathMode=false }
        overlay.geometryLockedSurfaceIDs = project.geometryLockedSurfaceIDs
        overlay.inputMode = inputMode; overlay.selectedID = selectedID; overlay.surfaces = resolvedBaseSurfaces
        updateCompositionConfiguration()
        renderer.blackout = false
        for (_, value) in outputWindows { value.1.surfaces = effective; value.1.blackout = blackout }
    }
    func refreshInspector() {
        if recording.nativeTracking {recording.pendingInspectorRefresh=true;return}
        recording.sliders.removeAll();recording.labels.removeAll()
        inspector.arrangedSubviews.forEach { inspector.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard let i = selectedIndex else { inspector.addArrangedSubview(label("Select a surface")); return }
        let surface = project.surfaces[i]
        let locked = project.geometryLockedSurfaceIDs.contains(surface.id)
        func add(_ view:NSView) { inspector.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:inspector.widthAnchor,constant:-24).isActive = true }
        func geometryControl(_ control: NSControl) { control.isEnabled = !locked; add(control) }
        func property(_ title:String,_ value:Double,_ min:Double,_ max:Double,_ change:@escaping (inout Surface,Double)->Void) {
            let caption=label(String(format:"%@  %.2f",title,value),size:11);add(caption)
            let parameter=title.lowercased()
            if TimelineEngine.parameters.contains(parameter) {
                recording.labels[parameter]=caption
                add(makeAutomationSlider(title:title,parameter:parameter,surfaceID:surface.id,value:value,min:min,max:max))
            } else {add(ActionSlider(value:value,min:min,max:max) { [weak self] v in self?.editSurface(title) { change(&$0,v) } })}
        }
        add(label("SURFACE",bold:true)); add(ActionField(surface.name) { [weak self] v in self?.editSurface("Rename") { $0.name = v } })
        add(ActionButton(surface.enabled ? "Hide surface" : "Show surface") { [weak self] in self?.editSurface("Visibility") { $0.enabled.toggle() } })
        add(ActionButton(locked ? "Unlock geometry" : "Lock geometry") { [weak self] in self?.toggleGeometryLock(for:surface.id) })
        add(label("Shape · four-corner frame",size:11))
        let shapes: [SurfaceShape] = [.quad,.triangle,.ellipse,.line,.bezier]
        geometryControl(ActionPopUp(items:["Quad","Triangle","Ellipse","Line","Bézier"],selected:shapes.firstIndex(of:surface.shape) ?? 0) { [weak self] v in self?.setSurfaceShape(shapes[v]) })
        if surface.shape == .triangle {
            geometryControl(ActionButton(overlay.pathMode ? "Edit cage corners" : "Edit triangle vertices") { [weak self] in
                guard let self else { return }; self.setShapePointEditing(!self.overlay.pathMode)
            })
            let reset = ActionButton("Reset triangle vertices") { [weak self] in
                guard let self, let i = self.editableGeometryIndex, self.project.surfaces[i].shape == .triangle else { return }
                self.editSurface("Reset triangle vertices") { $0.triangleVertices = TriangleGeometry.canonical }
            }
            reset.isEnabled = !locked && surface.triangleVertices != TriangleGeometry.canonical
            add(reset)
        }
        if surface.shape.isStroke {
            geometryControl(ActionButton(overlay.pathMode ? "Edit cage corners" : "Edit path points") { [weak self] in guard let self else { return }; self.setShapePointEditing(!self.overlay.pathMode) })
            geometryControl(ActionButton("Path nodes…") { [weak self] in self?.configureStroke() })
            add(label(String(format:"Stroke width  %.2f",surface.stroke.width),size:11))
            geometryControl(ActionSlider(value:surface.stroke.width,min:0.001,max:0.5) { [weak self] width in
                guard let self, self.editableGeometryIndex != nil else { return }
                self.editSurface("Stroke width") { $0.stroke.width = width }
            })
        }
        add(label("Generator / fallback",size:11))
        let generators = ["checker","gradient","solid","grid"]
        add(ActionPopUp(items:generators,selected:generators.firstIndex(of:surface.generator) ?? 0) { [weak self] v in self?.editSurface("Generator") { $0.generator = generators[v]; $0.mediaID = nil;$0.feedbackOutputID=nil } })
        let modes = ["normal","add","multiply","screen"]
        add(ActionPopUp(items:modes,selected:modes.firstIndex(of:surface.blendMode) ?? 0) { [weak self] v in self?.editSurface("Blend mode") { $0.blendMode = modes[v] } })
        property("Opacity",surface.opacity,0,1) { $0.opacity = $1 }
        property("Brightness",surface.brightness,0,2) { $0.brightness = $1 }
        property("Gamma",surface.gamma,0.1,4) { $0.gamma = $1 }
        property("Edge feather",surface.feather,0,0.5) { $0.feather = $1 }
        for (c,name) in ["Red","Green","Blue"].enumerated() { property(name,surface.color[c],0,1) { $0.color[c] = $1 } }
        add(label("Parent group",size:11))
        let groupIDs = project.groups.map(\.id), groupNames = groupLabels()
        let groupIndex = surface.groupID.flatMap { groupIDs.firstIndex(of:$0).map { $0+1 } } ?? 0
        add(ActionPopUp(items:["Root / no group"] + project.groups.map { groupNames[$0.id] ?? "Missing group" },selected:groupIndex) { [weak self] index in
            guard let self else { return }
            do { try self.assignSelectedGroup(index == 0 ? nil : groupIDs[index-1]) } catch { self.showError(error) }
        })
        add(ActionButton("Group controls…") { [weak self] in self?.selectedGroupID = surface.groupID; self?.configureGroups() })
        let groupToggle = ActionButton("Toggle entire group") { [weak self] in self?.toggleGroup() }
        groupToggle.isEnabled = surface.groupID != nil; add(groupToggle)
        let outputs = project.outputs
        let outputNames = ["All outputs"] + outputTitles(outputs)
        let outIndex = surface.outputID.flatMap { id in outputs.firstIndex(where:{$0.id == id}).map { $0 + 1 } } ?? 0
        add(ActionPopUp(items:outputNames,selected:outIndex) { [weak self] v in
            guard let self, outputNames.indices.contains(v) else { return }
            let id = v > 0 ? outputs[v-1].id : nil
            if let id, !self.project.outputs.contains(where: { $0.id == id }) { return }
            self.editSurface("Route output") { $0.outputID = id }
        })
        add(label("Geometry",bold:true))
        geometryControl(ActionButton("Transform surface…") {[weak self] in self?.configureSurfaceTransform()})
        geometryControl(ActionButton("Bezier warp…") {[weak self] in self?.configureWarp()})
        geometryControl(ActionButton("Edit output Bezier controls") {[weak self] in self?.setWarpEditing(input:false)})
        geometryControl(ActionButton("Edit input Bezier controls") {[weak self] in self?.setWarpEditing(input:true)})
        geometryControl(ActionButton(surface.meshLinked ? "Mesh link: ON" : "Mesh link: OFF") {[weak self] in
            guard let self else {return};do {try self.toggleMeshLink()} catch {self.showError(error)}
        })
        add(ActionButton("Draw freehand line") {[weak self] in self?.beginFreehand()})
        geometryControl(ActionButton("Reset quad / input") {[weak self] in self?.resetSelectedGeometry()})
        geometryControl(ActionButton("Create 4 × 4 warp mesh") { [weak self] in
            guard let self, self.editableGeometryIndex != nil else { return }
            self.editSurface("Create mesh") { s in s.meshColumns = 4; s.meshRows = 4; s.mesh = (try? Geometry.regularMesh(quad:s.output,columns:4,rows:4)) ?? [];s.bezierWarp=nil;s.inputWarp=nil;s.inputMesh=[];s.meshWeights=[];s.meshLinked=false;s.warpTransform = .identity;s.inputWarpTransform = .identity }
            self.modePicker.selectItem(at:0); self.overlay.warpMode=false; self.overlay.meshMode = true; self.overlay.maskMode = false; self.overlay.pathMode = false; self.updateRender()
        })
        let meshEditing=ActionButton(overlay.meshMode ? "Edit quad corners" : "Edit mesh points") { [weak self] in
            guard let self, self.editableGeometryIndex != nil else { return }
            if self.inputMode,self.project.surfaces[self.editableGeometryIndex!].inputMesh.isEmpty {
                self.editSurface("Prepare input mesh") {s in
                    if !s.mesh.isEmpty {s.inputMesh=(try? Geometry.regularMesh(quad:s.input,columns:s.meshColumns,rows:s.meshRows)) ?? []}
                }
            }
            self.overlay.warpMode=false
            self.overlay.meshMode.toggle()

            self.overlay.maskMode = false; self.overlay.pathMode = false; self.updateRender(); self.refreshInspector()
        }
        meshEditing.isEnabled = !locked && !surface.mesh.isEmpty;add(meshEditing)
        add(label("Polygon mask · this layer",bold:true))
        let spaces = PolygonMaskSpace.allCases
        geometryControl(ActionPopUp(items:["Source UV coordinates", "Output canvas coordinates"],selected:spaces.firstIndex(of:surface.maskSettings.space) ?? 0) { [weak self] index in
            guard spaces.indices.contains(index) else { return }
            self?.setMaskSpace(spaces[index])
        })
        geometryControl(ActionButton(surface.maskSettings.inverted ? "Invert mask: ON" : "Invert mask: OFF") { [weak self] in
            guard let self, self.editableGeometryIndex != nil else { return }
            self.overlay.finishDrag(); self.editSurface("Invert mask") { $0.maskSettings.inverted.toggle() }
        })
        add(label(String(format:"Mask feather  %.3f",surface.maskSettings.feather),size:11))
        geometryControl(ActionSlider(value:surface.maskSettings.feather,min:0,max:0.5) { [weak self] value in
            guard let self, self.editableGeometryIndex != nil else { return }
            self.editSurface("Mask feather") { $0.maskSettings.feather = value }
        })
        geometryControl(ActionButton(surface.mask.isEmpty ? "Add polygon mask" : "Edit polygon mask") { [weak self] in self?.editPolygonMask() })
        let maskVertices=ActionButton("Mask vertices…") { [weak self] in self?.configureMaskVertices() }
        geometryControl(maskVertices); maskVertices.isEnabled = !locked && !surface.mask.isEmpty
        if !surface.mask.isEmpty { add(label("\(surface.mask.count) mask vertices · 3…128",size:11)) }
        geometryControl(ActionButton("Remove mask") { [weak self] in
            guard let self, self.editableGeometryIndex != nil else { return }
            self.overlay.finishDrag(); self.overlay.maskMode = false; self.editSurface("Remove mask") { $0.mask = [] }
        })
        if let a = project.assets.first(where:{$0.id == surface.mediaID}) {
            add(label("MEDIA · \(a.name)",size:11,bold:true))
            let loops=MediaPlayback.effectiveSettings(a).mode == .loop
            add(ActionButton(loops ? "Loop: ON" : "Loop: OFF") { [weak self] in self?.mutate("Loop") { p in
                if let aIndex=p.assets.firstIndex(where:{$0.id==a.id}) {
                    if var settings=p.assets[aIndex].playback {settings.mode=loops ? .once : .loop;p.assets[aIndex].playback=settings}
                    else {p.assets[aIndex].loop.toggle()}
                }
            } })
            add(ActionSlider(value:a.volume,min:0,max:1) { [weak self] value in self?.mutate("Volume") { p in if let aIndex = p.assets.firstIndex(where:{$0.id == a.id}) { p.assets[aIndex].volume = value } } })
            add(ActionButton("Source playback / routing…") {[weak self] in self?.selectedMediaID=a.id;self?.sourceWindow?.close();self?.sourceWindow=nil;self?.showSources()})
            if a.kind != "camera" { add(ActionButton("Relink media…") { [weak self] in self?.relink(a.id) }) }
        }
        if let montage=project.montages.first(where:{$0.id==surface.mediaID}) {
            add(label("MONTAGE · " + montage.name,size:11,bold:true))
            add(ActionButton("Edit montage…") { [weak self] in self?.showMontageWindow(); self?.montageWindow?.selectMontage(id:montage.id) })
        }
        updateRecordingInspector()
    }
    @objc func newProject() {
        stopAutomationRecording(reason:"New project")
        guard confirmDiscard() else { return }; resetShowControlSessions(); resetControlMappings(); resetAutomationRecording(); closeOutputs(); project = Project(name:"Untitled",surfaces:[Surface()],outputs:[OutputConfig()]); projectURL = nil; recoveryBaseline=nil; sourceWindow?.close();sourceWindow=nil;media.reset();workMessage=""
        history.clear(); cueEngine.cancel(); cueTarget = nil; cueBefore = nil; selectedMediaID = nil; selectedGroupID = nil; editError = ""; overlay.maskMode = false; overlay.meshMode = false; overlay.pathMode = false;overlay.warpMode=false;overlay.drawMode=false; documentGeneration = UUID();feedback?.reset()
        lighting?.stop(); selectedID = project.surfaces.first?.id; dirty = false; showRuntime.stop(); media.pause(); media.seek(to:0); montageWindow?.close(); montageWindow=nil; montagePool.reset(); montageSerial &+= 1; timelineWindow?.close(); timelineWindow=nil; cueWindow?.close(); cueWindow=nil; cueMessage=""; reconcile(); refresh()
    }
    @objc func openDialog() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { openProject(url) }
    }
    func openProject(_ url:URL) {
        stopAutomationRecording(reason:"Open project")
        guard confirmDiscard() else { return }
        do {
            let loadedRevision=try ProjectStore.loadWithRecoveryBaseline(from:url)
            let baseline=loadedRevision.baseline
            var loaded=loadedRevision.project
            var recovered=false
            let recovery=ProjectStore.recoveryStatus(for:url)
            var recoveryMessage=""
            if recovery.state == .available {
                let restore:Bool
                if let decision=recoveryDecision {restore=decision(recovery)}
                else {
                    let alert=NSAlert();alert.messageText="Recovery snapshot found";alert.informativeText="Restore the autosaved state bound to this saved project revision?";alert.addButton(withTitle:"Restore");alert.addButton(withTitle:"Use saved project")
                    restore=alert.runModal() == .alertFirstButtonReturn
                }
                if restore {
                    do {loaded=try ProjectStore.loadRecovery(for:url);recovered=true}
                    catch {recoveryMessage="Recovery not restored: "+error.localizedDescription}
                }
            } else if recovery.state != .missing {recoveryMessage=recovery.diagnostic}
            guard baseline == (try ProjectStore.captureRecoveryBaseline(for:url)) else {throw ProjectError.invalid("saved project changed during opening; retry")}
            resetShowControlSessions();resetControlMappings();resetAutomationRecording();media.reset();sourceWindow?.close();sourceWindow=nil
            closeOutputs(); lighting?.stop(); showRuntime.stop(); media.pause(); media.seek(to:0); montageWindow?.close(); montageWindow=nil; montagePool.reset(); montageSerial &+= 1; timelineWindow?.close(); timelineWindow=nil; cueWindow?.close(); cueWindow=nil; cueMessage=""; history.clear(); cueEngine.cancel(); cueTarget = nil; cueBefore = nil; selectedMediaID = nil; selectedGroupID = nil; editError = ""; overlay.maskMode = false; overlay.meshMode = false; overlay.pathMode = false;overlay.warpMode=false;overlay.drawMode=false; documentGeneration = UUID();feedback?.reset(); project = loaded; projectURL = url; recoveryBaseline=baseline; dirty = false; selectedID = loaded.surfaces.first?.id
            dirty=recovered;workMessage=recoveryMessage
            reconcile(); refresh()
        } catch { showError(error) }
    }
    @objc func save() { if let url = projectURL { saveTo(url) } else { saveAs() } }
    @objc func saveAs() {
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = "\(project.name).aperturecue.json"
        if p.runModal() == .OK, let url = p.url { saveTo(url) }
    }
    func saveTo(_ url:URL) {
        stopAutomationRecording(reason:"Saved")
        do {
            let oldBaseline=projectURL?.standardizedFileURL==url.standardizedFileURL ? recoveryBaseline : nil
            let savedBaseline=try ProjectStore.saveWithRecoveryBaseline(project,to:url)
            if oldBaseline != nil {_=try? ProjectStore.removeRecovery(for:url,baseline:oldBaseline)}
            recoveryBaseline=savedBaseline
            projectURL=url;dirty=false;reconcile();refresh()
        } catch {showError(error)}
    }
    func confirmDiscard() -> Bool {
        stopAutomationRecording(reason:"Document close")
        guard dirty else { return true }
        let a = NSAlert(); a.messageText = "Save changes to \(project.name)?"; a.addButton(withTitle:"Save"); a.addButton(withTitle:"Cancel"); a.addButton(withTitle:"Discard")
        switch a.runModal() { case .alertFirstButtonReturn: save(); return !dirty; case .alertSecondButtonReturn: return false; default: return discardChanges() }
    }
    func discardChanges()->Bool {
        do {
            if let url=projectURL {_=try ProjectStore.removeRecovery(for:url,baseline:recoveryBaseline)}
            return true
        } catch {workMessage="Recovery could not be discarded: "+error.localizedDescription;return false}
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if sender === window { return confirmDiscard() }; return true }
    @objc func undoEdit() { stopAutomationRecording(reason:"Undo"); commitInterruptedCue(); if let p = history.undo(current:project) { project = p; dirty = true; reconcile(); refresh() } }
    @objc func redoEdit() { stopAutomationRecording(reason:"Redo"); commitInterruptedCue(); if let p = history.redo(current:project) { project = p; dirty = true; reconcile(); refresh() } }
    @objc func importMedia() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = [.image,.movie,.video,.audio]
        guard p.runModal() == .OK else { return }
        importMediaFiles(p.urls)
    }
    func importMediaFiles(_ urls:[URL]) {
        mutate("Import media") { state in
            for url in urls {
                let ext = url.pathExtension.lowercased()
                let kind = ["wav","aif","aiff","mp3","aac","m4a","caf","flac"].contains(ext) ? "audio" : (["mov","mp4","m4v","avi","mkv","webm"].contains(ext) ? "video" : "image")
                let asset = MediaAsset(name:url.lastPathComponent,path:url.path,kind:kind); state.assets.append(asset)
                if let i = state.surfaces.firstIndex(where:{$0.id == selectedID}) { state.surfaces[i].mediaID = asset.id;state.surfaces[i].feedbackOutputID=nil }
                else { let s = Surface(name:url.deletingPathExtension().lastPathComponent,mediaID:asset.id); state.surfaces.append(s); selectedID = s.id }
            }
        }
    }
    func relink(_ id:UUID) {
        let p = NSOpenPanel();p.canChooseDirectories=project.assets.first(where:{$0.id==id})?.kind=="sequence";p.canChooseFiles = !p.canChooseDirectories
        guard p.runModal() == .OK, let url = p.url else { return }
        let previousPath = project.assets.first(where: { $0.id == id })?.path
        mutate("Relink media") { state in if let i = state.assets.firstIndex(where:{$0.id == id}) { state.assets[i].path = url.path; state.assets[i].name = url.lastPathComponent } }
        if previousPath == url.path { montagePool.invalidateAsset(id); media.reloadAsset(id:id,assets:project.assets,baseURL:baseURL); refresh() }
    }
    func assignMedia() { guard let id = selectedMediaID else { return }; editSurface("Assign media") { $0.mediaID = id;$0.feedbackOutputID=nil } }
    func addSurface(shape:SurfaceShape = .quad) {
        mutate("Add surface") { p in
            var s = Surface(name:"\(shape == .quad ? "Surface" : shape.rawValue.capitalized) \(p.surfaces.count+1)")
            s.shape = shape; s.stroke = shape == .bezier ? .bezier : .line; p.surfaces.append(s); selectedID = s.id
        }
        if shape.isStroke { setShapePointEditing(true) }
    }
    func changeSurfaceShape(_ shape:SurfaceShape) throws {
        guard let i=editableGeometryIndex else { return }
        var candidate=project
        if !candidate.surfaces[i].shape.isStroke && shape.isStroke { candidate.surfaces[i].stroke = shape == .bezier ? .bezier : .line }
        candidate.surfaces[i].shape=shape
        try ProjectStore.validate(candidate)
        overlay.pathMode=false
        mutate("Surface shape") { $0=candidate }
    }
    func setSurfaceShape(_ shape:SurfaceShape) {
        do { try changeSurfaceShape(shape) } catch { showError(error) }
    }
    func duplicateSurface() { guard let i = selectedIndex else { return }; mutate("Duplicate surface") { p in var s = p.surfaces[i]; s.id = UUID(); s.name += " copy"; p.surfaces.insert(s,at:i+1); selectedID = s.id } }
    func deleteSurface() {
        guard let i = selectedIndex else { return }
        mutate("Delete surface") { p in
            let id = p.surfaces.remove(at:i).id
            p.geometryLockedSurfaceIDs.remove(id)
            p.timeline.removeAll { $0.surfaceID == id }
            let targets = Set((p.surfaces + p.cues.filter { $0.scope == .full }.flatMap(\.surfaces)).map(\.id))
            p.conductor.pruneTargets(targets)
            p.controlMap.prune(surfaceIDs: targets, cueIDs: Set(p.cues.map(\.id)))
            selectedID = p.surfaces.last?.id
        }
    }
    func moveLayer(_ delta:Int) { guard let i = selectedIndex, project.surfaces.indices.contains(i+delta) else { return }; mutate("Reorder layers") { $0.surfaces.swapAt(i,i+delta) } }
    func toggleGroup() {
        guard let i = selectedIndex,let id = project.surfaces[i].groupID,let g = project.groups.firstIndex(where:{$0.id == id}) else { return }
        mutate("Toggle group") { $0.groups[g].enabled.toggle() }
    }
    func togglePlayback() { if showRuntime.isPlaying { pauseShow() } else { playShow() }; playButton.title = showRuntime.isPlaying ? "Ⅱ Pause" : "▶ Play" }
    func captureCue() { mutate("Capture scene") { $0.cues.append(Cue(name:"Scene \($0.cues.count+1)",surfaces:$0.surfaces,duration:1)) } }
    func deleteCue() { let i=cuePicker.indexOfSelectedItem;guard project.cues.indices.contains(i) else {return};do {try cueDelete(id:project.cues[i].id)} catch {showError(error)} }
    @discardableResult
    func goCue(index: Int? = nil, interactive: Bool = true) -> Bool {
        let i = index ?? cuePicker.indexOfSelectedItem
        guard project.cues.indices.contains(i) else { return false }
        var target = project.cues[i]
        if target.scope == .full {
            let targetIDs = Set(target.surfaces.map(\.id))
            // Full snapshots hide later layers while retaining timeline bindings.
            target.surfaces += project.surfaces.filter { !targetIDs.contains($0.id) }.map { surface in
                var inactive=surface;inactive.enabled=false;return inactive
            }
        }
        do {
            try CompositionTransition.validate(cue:target,in:project)
            var destination=project
            destination.surfaces=try CueSelection.destination(from:project.surfaces,cue:target)
            try ProjectStore.validate(destination)
        } catch {
            if interactive { showError(error) } else { cueMessage = error.localizedDescription }
            return false
        }
        stopAutomationRecording(reason:"Scene GO")
        let missing=CueSelection.missingTargets(from:project.surfaces,cue:target)
        cueMessage=missing.isEmpty ? "" : "Cue skipped \(missing.count) missing surface target(s)"
        commitInterruptedCue()
        cueBefore = project; cueFrom = project.surfaces; cueTarget = target; cueStart = ProcessInfo.processInfo.systemUptime
        cueEngine.begin(from:project.surfaces,cue:target,at:cueStart)
        return cueEngine.isTransitioning
    }
    func startTick() {
        let tickTimer = Timer(timeInterval:1.0/30,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer=tickTimer;RunLoop.main.add(tickTimer,forMode:.common)
    }
    func applyCueSample(at hostTime: Double) {
        guard let sampled = cueEngine.sample(at: hostTime), sampled != project.surfaces else { return }
        do {
            try CompositionPlan.validateStack(surfaces: sampled, groups: project.groups)
            _ = try GroupEngine.resolveForComposition(surfaces: sampled, groups: project.groups)
            project.surfaces = sampled
            dirty = true
            window?.isDocumentEdited = true
        } catch {
            cueMessage = "Scene kept its last valid geometry: " + error.localizedDescription
        }
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        conductorHostTime = now
        flushControlMappings(at: now)
        applyExternalShowClock(at: now)
        advanceShow(at: now)
        pollShowSchedule(at: Date())
        media.update()
        sourceWindow?.updateClock()
        updateRecordingInspector()
        if let cue = cueTarget {
            applyCueSample(at: now)
            if !cueEngine.isTransitioning {
                if cueEngine.shouldFollow(at:now), let i = project.cues.firstIndex(where:{$0.id == cue.id}), i+1 < project.cues.count {
                    if !goCue(index:i+1, interactive:false) { commitInterruptedCue() }
                }
                else if cue.followAfter == nil || (cueEngine.shouldFollow(at:now) && project.cues.last?.id == cue.id) {
                    if let before=cueBefore,before != project { history.commit(before:before,after:project,label:"Recall scene");dirty=true }
                    cueBefore=nil;cueTarget=nil;refresh()
                }
            }
            updateRender()
        }
        for target in allCompositionRenderers {target.materialTime=showRuntime.time}
        advanceFeedback();updateFeedbackTextures()
        if !project.timeline.isEmpty || !project.montages.isEmpty || !project.materials.isEmpty || conductorRuntime.affectsRender { updateRender() }; montageWindow?.updatePlayhead()
        if lighting?.isSampling == true, now-lastLighting >= 1.0/30 {
            lighting?.fixtures = project.fixtures
            lighting?.renderer.blackout = blackout
            lighting?.update(surfaces:effectiveSurfaces); lastLighting = now
        }
        let playhead = showRuntime.time
        seekSlider.maxValue = max(project.timelineSettings.duration,playhead); seekSlider.doubleValue = playhead
        func time(_ n:Double)->String { String(format:"%02d:%02d",Int(max(0,n))/60,Int(max(0,n))%60) }
        timeLabel.stringValue = "\(time(playhead)) / \(time(project.timelineSettings.duration))\(playhead>project.timelineSettings.duration ? " +" : "")"
        playButton.title = showRuntime.isPlaying ? "Ⅱ Pause" : "▶ Play"
        let error = (montagePool.diagnostics.values.first ?? media.errorMessages.values.first ?? (feedback?.errorDescription.isEmpty == false ? feedback?.errorDescription : nil)).map { " · \($0)" } ?? ""
        status.stringValue = "\(renderer.statistics) · \(project.surfaces.count) surfaces · \(outputWindows.count) output windows\(blackout ? " · BLACKOUT" : "")\(error)\(renderer.errorDescription.isEmpty ? "" : " · Last render error: " + renderer.errorDescription)\(renderError.isEmpty ? "" : " · " + renderError)\(editError.isEmpty ? "" : " · " + editError)\(workMessage.isEmpty ? "" : " · " + workMessage)\(outputMessage.isEmpty ? "" : " · " + outputMessage)\(timelineEventWarning.isEmpty ? "" : " · " + timelineEventWarning)\(cueMessage.isEmpty ? "" : " · " + cueMessage)\(isRecordingAutomation ? " · REC INPUT" : "")"
        pollControlMappingOutputs(at: now)
        if dirty,now-lastRecovery>10,let url=projectURL {
            do {try ProjectStore.saveRecovery(project,for:url,baseline:recoveryBaseline)}
            catch {workMessage="Recovery not updated: "+error.localizedDescription}
            lastRecovery=now
        }
    }
    func toggleBlackout() { blackout.toggle(); updateRender() }
    @objc func exportPNG() {
        let p = NSSavePanel(); p.allowedContentTypes = [.png]; p.nameFieldStringValue = "ApertureCue-frame.png"
        guard p.runModal() == .OK,let url = p.url else { return }
        if let frame = compositionExportFrame(), let data = frame.representation(using:.png,properties:[:]) {
            do { try data.write(to:url,options:.atomic) } catch { showError(error) }
        }
    }
    func showError(_ error:Error) { let a = NSAlert(error:error); a.runModal() }
    @objc func about() { let a = NSAlert(); a.messageText = "ApertureCue 0.1.0"; a.informativeText = "Independent open source projection mapping. GPL-3.0-or-later. Early development build. See the feature matrix for measured coverage."; a.runModal() }
}

final class ProjectionWindow: NSWindow {
    var onClose:(()->Void)?
    override var canBecomeKey:Bool { true }
    override func keyDown(with event:NSEvent) { if event.keyCode == 53 { close() } else { super.keyDown(with:event) } }
    override func close() { onClose?(); super.close() }
}
#endif
