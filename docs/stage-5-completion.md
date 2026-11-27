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
