# Graphical parameter timeline GUI verification

27 October 2026, Apple M2 / macOS 26.6.2. Agent-driven native GUI via CUA, in an independently signed production copy `org.aperturecue.timeline-check` (only bundle name/identity changed). Opened a system-temporary copy of the original Timeline demo; no existing user project or reference installation was edited.

1. Open **Timeline…**. The independent native window lists three parameter tracks, Pause at 4 s and Scene at 8 s, and a curve graph. Double-click `(1150,1000)` adds an opacity key at approximately `(4.34408602 s, 0.31343284)`.
2. Drag that diamond to `(1200,900)`; numeric fields become `(4.88172043 s, 0.43781095)`. Toolbar Undo restores the earlier values; Redo restores the moved key.
3. Select outgoing **Bezier**, **Save key**, then drag the first orange curve handle. C1 becomes approximately `(0.19230769,0.24336283)`. The graph updates; the normalized time controls remain ordered.
4. Play from 0. The real UI returns to **Play** at exactly `4.000 s` on Pause. Play again resumes without retrigger and reaches finite end `12.000 s`. The saved current surface geometry matches the scene addressed by the 8 s marker, independently checked in the own JSON document.
5. Enable loop, set Start 5/End 10, apply, seek9.5 and Play. The clock stays playing and returns below the start position inside the5...10 range; Pause freezes it at 7.399 s in the observed sample. Stop resets0. Save the project and quit normally.
6. The first GUI pass exposed unused right-side space in the graph. The final production rebuild binds graph width to the available window and uses a flipped scrolling track sidebar; a hidden editor assertion also verifies graph width. Relaunch/Open the saved project, reopen Timeline: the graph fills the window, all three tracks and the changed curve remain, loop 5...10 is restored, and playhead begins0.
7. Drag the ruler past the4 s Pause marker: explicit seek reaches 5.006 s and stays paused without marker action. **Fit** changes view end from 10to12. **Add marker at playhead** inserts a visible Pause at 5.006 s; Undo removes it. Quit the own test app.

Saved-file assertions confirm schema 5, three tracks, five keys in the edited opacity track, the changed time/Bezier C1, loop 5...10, and the scene marker's final target geometry. The initial view/edit examples used the first layout pass; the final rebuild keeps the same runtime/edit code and adds the width/layout regression. Final production checks are recorded separately in status/distribution.

Scope: scalar parameter tracks, not media/audio/MIDI/OSC montage or full Conductor. Scene fades retain their host clock independently from parameter Pause. Logical marker time and UI labels are not measurements of physical event latency, decoder frame lock, presentation FPS or long-run stability. No external projector/camera/MIDI/light hardware was tested here.
