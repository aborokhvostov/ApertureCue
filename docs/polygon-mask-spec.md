# Layer polygon masks (schema 11)

Each surface has one existing `mask` polygon (empty or 3…128 finite vertices)
and `maskSettings`: `space` (`sourceUV` / `outputCanvas`), `inverted` (Boolean),
`feather` (finite 0…0.5). Missing settings use sourceUV / false / 0.
Schemas 0…10 ignore this extension before decoding, for both current layers
and full/selective scene snapshots. Save upgrades to schema 11; older binaries
reject this version. Preserve a separate old project copy when testing older apps.

`sourceUV` evaluates the final surface source coordinates after input crop and,
for strokes, arclength/across parameterization. Video orientation remains owned
by the media adapter. `outputCanvas` evaluates normalized composition coordinates
after mesh and group transforms. Its polygon remains fixed when the surface or
group moves, and applies independently on every routed output. Neither mode
masks other layers, a group buffer or the global composition.

The polygon uses even/odd filling, supporting concavity and self crossings.
Boundary points belong to the interior. Inversion keeps the exterior, revealing
underlying layers. An empty mask passes the whole layer even when inverted.
Coincident adjacent vertices contribute zero-length segments without division
by zero. Zero-area paths have only their boundary as an interior.

Feather attenuates inward from the boundary of the retained region by
`smoothstep(0, feather, nearestSegmentDistance)`, multiplying texture alpha,
surface opacity, primitive coverage and the existing shape feather. Width is
Euclidean distance in normalized coordinates of the selected space, independent
of output pixel aspect ratio. Zero feather retains a hard edge without additional
mask antialiasing. Feather is not an edge-blending calibration or a pixel width.

The inspector explicitly reinterprets the same point values when changing
coordinate space. It does not convert through a potentially folded mesh or
stroke UV inverse. Edit polygon mask selects full-source view for sourceUV and
composition view for outputCanvas. Points are edited directly in that space;
group inverse transforms never apply to mask handles. Leaving mask edit uses the
normal Output geometry / Input region picker. Lock geometry guards points,
space, inversion and mask feather, including controller callbacks.

The selective `Mask` field includes polygon and all settings atomically. Full
and selective cues interpolate equal-count polygons and feather only when space
and inversion agree. Otherwise the complete mask switches at transition 0.5.
Other selective fields leave it untouched. Undo/Redo, Save/Open, recovery and
Collect use the same document data. Multiple independent masks, compound holes,
Bézier paths and group/global mask scope remain open.

Automatic evidence: `PolygonMaskTests` (distance, concavity, inversion,
monotonic feather, coincident segments, validation, atomic scenes, old-schema
malformed-extension migration, persistence and Collect), production `SelfTest`
(pixel oracle with crop, mesh and reflected group, layer isolation, routing and
blackout) and `EditorSelfTest` (native controls, editing space, history, lock and
reopen). Local standalone assertion execution is separate from remote XCTest.

## Vertex editing (alpha 14, same schema 11)

Mask vertices opens a numeric editor for the selected polygon. Save changes one
vertex in the mask’s current coordinate space. Insert after splits the chosen
closed edge at its midpoint; the last vertex splits the closing edge to vertex 1.
This insertion preserves the polygon’s coverage and feather. Remove connects
neighbours, deliberately changing the contour. Limits are 3…128 points; use
Remove mask to clear it. Existing vertex coordinates may extend outside 0…1,
within the finite ±10000 document range.

Each accepted operation is one history command. Rejected coordinates/indexes or
capacity violations leave document/history unchanged. Geometry locks guard both
UI and controller calls. Numeric modal edits pin the document generation and
complete selected surface; if either changes while the modal runs, the edit is
rejected. Selection changes cannot redirect the operation to another layer.
Mask-mode canvas handles show vertex numbers for polygons with more than four
points. Changed vertex counts switch discretely at scene transition midpoint;
matching counts retain the existing interpolation policy.
