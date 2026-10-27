# Selective Cue native GUI verification

27 October 2026, Apple M2 / arm64 / macOS 26.6.2. Agent-driven native GUI through CUA in a separate ad hoc signed production copy, bundle ID `org.aperturecue.selective-check`; only bundle identity/display name differ. The original procedural SelectiveCues demo was copied to a new system-temporary JSON document. No existing user project or reference installation was edited.

1. Open Scenes. All four demo cues, two snapshot rows, 13 field checkboxes and stored/current columns are present. In a new draft, select opacity/RGB on the polyline and brightness on the cubic. Switching rows retains distinct UUID-bound masks. Set duration0 and Capture selective: a fifth saved scene appears with 3 fields on 2 surfaces; its scope picker is disabled.
2. In the main editor, rename the first live layer, set opacity0.4 and brightness1.7, then add a third layer. Return to the saved scene: Stored opacity1 versus Current0.4 and Stored brightness1 versus Current1.7 are visible. The first layer's brightness remains unchecked.
3. Rename the cue to `GUI saved mask`, add Gamma, and Save cue properties / fields. Stored opacity remains1. GO selected changes only included values: Current opacity becomes1, excluded brightness remains1.7. Undo changes current opacity back to0.4.
4. Recapture values explicitly changes Stored opacity to0.4. Its snapshot row now reflects the current layer name. Save the document from the main editor; all three current layers remain, including the later third layer.
5. Read back the own JSON independently: schema6, 3 current layers, 5 cues, first binding `[opacity,gamma,color]`, second `[brightness]`, recaptured opacity0.4, excluded live brightness1.7/name preserved. The test app quits normally.
6. The initial GUI pass exposed intrinsic-label width growth. A separate native AppKit probe measured the requested1120-point window expanding to1493. The corrected layout lowers horizontal compression resistance on value/help labels, truncates long values with full tooltips and wraps help. The identical probe then retained1120; a1440-character name and81-point mesh also retained1120, and the1060 minimum remained usable. Production editor checks assert the width for both new and stored scenes.

7. Relaunch the corrected production copy and Open the saved schema-6 document. The main editor restores three layers, the edited name, opacity0.4 and brightness1.7 with a clean title and stopped playhead0. Scenes opens at the requested1120-point width, with truncated geometry/path values and working columns. Select `GUI saved mask`: duration0, disabled saved scope, first target opacity/Gamma/RGB and second target brightness are restored; captured opacity0.4 is visible. Quit normally.

Native GUI result: PASS for the steps above. Archive execution and exact-source CI are separate publication gates.

Automatic checks cover additional masks, interpolation samples, hidden visibility, missing-only clean no-op, orphan-track/marker deletion, group frame ambiguity guards, active timeline precedence and a running generated H.264 decoder. Those are automatic evidence, not additional manual GUI observations. Follow/interruption/full recall remain covered by core/editor tests; this GUI run does not claim every field combination was manually exercised.

The first CUA launch was delayed by tool/host availability. That interval is not a measured soak. No physical projector, external display, camera, MIDI or lighting hardware was tested; UI statistics are not a new throughput or optical latency benchmark.
