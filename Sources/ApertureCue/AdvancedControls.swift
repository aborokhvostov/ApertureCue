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
            if let i = selectedIndex { p.surfaces[i].mediaID = asset.id } else { let surface = Surface(name:device.name,mediaID:asset.id); p.surfaces.append(surface); selectedID = surface.id }
        }
    }

    func configureAutomation() { showTimelineWindow() }

    func configureLighting() {
        let a = NSAlert(); a.messageText = "LED mapping · output composition"
        a.informativeText = "Sample normalized output coordinates at up to 30 Hz. A fixture is a line of pixels. Simulation requires no hardware. Universe numbers are sent unchanged on the wire."
        let count = ActionField("30",action:{_ in}), universe = ActionField("1",action:{_ in}), address = ActionField("1",action:{_ in})
        let start = ActionField("0.1, 0.5",action:{_ in}), end = ActionField("0.9, 0.5",action:{_ in})
        let order = ActionPopUp(items:["RGB","GRB","RGBW"],action:{_ in})
        let wire = ActionPopUp(items:["Art-Net","sACN"],selected:lighting.wireProtocol == .artnet ? 0 : 1,action:{_ in})
        let destination = ActionField(lighting.destination,action:{_ in})
        let info = label("\(project.fixtures.count) fixtures · \(lighting.isSending ? "SENDING" : "network stopped")",size:11,bold:true)
        let v = stack([info,label("Pixel count / universe / start address"),stack([count,universe,address],vertical:false),label("Start x,y / end x,y"),stack([start,end],vertical:false),order,label("Explicit IPv4 destination"),stack([wire,destination],vertical:false)])
        v.frame = NSRect(x:0,y:0,width:430,height:230); for field in [count,universe,address] { field.widthAnchor.constraint(equalToConstant:130).isActive = true }; start.widthAnchor.constraint(equalToConstant:200).isActive = true; end.widthAnchor.constraint(equalToConstant:200).isActive = true; destination.widthAnchor.constraint(equalToConstant:270).isActive = true
        a.accessoryView = v
        a.addButton(withTitle:"Add fixture + simulate"); a.addButton(withTitle:"Start network output"); a.addButton(withTitle:"Stop output"); a.addButton(withTitle:"Clear fixtures"); a.addButton(withTitle:"Cancel")
        let response = a.runModal()
        do {
            if response == .alertFirstButtonReturn {
                guard let n = Int(count.stringValue), (1...170).contains(n),let u = Int(universe.stringValue),let addr = Int(address.stringValue) else { throw SystemFailure(message:"Enter valid pixel count (1…170), universe and address") }
                func point(_ text:String) throws -> Point2 {
                    let parts = text.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }
                    guard parts.count == 2,let x = Double(parts[0]),let y = Double(parts[1]),x.isFinite,y.isFinite,(0...1).contains(x),(0...1).contains(y) else { throw SystemFailure(message:"Coordinates must be normalized x,y in 0…1") }; return Point2(x,y)
                }
                let p0 = try point(start.stringValue), p1 = try point(end.stringValue)
                let points = (0..<n).map { Point2.interpolate(p0,p1,t:n == 1 ? 0 : Double($0)/Double(n-1)) }
                let fixture = Fixture(name:"Strip \(project.fixtures.count+1)",universe:u,address:addr,points:points,channelOrder:order.titleOfSelectedItem ?? "RGB")
                var candidate = project; candidate.fixtures.append(fixture); try ProjectStore.validate(candidate)
                mutate("Add fixture") { $0 = candidate }; lighting.isSampling = true; lighting.showSimulator()
            } else if response == .alertSecondButtonReturn {
                let candidate = destination.stringValue.trimmingCharacters(in:.whitespaces)
                var target = in_addr(); guard inet_pton(AF_INET,candidate,&target) == 1 else { throw SystemFailure(message:"Enter a numeric IPv4 destination") }
                lighting.stop(); lighting.destination = candidate
                lighting.wireProtocol = wire.indexOfSelectedItem == 0 ? .artnet : .sacn
                lighting.isSampling = true; lighting.isSending = true; lighting.showSimulator()
            } else if response == .alertThirdButtonReturn { lighting.stop() }
            else if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue+3 { lighting.stop(); mutate("Clear fixtures") { $0.fixtures = [] } }
        } catch { showError(error) }
    }
}
#endif
