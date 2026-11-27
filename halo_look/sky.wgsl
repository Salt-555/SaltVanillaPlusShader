// The sky along each view ray: vanilla's colour plus horizon scatter and a deeper zenith.
override sky_haze: f32 = 1.0;
override stars: f32 = 1.0;
override aurora: f32 = 0.8;
override storm: f32 = 1.0;
override moon_halo: f32 = 1.0;

fn sky(input: SkyInput) -> vec4<f32> {
    // sky_haze rides its own terms below (every scatter term multiplies it),
    // and there is deliberately NO early return here: one silenced stars,
    // aurora, the moon halo and lightning too, which each have their own
    // slider — and it silenced the rain grey-out further down, which is
    // frame.rain's to own, not the haze slider's, at every haze value.
    let d = input.direction;   // the engine hands this unit (docs 0.2 "Unit view ray";
                               // both engine sky entries normalize before calling), so a
                               // second per-pixel normalize only divided by 1±ulp (0.16.42).
    let sun = frame.sun_direction;
    let low = 1.0 - clamp(abs(sun.y) * 2.2, 0.0, 1.0);
    let warm = vec3<f32>(1.0, 0.52, 0.26);
    var c = input.color.rgb;
    // Integer-exponent pows are guarded powf call sequences where naga stops; these
    // chains are what they evaluated to, as plain multiplies (0.16.42). The 60-power
    // serves every pixel (it is at FULL strength when low == 0), hence lives outside
    // the gate below.
    let dsun = max(dot(d, sun), 0.0);
    let ds2 = dsun * dsun;
    let ds4 = ds2 * ds2;
    let ds8 = ds4 * ds4;
    let ds16 = ds8 * ds8;
    let ds32 = ds16 * ds16;
    // The whole warm-scatter chain multiplies by low, which is EXACTLY 0.0 at every
    // midday hour and all of deep night — gated, not multiplied, since nothing below
    // the gate feeds anything else (0.16.42).
    if low > 0.0 {
        let hb = 1.0 - clamp(abs(d.y), 0.0, 1.0);
        c = mix(c, c * warm + warm * 0.05, hb * hb * hb * low * 0.55 * sky_haze);
        c += warm * ds4 * low * 0.22 * sky_haze;
        // A tight inner halo on the sun's own disc (Mie's forward lobe, as a high exponent).
        c += warm * (ds16 * ds8) * low * 0.06 * sky_haze;
    }
    c += vec3<f32>(0.9, 0.95, 1.0) * (ds32 * ds16 * ds8 * ds4) * (1.0 - low) * 0.05 * sky_haze;
    let zenith = pow(clamp(d.y, 0.0, 1.0), 0.6);
    c = mix(c, c * vec3<f32>(0.86, 0.93, 1.06), zenith * 0.35 * sky_haze);
    c = mix(c, vec3<f32>(luma(c)) * vec3<f32>(0.95, 0.97, 1.0), frame.rain * 0.45);

    // Night sky life: stars, the galaxy's dust band, aurora curtains. All of it rides the
    // ray direction, so it is pinned to the world's sphere (turn your head, the stars
    // hold), and it costs a handful of integer hashes on sky pixels only. Rain sheets
    // it out, because a starry sky over a rainstorm is a lie anyway.
    let night = clamp(-frame.sun_direction.y * 2.4, 0.0, 1.0);
    let clear = night * (1.0 - frame.rain * 0.92);
    if clear > 0.003 {
        if stars > 0.0 {
            let cell = floor(d * 240.0);
            let cu = vec3<u32>(vec3<i32>(cell));
            let hs = unit(h31(cu));
            if hs > 0.9972 {
                // the hash is the magnitude and the colour; brightness is FIXED per
                // star — no twinkle, the sky holds still like a sky should
                let mag = (hs - 0.9972) * (1.0 / 0.0028);
                let brt = 0.72 + 0.28 * unit(h31(cu + 11u));
                let tint = mix(vec3<f32>(0.82, 0.88, 1.0), vec3<f32>(1.0, 0.82, 0.62), unit(h31(cu + 5u)));
                c += tint * pow(mag, 1.6) * brt * clear * stars * 0.55;
            }
            // The Milky Way: one dust band along a fixed tilted axis. Its stars are too
            // dense to resolve individually, so it is noise, not points. The dust samples
            // direction components, not atan2 — an azimuth key seams where the angle wraps.
            let hb = 1.0 - clamp(abs(dot(d, normalize(vec3<f32>(0.42, 0.55, -0.66)))), 0.0, 1.0);
            let band = hb * hb * hb;
            // Two caps around the band's poles (|dot| > 0.785) bound the whole dust
            // term under one 8-bit display step, so both noises skip there (0.16.42).
            if band > 0.01 {
                let dust = 0.5 * (vnoise(vec2<f32>(d.x * 6.0, d.y * 7.0))
                                + vnoise(vec2<f32>(d.z * 6.0, d.y * 7.0 + 3.0)));
                c += vec3<f32>(0.52, 0.58, 0.85) * band * (0.3 + 0.7 * dust) * clear * stars * 0.06;
            }
        }
        if aurora > 0.0 {
            // One curtain hung along the x meridian (azimuth 0) — deliberately off the
            // z meridian the sun walks, so it never lines up with the sun's path. The
            // width falls off as a Gaussian in azimuth: at the atan2 wrap (az = ±pi) it
            // is 3e-4, so the wrap can never show a seam. The fold is two noise looks
            // on continuous coordinates, drifting slowly, and the brightness ramps
            // gently across the noise — wisps, not patches. Green at its feet, violet
            // in its rises. (Squared term on purpose: pow() with a possibly-negative
            // base is undefined in WGSL - multiply it out.)
            let height = smoothstep(0.015, 0.14, d.y) * smoothstep(0.72, 0.26, d.y);
            // Outside the height window (~2/3 of the sphere, screen-coherent bands)
            // the curtain adds exactly +0.0: the atan2, the Gaussian and both noise
            // folds gate on it (0.16.42).
            if height > 0.0 {
                let az = atan2(d.z, d.x);
                let dz = az / 1.1;
                let wide = exp(-dz * dz);
                let fold = 0.5 * (vnoise(vec2<f32>(az * 7.0 + frame.time * 0.040, d.y * 3.2 - frame.time * 0.012))
                                + vnoise(vec2<f32>(az * 2.3 - frame.time * 0.017, d.y * 6.4)));
                let glow = wide * height * smoothstep(0.30, 0.92, fold) * clear * aurora;
                c += mix(vec3<f32>(0.16, 1.0, 0.42), vec3<f32>(0.58, 0.32, 1.0),
                         clamp((d.y - 0.10) / 0.38, 0.0, 1.0)) * glow * 0.4;
            }
        }
        if moon_halo > 0.0 {
            // The moon's own coronet: a tight glass-disc gleam plus a wide soft lobe,
            // the night mirror of the sun's Mie halo — and one breath of airglow, the
            // faint green line real clear nights keep along the horizon. Rides the
            // engine's real moon vector: a new moon sits below the horizon and the
            // dot product can never light the sky for it.
            let moon = frame.moon_direction;
            let md = max(dot(d, moon), 0.0);
            // A graded cascade of lobes: five powers, 140/30/12/5/2, each paying
            // a slice of the angle range — same peak, same total, no single band
            // owning the falloff (one dominant band carves a visible rim at its
            // half-angle), and the dome closes smoothly toward the horizon.
            // Half the sphere faces away from the moon, where md is exactly 0.0 and
            // the cascade adds +0.0 — gated; and the five lobes share one log2 for
            // their two wide powers, three of them plain multiply chains (0.16.42).
            // The five lobes themselves are the settled rim-free design, untouched.
            if md > 0.0 {
                let m2 = md * md;
                let m4 = m2 * m2;
                let m12 = m4 * m4 * m4;
                let lm = log2(md);
                c += vec3<f32>(0.72, 0.80, 1.0)
                   * (exp2(lm * 140.0) * 0.30 + exp2(lm * 30.0) * 0.020
                      + m12 * 0.028 + (m4 * md) * 0.024
                      + m2 * 0.014) * clear * moon_halo;
            }
            // Airglow: |d.y| >= 0.16 puts the Gaussian near e^-8.5, so the whole
            // term sits ~300x under one display step there and the vnoise is
            // invisible (0.16.42).
            if abs(d.y) < 0.16 {
                let e = d.y / 0.055;
                let ag = exp(-e * e) * (0.55 + 0.45 * vnoise(d.xz * 2.5
                                        + vec2<f32>(0.0, frame.time * 0.004)));
                c += vec3<f32>(0.42, 0.72, 0.58) * ag * 0.030 * clear * moon_halo;
            }
        }
    }
    if frame.rain > 0.01 && storm > 0.0 {
        // Lightning inside the clouds: the flash brightens the whole sky shell, harder
        // when the sun cannot compete with it.
        let flash = lightning(frame.time) * frame.rain * storm;
        c += vec3<f32>(0.68, 0.74, 1.0) * flash * (0.32 + 0.5 * night) * 0.5;
    }

    return vec4<f32>(max(c, vec3<f32>(0.0)), input.color.a);
}
