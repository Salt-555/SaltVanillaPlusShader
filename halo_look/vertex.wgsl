// Wind. Plants bend about their sprite root; leaves sway as whole blocks. The manifest's
// [[materials]] map sprites to ids, and only the three wind ids (1 leaves, 2 plant, 3 vine)
// animate: every other id, including solid-block ids added for other stages like the ore
// glow's 8, returns untouched. Wind must never key on "nonzero" — it would wave solid blocks.
// The field is world-anchored (camera_position added) so gusts do not swim with the camera.
override wave_strength: f32 = 1.0;

const LEAVES: u32 = 1u;
const PLANT: u32 = 2u;
const VINE: u32 = 3u;

fn vertex(input: VertexInput) -> vec3<f32> {
    if wave_strength <= 0.001 {
        return input.position;
    }
    let kind = input.material;
    if kind == 0u || kind > 3u {
        // No table entry, or a solid-block id (ore glow's 8, the inert nether
        // 9): the wind knows only leaves, plants and vines. Pass through
        // before the wave math — the pass-through is also the skip.
        return input.position;
    }

    let world = input.position + frame.camera_position;
    let t = frame.time;
    // Two slow noise scales for gust and lull; three phase terms so neighbours slide past
    // each other in wind fronts instead of one coherent sine field.
    let gust = 0.45 + 0.85 * vnoise(world.xz * 0.012 + vec2<f32>(t * 0.055, -t * 0.041));
    let w1 = sin(world.x * 0.16 + world.z * 0.09 + t * 1.25);
    let w2 = sin(world.x * 0.053 - world.z * 0.061 + t * 0.51 + 2.1);
    let w3 = sin(world.z * 0.21 - world.x * 0.12 + t * 1.73 + 0.6);

    var amp: f32 = 0.0;
    var anchor: f32 = 1.0;                       // 0 at the root, 1 at the tip
    if kind == PLANT {
        amp = 0.085;
        // Sprites are named from the top left, so the root sits at uv.y 1.
        anchor = pow(1.0 - clamp(input.uv.y, 0.0, 1.0), 1.6);
    } else if kind == VINE {
        amp = 0.045;
        // Climers root at the bottom, droppers (weeping) at the top; split the difference
        // rather than guess the block, so every vine at least sways from somewhere fixed.
        anchor = 0.5 + 0.5 * (1.0 - clamp(input.uv.y, 0.0, 1.0));
    } else if kind == LEAVES {                   // leaves: the whole block, a little
        amp = 0.028;
    } else {
        // A solid-block id (the ore glow's 8, and any future one): the wind
        // knows only plants. Pass through untouched.
        return input.position;
    }
    amp = amp * (0.35 + gust) * wave_strength;
    let dx = (w1 * 0.6 + w2 * 0.4) * amp * anchor;
    let dz = (w3 * 0.55 + w2 * 0.45) * amp * 0.8 * anchor;
    // Tips draw down as they lean: the arc of a bent blade, not a shear.
    let dy = select(0.0, abs(w1) * anchor * 0.12, kind == PLANT);
    return input.position + vec3<f32>(dx, -dy, dz);
}
