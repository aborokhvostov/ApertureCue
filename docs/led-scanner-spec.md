# LED scan capture import

In ApertureCue, choose **Light → Import LED scan… → Save example…** to create an original three-slot capture. Open the same command, select **Import capture…**, choose the saved JSON, and enter a fixture name, universe, start address, and color order. **Add fixture** adds the decoded points in DMX slot order to the current project. Open **Light → Fixture patch…** to inspect or edit the resulting patch. Import participates in project Undo and Redo.

## Capture format

A version 1 `.acledscan.json` has integer fields `version`, `width`, and `height`, and a `frames` array. Each array element has an integer `slot` and three base64 strings `darkBefore`, `flash`, and `darkAfter`. Each string decodes to exactly `width × height` unsigned 8-bit luma samples. Store rows from top to bottom and pixels in each row from left to right. Files use contiguous, unique one-based slots. The array can be in any order. Each triplet has the same projection-space image bounds, and the source should keep its view fixed across the capture.

For a slot, supply an unlit frame immediately before its flash, a frame of just that slot lit, then an unlit frame. The decoder derives the background from both dark frames and removes a global exposure offset with the residual median. It detects connected bright regions using a median absolute deviation threshold, ignores isolated hot pixels, and returns the strength-weighted center of the dominant region as a normalized top-left coordinate. Competing highlights, no signal, and positions repeated across slots stay unresolved.

The format accepts 8–1,024 samples per axis, at most 262,144 pixels per raster, 1–170 slots, at most 32 MiB of raster bytes, and a 44 MiB file. An RGB or GRB pixel occupies three channels. RGBW occupies four channels. The full fixture must fit within one 512-channel universe and respect existing fixture patch overlap checks.

**Add fixture with gaps** explicitly keeps unresolved addresses reserved and emits zeros at those slots. Resolved LEDs keep their original slot order and addresses. Captures with zero resolved slots cannot be patched.

## Verification scope

Stage 6 uses original synthetic flashes with ambient drift, ambiguous reflections, missing signal, repeated positions, and independent expected patch bytes. Capture timing, real camera and projector calibration, fixture response, and registration under venue conditions require Stage 8 hardware verification.
