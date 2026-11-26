# Audio playback and routing

Stage 3 adds an optional per-source PCM route without changing the default
ordinary movie's AVPlayer system-audio path. An explicit `audioRouting` definition
owns audio even when disabled, unavailable or rejected; there is no fallback to
a different device. Custom source transport uses the PCM adapter for forward
sound and suppresses AVPlayer audio, avoiding two audible copies of a track.
The project keeps matrix/device settings outside surface-only scene snapshots.

## Implemented path

`MediaAudioPlayer` extracts the first audio track of a local AVFoundation asset
on a serial worker into 48 kHz interleaved Float32. WAV/AIFF and supported audio
tracks in MOV containers use the same reader. The file's channel count must match
an explicit matrix; native routes support 1…8 inputs and 1…8 outputs. The portable
matrix supports up to 32 channels, separately from native device capabilities.
Unsupported or corrupt media produces a source diagnostic rather than sound on
an unrelated output.

The matrix is output-row-major. Signed finite gains in -4…4 accumulate in Double;
each complete row clips once to [-1,1], then the source master fader applies.
Muted/disabled routes are silent. AVAudioMixer gain changes ramp over the next
render quantum; no physical latency is inferred from the offline quantum size.
An automatic forward route uses the actual first track's inputs and the current
system output's channels; mono duplicates into the first two outputs, and a
mono output averages the inputs. Other automatic channels use identity mapping.
Explicit routes preserve their exact coefficients.

The dedicated graph is AVAudioPlayerNode → AVAudioUnitVarispeed → mixer → output.
Forward rates 0.125…8 are supported with pitch changing together with speed.
Pause holds the reported source position. Explicit seek generations flush the
node and varispeed state; callbacks from older generations cannot install PCM.
A >100 ms source-clock mismatch or a changed trim end flushes the queue. Source
trim Out caps scheduled PCM before the next controller tick. Samples are admitted
when their 48 kHz PTS lies strictly before Out; a fractional Out can include the
last sample interval crossing that time by less than one sample frame. Reported
playing/paused position clamps to duration and the requested Out after EOF. A
new seek generation can restart a source after natural EOF. Video/render clocks and audible device clocks are not claimed
to be frame-locked. Reverse, zero-rate holds and random-frame source playback
produce silence with a diagnostic rather than stale forward audio.

## Output identity and bounds

A persisted CoreAudio device UID identifies an explicit output. The matrix output
count must equal that device's current output channel count. Missing output,
engine configuration change or loss of the selected identity stops the source;
reselection is explicit. Automatic system-output routes also stop if the system
default identity changes. Existing ordinary AVPlayer system audio retains its
platform behavior. The application reads device identities and formats; it does
not change the system default device, volume, sample rate, permissions or drivers.
Raw device UIDs/names are not written into verification reports.

An empty CoreAudio device catalog (including restart/headless operation) returns
no available outputs. Device-list byte sizes reject malformed or excessive counts
before allocating or borrowing a buffer; no empty-array base pointer is forced.

At most eight adapters may hold admission leases, including retired asynchronous
preparation and decoder work. A ninth source returns a typed capacity diagnostic;
capacity can be retried when earlier leases actually release. Each adapter allows
one pending decoder request and two queued 12,000-frame PCM buffers. Repeated
seeks coalesce into the latest request instead of growing a worker queue. One
reader packet is limited to 131,072 frames, and a decoder request reads at most
128 packets; exceeding either budget rejects with a source error. Main-thread
cancellation only advances a serial checked between packets. Actual reader reset,
`cancelReading` and `copyNextSampleBuffer` execute on the same worker, honoring
Apple's prohibition on concurrent cancel/copy operations. Main never waits for a
blocked file read; the source lease remains held until that work returns. Local edit-list gaps produce bounded chunks of silence. File I/O, packet
copying, allocation and matrix mixing never run in the engine's audio callback.
These are application PCM/request limits, not measurements of AVFoundation's
internal allocations, CoreAudio buffers or process RSS.

## Verification scope

The native `--audio-test` harness exercises the production reader, matrix,
player, varispeed and mixer through Apple's
[manual offline rendering API](https://developer.apple.com/documentation/avfaudio/avaudioengine).
It never starts a hardware output. Fixtures are original Float32 WAV at 48 kHz
and 44.1 kHz, with independent constant-channel values and tones; a separate
original MOV contains the generated audio track. Numerical checks cover channel
swaps/sums/clipping, post-matrix master volume, pause, seek, rapid generation
replacement, reverse silence, resampling, measured sample-clock drift/rate,
explicit/fractional trim Out, EOF clock bounds and seek-after-EOF, empty/malformed device-catalog byte counts, serialized reader cancellation, and eight-source admission/reuse. A fresh production run is
recorded separately from development harness results.

Offline sample-clock error is not a measurement of audible AV drift, speaker
output, hardware sample-clock stability or device latency. Physical multichannel
wiring, real disconnect/reconnect, device/sample-rate changes, audible media and
long-show audio/video drift remain separate hardware/runtime gates. No audio
montage, pitch-preserving time stretch, DSP effects, clock synchronization or
full reference routing compatibility is implied.

## Production automatic verification — 26 November 2026

The optimized production app built with the installed Swift 6.4.2 toolchain on
Apple M2 / macOS 26.6.2 passed all **15 native offline integration checks**.
This is a native integration harness, not XCTest or hardware audio execution. The run rendered 65,536
frames at 48 kHz (1.365333333 seconds) with zero measured source sample-clock
error; a double-rate interval advanced source time by 0.341333333 seconds.
The trim fixture admitted exactly 2,400 frames for source 0.25…0.30 seconds.
Four output channels matched the independent matrix oracle, including positive
overshoot clipped to 1 followed by master gain 0.5. No hardware audio was started.
The [sanitized report](verification/stage-3/audio-test.json) and
[stage ledger](stage-3-completion.md) record production/archive verification.
