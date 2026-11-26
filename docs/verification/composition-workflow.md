# Geometry and composition verification

26 November 2026, Apple M2 / arm64 / macOS 26.6.2 build 25G83,
Apple Swift 6.4.2 (installed Xcode), Metal Apple M2, 8 GiB system memory.
Target remains macOS 13+. All media/shaders/SVG fixtures are independently authored.
No physical projector, external display, light fixture or controller was used.

## Implementation

Schema 12 persists regular/Bézier source and output lattices, explicit links,
projective groups, isolated group blend/opacity/FX, layer/group/global masks,
materials and overrides, FX, output edge calibration and delayed feedback routes.
Original SVG imports become owned PNG media; video walls create independent
logical routes without assigning physical displays. Group/material definitions
remain shared state outside surface-only scene snapshots. Selective cues have
15 atomic surface fields. Unsupported geometry/precision/resource budgets reject
with diagnostics; no lower-quality fallback is silently substituted.

The material language and imported ISF are the declared bounded expression subset,
not arbitrary shader source. SVG likewise has a strict documented subset. See
[warp](../mesh-warp-spec.md), [materials](../material-spec.md),
[masks](../scoped-mask-controls.md), [SVG](../svg-import-spec.md),
[wall](../video-wall-spec.md) and [edge blend](../edge-blend-spec.md).

## Automatic checks

Final optimized native build passed **81 editor**, **25 composition**, **51 GPU/media**, **27 montage**, **11 lighting/UDP**, **5 live presentation**, **3 full-editor live checks** and OSC/MIDI localhost checks. Core passed **133 standalone methods**, zero failed assertions. [Raw reports](stage-2/). Freshly extracted final ZIP passed 81 editor, 25 composition, 5 live presentation and 3 full-editor live checks. [Exact-source CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/45881995353) passed 133 actual XCTest per platform on macOS/Linux, zero failures, plus macOS packaging.
The standalone assertion harness is separate from actual XCTest CI. Initial
integration found and corrected malformed mesh-weight indexing, legacy reset and
mode/cage integration, PNG export in Input preview, last-feedback deletion,
non-midpoint invalid full-cue geometry and exact storage of explicit cage corners.
An earlier diagnostic app passed 79 editor checks; it is not the release binary.

CPU caches share a 64 MiB requested-payload admission budget. Renderer geometry
and source-grid caches total at most 16 MiB per renderer; overlay tessellation
uses at most 16 MiB; each cache has a 256-entry limit and evicts/prunes entries.
GPU command payload leases have a separate 256 MiB limit. Feedback permits at
most eight referenced routes, 4096 per axis, 16M total pixels, one pending command
and four retained generations. Requested payload accounting is not a measurement
of resident memory, allocator overhead or GPU driver memory.

## Live presentation regression

