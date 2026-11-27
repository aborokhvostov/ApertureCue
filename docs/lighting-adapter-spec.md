# Lighting adapter preview and buffered USB output

Open **Light → USB-DMX / SPI…** and select a universe from the project's fixture mix. The panel previews current bytes, gives the payload length, and exports the exact bytes to a local `.bin` file. Opening the panel enables software sampling. Serial output starts only from the separate **Start USB output…** action in Buffered USB DMX mode.

## Buffered USB DMX

The sender is for a compatible, buffered DMX-Pro virtual serial endpoint. In **Buffered USB DMX** mode select a universe. In **Start USB output…** enter its exact macOS callout path beginning with `/dev/cu.` and choose **Start USB output**. ApertureCue opens the selected character device, reserves it against subsequent opens, and configures raw 8N1 host serial at nominal 115200 baud. Endpoint discovery, drivers, device identification, and permission configuration are external to ApertureCue.

The 518-byte host frame consists of marker `7E`, label `06`, little-endian payload length `01 02` for 513 bytes, DMX start code `00`, exactly 512 channel bytes, and marker `E7`. The worker offers changed values at up to 30 Hz and coalesces pending samples to the latest frame. The buffered adapter controls the physical DMX refresh. [ENTTEC public DMX USB Pro API](https://cdn.enttec.com/pdf/assets/70304/70304_DMX_USB_PRO_API.pdf)

An absent universe or a source silent for about one second causes a zero frame. Fresh samples can resume output while the session is active. **Stop USB output**, closing the adapter window, starting network replay or pass-through, replacing the project, or quitting attempts a final zero frame before closing the endpoint. Serial writes on the worker have a 120 ms budget. A failure closes the endpoint and requires an explicit new Start. Receipt of the final zero depends on connectivity and device behavior.

## SPI RGB payload

In **SPI RGB payload** mode select the first DMX address and pixel count. The window previews and exports consecutive byte triples from the selected universe, starting at that address. A slice must fit within its 512 slots. The open adapter boundary exposes these RGB bytes to optional downstream integrations. Chip-specific SPI clocks, framing, latch and protocol selection are outside this virtual output.

## Verification scope

Stage 6 checks host frame and payload bytes, path syntax, latest-frame coalescing, stale source blackout, stop, and cleanup on an injected write failure. Tests use an in-memory byte sink. USB adapter compatibility, physical DMX output, and SPI device operation require hardware checks.
