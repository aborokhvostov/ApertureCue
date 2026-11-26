# Bézier warp, source mesh link and cubic mask geometry

This specifies independently authored Foundation-only geometry. Desktop model,
editor, compositor and release integration require their own recorded checks;
these primitives alone do not establish implementation of the complete stage.

## Bicubic warp

`BezierWarp` stores 1…8 tensor-product cubic patches per axis in a row-major
`(3 * columns + 1) × (3 * rows + 1)` absolute control lattice. Every control must
be finite and inside the document working range ±10000. Adjacent patches share
their boundary controls. Incoming/outgoing controls on opposite sides are
independent: boundary continuity is C0, and C1 smoothness is an explicit user
choice rather than an implicit edit of another handle.

The lattice maps normalized local UV to output-local points. `point(at:)`
evaluates the exact polynomial. An optional `Homography` projects the result,
giving the exact rational surface for perspective group/cage transforms.
Projectivity must **not** be approximated by projecting the control points and
then treating them as ordinary polynomial controls. To preserve an existing
quad's source UV on initial conversion, start with a unit lattice and pass the
existing unit-to-output homography as the projection. `regular(quad:)` instead
constructs the stated bilinear quad and is useful when bilinear behavior is
intended.

`tessellated(width:height:projection:pixelTolerance:maximumTriangles:minimumSubdivision:)`
returns one conforming rectangular grid of output/local vertex pairs and indexed
triangles. Default tolerance is 0.5 pixels, maximum allowed tolerance is 0.5,
default triangle budget is 32768 (configurable 2…131072), and maximum uniform
subdivision depth is 8. Resolution is 1…16384 per axis. Every patch uses the same
dyadic subdivision, preventing T junctions and separate approximations of a
shared edge. A required precision that exceeds the budget is rejected; no
silently coarse fallback is emitted.

The geometric certificate works in the declared anisotropic pixel metric. Write
the projected patch as homogeneous bicubics `N(u,v) / W(u,v)` and its projected
corner bilinear interpolant as `B(u,v)`. Elevate `N` and `W * B` to bidegree
`(4,4)`. Convexity of the Bernstein basis bounds the distance to `B` by the
largest norm of the residual control coefficients divided by the smallest
positive weight. The two affine triangles differ from `B` by at most a quarter
of the projected corner twist norm. Their sum, with a conservative arithmetic
allowance, is reported as `maximumErrorPixels` and must fit the requested
tolerance. Homogeneous de Casteljau subdivision preserves the exact projected
surface. Control weights of different signs, zero/near-zero weights, nonfinite
projection and transformed controls outside the working range are rejected.

The certificate concerns the mathematical triangulation in Double precision;
GPU Float upload/rasterization and final frame behavior must be tested by the
production adapter separately. It is not a throughput, arbitrary shader or
physical-projector guarantee. `WarpTessellation.localPoint(at:)` gives the first
covering triangle on a folded surface, matching the existing regular-mesh inverse
policy; it does not claim a unique inverse where the surface overlaps itself.

Independent input and output warps can first determine their required dyadic
subdivision at output and texture resolution. Take the larger subdivision and
pass it as `minimumSubdivision` to obtain a shared local UV grid. This preserves
triangle correspondence while satisfying both bounds. The adapter must retain
the source lattice when the link is disabled; changing output geometry must not
rewrite source UV.

## Explicit mesh link

`MeshLinkGeometry.movingOutputVertex` accepts two equal-sized meshes, their
separate valid cage frames, an existing vertex index and the new output point.
With `linked == false`, source vertices remain bit-for-bit unchanged. With the
link enabled, the selected output displacement is measured through the inverse
output cage homography, added to the selected source point in the input cage's
normalized coordinates, then mapped through the input cage. Other points remain
unchanged. Merely enabling or disabling the link never reconciles different
meshes. Invalid dimensions/index/coordinates or singular cage transforms reject
the operation before publishing an edited value. The document adapter owns
geometry-lock, one-command history and current selection/generation checks.

`SurfaceSourceMapping` treats `inputMesh` as absolute source UV at matching
regular nodes. It prepares the exact base unit-to-input homography and stores
only the difference between each edited input node and that homography at the
same local coordinate. At a fragment, the adapter adds interpolated deltas to
the exact base homography. Initializing input nodes from the original crop
therefore creates zero deltas and preserves projective UV exactly; changing
only output geometry cannot alter this source-domain function. An independent
`inputWarp` instead defines absolute UV through `inputWarpTransform`.

`SurfaceWarpGeometry.tessellation` coordinates output and source precision. The
source-delta interpolant is the difference of input warp and base homography;
both get a 0.25 texture-pixel bound, so their combined error is at most 0.5.
The largest required subdivision is used for output vertices. Optional source
texture dimensions must describe the sampled texture; picking defaults to
1280×720 but can receive the renderer's exact cached tessellation.

