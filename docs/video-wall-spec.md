# Video-wall tiles

`VideoWall.tiles` returns row-major index/row/column, normalized source crop,
unit output quad and inner-edge blend settings. Rows/columns are 1…16, with at
most 64 tiles. Zero bezel/overlap partitions the source without interior gaps.
Bezel is the complete-source fraction omitted at each inter-screen gap.
Overlap is a tile fraction up to 0.5, mutually exclusive with bezel on that axis.
Tile size is `1/(count-(count-1)*overlap)` and step is `size*(1-overlap)`.
Each interior edge gets the overlap fraction for complementary blending.

Create wall in the native editor retains the selected source's media, material,
effects, color and source crop. It creates routed unit-quad clones and hides the
original in one Undo step. Groups, shape/mesh/warp/masks/feather reset. Each output
starts without a physical display binding; fullscreen assignment remains explicit.
The original source remains in the document, so existing scenes can restore its
visibility. New wall routes do not alter those saved scene snapshots.

Core tests cover unique indexes, coverage, bezel omission, overlap weights,
four-output gain summation, malformed bounds and Codable round trips. Native
integration must independently verify actual routes, history and pixels. No
multi-display/projector hardware claim follows from logical tiles.
