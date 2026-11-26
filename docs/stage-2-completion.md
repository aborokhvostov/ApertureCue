# Stage 2 completion ledger

The active user request is to complete the whole **Geometry and composition**
stage, rather than stop after another isolated alpha. The existing roadmap and
feature matrix remain the acceptance contract. Hardware evidence stays separate.
No stage-complete claim precedes its frame, persistence and editor gates.

## Paused checkpoint — 26 November 2026

The user paused local work to move and close the laptop. Development is stopped;
there is no background continuation scheduled. Cloud environment discovery found
a ready default configuration with no attached repositories, but the available
thread handoff explicitly does not support cloud and thread creation only offers
local/worktree execution. No cloud task was started.

The published, verified baseline remains alpha 14 (`b2b2b73`); the prior local
documentation commit is `4a0f19f`. All stage 2 changes below are an unpublished
integration checkpoint, not a completed stage or a release candidate.

Implementation now includes schema 12 and stored-cue migration, projective and
isolated groups, Bézier/source warps, mesh linking, freehand/nudge commands,
layer/group/global polygon and cubic masks, material expressions and the declared
ISF subset, key/color effects, SVG import, video walls, edge ramps and bounded
previous-frame feedback. Native controls and production self-tests are wired in.

Automatic evidence: the final `scripts/test-core.sh` run completed **133 standalone
test methods, zero failed assertions**. These are the shared test bodies through
the assertion harness, **not XCTest execution**. Its log is
`/tmp/aperture-stage2-core-final.log` (temporary local evidence). `git diff --check`
passes. No core-check compiler or runner remained active at pause. Earlier runs
whose input files changed during compilation do not count as successful evidence.

Native integration remains unverified. A semantic typecheck found the timeline
default argument typo, now corrected to `ProcessInfo.processInfo.systemUptime`;
the integrated app has not been rebuilt after the final edits. The existing
`dist` app/archive are alpha 14, not stage 2 builds. No stage 2 GUI, full production
Metal/editor/lighting regression, remote macOS/Linux XCTest or hardware result
has been claimed. Subagents have finished and are idle.

Resume by reading this ledger together with status, roadmap and feature matrix;
build using `scripts/build.sh`, resolve integration errors, then run the documented
production checks including the new `--composition-test` and extended editor
self-test in a logged-in graphics session. Verify feedback/resource bounds,
source mapping and group/mask pixel oracles before GUI workflows. Finish missing
acceptance work, update status/matrix and user documentation, run exact-source CI,
then audit original content and build a fresh archive before publication. Keep
hardware and physical seam/hotplug evidence separate from simulator/localhost.

| Workstream | Required behavior | State |
|---|---|---|
| G04–G11 geometry/editor | Retain tested primitives, groups, history and regular mesh; add direct numeric/nudge transforms and freehand path capture | Alpha14 baseline verified; additions pending |
| G12/G13 | Bounded Bézier warp, actual screen-space error certificate, explicit source/output link and UV preservation | Core module in progress |
| G08/G14/G15 | Projective groups, isolated group opacity/FX, multiple layer/group/global masks, closed cubic mask editing | Integration in progress |
| G17 | Complementary edge ramps with numeric GPU oracle; physical seam measurements remain separate | Core module in progress |
| G18/G19 | Bounded original SVG import with explicit unsupported errors; deterministic tiled outputs/bezel crops | Core module in progress |
| V08 | Chroma/luma key, spill and bounded color FX with CPU/GPU pixel oracle | Core module in progress |
| V10/V11 | Working material expression editor, parameters, last-good pipeline on error and genuine declared single-pass ISF subset | Core/parser module in progress |
| O02/O04 | Preserve independent routed outputs; explicit previous-frame feedback with bounded buffers and cycle-safe resets | Integration pending |
| Integration | Schema migration including stored cues; save/collect/recovery; native controls and generated demos | Pending |
| Completion | Core + actual macOS/Linux XCTest, production Metal/editor/lighting regressions, GUI workflows, fresh archive and provenance scan | Pending |

Parent owns shared project schema, group/render integration and native adapters.
Independent subagents own pure geometry, material parsing/FX, and SVG/blend/wall
utilities in separate files. A single schema boundary will ignore undefined new
keys in legacy documents before decoding, for current and stored scene surfaces.

All distributed media/shaders/SVG examples are original. No proprietary SDK or
MadMapper assets are part of this work. Physical projectors and hotplug remain
outside available equipment evidence; simulation cannot close those H gates.
