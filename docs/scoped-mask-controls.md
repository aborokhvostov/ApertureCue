# Scoped mask and group composition controls

The native scoped-mask editor addresses the selected layer, the chosen/parent
group, or the global composition. Each scope holds at most eight independent
masks. Save/Delete is one validated document/history operation. Geometry-locked
layers reject mask changes in both controller and UI callbacks; group/global
operations keep their existing separate semantics.

Masks can be enabled, inverted and feathered in source UV/group-local or output
canvas coordinates. Global masks require output-canvas coordinates. Their alpha
multiplies within the declared scope. New polygon masks start as an inset quad;
new cubic masks start as an ellipse. Converting a polygon to cubic retains its
straight edges with collapsed handles. Converting a curve to polygon explicitly
connects its existing anchors, changing the contour.

Nodes saves mask properties first and then opens a separate numeric control-point
editor. Each accepted node command is its own Undo operation. Anchor and tangent
coordinates are independent absolute points. Cubic insertion uses de Casteljau
subdivision, preserving the chosen closed segment including the last-to-first
edge. Polygon insertion preserves its straight edge. Removal changes the
neighbouring segments. Limits are 3…128 anchors; adaptive curve flattening has
its own precision budget and can reject an excessively curved edit.

Group composition edits isolation, blend mode and the same validated FX settings
used by layers: chroma/luma key, color/threshold/softness/spill, saturation,
inversion and posterization. Group masks/FX/non-normal blend also require a
composition buffer. Descendant layers must be contiguous in back-to-front order;
validation rejects ambiguous interleaving instead of silently moving layers.
Save + masks saves group settings first, then opens that group's mask scope.

Group perspective maps the current world-space bounding rectangle to a convex
four-corner destination. It composes a world homography through the parent's
inverse and preserves local member geometry, including geometry-locked members.
Missing members, singular mappings, unsafe horizons and invalid destination
quads reject before history publication. All modals pin document generation and
the project snapshot so timer/scene/document changes cannot redirect stale edits.

These controls are independent of rendering verification. The parent integration
must record group isolation/mask/FX/perspective GPU pixels, native callbacks,
history, persistence, manual workflow and hardware evidence separately.
