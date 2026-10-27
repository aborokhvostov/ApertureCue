#if os(macOS)
import AppKit
import MappingCore

/// Graphical parameter editing and the show-clock transport live in a separate
/// native window. Document changes refresh controls; ticks update the playhead.
@MainActor final class TimelineWindowController:NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
    weak var editor:EditorController?
    let canvas=TimelineCanvas()
    let trackTable=NSTableView(),markerTable=NSTableView()
    var selectedTrackID:UUID?
    var selectedKeyIndex:Int?
    private var selectedMarkerID:UUID?
    private var surfaceIDs:[UUID]=[],cueIDs:[UUID]=[]
    private var refreshing=false
    private let surfacePicker=ActionPopUp(items:[],action:{_ in})
    private let parameterPicker=ActionPopUp(items:TimelineEngine.parameters,action:{_ in})
    private let playButton=ActionButton("Play",action:{})
    private let timeField=ActionField("0",action:{_ in})
    private let positionLabel=label("0.000 s",size:12,bold:true)
    private let durationField=ActionField("10",action:{_ in})
    private let loopStartField=ActionField("0",action:{_ in})
    private let loopEndField=ActionField("10",action:{_ in})
    private let loopButton=NSButton(checkboxWithTitle:"Loop range",target:nil,action:nil)
    private let stopAtDurationButton=NSButton(checkboxWithTitle:"Stop at duration",target:nil,action:nil)
    private let viewStartField=ActionField("0",action:{_ in})
    private let viewEndField=ActionField("10",action:{_ in})
    private let keyTimeField=ActionField("0",action:{_ in})
    private let keyValueField=ActionField("1",action:{_ in})
    private let interpolationPicker=ActionPopUp(items:["Hold","Linear","Bezier"],selected:1,action:{_ in})
    private let c1x=ActionField("0.3333333333",action:{_ in}),c1y=ActionField("0.3333333333",action:{_ in})
    private let c2x=ActionField("0.6666666667",action:{_ in}),c2y=ActionField("0.6666666667",action:{_ in})
    private let keyCaption=label("Select a key or double-click the graph",size:11)
    private let markerName=ActionField("Marker",action:{_ in})
    private let markerAction=ActionPopUp(items:["Pause","Recall scene"],action:{_ in})
    private let markerCue=ActionPopUp(items:[],action:{_ in})
    private let trackToggle=ActionButton("Disable track",action:{})
    private let deleteKeyButton=ActionButton("Delete key",action:{})
    private let saveKeyButton=ActionButton("Save key",action:{})

    init(editor:EditorController) {
        self.editor=editor
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.title="ApertureCue · Parameter Timeline"; window.minSize=NSSize(width:1030,height:720)
        window.isReleasedWhenClosed=false; window.center()
        makeUI(); bind(); refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func fixedWidth(_ views:[NSView],_ width:CGFloat) { views.forEach {$0.widthAnchor.constraint(equalToConstant:width).isActive=true} }
    private func table(_ table:NSTableView,height:CGFloat)->NSScrollView {
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("name")); column.width=250
        table.addTableColumn(column); table.headerView=nil; table.rowHeight=26
        table.dataSource=self; table.delegate=self; table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        return scroll(table,height:height)
    }
    private func makeUI() {
        guard let content=window?.contentView else { return }
        let transport=stack([playButton,ActionButton("Stop") {[weak self] in self?.editor?.stopShow()},positionLabel,label("Seek s"),timeField,ActionButton("Seek") {[weak self] in self?.seekTyped()},ActionButton("Undo") {[weak self] in self?.editor?.undoEdit()},ActionButton("Redo") {[weak self] in self?.editor?.redoEdit()}],vertical:false)
        fixedWidth([timeField],90)
        let durationRow=stack([label("Duration / graph end s"),durationField,stopAtDurationButton,ActionButton("Apply duration / loop") {[weak self] in self?.saveSettings()}],vertical:false)
        let loopRow=stack([loopButton,label("Start s"),loopStartField,label("End s"),loopEndField],vertical:false)
        let settings=stack([durationRow,loopRow],spacing:6)
        fixedWidth([durationField,loopStartField,loopEndField],90)
        let tracks=table(trackTable,height:170),markers=table(markerTable,height:100)
        let left=FlippedStackView(views:[label("PARAMETER TRACKS",bold:true),tracks,
            stack([trackToggle,ActionButton("Delete track") {[weak self] in self?.deleteTrack()}],vertical:false),
            label("Surface"),surfacePicker,label("Parameter"),parameterPicker,
            ActionButton("Add track") {[weak self] in self?.addTrack()},
            label("TIME MARKERS",bold:true),markers,markerName,markerAction,markerCue,
            ActionButton("Add marker at playhead") {[weak self] in self?.addMarker()},
            stack([ActionButton("Seek marker") {[weak self] in self?.seekMarker()},ActionButton("Delete marker") {[weak self] in self?.deleteMarker()}],vertical:false)])
        left.orientation = .vertical;left.alignment = .leading;left.spacing=6;left.translatesAutoresizingMaskIntoConstraints=false
        left.widthAnchor.constraint(equalToConstant:270).isActive=true
        for view in [tracks,markers,surfacePicker,parameterPicker,markerName,markerAction,markerCue] {view.widthAnchor.constraint(equalTo: left.widthAnchor).isActive=true}
        let leftScroll=scroll(left); leftScroll.widthAnchor.constraint(equalToConstant:285).isActive=true
        let viewRange=stack([label("View s"),viewStartField,label("to"),viewEndField,ActionButton("View") {[weak self] in self?.applyViewRange()},ActionButton("Fit") {[weak self] in self?.fitView()},ActionButton("＋") {[weak self] in self?.zoom(0.5)},ActionButton("−") {[weak self] in self?.zoom(2)}],vertical:false)
        fixedWidth([viewStartField,viewEndField],75)
        let keyRow=stack([label("Time s"),keyTimeField,label("Value"),keyValueField,interpolationPicker,saveKeyButton,deleteKeyButton],vertical:false)
        fixedWidth([keyTimeField,keyValueField],80); interpolationPicker.widthAnchor.constraint(equalToConstant:100).isActive=true
        let tangentRow=stack([label("Bezier C1 x/y"),c1x,c1y,label("C2 x/y"),c2x,c2y],vertical:false)
        fixedWidth([c1x,c1y,c2x,c2y],75)
        canvas.translatesAutoresizingMaskIntoConstraints=false
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant:240).isActive=true
        let right=stack([viewRange,canvas,keyCaption,keyRow,tangentRow],spacing:8)
        for view in [viewRange,canvas,keyCaption,keyRow,tangentRow] {view.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true}
        let work=stack([leftScroll,right],vertical:false,spacing:16);work.alignment = .top
        right.widthAnchor.constraint(equalTo:work.widthAnchor,constant:-301).isActive=true
        leftScroll.heightAnchor.constraint(equalTo:work.heightAnchor).isActive=true
        right.heightAnchor.constraint(equalTo:work.heightAnchor).isActive=true
        right.setContentHuggingPriority(.defaultLow,for:.horizontal)
        canvas.setContentHuggingPriority(.defaultLow,for:.vertical)
        let help=label("Double-click: add key · drag diamond/handle: edit · ruler: seek · edits commit on mouse release",size:11)
        let markerHelp=label("Markers require time > 0 and fire only on forward crossing. Seek and loop-start wrap do not fire them.",size:11)
        let root=stack([transport,settings,work,help,markerHelp],spacing:12)
        root.edgeInsets=NSEdgeInsets(top:14,left:14,bottom:14,right:14)
        fill(root,in:content)
        for v in [transport,settings,work,help,markerHelp] {v.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-28).isActive=true}
        work.setContentHuggingPriority(.defaultLow,for:.vertical)
    }
    private func bind() {
        playButton.actionBlock={[weak self] in guard let e=self?.editor else {return};if e.showRuntime.isPlaying {e.pauseShow()} else {e.playShow()}}
        trackToggle.actionBlock={[weak self] in self?.toggleTrack()}
        saveKeyButton.actionBlock={[weak self] in self?.saveTypedKey()}
        deleteKeyButton.actionBlock={[weak self] in self?.deleteKey()}
        timeField.actionBlock={[weak self] _ in self?.seekTyped()}
        interpolationPicker.actionBlock={[weak self] _ in self?.updateCurveControls()}
        markerAction.actionBlock={[weak self] _ in self?.markerCue.isEnabled=self?.markerAction.indexOfSelectedItem == 1 && !(self?.cueIDs.isEmpty ?? true)}
        canvas.onSelectKey={[weak self] index in self?.selectedKeyIndex=index;self?.loadKeyFields()}
        canvas.onSeek={[weak self] time in self?.editor?.seekShow(to:time)}
        canvas.onInsertKey={[weak self] time,value in
            guard let self,let id=self.selectedTrackID else {return}
            self.perform {try self.editor?.timelineEditKey(trackID:id,index:nil,key:AutomationKeyframe(time:time,value:value))}
            self.selectKey(at:time)
        }
        canvas.onEditKey={[weak self] index,key in
            guard let self,let id=self.selectedTrackID else {return}
            self.perform {try self.editor?.timelineEditKey(trackID:id,index:index,key:key)}
            self.selectKey(at:key.time)
        }
    }
    private func perform(_ action:()throws->Void) {
        do {try action()} catch {editor?.showError(error)}
        refresh()
    }
    private func number(_ field:NSTextField,_ name:String)throws->Double {
        guard let value=Double(field.stringValue),value.isFinite else {throw ProjectError.invalid("enter a finite \(name)")};return value
    }
    private var selectedTrack:AutomationTrack? {guard let id=selectedTrackID else {return nil};return editor?.project.timeline.first {$0.id==id}}
    private func chartRange(_ track:AutomationTrack?)->ClosedRange<Double> {
        guard let track else {return 0...1}
        let limits:ClosedRange<Double>=track.parameter == "opacity" ? 0...1 : (track.parameter == "gamma" ? 0.01...10 : 0...16)
        if track.parameter == "opacity" {return limits}
        let values=track.keyframes.map(\.value),lo=values.min() ?? limits.lowerBound,hi=values.max() ?? limits.upperBound
        let margin=max(0.1,(hi-lo)*0.25,abs(hi)*0.25)
        return max(limits.lowerBound,lo-margin)...min(limits.upperBound,hi+margin)
    }
    func refresh() {
        guard let editor else {return}
        refreshing=true;defer {refreshing=false}
        let oldSurface=surfaceIDs.indices.contains(surfacePicker.indexOfSelectedItem) ? surfaceIDs[surfacePicker.indexOfSelectedItem] : editor.selectedID
        var surfaces=editor.project.surfaces,known=Set(surfaces.map(\.id))
        for surface in editor.project.cues.flatMap(\.surfaces) where known.insert(surface.id).inserted {surfaces.append(surface)}
        surfaceIDs=surfaces.map(\.id);surfacePicker.removeAllItems();surfacePicker.addItems(withTitles:surfaces.map {String($0.name.prefix(40))+" · "+$0.id.uuidString.prefix(6)})
        surfacePicker.selectItem(at:oldSurface.flatMap {surfaceIDs.firstIndex(of:$0)} ?? 0)
        let oldCue=cueIDs.indices.contains(markerCue.indexOfSelectedItem) ? cueIDs[markerCue.indexOfSelectedItem] : nil
        cueIDs=editor.project.cues.map(\.id);markerCue.removeAllItems();markerCue.addItems(withTitles:editor.project.cues.map {String($0.name.prefix(50))})
        markerCue.selectItem(at:oldCue.flatMap {cueIDs.firstIndex(of:$0)} ?? 0)
        markerCue.isEnabled=markerAction.indexOfSelectedItem == 1 && !cueIDs.isEmpty
        if !editor.project.timeline.contains(where:{$0.id==selectedTrackID}) {selectedTrackID=editor.project.timeline.first?.id;selectedKeyIndex=nil}
        if !editor.project.timelineSettings.markers.contains(where:{$0.id==selectedMarkerID}) {selectedMarkerID=nil}
        trackTable.reloadData();markerTable.reloadData()
        if let i=editor.project.timeline.firstIndex(where:{$0.id==selectedTrackID}) {trackTable.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false)} else {trackTable.deselectAll(nil)}
        if let i=editor.project.timelineSettings.markers.firstIndex(where:{$0.id==selectedMarkerID}) {markerTable.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false)} else {markerTable.deselectAll(nil)}
        let settings=editor.project.timelineSettings
        durationField.stringValue=String(settings.duration);loopStartField.stringValue=String(settings.loopStart);loopEndField.stringValue=String(settings.loopEnd);loopButton.state=settings.loopEnabled ? .on : .off;stopAtDurationButton.state=settings.stopAtEnd ? .on : .off
        if canvas.visibleEnd>settings.duration || canvas.visibleEnd<=canvas.visibleStart {canvas.visibleStart=0;canvas.visibleEnd=settings.duration}
        canvas.duration=settings.duration;canvas.markers=settings.markers
        canvas.track=selectedTrack;canvas.valueRange=chartRange(selectedTrack)
        if let i=selectedKeyIndex,!(selectedTrack?.keyframes.indices.contains(i) ?? false) {selectedKeyIndex=nil}
        canvas.selectedKeyIndex=selectedKeyIndex
        trackToggle.title=selectedTrack?.enabled == true ? "Disable track" : "Enable track";trackToggle.isEnabled=selectedTrack != nil
        viewStartField.stringValue=String(format:"%.6g",canvas.visibleStart);viewEndField.stringValue=String(format:"%.6g",canvas.visibleEnd)
        loadKeyFields();updatePlayhead()
    }
    func updatePlayhead() {
        guard let editor else {return}
        canvas.playhead=editor.showRuntime.time
        positionLabel.stringValue=String(format:"%.3f s",editor.showRuntime.time)+(editor.showRuntime.time>editor.project.timelineSettings.duration && !editor.project.timelineSettings.stopAtEnd ? " · beyond graph" : "")
        playButton.title=editor.showRuntime.isPlaying ? "Pause" : "Play"
        // Do not replace text under the user's insertion point on every tick.
        if window?.firstResponder !== timeField.currentEditor() {timeField.stringValue=String(format:"%.3f",editor.showRuntime.time)}
    }
    private func loadKeyFields() {
        guard let track=selectedTrack,let i=selectedKeyIndex,track.keyframes.indices.contains(i) else {
            keyCaption.stringValue=selectedTrack == nil ? "Add or select a track" : "Double-click graph to add a key; select a diamond to edit"
            for v in [keyTimeField,keyValueField,c1x,c1y,c2x,c2y] {v.isEnabled=false}
            interpolationPicker.isEnabled=false;saveKeyButton.isEnabled=false;deleteKeyButton.isEnabled=false
            return
        }
        let key=track.keyframes[i]
        keyCaption.stringValue="Key \(i+1) / \(track.keyframes.count) · outgoing interpolation · values: \(track.parameter)"
        keyTimeField.stringValue=String(key.time);keyValueField.stringValue=String(key.value)
        let modes:[AutomationInterpolation]=[.hold,.linear,.bezier]
        interpolationPicker.selectItem(at:modes.firstIndex(of:key.interpolation) ?? 1)
        for (field,value) in zip([c1x,c1y,c2x,c2y],[key.control1.x,key.control1.y,key.control2.x,key.control2.y]) {field.stringValue=String(value)}
        keyTimeField.isEnabled=true;keyValueField.isEnabled=true;interpolationPicker.isEnabled=true;saveKeyButton.isEnabled=true;deleteKeyButton.isEnabled=track.keyframes.count>1
        updateCurveControls()
    }
    private func updateCurveControls() {for f in [c1x,c1y,c2x,c2y] {f.isEnabled=selectedKeyIndex != nil && interpolationPicker.indexOfSelectedItem == 2}}
    private func selectKey(at time:Double) {
        selectedKeyIndex=selectedTrack?.keyframes.firstIndex(where:{$0.time==time});canvas.selectedKeyIndex=selectedKeyIndex;loadKeyFields()
    }
    private func addTrack() {
        guard let editor,surfaceIDs.indices.contains(surfacePicker.indexOfSelectedItem),TimelineEngine.parameters.indices.contains(parameterPicker.indexOfSelectedItem) else {return}
        perform {selectedTrackID=try editor.timelineAddTrack(surfaceID:surfaceIDs[surfacePicker.indexOfSelectedItem],parameter:TimelineEngine.parameters[parameterPicker.indexOfSelectedItem]);selectedKeyIndex=0}
    }
    private func deleteTrack() {guard let editor,let id=selectedTrackID else {return};perform {try editor.timelineRemoveTrack(id:id);selectedTrackID=nil;selectedKeyIndex=nil}}
    private func toggleTrack() {guard let editor,let track=selectedTrack else {return};perform {try editor.timelineSetTrackEnabled(id:track.id,enabled:!track.enabled)}}
    private func seekTyped() {guard let editor else {return};perform {editor.seekShow(to:try number(timeField,"show time"))}}
    private func saveSettings() {
        guard let editor else {return}
        perform {var settings=editor.project.timelineSettings;settings.duration=try number(durationField,"duration");settings.loopStart=try number(loopStartField,"loop start");settings.loopEnd=try number(loopEndField,"loop end");settings.loopEnabled=loopButton.state == .on;settings.stopAtEnd=stopAtDurationButton.state == .on;try editor.timelineUpdateSettings(settings)}
    }
    private func saveTypedKey() {
        guard let editor,let track=selectedTrack,let index=selectedKeyIndex else {return}
        let modes:[AutomationInterpolation]=[.hold,.linear,.bezier]
        var editedTime:Double?
        perform {
            let time=try number(keyTimeField,"key time"),value=try number(keyValueField,"key value")
            let key=AutomationKeyframe(time:time,value:value,interpolation:modes[max(0,interpolationPicker.indexOfSelectedItem)],control1:Point2(try number(c1x,"control 1 x"),try number(c1y,"control 1 y")),control2:Point2(try number(c2x,"control 2 x"),try number(c2y,"control 2 y")))
            try editor.timelineEditKey(trackID:track.id,index:index,key:key);editedTime=time
        }
        if let editedTime {selectKey(at:editedTime)}
    }
    private func deleteKey() {guard let editor,let track=selectedTrack,let i=selectedKeyIndex else {return};perform {try editor.timelineDeleteKey(trackID:track.id,index:i);selectedKeyIndex=nil}}
    private func addMarker() {
        guard let editor else {return}
        perform {
            let action:TimelineMarkerAction=markerAction.indexOfSelectedItem == 0 ? .pause : .cue
            let cueID=action == .cue && cueIDs.indices.contains(markerCue.indexOfSelectedItem) ? cueIDs[markerCue.indexOfSelectedItem] : nil
            selectedMarkerID=try editor.timelineAddMarker(name:markerName.stringValue,time:editor.showRuntime.time,action:action,cueID:cueID)
        }
    }
    private func seekMarker() {guard let editor,let marker=editor.project.timelineSettings.markers.first(where:{$0.id==selectedMarkerID}) else {return};editor.seekShow(to:marker.time);updatePlayhead()}
    private func deleteMarker() {guard let editor,let id=selectedMarkerID else {return};perform {try editor.timelineDeleteMarker(id:id);selectedMarkerID=nil}}
    private func applyViewRange() {
        perform {
            let start=try number(viewStartField,"view start"),end=try number(viewEndField,"view end")
            guard start>=0,end>start,end<=canvas.duration else {throw ProjectError.invalid("view range must fit inside the show duration")}
            canvas.visibleStart=start;canvas.visibleEnd=end
        }
    }
    private func fitView() {canvas.visibleStart=0;canvas.visibleEnd=canvas.duration;refresh()}
    private func zoom(_ factor:Double) {
        let oldSpan=canvas.visibleEnd-canvas.visibleStart,span=min(canvas.duration,max(0.001,oldSpan*factor)),center=(canvas.visibleStart+canvas.visibleEnd)/2
        let start=max(0,min(canvas.duration-span,center-span/2))
        canvas.visibleStart=start;canvas.visibleEnd=start+span;refresh()
    }
    func numberOfRows(in tableView:NSTableView)->Int {tableView === trackTable ? editor?.project.timeline.count ?? 0 : editor?.project.timelineSettings.markers.count ?? 0}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard let editor else {return nil}
        if tableView === trackTable {
            guard editor.project.timeline.indices.contains(row) else {return nil}
            let track=editor.project.timeline[row]
            return label((track.enabled ? "● " : "○ ")+String(track.name.prefix(100)),size:11)
        }
        guard editor.project.timelineSettings.markers.indices.contains(row) else {return nil}
        let marker=editor.project.timelineSettings.markers[row]
        return label(String(format:"%.3f · ",marker.time)+(marker.action == .pause ? "Pause · " : "Scene · ")+String(marker.name.prefix(60)),size:11)
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !refreshing,let table=notification.object as? NSTableView,let editor else {return}
        if table === trackTable {
            let row=trackTable.selectedRow
            selectedTrackID=editor.project.timeline.indices.contains(row) ? editor.project.timeline[row].id : nil
            selectedKeyIndex=nil;canvas.track=selectedTrack;canvas.selectedKeyIndex=nil;canvas.valueRange=chartRange(selectedTrack);loadKeyFields()
            trackToggle.title=selectedTrack?.enabled == true ? "Disable track" : "Enable track";trackToggle.isEnabled=selectedTrack != nil
        } else {
            let row=markerTable.selectedRow
            selectedMarkerID=editor.project.timelineSettings.markers.indices.contains(row) ? editor.project.timelineSettings.markers[row].id : nil
        }
    }
}
#endif
