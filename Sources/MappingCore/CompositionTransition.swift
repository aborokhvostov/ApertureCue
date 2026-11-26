import Foundation

/// Preflight for cue execution against the currently displayed scene. Validation
/// never starts or interrupts the caller's CueEngine and never mutates a project.
public enum CompositionTransition {
    /// Checks both discrete sides of the midpoint, the endpoints, and representative
    /// interior states using CueEngine itself. This catches unsupported isolated
    /// stack changes and sampled geometry failures; it is not a proof that every
    /// continuously interpolated geometry state is valid.
    ///
    /// A full cue retains uncaptured current layers as disabled destination layers,
    /// matching editor recall: their source states remain present during the fade.
    /// Selective cues retain their normal merge and missing-target semantics.
    public static func validate(cue:Cue,in project:Project) throws {
        try ProjectStore.validate(project)
        try CueSelection.validate(cue)

        // Validate snapshots even when the caller passes a cue not already stored
        // in the project. In particular, dormant selective payloads remain bounded.
        var snapshotProject=project
        if let index=snapshotProject.cues.firstIndex(where:{$0.id==cue.id}) {
            snapshotProject.cues[index]=cue
        } else { snapshotProject.cues.append(cue) }
        try ProjectStore.validate(snapshotProject)

        var prepared=cue
        if prepared.scope == .full {
            let capturedIDs=Set(prepared.surfaces.map(\.id))
            for var outgoing in project.surfaces where !capturedIDs.contains(outgoing.id) {
                outgoing.enabled=false
                prepared.surfaces.append(outgoing)
            }
        }
        var candidate=project
        candidate.surfaces=try CueSelection.destination(from:project.surfaces,cue:prepared)
        try ProjectStore.validate(candidate)
        guard prepared.duration>0 else { return }

        // Interpolation depends only on normalized phase. A synthetic unit duration
        // avoids precision loss for very small positive durations without consulting
        // a wall clock, following another cue, or mutating a running transport.
        prepared.duration=1
        let engine=CueEngine()
        engine.begin(from:project.surfaces,cue:prepared,at:0)
        let phases:[Double]=[0,0.25,Double(0.5).nextDown,0.5,0.75,Double(1).nextDown,1]
        for phase in phases {
            guard let surfaces=engine.sample(at:phase) else {
                throw ProjectError.invalid("cue transition could not be prepared")
            }
            candidate.surfaces=surfaces
            do { try ProjectStore.validate(candidate) }
            catch {
                throw ProjectError.invalid("unsupported cue transition at phase \(phase): \(error.localizedDescription); use a zero-duration cut or adjust the scene geometry and isolated layer order")
            }
        }
    }
}
