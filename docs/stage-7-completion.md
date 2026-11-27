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
