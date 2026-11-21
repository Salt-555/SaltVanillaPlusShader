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
    let d = normalize(input.direction);
    let sun = frame.sun_direction;
    let low = 1.0 - clamp(abs(sun.y) * 2.2, 0.0, 1.0);
    let horizon = pow(1.0 - clamp(abs(d.y), 0.0, 1.0), 3.0);
    let toward = pow(max(dot(d, sun), 0.0), 4.0);
    let warm = vec3<f32>(1.0, 0.52, 0.26);
    var c = input.color.rgb;
    c = mix(c, c * warm + warm * 0.05, horizon * low * 0.55 * sky_haze);
    c += warm * toward * low * 0.22 * sky_haze;
    // A tight inner halo on the sun's own disc (Mie's forward lobe, as a high exponent).
    c += warm * pow(max(dot(d, sun), 0.0), 24.0) * low * 0.06 * sky_haze;
    c += vec3<f32>(0.9, 0.95, 1.0) * pow(max(dot(d, sun), 0.0), 60.0) * (1.0 - low) * 0.05 * sky_haze;
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
            let band = pow(1.0 - clamp(abs(dot(d, normalize(vec3<f32>(0.42, 0.55, -0.66)))), 0.0, 1.0), 3.0);
            let dust = 0.5 * (vnoise(vec2<f32>(d.x * 6.0, d.y * 7.0))
                            + vnoise(vec2<f32>(d.z * 6.0, d.y * 7.0 + 3.0)));
            c += vec3<f32>(0.52, 0.58, 0.85) * band * (0.3 + 0.7 * dust) * clear * stars * 0.06;
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
            let az = atan2(d.z, d.x);
            let dz = az / 1.1;
            let wide = exp(-dz * dz);
            let height = smoothstep(0.015, 0.14, d.y) * smoothstep(0.72, 0.26, d.y);
            let fold = 0.5 * (vnoise(vec2<f32>(az * 7.0 + frame.time * 0.040, d.y * 3.2 - frame.time * 0.012))
                            + vnoise(vec2<f32>(az * 2.3 - frame.time * 0.017, d.y * 6.4)));
            let glow = wide * height * smoothstep(0.30, 0.92, fold) * clear * aurora;
            c += mix(vec3<f32>(0.16, 1.0, 0.42), vec3<f32>(0.58, 0.32, 1.0),
                     clamp((d.y - 0.10) / 0.38, 0.0, 1.0)) * glow * 0.4;
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
            c += vec3<f32>(0.72, 0.80, 1.0)
               * (pow(md, 140.0) * 0.30 + pow(md, 30.0) * 0.020
                  + pow(md, 12.0) * 0.028 + pow(md, 5.0) * 0.024
                  + pow(md, 2.0) * 0.014) * clear * moon_halo;
            let e = d.y / 0.055;
            let band = exp(-e * e) * (0.55 + 0.45 * vnoise(d.xz * 2.5
                                    + vec2<f32>(0.0, frame.time * 0.004)));
            c += vec3<f32>(0.42, 0.72, 0.58) * band * 0.030 * clear * moon_halo;
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
