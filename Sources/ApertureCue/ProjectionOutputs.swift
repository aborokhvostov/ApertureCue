#if os(macOS)
import AppKit
import ColorSync
import CoreGraphics
import MetalKit
import MappingCore

enum ProjectionWindowKey: Hashable {
    case preview(UUID), fullscreen(UUID)

    var outputID: UUID {
        switch self { case .preview(let id), .fullscreen(let id): return id }
    }
}

struct ProjectionDisplay {
    let id: UUID
    let screen: NSScreen
    let allowsFullscreen: Bool

    @MainActor static var connected: [Self] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let display = number.uint32Value
            guard display != kCGNullDirectDisplay, let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
                  let id = UUID(uuidString:CFUUIDCreateString(nil,uuid) as String) else { return nil }
            let usable = CGDisplayIsActive(display) != 0 && CGDisplayIsInMirrorSet(display) == 0
            return Self(id:id,screen:screen,allowsFullscreen:usable)
        }
    }

    static func target(_ id: UUID?, in displays: [Self]) -> Self? {
        guard let id else { return nil }
        let matches = displays.filter { $0.id == id }
        guard matches.count == 1, let display = matches.first, display.allowsFullscreen else { return nil }
        return display
    }
}

extension EditorController {
    func outputTitles(_ outputs: [OutputConfig]) -> [String] {
        outputs.enumerated().map { "\($0.offset+1). \($0.element.name)" }
    }

    func configureOutputs() {
        let generation = documentGeneration
        let configs = project.outputs
        let displays = ProjectionDisplay.connected
        let choices = displays.filter { ProjectionDisplay.target($0.id,in:displays) != nil }
        let outputPicker = ActionPopUp(items:outputTitles(configs) + ["New output"],action:{ _ in })
        let displayPicker = ActionPopUp(items:["Choose a display…"] + choices.enumerated().map {
            "\($0.element.screen.localizedName) (\($0.offset+1))"
        },action:{ _ in })
        let binding = label("",size:11)
        @MainActor func selectOutput(_ index:Int) {
            let saved = configs.indices.contains(index) ? configs[index].displayUUID : nil
            let choice = saved.flatMap { id in choices.firstIndex { $0.id == id } }
            displayPicker.selectItem(at:choice.map { $0+1 } ?? 0)
            binding.stringValue = choice.map { "Assigned: \(choices[$0].screen.localizedName)" } ??
                (saved == nil ? "Fullscreen display unassigned" : "Saved display unavailable")
        }
        outputPicker.actionBlock=selectOutput
        selectOutput(outputPicker.indexOfSelectedItem)

        let alert = NSAlert()
        alert.messageText = "Projection outputs"
        alert.informativeText = "Choose an output for preview. Choose a display to assign and open it fullscreen. Escape closes the output window."
        let view = stack([label("Output"),outputPicker,label("Fullscreen display"),displayPicker,binding])
        view.frame = NSRect(x:0,y:0,width:360,height:132)
        for control in [outputPicker,displayPicker] { control.widthAnchor.constraint(equalToConstant:350).isActive = true }
        alert.accessoryView=view
        alert.addButton(withTitle:"Open fullscreen")
        alert.addButton(withTitle:"Open preview window")
        alert.addButton(withTitle:"Close outputs")
        alert.addButton(withTitle:"Cancel")
        let response=alert.runModal()
        guard documentGeneration==generation else { return }
        if response == .alertThirdButtonReturn { closeOutputs(); return }
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        let selection = outputPicker.indexOfSelectedItem
        let displayIndex = displayPicker.indexOfSelectedItem-1
        let id = configs.indices.contains(selection) ? configs[selection].id : nil
        do {
            try presentOutput(id:id,fullscreen:response == .alertFirstButtonReturn,
                              displayUUID:choices.indices.contains(displayIndex) ? choices[displayIndex].id : nil)
        } catch { showError(error) }
    }

