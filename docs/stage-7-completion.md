# Stage 7 · External media and hardware

The current work adds a same-user external frame inbox, a separately built
Syphon receiver, projector control, Arduino input/output, MIDI Time Code,
macOS gamepad controls and optional Ableton Link scene launches. Devices
and clocks are session-based.
Only the external feed reference is added to project schema 17.

| Matrix | Working or pending path |
|---|---|
| V13 Syphon | Explicit-source optional macOS helper built against the public BSD upstream framework. It copies the latest frame to the app's bounded local inbox. The independent-process interoperability test uses the upstream OpenGL fixture source and Metal receiver. Syphon output, third-party source profiles and sustained throughput remain open. |
| V14 Spout | Official SDK uses Windows DirectX shared textures. A Windows desktop backend and a compatible DirectX test host are absent from this macOS-first build. [Official BSD SDK](https://github.com/leadedge/Spout2) |
| V15 NDI | The receiver runtime and test sender are absent. The public SDK document allows MIT headers with dynamic loading while the binaries and redistributables have separate terms. SDK integration and sender/receiver latency remain open. [NDI distribution terms](https://docs.ndi.video/all/developing-with-ndi/sdk/software-distribution) · [SDK download](https://ndi.video/for-developers/ndi-sdk/download/) |
| V16 Blackmagic/Canon | Existing macOS AVCapture input can list devices exposed by the OS. No DeckLink or Canon SDK/device combination was available for native integration. Camera models and driver versions require device-specific checks. [Desktop Video SDK](https://sdk-doc.blackmagicdesign.com/decklink-sdk/) · [DeckLink SDK terms](https://downloads.blackmagicdesign.com/EULA/DeckLink/DeckLink-End-User-License-Agreement.pdf) · [Canon compatibility list](https://developercommunity.usa.canon.com/resource/1727731595000/CDC_EDSDKRAW_Compat_List) |
| V17 Depth/legacy | No depth device or supported capture fixture was available. The upstream RealSense documentation advertises partial macOS capabilities. Platform and device subsets remain open. [RealSense macOS scope](https://github.com/realsenseai/librealsense/blob/master/doc/installation_osx.md) |
| H04 PJLink | Class 1 status, power and AV mute against a single explicit IPv4 endpoint. Verified against an original simulator. [Protocol and security scope](pjlink-spec.md) |
| H05 Firmata | Explicit buffered serial connection, handshake/capabilities, selected input and a mapped show control, explicit digital write and readback. [Firmata scope](firmata.md) |
| H06 Control surfaces | Existing MIDI mapping and feedback plus explicit GameController extended-profile face-button mappings in the active macOS app. Stream Deck and other vendor profiles and physical gamepads remain open. |
| N06 Synchronization | Existing localhost OSC clock and selected CoreMIDI Time Code support explicit clock ownership, loss and recovery. An opt-in Ableton Link helper supplies tempo and phase for the next four-beat scene launch. Start/Stop Sync, variable-rate media and free-running timeline alignment remain open. [Link timing and test plan](https://ableton.github.io/link/) |

The base application uses the Apple SDK, independently of the optional
helpers. Its archive contains the ad hoc signed app, original demo assets
and notices. Tests use original frame patterns, virtual endpoints, serial
PTYs and loopback responders. Physical model compatibility requires testing
the concrete device, firmware and macOS driver with its production path.

[External video inbox](external-video-spec.md)

## Verification

[Alpha 20](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.20) publishes the tested macOS work in schema 17. Windows and vendor media, depth input, Ableton Link media/timeline rate and Start/Stop Sync, sustained Syphon throughput and physical device profiles keep the full stage open.

| Gate | Result |
|---|---|
| Portable core | 215 methods ran locally in the standalone assertion harness with zero failed assertions. [Local report](verification/stage-7/core-summary.json) |
| GitHub Actions | 215 XCTest each on macOS and Linux, zero failures. The macOS job built SwiftPM release, signed the native app ad hoc and archived it with the original examples. [Run](https://github.com/aborokhvostov/ApertureCue/actions/runs/45968409998) |
| Original media | The 96×64 BGRA8 input restored one Metal surface and logical output across producer loss. The independent Syphon helper at upstream `f4761677a45b8034a3c2069ec0f3d2553da81fba` produced exact RGBA `[221, 92, 23, 255]`, black, then the source color again. [Inbox checks](verification/stage-7/external-video.json) · [Syphon checks](verification/stage-7/syphon-loopback.json) |
| Devices | The PJLink TCP simulator verified auth, status, writes and cancellation. The Firmata PTY verified exact serial input and individual pin output, reboot and remapping. Virtual gamepads verified focus and action routing. [PJLink](verification/stage-7/pjlink.json) · [Firmata](verification/stage-7/firmata.json) · [Gamepad](verification/stage-7/gamepad.json) |
| Time code | A separate virtual CoreMIDI source verified locate, play, dropout, arbitration and reacquisition. Maximum phase error across 74 samples was 0.449 ms. [MIDI Time Code](verification/stage-7/midi-time-code.json) |
| Native regression | 29 modes passed on the macOS 26.6.2 MacBook Air M2, Apple M2 GPU, 8 GiB. The 120.015-second managed media workload used four H.264/MOV 160×96 sources at 30 fps without outputs. 112 out of 13,952 pulls had no eligible frame. Maximum legacy drift was 124.464 ms and maximum managed PTS age was 198.516 ms. An initial CoreMIDI fixture client creation failed before the adapter was exercised. Two exact-binary repeats passed. [Mode results](verification/stage-7/production-modes.json) · [Media soak](verification/stage-7/media-soak.json) · [CoreMIDI retries](verification/stage-7/midi-control-startup.json) |
| Visible operator workflow | An isolated diagnostic app discovered and assigned an original CLI source, showed `Receiving`, and disabled assignment when the inbox stopped. The MIDI Time Code panel opened disarmed. The extracted app opened the packaged demo and showed both the inbox and Link initially disarmed. [Diagnostic workflow](verification/stage-7/manual-diagnostic.json) · [Extracted app](verification/stage-7/manual-release.json) |
| Fresh archive | Ten modes passed again after extracting the identical signed app and original demo bytes. The public tag and both asset digests match the verified local files. [Distribution record](verification/stage-7/distribution.json) · [Release record](verification/stage-7/release.json) |
| Hardware | Device-specific reports remain open for projectors, Arduino boards, MIDI timecode, gamepads, camera and specialty captures. Throughput across third-party Syphon sources and live-rig CPU/GPU use remain unmeasured. |
| Ableton Link | Independent test peers supplied real tempo and phase in an isolated software network. The app dispatched one queued scene on the next four-beat boundary and cleared pending launches after loss. The maximum phase difference across 24 common-time readings was 0.000003 beats. [Link verification](verification/stage-7/ableton-link.json) |

The offscreen Metal check rendered 300 frames at 640×360 with two procedural surfaces and one output. It measured 432.9 readbacks per second and 0.201 ms mean GPU execution per command. The short Syphon and Link tests also recorded process CPU time and peak memory. [Offscreen workload](verification/stage-7/self.json) · [Helper resource measurements](verification/stage-7/helper-resources.json) · [Visible synthetic composition](verification/stage-7/live-composition.json) · [Test regressions](verification/stage-7/test-harness-regressions.json)
