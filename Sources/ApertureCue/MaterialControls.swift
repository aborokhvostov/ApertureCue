#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import MappingCore

extension EditorController {
    /// CPU schema validation and complete backend preflight precede document
    /// mutation, so an invalid edit cannot replace the last accepted material.
    func saveMaterial(_ definition: MaterialDefinition, assignSelected: Bool = true, values: [String:[Double]]? = nil) throws {
        _=try MaterialProgram(definition:definition)
        guard assignSelected || values == nil || values?.isEmpty == true else { throw ProjectError.invalid("surface parameter overrides need a selected assignment") }
        guard !assignSelected || selectedIndex != nil else { throw ProjectError.invalid("select a surface to assign the material") }
        var candidate=project
        if let index=candidate.materials.firstIndex(where:{$0.id == definition.id}) { candidate.materials[index]=definition }
        else { candidate.materials.append(definition) }
        if assignSelected,let index=selectedIndex {
            let same=candidate.surfaces[index].materialID == definition.id
            candidate.surfaces[index].materialID=definition.id
            candidate.surfaces[index].materialValues=values ?? (same ? candidate.surfaces[index].materialValues : [:])
        }
        try ProjectStore.validate(candidate)
        guard let renderer=renderer else { throw ProjectError.invalid("material validation needs a Metal renderer") }
        try renderer.validateMaterial(definition)
        mutate("Save material") { $0=candidate }
    }

    func assignMaterial(_ id: UUID?, values: [String:[Double]] = [:]) throws {
        guard let index=selectedIndex else { throw ProjectError.invalid("select a surface to assign the material") }
        if let id {
            guard let definition=project.materials.first(where:{$0.id == id}) else { throw ProjectError.invalid("material is missing") }
            _=try MaterialProgram(definition:definition).parameterVectors(values:values)
            guard let renderer=renderer else { throw ProjectError.invalid("material validation needs a Metal renderer") }
            try renderer.validateMaterial(definition)
        } else if !values.isEmpty { throw ProjectError.invalid("parameter values need a material assignment") }
        var candidate=project
        candidate.surfaces[index].materialID=id; candidate.surfaces[index].materialValues=values
        try ProjectStore.validate(candidate)
        mutate("Assign material") { $0=candidate }
    }

    func deleteMaterial(_ id: UUID) throws {
        guard project.materials.contains(where:{$0.id == id}) else { return }
        var candidate=project
        candidate.materials.removeAll { $0.id == id }
        func clear(_ surface: inout Surface) {
            if surface.materialID == id { surface.materialID=nil; surface.materialValues=[:] }
        }
        for i in candidate.surfaces.indices { clear(&candidate.surfaces[i]) }
        for c in candidate.cues.indices { for i in candidate.cues[c].surfaces.indices { clear(&candidate.cues[c].surfaces[i]) } }
        try ProjectStore.validate(candidate)
        mutate("Delete material") { $0=candidate }
    }

    @discardableResult
    func importISF(_ data: Data, name: String, assignSelected: Bool = true) throws -> MaterialDefinition {
        guard data.count <= 65536,let source=String(data:data,encoding:.utf8) else { throw ProjectError.invalid("ISF must be UTF-8 and at most 64 KiB") }
        let definition=try ISFMaterial.importSource(source,name:name)
        try saveMaterial(definition,assignSelected:assignSelected)
        return definition
    }

    func saveEffects(_ settings: EffectsSettings) throws {
        guard let index=selectedIndex else { throw ProjectError.invalid("select a surface to edit FX") }
        try Effects.validate(settings)
        var candidate=project; candidate.surfaces[index].effects=settings
        try ProjectStore.validate(candidate)
        mutate("Surface FX") { $0=candidate }
    }

