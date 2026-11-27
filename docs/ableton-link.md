# Ableton Link scene recall

**Show → Ableton Link…** can recall a selected scene on the next four-beat boundary. The helper shows its name, peer count, tempo, current beat, and phase in the four-beat quantum. The show timeline, media playback, MIDI Time Code and OSC clocks retain their existing control paths.

## Build and connect

Use a clean checkout of Ableton Link 4.1.1 at `5ba907ae027a8c2ec8824463e37296dcefc5e9be`, with its Asio submodule at `8806a6803cde7054c3049d3666d3ec36786568c5`. From the ApertureCue checkout, run `optional/link/build.sh /path/to/Link-4.1.1 /path/to/helper-output` with the macOS developer tools installed. The build writes `aperturecue-link` in the chosen directory and does not fetch dependencies. Use **Choose helper…** in the panel to select that executable. [Ableton Link 4.1.1 source](https://github.com/Ableton/link/tree/5ba907ae027a8c2ec8824463e37296dcefc5e9be)

Click **Connect to Link on LAN** when you want the helper to join the Link session on your local network. ApertureCue starts with Link off and stores the connection only for the current panel session. The bridge observes Link tempo and phase without committing tempo changes or synchronizing transport start and stop. An existing Link participant must be present to queue a scene. [Ableton Link concepts](https://ableton.github.io/link/)

Select a scene, then click **Queue cue on next bar**. The scene recalls once after the next confirmed four-beat boundary. A new choice replaces the pending recall. Click **Cancel queued cue** to clear it. The panel also cancels a pending cue on a timeline edit, local seek or discontinuity, scene edit, peer loss reported by Link, bridge loss, or project replacement. Abrupt peer loss is detected on Link's discovery expiry. Closing the panel disconnects Link and clears the pending cue.

## Test and distribution scope

Pass `--fixtures` as a third build argument to get the separately compiled bridge and controllable peer under `fixtures/`. They use a temporary upstream header overlay to bind IPv4 multicast to macOS loopback and a private group. Run `ApertureCue --ableton-link-test /path/to/fixtures/aperturecue-link /path/to/fixtures/aperturecue-link-peer` against the application's executable. The native test measures phase at common monotonic timestamps and checks cue recall, cancellation, and peer recovery. It writes `artifacts/local/ableton-link/report.json`. The test scope is two same-host processes and a hidden native editor.

The standard app builds without the helper, SDK, or test overlay. The optional helper compiles the public Link source under GPL-2.0-or-later with standalone Asio under the Boost Software License 1.0. Distribution of a prebuilt helper would require publishing its corresponding source and license notices. [Link license](https://github.com/Ableton/link/blob/5ba907ae027a8c2ec8824463e37296dcefc5e9be/LICENSE.md) · [Asio license](https://github.com/chriskohlhoff/asio/blob/8806a6803cde7054c3049d3666d3ec36786568c5/LICENSE_1_0.txt)
