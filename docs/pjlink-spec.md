# PJLink projector control

Open **PJLink Projector…** and enter the IPv4 address of one projector or
display. Choose the authentication configured on that device and enter its
PJLink password when needed. The controller opens one TCP connection to port
4352 for each button action. The window keeps its fields only for the current
session and clears them on close or document change.

- **Read status** queries power, AV mute, diagnostics and the reported device
  class in one sequential transaction. A device can reject a query while
  cooling, warming or in standby. The panel displays that rejection and the
  other available values.
- **Power on**, **Power off**, **AV mute** and **AV unmute** each send one
  command. An acknowledgement means the device accepted the command. Use
  **Read status** to check the actual state after it transitions.
- **Cancel request** stops the active transaction and waits for the worker to
  close its socket before enabling new commands. If the command was already
  sent, read status to check the device state.

The command set covers the Class 1 forms of `POWR`, `AVMT`, `ERST` and
`CLSS`. The returned class reports what the projector or display advertises.
Device discovery, unsolicited UDP status, Class 2 extension commands and
automatic power retries are outside this client. [JBMIA specification v2.10](https://pjlink.jbmia.or.jp/english/data_cl2/PJLink_5-1.pdf)

## Authentication and transport

**SHA-256** is the default selection. It negotiates the v2.10 challenge,
combines the two 16-byte nonces and uses a fresh controller nonce for each
connection. **Legacy MD5** uses the eight-character challenge only when
selected by the operator. **No authentication** requires the device's plain
greeting. Authentication modes are selected explicitly. A rejected upgrade
ends the current connection. Authenticated modes accept up to 32 ASCII
alphanumeric password characters. PJLink digests are challenge responses.
The TCP exchange still needs a trusted network. [JBMIA authentication compatibility guide](https://pjlink.jbmia.or.jp/english/data_cl2/PJLink_2-1.pdf)

The Mac adapter uses an eight-second monotonic transaction deadline. The
socket remains on the worker, which checks cancellation between bounded
nonblocking TCP operations. The parser requires printable ASCII and carriage
return termination. It bounds line length, retains incomplete TCP fragments
and checks the class and command body of each reply. Password and addresses
stay out of project data, reports and error strings.

## Verification scope

Portable tests cover fragmented lines, hostile or mismatched responses, typed
device states, authentication negotiation, digest inputs and rejection of mixed
write batches. A native self-test sends commands only to an independent
original loopback scripted peer. It validates exact SHA-256 and legacy MD5
wire bytes, unsupported upgrade behavior, authentication failure, truncated
replies, deadline and close on cancellation. Physical power transitions,
standby-network configuration, vendor compatibility and site LAN behavior
have separate acceptance checks.
