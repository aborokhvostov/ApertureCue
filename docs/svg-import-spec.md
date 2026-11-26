# Bounded SVG import

The independent parser implements a declared geometry subset based on W3C
[SVG paths](https://www.w3.org/TR/SVG2/paths.html) and
[coordinates/transforms](https://www.w3.org/TR/SVG2/coords.html).
UTF-8 XML has one svg root with a positive viewBox or numeric width/height
(unitless/px). Path points normalize the viewBox directly to 0…1; no separate CSS
root viewport is reproduced. Nested g transforms compose in SVG order: matrix,
translate, scale, rotate and skewX/Y. Nested svg viewports reject.

Elements: path, rect without rounded corners, circle, ellipse, line, polyline,
polygon, g, svg, title and desc. Paths accept absolute/relative M/L/H/V/C/Q/Z,
repeated tuples, signs and exponents. Quadratics convert exactly to cubic handles.
Compound subpaths retain a shared SVGShape and evenodd/nonzero fill rule, so holes
can be rendered correctly. Circles/ellipses use four quarter-circle cubics with
relative radial error below 0.00028, checked by an independent dense oracle;
this is a declared approximation, not an arbitrary-scale exact ellipse claim.

Paint: none, basic named colors, #RGB/#RGBA/#RRGGBB/#RRGGBBAA; opacity, fill/stroke
opacity, fill-rule, stroke width/cap/join and miter limit. Element/group opacity
is applied through transparency layers after its descendants/fill+stroke combine,
preserving overlapping alpha. Uniform stroke transforms
are supported; nonuniform/sheared transforms of stroked shapes reject rather
than approximate their width. Filled shapes support these transforms.

Unknown elements/attributes, CSS/style, scripts, external references, DTD/entity
declarations, processing instructions, foreign namespaces, arcs and S/T shorthand
reject atomically. No resource lookup/network access occurs. Budgets: 1 MiB input,
4096 elements, depth 32, 32 attributes, 32 transforms per element, 256 shapes,
32 subpaths/shape, 128 anchors/path and 8192 anchors total. Coordinates and widths
must remain finite and within the normalized working range.

The native adapter rasterizes grouped cubic paths with CoreGraphics in explicit
sRGB, preserving holes, paint and alpha. Default maximum dimension is 1024;
4096 is the hard cap, with a conservative 256 MiB transparency-layer work budget. A new UUID-owned PNG is written in application support,
then imported as an ordinary image in one validated history command. Tests can
provide a separate destination. Undo keeps the owned file for Redo; Collect
copies it like ordinary image media. A failed import never publishes a partial
document and only its own newly created folder is eligible for rollback.
Original example: `examples/SVG/geometry.svg`. GPU/media/native manual verification
must be recorded separately from parser/core checks.
