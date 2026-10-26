# Native GUI workflow observations

Date: 26 October 2026, Europe/Moscow. macOS 26.6.2, Apple M2, 8 GiB RAM. These are native UI observations performed by the agent through CUA, distinct from hidden controller tests and human or external-hardware certification.

An isolated production-app copy was used. Only its bundle identifier/display name were changed to `org.aperturecue.gui-check` / `ApertureCue GUI Check`, then it was signed ad hoc. Application logic was unchanged. Documents stayed under ignored `.build/gui-check`. The original demo and existing user projects were not edited.

| Operation | Observed result |
|---|---|
| Launch/open original demo | Native editor opened with the generated calibration image, H.264 movie and two surfaces. |
| Save As | NSSavePanel created a separate `GUI.aperturecue.json`. |
| Add/rename | `+ Quad` added a third layer; the name field committed `GUI Quad`. |
| Output corner drag | Moving its first handle changed the rectangle into a projective quad. |
| Undo/Redo | Undo restored the rectangle; Redo restored the moved corner. |
| Input corner drag | Input region showed the source. Its first handle changed the crop independently; both coordinate sets were checked in saved JSON. |
| PNG/movie import | Import accepted a multiple selection of the original PNG/MOV. The bin grew to four assets and the selected surface received the movie. |
| Play/Pause/Seek | Play displayed changing frames and changed to Pause. Pause stopped the clock. Seek to 1.5 seconds persisted and showed `00:01 / 00:03`. Loop was enabled; precise wrap behavior is covered by the media self-test. |
| Fullscreen | Outputs offered `0: Built-in Retina Display`. Open fullscreen showed a separate borderless composition without editor handles. Escape returned to the editor with zero output windows. No external-projector/multi-display rig was tested. |
| Quit/relaunch/reopen | A normal quit completed. A new process opened the saved three surfaces/four assets with their geometry. |
| Forced-termination recovery | An unsaved rename `Recovered GUI Quad` appeared in the automatic sidecar while the main file still contained `GUI Quad`. Only the isolated process was terminated with SIGKILL, after checking its executable path. Reopening offered `Recovery snapshot found`; Restore recovered the new name and dirty marker. |
| Save restored state | Save persisted the recovered name and removed the sidecar. Original demo stayed two surfaces/two assets. The test app quit. |

The saved first corners after independent drags were:

```json
{
  "input": {"x": 0.09748083242059145, "y": 0.10700389105058365},
  "output": {"x": 0.14676889375684557, "y": 0.14591439688715954}
}
```

Other input corners remained unit-square corners; other output corners remained `(0.9,0.1)`, `(0.9,0.9)`, `(0.1,0.9)`. Media references were relative. File assertions confirmed the restored three-surface/four-asset document, removed sidecar and unchanged original demo.

No camera permission, physical MIDI/light node or external lighting destination was used. GUI status FPS was not treated as a benchmark. Power-loss durability, physical hotplug and long-show stability remain separate gates.
