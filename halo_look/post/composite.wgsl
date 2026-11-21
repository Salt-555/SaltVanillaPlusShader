// The last pass, at the window's size: the world's picture times the half-res shade target,
// plus the quarter-res bloom, a grade that follows the time of day, a vignette, and an
// edge-directed filter. The pack's own [tonemap] ACES curve runs after this pass.
override saturation: f32 = 1.2;
override warmth: f32 = 0.35;
override vignette: bool = true;
override edge_smooth: f32 = 1.0;
override clarity: f32 = 0.25;
override film_grain: f32 = 0.35;
override night_grade: f32 = 0.6;
override ground_fog: f32 = 0.45;
override fog_line: f32 = 100.0;

// One pixel's four neighbours, loaded as integers. A full-res post pixel's uv sits at the
// exact centre of a texel, so a centre-weighted bilinear sample and a textureLoad of that
// texel return the same number; the explicit clamp keeps the sampler's edge behaviour.
// This turns the edge test and the clarity high-pass from 8 bilinear reads (32 fetches)
// into 4 loads (4 fetches) that they SHARE.
fn scene_at(p: vec2<i32>) -> vec3<f32> {
    let dims = vec2<i32>(frame.resolution);
    return textureLoad(scene_color, clamp(p, vec2<i32>(0, 0), dims - vec2<i32>(1, 1)), 0).rgb;
}

// Not FXAA 3.11. min/max luma over the shared cross is an edge test that does not care
// what order the neighbours arrive in, and it costs no extra reads because those texels
// were fetched for clarity anyway. Most pixels are flat block interior and return here
// after a single test; only a real edge pays for the blur.
fn smooth_edges(uv: vec2<f32>, c: vec3<f32>, cn: vec3<f32>, cs: vec3<f32>,
                cw: vec3<f32>, ce: vec3<f32>) -> vec3<f32> {
    let lc = luma(c);
    let lo = min(lc, min(min(luma(cn), luma(cs)), min(luma(cw), luma(ce))));
    let hi = max(lc, max(max(luma(cn), luma(cs)), max(luma(cw), luma(ce))));
    let range = hi - lo;
    if range < max(0.0312, hi * 0.125) {
        return c;
    }
    let px = 1.0 / frame.resolution;
    let grad = vec2<f32>(luma(cw) - luma(ce), luma(cn) - luma(cs));
    let gl = max(length(grad), 1e-5);
    let along = vec2<f32>(-grad.y, grad.x) / gl;   // along the edge, across the gradient
    let step = along * px * 1.5;
    let a = textureSampleLevel(scene_color, linear_sampler, uv + step, 0.0).rgb;
    let b = textureSampleLevel(scene_color, linear_sampler, uv - step, 0.0).rgb;
    let blend = clamp(range / max(hi, 1e-4) * 1.5, 0.0, 0.5) * edge_smooth;
    return mix(c, (a + b) * 0.5, blend);
}

