#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    @objc func showSources() {
        if sourceWindow==nil {sourceWindow=MediaSourceWindow(editor:self)}
        sourceWindow?.refresh();sourceWindow?.showWindow(nil);sourceWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func sourceSettings(id:UUID,playback:MediaPlaybackSettings?) throws {
        guard let index=project.assets.firstIndex(where:{$0.id==id}) else {throw ProjectError.invalid("source no longer exists")}
        var next=project;next.assets[index].playback=playback
        try ProjectStore.validate(next);mutate("Source playback settings") {$0=next}
    }
    func sourceRouting(id:UUID,routing:AudioRoutingSettings?) throws {
        guard let index=project.assets.firstIndex(where:{$0.id==id}) else {throw ProjectError.invalid("source no longer exists")}
        var next=project;next.assets[index].audioRouting=routing
        try ProjectStore.validate(next);mutate("Source audio routing") {$0=next}
        media.retryAudio(for:id)
    }
    @objc func importSequence() {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false
        guard panel.runModal() == .OK,let directory=panel.url else {return}
        let generation=documentGeneration;workMessage="Reading image sequence…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result {try Self.sequenceManifest(at:directory,fps:30)}
            DispatchQueue.main.async {
                guard let self,self.documentGeneration==generation else {return};self.workMessage=""
                do {try self.addSequence(directory:directory,manifest:result.get())} catch {self.showError(error)}
            }
        }
    }
    nonisolated static func sequenceManifest(at directory:URL,fps:Double)throws->MediaSequenceSettings {
        let fm=FileManager.default
        guard let iterator=fm.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsSubdirectoryDescendants]) else {throw ProjectError.invalid("sequence folder is unavailable")}
        var names:[String]=[];var count=0
        for case let url as URL in iterator {
            count+=1;guard count<=100000 else {throw ProjectError.invalid("sequence folder exceeds enumeration budget")}
            guard MediaSequenceSettings.supportedExtensions.contains(url.pathExtension.lowercased()) else {continue}
            let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile==true,values.isSymbolicLink != true else {throw ProjectError.invalid("sequence frames must be regular files, without symlinks")}
            names.append(url.lastPathComponent)
        }
        return try MediaSequenceSettings.discover(names:names,fps:fps)
    }
    func addSequence(directory:URL,manifest:MediaSequenceSettings)throws {
        try manifest.validate()
        var asset=MediaAsset(name:directory.lastPathComponent,path:directory.path,kind:"sequence",volume:0)
        asset.sequence=manifest
        var next=project;next.assets.append(asset)
        if let index=selectedIndex {next.surfaces[index].mediaID=asset.id;next.surfaces[index].feedbackOutputID=nil}
        else {next.surfaces.append(Surface(name:asset.name,mediaID:asset.id))}
        try ProjectStore.validate(next);mutate("Import image sequence") {$0=next;selectedMediaID=asset.id}
    }
    func refreshSequence(id:UUID)throws {
        guard let index=project.assets.firstIndex(where:{$0.id==id}),project.assets[index].kind=="sequence" else {return}
        let asset=project.assets[index],url=asset.path.hasPrefix("/") ? URL(fileURLWithPath:asset.path) : baseURL.appendingPathComponent(asset.path)
        let manifest=try Self.sequenceManifest(at:url,fps:asset.sequence?.fps ?? 30)
        var next=project;next.assets[index].sequence=manifest;try ProjectStore.validate(next)
        mutate("Refresh sequence manifest") {$0=next}
        media.reloadAsset(id:id,assets:project.assets,baseURL:baseURL)
    }
    func refreshSequenceAsync(id:UUID) {
        guard let asset=project.assets.first(where:{$0.id==id}),asset.kind=="sequence" else {return}
        let generation=documentGeneration,url=asset.path.hasPrefix("/") ? URL(fileURLWithPath:asset.path) : baseURL.appendingPathComponent(asset.path)
        workMessage="Refreshing sequence manifest…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result {try Self.sequenceManifest(at:url,fps:asset.sequence?.fps ?? 30)}
            DispatchQueue.main.async {
                guard let self,self.documentGeneration==generation else {return};self.workMessage=""
                guard self.project.assets.first(where:{$0.id==id})==asset else {return}
                do {
                    let manifest=try result.get();var next=self.project
                    guard let index=next.assets.firstIndex(where:{$0.id==id}) else {return}
                    next.assets[index].sequence=manifest;try ProjectStore.validate(next)
                    self.mutate("Refresh sequence manifest") {$0=next};self.media.reloadAsset(id:id,assets:self.project.assets,baseURL:self.baseURL)
                } catch {self.showError(error)}
            }
        }
    }
    func configureSourceAudio(id:UUID) {
        guard let asset=project.assets.first(where:{$0.id==id}) else {return}
        let generation=documentGeneration,route=asset.audioRouting ?? AudioRoutingSettings()
        let devices=MediaAudioPlayer.availableDevices()
        var deviceIDs:[String?]=[nil];var titles=["System default output"]
        for device in devices {deviceIDs.append(device.uid);titles.append("\(device.name) · \(device.outputChannels) channels")}
        if let uid=route.deviceUID,!deviceIDs.contains(where:{$0==uid}) {deviceIDs.append(uid);titles.append("Unavailable saved output")}
        let picker=ActionPopUp(items:titles,selected:deviceIDs.firstIndex(where:{$0==route.deviceUID}) ?? 0,action:{_ in})
        let input=ActionField(String(route.inputChannels),action:{_ in}),output=ActionField(String(route.outputChannels),action:{_ in})
        let gains=ActionField(route.gains.map {String($0)}.joined(separator:", "),action:{_ in})
        let muted=NSButton(checkboxWithTitle:"Mute routed audio",target:nil,action:nil);muted.state=route.muted ? .on : .off
        let a=NSAlert();a.messageText="Audio routing · "+asset.name
        a.informativeText="Row-major matrix: one row per output, one gain per input. Native routing supports up to 8 channels. Missing selected devices stay silent; physical channel verification is separate."
        let content=stack([picker,label("Input channels / output channels"),stack([input,output],vertical:false),label("Matrix gains, row by row"),gains,muted]);content.frame=NSRect(x:0,y:0,width:510,height:170);a.accessoryView=content
        a.addButton(withTitle:"Save route");a.addButton(withTitle:"Use ordinary system audio");a.addButton(withTitle:"Cancel")
        let response=a.runModal()
        guard documentGeneration==generation,project.assets.first(where:{$0.id==id})==asset else {return}
        do {
            if response == .alertSecondButtonReturn {try sourceRouting(id:id,routing:nil)}
            else if response == .alertFirstButtonReturn {
                guard let inputs=Int(input.stringValue),let outputs=Int(output.stringValue),(1...8).contains(inputs),(1...8).contains(outputs) else {throw ProjectError.invalid("native audio supports 1…8 input/output channels")}
                let fields=gains.stringValue.split(whereSeparator:{$0=="," || $0.isWhitespace});let values=fields.compactMap {Double($0)}
                guard values.count==fields.count else {throw ProjectError.invalid("matrix gains must be finite numbers")}
                try sourceRouting(id:id,routing:AudioRoutingSettings(deviceUID:deviceIDs[picker.indexOfSelectedItem],inputChannels:inputs,outputChannels:outputs,gains:values,muted:muted.state == .on))
            }
        } catch {showError(error)}
    }
}

