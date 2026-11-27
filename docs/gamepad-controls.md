# Gamepad show controls

Connect an extended-profile gamepad in macOS, then choose **Show → Gamepad controls…**. Select the named controller, assign actions to buttons **A**, **B**, **X**, or **Y**, and click **Arm gamepad**. The four positions follow Apple’s extended profile. Button labels printed on a controller can differ.

Available actions are a cue from the current project, play, pause, toggle playback, stop, and blackout on or off. Each rising edge sends one action while ApertureCue is active. A button already held when you arm or return to the app must be released before it can trigger. **Refresh controllers** updates discovery and cue choices. Disconnecting disarms the session. Reconnection requires selecting and arming the controller again. Project replacement clears the device and button assignments.

The implementation uses the existing cue, transport and blackout action queue. Devices are selected by their current connection identity. The scope covers the standard extended profile's four face buttons. Physical USB or Bluetooth controllers, haptics, controller lights, and device-specific profiles have separate verification. [Apple Game Controller documentation](https://developer.apple.com/documentation/gamecontroller/gccontroller)

Run `--gamepad-test` for the software check. It creates two original virtual GameController snapshots and tests explicit input selection, held and background suppression, ordered actions, cue/transport/blackout execution, disconnect and reset. The report is written to `artifacts/local/gamepad/report.json`.
