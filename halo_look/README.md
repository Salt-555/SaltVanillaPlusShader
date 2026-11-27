# Halo Look 0.17.12

A Horizon shader pack (shader API 0.2, WGSL) for the Strix Halo APU. No ray tracing: the
shadow is a shadow map, the water mirror is a planar reflection, everything else is
screen-space or analytic. With a LabPBR texture pack (SPBR tested) it decodes the format
fully: vector-F0 metals, sun backlight through translucent foliage, rain-darkened porous
materials, per-texel emission, and optional height relief geometry near the camera.
Written against `docs/shaders.md` and
`docs/api/shaders-reference-0.2.md` in the Horizon tree.

## Stages

| Stage | File | What it does |
|---|---|---|
| `[sky]` | `sky.wgsl` | vanilla's sky plus horizon scatter at a low sun, a deeper zenith, greyer in rain, stars and aurora at night |
| `[vertex]` | `vertex.wgsl` | wind: sways the leaf, plant and vine sprite classes the manifest maps in `[[materials]]` |
| `[material]` | `material.wgsl` | LabPBR normals and specular, coloured block light, and water: a traveling dispersive swell with breathing modulation (hand-unrolled, frame-constant terms read from the wave clock), scrolled ripple maps, the vanilla flow-boil overlay close in, depth absorption, foam, planar mirror, distance-scaled glitter |
| `[shadow]` | manifest | 1024 map over 64 blocks, player-selectable resolution and distance |
| `[reflection]` | manifest | quarter-res planar water mirror: the planar draw is a full second world pass, the pack's one big bill at native 4K |
| `[[before_world]]` | `pre/wave_clock.wgsl` | one dispatch a frame: folds the spectrum's frame-constant sines and time products (22 transcendentals per water pixel) into the `wave_clock` buffer the material stage reads |
| `[[post]]` | `post/shade.wgsl` | half-res sun/moon shadow with a distance fade, tint through water and glass, 6-tap contact shading |
| `[[post]]` | `post/god_rays.wgsl` | quarter-res volumetric march: four jittered shadow-map samples per ray; sun by day, moon (the night caster) by night |
| `[[post]]` | `post/rays_accum.wgsl` | shaft history: reprojects last frame's cell by the engine's camera-motion law, neighbourhood-clamps it, blends ~thirteen frames of four-step samples; runs ahead of the bloom trio so the blur's vertical leg can fold its output |
| `[[post]]` | `post/bloom_bright.wgsl` | quarter-res bright pass, soft knee at white |
| `[[post]]` | `post/bloom_blur.wgsl` | quarter-res 7-tap horizontal blur |
| `[[post]]` | `post/bloom_blur_v.wgsl` | the vertical leg, pair-split so each reads one cache-resident strip; folds rays_hist in per texel so composite pays ONE sample for bloom plus shafts |
| `[[resource]]` | `rays_hist` | the kept history itself: quarter-res rgba16float, held across frames within a view |
| `[[resource]]` | `wave_clock` | the frame-constant wave terms: 29 f32 slots, written by the before-world dispatch, read by `[material] reads` |
| `[[post]]` | `post/composite.wgsl` | shade and the merged bloom+shaft field (one full-res sample), ground fog with a shadow verdict, time-of-day grade, vignette, edge-directed smoothing by `textureLoad` |
| `[[tonemap]]` | `tonemap.wgsl` | the ACES filmic fit, last |
| shared | `common.wgsl` | luma, Fresnel, specular, normal mapping, world reconstruction, sky gradient, integer value noise, the spectrum tables, the shaft lobe constants |
| `[[textures]]` | `textures/ripple_a.png`, `ripple_b.png` | tileable capillary normal maps (generated band-limited, seamless by construction) |

## Water

The swell is a sampled directional spectrum: seven trains of a bearing fan heaped around a
LIVE wind heading (noise-steered, applied to the whole fan at once — turning a spectrum is
honest, stretching one live wave is not). Wavelengths ride a geometric cascade from a
~26-block swell to ~5-block chop; a Stokes second harmonic sharpens crests and flattens
troughs; per-train life envelopes fade trains out and back in independently.

