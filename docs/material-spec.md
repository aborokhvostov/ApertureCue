# Materials and surface FX

This is an independently implemented, bounded material language and an explicit
ISF 2 expression subset. It does not execute arbitrary GLSL/Metal source or
provide a full ISF library. The base build uses Foundation and the existing
system Metal backend; it downloads no material SDK or third-party shader assets.

## Document model and editor

`MaterialDefinition` contains a UUID, display name, one RGBA expression, ordered
`MaterialInput` definitions and attribution text. Project integration owns the
shared definition list; each surface assigns a definition ID and parameter value
overrides. Definitions remain shared outside scene snapshots. Material and FX
field masks must be captured separately from source/geometry when used in cues.

The Materials panel offers New/existing selection, a multiline expression,
editable inputs JSON and selected-surface values JSON, import, Save + Assign,
Delete and Clear selected material. Each input JSON object contains `name`,
`label`, `kind`, `defaultValue`, `minimum` and `maximum`. Kinds are `float`,
`bool`, `point2D` and `color`, with respectively 1, 1, 2 and 4 components.
Boolean values use numeric 0/1 in this native parameter representation. Defaults
and ranges must have the declared component count, finite values within ±1e6,
and ordered min ≤ default ≤ max. A missing ISF default starts from zero (one for
color) clamped into the declared range. Up to 16 inputs are accepted. Names are unique
ASCII identifiers (max 64 bytes) and cannot shadow language built-ins.

Selected values use an object such as `{"amount":[0.25],"tint":[1,0.5,0.2,1]}`.
An empty object uses defaults. Unknown names, wrong component counts and
out-of-range/nonfinite overrides fail. Saving a changed definition validates
all current and scene assignments against its new interface; it does not
silently clamp or discard their overrides. Deletion clears current and stored
surface references in one history command. Clearing one assignment leaves the
library and other surfaces intact.

The adapter validates the full candidate project and preflights every Metal
blend variant before committing a material edit. A failed edit retains the
accepted document and compiled material. Modal saves pin document generation,
selection and library contents, so a late modal result cannot modify a replacement
document or newly selected surface. Explicit user imports read only the chosen
UTF-8 `.fs` file; source includes and imported image paths are never followed.
The native UI and GPU integration require their own production verification;
core parser tests alone do not establish those gates.

## Native expression language

A material consists of one expression producing `vec4` straight RGBA. Inputs
are scalar/vector numeric values; a scalar broadcasts to a vector under
arithmetic. Supported operators: unary `+`/`-`, binary `+ - * /`, parentheses and
swizzles `xyzw` or `rgba` (one alphabet per swizzle, within the operand width).
Constructors `vec2`, `vec3`, `vec4` concatenate exactly the requested component
count, or broadcast one scalar.

Built-ins:

- `uv`: final normalized source coordinates with the application's y-down origin.
- `time`: explicit render time in seconds; the caller owns the show clock.
- `size`: positive render target dimensions.
- `pi`: the numeric constant.
- `sample(vec2)`: the surface's source lookup using normalized y-down coordinates.
- `sin cos abs floor ceil fract sqrt length`, `min max pow mod step dot`, and
  `clamp mix smoothstep`, with validated argument counts and vector sizes.

Example: `mix(sample(uv), vec4(uv, 0.5+0.5*sin(time), 1), amount)`.
`mod` follows floor-based GLSL semantics, including negative operands. `mix` is
linear interpolation; `smoothstep` uses the cubic Hermite polynomial. Domain
errors such as division by zero or a negative square root are rejected by the
CPU evaluator; the backend must discard/blacken nonfinite output, rather than
publish invalid texture values. The material compiler handles syntax/type errors
before replacing an accepted shader. It does not infer a hardware throughput or
GPU-timeout guarantee from successful compilation.