    func configureMaterial() {
        let generation=documentGeneration,selection=selectedID,definitions=project.materials
        let surface=selectedIndex.map { project.surfaces[$0] }
        let picker=ActionPopUp(items:["New material"]+definitions.enumerated().map { "\($0.offset+1). \($0.element.name)" },action:{_ in})
        let name=ActionField("",action:{_ in}),credit=ActionField("",action:{_ in})
        let (expressionBox,expression)=materialTextArea("sample(uv)",height:100)
        let (inputsBox,inputs)=materialTextArea("[]",height:85)
        let (valuesBox,values)=materialTextArea("{}",height:65)
        func encode<T: Encodable>(_ value: T) -> String {
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            return (try? encoder.encode(value)).flatMap { String(data:$0,encoding:.utf8) } ?? ""
        }
        let newID=UUID(),clearCode=NSApplication.ModalResponse(rawValue:1004)
        let clear=ActionButton("Clear selected material") { NSApplication.shared.stopModal(withCode:clearCode) }
        clear.isEnabled=surface?.materialID != nil
        values.isEditable=selection != nil
        func load(_ index: Int) {
            guard (0...definitions.count).contains(index) else { return }
            let definition=index > 0 ? definitions[index-1] : MaterialDefinition(id:newID)
            name.stringValue=definition.name;credit.stringValue=definition.credit
            expression.string=definition.expression; inputs.string=encode(definition.inputs)
            values.string=encode(surface?.materialID == definition.id ? surface?.materialValues ?? [:] : [:])
        }
        picker.actionBlock=load
        let initial=surface?.materialID.flatMap { id in definitions.firstIndex(where:{$0.id == id}).map { $0+1 } } ?? 0
        picker.selectItem(at:initial);load(initial)
        let view=stack([picker,clear,label("Name"),name,label("RGBA expression · uv / time / size / sample(uv)"),expressionBox,
                        label("Inputs JSON · name, label, kind, defaultValue, minimum, maximum"),inputsBox,
                        label("Selected surface parameter values JSON · {} uses defaults"),valuesBox,label("Credit / provenance"),credit])
        view.frame=NSRect(x:0,y:0,width:460,height:480)
        for control in [picker as NSView,name,credit] { control.widthAnchor.constraint(equalToConstant:450).isActive=true }
        let alert=NSAlert(); alert.messageText="Materials"
        alert.informativeText="Expressions are bounded RGBA math, not arbitrary shader programs. Up to 16 named inputs: float, bool, point2D and color. Save validates every current/scene use and compiles all blend variants before changing the document. ISF import accepts only the documented single-pass expression subset."
        alert.accessoryView=view
        alert.addButton(withTitle:selection == nil ? "Save material" : "Save + Assign")
        alert.addButton(withTitle:"Import ISF…");alert.addButton(withTitle:"Delete");alert.addButton(withTitle:"Cancel")
        alert.buttons[2].isEnabled=initial > 0
        picker.actionBlock={ [weak alert] index in
            guard (0...definitions.count).contains(index) else { return }
            load(index);alert?.buttons[2].isEnabled=index > 0
        }
        let response=alert.runModal()
        guard [.alertFirstButtonReturn,.alertSecondButtonReturn,.alertThirdButtonReturn,clearCode].contains(response) else { return }
        do {
            guard generation == documentGeneration, selection == selectedID, definitions == project.materials else {
                throw ProjectError.invalid("document, selection or material library changed; reopen Materials")
            }
            if response == clearCode { try assignMaterial(nil);return }
            let index=picker.indexOfSelectedItem
            guard (0...definitions.count).contains(index) else { throw ProjectError.invalid("choose a material") }
            if response == .alertFirstButtonReturn {
                guard expression.string.utf8.count <= 4096,inputs.string.utf8.count <= 32768,values.string.utf8.count <= 32768,
                      let inputData=inputs.string.data(using:.utf8),let valueData=values.string.data(using:.utf8) else {
                    throw ProjectError.invalid("material expression or parameter JSON budget exceeded")
                }
                let inputList=try JSONDecoder().decode([MaterialInput].self,from:inputData)
                let overrides=try JSONDecoder().decode([String:[Double]].self,from:valueData)
                let id=index == 0 ? newID : definitions[index-1].id
                let definition=MaterialDefinition(id:id,name:name.stringValue,expression:expression.string,inputs:inputList,credit:credit.stringValue)
                try saveMaterial(definition,assignSelected:selection != nil,values:overrides)
            } else if response == .alertSecondButtonReturn {
                let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"fs") ?? .plainText]
                panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
                guard panel.runModal() == .OK,let url=panel.url else { return }
                guard generation == documentGeneration, selection == selectedID, definitions == project.materials else {
                    throw ProjectError.invalid("document, selection or library changed during ISF import")
                }
                let attributes=try url.resourceValues(forKeys:[.fileSizeKey])
                guard let size=attributes.fileSize,size <= 65536 else { throw ProjectError.invalid("ISF file exceeds 64 KiB") }
                try importISF(Data(contentsOf:url),name:url.deletingPathExtension().lastPathComponent,assignSelected:selection != nil)
            } else if index > 0 { try deleteMaterial(definitions[index-1].id) }
        } catch { showError(error) }
    }

    func configureEffects() {
        guard let index=selectedIndex else { return }
        let generation=documentGeneration,id=project.surfaces[index].id,settings=project.surfaces[index].effects
        let modes=KeyMode.allCases
        let picker=ActionPopUp(items:modes.map(\.rawValue),selected:modes.firstIndex(of:settings.keyMode) ?? 0,action:{_ in})
        let fields=[settings.keyColor[0],settings.keyColor[1],settings.keyColor[2],settings.threshold,settings.softness,settings.spill,settings.saturation].map { ActionField(String($0),action:{_ in}) }
        let invert=NSButton(checkboxWithTitle:"Invert RGB after saturation",target:nil,action:nil);invert.state=settings.inverted ? .on : .off
        let levels=ActionField(String(settings.posterizeLevels),action:{_ in})
        let view=stack([label("Key mode"),picker,label("Key RGB · each 0…1"),stack(Array(fields.prefix(3)),vertical:false),
                        label("Threshold / softness / spill · each 0…1"),stack(Array(fields[3...5]),vertical:false),
                        label("Saturation · 0…2"),fields[6],invert,label("Posterize levels · 0 disables, or 2…256"),levels])
        view.frame=NSRect(x:0,y:0,width:430,height:280)
        for field in fields { field.widthAnchor.constraint(equalToConstant:130).isActive=true }
        picker.widthAnchor.constraint(equalToConstant:410).isActive=true;levels.widthAnchor.constraint(equalToConstant:410).isActive=true
        let alert=NSAlert();alert.messageText="Surface FX"
        alert.informativeText="Chroma keys normalized RGB distance from the key color; luma keys Rec.709-weighted brightness. Softness is the inward alpha transition. Spill suppresses excess in the key's dominant channel. Effects run before surface color correction."
        alert.accessoryView=view;alert.addButton(withTitle:"Save FX");alert.addButton(withTitle:"Reset FX");alert.addButton(withTitle:"Cancel")
        let response=alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        do {
            guard generation == documentGeneration,selectedID == id,let current=selectedIndex,project.surfaces[current].effects == settings else {
                throw ProjectError.invalid("document, selection or effects changed; reopen Surface FX")
            }
            if response == .alertSecondButtonReturn { try saveEffects(.init());return }
            let numbers=try fields.map { field -> Double in
                guard let value=Double(field.stringValue),value.isFinite else { throw ProjectError.invalid("enter finite FX values") };return value
            }
            guard modes.indices.contains(picker.indexOfSelectedItem),let count=Int(levels.stringValue) else { throw ProjectError.invalid("invalid FX mode or posterize count") }
            try saveEffects(EffectsSettings(keyMode:modes[picker.indexOfSelectedItem],keyColor:Array(numbers.prefix(3)),threshold:numbers[3],softness:numbers[4],spill:numbers[5],saturation:numbers[6],inverted:invert.state == .on,posterizeLevels:count))
        } catch { showError(error) }
    }
}

@MainActor
private func materialTextArea(_ value: String,height: CGFloat) -> (NSScrollView,NSTextView) {
    let text=NSTextView(frame:NSRect(x:0,y:0,width:450,height:height))
    text.string=value;text.isRichText=false;text.isAutomaticQuoteSubstitutionEnabled=false
    text.isAutomaticDashSubstitutionEnabled=false;text.font=NSFont.monospacedSystemFont(ofSize:11,weight:.regular)
    text.isVerticallyResizable=true;text.isHorizontallyResizable=false;text.textContainer?.widthTracksTextView=true
    let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;scroll.documentView=text
    scroll.widthAnchor.constraint(equalToConstant:450).isActive=true;scroll.heightAnchor.constraint(equalToConstant:height).isActive=true
    return (scroll,text)
}
#endif