The trains travel, on deep-water dispersion: phase advances as
`k*(u*cx+v*cy) - t*omega[i]` with `omega = sqrt(1.74*k)` — the same physical table vanilla's
own water animation approximates, so long swells walk at ~2.7 blocks/s and the short chop at
~1.2, along one noise-steered wind bearing. Pure travel alone read as a conveyor, and pure
standing-wave sway (tried at 0.14) read as dead water, so each train's travel rate is
modulated by up to ±42% of its own travel rate (the seven trains sit at 11, 14, 18,
24, 25, 30 and 42 per cent) by its own
pairwise-irrational breathing period (~36-65 s): the sea surges
and eases and never stalls in lockstep. Fine chop is two isotropic tileable normal maps,
orbital sway plus a slow net drift along the wind, patch-mixed, shore-weighted (wind chop
is born in the shallows: full energy in the first blocks of depth, 30% in open deep water),
and faded out by distance because pack textures carry no mip chain. Close in, the boil:
`block_texture(input.uv)` — the engine's own query returns the water block's current
animation frame, cycled at tick rate, on UVs the fluid mesher has already rotated by the
block's flow vector. Direction and speed are the sim's, not ours; four hand-rolled
substitutes got them wrong before we asked. The pattern multiplies onto the composited
water pixel at up to the slider's value (60% at the default) inside ten blocks, gone by thirty — the fade also
keeps a 32-pixel feature out of the shimmer band — and its weight rides divided by the
surface alpha, so the cap means that fraction on screen even on thin cascade sheets. The
detail slope drives the normal, the mirror, and — the cue that makes near water read wet —
the refraction of the bed; below a 0.55% tilt the ripple layer ramps to zero and its two un-mipped fetches, patch-mix noise and
rotations are skipped whole. Every frame-constant term of the spectrum (life envelope, travel angle, breathing sway, ripple
drift) arrives precomputed from the `[[before_world]]` wave clock — one dispatch a frame instead of twenty-two transcendentals
per water pixel.