    /// Resolves the dialog's captured UUID against current topology before a
    /// stale selection can persist a binding or open on a different display.
    func presentOutput(id: UUID?, fullscreen: Bool, displayUUID: UUID?, showWindow: Bool = true) throws {
        let displays = ProjectionDisplay.connected
        let original = id.flatMap { id in project.outputs.first { $0.id == id } }
        if id != nil && original == nil { throw SystemFailure(message:"This output is no longer in the project.") }
        if original == nil && project.outputs.count >= 64 { throw SystemFailure(message:"The project already contains 64 outputs.") }
        var ordinal = project.outputs.count+1
        while project.outputs.contains(where: { $0.name == "Output \(ordinal)" }) { ordinal += 1 }
        var config = original ?? OutputConfig(name:"Output \(ordinal)")
        if fullscreen {
            guard let displayUUID, ProjectionDisplay.target(displayUUID,in:displays) != nil else {
                throw SystemFailure(message:"Choose an available, non-mirrored fullscreen display.")
            }
            guard !outputWindows.contains(where: { $0.key.outputID != config.id && $0.value.displayUUID == displayUUID }) else {
                throw SystemFailure(message:"Another fullscreen output is already using that display.")
            }
            config.displayUUID=displayUUID
        }
        if original != config {
            mutate(original == nil ? "Add output" : "Assign fullscreen display") { project in
                if let index = project.outputs.firstIndex(where: { $0.id == config.id }) { project.outputs[index] = config }
                else { project.outputs.append(config) }
            }
        }
        openOutput(config,fullscreen:fullscreen,showWindow:showWindow)
    }

    func openOutput(_ config: OutputConfig, fullscreen: Bool, showWindow: Bool = true) {
        let screen: NSScreen
        if fullscreen {
            guard let target = ProjectionDisplay.target(config.displayUUID,in:ProjectionDisplay.connected),
                  project.outputs.first(where: { $0.id == config.id })?.displayUUID == target.id,
                  !outputWindows.contains(where: { $0.key.outputID != config.id && $0.value.displayUUID == target.id }) else {
                outputMessage = "Fullscreen output unavailable. Check its display assignment."
                return
            }
            screen=target.screen
        } else {
            guard let preferred = window?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
                outputMessage = "A display is needed to open a preview window."
                return
            }
            screen=preferred
        }
        let available = screen.visibleFrame
        let scale = min(1,available.width/1000,available.height/610)
        let viewFrame = NSRect(x:0,y:0,width:960*scale,height:540*scale)
        let projection = ProjectionWindow(contentRect:viewFrame,styleMask:fullscreen ? [.borderless] : [.titled,.closable,.resizable],
                                          backing:.buffered,defer:false,screen:screen)
        projection.title="ApertureCue · \(config.name)"
        projection.backgroundColor = .black
        projection.isReleasedWhenClosed=false
        let view = MTKView(frame:.zero,device:metalView.device)
        guard let outputRenderer = MetalRenderer(view:view,media:media), let content=projection.contentView else {
            outputMessage = "Could not initialize the output renderer."
            return
        }
        outputRenderer.outputID=config.id
        outputRenderer.surfaces=effectiveSurfaces
        outputRenderer.blackout=blackout
        fill(view,in:content)
        if fullscreen {
            projection.setFrame(screen.frame,display:true)
            projection.level = NSWindow.Level(rawValue:NSWindow.Level.mainMenu.rawValue+1)
            projection.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        } else {
            projection.setFrameOrigin(NSPoint(x:available.midX-projection.frame.width/2,y:available.midY-projection.frame.height/2))
        }
        let key: ProjectionWindowKey = fullscreen ? .fullscreen(config.id) : .preview(config.id)
        outputWindows[key]?.0.close()
        outputWindows[key]=(projection,outputRenderer,fullscreen ? config.displayUUID : nil)
        projection.onClose = { [weak self, weak projection] in
            guard let self, self.outputWindows[key]?.0 === projection else { return }
            self.outputWindows.removeValue(forKey:key)
        }
        outputMessage=""
        if showWindow { projection.makeKeyAndOrderFront(nil) }
    }

    func reconcileOutputWindows(displays: [ProjectionDisplay]? = nil) {
        guard !outputWindows.isEmpty else { return }
        let available=displays ?? ProjectionDisplay.connected
        let configs=Dictionary(project.outputs.map { ($0.id,$0) },uniquingKeysWith: { first,_ in first })
        var closed=0
        for (key,output) in Array(outputWindows) {
            guard let config=configs[key.outputID] else { output.0.close(); continue }
            if let displayUUID=output.displayUUID {
                guard config.displayUUID==displayUUID, let target=ProjectionDisplay.target(displayUUID,in:available) else {
                    output.0.orderOut(nil)
                    output.0.close()
                    closed += 1
                    continue
                }
                if output.0.frame != target.screen.frame { output.0.setFrame(target.screen.frame,display:true) }
            }
            output.0.title="ApertureCue · \(config.name)"
        }
        if closed > 0 {
            outputMessage = "Fullscreen output closed after a display change. Open Outputs… to resume."
        }
    }

    func closeOutputs() {
        let windows=Array(outputWindows.values)
        outputWindows.removeAll()
        windows.forEach { $0.0.close() }
        outputMessage=""
    }
}
#endif
