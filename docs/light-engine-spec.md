# Light engine

## Patch and logical outputs

Open **Light → Fixture patch…** or **LED…**. A patch stores each fixture's
universe, one-based starting address, ordered normalized sample positions, and
channel definition. An output UUID selects the corresponding composition and
its edge blend. **All outputs** samples the combined editor composition. The
engine submits one asynchronous Metal command buffer for up to seven routed
outputs plus the combined output. Each readback is 320×180 BGRA8 before
conversion to RGBA. A busy job drops the new sample request. Live sampling
supports up to 128 patched universes and runs at up to 30 Hz.

Point sampling uses the nearest clamped pixel. A box uses a two-dimensional
average of the pixels whose centers are inside the clipped normalized box. A
subpixel or edge box with no included centers uses the nearest pixel along
that axis. The RGB component precision entering the sampler is eight bits
per texel. Box averages and manual scalar or animated channels can have
finer precision before DMX quantization. The physical response depends on
fixture calibration.

Choose a line or a matrix between normalized positions. Serpentine order
reverses every other row. Zero-based skipped positions keep their full slot
stride and stay zero. A fixture remains within one 512-slot universe and
patches cannot overlap. Schema 16 accepts universes 0…63999. Art-Net output
accepts 0…32767, sACN 1…63999. Stage 5 network arming, synchronization,
rate limiting and retirement still apply. [Transport](lighting-transport-spec.md)

## Defining channels

**Channels…** can start from an RGB, GRB or RGBW preset. Add, edit and reorder
8-bit or 16-bit coarse/fine or fine/coarse values. Supported sources include
RGB, extracted white, CMY, luma, pan, tilt, dimmer, constant and reserved.
A reserved slot encodes zero. A white channel uses the shared RGB minimum;
its RGB companions carry the remaining color. Manual motion, dimmer and
constants use 0…1. Choose a surface and a parameter to use its effective
value after timeline or Conductor, normalized over the parameter's supported
range. The configured fallback applies when that surface is absent. The
editor shows actual byte order and last occupied address. Moving-head mode
definitions and range calibration remain fixture-specific.

## Layout files

**Import CSV / JSON…** validates the file and the merged patch before changing
the project. Failed imports report the first invalid physical CSV row or JSON
array entry. **Export JSON…** saves the same native fixture-array format.
Layout files have a 1 MiB limit. The required CSV header is:

```csv
name,universe,address,channelOrder,x1,y1,x2,y2,rows,columns,serpentine
Sample wall,1,1,RGBW,0.1,0.2,0.9,0.8,3,8,true
```

Optional columns are `skippedPixels`, `outputID`, `sampleWidth` and
`sampleHeight`. Separate zero-based skipped indices with `|`. Both box
dimensions must be present together. An output UUID in a layout must exist in
the destination project. **Add SVG positions…** reads the bounds-center of
each visible supported shape in document order through the existing bounded
SVG parser. Use small original markers for the expected sample positions.

## DMX monitor and routing

**Light → DMX monitor…** enables simulation and exposes slot levels, current
universe and the selected slot in decimal and hexadecimal. Incoming UDP is a
separate explicit receiver on `127.0.0.1`, one selected universe and a diagnostic
port other than the Art-Net and sACN output ports. The receiver validates packet
structure, sequence and source identity and reports packet admission counts.
The sACN receive subset covers unsynchronized non-preview data and termination;
its send path still supports synchronization. There is no packet mixing.

**Route to armed output** temporarily selects the incoming universe as the
source for the previously armed Art-Net/sACN sender. The input and standard
output ports are disjoint. After one second without fresh input the route
retires the universe with normal zero/termination behavior. It can accept new
data while armed. Ending the route or closing the monitor stops its output.
A timed-out composition sample also retires stale levels. Blackout zeros all
slots, including motion. Confirm the expected slot behavior in simulation
before selecting a fixture-specific physical mode.

[DMX recording and replay](dmx-sequence-spec.md) · [LED capture import](led-scanner-spec.md) · [Optional USB-DMX and SPI](lighting-adapter-spec.md)
