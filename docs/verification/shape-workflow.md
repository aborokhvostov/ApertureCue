# Primitive shape GUI verification

26 October 2026, Apple M2 / macOS 26.6.2. Agent-driven native GUI observation through CUA. A separately signed production copy used bundle ID `org.aperturecue.shape-check`; only bundle identity/name changed. No existing user project was edited.

1. Launch with original procedural two-surface project; **+ Triangle** created Triangle 3, with a clipped triangular texture and matching contour in its four-handle cage.
2. Drag its top-left cage handle; the projective triangle/texture moved. **+ Ellipse** created Ellipse 4 with an analytic elliptical texture and matching contour. Move its top-right cage handle to deform its perspective.
3. **Input region** displayed the entire rectangular procedural source, including all four colored corners, without output-shape clipping.
4. Save As created a new ignored `Shapes.aperturecue.json`. File assertions confirmed schema 2, quad/quad/triangle/ellipse, and changed independent cage coordinates on both new forms.
5. **Outputs → 0: Built-in Retina Display → Open fullscreen** showed a separate clean composition of the shapes, with no editor handles/menu. Escape closed the output.
6. Quit normally, launch a new process and Open the saved file. Four surfaces reappeared; selecting Ellipse 4 showed **Ellipse** in the shape selector. Quit normally.

No external projector/hotplug, camera, lighting or MIDI hardware was involved. GUI FPS text is not performance evidence. Automated production tests independently cover selector callbacks, undo/redo, input preview, empty-corner picking and schema-2 scene/save/new/open roundtrip. The GPU report covers numerical area, edge AA, independent crop, perspective, displaced mesh, UV mask and feather for both new primitives.
