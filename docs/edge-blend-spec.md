# Output edge blending

`EdgeBlendSettings` is an original normalized output calibration definition.
Left/right/top/bottom widths are 0…1, with opposite-side totals at most one.
Zero disables that edge. Power is 0.1…10, gamma 0.1…5 and blackLevel 0…1.
For distance fraction t into an overlap use
`r(t)=t^power/(t^power+(1-t)^power)`, clamped at zero/one.
Opposite projector coordinates must be complementary: `r(t)+r(1-t)=1`.
Four edge gains multiply, so rectangular four-way overlaps factor into two
complementary sums. Tests cover both pairs and four-output wall weights.

`channel` applies `blackLevel+(1-blackLevel)*color^(1/gamma)*gain` to normalized
unpremultiplied RGB after composition, never once per overlapping layer.
Blackout must bypass calibration and stay black. Alpha belongs to the compositor.
Black lift can equalize software levels upward; it cannot reduce physical black.
No optical calibration, projector seam, HDR or hardware compatibility is implied.

The native Output edge blend dialog selects a logical output by UUID and saves
all fields as one validated history command. Stale modal snapshots reject.
The renderer must use identical ramp/calibration math for display, readback and
lighting. GPU golden frames and physical projector checks are separate gates.
