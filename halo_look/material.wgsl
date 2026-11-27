// Each point of a block's surface: vanilla's light, then LabPBR normals and specular,
// coloured block light, and water that mirrors the world about its plane.
// `shaded_tint` is the free path: it carries vanilla's tint, shade and ambient occlusion
// without turning on terrain look storage (no world reload, no extra terrain memory).
override specular: f32 = 0.8;
override sss_back: f32 = 1.0;
override pbr_relief: f32 = 0.25;
override surface_geometry: bool = false;
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


// Constant amplitude-over-wavelength. GPU Gems keeps A/L fixed because "the surface
// orientation is dominated by waves with greater ratios of amplitude to wavelength", so
// every train contributes equally to the normal instead of one frequency rowing the surface.
// The height term per train rides SLOPE_AMP / WF_K[i] pre-divided: the literals in
// wave_field are the exact f32 quotients, so the per-train runtime divide is gone
// without a rounding moving.
const SLOPE_AMP: f32 = 0.022;

// The ripple layers' two fixed bearings off the live heading, as exact f32 angle constants
// for the addition formulas in the water branch (cos(h+0.35), sin(h+0.35), cos(h-0.55),
// sin(h-0.55)) — four quarter-rate transcendentals per pixel bought down to eight mults.
const COS35: f32 = 0.939372718334198;
const SIN35: f32 = 0.34289780259132385;
const COS55: f32 = 0.8525245189666748;
const SIN55: f32 = 0.5226872563362122;

