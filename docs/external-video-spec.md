# External video inbox

**Devices → External video…** starts one private same-user inbox and displays
its temporary path. The application discovers local feed filenames, and the
operator assigns an explicit feed to a surface. Project schema 17 stores the
feed name and its media ID. Save/Open and Collect preserve that reference.
Opening a project, starting a new project, or quitting stops the inbox.
A saved feed displays black until an operator starts an inbox and a selected
producer publishes fresh frames.

## Local producer

Write one atomic replacement of `NAME.acframe` into the active inbox per frame.
Names contain 1–48 ASCII letters, digits, hyphens or underscores. A single
project can bind four distinct names. The viewer polls at up to 30 Hz and
retains only one immutable accepted texture per feed. The received image is
packed top-left SDR BGRA8, with no alpha conversion, audio, timecode or external
network framing. Frames exceeding 1280×720 are discarded. The texture is
retained by consuming GPU commands through the usual MediaPool path.

The frame record is exactly 40 bytes of header followed by `w × h × 4` bytes.

| Offset | Bytes | Field |
|---|---:|---|
| 0 | 8 | ASCII `ACFRAME1` |
| 8 | 16 | Producer UUID in network byte order |
| 24 | 8 | Nonzero, monotonically increasing frame sequence, big endian |
| 32 | 4 | Width, big endian unsigned |
| 36 | 4 | Height, big endian unsigned |
| 40 | varies | Packed BGRA rows, no file padding |

Each producer picks a fresh UUID when it starts. Repeated or backward frames
do not extend freshness. Admission checks file type, owner, size, stable stat
identity and a recent modification time. After one second without an accepted
frame, the assigned surface goes black. An active owner cannot be replaced by
a competing producer with the same name. After loss a replacement can recover.

With the extracted app and original **ExternalVideo.aperturecue.json**, start
the inbox and copy the path from the panel. From the extracted folder:

```sh
./ApertureCue.app/Contents/MacOS/ApertureCue --publish-demo-feed '/path/from/the/inbox' demo-feed 30
```

This publishes an original animated 96×64 image at about 20 Hz for 30 seconds.
The left surface shows the feed. The comparison gradient is procedural.

## Optional Syphon helper

The application ships with no Syphon binary or vendor SDK. Build the optional
source helper against an independently obtained official arm64 framework.
It selects one server by exact name and optional application name. Ambiguous
matches are rejected. It copies an SDR BGRA8/BGRA8-sRGB texture through a Metal
readback into the inbox. This path uses CPU copies and retains one latest frame.
The receiver checks for disappeared producers and rediscovers the same name.

```sh
./optional/syphon/build.sh '/path/to/Syphon.framework' /tmp/aperturecue-helpers
/tmp/aperturecue-helpers/aperturecue-syphon list
/tmp/aperturecue-helpers/aperturecue-syphon receive '/path/from/the/inbox' demo-feed 'Exact server name'
```

The official project provides the API and licensing material. The separately
compiled original test publisher uses the upstream OpenGL server to send the
same generated SDR pattern across processes. It runs without a separate
Metal shader compiler when the upstream frame-sharing library is built for
that test with its Metal server shader excluded. General Syphon servers,
orientation behavior at third-party sources, zero-copy output, rates beyond
the declared limits and third-party GPU interop need separate checks.
[Syphon upstream and license](https://github.com/Syphon/Syphon-Framework)

The inbox protocol is independent of Syphon and is not an implementation of
Spout, NDI or a particular camera SDK. [Stage scope](stage-7-completion.md)
