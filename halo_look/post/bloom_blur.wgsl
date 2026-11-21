// Separable bloom blur, horizontal leg: one 7x7 product kernel in two legs of 7 reads
// (vertical leg: post/bloom_blur_v.wgsl), a 71% fetch cut over a single wide kernel,
// whose weight difference shows only at the +/-45 degree corners of a halo nobody
// looks at directly. Merging the bright pass into this one stays forbidden: merged
// taps re-read the FULL-SIZE scene_color. Fewer passes is not fewer fetches. The
// texel size below hard-codes this pass's manifest scale of 0.25 — move them
// together if the scale ever changes.
fn post(input: PostInput) -> vec4<f32> {
    let px = 1.0 / (frame.resolution * 0.25);
    var sum = vec3<f32>(0.0);
    var weights = 0.0;
    for (var i = -3; i <= 3; i++) {
        let fi = f32(i);
        let w = 1.0 / (1.0 + fi * fi * 0.55);
        sum += textureSampleLevel(glow_buf, linear_sampler,
                                  input.uv + vec2<f32>(px.x * fi, 0.0), 0.0).rgb * w;
        weights += w;
    }
    return vec4<f32>(sum / max(weights, 1e-4), 1.0);
}
