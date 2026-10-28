#if os(macOS)
import AppKit
import MappingCore

extension EditorController {
    func sourceName(for id:UUID)->String? {
        project.assets.first {$0.id==id}?.name ?? project.montages.first {$0.id==id}?.name
    }
    func updateActiveMedia() {
        let ordinary=Set(project.assets.map(\.id))
        media.setActiveAssetIDs(Set(project.surfaces.compactMap(\.mediaID)).intersection(ordinary))
    }
    func showMontageWindow() {
        if montageWindow == nil {montageWindow=MontageWindowController(editor:self)}
        montageWindow?.refresh();montageWindow?.showWindow(nil);montageWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @discardableResult
    func montageCreate(name:String,duration:Double,loop:Bool,gapMode:MontageGapMode)throws->UUID {
        let montage=MediaMontage(name:name,duration:duration,loop:loop,gapMode:gapMode)
        var candidate=project;candidate.montages.append(montage);try ProjectStore.validate(candidate)
        mutate("Create montage") {$0=candidate};return montage.id
    }
    func montageUpdate(id:UUID,name:String,duration:Double,loop:Bool,gapMode:MontageGapMode)throws {
        guard let i=project.montages.firstIndex(where:{$0.id==id}) else {throw ProjectError.invalid("montage no longer exists")}
        var candidate=project;candidate.montages[i].name=name;candidate.montages[i].duration=duration
        candidate.montages[i].loop=loop;candidate.montages[i].gapMode=gapMode
        try ProjectStore.validate(candidate);mutate("Edit montage") {$0=candidate}
    }
    func montageDelete(id:UUID)throws {
        guard project.montages.contains(where:{$0.id==id}) else {throw ProjectError.invalid("montage no longer exists")}
        var candidate=project;candidate.montages.removeAll {$0.id==id}
        for i in candidate.surfaces.indices where candidate.surfaces[i].mediaID==id {candidate.surfaces[i].mediaID=nil}
        for c in candidate.cues.indices {
            for i in candidate.cues[c].surfaces.indices where candidate.cues[c].surfaces[i].mediaID==id {candidate.cues[c].surfaces[i].mediaID=nil}
        }
        try ProjectStore.validate(candidate);mutate("Delete montage") {$0=candidate}
        if selectedMediaID==id {selectedMediaID=nil}
    }
    func montageSaveClip(montageID:UUID,clip:MontageClip)throws {
        guard let i=project.montages.firstIndex(where:{$0.id==montageID}) else {throw ProjectError.invalid("montage no longer exists")}
        if let asset=project.assets.first(where:{$0.id==clip.assetID}),asset.kind=="video" {
            let known=media.duration(for:asset.id)
            guard known<=0 || clip.sourceOut<=known+1e-6 else {throw ProjectError.invalid("Source Out exceeds known media duration")}
        }
        var candidate=project
        if let c=candidate.montages[i].clips.firstIndex(where:{$0.id==clip.id}) {candidate.montages[i].clips[c]=clip}
        else {candidate.montages[i].clips.append(clip)}
        candidate.montages[i].clips.sort {$0.start<$1.start}
        try ProjectStore.validate(candidate);mutate("Save montage clip") {$0=candidate}
    }
    func montageDeleteClip(montageID:UUID,clipID:UUID)throws {
        guard let i=project.montages.firstIndex(where:{$0.id==montageID}),project.montages[i].clips.contains(where:{$0.id==clipID}) else {throw ProjectError.invalid("montage clip no longer exists")}
        var candidate=project;candidate.montages[i].clips.removeAll {$0.id==clipID}
        try ProjectStore.validate(candidate);mutate("Delete montage clip") {$0=candidate}
    }
    func montageAssign(id:UUID)throws {
        guard project.montages.contains(where:{$0.id==id}),let i=selectedIndex else {throw ProjectError.invalid("select a montage and a surface")}
        var candidate=project;candidate.surfaces[i].mediaID=id
        try ProjectStore.validate(candidate);mutate("Assign montage") {$0=candidate}
    }
}
#endif
