# Stage 5 · Control protocols

Stage 5 adds an opt-in control panel, stable mapping definitions in schema 15
and connection status for OSC, MIDI and OSCQuery. The previous fixed commands
remain available as a fallback. [Mapping specification](control-mapping-spec.md)

| Scope | Implemented software behavior |
|---|---|
| N01, H06 | Select MIDI 1.0 source and feedback endpoint by UID. Decode running status, notes, CC7/CC14, pitch bend and realtime transport bytes. Reconnect on CoreMIDI notifications, invalidate stale delivery, and restore feedback from the current show. |
| N02, S08 | Retain OSC 1.0 bounded message/immediate bundle handling and add blobs. Map normalized values or trigger edges to saved UUID targets. Bind one local IPv4 address, with one explicit peer outside loopback. Timed OSC tracks use an explicit session destination and saved per-event ports. |
| N03 | Read-only OSCQuery HTTP metadata and values, localhost DNS-SD discovery, WebSocket subscriptions, structure changes and automatic initial state on a new connection. OSC UDP handles writable paths. |
| N04 | ArtDmx IPv4 output with bounded updates, retirement, destination-specific sequences and explicit targeted ArtPoll/ArtPollReply diagnostics. |
| N05 | sACN IPv4 unicast/multicast addressing, optional sync and per-destination sequence/termination lifecycle. |

Protocol packet checks use original inputs and controlled receivers. Hardware
tests remain separate for physical MIDI/feedback controllers, network nodes,
field multicast routing, lights and optical timing. Art-Net OEM registration
and current E1.31 conformance remain separate from the implemented subsets.
See [lighting transport](lighting-transport-spec.md) for scope and sources.

The original ControlMapping demo uses procedural surfaces, OSC fader and
trigger mappings, and a CC14 mapping with optional feedback. Opening the
demo restores mappings and leaves all services stopped.

## Implementation and evidence

- [Control mapping specification](control-mapping-spec.md) describes stable
  address identity, saved bindings, input ranges, trigger thresholds and queues.
- [MIDI control](midi-control-spec.md) describes the byte stream and endpoint
  reconnection. [OSCQuery](osc-query-spec.md) describes HTTP, WebSocket, DNS-SD
  and the direct URL available after a Bonjour timeout.
- [Lighting transport](lighting-transport-spec.md) describes ArtDmx and sACN
  ports, supported packets, rate/retry, stream retirement and synchronization.

The acceptance checks distinguish the core assertion harness, SwiftPM XCTest
on both CI runners, the optimized AppKit build, and a scoped visible workflow
using an isolated copy of the demo. Virtual MIDI endpoints and original UDP and
multicast fixtures exercise the real macOS adapters. The original demo contains
two procedural surfaces and one logical output. The protocol checks do not
require media files. Earlier media and rendering workloads remain regression
checks with their own resolutions and timing.

The first packaged candidate failed in the signed build during Bonjour
registration and then at the Foundation client's local HTTP request. The
tested correction declares the service and limits the ATS loopback exceptions
to `127.0.0.1` and `localhost.`. It also bounds optional DNS-SD registration
to five seconds. A separate fault-injection run withheld the callback and
confirmed that the direct HTTP path remained available. The first candidate
was superseded before release.

## Acceptance results

| Check | Result |
|---|---|
| Portable direct compiler | 183 standalone test methods, 0 failed assertions. |
| SwiftPM CI on the tagged source | 183 XCTest each on macOS and Linux, with zero failures. The macOS job completed its release build, native bundle, distribution ZIP and artifact upload. [CI](https://github.com/aborokhvostov/ApertureCue/actions/runs/45952678380) |
| Optimized local app | 20 modes passed, including 5 mapping, 5 CoreMIDI, 6 OSCQuery, 4 extended lighting transport, 11 GPU-to-UDP and 91 editor checks. |
| Visible AppKit workflow | The diagnostic app opened the four-binding demo and showed the lighting controls. The final extracted app added and undid a binding and stopped and restarted Query on the same port. The extracted integration mode verified Save/Open and stopped services. |
| Distribution | The 45-entry ZIP passed CRC, strict signature, executable mode and app/demo byte checks. Seven focused modes passed in the freshly extracted app. [Distribution](verification/distribution.md#alpha-18) |

The 120.025-second media regression used four original 160×96, 30 fps
H.264/MOV sources and zero logical outputs. It recorded 13,260 pulls, including
806 without an eligible frame, with maximum legacy clock drift of 122.223 ms
and maximum eligible managed PTS age of 212.526 ms. This workload measures
acquisition and timing on one Mac. [Production reports](verification/stage-5/)
