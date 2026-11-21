// Sun shafts: real volumetric in-scattering, at a quarter of the world's resolution
// — the architecture Frostbite/ARM/small-world-machine converged on. March each
// camera ray from the eye to the surface it hits (or the shadow map's reach for open
// sky), and at each step ask the shadow map whether that point in the air can reach
// the light. The average lit-fraction along the path IS the shaft — occluder
// silhouettes stretched toward the camera with true perspective, converging on the
// sun because the march is in the world, not in the picture: beam structure comes
// from geometry, never from smearing scene colour. Forward scattering is a Schlick
// lobe in ANGLE space, so the fan is round and aspect-proof. Steps are
// stratified-jittered and each verdict is a soft depth ramp; four steps per
// frame, then post/rays_accum.wgsl folds ~thirteen jittered frames (96%
// weight) into the cell by the engine's camera-motion reprojection law — the
// low-res volumetrics consensus (fewer steps + temporal accumulation). With
// the history trusted the beams are smoother than the old ten ever drew;
// exactly where the history gate fires (fast moves, resets) the cell pays the
// raw four-step estimate — momentarily coarser than the old ten, never worse
// than a frame behind. The same march runs nightward against the moon's shadow map
// (frame.light_direction IS the night caster).
override god_rays: f32 = 0.45;
override moon_shafts: f32 = 0.7;

