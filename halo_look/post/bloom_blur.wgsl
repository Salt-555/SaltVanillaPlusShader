// Separable bloom blur, horizontal leg: one 7x7 product kernel in two legs of 7 reads
// (vertical leg: post/bloom_blur_v.wgsl), a 71% fetch cut over a single wide kernel,
// whose weight difference shows only at the +/-45 degree corners of a halo nobody
// looks at directly. Merging the bright pass into this one stays forbidden: merged
// taps re-read the FULL-SIZE scene_color. Fewer passes is not fewer fetches. The
// texel size below hard-codes this pass's manifest scale of 0.25 — move them
// together if the scale ever changes.
//
// The weights are the loop's own arithmetic (w = 1/(1 + i*i*0.55) over i = -3..3,
// accumulated in loop order in exact f32) folded to literals — including the
// constant the max(weights, 1e-4) divisor settled on — so each leg pays one divide
// per pixel instead of one per tap. Strength reduction, not a re-tune: recompute
// the literals with it if the kernel ever changes (0.16.42).
fn post(input: PostInput) -> vec4<f32> {
    let px = 1.0 / (frame.resolution * 0.25);
    var sum = textureSampleLevel(glow_buf, linear_sampler,
                                 input.uv + vec2<f32>(px.x * -3.0, 0.0), 0.0).rgb * 0.16806721687316895;
    sum += textureSampleLevel(glow_buf, linear_sampler,
                               input.uv + vec2<f32>(px.x * -2.0, 0.0), 0.0).rgb * 0.3125;
    sum += textureSampleLevel(glow_buf, linear_sampler,
                               input.uv + vec2<f32>(px.x * -1.0, 0.0), 0.0).rgb * 0.6451613306999207;
    sum += textureSampleLevel(glow_buf, linear_sampler, input.uv, 0.0).rgb;
    sum += textureSampleLevel(glow_buf, linear_sampler,
                               input.uv + vec2<f32>(px.x * 1.0, 0.0), 0.0).rgb * 0.6451613306999207;
    sum += textureSampleLevel(glow_buf, linear_sampler,
                               input.uv + vec2<f32>(px.x * 2.0, 0.0), 0.0).rgb * 0.3125;
    sum += textureSampleLevel(glow_buf, linear_sampler,
                               input.uv + vec2<f32>(px.x * 3.0, 0.0), 0.0).rgb * 0.16806721687316895;
    return vec4<f32>(sum / 3.2514572143554688, 1.0);
}
