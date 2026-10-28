#if os(macOS)
import AppKit
import MappingCore

/// Saved montage/clip edits are explicit; the strip selects clips and numeric
/// fields perform real timing edits through the production document adapter.
@MainActor final class MontageWindowController:NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
    weak var editor:EditorController?
    let montageTable=NSTableView(),clipTable=NSTableView()
    let strip=MontageStripView()
    var selectedMontageID:UUID?,selectedClipID:UUID?
    private(set) var selectedAssetID:UUID?
    let nameField=ActionField("Montage 1",action:{_ in})
    let durationField=ActionField("10",action:{_ in})
    let montageLoopButton=NSButton(checkboxWithTitle:"Loop montage",target:nil,action:nil)
    let gapPicker=ActionPopUp(items:["Black","Skip"],action:{_ in})
    let assetPicker=ActionPopUp(items:[],action:{_ in})
    let clipStartField=ActionField("0",action:{_ in})
    let clipDurationField=ActionField("1",action:{_ in})
    let sourceInField=ActionField("0",action:{_ in})
    let sourceOutField=ActionField("1",action:{_ in})
    let rateField=ActionField("1",action:{_ in})
    let clipLoopButton=NSButton(checkboxWithTitle:"Loop trimmed video",target:nil,action:nil)
    let newMontageButton=ActionButton("New montage",action:{})
    let createButton=ActionButton("Create montage",action:{})
    let saveButton=ActionButton("Save montage properties",action:{})
    let deleteButton=ActionButton("Delete montage",action:{})
    let assignButton=ActionButton("Assign montage to selected surface",action:{})
    let newClipButton=ActionButton("New clip",action:{})
    let addClipButton=ActionButton("Add clip",action:{})
    let saveClipButton=ActionButton("Save clip",action:{})
    let deleteClipButton=ActionButton("Delete clip",action:{})
    let seekClipButton=ActionButton("Seek clip start",action:{})
    let summary=label("",size:11),warning=label("",size:11),sourceInfo=label("",size:11)
    private let heading=label("New montage draft",size:15,bold:true)
    private let clipHeading=label("New clip draft",size:12,bold:true)
    private let playheadLabel=label("0.000 s",size:11)
    private var assetIDs:[UUID]=[],clips:[MontageClip]=[]
    private var loadedMontage:MediaMontage?,loadedClip:MontageClip?
    private var draftInitialized=false,clipDraftInitialized=false,refreshing=false
    private var selectedMontage:MediaMontage? {editor?.project.montages.first {$0.id==selectedMontageID}}
    private var selectedClip:MontageClip? {selectedMontage?.clips.first {$0.id==selectedClipID}}
    private var selectedAsset:MediaAsset? {editor?.project.assets.first {$0.id==selectedAssetID}}

    init(editor:EditorController) {
        self.editor=editor
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1140,height:790),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.title="ApertureCue · Source Montage";window.minSize=NSSize(width:1010,height:670)
        window.isReleasedWhenClosed=false;window.center()
        makeUI();bind();refresh()
    }
    required init?(coder:NSCoder) {fatalError()}
    private func truncated(_ text:String,size:CGFloat=11)->NSTextField {
        let field=label(text,size:size)
        field.lineBreakMode = .byTruncatingTail;field.maximumNumberOfLines=1;field.toolTip=text
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return field
    }
    private func makeTable(_ table:NSTableView,columns:[(String,String,CGFloat)],height:CGFloat)->NSScrollView {
        for (id,title,width) in columns {
            let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title=title;column.width=width
            column.minWidth=id=="source" ? 100 : 55;table.addTableColumn(column)
        }
        if columns.count==1 {table.headerView=nil}
        table.rowHeight=27;table.dataSource=self;table.delegate=self
        table.backgroundColor = .clear;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        return scroll(table,height:height)
    }
    private func makeUI() {
        guard let content=window?.contentView else {return}
        let saved=makeTable(montageTable,columns:[("name","Montage",240)],height:220)
        let left=FlippedStackView(views:[label("MONTAGE SOURCES",bold:true),saved,newMontageButton,deleteButton,
            label("ASSIGNMENT",bold:true),assignButton,truncated("Import images/video from the main editor before adding clips.")])
        left.orientation = .vertical;left.alignment = .leading;left.spacing=9;left.translatesAutoresizingMaskIntoConstraints=false
        left.widthAnchor.constraint(equalToConstant:250).isActive=true
        for view in left.arrangedSubviews {view.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true}
        let leftScroll=scroll(left);leftScroll.widthAnchor.constraint(equalToConstant:265).isActive=true
        nameField.widthAnchor.constraint(equalToConstant:260).isActive=true
        for field in [durationField,clipStartField,clipDurationField,sourceInField,sourceOutField,rateField] {field.widthAnchor.constraint(equalToConstant:80).isActive=true}
        let titleRow=stack([label("Name"),nameField],vertical:false)
        let settingsRow=stack([label("Duration s"),durationField,montageLoopButton,label("Gap"),gapPicker],vertical:false)
        let montageActions=stack([createButton,saveButton],vertical:false)
        strip.heightAnchor.constraint(equalToConstant:104).isActive=true
        let clipScroll=makeTable(clipTable,columns:[("source","Source",270),("start","Start s",85),("duration","Duration s",95),("trim","Video In / Out",125),("rate","Rate / loop",95)],height:155)
        let clipListActions=stack([newClipButton,deleteClipButton,seekClipButton,playheadLabel],vertical:false)
        let sourceRow=stack([label("Source asset"),assetPicker],vertical:false)
        assetPicker.widthAnchor.constraint(equalTo:sourceRow.widthAnchor,constant:-92).isActive=true
        let placement=stack([label("Start s"),clipStartField,label("Duration s"),clipDurationField],vertical:false)
        let trim=stack([label("Video In s"),sourceInField,label("Out s"),sourceOutField,label("Rate"),rateField,clipLoopButton],vertical:false)
        let clipActions=stack([addClipButton,saveClipButton],vertical:false)
        let help=label("Save montage properties before editing clips. Clips use [start,end); touching is allowed, overlaps are rejected. Click a strip block to select it; edit timing below. Video clips are silent. Reverse/crossfade and montage audio are not available in this stage.",size:11)
        for field in [summary,warning,sourceInfo,help] {
            field.maximumNumberOfLines=0;field.lineBreakMode = .byWordWrapping
            field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        }
        for field in [heading,clipHeading,playheadLabel] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        }
        warning.textColor = .systemOrange
        let rows:[NSView]=[heading,titleRow,settingsRow,montageActions,summary,warning,strip,clipScroll,clipListActions,clipHeading,sourceRow,placement,trim,sourceInfo,clipActions,help]
        let right=FlippedStackView(views:rows)
        right.orientation = .vertical;right.alignment = .leading;right.spacing=9;right.translatesAutoresizingMaskIntoConstraints=false
        for view in rows {view.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true}
        let rightScroll=scroll(right)
        let work=stack([leftScroll,rightScroll],vertical:false,spacing:16);work.alignment = .top
        rightScroll.widthAnchor.constraint(equalTo:work.widthAnchor,constant:-281).isActive=true
        right.widthAnchor.constraint(equalTo:rightScroll.contentView.widthAnchor,constant:-15).isActive=true
        leftScroll.heightAnchor.constraint(equalTo:work.heightAnchor).isActive=true
        rightScroll.heightAnchor.constraint(equalTo:work.heightAnchor).isActive=true
        fill(work,in:content,inset:14)
    }
    private func bind() {
        montageLoopButton.target=self;montageLoopButton.action=#selector(loopChanged(_:))
        clipLoopButton.target=self;clipLoopButton.action=#selector(loopChanged(_:))
        newMontageButton.actionBlock={[weak self] in self?.newMontageDraft()}
        createButton.actionBlock={[weak self] in self?.createMontage()}
        saveButton.actionBlock={[weak self] in self?.saveMontage()}
        deleteButton.actionBlock={[weak self] in self?.deleteMontage()}
        assignButton.actionBlock={[weak self] in
            guard let self,let editor=self.editor,let id=self.selectedMontageID else {return}
            self.perform {try editor.montageAssign(id:id)}
        }
        newClipButton.actionBlock={[weak self] in self?.newClipDraft()}
        addClipButton.actionBlock={[weak self] in self?.saveClip(asNew:true)}
        saveClipButton.actionBlock={[weak self] in self?.saveClip(asNew:false)}
        deleteClipButton.actionBlock={[weak self] in self?.deleteClip()}
        seekClipButton.actionBlock={[weak self] in
            guard let self,let clip=self.selectedClip else {return}
            self.editor?.seekShow(to:clip.start);self.updatePlayhead()
        }
        assetPicker.actionBlock={[weak self] index in
            guard let self,self.assetIDs.indices.contains(index) else {return}
            self.selectedAssetID=self.assetIDs[index]
            if self.selectedClipID==nil {self.seedClipSource()}
            self.updateSourceControls();self.updateSummary()
        }
        gapPicker.actionBlock={[weak self] _ in self?.updateSummary()}
        strip.onSelect={[weak self] id in self?.selectClip(id:id)}
        for field in [durationField,clipStartField,clipDurationField,sourceInField,sourceOutField,rateField] {
            field.actionBlock={[weak self] _ in self?.updateSummary()}
        }
    }
    @objc private func loopChanged(_ sender:NSButton) {updateSummary()}
    func newMontageDraft() {
        selectedMontageID=nil;selectedClipID=nil;loadedMontage=nil;loadedClip=nil
        draftInitialized=true;clipDraftInitialized=false
        nameField.stringValue="Montage \((editor?.project.montages.count ?? 0)+1)"
        durationField.stringValue="10";montageLoopButton.state = .off;gapPicker.selectItem(at:0)
        refresh()
    }
    func selectMontage(id:UUID?) {
        guard let id else {newMontageDraft();return}
        selectedMontageID=id;selectedClipID=nil;loadedMontage=nil;loadedClip=nil;clipDraftInitialized=false
        refresh()
    }
    func selectClip(id:UUID?) {
        selectedClipID=id;loadedClip=nil;clipDraftInitialized=false;refresh()
    }
    func selectAsset(id:UUID) {
        guard let index=assetIDs.firstIndex(of:id) else {return}
        assetPicker.selectItem(at:index);selectedAssetID=id
        if selectedClipID==nil {seedClipSource()}
        updateSourceControls();updateSummary()
    }
    func newClipDraft() {
        selectedClipID=nil;loadedClip=nil;clipDraftInitialized=true
        clipStartField.stringValue=String(clips.map {$0.start+$0.duration}.max() ?? 0)
        seedClipSource();refresh()
    }
    func refresh() {
        guard let editor else {return}
        refreshing=true;defer {refreshing=false}
        if selectedMontageID != nil && selectedMontage==nil {selectedMontageID=nil;loadedMontage=nil;draftInitialized=false;clipDraftInitialized=false}
        if !draftInitialized,selectedMontageID==nil {
            selectedMontageID=editor.project.montages.first?.id
            if selectedMontageID==nil {nameField.stringValue="Montage \(editor.project.montages.count+1)";durationField.stringValue="10";montageLoopButton.state = .off;gapPicker.selectItem(at:0)}
            draftInitialized=true
        }
        if let montage=selectedMontage {
            let old=loadedMontage
            if old?.id != montage.id || old?.name != montage.name || old?.duration != montage.duration || old?.loop != montage.loop || old?.gapMode != montage.gapMode {
                nameField.stringValue=montage.name;durationField.stringValue=String(montage.duration)
                montageLoopButton.state=montage.loop ? .on : .off;gapPicker.selectItem(at:montage.gapMode == .black ? 0 : 1)
            }
            loadedMontage=montage
            clips=montage.clips.sorted {$0.start == $1.start ? $0.id.uuidString<$1.id.uuidString : $0.start<$1.start}
        } else {clips=[]}
        let assets=editor.project.assets.filter {$0.kind=="image" || $0.kind=="video"}
        assetIDs=assets.map(\.id)
        if !assetIDs.contains(where:{$0==selectedAssetID}) {selectedAssetID=assetIDs.first}
        assetPicker.removeAllItems();assetPicker.addItems(withTitles:assets.map {String($0.name.prefix(55))+" · "+String($0.id.uuidString.prefix(6))})
        if let id=selectedAssetID,let i=assetIDs.firstIndex(of:id) {assetPicker.selectItem(at:i)}
        if selectedClipID != nil && selectedClip==nil {selectedClipID=nil;loadedClip=nil;clipDraftInitialized=false}
        if let clip=selectedClip {
            if loadedClip != clip {
                selectedAssetID=clip.assetID
                if let i=assetIDs.firstIndex(of:clip.assetID) {assetPicker.selectItem(at:i)}
                clipStartField.stringValue=String(clip.start);clipDurationField.stringValue=String(clip.duration)
                sourceInField.stringValue=String(clip.sourceIn);sourceOutField.stringValue=String(clip.sourceOut)
                rateField.stringValue=String(clip.rate);clipLoopButton.state=clip.loop ? .on : .off
                loadedClip=clip
            }
        } else if !clipDraftInitialized {
            clipStartField.stringValue=String(clips.map {$0.start+$0.duration}.max() ?? 0)
            seedClipSource();clipDraftInitialized=true
        }
        montageTable.reloadData();clipTable.reloadData()
        if let i=editor.project.montages.firstIndex(where:{$0.id==selectedMontageID}) {montageTable.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false)} else {montageTable.deselectAll(nil)}
        if let i=clips.firstIndex(where:{$0.id==selectedClipID}) {clipTable.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false)} else {clipTable.deselectAll(nil)}
        let saved=selectedMontage != nil,hasClip=selectedClip != nil,hasAsset=selectedAsset != nil
        createButton.isEnabled = !saved;saveButton.isEnabled=saved;deleteButton.isEnabled=saved
        assignButton.isEnabled=saved && editor.project.surfaces.contains(where:{$0.id==editor.selectedID})
        newClipButton.isEnabled=saved;addClipButton.isEnabled=saved && !hasClip && hasAsset
        saveClipButton.isEnabled=saved && hasClip && hasAsset;deleteClipButton.isEnabled=hasClip;seekClipButton.isEnabled=hasClip
        assetPicker.isEnabled=saved && !assetIDs.isEmpty
        clipStartField.isEnabled=saved && hasAsset;clipDurationField.isEnabled=saved && hasAsset
        heading.stringValue=saved ? "Saved montage · edit properties explicitly" : "New montage draft · create to add clips"
        clipHeading.stringValue=hasClip ? "Saved clip" : "New clip draft · use Add clip to save"
        strip.montage=selectedMontage;strip.selectedClipID=selectedClipID
        strip.assetNames=Dictionary(uniqueKeysWithValues:assets.map {($0.id,$0.name)})
        updateSourceControls();updateSummary();updatePlayhead()
    }
    private func seedClipSource() {
        guard let asset=selectedAsset else {
            clipDurationField.stringValue="1";sourceInField.stringValue="0";sourceOutField.stringValue="1";rateField.stringValue="1";clipLoopButton.state = .off;return
        }
        let sourceDuration=asset.kind=="video" ? (editor?.media.duration(for:asset.id) ?? 0) : 0
        let span=sourceDuration.isFinite && sourceDuration>0 ? sourceDuration : 1
        sourceInField.stringValue="0";sourceOutField.stringValue=asset.kind=="video" ? String(span) : "1"
        rateField.stringValue="1";clipLoopButton.state = .off
        clipDurationField.stringValue=String(asset.kind=="video" ? min(5,span) : 1)
    }
    private func updateSourceControls() {
        let video=selectedAsset?.kind=="video",enabled=selectedMontage != nil && video
        for field in [sourceInField,sourceOutField,rateField] {field.isEnabled=enabled}
        clipLoopButton.isEnabled=enabled
        guard let asset=selectedAsset else {sourceInfo.stringValue="Import an image or video in the main editor to add clips.";return}
        if video {
            let duration=editor?.media.duration(for:asset.id) ?? 0
            let info=duration.isFinite && duration>0 ? String(format:"Decoded file duration %.3f s.",duration) : "File duration is not ready; enter trim explicitly and check playback diagnostics."
            sourceInfo.stringValue="\(asset.name) · \(info) Positive rate 0.25…4; In/Out trim source seconds. Montage video is silent."
        } else {sourceInfo.stringValue="\(asset.name) · Image clip: set Start and Duration."}
        sourceInfo.toolTip=sourceInfo.stringValue
    }
    private func updateSummary() {
        guard let editor else {return}
        let gap=gapPicker.indexOfSelectedItem==1 ? "Skip" : "Black"
        summary.stringValue="\(clips.count) saved clips · duration \(durationField.stringValue) s · gap \(gap) · montage loop \(montageLoopButton.state == .on ? "on" : "off"). Changes take effect only after Save."
        var notices:[String]=[]
        if selectedMontage==nil {notices.append("Create the montage before adding clips or assigning it to a surface.")}
        if assetIDs.isEmpty {notices.append("No image/video assets: use Import in the main editor.")}
        if let end=Double(durationField.stringValue),editor.project.timelineSettings.stopAtEnd,end>editor.project.timelineSettings.duration {
            notices.append(String(format:"Master timeline stops at %.3f s; adjust its duration to play the full montage.",editor.project.timelineSettings.duration))
        }
        if let asset=selectedAsset,asset.kind=="video" {
            let actual=editor.media.duration(for:asset.id)
            if let out=Double(sourceOutField.stringValue),actual.isFinite,actual>0,out>actual+1e-8 {notices.append(String(format:"Out exceeds the current decoded file duration %.3f s.",actual))}
            if clipLoopButton.state != .on,let start=Double(sourceInField.stringValue),let end=Double(sourceOutField.stringValue),let rate=Double(rateField.stringValue),rate>0,let duration=Double(clipDurationField.stringValue),duration>(end-start)/rate+1e-8 {
                notices.append("A non-loop video clip cannot outlast its trimmed source span at the chosen rate.")
            }
        }
        if let start=Double(clipStartField.stringValue),let duration=Double(clipDurationField.stringValue),let end=Double(durationField.stringValue),start+duration>end+1e-8 {notices.append("Draft clip end exceeds montage duration; extend the montage or shorten this clip.")}
        if let id=editor.selectedID,let surface=editor.project.surfaces.first(where:{$0.id==id}) {assignButton.toolTip="Assign to \(surface.name) · \(id.uuidString)"} else {assignButton.toolTip="Select a current surface in the main editor first."}
        warning.stringValue=notices.joined(separator:" ");warning.toolTip=warning.stringValue
    }
    func updatePlayhead() {
        guard let editor else {return}
        let time=editor.showRuntime.time
        let text=String(format:"Master %.3f s",time)
        if playheadLabel.stringValue != text {playheadLabel.stringValue=text}
        if let montage=selectedMontage,montage.duration.isFinite,montage.duration>0 {
            strip.playhead=montage.loop ? time.truncatingRemainder(dividingBy:montage.duration) : min(time,montage.duration)
        } else {strip.playhead=0}
    }
    private func number(_ field:NSTextField,_ name:String)throws->Double {
        guard let value=Double(field.stringValue),value.isFinite else {throw ProjectError.invalid("Enter a finite \(name)")}
        return value
    }
    private func perform(_ action:()throws->Void) {
        do {try action();refresh()} catch {editor?.showError(error)}
    }
    private func createMontage() {
        guard let editor else {return}
        perform {
            selectedMontageID=try editor.montageCreate(name:nameField.stringValue,duration:number(durationField,"montage duration"),loop:montageLoopButton.state == .on,gapMode:gapPicker.indexOfSelectedItem==1 ? .skip : .black)
            selectedClipID=nil;loadedMontage=nil;loadedClip=nil;clipDraftInitialized=false
        }
    }
    private func saveMontage() {
        guard let editor,let id=selectedMontageID else {return}
        perform {try editor.montageUpdate(id:id,name:nameField.stringValue,duration:number(durationField,"montage duration"),loop:montageLoopButton.state == .on,gapMode:gapPicker.indexOfSelectedItem==1 ? .skip : .black)}
    }
    private func deleteMontage() {
        guard let editor,let id=selectedMontageID else {return}
        perform {
            try editor.montageDelete(id:id)
            selectedMontageID=editor.project.montages.first?.id;selectedClipID=nil;loadedMontage=nil;loadedClip=nil;clipDraftInitialized=false
            if selectedMontageID==nil {draftInitialized=false}
        }
    }
    private func saveClip(asNew:Bool) {
        guard let editor,let montageID=selectedMontageID,let asset=selectedAsset else {return}
        perform {
            let id=asNew ? UUID() : selectedClipID
            guard let id else {throw ProjectError.invalid("Select a saved clip to update")}
            let video=asset.kind=="video"
            let clip=MontageClip(id:id,assetID:asset.id,start:try number(clipStartField,"clip start"),duration:try number(clipDurationField,"clip duration"),
                sourceIn:video ? try number(sourceInField,"source In") : 0,sourceOut:video ? try number(sourceOutField,"source Out") : 1,
                rate:video ? try number(rateField,"source rate") : 1,loop:video && clipLoopButton.state == .on)
            try editor.montageSaveClip(montageID:montageID,clip:clip)
            selectedClipID=id;loadedClip=nil;clipDraftInitialized=false
        }
    }
    private func deleteClip() {
        guard let editor,let montageID=selectedMontageID,let clipID=selectedClipID else {return}
        perform {try editor.montageDeleteClip(montageID:montageID,clipID:clipID);selectedClipID=nil;loadedClip=nil;clipDraftInitialized=false}
    }
    func numberOfRows(in tableView:NSTableView)->Int {tableView === montageTable ? editor?.project.montages.count ?? 0 : clips.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        if tableView === montageTable {
            guard let montages=editor?.project.montages,montages.indices.contains(row) else {return nil}
            let montage=montages[row];return truncated("\(montage.name) · \(montage.clips.count) clips")
        }
        guard clips.indices.contains(row) else {return nil}
        let clip=clips[row],asset=editor?.project.assets.first {$0.id==clip.assetID}
        let text:String
        switch tableColumn?.identifier.rawValue {
        case "start":text=String(format:"%.4g",clip.start)
        case "duration":text=String(format:"%.4g",clip.duration)
        case "trim":text=asset?.kind=="video" ? String(format:"%.4g / %.4g",clip.sourceIn,clip.sourceOut) : "Image"
        case "rate":text=asset?.kind=="video" ? String(format:"%.3g×",clip.rate)+(clip.loop ? " loop" : "") : "—"
        default:text=asset?.name ?? "Missing asset \(clip.assetID.uuidString.prefix(8))"
        }
        return truncated(text)
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !refreshing,let table=notification.object as? NSTableView else {return}
        if table === montageTable {
            guard let montages=editor?.project.montages,montages.indices.contains(montageTable.selectedRow) else {return}
            selectMontage(id:montages[montageTable.selectedRow].id)
        } else if clips.indices.contains(clipTable.selectedRow) {selectClip(id:clips[clipTable.selectedRow].id)}
    }
}