// The sea's shape: a sampled directional spectrum, seven trains of it (the tables and the
// spectrum's contract live in common.wgsl). Local to the water branch, which is its only
// caller, and HAND-UNROLLED on purpose: every table read takes a literal index, which folds
// the private-array reads to immediates (docs/api/shaders-reference-0.2.md, Tables: a
// constant index avoids the spill store) while the accumulation keeps the loop's exact
// train order, so every sum is the same sequence of adds. The frame-constant terms — the
// life envelope, the travel angle, the breathing sway — arrive precomputed from the
// [[before_world]] wave clock: env = wave_clock[i], travel = wave_clock[7u+i], sway =
// wave_clock[14u+i] (see pre/wave_clock.wgsl for the layout and the exact arithmetic).
// q is the domain-warped world xz; ch/sh are cos/sin of the live wind heading, applied to
// the whole fan at once. Returns vec4(slope.x, slope.y, 0, height proxy).
// Shore coupling: adding the water's depth to the long trains' phase slides their crests
// along the depth contours (equal depth = equal phase) — the cheap form of wave refraction:
// real swell turns to run parallel to the shore and shortens as it shallows.
fn wave_field(q: vec2<f32>, shore_phase: f32, ch: f32, sh: f32) -> vec4<f32> {
    let u = q.x * ch + q.y * sh;
    let v = q.y * ch - q.x * sh;
    // Aperiodic patches of calm and rough.
    let group = 0.70 + 0.30 * vnoise(q * 0.022 + vec2<f32>(frame.time * 0.010, -frame.time * 0.008));
    var acc = vec3<f32>(0.0);
    let ph0 = WF_K[0u] * (u * WF_CC[0u] + v * WF_CS[0u]) - wave_clock[7u + 0u] - wave_clock[14u + 0u] + WF_SHORE[0u] * shore_phase;
    let sn0 = sin(ph0);
    let cs0 = cos(ph0);
    let en0 = wave_clock[0u];
    let sl0 = -(sn0 + WF_STEEP[0u] * 2.0 * sn0 * cs0) * SLOPE_AMP * en0;
    acc += vec3<f32>((ch * WF_CC[0u] - sh * WF_CS[0u]) * sl0,
                     (sh * WF_CC[0u] + ch * WF_CS[0u]) * sl0,
                     sn0 * 0.09053497761487961 * en0);
    let ph1 = WF_K[1u] * (u * WF_CC[1u] + v * WF_CS[1u]) - wave_clock[7u + 1u] - wave_clock[14u + 1u] + WF_SHORE[1u] * shore_phase;
    let sn1 = sin(ph1);
    let cs1 = cos(ph1);
    let en1 = wave_clock[1u];
    let sl1 = -(sn1 + WF_STEEP[1u] * 2.0 * sn1 * cs1) * SLOPE_AMP * en1;
    acc += vec3<f32>((ch * WF_CC[1u] - sh * WF_CS[1u]) * sl1,
                     (sh * WF_CC[1u] + ch * WF_CS[1u]) * sl1,
                     sn1 * 0.06874334067106247 * en1);
    let ph2 = WF_K[2u] * (u * WF_CC[2u] + v * WF_CS[2u]) - wave_clock[7u + 2u] - wave_clock[14u + 2u] + WF_SHORE[2u] * shore_phase;
    let sn2 = sin(ph2);
    let cs2 = cos(ph2);
    let en2 = wave_clock[2u];
    let sl2 = -(sn2 + WF_STEEP[2u] * 2.0 * sn2 * cs2) * SLOPE_AMP * en2;
    acc += vec3<f32>((ch * WF_CC[2u] - sh * WF_CS[2u]) * sl2,
                     (sh * WF_CC[2u] + ch * WF_CS[2u]) * sl2,
                     sn2 * 0.052196916192770004 * en2);
    let ph3 = WF_K[3u] * (u * WF_CC[3u] + v * WF_CS[3u]) - wave_clock[7u + 3u] - wave_clock[14u + 3u] + WF_SHORE[3u] * shore_phase;
    let sn3 = sin(ph3);
    let cs3 = cos(ph3);
    let en3 = wave_clock[3u];
    let sl3 = -(sn3 + WF_STEEP[3u] * 2.0 * sn3 * cs3) * SLOPE_AMP * en3;
    acc += vec3<f32>((ch * WF_CC[3u] - sh * WF_CS[3u]) * sl3,
                     (sh * WF_CC[3u] + ch * WF_CS[3u]) * sl3,
                     sn3 * 0.03963319584727287 * en3);
    let ph4 = WF_K[4u] * (u * WF_CC[4u] + v * WF_CS[4u]) - wave_clock[7u + 4u] - wave_clock[14u + 4u] + WF_SHORE[4u] * shore_phase;
    let sn4 = sin(ph4);
    let cs4 = cos(ph4);
    let en4 = wave_clock[4u];
    let sl4 = -(sn4 + WF_STEEP[4u] * 2.0 * sn4 * cs4) * SLOPE_AMP * en4;
    acc += vec3<f32>((ch * WF_CC[4u] - sh * WF_CS[4u]) * sl4,
                     (sh * WF_CC[4u] + ch * WF_CS[4u]) * sl4,
                     sn4 * 0.030093543231487274 * en4);
    let ph5 = WF_K[5u] * (u * WF_CC[5u] + v * WF_CS[5u]) - wave_clock[7u + 5u] - wave_clock[14u + 5u] + WF_SHORE[5u] * shore_phase;
    let sn5 = sin(ph5);
    let cs5 = cos(ph5);
    let en5 = wave_clock[5u];
    let sl5 = -(sn5 + WF_STEEP[5u] * 2.0 * sn5 * cs5) * SLOPE_AMP * en5;
    acc += vec3<f32>((ch * WF_CC[5u] - sh * WF_CS[5u]) * sl5,
                     (sh * WF_CC[5u] + ch * WF_CS[5u]) * sl5,
                     sn5 * 0.022850070148706436 * en5);
    let ph6 = WF_K[6u] * (u * WF_CC[6u] + v * WF_CS[6u]) - wave_clock[7u + 6u] - wave_clock[14u + 6u] + WF_SHORE[6u] * shore_phase;
    let sn6 = sin(ph6);
    let cs6 = cos(ph6);
    let en6 = wave_clock[6u];
    let sl6 = -(sn6 + WF_STEEP[6u] * 2.0 * sn6 * cs6) * SLOPE_AMP * en6;
    acc += vec3<f32>((ch * WF_CC[6u] - sh * WF_CS[6u]) * sl6,
                     (sh * WF_CC[6u] + ch * WF_CS[6u]) * sl6,
                     sn6 * 0.0173500906676054 * en6);
    return vec4<f32>(acc.x, acc.y, 0.0, acc.z) * group;
}

// SPBR heights are geometry near the camera; the engine replaces the
// flat face with this grid inside the reach, pins face edges at the
// texture's mean height itself, and needs a REAL depth - at zero the
// grid's own coplanar cells z-fight. Runs in a vertex context: input
// and the menu only.
fn displacement(input: DisplacementInput) -> f32 {
    return (1.0 - input.height) * pbr_relief;
}

