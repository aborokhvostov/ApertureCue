#if os(macOS)
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import MappingCore

extension EditorController {
    @objc func collectProject() {
        let panel = NSSavePanel(); panel.title = "Create a portable project folder"; panel.nameFieldStringValue = "ApertureCue Show"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK,let directory = panel.url else { return }
        let snapshot = project; workMessage = "Collecting media…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try ProjectStore.collect(snapshot,to:directory) }
            DispatchQueue.main.async {
                guard let self else { return }; self.workMessage = ""
                switch result {
                case .success(let url): let a = NSAlert(); a.messageText = "Portable copy saved"; a.informativeText = url.path; a.runModal()
                case .failure(let error): self.showError(error)
                }
            }
        }
    }
    @objc func importOBJ() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension:"obj") ?? .plainText]
        guard panel.runModal() == .OK,let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Project OBJ into editable patches"
        alert.informativeText = "Bake a pinhole view into 2D quad patches. Each triangle becomes 3 patches. Camera looks at the origin. Materials and depth-buffer rendering are not imported."
        let z = ActionField("3",action:{_ in}),fov = ActionField("60",action:{_ in})
        let controls = stack([label("Camera Z / vertical field of view (degrees)"),stack([z,fov],vertical:false)]); controls.frame = NSRect(x:0,y:0,width:370,height:60)
        z.widthAnchor.constraint(equalToConstant:170).isActive = true; fov.widthAnchor.constraint(equalToConstant:170).isActive = true
        alert.accessoryView = controls; alert.addButton(withTitle:"Import patches"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,let cameraZ = Double(z.stringValue),let angle = Double(fov.stringValue) else { return }
        let generation = documentGeneration, mediaID = selectedIndex.flatMap { project.surfaces[$0].mediaID }
        workMessage = "Projecting OBJ…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result:Result<[Surface],Error> = Result {
                let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
                guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 16*1024*1024 else { throw SystemFailure(message:"OBJ file exceeds 16 MiB") }
                let source = try String(contentsOf:url,encoding:.utf8)
                let mesh = try OBJMesh.parse(source)
                let camera = Camera3D(position:Point3(0,0,cameraZ),verticalFOV:angle)
                let patches = try mesh.projectedSurfaces(camera:camera,mediaID:mediaID)
                guard !patches.isEmpty else { throw SystemFailure(message:"No visible patches. Check camera distance, FOV and mesh scale.") }
                return patches
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.workMessage = ""
                guard self.documentGeneration == generation else { return }
                do {
                    let patches = try result.get(); var candidate = self.project; candidate.surfaces.append(contentsOf:patches); try ProjectStore.validate(candidate)
                    self.mutate("Import projected OBJ") { p in p = candidate; self.selectedID = patches.first?.id }
                } catch { self.showError(error) }
            }
        }
    }
    func addCamera() {
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for:.video) { [weak self] granted in DispatchQueue.main.async { if granted { self?.addCamera() } else { self?.showError(SystemFailure(message:"Camera access denied")) } } }; return
        case .authorized: break
        default: showError(SystemFailure(message:"Camera access is denied. Change it in macOS Privacy settings to use capture.")); return
        }
        let devices = MediaPool.availableCameras()
        guard !devices.isEmpty else { showError(SystemFailure(message:"No camera devices are currently available")); return }
        let a = NSAlert(); a.messageText = "Live camera source"
        let picker = ActionPopUp(items:devices.map(\.name),action:{_ in}); picker.frame = NSRect(x:0,y:0,width:320,height:28); a.accessoryView = picker
        a.addButton(withTitle:"Add camera"); a.addButton(withTitle:"Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }; let device = devices[picker.indexOfSelectedItem]
        mutate("Add camera") { p in let asset = MediaAsset(name:device.name,path:device.id,kind:"camera",volume:0); p.assets.append(asset)
            if let i = selectedIndex { p.surfaces[i].mediaID = asset.id;p.surfaces[i].feedbackOutputID=nil } else { let surface = Surface(name:device.name,mediaID:asset.id); p.surfaces.append(surface); selectedID = surface.id }
        }
    }

    func configureAutomation() { showTimelineWindow() }
}
#endif