And the water asks the sun: glitter, sparkle, crest transmission and the foam's
white ride one shadow-map compare — the composite pass's own surface law (clamped
uv, past-the-edge fade toward true shadow), the shade pass's sunrise ramp, up
offsets at terrain parity so the dark edge stays welded to the rock that casts
it, and the same optional softness taps, so the water terminator softens when
the terrain's does. Offsets along the light stay seam-sized rather than
acne-sized: water casts into the map's translucent copy and can't shadow itself.
The verdict splits the way the light does — the specular terms fall to a 0.12
floor (a cliff's penumbra at water is razor-thin) while the foam falls to a
diffuse 0.45 — so glitter dies clean in a cliff's cast while the foam only
dulls, and canopy patches drift light across a pond. The mirror and the deep
body stay out of it: reflected sky visibility is not sun visibility, and
ambient is the lightmap's business.

Domain warp on the sample position, a calm/rough group envelope, and the foam mask are all
noise. **No periodic intensity term survives anywhere in the pack**: a single plane wave
used as a mask is parallel bands, which is what earlier versions showed.

Value noise uses an integer lattice and a u32 bit-mixing hash, exact at any world
coordinate. The `fract(sin(x)*43758.5453)` family is not: at a few hundred blocks out its
argument reaches a few thousand radians, f32 spacing there is ~2.4e-4, and the multiply
turns that into ~9 whole units, so the pattern re-rolls on every camera move. The engine
snaps the terrain origin to 1/65536 block while `frame.camera_position` keeps the exact
camera, which guarantees such a move.

Water depth comes from `opaque_depth`, reconstructed through the frame matrices, and drives
Beer-Lambert absorption (red first, so deep water goes blue-green), depth-scaled
refraction, shoreline alpha fade, foam on shallow bottoms, wave amplitude die-off in the
shallows, and the chop weighting above. The long trains read depth as PHASE: equal depth =
equal phase slides crests along the shoreline, the cheap form of wave refraction.

## Options

Options > Video Settings > Shaders > Shader Packs > Halo Look. A main page plus four
sub-pages, listing all 35 options as the menu actually files them:

**Light and shadow** (9): `shadows`, `shadow_resolution`, `shadow_distance`,
`shadow_softness`, `contact_ao`, `god_rays`, `moon_shafts`, `specular`, `ore_glow`.
**Colour** (12): `bloom`, `saturation`, `warmth`, `clarity`, `vignette`, `film_grain`,
`edge_smooth`, `sky_haze`, `stars`, `aurora`, `moon_halo`, `night_grade`.
**Wind** (4): `wave_strength`, `storm`, `ground_fog`, `fog_line`.
**Water and lamps** (10): `reflections`, `water_waves`, `wave_bend`,
`reflection_distort`, `refraction`, `water_murk`, `water_foam`, `sparkle`,
`vanilla_flow`, `colored_light`.

The two that cost the most are **Water mirror** (a second world draw at quarter resolution
every frame, even with no water in view) and **Shadow resolution** (terrain in the light's
square is drawn again each frame).

## Trade-offs, from their docs

- Any pack's post chain replaces Horizon's resolve: TAA, FXAA, upscaling and FSR frame
  generation do not run, and the camera is never jittered, so temporal AA is impossible
  here. The composite does its own edge-directed smoothing instead.
- `[shadow]` frames take the CPU culling path, and translucent batching reverts while the
  pack runs. Picking the pack at startup avoids a world remesh.
- Specular on solid terrain needs a normal map. A block face has a flat normal, so a
  highlight is near-constant across it and paints the whole face pale. That is what the
  removed rain sheen did, at +29% luma over 82% of pixels. Water keeps its glint because
  the wave field varies the normal per fragment.
- Coloured block light is a hue shift on the block-lit part, not a separate light source.
- Pack textures upload with no mip chain, so anything sampled from one (the ripple maps)
  must fade to zero with distance itself, or it will shimmer.

## Lessons recorded in the code

- Merging bloom bright and blur into one pass measured 0.217 ms against 0.133 ms for the
  pair: the tap blur reads a small cache-resident target, while each merged tap re-reads
  the full-size `scene_color` with bilinear filtering. Fewer passes is not fewer fetches.
- A pack `output` target's name collides with an `override` of the same name; the prelude
  declares the target.
- Shared code in `common.wgsl` is compiled into EVERY stage's module, so it may only use
  bindings every stage's prelude declares — the shadow verdict blocks are near-duplicates
  in `god_rays` and `composite` by necessity, cross-noted at both sites (sky, vertex,
  weather and tonemap preludes carry no shadow bindings; material's does).
- Light bleed needs the shadow verdict on the FULL amplitude: an unoccluded floor under a
  glow (the old `0.15 + 0.85 * beam`) draws a haze through cliffs.
- A hand-placed wave list at evenly-spaced bearings and wavelengths is a lattice generator;
  so are round-number angles. Bearings and periods stay irrational relatives.
- Point-indexed rain rings on block-world water never survive contact with shorelines or
  distance (clean-cut corners where a ring crosses the water silhouette; saucers at range).
  The whole feature was cut at 0.15.6; the boil overlay carries the rain-adjacent life instead.
- Screen derivatives of a branch-guarded texture fetch can compute on divergent quads, and
  there the result is undefined. The boil's guard sits at weight 0.003, not 0, so its
  boundary ring can hold garbage gradients — bounded small by the clamp and the weight
  (< 5e-4 slope, unmeasurable) but not zero. If that fetch is ever restructured, hoist the
  derivative calls out of the guard and keep only the fetch itself guarded.

## Build, check, install

    horizon-shader check .
    horizon-shader pack .          # writes halo_look-0.17.12.hshader

Copy the folder or the `.hshader` into `shaderpacks/` beside `options.txt`.
`HORIZON_SHADER_PACK=halo_look` forces it for development. A saved pack is re-checked twice a
second, so edits hot-reload; the client's chat says "Shader pack Halo Look reloaded".

## Measuring

    horizon-ctl gpu-passes on
    horizon-ctl bench 6            # SECONDS, not frames; replies shader_passes beside gpu_passes

Clear the throttles first or the numbers are a limiter, not the engine:
`options-set inactivityFpsLimit minimized`, `pauseOnLostFocus false`, `enableVsync false`.
`[budget] gpu_ms = 0.8` is the declared target.

MIT for the pack code. No Mojang assets ship inside: the boil queries the engine's
own atlas through the shader API.
