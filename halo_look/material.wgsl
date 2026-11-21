// Each point of a block's surface: vanilla's light, then LabPBR normals and specular,
// coloured block light, and water that mirrors the world about its plane.
// `shaded_tint` is the free path: it carries vanilla's tint, shade and ambient occlusion
// without turning on terrain look storage (no world reload, no extra terrain memory).
override specular: f32 = 0.8;
override reflections: bool = true;
override water_waves: f32 = 1.0;
override wave_bend: f32 = 4.0;
override colored_light: f32 = 0.85;
override water_murk: f32 = 1.0;
override water_foam: f32 = 0.6;
override refraction: f32 = 1.0;
override reflection_distort: f32 = 1.0;
override sparkle: f32 = 1.0;
override vanilla_flow: f32 = 0.6;
// the water's sun verdict rides the same toggle as the post shadow pass
// (same pipeline constant, same name): one shadows switch for all sun-cast dark.
override shadows: bool = true;
// and the same softness dial: raise it and water's terminator softens WITH the
// terrain's, on the same taps — one switch for one perceptual property.
override shadow_softness: f32 = 0.0;
override ore_glow: f32 = 0.5;

fn material(input: MaterialInput) -> Surface {
    // Fully transparent texels - leaf gaps, the empty corners of cross quads - are invisible
    // in every blend mode and alpha-tested away anyway. Returning before anything else spares
    // the whole pipeline (maps, light, water) on the largest category of shaded-and-discarded
    // pixels the canopy-heavy frames pay for. Bit-identical output; less work.
    if input.albedo.a == 0.0 {
        return Surface(vec4<f32>(0.0));
    }
    let n_geo = normalize(input.normal);
    let pbr = block_pbr_maps();
    var n = n_geo;
    var smoothness = 0.0;
    var emission_map = 0.0;
    if pbr {
        // both reads inside the branch: with no LabPBR pack installed they cost nothing
        let spec_map = block_specular_map(input.uv);
        n = mapped_normal(n_geo, input.tangent, block_normal_map(input.uv));
        smoothness = spec_map.r;
        emission_map = spec_map.a;
    }

    // vanilla's lit colour, in linear light
    let base = input.albedo.rgb * input.shaded_tint.rgb;
    var color = base * input.lightmap;

    // coloured block light: shift the hue of the block-lit part, keep its brightness
    // the light grid is a trilinear 3D sample, eight fetches: skip it where no block
    // light reaches, which is most of a daylit surface. The engine's colour grid is
    // a 128-block cube around the camera that samples 0 outside, and its edge sits
    // anywhere from 48 to 64 blocks out, snapping 16 blocks whenever the cube
    // recentres — so the hue is faded in over the last stretch before 48, the
    // closest that edge ever gets. Then it fades with distance instead of switching
    // on at the cube's wall, however the cube moves.
    let gf = min(min(1.0 - smoothstep(40.0, 48.0, abs(input.position.x)),
                     1.0 - smoothstep(40.0, 48.0, abs(input.position.y))),
                 1.0 - smoothstep(40.0, 48.0, abs(input.position.z)));
    if colored_light > 0.0 && input.light.x > 0.01 && gf > 0.0 {
        let cl = block_light_color(input.position);
        // cl.a is the engine's own proximity term: (1 - d/level)^2 summed over
        // the lights that reach here — continuous in distance. sqrt brings it
        // back to a linear falloff. The hue rode on input.light.x alone, which
        // is the light engine's integer level dropping one full 1/15 rung per
        // block: that is the step. Riding the proximity curve instead lets the
        // torch's colour fade in while you walk to the flame; light.x stays as
        // the gate that the surface is block-lit at all.
        let near = sqrt(min(cl.a, 1.0));
        let tint = mix(vec3<f32>(1.0), cl.rgb, near * colored_light);
        color += base * near * gf * (tint - vec3<f32>(1.0));
    }
    // the engine's carried block lights — held and dropped items, and any
    // [[particle_lights]] or mod lights upstream — ride in as a hue shift
    if any(input.colored_light > vec3<f32>(0.0)) {
        color = mix(color, color * (vec3<f32>(1.0) + input.colored_light), 0.5);
    }

    // the sun's or moon's highlight where the sky reaches the surface
    let view = normalize(-input.position);
    let light_dir = frame.light_direction;
    if specular > 0.0 && light_dir.y > 0.0 {
        // Specular only where a normal map gives variation inside a face: a block face
        // has a flat normal, so a highlight is near-constant across it and paints the
        // whole face pale. Water keeps its glint because the wave field varies the
        // normal per fragment.
        // LabPBR smoothness, only where a resource pack actually ships maps
        if smoothness > 0.02 {
            let sun_tint = mix(vec3<f32>(1.0), frame.sky_color * 2.0, 0.35);
            let glint = shine(n, light_dir, view, smoothness) * input.light.y * specular;
            color += vec3<f32>(glint * 0.5) * sun_tint;
        }
    }

    // LabPBR's per-texel emission: glowing ore, a lamp's filament
    if emission_map > 0.0 {
        color += base * emission_map * 0.5;
    }

    // Ore glow: the manifest names the fourteen glowing sprites outright
    // (coal and the nether ores are deliberately outside the list), so this
    // is a block-class lookup, not a color guess. Gate and add read the raw
    // texture, not base: base carries the per-face shade and AO, and a
    // "self"-light that swings 3x with face orientation is the wrong law
    // (measured at the 0.16.39 review). The add is the texel's own color
    // times its chroma: saturated flecks brighten toward the bloom knee
    // (post/bloom_bright.wgsl — diamond, gold and emerald cross it and halo;
    // the pale sprites glow without one until the slider lifts them over),
    // the stone or deepslate host gates out, and the hue carries itself with
    // no per-ore table. Gate floor 0.05 sits a quarter above the warmest
    // overworld host texel measured (0.0375, deepslate redstone). Where a
    // LabPBR pack already emits through the block above, this adds only the
    // excess over that emission: never a stack, and no per-texel handoff on
    // the smallest step of an 8-bit channel.
    if ore_glow > 0.0 && input.material == 8u {
        let lit = input.albedo.rgb;
        let fleck = smoothstep(0.05, 0.25,
            max(lit.r, max(lit.g, lit.b)) - min(lit.r, min(lit.g, lit.b)));
        color += lit * max(ore_glow * fleck - emission_map * 0.5, 0.0);
    }

    var alpha = input.albedo.a;

    if input.translucent && input.fluid == 1u {
        let dist = length(input.position);
        // input.position is camera-relative: anchor the field to the world, or the whole
        // pattern travels with the camera as the player moves
        let world = input.position + frame.camera_position;

        // depth first, because the waves need it: GPU Gems attenuates wave amplitude in the
        // shallows so waves lap up onto a shore instead of clipping through the bank
        let floor_depth = textureLoad(opaque_depth, vec2<i32>(input.screen * frame.resolution), 0);
        var path = 4.0;                               // no floor in reach: treat it as deep
        if floor_depth != 0.0 {
            path = clamp(length(world_at(input.screen, floor_depth) - input.position), 0.0, 24.0);
        }
        let shallow = smoothstep(0.0, 1.2, path);
        // The swells' shore phase: crests ride equal depth, so they wrap the lakebed's
        // contours and crowd together as the bottom rises under them, which is what real
        // swell does in its last hundred blocks before the beach.
        let shore_phase = min(path, 24.0) * 0.55;

        let detail = 1.0 / (1.0 + dist * 0.035);
        // One warp and one heading for everything: the swell field AND the ripple
        // textures ride the same wander and the same wind.
        let q = world.xz + wave_warp(world.xz, frame.time, wave_bend);
        let heading = wind_heading(world.xz, frame.time);
        let ch = cos(heading);
        let sh = sin(heading);
        let field = wave_field(q, frame.time, shore_phase, ch, sh);
        let slope = field.xy * water_waves * shallow;
        let crest_h = clamp(field.w * 3.0 * water_waves, 0.0, 1.0);

        // Capillary detail: two tileable ripple normal maps, rotated to the wind and
        // scrolling apart from each other, patch-mixed so neither tiles alone. They buy
        // the fine end of the spectrum — the frequencies the swell trains do not
        // carry — for two filtered fetches. The engine uploads pack PNGs with no mip
        // chain, so the layer rides detail^3 toward zero by mid distance: where raw
        // sampling would shimmer, distance was already hiding the structure. Ripples
        // bend the normal and the reflection, not the foam: foam marks breaking crests,
        // and a crest is a swell event. (Layer B rides back in layer A's rotation frame
        // - a fixed 0.9 rad skew on isotropic chop, which is nothing.)
        let da = heading + 0.35;
        let ca = cos(da);
        let sa = sin(da);
        // Chop rides the current too. Water does move along with wind-driven waves
        // (Stokes drift, plus surface drag), and standing chop alone reads as
        // dead water. Each layer slides slowly along its own bearing — fractions of a
        // block per second, the swell carries the fast visible flow — while keeping
        // the orbital sway on top: trackable motion without the single-axis conveyor
        // that a pure linear scroll makes.
        let t = frame.time;
        let oa1 = sin(t * 0.110) * 0.34 + sin(t * 0.043) * 0.18;
        let oa2 = sin(t * 0.090 + 1.3) * 0.30 + sin(t * 0.031 + 2.4) * 0.16;
        let ua = (q.x * ca + q.y * sa) * 0.0781 + oa1 + t * 0.030;   // /12.8 blocks
        let va = (q.y * ca - q.x * sa) * 0.0781 + oa2 + t * 0.008;
        let na = textureSampleLevel(ripple_a, ripple_a_sampler, vec2<f32>(ua, va), 0.0).xyz * 2.0 - 1.0;
        let db = heading - 0.55;
        let cb = cos(db);
        let sb = sin(db);
        let ob1 = sin(t * 0.083 + 2.1) * 0.30 + sin(t * 0.037 + 0.7) * 0.15;
        let ob2 = sin(t * 0.075 + 4.0) * 0.28 + sin(t * 0.029 + 5.1) * 0.14;
        let ub = (q.x * cb + q.y * sb) * 0.1220 + ob1 + t * 0.022;   // /8.2 blocks
        let vb = (q.y * cb - q.x * sb) * 0.1220 + ob2 + t * 0.009;
        let nb = textureSampleLevel(ripple_b, ripple_b_sampler, vec2<f32>(ub, vb), 0.0).xyz * 2.0 - 1.0;
        let msrc = vnoise(q * 0.05 + vec2<f32>(frame.time * 0.03, -frame.time * 0.02));
        let nd = mix(na.xy, nb.xy, msrc);
        // detail^3 for distance; and a shore weighting — wind chop is born against the
        // shallows and dies in the deep center, so `path` (the depth under the surface)
        // decides the energy: full in the first blocks, a third of it in open deep water.
        let chop = mix(1.0, 0.30, smoothstep(1.5, 6.5, path));
        let dfade = detail * detail * detail * 1.15 * chop;
        let slope_n = slope + vec2<f32>(ca * nd.x - sa * nd.y, sa * nd.x + ca * nd.y) * dfade;
        // The boil is vanilla's own, asked of the engine rather than rebuilt.
        // block_texture(input.uv) returns the water block's current animation frame at
        // its own sprite coords: the engine cycles frames at tick rate (vanilla's
        // speed, vanilla's sync) and the fluid mesher has already rotated the face UVs
        // by the flow vector (the fluid sim's direction). Direction, speed and frame
        // sync are the sim's, never ours to imitate. Tint-free per the API; the strip
        // averages mid-gray, normalized here so the pattern lends texture without
        // shifting brightness.
        let og_w = vanilla_flow * (1.0 - smoothstep(10.0, 30.0, dist));
        var og_pat = 1.0;
        var slope_o = vec2<f32>(0.0);
        if (og_w > 0.003) {
            og_pat = luma(block_texture(input.uv).rgb) * 1.515;      // /0.66 strip mean
            slope_o = clamp(vec2<f32>(dpdx(og_pat), dpdy(og_pat)),
                            vec2<f32>(-0.06), vec2<f32>(0.06)) * (og_w * 2.5);
        }
        let slope_f = slope_n + slope_o;

        // flowing water carries a per-block geometric slope, which steps at every block edge.
        // Flatten most of it on upward faces and let the continuous field carry the tilt;
        // side faces keep their own normal and get no waves.
        let upness = clamp(n_geo.y, 0.0, 1.0);
        let base_n = normalize(mix(n_geo, vec3<f32>(0.0, 1.0, 0.0), 0.7 * upness));
        let nw = normalize(base_n + vec3<f32>(slope_f.x, 0.0, slope_f.y) * upness);
        // The water asks the sun. The pack draws a shadow map every frame and the
        // material stage is bound to it, yet water was the one surface that never
        // asked whether the light could see it: glitter, foam and crest
        // transmission ignored every caster. Column skylight (input.light.y) is a
        // soft block-propagation proxy that knows nothing of this frame's cliffs
        // and canopy at raking sun. One comparison fetch (four when the softness
        // option is on) rides glitter, sparkle and crest transmission — the
        // sun-directed terms — and the foam's white. NOT the mirror (reflected
        // sky visibility is not sun visibility) and not the body
        // (ambient-dominated; the lightmap's business).
        // The verdict SPLITS the way the light does (Karis, SIGGRAPH'13): the
        // specular floor is 0.12 because a cliff's penumbra at water is nearly
        // razor — glitter inside a hard cast is nearly gone — while the foam, a
        // diffuse white, falls to 0.45, kin of the terrain's 0.42 in the shade
        // pass, and takes the verdict DIRECTLY like terrain does: no coupling
        // weight to hide behind. Foam and the crest carry no N·L of their own;
        // the floors answer for them, and the specular lobes carry theirs, so
        // no cos term here. The floors are daylight-bounce numbers; moonlit
        // water shares them for now.
        // The SURFACE law is the composite pass's: uv clamped off the border
        // texels — the taps clamped too, or edge verdicts sneak back in — and
        // past the map's square the unknown fades toward TRUE shadow (never sun
        // through mountains). That law saturates dark by 1.35xD, so beyond the
        // fetch ring the lit factor STARTS at the saturated verdict and only
        // the fetch refines it: an early-return there once reset it to sunlit
        // and drew a sun ring on the water at 1.35xD. The sunrise ramp,
        // clamp(l.y*20), is the shade pass's: a hard horizon gate was caught
        // relighting faces in one frame there, and foam carries no skylight
        // mask to hide a pop here.
        // The bias: offsets ON the vertical, never on nw — a rippling normal
        // under the offset only jitters the shadow line. Water is drawn into
        // the map's translucent COPY (the shadow module's header), never into
        // the map itself, so it cannot self-shadow: sunward leak behind casters
        // is bias's only failure mode here. The along-light term is seam-sized
        // (0.25+0.75*tan a) for exactly that reason. The up term still rides
        // the shade pass's coefficients (0.5+1.5*sin a): an offset
        // perpendicular to the light shears the shadow band by dy/tan(elev),
        // and on flat water — where the terrain's receiver normal is also
        // vertical — equal coefficients weld the glitter's dark edge to the
        // rock casting it. Falls' tilted faces shear slightly differently;
        // seam-sized consequence, with no acne possible to trade against. The
        // softness radius copies shade's law capped at four texels: shade
        // fades its reads out by the square's edge and never exercises the
        // growth; water fetches to 1.35xD, where uncapped it reaches ~22.
        var sun_spec = 1.0;
        var sun_diff = 1.0;
        if shadows && frame.has_shadow == 1u && light_dir.y > 0.0 {
            let ramp = clamp(light_dir.y * 20.0, 0.0, 1.0);
            let ground = max(abs(input.position.x), abs(input.position.z));
            let over_edge = ground / max(frame.shadow_distance, 1.0);
            if ramp > 0.001 {
                var lit = 0.0;    // the saturated past-edge verdict, refined below
                if over_edge < 1.35 {
                    let sin_a = sqrt(max(1.0 - light_dir.y * light_dir.y, 0.0));
                    let tan_a = min(sin_a / max(light_dir.y, 1e-3), 2.0);
                    let texel = max(frame.shadow_center_texel, 0.01);
                    let sp = shadow_position(input.position
                            + vec3<f32>(0.0, 1.0, 0.0) * (texel * (0.5 + 1.5 * sin_a))
                            + light_dir * (texel * (0.25 + 0.75 * tan_a)));
                    let lo = vec2<f32>(0.002, 0.002);
                    let hi = vec2<f32>(0.998, 0.998);
                    let uv = clamp(sp.xy, lo, hi);
                    lit = textureSampleCompareLevel(shadow_map, shadow_sampler,
                                                    uv, sp.z);
                    if shadow_softness > 0.0 {
                        let r = min((1.0 + length(input.position) * 0.02)
                                  * shadow_softness, 4.0)
                              / max(frame.shadow_resolution, 1.0);
                        lit += textureSampleCompareLevel(shadow_map, shadow_sampler,
                                                         clamp(uv + vec2<f32>(r, r * 0.5), lo, hi), sp.z);
                        lit += textureSampleCompareLevel(shadow_map, shadow_sampler,
                                                         clamp(uv + vec2<f32>(-r, r * 0.5), lo, hi), sp.z);
                        lit += textureSampleCompareLevel(shadow_map, shadow_sampler,
                                                         clamp(uv + vec2<f32>(0.0, -r), lo, hi), sp.z);
                        lit *= 0.25;
                    }
                }
                let verdict = mix(lit, 0.0, smoothstep(1.0, 1.35, over_edge));
                sun_spec = mix(1.0, mix(0.12, 1.0, verdict), ramp);
                sun_diff = mix(1.0, mix(0.45, 1.0, verdict), ramp);
            }
        }
        let cos_t = max(dot(nw, view), 0.0);
        let fres = fresnel_schlick(cos_t, 0.02);      // water's own F0, no boost
        // The mirror is planar: it is only honest where the water's surface is the plane it
        // mirrors about. Vertical faces (falls, waterfall sheets) and film-thin edges sample
        // a wrong slice of the mirrored world, so reflection is kept to upward faces with a
        // real path under them; everything else reads as the water's own body.
        let fres_m = fres * upness * smoothstep(0.12, 0.55, path);

        // refraction bends by the slope, scaled by the path so shallow water barely warps.
        // slope_f, not the swell alone: the near field of water is seen THROUGH the
        // surface (Fresnel says looking down = refraction), and the ripple dance lives
        // there — bend by the swell only and close water reads dead.
        let bend = slope_f * clamp(path, 0.0, 4.0) * refraction * 0.02;
        let ruv = clamp(input.screen + bend, vec2<f32>(0.002), vec2<f32>(0.998));
        let behind = textureLoad(opaque_color, vec2<i32>(ruv * frame.resolution), 0).rgb;
        // Beer-Lambert: red is absorbed first, so deep water goes blue-green on its own
        let absorb = exp(-vec3<f32>(0.42, 0.16, 0.10) * path * water_murk);
        // vanilla interpolates light from block corners, which quilts a flat water surface.
        // Halve the chroma deviation, compress the corner-to-corner steps, and add a continuous
        // shade from the wave normal so the surface reads as one body rather than lit blocks.
        let lm = input.lightmap;
        let g = luma(lm);
        let lm_w = pow(max(mix(vec3<f32>(g), lm, 0.5), vec3<f32>(0.0)), vec3<f32>(0.9));
        let ndl = clamp(dot(nw, frame.light_direction) * 0.5 + 0.5, 0.0, 1.0);
        let body = (behind * absorb + vec3<f32>(0.02, 0.09, 0.12) * lm_w * (1.0 - absorb))
                 * (0.92 + 0.08 * ndl);

        // foam from crest steepness and shore depth under one slow mask: no product of plane
        // waves (a checkerboard) and no fract(sin(x)*43758) hash, which re-rolls at world scale
        let shore = 1.0 - exp(-path * 3.0);
        let crest = clamp(length(slope) * 4.0 - 0.45, 0.0, 1.0);
        // the swash line breathes: one slow, per-patch phase drives where the foam edge
        // sits and how bright it runs, so the waterline advances up the beach and drains
        // back down it, which is what a breaking wave actually looks like from far away
        let run = sin(frame.time * 0.75 + vnoise(world.xz * 0.05 + vec2<f32>(7.31, 2.17)) * 6.2831);
        let swash = 0.5 + 0.5 * run;
        let foam_edge = 0.30 + 0.16 * run;
        // aperiodic patches: a single plane wave here would be 32-block parallel bands of foam
        let mask = smoothstep(0.35, 0.78, vnoise(world.xz * 0.09 + vec2<f32>(frame.time * 0.03, -frame.time * 0.02)));
        let foam = clamp((1.0 - smoothstep(foam_edge - 0.10, foam_edge + 0.34, path))
                             * (0.55 + 0.45 * swash)
                         + crest * mask * 1.2
                         + crest * (1.0 - smoothstep(0.0, 3.5, path)) * 0.8 * swash,
                         0.0, 1.0)
                 * water_foam;
        let foamy = mix(body, vec3<f32>(0.9, 0.95, 1.0) * lm_w * sun_diff,
                        foam * 0.65);

        // reflection: the engine's planar mirror, perturbed by the slope and scaled with
        // distance, because far water mirrors far things and the same tilt moves them more
        let r = reflect(-view, nw);
        // the mirror is planar: it flips the world about one water plane, and it is only
        // truthful for surfaces standing on that plane. Sloped, flowing, or stepped water
        // samples it with parallax error that slides toward the mirror's horizon, which is
        // where "I can see far LOD tiles and the horizon through the water" comes from.
        // Trust it fully within two blocks of the plane, not at all eight out.
        let on_plane = 1.0 - smoothstep(2.0, 8.0, abs(frame.water_plane - world.y));
        var mirror = sky_gradient(r);
        if reflections && frame.has_reflection == 1u {
            let muv = clamp(input.screen + slope_n * (0.030 + dist * 0.0006) * reflection_distort,
                            vec2<f32>(0.002), vec2<f32>(0.998));
            let m = textureSampleLevel(reflection, reflection_sampler, muv, 0.0).rgb;
            // the mirror carries vanilla's sky, not this pack's: ease toward our own near
            // the horizon so the reflected sky and the real sky do not disagree
            let grazing = 1.0 - clamp(abs(r.y) * 3.0, 0.0, 1.0);
            // `mirror` already holds sky_gradient(r): reuse it, don't re-derive it
            mirror = mix(m, mirror, max(grazing * 0.45, 1.0 - on_plane));
        }
        color = mix(foamy, mirror, fres_m);

        // light through the thin water at a crest, the cheap subsurface term Seascape uses
        color += vec3<f32>(0.05, 0.18, 0.20) * lm_w * crest_h * 0.35 * input.light.y * (1.0 - fres) * sun_spec;

        // the sun's path across the chop. The exponent widens with distance and the gain
        // falls, so far glitter does not alias into sparkle; clamped so it can never
        // become a broad face-painting wash on the water.
        if specular > 0.0 && light_dir.y > 0.0 {
            let gd = max(dist, 2.0);
            let s = clamp(1.0 - sqrt(gd / 450.0), 0.62, 0.90);
            let gain = 0.5 / (1.0 + gd * 0.012);
            let glint = shine(nw, light_dir, view, s) * input.light.y * specular * gain * sun_spec;
            color += vec3<f32>(glint) * mix(vec3<f32>(1.0), frame.sky_color * 2.0, 0.3);

            // Sparkle: discrete facets here and there catch full sun and go white for a
            // beat. Cells are world-fixed and re-rolled fifteen times a second (facet
            // geometry genuinely turns over about that fast), and only crest-top cells
            // qualify, so the path leads the chop instead of snowing on top of it.
            if sparkle > 0.0 {
                let sc = floor(world.xz * 6.0);
                let hf = unit(h21(u32(i32(sc.x)) ^ 0x45D9u,
                                  (u32(i32(sc.y)) * 2u + 7u) ^ (u32(frame.time * 15.0) * 2246822519u)));
                let facet = smoothstep(0.984, 1.0, hf);
                let oncrest = clamp(length(slope) * 4.5 - 0.35, 0.0, 1.0);
                let hit = shine(nw, light_dir, view, 0.985);
                color += vec3<f32>(1.0, 0.96, 0.88) * facet * oncrest * hit
                       * input.light.y * specular * gain * 7.0 * sparkle * sun_spec;
            }
        }
        // soft intersection: the water fades out where it meets the shore, no hard line
        alpha = clamp(input.albedo.a * shore + fres_m * 0.25 + foam * 0.15, 0.0, 0.96);
        // The boil's weight divides out the surface alpha, because the engine blends
        // this Surface color against the background AT that alpha: any modulation put
        // into color arrives on screen scaled down by it. Thin sheets on steps run at
        // ~0.35 alpha, so an uncorrected 30% cap would land as a 10% tint. og_eff
        // cancels the tax — the pattern shades the sheet fully, and the sheet's own
        // transparency still limits how much reaches the eye, which is honest.
        let og_eff = min(og_w / max(alpha, 0.25), 0.85);
        color *= mix(vec3<f32>(1.0), vec3<f32>(og_pat), og_eff);
        // water is not solid terrain: leave the post stage's surface buffer alone
        return Surface(vec4<f32>(max(color, vec3<f32>(0.0)), alpha));
    }

    if !input.translucent {
        // what the post passes read: world normal, smoothness, and the sky light as our own data
        set_surface(n, smoothness, input.light.y);
    }
    return Surface(vec4<f32>(max(color, vec3<f32>(0.0)), alpha));
}