fn post(input: PostInput) -> vec4<f32> {
    if god_rays <= 0.001 {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let sun = frame.sun_direction;
    let moon = frame.moon_direction;
    let night = clamp(-sun.y * 2.4, 0.0, 1.0);
    let moon_mode = sun.y < -0.02 && moon_shafts > 0.001 && moon.y > 0.02;
    // The shadows toggle takes shafts with it (no map, no verdicts): say it
    // here, before the corner-depth toll, not via march < 0.5 after it.
    if abs(sun.y) <= 0.02 || frame.has_shadow == 0u
        || (sun.y < -0.02 && (moon.y <= 0.02 || moon_shafts <= 0.001)) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);    // dusk handover; night with the
    }                                            // moon slider off stays black
    let light = select(sun, moon, moon_mode);
    // Day-side pre-fade: shafts PEAK at sunset, so the blackout window's edge was
    // the loudest possible place for a step. Day strength rides elevation to zero
    // inside the window; full day is untouched (fade = 1 past sun.y 0.12).
    let day_fade = smoothstep(0.02, 0.12, sun.y);
    let strength = god_rays * select(day_fade, moon_shafts * 0.55 * night, moon_mode);
    if strength <= 0.001 {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }

    // Forward-scatter lobe, Schlick's power-light Henyey-Greenstein stand-in, in the
    // angle between the view ray and the light. Round by construction: the fan
    // never stretches with the aspect ratio.
    let dir = ray_dir(input.uv);
    let mu = dot(dir, light);
    let k = 0.68;
    // The Schlick form never reaches zero: pointing straight away from the light
    // it still pays ((1-k)/(1+k))^3 ≈ 0.0068. Times the night strength that floor
    // sits right at the bail threshold, and a hard cut there would draw a ring of
    // faint beam around the ANTI-light point (the beam is fully lit looking away
    // from the caster, so the ring's inside is the hazy side). Subtract the floor
    // and renormalize: the lobe closes clean and smooth, and the bail only ever
    // fires where the term is already invisible.
    let floor_ = pow((1.0 - k) / (1.0 + k), 3.0);
    let glow = (pow((1.0 - k) / max(1.0 - k * mu, 0.02), 3.0) - floor_) / (1.0 - floor_);
    // Pixels the light barely reaches forward cannot pay for a march: bail BEFORE
    // any depth or shadow traffic. Sun behind the camera lands here. But the bail
    // itself must not draw: a hard cut sits at a fixed angle from the light and
    // renders as a faint circle tilting with it. Keep the threshold sub-LSB and
    // ramp the last orders of magnitude away, so the boundary is a fade, never
    // an edge.
    let gs = glow * strength;
    if gs < 0.0008 {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let bail = smoothstep(0.0008, 0.005, gs);

    // input.depth IS depth_at(input.uv) — the engine's generated entry
    // passes exactly that (stages.rs POST_ENTRIES); skip the load.
    let depth = input.depth;
    let over_sky = depth == 0.0;
    // The march stops at the surface the ray hits: no scattering drawn through walls.
    // One depth sample per quarter-res cell is not enough at block corners: a
    // cell that reads sky can still contain a corner, the ray marches past the
    // block, and the lit fan bleeds across it on upsample. Stop at the nearest
    // of the cell's four corner texels, so the march can never pass a solid
    // surface that sits inside its own pixel.
    let off = vec2<f32>(1.5) / frame.resolution;
    var d_stop = 1.0e9;
    if !over_sky {
        d_stop = length(view_position(input.uv, depth));
    }
    let corners = array<vec2<f32>, 4>(
        clamp(input.uv + vec2<f32>(-off.x, -off.y), vec2<f32>(0.0), vec2<f32>(1.0)),
        clamp(input.uv + vec2<f32>(off.x, -off.y), vec2<f32>(0.0), vec2<f32>(1.0)),
        clamp(input.uv + vec2<f32>(-off.x, off.y), vec2<f32>(0.0), vec2<f32>(1.0)),
        clamp(input.uv + vec2<f32>(off.x, off.y), vec2<f32>(0.0), vec2<f32>(1.0)),
    );
    for (var i = 0; i < 4; i++) {
        let d = depth_at(corners[i]);
        if d != 0.0 {
            d_stop = min(d_stop, length(view_position(corners[i], d)));
        }
    }
    let reach = frame.shadow_distance * 1.4;
    let march = min(d_stop, reach);
    if march < 0.5 {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);    // face planted in a block
    }

    // has_shadow == 0u returned at the top gate; this guard is the map-
    // presence contract for the march body, not a live branch.
    var beam = 1.0;
    if frame.has_shadow == 1u {
        let texel = max(frame.shadow_center_texel, 0.01);
        // A fixed toward-light bias. The shade pass's along-light term is
        // texel*(0.5+1.5*tan a), so this is conservative at mid angles and
        // under-biased past ~16 blocks, where edge texels run up to 4x coarser.
        let bias = light * (texel * 1.5);
        // Per-pixel start offset seeded from the pass's own pixel grid (the
        // manifest's 0.25 scale), hashed with the golden-ratio R2 pair: its
        // coordinate ratio is irrational, so no integer stride can fold the
        // seeds onto a screen lattice (the fixed 1920x1080 grid aliased into a
        // visible hatch at this pass's real 960x540 size on a 4K window).
        let pp = floor(input.uv * frame.resolution * 0.25) + 0.5;
        let jitter = fract(52.9829189 * fract(dot(pp, vec2<f32>(0.7548776662, 0.5698403028))));
        // Per-frame golden-ratio stride on top of the per-pixel seed: successive
        // frames sample different sub-step positions, so what the history
        // accumulates is a stratified set instead of one pattern repeated
        // (Frostbite's temporal-upsampling offset). The index rides mod 1024:
        // raw f32(frame_index) grows until its ulp swallows the sub-step
        // fractions — distinct offsets collapse to a handful after hours of
        // uptime and to ONE after days, silently un-dithering the staircase.
        // A 1024-frame cycle is periodic but never degenerate.
        let seed = jitter + f32(frame.frame_index % 1024u) * 0.6180339887;
        let step_len = march / 4.0;
        // Soft depth test. A binary tap answers 0 or 1, and N of them make the
        // beam an N+1-level staircase. Load the stored depth and ramp the
        // verdict. The penumbra must be at least ONE march step: the estimator
        // is samples spaced step_len apart, and a ramp sized in shadow texels
        // (2.5 texels = 0.31 blocks here) is narrower than that spacing, so the
        // samples flip one at a time and the beam moves in fractions. Where a
        // shadow edge runs horizontally, those fractions are the horizontal
        // bands. One step of ramp makes consecutive samples overlap and the
        // beam continuous; both terms are unit-free clip-z distances.
        let texel_world = 2.0 * frame.shadow_distance / max(frame.shadow_resolution, 1.0);
        let z0 = shadow_position(vec3<f32>(0.0)).z;
        let z_texel = abs(shadow_position(light * texel_world).z - z0) * 2.5;
        let z_step = abs(shadow_position(dir * step_len).z - z0);
        let ramp = max(max(z_texel, z_step), 1.0e-6);
        let dims = vec2<i32>(textureDimensions(shadow_map));
        var lit_sum = 0.0;
        for (var i = 0u; i < 4u; i = i + 1u) {
            let fi = f32(i);
            // Per-step offsets decorrelate the coverage samples, so the mean
            // converges instead of flipping in lockstep along a contour.
            let t = (fi + fract(seed + fi * 0.6180339887)) * step_len;
            let p = dir * t;
            let sp = shadow_position(p + bias);
            // 2x2 bilinear coverage. The compare tap filtered a 2x2 footprint with
            // hardware PCF; one nearest texel put that lattice back at full
            // contrast. Four loads, bilinear weights on the fractional position:
            // the coverage field goes C0 across the map instead of an equal-weight
            // box, so texel cells stop showing as steps.
            let u = sp.xy * vec2<f32>(dims) - vec2<f32>(0.5);
            let b = vec2<i32>(floor(u));
            let f = u - vec2<f32>(b);
            let hi = dims - vec2<i32>(1, 1);
            let d0 = textureLoad(shadow_map, clamp(b, vec2<i32>(0), hi), 0);
            let d1 = textureLoad(shadow_map, clamp(b + vec2<i32>(1, 0), vec2<i32>(0), hi), 0);
            let d2 = textureLoad(shadow_map, clamp(b + vec2<i32>(0, 1), vec2<i32>(0), hi), 0);
            let d3 = textureLoad(shadow_map, clamp(b + vec2<i32>(1, 1), vec2<i32>(0), hi), 0);
            let c0 = clamp((d0 - sp.z) / ramp + 0.5, 0.0, 1.0);
            let c1 = clamp((d1 - sp.z) / ramp + 0.5, 0.0, 1.0);
            let c2 = clamp((d2 - sp.z) / ramp + 0.5, 0.0, 1.0);
            let c3 = clamp((d3 - sp.z) / ramp + 0.5, 0.0, 1.0);
            let s = mix(mix(c0, c1, f.x), mix(c2, c3, f.x), f.y);
            // Past the map's edge there is no verdict; fade toward wrong-dark, the
            // same honesty law as the ground-fog verdict in composite.wgsl (never
            // sun through mountains). The near-duplicate is forced: shared files
            // compile into every stage, and the sky, vertex, weather and tonemap
            // preludes carry no shadow bindings.
            let d = max(abs(p.x), abs(p.z));
            let past = smoothstep(1.0, 1.35, d / max(frame.shadow_distance, 1.0));
            // Past the map's square the verdict is unknown. The old 0.30 floor
            // leaked there: steps beyond the square kept a third of the fan, so
            // a sun-locked veil showed on walls, tunnels and cave interiors that
            // fully cover the light. Surfaces fade to true shadow; the sky keeps
            // the 0.30 aerial floor because there is no occluder to be honest
            // about, and the fade still never draws an edge.
            lit_sum += mix(s, select(0.30, 0.0, !over_sky), past);
        }
        beam = lit_sum / 4.0;
    }

    let low = 1.0 - clamp(light.y * 1.6, 0.0, 1.0);
    let day_tint = mix(vec3<f32>(1.0, 0.97, 0.92), vec3<f32>(1.0, 0.78, 0.52), low);
    // moonlight is a cold silver, and it never warms at a horizon the sun left hours ago
    let tint = select(day_tint, vec3<f32>(0.70, 0.80, 1.05), moon_mode);
    // A fully lit path is plain aerial glow; occluded paths cut it to a sliver,
    // and the cut pattern IS the shaft structure. The glow rides the verdict:
    // opaque geometry covering the light must fully occlude the flare, not keep a
    // 15% floor of it (that leaked the halo through cliffs).
    let amp = strength * glow * beam * bail
            * (0.55 + 0.45 * light.y) * select(0.42, 0.24, over_sky);
    return vec4<f32>(tint * amp, 1.0);
}
