# Mapped MIDI control

The mapped MIDI session binds the input source and optional feedback destination
selected by the operator. CoreMIDI persistent Unique IDs identify endpoints.
When a selected endpoint is missing, the session waits for the same Unique ID
to return. Setup and property notifications trigger reconnection. Only the
selected source contributes input, and feedback uses the selected destination.
A missing destination drops feedback and reports a send failure. Opening a
project or stopping the session disposes ports and clears pending input.

## MIDI 1.0 bytes

The decoder preserves running status and partial messages across callbacks.
System Common and SysEx statuses clear running status. System Realtime messages
can appear between two data bytes. Clock, Start, Continue and Stop reach the
mapping layer; other System Realtime messages are ignored. Note On with velocity
zero is treated as Note Off. Channel numbers are 1…16 in the editor. Reported
pitch bend values are unsigned 0…16,383 with 8,192 as the center.

Standard Control Change events carry values 0…127. High-resolution Control
Change pairs controllers 0…31 with their fine controllers 32…63 on the same
channel. Once both halves have arrived, updates to either half also yield a
paired 0…16,383 event. Each connection starts with empty latches. Use the
high-resolution mapping for a 14-bit control and the ordinary mapping for a
seven-bit control. MIDI feedback validates channel and data ranges and emits
one message per command or two messages for a 14-bit CC.

CoreMIDI callbacks admit up to 64 packets and 4,096 MIDI bytes at a time.
The mailbox queues up to 256 decoded events, schedules one main-thread delivery,
and counts dropped batches. Truncation of raw bytes resets running status and
the CC latches. Endpoint replacement invalidates queued events from the previous
connection and establishes a fresh decoder. Independent connection generations
let the editor reset held triggers and feedback even when the same Unique ID
reconnects between update ticks. Sources published for timed show
output are excluded from mapped input discovery to avoid a local feedback loop.

## Verification scope

Portable checks cover running status, System Common/SysEx boundaries, realtime
interleaving, 14-bit channel state, pitch bend, malformed feedback and packet
budget. The native integration uses original CoreMIDI virtual sources and
destinations. It compares exact data bytes, ignores unselected endpoints,
recreates a removed endpoint with its previous Unique ID, confirms reset
decoder state and exercises the bounded input mailbox. Concrete physical
controllers, interfaces and feedback displays require separate verification.
