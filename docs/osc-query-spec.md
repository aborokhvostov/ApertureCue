# OSC Query

Enable OSC input on localhost, then start OSC Query from the control mapping
window. The Query port defaults to 9002. Keep each local OSC input service and
Query service on its own port. The Query server publishes the current control
tree for the open document. Closing the session or opening a different project
stops the listener. Starting it again uses the current document.

Use `http://127.0.0.1:9002/` for the tree and `/?HOST_INFO` for connection
details. An individual method returns its full description at its OSC address.
Append `?VALUE`, `?TYPE`, `?RANGE`, `?ACCESS`, `?DESCRIPTION`, `?FULL_PATH` or
`?CONTENTS` to fetch one property. The HTTP service accepts only `GET`. A value
request on a write-only node returns 204, and a missing method returns 404.
`ACCESS` describes the separate OSC command endpoint published in `HOST_INFO`.

Connect to `ws://127.0.0.1:9002/` to subscribe to readable methods. Send a text
message with `COMMAND` set to `LISTEN` and `DATA` set to one method address.
`IGNORE` clears that subscription. The first current value and changed values
arrive as binary OSC messages. `PATH_CHANGED` asks clients to reload the
namespace when paths or method metadata change. Subscribers reconnect and send
their `LISTEN` commands again after a disconnect. Supported writes use the
declared OSC UDP endpoint.

Enable local discovery to register `_oscjson._tcp` with macOS DNS-SD. The service
resolves to `localhost.`. Registration uses `kDNSServiceInterfaceIndexLocalOnly`,
so it appears in discovery to other apps running on this Mac. You can use the
HTTP URL directly when discovery is off or unavailable.

## Scope and bounds

The listener binds IPv4 `127.0.0.1` and accepts that peer address. HTTP checks
`Host` against the loopback aliases and the actual port. Browser origins, when
present, must use a matching local HTTP host and port. Responses contain JSON
and disable caching. One listener owns the bound loopback endpoint. Socket address
reuse allows the same service to restart while closed connections finish their
TCP teardown.

Each session has up to 16 TCP peers, including up to eight WebSocket peers.
A WebSocket can subscribe to up to 32 methods. The server accepts an 8 KiB HTTP
header and a 4 KiB WebSocket message, with up to 16 fragments per message.
Admission and WebSocket frames use separate token buckets with 32 tokens per
second and a 32-token burst. The serial server polls at 20 Hz, stages one
bounded output write per connection, and coalesces values to their latest
snapshot when a client is slow. The response limit is 1 MiB for HTTP and the
update batch limit is 128 KiB. HTTP and pending output writes expire after about
five seconds. An idle WebSocket gets a ping about every 30 seconds and closes
after 90 seconds without client frames.

The portable tree accepts up to 2,048 methods, an 8,192-branch budget and 12
path segments per method. Published methods use up to eight arguments with
types `i`, `f`, `s`, `T`, `F` and `b`. An OSC blob appears as JSON `null` and
uses the native binary OSC representation on a WebSocket. Read-only and
write-only methods carry declared access. Full OSC Query optional extensions,
LAN discovery, encrypted WebSockets and physical control applications have
separate scope.

Schema, command and discovery behavior follow the
[OSCQuery Proposal](https://github.com/Vidvox/OSCQueryProposal).
WebSocket framing follows [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455).
Local discovery uses
[Apple DNS-SD LocalOnly semantics](https://developer.apple.com/documentation/dnssd/kdnsserviceinterfaceindexlocalonly).