@MainActor final class MediaSourceWindow:NSWindowController {
    private weak var editor:EditorController?
    private var selected:UUID?
    private var assetSnapshot:MediaAsset?
    private var documentToken=UUID()
    private var known:[MediaAsset]=[]
    private var knownAssignments=Set<UUID>()
    private let clock=label("",size:12)
    init(editor:EditorController) {
        self.editor=editor
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:670,height:500),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Sources · playback and routing";window.minSize=NSSize(width:640,height:430);window.center();super.init(window:window);window.isReleasedWhenClosed=false
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
    func updateClock() {
        guard let editor,let id=selected else {clock.stringValue="No source selected";return}
        clock.stringValue=String(format:"%@ · elapsed %.3f s · item %.3f s · duration %.3f s",editor.media.sourceFollowsMaster(for:id) ? "Follow master" : "Independent",editor.media.sourceElapsedTime(for:id),editor.media.playbackTime(for:id),editor.media.duration(for:id))
    }
    func refresh() {
        guard let editor,let content=window?.contentView else {return}
        updateClock()
        let assignments=Set(editor.project.surfaces.compactMap(\.mediaID))
        guard known != editor.project.assets || knownAssignments != assignments || documentToken != editor.documentGeneration || assetSnapshot==nil else {return}
        knownAssignments=assignments
        known=editor.project.assets;documentToken=editor.documentGeneration
        if !known.contains(where:{$0.id==selected}) {selected=known.first(where:{$0.id==editor.selectedMediaID})?.id ?? known.first?.id}
        content.subviews.forEach {$0.removeFromSuperview()}
        let picker=ActionPopUp(items:known.map {"\($0.name) · \($0.kind)"},selected:known.firstIndex(where:{$0.id==selected}) ?? 0) { [weak self] index in
            guard let self,self.known.indices.contains(index) else {return};self.selected=self.known[index].id;self.assetSnapshot=nil;self.refresh()
        }
        let importButtons=stack([ActionButton("Import image sequence…") {[weak editor] in editor?.importSequence()},ActionButton("Import image / video / audio…") {[weak editor] in editor?.importMedia()}],vertical:false)
        guard let asset=known.first(where:{$0.id==selected}) else {fill(stack([importButtons,label("Import media to edit its playback and routing.")]),in:content);return}
        assetSnapshot=asset
        let settings=MediaPlayback.effectiveSettings(asset)
        let modes=MediaPlaybackMode.allCases
        let mode=ActionPopUp(items:modes.map(\.rawValue),selected:modes.firstIndex(of:settings.mode) ?? 0,action:{_ in})
        let input=ActionField(String(settings.trimIn),action:{_ in}),output=ActionField(settings.trimOut.map {String($0)} ?? "",action:{_ in})
        let rate=ActionField(String(settings.rate),action:{_ in}),seed=ActionField(String(settings.randomSeed),action:{_ in}),interval=ActionField(String(settings.randomInterval),action:{_ in})
        let fps=ActionField(String(asset.sequence?.fps ?? 30),action:{_ in}),seek=ActionField("0",action:{_ in})
        for f in [input,output,rate,seed,interval,fps,seek] {f.widthAnchor.constraint(equalToConstant:100).isActive=true}
        let save=ActionButton("Save source settings") { [weak self,weak editor] in
            guard let self,let editor,editor.documentGeneration==self.documentToken,editor.project.assets.first(where:{$0.id==asset.id})==asset else {return}
            do {
                guard let start=Double(input.stringValue),let speed=Double(rate.stringValue),let randomSeed=UInt64(seed.stringValue),let step=Double(interval.stringValue) else {throw ProjectError.invalid("enter numeric source settings")}
                let end=output.stringValue.isEmpty ? nil : Double(output.stringValue)
                guard output.stringValue.isEmpty || end != nil else {throw ProjectError.invalid("Out must be empty or numeric")}
                var next=editor.project;guard let i=next.assets.firstIndex(where:{$0.id==asset.id}) else {return}
                next.assets[i].playback=MediaPlaybackSettings(trimIn:start,trimOut:end,rate:speed,mode:modes[mode.indexOfSelectedItem],randomSeed:randomSeed,randomInterval:step)
                if var sequence=asset.sequence {guard let value=Double(fps.stringValue) else {throw ProjectError.invalid("sequence FPS must be numeric")};sequence.fps=value;next.assets[i].sequence=sequence}
                try ProjectStore.validate(next);editor.mutate("Source playback settings") {$0=next};self.refresh()
            } catch {editor.showError(error)}
        }
        save.isEnabled=["video","audio","sequence"].contains(asset.kind)
        let transport=stack([ActionButton("Play source") {[weak editor] in editor?.media.sourcePlay(asset.id)},ActionButton("Pause source") {[weak editor] in editor?.media.sourcePause(asset.id)},ActionButton("Follow master") {[weak editor] in editor?.media.sourceFollowMaster(asset.id)}],vertical:false)
        let seekRow=stack([label("Source elapsed s"),seek,ActionButton("Seek source") {[weak editor] in if let v=Double(seek.stringValue),v.isFinite {editor?.media.sourceSeek(asset.id,to:v)}}],vertical:false)
        let routing=ActionButton("Audio routing…") {[weak editor] in editor?.configureSourceAudio(id:asset.id)};routing.isEnabled=asset.kind=="audio" || asset.kind=="video"
        let refresh=ActionButton("Refresh sequence manifest") {[weak editor] in editor?.refreshSequenceAsync(id:asset.id)};refresh.isEnabled=asset.kind=="sequence"
        let reset=ActionButton("Restore legacy playback") {[weak editor] in do {try editor?.sourceSettings(id:asset.id,playback:nil)} catch {editor?.showError(error)}}
        let temporal=["video","audio","sequence"].contains(asset.kind)
        let assigned=assignments.contains(asset.id)
        let timingControls:[NSControl]=[mode,input,output,rate,seed,interval]
        for field in timingControls {field.isEnabled=temporal}
        fps.isEnabled=asset.kind=="sequence";reset.isEnabled=temporal
        for control in transport.arrangedSubviews.compactMap({$0 as? NSControl}) {control.isEnabled=temporal && assigned}
        for control in seekRow.arrangedSubviews.compactMap({$0 as? NSControl}) {control.isEnabled=temporal && assigned}
        let help=label("Assign a source to a surface before using its transport. Elapsed time is independent of trim/item time. Play/Pause/Seek source leave the master and other sources intact. Follow master rejoins the show. Random uses the saved seed; a sequence plays frozen filenames consecutively. Missing frames show fallback; directory additions require Refresh. Reverse/random audio is silent with a diagnostic.",size:11);help.maximumNumberOfLines=0
        let assign=ActionButton("Assign to selected surface") {[weak editor] in editor?.selectedMediaID=asset.id;editor?.assignMedia()}
        assign.isEnabled=editor.selectedIndex != nil
        let rows=FlippedStackView(views:[importButtons,picker,assign,clock,label("Mode / signed speed / sequence FPS"),stack([mode,rate,fps],vertical:false),label("Trim In / Out (empty = duration)"),stack([input,output],vertical:false),label("Random seed / interval seconds"),stack([seed,interval],vertical:false),stack([save,reset],vertical:false),transport,seekRow,stack([routing,refresh],vertical:false),help])
        rows.orientation = .vertical;rows.alignment = .leading;rows.spacing=8;rows.translatesAutoresizingMaskIntoConstraints=false
        let viewport=scroll(rows);fill(viewport,in:content,inset:16)
        rows.widthAnchor.constraint(equalTo:viewport.contentView.widthAnchor,constant:-15).isActive=true
        for row in rows.arrangedSubviews {row.widthAnchor.constraint(equalTo:rows.widthAnchor).isActive=true}
    }
}
#endif