Budgets: 4096 expression bytes, 512 lexical tokens, 256 AST nodes, nesting depth
32, at most 16 syntactic texture samples and 32768 generated MSL bytes. Loops,
assignments, statements, arrays, functions supplied by the user, pointers,
preprocessor directives and includes are rejected. Generated code uses only
compiler-owned function names and numbered uniforms, never raw user identifiers.
Texture-coordinate conversion calls a helper once so nested samples are not
duplicated by string expansion. Comments are accepted but cannot bypass budgets.

Backend interface: `MaterialProgram.metalExpression` uses `materialUV` (float2),
`materialTime` (float), `materialSize` (float2), `materialParams` (16 float4 rows),
`sampleMaterial(float2)` and `sampleMaterialISF(float2)`. The ISF helper flips y
once before calling the native sampler. Append `MaterialProgram.metalFunctions`
for overloaded floor-mod helpers. `parameterVectors(values:)` produces 16 padded
rows; `evaluate(uv:time:renderSize:values:sample:)` is the deterministic CPU oracle.

## Supported ISF 2 subset

The importer follows the ISF requirement for a leading JSON comment and typed
`INPUTS`, and accepts specification strings `2`, `2.0` or `2.0.0`. It accepts
float/bool/point2D/color parameters and at most one image input bound to the
surface source. The fragment body must be one `gl_FragColor = expression;` inside
`void main()` or `void main(void)`. The supported expression functions above are
available with standard GLSL names. Local variable declarations, control flow,
custom functions, vertex shaders, audio/event/long inputs, external `IMPORTED`
images and multipass/persistent/custom-sized targets are rejected. `PASSES` may
be absent, empty, or contain one empty pass object.

ISF `isf_FragNormCoord` has a bottom-left origin, unlike native `uv`; the importer
preserves that orientation. `TIME`, `RENDERSIZE`, `IMG_NORM_PIXEL(image, vec2)` and
`IMG_NORM_THIS_PIXEL(image)` are supported. Normalized source reads convert back
to the native y-down sampler. Native aliases (`uv`, `time`, `size`, `pi`, `sample`)
are rejected in imported ISF rather than silently accepting an invalid GLSL
program. Additional ISF variables/functions and non-normalized image reads are
outside this declared subset.

Primary references: [ISF JSON attributes](https://docs.isf.video/ref_json),
[ISF standard variables](https://docs.isf.video/ref_variables.html), and
[ISF image/math functions](https://docs.isf.video/ref_functions).
`examples/Materials/OriginalGradient.fs` and `OriginalTint.fs` are independently
authored GPL-3.0-or-later examples. Imported attribution is retained as text;
importing a user file does not authorize distributing it or establish its license.

## Surface FX

`EffectsSettings` provides none/chroma/luma keying, RGB key color, threshold,
softness and dominant-channel spill suppression, plus saturation (0…2), RGB
inversion and posterization (0 disables, otherwise 2…256 levels). Normalized
straight RGBA is processed before the existing surface color/brightness/gamma
and premultiplication. Defaults preserve normalized input.

Chroma metric is Euclidean RGB distance divided by sqrt(3). Luma metric uses
encoded-RGB weights 0.2126/0.7152/0.0722. It is not a scene-linear or color-managed
key. The retained alpha is `smoothstep(threshold, threshold+softness, metric)`;
zero softness uses the strict comparison `metric > threshold` without division.
Chroma spill suppresses the key's first-largest RGB channel toward the maximum
of the other two channels. Saturation mixes Rec.709 gray with RGB, clamps to
0…1, then optionally inverts and rounds to the declared posterization levels.
Texture alpha is multiplied by key alpha and preserved by the color-only effects.

`Effects.evaluate` is the CPU oracle. `Effects.metalFunction` exports
`apertureEffects(source,keyColor,keyStyle,effectStyle)`: `keyStyle` packs mode
(0 none/1 chroma/2 luma), threshold, softness and spill; `effectStyle` packs
saturation, inversion (0/1), posterize count and an unused value. Appearance FX
remain editable under a geometry lock, matching existing surface color controls.
