# Lighting network transport

The **Lighting network** window starts and stops output for this app session.
Choose **Art-Net unicast** or **sACN unicast** and enter a numeric IPv4 destination.
For **sACN multicast**, each universe uses its own group. Set the maximum rate
between 1 and 30 Hz and optionally choose an sACN synchronization universe.
A synchronization value of 0 sends immediate data frames.

## Art-Net node inspection

**Check Art-Net node** sends one targeted ArtPoll to the explicit IPv4 address.
Enter an inclusive Port-Address range in the supported 0…32767 range. The window
shows matching ArtPollReply bindings, sanitized device names, DMX512 input/output
Port-Addresses and the advertised refresh limit. It waits up to 1.2 seconds,
examines at most 128 datagrams and retains up to 32 distinct bindings from the
selected peer and port. A later check evaluates a fresh reply window. Previous
replies do not prove that a node is still connected. Probes are user initiated and
limited to one per 2.75 seconds. Manufacturer and OEM fields are unassigned.
[Art-Net 4 revision 1.4dp](https://art-net.org.uk/downloads/art-net.pdf)

ArtDmx output remains explicit IPv4 unicast from UDP source port 6454. Inspecting
a node does not start output or replace the configured destination. Full
subscriber management, periodic network-wide controller discovery and OEM
registration remain separate work.

## sACN synchronization and addressing

The data sender sends zero start code frames to UDP port 5568. In multicast mode,
universe U uses `239.255.(U >> 8).(U & 255)` and hop limit 1. The sender uses the
OS-selected IPv4 multicast interface. If synchronization is enabled, the sender
sends the frame's data universes first, followed by a synchronization packet with
the same CID and its own sequence. On unicast it uses the same peer. On multicast
it uses the group of the synchronization universe. Force Synchronization stays
off. This packet layout uses the IPv4 subset corroborated by ETC's implementation
of the earlier edition. The current ANSI E1.31-2025 edition also covers IPv6.
[ANSI E1.31-2025 listing](https://webstore.ansi.org/standards/esta/ansie1312025)
[ETC reference wire implementation](https://github.com/ETCLabs/sACN/blob/main/src/sacn/pdu.c)

Current implementation scope covers IPv4 data, synchronization and termination.
IPv6, PAP, Universe Discovery, multi-NIC configuration, interoperability and
full current-standard conformance require their own verification.

## Stream lifecycle

The sampling workspace and network output share the newest sampled levels. The
sender keeps one normal batch in flight and one newest waiting frame while
capped by the destination's session rate. Sequence counters advance separately
per destination and universe. The latest attempted streams are retained so that
stopping or moving to another endpoint sends zero to the active endpoint. A
removed universe sends zero using its last slot count. An sACN retirement sends
ordinary zero, a synchronization packet if configured and three consecutive
StreamTerminated packets with sync address zero. Changing the output configuration
retires the old streams before new ones are queued.

A local socket/send error is visible and retried after at least 500 ms while
output remains active. The retry uses the newest sampled levels. Stop cancels
queued ordinary frames and invalidates asynchronous sample results. UDP sends
provide no receiver acknowledgement. Use **Check Art-Net node** to observe a
specific Art-Net peer again after an interruption.

## Verification boundaries

Core tests cover literal packet bytes, lengths, wire byte order, binding and
port fields, multicast addresses and sync framing. Native transport tests use
original UDP fixtures on 127.0.0.1. The multicast fixture explicitly selects the
loopback interface. They cover targeted request and source-port validation,
duplicate and out-of-range replies, timeout and rediscovery, synchronized frame
order, rate/latest-frame behavior, universe retirement, Stop and local socket
recovery. The production GPU lighting regression remains a separate test.
Physical receivers, switch and NIC behavior, DMX framing and timing at the
fixture, simultaneous display and sustained throughput remain hardware gates.
