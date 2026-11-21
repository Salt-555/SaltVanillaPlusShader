# Salt's Vanilla Plus Shader (SVPS)

A hand-written WGSL shader pack for the Rust [Horizon](https://github.com/horizon-rust/horizon)
client's shader API (`api = "0.2"`). Vanilla look, plus: sun shadows from a real shadow
map, spectral water with physical dispersion, absorption, foam and a planar mirror,
temporal sun and moon shafts, coloured block light, wind, aurora, and an ACES filmic
curve. No ray tracing anywhere.

The pack's own [technical documentation](halo_look/README.md) covers every stage, the
water model, the honest trade-offs of the post chain, and the lessons encoded in the
comments. Read it before changing anything.

## Requirements

A Horizon client with shader API 0.2 (the [documentation](https://github.com/horizon-rust/horizon)
lives at `docs/shaders.md` and `docs/api/shaders-reference-0.2.md` in the tree). This is
not an Iris or OptiFine pack and never will be; the API, the manifest, and the pass
contract are Horizon's own.

## Install

Copy the `halo_look/` folder into `shaderpacks/` beside your `options.txt` (the shaders
menu has an "Open Pack Folder" button), then pick **Halo Look** under
Options > Video Settings > Shaders. `halo_look` is the pack's internal id: your slider
values save to `shaderpacks/halo_look.txt`. `HORIZON_SHADER_PACK=halo_look` forces it
from the environment for development. Saved packs hot-reload twice a second.

## Performance

Tuned on a Strix Halo APU (integrated graphics) at 4K, so the common path is deliberately
cheap: half- and quarter-res passes, zero full-frame extras, one declared GPU budget of
0.8 ms. The two options that cost real money are the **water mirror** (a second world
draw every frame at quarter resolution, water in view or not) and **shadow resolution**
(terrain redrawn into the light's square each frame). Both are per-option toggles; the
option descriptions carry the measured costs.

## What does not ship here

No Mojang assets of any kind. The water's flow-boil overlay, for example, queries the
engine's own atlas through the shader API rather than bundling a texture.

## License

MIT. Shader code by Artemis, for Salt.