Regular mesh projectivity uses positive `meshWeights`. Forward triangle
mapping multiplies local barycentric weights by these homogeneous weights and
normalizes. Inverse mapping divides screen barycentric weights by them and
normalizes. This preserves perspective-correct local/source coordinates after
group projection. CPU picking checks all covering triangles on a fold while
editing returns the first valid preimage. `SurfaceGeometry.outputPoints`,
outlines and centerlines prepare one mapping per batch and split straight local
edges at mesh/tessellation cell boundaries; invalid precision/geometry throws
instead of silently displaying untransformed geometry.

## Closed cubic masks

`BezierMask` stores 3…128 `StrokeNode` anchors and independent absolute incoming
and outgoing handles, all finite in ±10000 in the enclosing mask's coordinate
space. Every path is closed, including last-to-first. Filling uses the same
even/odd rule as polygon masks, including concave or self-intersecting paths.
The `ellipse` fixture is an original four-cubic approximation; `polygon` makes
straight edges with collapsed tangents.

`flattened` uses bounded de Casteljau subdivision and maximum control distance
to the **finite** chord, preserving the error guarantee for collinear reversal,
coincident endpoint loops and sharp tangents. Default tolerance is 0.00025 in
normalized coordinates, default segment budget 256 and maximum depth 16.
Callers may use `metricScale = (width,height)` with tolerance 0.5 for a pixel
metric, or select a budget 3…4096 and depth 0…20. Precision exhaustion throws.
The returned polygon omits the repeated closing endpoint. Both CPU membership
and the GPU adapter must use that exact flattened contour and even/odd rule;
the path is not replaced with a different AppKit winding mode.

`insertingNode` splits the chosen cubic at one half, including the closing edge,
and preserves its geometry while updating the two neighbouring handles.
`removingNode` deliberately joins its neighbours and may change the contour;
three nodes are the minimum. `movingAnchor` translates that anchor's two handles
by the same vector, leaving every other node unchanged. Array/model copies keep
rejected operations atomic. Scope, multiple paths/holes, inversion, antialias and
feather composition belong to the enclosing mask/compositor specification.

## Automatic evidence

`BezierWarpTests` compares exact evaluation with independent de Casteljau,
checks a dense grid against the conservative pixel bound under perspective and
reflection, patch-boundary correspondence, inverse picking, independent
tangents, forced joint subdivision, malformed data, horizon/precision rejection,
round trips and explicit linked/unlinked source displacement.
`BezierMaskTests` compares 2004 dense curve samples with pixel-space flattened
edges, reverses path winding, checks exact closing-edge split geometry, anchor
handle translation, loops/reversals, Codable and budget/minimum rejection.
These tests are executable by XCTest CI and the separate standalone assertion
harness; execution evidence must identify which harness actually ran.

## Direct surface commands and freehand adapter

`SurfaceEditing` computes validated Project candidates for warp creation/reset,
source-lattice initialization, link changes, active control replacement, direct
world transforms and a new freehand surface. Locked or absent target IDs are
no-ops. No method mutates an input Project value. A world transform is conjugated
through the parent's inverse, updating output cage/regular mesh and homogeneous
weights or composing into the Bezier warp transform. Input crop, input lattice
and input transform remain unchanged. The editor records one accepted command;
canvas drag samples instead belong to its existing begin/end history gesture.

Bezier creation starts with the unit control lattice plus the original cage's
homography, preserving the original projective crop. Its explicit UI action
replaces regular mesh/source edits. Reset removes both Bezier lattices and returns
to the independent quad crop/cage. Merely disabling a source link retains edited
source data. A linked control edit measures its displacement through the output
and input cage frames and moves only the corresponding control in the other
lattice. Output numeric positions are in the world canvas; input numeric
positions are source UV. Numeric dialogs pin the document generation and entire
selected surface; a late confirmation cannot target a replaced layer.

`FreehandPath.fit` uses deterministic finite-segment Ramer–Douglas–Peucker
subdivision, at most 512 input samples and 32 retained nodes. Distances use a
16:9 canvas metric by default and tolerance 0.001. The tolerance is not raised to
fit a complex gesture into the node budget. Nonfinite/zero-length, over-budget
or collapsed results are rejected. Each accepted source sample lies within the
specified tolerance of its retained segment; straight intervals between samples
inherit that convex distance bound. This does not infer unseen motion between
sample events. The desktop adapter creates an editable textured `.line` path in
an explicitly padded output cage; the original project and existing layers are
unchanged on rejection. Filled freehand shapes and alternate stroke joins/caps
are separate behaviors, not implied by polyline capture.
