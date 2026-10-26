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
        if let path = CommandLine.arguments.dropFirst().first, !path.hasPrefix("--") {
            editor.openProject(URL(fileURLWithPath: path))
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard editor.confirmDiscard() else { return .terminateCancel }
        editor.media.pause(); editor.network?.stop(); editor.midi?.stop()
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
        file.addItem(item("Import Media…", #selector(EditorController.importMedia), "i")); file.addItem(item("Export PNG…", #selector(EditorController.exportPNG), "e"))
        file.addItem(item("Import projected OBJ…", #selector(EditorController.importOBJ), ""))
        file.addItem(item("Collect portable project…", #selector(EditorController.collectProject), ""))
        let edit = NSMenu(); edit.addItem(item("Undo", #selector(EditorController.undoEdit), "z")); edit.addItem(item("Redo", #selector(EditorController.redoEdit), "Z"))
        edit.addItem(.separator()); edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x", target: nil)); edit.items.last?.target = nil
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c", target: nil)); edit.items.last?.target = nil
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v", target: nil)); edit.items.last?.target = nil
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil)); edit.items.last?.target = nil
        for (title, submenu) in [("ApertureCue",app),("File",file),("Edit",edit)] {
            let i = NSMenuItem(); i.title = title; i.submenu = submenu; menu.addItem(i)
        }
        NSApp.mainMenu = menu
    }
}

@MainActor final class EditorController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var project = Project.demo()
    var projectURL: URL?
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
    var outputWindows: [UUID: (NSWindow, MetalRenderer)] = [:]
    var timer: Timer?
    var dragBefore: Project?
    var cueFrom: [Surface] = [], cueTarget: Cue?, cueStart: Double = 0
    let cueEngine = CueEngine()
    var cueBefore: Project?
    var lastRecovery: Double = 0
    var network: NetworkController?
    var midi: MIDIController?
    var lighting: LightingController!
    var lightingView: MTKView!
    var lastLighting: Double = 0
    var effectiveSurfaces: [Surface] {
        do {
            let timed = try TimelineEngine.apply(tracks:project.timeline,time:media.currentTime,surfaces:project.surfaces)
            let resolved = try GroupEngine.resolve(surfaces:timed,groups:project.groups)
            renderError = ""; return resolved
        } catch {
            renderError = "Group/automation: \(error.localizedDescription)"
            return []
        }
    }
    var blackout = false
    var baseURL: URL { projectURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true) }
    var selectedIndex: Int? { project.surfaces.firstIndex { $0.id == selectedID } }
    var inputMode: Bool { modePicker?.indexOfSelectedItem == 1 }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 870), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        super.init(window: window); window.minSize = NSSize(width: 1050, height: 700); window.center(); window.delegate = self
        selectedID = project.surfaces.first?.id
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("ApertureCue requires Metal") }
        metalView.device = device; media = MediaPool(device: device)
        renderer = MetalRenderer(view: metalView, media: media)
        makeUI(); bindOverlay(); reconcile(); refresh(); startTick()
        network = NetworkController { [weak self] command in self?.remote(command) }
        midi = MIDIController { [weak self] command in self?.remote(command) }
        lighting = LightingController(); lightingView = MTKView(frame:.zero,device:device)
        lighting.renderer = MetalRenderer(view:lightingView,media:media); lightingView.isPaused = true
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
            ActionButton("Animate…") { [weak self] in self?.configureAutomation() },
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
        modePicker = ActionPopUp(items:["Output geometry", "Input region"], action: { [weak self] _ in self?.overlay.maskMode = false; self?.overlay.meshMode = false; self?.updateRender(); self?.refreshInspector() })
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
        seekSlider = ActionSlider(value: 0,min:0,max:1) { [weak self] value in self?.media.seek(to:value) }
        seekSlider.widthAnchor.constraint(greaterThanOrEqualToConstant:150).isActive = true
        let transport = stack([playButton,ActionButton("Stop") { [weak self] in self?.media.pause(); self?.media.seek(to:0) },seekSlider,timeLabel],vertical:false)
        let cueRow = stack([label("SCENES",bold:true),ActionButton("Capture") { [weak self] in self?.captureCue() }],vertical:false)
        let cuesContainer = NSView(); cuePicker = ActionPopUp(items:[], action:{ _ in })
        fill(cuePicker,in:cuesContainer)
        cueRow.addArrangedSubview(cuesContainer); cuesContainer.widthAnchor.constraint(greaterThanOrEqualToConstant:150).isActive = true
        cueRow.addArrangedSubview(ActionButton("GO") { [weak self] in self?.goCue() })
        cueRow.addArrangedSubview(ActionButton("Delete") { [weak self] in self?.deleteCue() })
        cueRow.addArrangedSubview(ActionButton("Control…") { [weak self] in self?.configureControl() })
        let root = stack([top,work,transport,cueRow,status],spacing:12)
        root.edgeInsets = NSEdgeInsets(top:12,left:14,bottom:12,right:14); fill(root,in:content)
        for v in [top,work,transport,cueRow,status] { v.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-28).isActive = true }
        top.heightAnchor.constraint(equalToConstant:32).isActive = true
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
            label("SURFACES · back → front",bold:true),layers,
            stack([ActionButton("+ Quad") { [weak self] in self?.addSurface() },ActionButton("Duplicate") { [weak self] in self?.duplicateSurface() }],vertical:false),
            stack([ActionButton("+ Triangle") { [weak self] in self?.addSurface(shape:.triangle) },ActionButton("+ Ellipse") { [weak self] in self?.addSurface(shape:.ellipse) }],vertical:false),
            stack([ActionButton("↓") { [weak self] in self?.moveLayer(-1) },ActionButton("↑") { [weak self] in self?.moveLayer(1) },ActionButton("Delete") { [weak self] in self?.deleteSurface() }],vertical:false)])
        for v in [assets,layers] { v.widthAnchor.constraint(equalTo:s.widthAnchor).isActive = true }
        layers.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive = true
        return s
    }
    func numberOfRows(in tableView:NSTableView) -> Int { tableView === layerTable ? project.surfaces.count : project.assets.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        if tableView === layerTable {
            let s = project.surfaces[row]
            let visible = resolvedBaseSurfaces.first(where:{$0.id == s.id})?.enabled ?? s.enabled
            let prefix = s.groupID.flatMap { id in project.groups.first(where:{$0.id == id})?.name }.map { "[\($0)] " } ?? ""
            return label((visible ? "◈ " : "○ ") + prefix + s.name)
        }
        let a = project.assets[row]; return label((a.kind == "video" ? "▶ " : "▧ ") + a.name)
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === layerTable, project.surfaces.indices.contains(table.selectedRow) {
            selectedID = project.surfaces[table.selectedRow].id; refreshInspector(); updateRender()
        } else if table === mediaTable, project.assets.indices.contains(table.selectedRow) { selectedMediaID = project.assets[table.selectedRow].id }
    }
    private func bindOverlay() {
        overlay.onSelect = { [weak self] id in self?.selectedID = id; self?.refresh() }
        overlay.onBegin = { [weak self] in guard let self else { return }; self.commitInterruptedCue(); self.dragBefore = self.project }
        overlay.onChange = { [weak self] id,points,input,mesh in
            guard let self, let i = self.project.surfaces.firstIndex(where:{$0.id == id}) else { return }
            do {
                var edited = self.project.surfaces[i]
                if self.overlay.maskMode { edited.mask = points }
                else if input { try Geometry.validateQuad(points); edited.input = points }
                else {
                    let inverse = try GroupEngine.worldTransform(for:edited.groupID,groups:self.project.groups).inverse()
                    let local = try points.map { try inverse.applying($0) }
                    guard local.allSatisfy({ abs($0.x) <= 10000 && abs($0.y) <= 10000 }) else { throw ProjectError.invalid("grouped edit exceeds the finite local working range") }
                    if mesh {
                        guard local.count == edited.mesh.count else { throw ProjectError.invalid("mesh edit has a different vertex count") }
                        edited.mesh = local
                    } else {
                        try Geometry.validateQuad(local); edited.output = local
                        edited.mesh = []; edited.meshRows = 0; edited.meshColumns = 0
                    }
                }
                self.project.surfaces[i] = edited; self.editError = ""
            } catch { self.editError = error.localizedDescription; return }
            self.updateRender()
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
        commitInterruptedCue(); let before = project; body(&project)
        guard before != project else { return }
        history.commit(before:before,after:project,label:name); dirty = true; reconcile(); refresh()
    }
    func editSurface(_ name:String,_ body:(inout Surface)->Void) {
        guard let i = selectedIndex else { return }; mutate(name) { body(&$0.surfaces[i]) }
    }
    func reconcile() { media.reconcile(assets:project.assets,baseURL:baseURL) }
    func refresh() {
        updateRender()
        layerTable.reloadData(); mediaTable.reloadData()
        if let i = selectedIndex { layerTable.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
        cuePicker.removeAllItems(); cuePicker.addItems(withTitles:project.cues.map(\.name))
        window?.title = "\(project.name)\(dirty ? " •" : "") — ApertureCue 0.1"
        window?.isDocumentEdited = dirty; refreshInspector()
    }
    func updateRender() {
        let effective = effectiveSurfaces
        do { resolvedBaseSurfaces = try GroupEngine.resolve(surfaces:project.surfaces,groups:project.groups) }
        catch { resolvedBaseSurfaces = []; renderError = error.localizedDescription }
        if inputMode, let i = selectedIndex {
            var s = project.surfaces[i]; s.input = Point2.unitQuad; s.output = Point2.unitQuad
            s.shape = .quad; s.mesh = []; s.meshColumns = 0; s.meshRows = 0; s.mask = []; s.feather = 0; s.opacity = 1; s.brightness = 1; s.gamma = 1; s.color = [1,1,1]; s.enabled = true
            renderer.surfaces = [s]
        } else { renderer.surfaces = effective }
        overlay.inputMode = inputMode; overlay.selectedID = selectedID; overlay.surfaces = resolvedBaseSurfaces
        renderer.blackout = false
        for (_, value) in outputWindows { value.1.surfaces = effective; value.1.blackout = blackout }
    }
    func refreshInspector() {
        inspector.arrangedSubviews.forEach { inspector.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard let i = selectedIndex else { inspector.addArrangedSubview(label("Select a surface")); return }
        let surface = project.surfaces[i]
        func add(_ view:NSView) { inspector.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:inspector.widthAnchor,constant:-24).isActive = true }
        func property(_ title:String,_ value:Double,_ min:Double,_ max:Double,_ change:@escaping (inout Surface,Double)->Void) {
            add(label(String(format:"%@  %.2f",title,value),size:11))
            add(ActionSlider(value:value,min:min,max:max) { [weak self] v in self?.editSurface(title) { change(&$0,v) } })
        }
        add(label("SURFACE",bold:true)); add(ActionField(surface.name) { [weak self] v in self?.editSurface("Rename") { $0.name = v } })
        add(ActionButton(surface.enabled ? "Hide surface" : "Show surface") { [weak self] in self?.editSurface("Visibility") { $0.enabled.toggle() } })
        add(label("Shape · four-corner frame",size:11))
        let shapes: [SurfaceShape] = [.quad,.triangle,.ellipse]
        add(ActionPopUp(items:["Quad","Triangle","Ellipse"],selected:shapes.firstIndex(of:surface.shape) ?? 0) { [weak self] v in self?.setSurfaceShape(shapes[v]) })
        add(label("Generator / fallback",size:11))
        let generators = ["checker","gradient","solid","grid"]
        add(ActionPopUp(items:generators,selected:generators.firstIndex(of:surface.generator) ?? 0) { [weak self] v in self?.editSurface("Generator") { $0.generator = generators[v]; $0.mediaID = nil } })
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
        let outputNames = ["All outputs"] + project.outputs.map(\.name)
        let outIndex = surface.outputID.flatMap { id in project.outputs.firstIndex(where:{$0.id == id}).map { $0 + 1 } } ?? 0
        add(ActionPopUp(items:outputNames,selected:outIndex) { [weak self] v in
            guard let self else { return }; let id = v > 0 ? self.project.outputs[v-1].id : nil
            self.editSurface("Route output") { $0.outputID = id }
        })
        add(label("Geometry",bold:true))
        add(ActionButton("Reset quad / input") { [weak self] in
            guard let self else { return }; self.editSurface("Reset geometry") { s in
                if self.inputMode { s.input = Point2.unitQuad } else { s.output = Point2.insetQuad; s.mesh = []; s.meshColumns = 0; s.meshRows = 0 }
            }
        })
        add(ActionButton("Create 4 × 4 warp mesh") { [weak self] in
            self?.editSurface("Create mesh") { s in s.meshColumns = 4; s.meshRows = 4; s.mesh = (try? Geometry.regularMesh(quad:s.output,columns:4,rows:4)) ?? [] }
            self?.modePicker.selectItem(at:0); self?.overlay.meshMode = true; self?.overlay.maskMode = false; self?.updateRender()
        })
        add(ActionButton(overlay.meshMode ? "Edit quad corners" : "Edit mesh points") { [weak self] in self?.overlay.meshMode.toggle(); if self?.overlay.meshMode == true { self?.modePicker.selectItem(at:0) }; self?.overlay.maskMode = false; self?.updateRender(); self?.refreshInspector() })
        add(ActionButton(surface.mask.isEmpty ? "Add polygon mask" : "Edit polygon mask") { [weak self] in
            self?.editSurface("Mask") { s in if s.mask.isEmpty { s.mask = [Point2(0.1,0.1),Point2(0.9,0.1),Point2(0.8,0.9),Point2(0.2,0.9)] } }
            self?.modePicker.selectItem(at:1); self?.overlay.maskMode = true; self?.overlay.meshMode = false; self?.updateRender()
        })
        add(ActionButton("Remove mask") { [weak self] in self?.overlay.maskMode = false; self?.editSurface("Remove mask") { $0.mask = [] } })
        if let a = project.assets.first(where:{$0.id == surface.mediaID}) {
            add(label("MEDIA · \(a.name)",size:11,bold:true))
            add(ActionButton(a.loop ? "Loop: ON" : "Loop: OFF") { [weak self] in self?.mutate("Loop") { p in if let aIndex = p.assets.firstIndex(where:{$0.id == a.id}) { p.assets[aIndex].loop.toggle() } } })
            add(ActionSlider(value:a.volume,min:0,max:1) { [weak self] value in self?.mutate("Volume") { p in if let aIndex = p.assets.firstIndex(where:{$0.id == a.id}) { p.assets[aIndex].volume = value } } })
            if a.kind != "camera" { add(ActionButton("Relink media…") { [weak self] in self?.relink(a.id) }) }
        }
    }
    @objc func newProject() {
        guard confirmDiscard() else { return }; closeOutputs(); project = Project(name:"Untitled",surfaces:[Surface()],outputs:[OutputConfig()]); projectURL = nil
        history.clear(); cueEngine.cancel(); cueTarget = nil; cueBefore = nil; selectedMediaID = nil; selectedGroupID = nil; editError = ""; overlay.maskMode = false; overlay.meshMode = false; documentGeneration = UUID()
        lighting?.stop(); selectedID = project.surfaces.first?.id; dirty = false; media.pause(); media.seek(to:0); reconcile(); refresh()
    }
    @objc func openDialog() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { openProject(url) }
    }
    func openProject(_ url:URL) {
        guard confirmDiscard() else { return }
        do {
            let loaded = try ProjectStore.load(from:url)
            closeOutputs(); lighting?.stop(); media.pause(); media.seek(to:0); history.clear(); cueEngine.cancel(); cueTarget = nil; cueBefore = nil; selectedMediaID = nil; selectedGroupID = nil; editError = ""; overlay.maskMode = false; overlay.meshMode = false; documentGeneration = UUID(); project = loaded; projectURL = url; dirty = false; selectedID = loaded.surfaces.first?.id
            if FileManager.default.fileExists(atPath:ProjectStore.recoveryURL(for:url).path) {
                let alert = NSAlert(); alert.messageText = "Recovery snapshot found"; alert.informativeText = "Restore the autosaved state for this project?"; alert.addButton(withTitle:"Restore"); alert.addButton(withTitle:"Use saved project")
                if alert.runModal() == .alertFirstButtonReturn, let recovered = try? ProjectStore.loadRecovery(for:url) { project = recovered; dirty = true }
            }
            reconcile(); refresh()
        } catch { showError(error) }
    }
    @objc func save() { if let url = projectURL { saveTo(url) } else { saveAs() } }
    @objc func saveAs() {
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = "\(project.name).aperturecue.json"
        if p.runModal() == .OK, let url = p.url { saveTo(url) }
    }
    func saveTo(_ url:URL) {
        do { try ProjectStore.save(project,to:url); try? FileManager.default.removeItem(at:ProjectStore.recoveryURL(for:url)); projectURL = url; dirty = false; reconcile(); refresh() } catch { showError(error) }
    }
    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let a = NSAlert(); a.messageText = "Save changes to \(project.name)?"; a.addButton(withTitle:"Save"); a.addButton(withTitle:"Cancel"); a.addButton(withTitle:"Discard")
        switch a.runModal() { case .alertFirstButtonReturn: save(); return !dirty; case .alertSecondButtonReturn: return false; default: return true }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if sender === window { return confirmDiscard() }; return true }
    @objc func undoEdit() { commitInterruptedCue(); if let p = history.undo(current:project) { project = p; dirty = true; reconcile(); refresh() } }
    @objc func redoEdit() { commitInterruptedCue(); if let p = history.redo(current:project) { project = p; dirty = true; reconcile(); refresh() } }
    @objc func importMedia() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = [.image,.movie,.video]
        guard p.runModal() == .OK else { return }
        mutate("Import media") { state in
            for url in p.urls {
                let ext = url.pathExtension.lowercased()
                let kind = ["mov","mp4","m4v","avi","mkv","webm"].contains(ext) ? "video" : "image"
                let asset = MediaAsset(name:url.lastPathComponent,path:url.path,kind:kind); state.assets.append(asset)
                if let i = state.surfaces.firstIndex(where:{$0.id == selectedID}) { state.surfaces[i].mediaID = asset.id }
                else { let s = Surface(name:url.deletingPathExtension().lastPathComponent,mediaID:asset.id); state.surfaces.append(s); selectedID = s.id }
            }
        }
    }
    func relink(_ id:UUID) {
        let p = NSOpenPanel(); guard p.runModal() == .OK, let url = p.url else { return }
        let previousPath = project.assets.first(where: { $0.id == id })?.path
        mutate("Relink media") { state in if let i = state.assets.firstIndex(where:{$0.id == id}) { state.assets[i].path = url.path; state.assets[i].name = url.lastPathComponent } }
        if previousPath == url.path { media.reloadAsset(id:id,assets:project.assets,baseURL:baseURL); refresh() }
    }
    func assignMedia() { guard let id = selectedMediaID else { return }; editSurface("Assign media") { $0.mediaID = id } }
    func addSurface(shape:SurfaceShape = .quad) {
        mutate("Add surface") { p in
            var s = Surface(name:"\(shape == .quad ? "Surface" : shape.rawValue.capitalized) \(p.surfaces.count+1)")
            s.shape = shape; p.surfaces.append(s); selectedID = s.id
        }
    }
    func setSurfaceShape(_ shape:SurfaceShape) { editSurface("Surface shape") { $0.shape = shape } }
    func duplicateSurface() { guard let i = selectedIndex else { return }; mutate("Duplicate surface") { p in var s = p.surfaces[i]; s.id = UUID(); s.name += " copy"; p.surfaces.append(s); selectedID = s.id } }
    func deleteSurface() { guard let i = selectedIndex else { return }; mutate("Delete surface") { p in let id = p.surfaces[i].id; p.surfaces.remove(at:i); p.timeline.removeAll { $0.surfaceID == id }; selectedID = p.surfaces.last?.id } }
    func moveLayer(_ delta:Int) { guard let i = selectedIndex, project.surfaces.indices.contains(i+delta) else { return }; mutate("Reorder layers") { $0.surfaces.swapAt(i,i+delta) } }
    func toggleGroup() {
        guard let i = selectedIndex,let id = project.surfaces[i].groupID,let g = project.groups.firstIndex(where:{$0.id == id}) else { return }
        mutate("Toggle group") { $0.groups[g].enabled.toggle() }
    }
    func togglePlayback() { if media.isPlaying { media.pause() } else { media.play() }; playButton.title = media.isPlaying ? "Ⅱ Pause" : "▶ Play" }
    func captureCue() { mutate("Capture scene") { $0.cues.append(Cue(name:"Scene \($0.cues.count+1)",surfaces:$0.surfaces,duration:1)) } }
    func deleteCue() { let i = cuePicker.indexOfSelectedItem; guard project.cues.indices.contains(i) else { return }; mutate("Delete scene") { $0.cues.remove(at:i) } }
    func goCue(index:Int? = nil) {
        let i = index ?? cuePicker.indexOfSelectedItem; guard project.cues.indices.contains(i) else { return }
        var target = project.cues[i]
        let targetIDs = Set(target.surfaces.map(\.id))
        // Scene absence hides a definition; it must not orphan automation or
        // silently discard a surface created after that scene was captured.
        target.surfaces += project.surfaces.filter { !targetIDs.contains($0.id) }.map { surface in
            var inactive = surface; inactive.enabled = false; return inactive
        }
        var destination = project; destination.surfaces = target.surfaces
        do { try ProjectStore.validate(destination) } catch { showError(error); return }
        commitInterruptedCue()
        cueBefore = project; cueFrom = project.surfaces; cueTarget = target; cueStart = ProcessInfo.processInfo.systemUptime
        cueEngine.begin(from:project.surfaces,cue:target,at:cueStart)
    }
    func startTick() {
        timer = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let cue = cueTarget {
            if let sampled = cueEngine.sample(at:now),sampled != project.surfaces { project.surfaces = sampled; dirty = true; window?.isDocumentEdited = true }
            if !cueEngine.isTransitioning {
                if cueEngine.shouldFollow(at:now), let i = project.cues.firstIndex(where:{$0.id == cue.id}), i+1 < project.cues.count { goCue(index:i+1) }
                else if cue.followAfter == nil || (cueEngine.shouldFollow(at:now) && project.cues.last?.id == cue.id) {
                    if let before = cueBefore { history.commit(before:before,after:project,label:"Recall scene") }
                    cueBefore = nil; cueTarget = nil; dirty = true; refresh()
                }
            }
            updateRender()
        }
        if !project.timeline.isEmpty { updateRender() }
        if lighting?.isSampling == true, now-lastLighting >= 1.0/30 {
            lighting?.fixtures = project.fixtures
            lighting?.renderer.blackout = blackout
            lighting?.update(surfaces:effectiveSurfaces); lastLighting = now
        }
        let primary = project.assets.first(where:{$0.kind == "video"})
        let playhead = primary.map { media.playbackTime(for:$0.id) } ?? media.currentTime
        seekSlider.maxValue = max(1,media.duration,project.timeline.flatMap(\.keyframes).map(\.time).max() ?? 0); seekSlider.doubleValue = playhead
        func time(_ n:Double)->String { String(format:"%02d:%02d",Int(max(0,n))/60,Int(max(0,n))%60) }
        timeLabel.stringValue = "\(time(playhead)) / \(time(media.duration))"
        playButton.title = media.isPlaying ? "Ⅱ Pause" : "▶ Play"
        let error = media.errorMessages.values.first.map { " · \($0)" } ?? ""
        status.stringValue = "\(renderer.statistics) · \(project.surfaces.count) surfaces · \(outputWindows.count) output windows\(blackout ? " · BLACKOUT" : "")\(error)\(renderer.errorDescription.isEmpty ? "" : " · Last render error: " + renderer.errorDescription)\(renderError.isEmpty ? "" : " · " + renderError)\(editError.isEmpty ? "" : " · " + editError)\(workMessage.isEmpty ? "" : " · " + workMessage)"
        if dirty, now-lastRecovery > 10, let url = projectURL { try? ProjectStore.saveRecovery(project,for:url); lastRecovery = now }
    }
    func configureOutputs() {
        let a = NSAlert(); a.messageText = "Projection output"; a.informativeText = "Create an independent output on a selected display. Escape closes its fullscreen window."
        let picker = ActionPopUp(items:NSScreen.screens.enumerated().map { "\($0.offset): \($0.element.localizedName)" },action:{_ in})
        a.accessoryView = picker; picker.frame = NSRect(x:0,y:0,width:330,height:28)
        a.addButton(withTitle:"Open fullscreen"); a.addButton(withTitle:"Open preview window"); a.addButton(withTitle:"Close outputs"); a.addButton(withTitle:"Cancel")
        let response = a.runModal()
        if response == .alertFirstButtonReturn || response == .alertSecondButtonReturn {
            let screen = max(0,picker.indexOfSelectedItem)
            var config = project.outputs.first(where:{$0.screenIndex == screen})
            if config == nil { config = OutputConfig(name:"Display \(screen+1)",screenIndex:screen); mutate("Add output") { $0.outputs.append(config!) } }
            openOutput(config!,fullscreen:response == .alertFirstButtonReturn)
        } else if response == .alertThirdButtonReturn { closeOutputs() }
    }
    func openOutput(_ config:OutputConfig,fullscreen:Bool,showWindow:Bool = true) {
        if let old = outputWindows[config.id] { old.0.close(); outputWindows.removeValue(forKey:config.id) }
        let screen = NSScreen.screens.indices.contains(config.screenIndex) ? NSScreen.screens[config.screenIndex] : NSScreen.main!
        let w = ProjectionWindow(contentRect:NSRect(x:screen.frame.minX+60,y:screen.frame.minY+60,width:960,height:540),styleMask:fullscreen ? [.borderless] : [.titled,.closable,.resizable],backing:.buffered,defer:false,screen:screen)
        w.title = "ApertureCue · \(config.name)"; w.backgroundColor = .black; w.isReleasedWhenClosed = false
        let v = MTKView(frame:.zero,device:metalView.device)
        guard let r = MetalRenderer(view:v,media:media) else { return }; r.outputID = config.id; r.surfaces = effectiveSurfaces; r.blackout = blackout
        fill(v,in:w.contentView!); outputWindows[config.id] = (w,r)
        w.onClose = { [weak self] in self?.outputWindows.removeValue(forKey:config.id) }
        if fullscreen {
            w.setFrame(screen.frame,display:true)
            w.level = NSWindow.Level(rawValue:NSWindow.Level.mainMenu.rawValue+1)
            w.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        }
        if showWindow { w.makeKeyAndOrderFront(nil) }
    }
    func closeOutputs() { let windows = Array(outputWindows.values); outputWindows.removeAll(); windows.forEach { $0.0.close() } }
    func toggleBlackout() { blackout.toggle(); updateRender() }
    @objc func exportPNG() {
        let p = NSSavePanel(); p.allowedContentTypes = [.png]; p.nameFieldStringValue = "ApertureCue-frame.png"
        guard p.runModal() == .OK,let url = p.url else { return }
        let saved = renderer.surfaces; renderer.surfaces = effectiveSurfaces
        defer { renderer.surfaces = saved }
        if let frame = renderer.render(width:1920,height:1080), let data = frame.representation(using:.png,properties:[:]) {
            do { try data.write(to:url,options:.atomic) } catch { showError(error) }
        }
    }
    func configureControl() {
        let a = NSAlert(); a.messageText = "Remote control · localhost"; a.informativeText = "OSC UDP 9000: /aperturecue/play, /pause, /seek float seconds, /blackout int, /cue int (0-based), /surface/<index>/opacity float. MIDI: notes 60/61 play/pause, 62 blackout, notes 36…59 scenes, CC1 first surface opacity. Network starts only on request; no fixture output is enabled automatically."
        a.addButton(withTitle:"Start OSC + MIDI"); a.addButton(withTitle:"Stop control"); a.addButton(withTitle:"Cancel")
        switch a.runModal() { case .alertFirstButtonReturn: do { try network?.start(port:9000); try midi?.start() } catch { showError(error) }; case .alertSecondButtonReturn: network?.stop(); midi?.stop(); default: break }
    }
    func remote(_ command:ControlCommand) {
        switch command {
        case .play: media.play()
        case .pause: media.pause()
        case .seek(let time): media.seek(to:time)
        case .blackout(let value): blackout = value; updateRender()
        case .cue(let index): goCue(index:index)
        case .opacity(let index,let value): if project.surfaces.indices.contains(index) { mutate("Remote opacity") { $0.surfaces[index].opacity = max(0,min(1,value)) } }
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