fn material(input: MaterialInput) -> Surface {
    // Fully transparent texels - leaf gaps, the empty corners of cross quads - are invisible
    // in every blend mode and alpha-tested away anyway. Returning before anything else spares
    // the whole pipeline (maps, light, water) on the largest category of shaded-and-discarded
    // pixels the canopy-heavy frames pay for. Bit-identical output; less work.
    if input.albedo.a == 0.0 {
        return Surface(vec4<f32>(0.0));
    }
    let n_geo = normalize(input.normal);
    let view = normalize(-input.position);
    let light_dir = frame.light_direction;
    var alpha = input.albedo.a;

    // Water first, and the terrain prologue below stays below it: the water branch shares
    // only n_geo, view, light_dir and the alpha slot with the terrain path, so keeping them
    // apart means a water pixel never pays the coloured-light grid sample, the LabPBR fetches,
    // the terrain glint or the ore glow — and new terrain-only work must keep landing AFTER
    // this branch or it silently joins the water bill.
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
        var q = world.xz;
        if wave_bend > 0.0 {
            // A zero slider means zero: the branch deletes the warp's two noise looks;
            // a multiply by 0 would leave them running.
            q = q + wave_warp(world.xz, frame.time, wave_bend);
        }
        let heading = wind_heading(world.xz, frame.time);
        let ch = cos(heading);
        let sh = sin(heading);
        var field = vec4<f32>(0.0);
        if water_waves > 0.0 {
            field = wave_field(q, shore_phase, ch, sh);
        }
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
        // detail^3 for distance; and a shore weighting — wind chop is born against the
        // shallows and dies in the deep center, so `path` (the depth under the surface)
        // decides the energy: full in the first blocks, a third of it in open deep water.
        let chop = mix(1.0, 0.30, smoothstep(1.5, 6.5, path));
        let df_raw = detail * detail * detail * 1.15 * chop;
        // The amplitude gate: below ~0.55% tilt the layer is sub-pixel by construction, so
        // ramp it to zero across this band and take the two un-mipped fetches, the patch-mix
        // noise and both rotations out with it. dfade -> 0 is the layer's own continuation at
        // this bound (never a neutral default), so nothing can re-appear as a ring; near and
        // mid water are untouched, bit for bit.
        let dfade = df_raw * (1.0 - smoothstep(0.0030, 0.0055, df_raw));
        var slope_n = slope;
        if dfade > 0.0 {
            // Bearing offsets from the live heading by angle addition: the two layer skews
            // are constants, so the four extra sin/cos are pure waste. Exact f32 angle
            // constants below (module scope).
            let ca = ch * COS35 - sh * SIN35;
            let sa = sh * COS35 + ch * SIN35;
            let ua = (q.x * ca + q.y * sa) * 0.0781 + wave_clock[21u] + wave_clock[25u];   // /12.8 blocks
            let va = (q.y * ca - q.x * sa) * 0.0781 + wave_clock[22u] + wave_clock[26u];
            let na = textureSampleLevel(ripple_a, ripple_a_sampler, vec2<f32>(ua, va), 0.0).xyz * 2.0 - 1.0;
            let cb = ch * COS55 + sh * SIN55;
            let sb = sh * COS55 - ch * SIN55;
            let ub = (q.x * cb + q.y * sb) * 0.1220 + wave_clock[23u] + wave_clock[27u];   // /8.2 blocks
            let vb = (q.y * cb - q.x * sb) * 0.1220 + wave_clock[24u] + wave_clock[28u];
            let nb = textureSampleLevel(ripple_b, ripple_b_sampler, vec2<f32>(ub, vb), 0.0).xyz * 2.0 - 1.0;
            let msrc = vnoise(q * 0.05 + vec2<f32>(frame.time * 0.03, -frame.time * 0.02));
            let nd = mix(na.xy, nb.xy, msrc);
            slope_n = slope + vec2<f32>(ca * nd.x - sa * nd.y, sa * nd.x + ca * nd.y) * dfade;
        }
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
                        let r = min((1.0 + dist * 0.02)
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
        let ndl = clamp(dot(nw, light_dir) * 0.5 + 0.5, 0.0, 1.0);
        let body = (behind * absorb + vec3<f32>(0.02, 0.09, 0.12) * lm_w * (1.0 - absorb))
                 * (0.92 + 0.08 * ndl);

        // foam from crest steepness and shore depth under one slow mask: no product of plane
        // waves (a checkerboard) and no fract(sin(x)*43758) hash, which re-rolls at world scale
        let shore = 1.0 - exp(-path * 3.0);
        let slen = length(slope);
        let crest = clamp(slen * 4.0 - 0.45, 0.0, 1.0);
        var foam = 0.0;
        if water_foam > 0.0 {
        // the swash line breathes: one slow, per-patch phase drives where the foam edge
        // sits and how bright it runs, so the waterline advances up the beach and drains
        // back down it, which is what a breaking wave actually looks like from far away
            let run = sin(frame.time * 0.75 + vnoise(world.xz * 0.05 + vec2<f32>(7.31, 2.17)) * 6.2831);
            let swash = 0.5 + 0.5 * run;
            let foam_edge = 0.30 + 0.16 * run;
            // aperiodic patches: a single plane wave here would be 32-block parallel bands of foam
            let mask = smoothstep(0.35, 0.78, vnoise(world.xz * 0.09 + vec2<f32>(frame.time * 0.03, -frame.time * 0.02)));
            foam = clamp((1.0 - smoothstep(foam_edge - 0.10, foam_edge + 0.34, path))
                             * (0.55 + 0.45 * swash)
                         + crest * mask * 1.2
                         + crest * (1.0 - smoothstep(0.0, 3.5, path)) * 0.8 * swash,
                         0.0, 1.0)
                 * water_foam;
        }
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
        // Water composes its own color from the mix below; the terrain prologue's color
        // never reaches this branch, and this branch never reads it.
        var color = vec3<f32>(0.0);
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
        // THE SKY-OPEN LAW (owner, 0.17.11: "water doesnt reflect if it is
        // under ground"): the mirror - engine plane image or the pack's own
        // sky_gradient fallback - depicts OPEN SKY, and a cave pool is not
        // under open sky no matter what the ray points at. Skylight is the
        // engine's own sky-visibility measurement, the same field the
        // shines below already gate on; the mirror's weight rides it, so a
        // sealed pool goes matte and a pool one block from a skyhole keeps
        // the reflection its light actually receives.
        color = mix(foamy, mirror, fres_m * input.light.y);

        // The sun-directed water terms all carry input.light.y (crest transmission, the
        // glint, the sparkle): where skylight is exactly zero — cave pools, Nether water,
        // full roofing — this branch deletes the two shines, the sqrt and the hash that
        // were computing exact zeros. The sun verdict above stays OUT of this gate: the
        // foam's white rides sun_diff with no light.y factor of its own.
        if input.light.y > 0.0 {
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
                    let oncrest = clamp(slen * 4.5 - 0.35, 0.0, 1.0);
                    if facet > 0.0 && oncrest > 0.0 {
                        // smoothstep clamps to an exact zero below its edge: ~98% of cells are
                        // facet-killed, most of the rest crest-killed; only survivors pay a shine.
                        let hit = shine(nw, light_dir, view, 0.985);
                        color += vec3<f32>(1.0, 0.96, 0.88) * facet * oncrest * hit
                               * input.light.y * specular * gain * 7.0 * sparkle * sun_spec;
                    }
                }
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


    let pbr = block_pbr_maps();
    var n = n_geo;
    var smoothness = 0.0;
    var f0 = vec3<f32>(0.0);
    var metal_damp = vec3<f32>(1.0);
    var emission_map = 0.0;
    var sss = 0.0;
    var porosity = 0.0;
    if pbr {
        // all reads inside the branch: with no LabPBR pack installed they cost nothing
        let spec_map = block_specular_map(input.uv);
        smoothness = spec_map.r;
        // LabPBR's alpha is emission EXCEPT that exactly 255/255 means
        // "ignored" — the format's own footgun: any plain opaque map reads
        // as full emission if the rule isn't applied. The engine passes the
        // maps through raw (the generated sampler is a passthrough; "1 none"
        // is convention, not runtime), so the decode is the pack's job:
        // up to 254/255 scales linearly, 255 is none. SPBR ships alpha 255
        // on every non-emissive block; unruled, every face added half its
        // albedo at all hours and nothing stayed dark (owner: "the dark
        // areas are no longer dark at all").
        emission_map = select(spec_map.a, 0.0, spec_map.a > 0.998);
        // LabPBR green is the reflectance: F0 up to 229/255 for dielectrics,
        // 230-254 the preset metals, 255 the albedo-as-F0 metal. Every
        // highlight must ride it. Reading only red gave every sunlit face a
        // half-strength broad lobe regardless of what the material is — the
        // tonemap clipped that to pale (owner: "everything gettin hit by the
        // sun is mad washed out"). SPBR ships stone/dirt/wood at F0 0, so
        // those faces now add nothing. Metal bands per the format: 230-254
        // are preset metals — one shared strength, albedo as the F0 COLOR —
        // and 255 says the albedo IS the F0 per channel. Metals pay for
        // their reflectance out of their diffuse (metal_damp): a metal's
        // color belongs in its reflection, not its matte shading. The
        // per-metal N/K tables are still not modeled.
        let g = spec_map.g;
        f0 = vec3<f32>(g);
        if (g > 0.9) { f0 = input.albedo.rgb * 0.9; }
        if (g > 0.999) { f0 = input.albedo.rgb; }
        // Damp is a SCALAR on the F0's luma with a floor (review,
        // measured on SPBR: (1-F0) per channel left gold and copper
        // matte shading tinted with their own COMPLEMENT - cyan
        // residue - and iron at 0.137 reads black in a forward pass
        // with no env reflection to pay back the traded energy).
        // One law for both metal bands; band starts at 230, not 229.
        metal_damp = mix(vec3<f32>(1.0),
                         vec3<f32>(max(1.0 - max3(f0), 0.25)),
                         step(229.5 / 255.0, g));
        // THE EMISSION GATE (owner: "the grass still has lime green bright
        // edges as if lit up even in midnight"): a cutout sprite's _s alpha
        // is 255 on the blade / 0 behind it, neither is emission, and linear
        // filtering blends them to a mid alpha along every seam that the
        // alpha rule then reads as real, blade-tinted glow — with no sun
        // gate, so it blazes at midnight. A coverage gate on the color's own
        // alpha CANNOT catch it: a blade texel is fully opaque (alpha 1); the
        // map bled via filtering while the color did not. The discriminator
        // is the block's own light level: a pack's per-texel emission is
        // detail on a block that ALREADY emits (a torch 0.93, glowstone/magma/
        // lantern 1), never a way to make grass or stone glow. Scaling map
        // emission by input.emission zeroes it on every non-emissive block —
        // grass, leaves, flowers, saplings — regardless of how their maps
        // filtered, and keeps every real emitter's glow in full.
        emission_map *= input.emission;
        // THE COVERAGE LAW: map arrays filter and mipmap on their own and
        // the pack stores junk behind transparent texels (SPBR: 138 cutout
        // sprites), which mips average into distance and edge taps drink, so
        // the highlight strength and the normal ease toward flat with the
        // coverage the color sprite actually paints (owner: "all of the grass
        // has a highlight"). Opaque faces are coverage 1: untouched.
        let cov = smoothstep(0.5, 0.9, input.albedo.a);
        f0 *= cov;
        // THE BLUE BAND, split by value like the format says: 0-64 is
        // porosity (how thirsty the material is), 65-255 is subsurface
        // translucence. One byte is never both. Both ride coverage: the
        // junk behind cutout texels is full-range in every channel.
        sss = min(clamp((spec_map.b - 65.0 / 255.0) * (255.0 / 190.0), 0.0, 1.0), 0.6) * cov;
        porosity = select(spec_map.b * (255.0 / 64.0), 0.0, spec_map.b > 64.0 / 255.0) * cov;
        n = normalize(mix(n_geo, mapped_normal(n_geo, input.tangent, block_normal_map(input.uv)), cov));
    }

    // vanilla's lit colour, in linear light
    let base = input.albedo.rgb * input.shaded_tint.rgb;
    var color = base * input.lightmap * metal_damp;

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
        color += base * metal_damp * near * gf * (tint - vec3<f32>(1.0));
    }
    // the engine's carried block lights — held and dropped items, and any
    // [[particle_lights]] or mod lights upstream — ride in as a hue shift
    if any(input.colored_light > vec3<f32>(0.0)) {
        color = mix(color, color * (vec3<f32>(1.0) + input.colored_light), 0.5);
    }

    // Rain on porous material (LabPBR blue 0-64): damp darkens the albedo
    // and a thin water film smooths the surface toward a mirror sheen.
    // frame.wetness is the engine's smoothed rain state — 0 when dry, and
    // porosity is 0 without maps, so either alone makes this free.
    // Before the highlight block: the smoothing must ride the same
    // smoothness the sun lobe is cut from.
    let wet = clamp(frame.wetness * porosity, 0.0, 1.0)
            // wetness is ONE global weather scalar with no position
            // (review): gate it to actual rain (not snow) falling on
            // surfaces that can see the sky, or caves and covered
            // floors darken in a storm.
            * step(0.1, input.light.y) * select(0.0, 1.0, frame.precipitation == 1u);
    if wet > 0.0 {
        color *= mix(vec3<f32>(1.0), vec3<f32>(0.62), wet);
        smoothness = min(smoothness + (1.0 - smoothness) * wet, 1.0);
    }

    // the sun's or moon's highlight where the sky reaches the surface
    if specular > 0.0 && light_dir.y > 0.0 {
        // Specular only where a normal map gives variation inside a face: a block face
        // has a flat normal, so a highlight is near-constant across it and paints the
        // whole face pale. Water keeps its glint because the wave field varies the
        // normal per fragment.
        // LabPBR's own channels decide: smoothness sets the lobe width, F0
        // the strength. A gate on f0 > 0.0 skips zero-F0 sprites wholesale —
        // the skipped face's continuation is exactly what an F0 of 0 added,
        // so no boundary can render.
        if smoothness > 0.02 && max3(f0) > 0.0 {
            let sun_tint = mix(vec3<f32>(1.0), frame.sky_color * 2.0, 0.35);
            let glint = shine(n, light_dir, view, smoothness) * input.light.y * specular;
            // Schlick: F0 is the head-on share; grazing angles mirror more.
            // The grazing RAMP is scaled by F0 itself (to 3x) rather than
            // the textbook (1-F0): pure Schlick's largest boost goes to
            // F0 = 0 - and SPBR ships wood at F0 = 11/255 (measured from
            // acacia/birch _s: green ~11) - the near-maximum grey ramp on
            // every log. A sun-only forward pass with no environment to
            // answer for it renders that as a grey gradient across every
            // log face (owner, 0.17.10: "a gradient of grey on all of the
            // logs"). Dielectrics keep a sheen proportional to what they
            // actually mirror (11/255 x 3 = a whisper); the metal bands
            // (F0 >= .9) saturate the cap at 3x and are untouched.
            let hv = max(dot(normalize(light_dir + view), view), 0.0);
            let graze = min(f0 * 3.0, vec3<f32>(1.0));
            let f_ang = f0 + graze * pow(1.0 - hv, 5.0);
            color += glint * 0.5 * f_ang * sun_tint;
        }
    }

    // LabPBR's subsurface: the sun shining through a translucent
    // surface toward the eye (blue 65-255 = the fraction). Two gates
    // beyond the sun: the FACE must point away from the sun (a
    // backlit side is what transmission is), or every upward lawn
    // facing a low sun gets a flat albedo add — washed-out grass,
    // shipped 0.17.0, owner: "grass and leaves seem washed out".
    // And the add is half-rate: it is a highlight through leaves,
    // not a second sun. Lava and water carry their own light.
    // LabPBR's subsurface: SUNlight through a translucent surface
    // toward the eye (blue 65-255 = the fraction). Sun-specific vectors
    // — frame.light_direction is the MOON by night, and a warm-white
    // moonlit transmission glow is wrong (review: leaves glowed at
    // midnight). sun_direction goes below the horizon at night, which
    // is this block's off switch; the y ramp fades it at dawn/dusk.
    // Gates: the FACE must point away from the sun (backlit is what
    // transmission is — the wash-out fix), input.light.y keeps caves
    // and covered spots out, fluids carry their own light.
    if sss > 0.0 && sss_back > 0.0 && input.fluid == 0u {
        let sun = frame.sun_direction;
        let day = clamp(sun.y * 6.0, 0.0, 1.0);
        if day > 0.0 {
            let backlit = max(-dot(n, sun), 0.0);
            let back = max(dot(sun, -view), 0.0);
            let trans = pow(back, 4.0) * backlit * sss * sss_back * 0.5 * day * input.light.y;
            color += input.albedo.rgb * vec3<f32>(1.0, 0.86, 0.66) * trans;
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


    if !input.translucent {
        // what the post passes read: world normal, smoothness, and the sky light as our own data
        set_surface(n, smoothness, input.light.y);
    }
    return Surface(vec4<f32>(max(color, vec3<f32>(0.0)), alpha));
}