An initial visible opening of the original Composition demo caused two UI
accessibility timeouts. A native stack sample found most main-thread samples
inside `MTKView.currentDrawable` / `CAMetalLayer.nextDrawable`, waiting for a
presentation buffer. The earlier offscreen checks did not exercise this path.
The live adapter now acquires only the drawable on a serial worker with one
pending request. View/document/media access and encoding remain on main; stale
window/layer/size completions cancel, and GPU command leases remain bounded.
Apple documents the blocking acquisition and supports a separate rendering
thread in its [custom Metal view example](https://developer.apple.com/documentation/Metal/creating-a-custom-metal-view).

The new `--live-composition-test` measures a real visible 1920×1080 original
Composition interval separately from controlled drawable-wait, resize/hide,
nil-result recovery and renderer-lifetime fixtures. Final optimized run passed **5 checks**. Over its six-second 1920×1080 interval,
300 main-queue probes recorded a maximum 41.612 ms and mean 0.203 ms; startup
was separate (maximum 235.296 ms). A controlled 0.503 s acquisition wait ran on
the worker while 26 main probes continued (maximum 2.048 ms). These observations
are specific to this local run, not latency or refresh guarantees. [Raw report](stage-2/live-composition-test.json).

## Full editor and tool regression

The visible renderer-only interval is supplemented by `--live-editor-test`:
an actual EditorController, its production timer/material clock, native
Input/Output actions and ordinary auto-resize. Duplicate surface/selection/mode
assignments and unchanged layout sizes no longer rebuild the static overlay.
The first successful diagnostic full-editor run preserved layer identity for
six seconds, kept the model intact and resumed acquired drawables after mode
changes and resize. The final optimized run passed all three checks: 279 completed commands during 6.001 seconds at 1506×848, 300 main probes, maximum 2.651 ms and mean 0.100 ms, with static overlay layer identity preserved. This is an automatic visible-editor test, not manual GUI evidence.

Tool modes now have one backing owner instead of independent Boolean flags;
path/mask entry cannot retain warp or freehand routing. Native regressions cover
the previous path-handle indexing failure, mask-to-warp misrouting and ordinary
image import replacing a feedback source. No source geometry is changed by a
mere mode switch.

## Manual checks

The first locally accepted extracted candidate opened separate temporary copies of both the original
image/video Demo and the five-layer procedural Composition through File → Open.
The Composition screenshot showed the curved color layer, isolated masked blend,
posterized material layer and original cubic accent. On layer 02, Save point
changed the first Output world x from 0.07985741969430582 to 0.09; reopening the
controls after Undo restored the original value and Redo restored
0.09000000000000001. The mesh link stayed OFF.

On layer 04, Save FX changed saturation from 0.35 to 0.6 while retaining five
posterize levels. Materials → Save + Assign changed the selected surface's
`speed` override from 1.4 to 1.1, leaving the original expression and provenance
visible. Save cleared the dirty title. Quit, relaunch and File → Open restored
the five layers; reopened FX and Materials dialogs showed saturation 0.6,
five levels and speed 1.1. Play changed to Pause and advanced the show position;
Pause retained 00:05. The temporary project was closed. The original repository
demos and existing recovery snapshot were not altered by this manual run.

Earlier accessibility/screenshot timeouts are retained as observations, not a
final manual pass. That extracted run completed the workflow above without
those timeouts. The optional launch_app wrapper was unavailable; it was not used
to establish success. Hidden native callbacks and the automated visible-editor
suite remain A evidence. No claim of manual coverage for every new control,
physical hardware, optical refresh or sustained UI/render throughput is made.

## Hardware and remaining limits

Offscreen tests use 128×96, 64×64, 127×95 and 320×180 fixtures, with 32×18 feedback
routes; there are at most four fixture layers and two feedback routes. These
are frame oracles, not a throughput benchmark. No optical seam, physical hotplug,
refresh synchronization, 4K/60, long-duration stability or decoder/audio drift
claim is made. Edge ramps sum numerically in simulation; physical projector
measurements remain a separate H gate. Surface scenes do not snapshot shared
group/material definitions; group automation belongs to later show-control work.

## Compiler compatibility follow-up

The first exact-source [CI run](https://github.com/aborokhvostov/ApertureCue/actions/runs/45881718483)
for `e5918a2` failed before tests: Swift 6.1.2 on macOS and 6.0.3 on Linux
could not type-check a compact matrix-product `reduce` expression. An explicitly
typed accumulation loop preserves the calculation and avoids that compiler
limit. The corrected build passed all 133 standalone core methods and all eight
production modes from its freshly extracted archive. The raw reports above now
describe that corrected source (`0310457`). The manual GUI run preceded this
compiler-only rewrite; no editor source changed after it. SHA-256 comparison confirms that the
optimized executable and core dylib are byte-identical across that rewrite. Exact-source CI passed on both platforms and completed macOS packaging; see
[CI summary](stage-2/ci.json) and [published asset identity](stage-2/release.json). No failed CI run is counted as an XCTest pass.
