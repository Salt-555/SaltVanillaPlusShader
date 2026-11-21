// Shaft history: the march's temporal accumulator (Frostbite's cloud temporal
// upsampling; UE Volumetric Fog's reprojection — the low-res volumetrics con-
// sensus). Each frame pays FOUR jittered steps; this pass reprojects last
// frame's cell by the engine's own camera-motion law (a point at camera-rela-
// tive p now stood at p + camera_motion under last frame's camera) and blends
// it clamped into a cross-box of this frame's cell (Karis-style neighbourhood
// clip). The law is EXACT for static content: translation rides camera_motion,
// rotation/bob/roll ride previous_view_projection (last frame's full product;
// camera-relative coords are world axes, inputs.rs). What no law can model is
// content with no motion term: shaft features belonging to an occluder NEARER
// than the cell's sampled depth (the march is a line integral; anchoring it at
// one depth moves a fence-at-2-against-a-wall-at-20 with the wall's parallax),
// [vertex]-stage wind foliage, entities, block edits, and the shadow map's
// cell-snap requantizing silhouettes as the camera crosses a step. Those land
// in the clamp box — it forfeits history it cannot vouch for, it never ghosts.
// Convergence ~thirteen frames at 60 fps (dt-normalized). The output is what
// the composite adds; the raw god_halo is this pass's input only. input.pixel
// addresses god_halo texel-for-texel ONLY because both this pass's attachment
// and god_halo are scale 0.25 — move either scale and re-derive these taps.
override god_rays: f32 = 0.45;
override moon_shafts: f32 = 0.7;

fn post(input: PostInput) -> vec4<f32> {
    // Gates first, no read before any of them: the march's own uniform
    // blackouts (same names = same pipeline constants, same fallbacks) plus
    // its strength cut — where the march writes black there is nothing to
    // accumulate, and black is exactly what this pass would converge to. The
    // shadows toggle takes shafts with it (no map, no verdicts); saying so in
    // the gate stops this pass from reading black under a dead march.
    let sun = frame.sun_direction;
    let moon = frame.moon_direction;
    let night = clamp(-sun.y * 2.4, 0.0, 1.0);
    let moon_mode = sun.y < -0.02 && moon_shafts > 0.001 && moon.y > 0.02;
    let strength = god_rays * select(smoothstep(0.02, 0.12, sun.y),
                                     moon_shafts * 0.55 * night, moon_mode);
    let light = select(sun, moon, moon_mode);
    if god_rays <= 0.001 || frame.has_shadow == 0u || strength <= 0.001
        || abs(sun.y) <= 0.02
        || (sun.y < -0.02 && (moon.y <= 0.02 || moon_shafts <= 0.001)) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    // The march's per-cell angular bail, mirrored — pure ALU (ray dir + lobe,
    // zero texture reads), so it costs nothing to recompute instead of
    // accumulating black. Past the fan's reach the clamp box annihilates
    // history in one frame anyway; skipping the reads here keeps most of the
    // screen free when facing away from the light.
    let k = 0.68;
    let mu = dot(ray_dir(input.uv), light);
    let floor_ = pow((1.0 - k) / (1.0 + k), 3.0);
    let glow = (pow((1.0 - k) / max(1.0 - k * mu, 0.02), 3.0) - floor_) / (1.0 - floor_);
    if glow * strength < 0.0008 {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let cur = textureLoad(god_halo, vec2<i32>(input.pixel), 0).rgb;
    let depth = input.depth;
    // Where this cell's air column ends: the hit surface, or a far proxy for
    // sky. Direction-anchored sky content rides a fixed-direction point
    // through rotation exactly, and one frame of translation is nothing
    // against 400 blocks.
    let here = select(view_position(input.uv, depth),
                      ray_dir(input.uv) * 400.0, depth == 0.0);
    let clip = frame.previous_view_projection * vec4<f32>(here + frame.camera_motion, 1.0);
    let front = clip.w > 1.0e-3;
    let ndc = vec2<f32>(clip.x, clip.y) / max(abs(clip.w), 1.0e-3);
    let prev_uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    let on = front && all(prev_uv >= vec2<f32>(0.0)) && all(prev_uv <= vec2<f32>(1.0));
    // Blend and motion gate dt-normalized: the same time constant and the
    // same motion ceiling (21 blocks/s) at every frame rate. A per-frame
    // constant would strangle the history exactly on the frames that are
    // already struggling — the ones that need the denoise most.
    let dt = frame.delta_time;
    var keep = 0.78;
    if dt > 0.0 {
        keep = pow(0.78, dt * 60.0);
    }
    if frame.reset_reasons != 0u || dt <= 0.0
        || length(frame.camera_motion) > 21.0 * max(dt, 1.0e-3) || !on {
        keep = 0.0;
    }
    // A passthrough cell (reset, pause, fast move, off-screen) is raw truth;
    // it must not pay six reads to learn that.
    if keep <= 0.0 {
        return vec4<f32>(cur, 1.0);
    }
    var hist = textureSampleLevel(rays_hist_previous, linear_sampler,
                                  clamp(prev_uv, vec2<f32>(0.0), vec2<f32>(1.0)), 0.0).rgb;
    // NaN scrub: this is a feedback loop — one stray non-finite value would
    // live in the history forever through clamp and mix (downstream scrubs
    // the symptom out of the picture, not out of the texture).
    hist = select(hist, cur, hist != hist);
    // Cross box of this frame's shaft term (five loads, coords clamped to the
    // target's edges exactly like god_rays clamps its coverage taps — no
    // out-of-range load is ever issued; an edge cell just pays a hair of
    // duplicated texel). A shift beyond this box re-pins history to the box
    // edge for a few frames — the box's stated limit: it forfeits, never
    // ghosts.
    var mn = cur;
    var mx = cur;
    let px = vec2<i32>(input.pixel);
    let gd = vec2<i32>(textureDimensions(god_halo)) - vec2<i32>(1, 1);
    let o1 = textureLoad(god_halo, clamp(px + vec2<i32>(1, 0), vec2<i32>(0), gd), 0).rgb;
    let o2 = textureLoad(god_halo, clamp(px - vec2<i32>(1, 0), vec2<i32>(0), gd), 0).rgb;
    let o3 = textureLoad(god_halo, clamp(px + vec2<i32>(0, 1), vec2<i32>(0), gd), 0).rgb;
    let o4 = textureLoad(god_halo, clamp(px - vec2<i32>(0, 1), vec2<i32>(0), gd), 0).rgb;
    mn = min(min(mn, o1), min(o2, min(o3, o4)));
    mx = max(max(mx, o1), max(o2, max(o3, o4)));
    // A hair of absolute margin: a faint true beam is exactly what accumulation
    // exists to find, and a hard box would starve it toward one dark frame.
    mn = mn - vec3<f32>(0.004);
    mx = mx + vec3<f32>(0.004);
    hist = clamp(hist, mn, mx);
    // 22% fresh per 60fps frame: 0.78^14 = 3% residue — ~thirteen frames to
    // 96% at any frame rate, by construction.
    return vec4<f32>(mix(cur, hist, keep), 1.0);
}
