# Control mappings

Open **Show → Control mappings…** or **Control…** in the main window. A
mapping stores a source and a target in the project. Both a surface target and
a scene target use their persistent UUID across renaming and reordering.

## Inputs and editing

- **Start OSC** opens one explicit IPv4 address and UDP port. The defaults are
  127.0.0.1:9000. To listen on another local address, set the sender field
  to one explicit peer IPv4 address. The socket filters by sender address.
  OSC is UDP and has no authentication or encryption at this layer.
- Choose a concrete MIDI source and, optionally, an independent destination
  for feedback, then **Connect MIDI**. A selected UID rebinds when it reappears.
  Each connection starts with fresh running status and 14-bit controller state.
- **Add mapping…** enters a concrete OSC path or a MIDI channel and note or
  controller. **Learn next input** captures one supported input and consumes it
  without applying its action. **Map learned input…** opens the mapping editor.
  For an MSB/LSB pair, choose **MIDI cc14** and the MSB controller number 0–31.
- Up to 256 entries can bind a surface opacity, brightness, gamma or an RGB
  multiplier, a scene, playback, stop, seek or blackout. Entries support
  Undo/Redo. The input key must be unique. Deleting a scene or losing the last
  saved owner of a surface also removes its mappings.
- Scalar mappings use one finite numeric argument or bool in 0…1 and clamp
  outside that range. MIDI notes map the held and released states to 1 and 0.
  Triggers accept a no-argument OSC pulse, or fire at 0.5 and rearm at 0.25
  or lower. Inversion reverses the normalized value. Mapped Seek scales over
  timeline duration. A direct Seek is in seconds.
- MIDI feedback is available for mapped surface parameters, blackout and
  playback toggle. Only changed quantized values are sent to the selected
  destination. Active note indicators are released on Disconnect or a mapping
  edit when the destination is connected. Reconnection sends current values.

The built-in OSC aliases and fixed MIDI profile still work for inputs without
a custom mapping. The selected MIDI endpoint is the only endpoint subscribed
by the mapping editor. The Show Control Tracks and Clock window continues to
own timed output events. Its OSC destination is one explicit unicast IPv4 address
per armed session. The per-event OSC destination port stays in the project.
The virtual show MIDI source and separate external clock have their own arms.

## OSCQuery tree and direct OSC addresses

Start localhost OSC, then **Start Query**. The Query listener binds to IPv4
loopback and advertises the currently bound OSC UDP port. **Local discovery**
publishes a local-only DNS-SD service. The HTTP tree provides descriptions,
types, access, ranges and values. WebSocket can subscribe to leaves and receives
OSC binary updates and supported path changes. [OSCQuery Proposal](https://github.com/Vidvox/OSCQueryProposal)

The tree includes up to the first 200 current surfaces. Direct OSC accepts
all current surface IDs through these canonical lowercase paths.

| Path | Value |
|---|---|
| /aperturecue/surfaces/&lt;uuid&gt;/opacity | Float 0…1 |
| Same path ending in brightness, red, green or blue | Float 0…16 |
| Same path ending in gamma | Float 0.01…10 |
| /aperturecue/transport/time | Float seconds, seekable through transport limits |
| /aperturecue/transport/playing | Read-only integer 0 or 1 |
| /aperturecue/blackout/value | Integer 0 or 1 |

Surface values are document values before the current timeline, Conductor and
signal overrides. Write them with OSC UDP. Query HTTP publishes values and
metadata. Paths use concrete addresses and immediate bundles. The basic codec
supports int32, float32, ASCII string and blob, plus bool tags. Receiver limits
cover nesting, packet size, strings, blob padding and elements.
[OSC 1.0 specification](https://opensoundcontrol.stanford.edu/spec-1_0.html)

A token bucket allows up to 512 datagrams/s with a 128-datagram burst. Parsing
stays off the main thread. The bounded mailbox retains at most 256 commands
and uses one scheduled drain. The editor holds at most 64 pending intents and
coalesces consecutive fader changes. Queue overflow drops the oldest work and
appears in status. OSCQuery publishing runs at up to 10 Hz and the MIDI feedback
poll at 20 Hz with up to 32 changed mapping events per poll. New/Open and Quit
stop input, feedback and Query. None of these services start when opening the demo.

[MIDI adapter details](midi-control-spec.md) · [Lighting transport](lighting-transport-spec.md)