/// Read-only placement overview with real clip selection. Timing changes are
/// committed through the numeric editor rather than an unimplemented drag mode.
@MainActor final class MontageStripView:NSView {
    var montage:MediaMontage? {didSet {needsDisplay=true}}
    var selectedClipID:UUID? {didSet {needsDisplay=true}}
    var assetNames:[UUID:String]=[:] {didSet {needsDisplay=true}}
    var playhead=0.0 {didSet {if oldValue != playhead {needsDisplay=true}}}
    var onSelect:((UUID)->Void)?
    override var isFlipped:Bool {true}
    private var plot:NSRect {NSRect(x:8,y:28,width:max(1,bounds.width-16),height:48)}
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.08,alpha:1).setFill();bounds.fill()
        guard let montage,montage.duration.isFinite,montage.duration>0 else {
            drawText("Create or select a montage to inspect clip placement",in:bounds.insetBy(dx:8,dy:28));return
        }
        drawText(String(format:"0 s · click a clip to select · %.4g s",montage.duration),in:NSRect(x:8,y:4,width:max(1,bounds.width-16),height:20))
        NSColor(calibratedWhite:0.17,alpha:1).setFill();plot.fill()
        for clip in montage.clips.sorted(by:{$0.start<$1.start}) where clip.start.isFinite && clip.duration.isFinite {
            let x=plot.minX+CGFloat(clip.start/montage.duration)*plot.width
            let width=max(0.5,CGFloat(clip.duration/montage.duration)*plot.width)
            let rect=NSRect(x:x,y:plot.minY,width:width,height:plot.height).intersection(plot)
            guard !rect.isNull && rect.width>0 else {continue}
            (clip.id==selectedClipID ? NSColor.systemBlue : NSColor.systemTeal.withAlphaComponent(0.65)).setFill();rect.insetBy(dx:0.5,dy:1).fill()
            if rect.width>50 {
                NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:rect).addClip()
                drawText(assetNames[clip.assetID] ?? "Missing asset",in:rect.insetBy(dx:5,dy:6))
                drawText(String(format:"%.4g + %.4g s",clip.start,clip.duration),in:NSRect(x:rect.minX+5,y:rect.minY+27,width:max(1,rect.width-10),height:16))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if playhead.isFinite,(0...montage.duration).contains(playhead) {
            let x=plot.minX+CGFloat(playhead/montage.duration)*plot.width
            NSColor.systemRed.setStroke();let line=NSBezierPath();line.move(to:NSPoint(x:x,y:plot.minY-4));line.line(to:NSPoint(x:x,y:plot.maxY+4));line.stroke()
        }
        drawText("Gap: \(montage.gapMode == .skip ? "Skip" : "Black") · \(montage.loop ? "Montage loops" : "Montage does not loop")",in:NSRect(x:8,y:82,width:max(1,bounds.width-16),height:18))
    }
    private func drawText(_ text:String,in rect:NSRect) {
        let style=NSMutableParagraphStyle();style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.white,.paragraphStyle:style])
    }
    override func mouseDown(with event:NSEvent) {
        guard let montage,montage.duration.isFinite,montage.duration>0 else {return}
        let point=convert(event.locationInWindow,from:nil)
        guard plot.contains(point) else {return}
        let time=Double((point.x-plot.minX)/plot.width)*montage.duration
        if let clip=montage.clips.first(where:{$0.start<=time && time<$0.start+$0.duration}) {onSelect?(clip.id)}
    }
}
#endif
