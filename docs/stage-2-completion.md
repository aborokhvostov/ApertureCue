# Stage 2 acceptance ledger

Scope: **Geometry and composition**, G04–G19, V07–V11 and O02/O04.
The roadmap and feature matrix define the declared software acceptance criteria;
this does not establish full reference parity. Hardware H gates stay separate.

## Software workstreams

| Workstream | Implemented behavior | Automatic evidence |
|---|---|---|
| G04–G11 | Retained primitive/path/group/history behavior; freehand capture, numeric transforms/nudge, independent regular input/output meshes | Core, production editor and GPU regressions |
| G12/G13 | Bounded rational Bézier warp, conforming error certificate, explicit source/output link; cage edits carry lattices and preserve unlinked source UV | Dense core certificate, analytic Metal UV, linked editor/history/persistence |
| G08/G14/G15 | Projective groups, isolated opacity/blend/FX, multiple layer/group/global polygon and cubic masks | CPU/Metal scope, alpha/blend/AA and native mask/group commands |
| G17 | Output ramps, power/gamma/black level; complementary simulated overlaps | Independent CPU/GPU channel oracle and pair/four-tile sums; optical H open |
| G18/G19 | Strict original SVG subset to owned PNG; deterministic bezel/overlap crops and independent routed clones | Exact raster pixels, media/Metal import, tile coverage/routes and history |
| V08 | Chroma/luma key, spill and declared color FX before tint | CPU/GPU numerical oracle and native edit/rejection/history |
| V10/V11 | Typed expression editor/parameters, last-good accepted pipelines and declared ISF expression subset | Parser/CPU/Metal, import provenance, native assignment/delete/scene/history |
| O02/O04 | Independent routed views, immutable previous-generation feedback, reset/backpressure/dimension limits | Hidden routed frames, self/cross-loop GPU oracle, stale completion and deletion/Undo |
| Live presentation | One pending background drawable acquisition; main owns scene/media/encoding, stale view/window/size cancellation and three GPU slots | Five live/delayed/nil/cancellation/lifetime checks |
| Persistence | Schema 12, current/stored-cue migration, 15 selective fields, save/reopen/recovery/Collect and original demos | Core and production controller checks |

## Completion gates — 26 November 2026

- Core: **133 standalone methods, zero failed assertions**. This is the shared
  assertion harness, not XCTest execution. Core sources are unchanged since this run.
- Optimized native app: **81 editor**, **25 composition**, **51 GPU/media**,
  **27 montage**, **11 lighting/UDP**, OSC/MIDI loopback and **5 live presentation** and **3 full-editor live checks** — PASS.
- Final ZIP: CRC, signature, executable mode and exact app/demo/example bytes — PASS.
  Extracted app passed **81 editor**, **25 composition**, **5 live presentation**
  and **3 full-editor live checks**; [raw reports](verification/stage-2/).
- Visible final GUI: original Composition rendering, numeric warp edit/Undo/Redo,
  material and FX edits, Save/Quit/relaunch/reopen and Play/Pause — PASS within
  the [documented manual scope](verification/composition-workflow.md#manual-checks).
- Exact-source macOS/Linux XCTest and publication: pending. No release-complete
  claim precedes actual remote results and confirmed uploaded assets.

CPU cache requested payloads share 64 MiB; each renderer uses at most 16 MiB and
overlay tessellation at most 16 MiB, with 256-entry LRU bounds. GPU payload leases
have a separate 256 MiB limit. Feedback has eight referenced routes, 4096 per axis,
16M total pixels, one pending command and at most four retained generations.
These are software payload limits, not measurements of driver/RSS/hardware capacity.

## Observations and retained limits

Checkpoint `ff2c742` saved the unfinished stage before the user's pause; no cloud
continuation ran. Resumption found and fixed malformed mesh-weight indexing,
legacy cage/reset/mode integration, Input-preview PNG export, last-feedback
history cleanup, full-cue interior collapse and exact explicit-cage storage.
A visible Composition opening then exposed main-thread `nextDrawable` waiting;
the separate acquisition queue and new live checks address that path. Initial
failed/diagnostic runs are not counted as final production evidence.

All distributed code/media/shaders/SVG are original. No proprietary SDK or
MadMapper assets are included. Filled FreeDraw/alternate joins, arbitrary shader
programs/full ISF, broader SVG/FX and shared group automation remain explicitly
outside the declared subset. Physical seams, display hotplug/refresh, external
projectors and long-show timing/throughput remain separate open hardware/run gates.
The next software stage after acceptance is media timing and durability.

## Compiler compatibility follow-up

The first exact-source [CI run](https://github.com/aborokhvostov/ApertureCue/actions/runs/45881718483)
for `e5918a2` failed before tests: Swift 6.1.2 on macOS and 6.0.3 on Linux
could not type-check a compact matrix-product `reduce` expression. An explicitly
typed accumulation loop preserves the calculation and avoids that compiler
limit. The local optimized/standalone reports above describe the preceding
candidate; the corrected archive and exact-source CI are being rerun before
publication. No failed CI run is counted as an XCTest pass.
