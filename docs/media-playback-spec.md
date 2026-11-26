# Ordinary-source playback and folder frames

Schema 13 adds optional playback, sequence and audioRouting to media assets.
Schemas 0…12 ignore undefined extensions before decoding their values. Audio
and sequence kinds require schema 13. Shared media settings are outside the
surface-only scene snapshots; selection/cues do not silently reset source clocks.

## Source clocks and frame requests

Nil playback preserves the legacy loop flag. A source initially follows the
master. Its Play/Pause/Seek switches to an independent host-clock transport;
master operations then affect followers only. Follow master explicitly rejoins.
Transport is session state; trim/mode/speed/seed/FPS/routing are saved settings.
Use Sources in the Media library to assign an asset and edit its settings.
Still images and camera have no file transport. Elapsed seconds are distinct
from mapped item time. Seek zero explicitly restarts a Once source.

Trim is a half-open [In,Out) source interval, clipped to the actual duration.
Empty Out means duration; non-overlapping actual trims diagnose after metadata.
Signed speed is -8…8; zero freezes the initial frame. Once stops at the last
covering sample; Loop wraps; Hold freezes the start (the final sample for a
negative speed); PingPong reflects; Random uses saved counter-based SplitMix64
seed/interval and frame quantization, independent of seek/call order. Reversal
uses actual AVAssetReader PTS intervals, including VFR, rather than assuming
AVPlayer supports negative rate. Unsupported codecs fail visibly.

Decoded samples follow the framework's [presentation-order reader contract](https://developer.apple.com/documentation/avfoundation/avassetreaderoutput/copynextsamplebuffer%28%29?language=objc).

Ordinary legacy AVPlayer sources have a maximum of eight admitted players;
managed modes have eight shared reader slots. Assigned sources have admission priority; inactive entries can retain bounded
muted paused preview players, and assignment changes retire inactive players; video demand separately retires hidden managed readers without changing
hidden-layer legacy audio semantics. Effective automation/group visibility is
used, including Input preview. Each managed slot has one worker and one pending
coalesced request. Explicit seek/relink/document generations invalidate old work;
no old seek texture remains eligible. Reader cancellation stays on its serial
owner queue. Images retain at most three sequence entries per source, sharing
a 64 MiB payload budget including GPU frame owners. File/header/dimension limits
are checked before decode (128 MiB file, 8192 per axis, 16 megapixels, 8-bit RGBA).
Driver allocations, transient framework memory and total RSS are separate.

Paused/explicit requests accept the covering PTS interval exactly. Continuous
forward/backward managed playback may hold its last completed sample for at
most 120 ms of source time scaled by speed; otherwise fallback is shown. A late reverse frame is restricted to its known
contiguous PTS run and cannot bridge an explicit gap.
This is bounded late-frame behavior, not frame lock or a refresh guarantee.
Legacy follower players correct clock error beyond 120 ms; accepted PTS,
missing pulls and correction counts are measured separately in the soak report.
The declared local codec fixtures are original H.264 MOV and PNG sequences;
other OS codecs are availability-dependent.

## Frozen image sequences

Import Image Sequence selects one local folder. Discovery runs off main and
admits regular supported PNG/JPEG/TIFF/BMP leaf files without symlinks. A frozen
manifest contains 1…10000 unique safe basenames; FPS is 1/240…240. Numeric ASCII
runs sort by value then padding, with bytewise case tie-breaking; no locale or
filesystem enumeration order determines playback. Gaps play consecutively.
Added files join only on Refresh sequence manifest. A missing/corrupt frame
shows fallback and a diagnostic; it never substitutes another frame. Corrupt/missing
frames are memoized until Refresh/relink; transient occupied-budget failures
retry with backoff after payload leases are released. Repeated requests coalesce
while loading. Unused static bin images load only on demand and idle static
textures are retired. Changing folder path retains the frozen names until explicit refresh.
Collect copies exactly the manifest, including its order/FPS/playback settings.

## Audio, recovery and acceptance

[Audio](audio-playback-spec.md) defines PCM matrices and the separate silent
reverse/random/hold policy. [Durability](durability-spec.md) defines bound
recovery and atomic collection. Camera simulator tests use the same production
entry adapter: disconnect clears capture/latest frame while outstanding GPU
owners remain alive; late old-session errors cannot clear a replacement.
Simulator results do not verify a physical camera.

[Stage 3 ledger](stage-3-completion.md) distinguishes implementation, automatic
checks, native manual observations and physical H gates. The two-minute video
soak is a bounded local workload, not show-length stability or AV hardware sync.