fn post(input: PostInput) -> vec4<f32> {
    var c = input.color.rgb;
    // Fetch the cross once, and only when a feature that reads it is on.
    let ctr = vec2<i32>(input.uv * frame.resolution);
    var cn = c;
    var cs = c;
    var cw = c;
    var ce = c;
    if edge_smooth > 0.0 || clarity > 0.001 {
        cn = scene_at(ctr + vec2<i32>(0, -1));
        cs = scene_at(ctr + vec2<i32>(0, 1));
        cw = scene_at(ctr + vec2<i32>(-1, 0));
        ce = scene_at(ctr + vec2<i32>(1, 0));
    }
    if edge_smooth > 0.0 {
        c = smooth_edges(input.uv, c, cn, cs, cw, ce);
    }
    c *= textureSampleLevel(shade_buf, linear_sampler, input.uv, 0.0).rgb;
    c += textureSampleLevel(glow_blur, linear_sampler, input.uv, 0.0).rgb;
    // Sun shafts: rays_hist is post/rays_accum.wgsl's accumulated target (both
    // it and the march write black when off or gated, so this add is always
    // safe and often free). The raw quarter-res god_halo is the accumulator's
    // input now, never sampled here directly).
    c += textureSampleLevel(rays_hist, linear_sampler, input.uv, 0.0).rgb;

    // Ground fog: a shallow world-height band with a slow noise field, so mist pools
    // in valleys and drapes across the lake instead of hazing the whole screen. The
    // fog WEARS the pixel's own light (ambient * 0.75) and picks up silver only where
    // it faces the moon — night fog that glows on its own is the wallpaper look.
    if ground_fog > 0.0 {
        let fdepth = input.depth;
        if fdepth > 0.0 {                           // sky keeps its own haze
            let fpos = view_position(input.uv, fdepth);
            let wy = frame.camera_position.y + fpos.y;
            let below = max(fog_line - wy, 0.0);
            let fdist = length(fpos);
            if below > 0.25 && fdist > 3.0 {
                let sun0 = frame.sun_direction;
                // Grade and fog cool slower (2.0) than stars and shafts arrive
                // (sky and god_rays use 2.4): dusk keeps a warm beat before the silver.
                let night0 = clamp(-sun0.y * 2.0, 0.0, 1.0);
                let h = 1.0 - exp(-below * 0.22);
                let f = (1.0 - exp(-fdist * 0.016 * ground_fog
                                   * (0.35 + 0.65 * night0))) * h;
                let n = vnoise(fpos.xz * 0.045 + vec2<f32>(frame.time * 0.020,
                                                           -frame.time * 0.013));
                // The silver must be EARNED: one shadow-map verdict for this fog
                // point, so mist glowing moonward behind a treeline dims to its
                // leaked fraction instead of shining through the trees. The moon is
                // the night caster, so the verdict and the lobe share a light. Same
                // texel bias and past-edge honesty law as the march in god_rays.wgsl:
                // this verdict sits on a surface, so past the map's square it fades
                // to true shadow (the 0.30 aerial floor belongs to sky rays only).
                // The near-duplicate is forced: shared files compile into every
                // stage, and the sky, vertex, weather and tonemap preludes carry
                // no shadow bindings.
                var moonlit = pow(max(dot(normalize(fpos), frame.moon_direction), 0.0), 5.0) * night0;
                if night0 > 0.05 && moonlit > 0.0 && frame.has_shadow == 1u {
                    let texel = max(frame.shadow_center_texel, 0.01);
                    let sp = shadow_position(fpos + frame.light_direction * (texel * 1.5));
                    var lit = textureSampleCompareLevel(shadow_map, shadow_sampler,
                        clamp(sp.xy, vec2<f32>(0.002, 0.002), vec2<f32>(0.998, 0.998)), sp.z);
                    let d = max(abs(fpos.x), abs(fpos.z));
                    let past = smoothstep(1.0, 1.35, d / max(frame.shadow_distance, 1.0));
                    lit = mix(lit, 0.0, past);   // surface past the square: true shadow
                    moonlit *= mix(0.12, 1.0, lit);
                }
                let dens = clamp(f * (0.55 + 0.45 * n) + f * moonlit * 0.55, 0.0, 0.90);
                c = mix(c, c * 0.75 + vec3<f32>(0.016, 0.020, 0.032) * (0.3 + 0.7 * night0)
                             + vec3<f32>(0.055, 0.075, 0.13) * moonlit, dens);
            }
        }
    }

    if warmth > 0.0 {
        let sun = frame.sun_direction;
        let low = 1.0 - clamp(abs(sun.y) * 2.5, 0.0, 1.0);
        let night = clamp(-sun.y * 2.0, 0.0, 1.0);
        c *= mix(vec3<f32>(1.0), vec3<f32>(1.0, 0.93, 0.82), low * warmth);
        c *= mix(vec3<f32>(1.0), vec3<f32>(0.88, 0.94, 1.06), night * warmth * 0.6);
    }

    let grey = luma(c);
    c = mix(vec3<f32>(grey), c, saturation);

    // Night grade: the moon is cold, the lamp is not. Only the unlit end of the
    // range tips teal; anything already warm (hearth, glowstone, torchlit wall)
    // keeps its colour, which is exactly the contrast a night scene lives on.
    if night_grade > 0.0 {
        let night = clamp(-frame.sun_direction.y * 2.0, 0.0, 1.0);
        if night > 0.0 {
            let shad = 1.0 - smoothstep(0.015, 0.16, grey);
            c = mix(c, c * vec3<f32>(0.74, 0.94, 1.16)
                   + vec3<f32>(0.003, 0.007, 0.012),
                night * night_grade * shad * 0.5);
        }
    }

    // Clarity: local contrast by a four-tap high-pass, riding the cross the edge test
    // already loaded. The guard keeps flat block interiors (where the high-pass is only
    // texture noise and dither) out of it, so it sharpens edges and detail, not crunch.
    if clarity > 0.001 {
        let detail = c - (cn + cs + cw + ce) * 0.25;
        let peak = max(max(detail.r, detail.g), detail.b);
        let guard = clamp((peak - 0.015) * 8.0, 0.0, 1.0);
        c += detail * clarity * guard;
    }

    if vignette {
        let d = length(input.uv - vec2<f32>(0.5));
        let v = smoothstep(0.42, 0.92, d);
        c *= 1.0 - v * 0.24;
        // the darkened edge runs a hair cold: reads as lens glass, not as dirt on a screen
        c = mix(c, vec3<f32>(luma(c)) * vec3<f32>(0.90, 0.95, 1.12), v * 0.30);
    }

    // Film grain: re-rolls at twelve steps a second (a film shutter's cadence, not a
    // television's), weighted into the shadows where real film grain actually lives.
    if film_grain > 0.0 {
        let g = unit(h21(u32(ctr.x) ^ (u32(frame.time * 12.0) * 2654435761u), u32(ctr.y) + 0x517C1u));
        c += (g - 0.5) * film_grain * 0.018 * (0.4 + 0.6 * (1.0 - clamp(grey * 1.6, 0.0, 1.0)));
    }
    return vec4<f32>(max(c, vec3<f32>(0.0)), 1.0);
}
