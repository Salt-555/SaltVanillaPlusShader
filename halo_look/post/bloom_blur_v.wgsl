// Separable bloom blur, vertical leg: finishes what the horizontal leg started, reading
// its glow_h target so the pair is one 7x7 product blur at two 7-tap costs. Normalising
// each leg by its own weight sum keeps the pair's total energy constant. The texel
// size below hard-codes this pass's manifest scale of 0.25.
fn post(input: PostInput) -> vec4<f32> {
    let px = 1.0 / (frame.resolution * 0.25);
    var sum = vec3<f32>(0.0);
    var weights = 0.0;
    for (var i = -3; i <= 3; i++) {
        let fi = f32(i);
        let w = 1.0 / (1.0 + fi * fi * 0.55);
        sum += textureSampleLevel(glow_h, linear_sampler,
                                  input.uv + vec2<f32>(0.0, px.y * fi), 0.0).rgb * w;
        weights += w;
    }
    return vec4<f32>(sum / max(weights, 1e-4), 1.0);
}
