// Shadow and contact shading at HALF the world's resolution, written to a side target the
// composite multiplies in. Both effects are local, so both are gated by distance and their
// reads skipped where they cannot show: the shadow map covers a square of shadow_distance
// half-side, and contact shading reaches 1.2 blocks. Past those, a pixel still pays its
// depth and surface reads and passes through unshaded.
override shadows: bool = true;
override shadow_softness: f32 = 0.0;
override contact_ao: f32 = 0.5;

fn post(input: PostInput) -> vec4<f32> {
    let white = vec4<f32>(1.0);
    let depth = depth_at(input.uv);
    if depth == 0.0 {
        return white;                              // the sky is never shaded
    }
    if !shadows && contact_ao <= 0.001 {
        return white;                              // both off: nothing to read
    }
    // scene_surface is the world's size, so map by uv, not by this target's pixel
    let s = surface_at(vec2<i32>(input.uv * frame.resolution));
    if !s.present {
        return white;                              // an entity, water or glass keeps its own light
    }
    let pos = view_position(input.uv, depth);
    let away = length(pos);
    let sky_part = clamp(s.data, 0.0, 1.0);        // the sky light the material stage stored
    var shade = vec3<f32>(1.0);

    // Past the map's square the comparison sampler clamps to its edge and invents shadow,
    // so fade out over the last quarter and skip the reads entirely beyond it.
    let ground = max(abs(pos.x), abs(pos.z));
    let shadow_fade = 1.0 - smoothstep(frame.shadow_distance * 0.75, frame.shadow_distance, ground);
    if shadows && frame.has_shadow == 1u && shadow_fade > 0.001 {
        let l = frame.light_direction;
        // A shadow attenuates the DIRECT sun, and a face edge-on to the light receives none.
        // Weighting by N.L instead of the sun's elevation is what stops shadow-map error being
        // painted onto block sides when the sun is overhead: those faces have no sun in them to
        // shadow, and they are also edge-on to the shadow camera, where its depth is worst.
        let cos_a = clamp(dot(s.normal, l), 0.0, 1.0);
        // The caster's own elevation rides the strength: a body crossing the
        // horizon dims the shade over its last degrees instead of deleting a
        // frame's worth of it (a hard l.y gate relit a squared-up face in one step).
        let strength = sky_part * cos_a * shadow_fade * clamp(l.y * 20.0, 0.0, 1.0);
        if strength > 0.002 {
            // The Witness's bias law: the normal offset scales with sin(alpha), the offset along
            // the light with tan(alpha) clamped to 2. Both in world blocks, so shadow_position
            // does the projection and we never have to guess the map's depth scale. A constant
            // bias is what let the side faces acne: they need a much larger one than the floor.
            let sin_a = sqrt(max(1.0 - cos_a * cos_a, 0.0));
            let tan_a = min(sin_a / max(cos_a, 1e-3), 2.0);
            let texel = max(frame.shadow_center_texel, 0.01);
            let off_n = texel * (0.5 + 1.5 * sin_a);
            let off_l = texel * (0.5 + 1.5 * tan_a);
            let p = shadow_position(pos + s.normal * off_n + l * off_l);
            // the comparison sampler already filters 2x2; this is one read
            var lit = textureSampleCompareLevel(shadow_map, shadow_sampler, p.xy, p.z);
            if shadow_softness > 0.0 {
                let r = (1.0 + away * 0.02) * shadow_softness / max(frame.shadow_resolution, 1.0);
                lit += textureSampleCompareLevel(shadow_map, shadow_sampler, p.xy + vec2<f32>(r, r * 0.5), p.z);
                lit += textureSampleCompareLevel(shadow_map, shadow_sampler, p.xy + vec2<f32>(-r, r * 0.5), p.z);
                lit += textureSampleCompareLevel(shadow_map, shadow_sampler, p.xy + vec2<f32>(0.0, -r), p.z);
                lit *= 0.25;
            }
            shade *= mix(1.0, mix(0.42, 1.0, lit), strength);

            // light that passed through water or stained glass: reuse `lit` as the solid
            // test instead of reading the solid map a second time
            if lit > 0.5 {
                let trans_lit = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, p.xy, p.z);
                if trans_lit < 0.5 {
                    let dim = vec2<f32>(textureDimensions(shadow_color));
                    let sc = textureLoad(shadow_color, vec2<i32>(p.xy * dim), 0);
                    shade *= mix(vec3<f32>(1.0), sc.rgb, clamp(sc.a, 0.0, 1.0) * strength);
                }
            }
        }
    }

    // Contact shading is a 1.2-block effect: past about 40 blocks it is sub-pixel, so fade
    // it out and skip its reads on the distant majority of the screen. Six taps; cutting to
    // four buys an unmeasurable 0.001 ms at coarser occlusion.
    let ao_fade = 1.0 - smoothstep(32.0, 40.0, away);
    if contact_ao > 0.001 && ao_fade > 0.001 {
        let dsize = vec2<f32>(textureDimensions(scene_depth));
        let ring = clamp(24.0 / max(away, 0.5), 2.0, 16.0) / dsize;
        var occ = 0.0;
        for (var i = 0; i < 6; i++) {
            let a = f32(i) * 1.0471976;
            let suv = clamp(input.uv + vec2<f32>(cos(a), sin(a)) * ring, vec2<f32>(0.0), vec2<f32>(1.0));
            let sd = textureLoad(scene_depth, vec2<i32>(suv * dsize), 0);
            if sd != 0.0 {
                let d = view_position(suv, sd) - pos;
                let dist = length(d);
                if dist > 0.001 {
                    occ += clamp(dot(s.normal, d / dist) - 0.15, 0.0, 1.0)
                         * clamp(1.0 - dist / 1.2, 0.0, 1.0);
                }
            }
        }
        shade *= 1.0 - clamp(occ / 6.0, 0.0, 1.0) * contact_ao * 0.65 * ao_fade;
    }

    return vec4<f32>(clamp(shade, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
