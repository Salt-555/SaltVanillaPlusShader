// Separable bloom blur, vertical leg: finishes what the horizontal leg started, reading
// its glow_h target so the pair is one 7x7 product blur at two 7-tap costs. Normalising
// each leg by its own weight sum keeps the pair's total energy constant. The texel
// size below hard-codes this pass's manifest scale of 0.25; tap weights are the same
// folded loop constants documented in post/bloom_blur.wgsl.
//
// The shafts fold in here (0.16.42): post/rays_accum.wgsl runs ahead of this pass
// (manifest order) and rays_hist shares this attachment's quarter-res texel grid,
// so the shaft field arrives as a per-texel sum and composite pays ONE full-res
// sample for both additive fields instead of two. Bilinear filtering is linear —
// bilinear(glow) + bilinear(rays) is bilinear(glow + rays) at the same weights —
// and rays_accum writes exact zero wherever shafts are gated, so the bloom rides
// through untouched exactly as it did when composite added the black itself.
fn post(input: PostInput) -> vec4<f32> {
    let px = 1.0 / (frame.resolution * 0.25);
    var sum = textureSampleLevel(glow_h, linear_sampler,
                                 input.uv + vec2<f32>(0.0, px.y * -3.0), 0.0).rgb * 0.16806721687316895;
    sum += textureSampleLevel(glow_h, linear_sampler,
                               input.uv + vec2<f32>(0.0, px.y * -2.0), 0.0).rgb * 0.3125;
    sum += textureSampleLevel(glow_h, linear_sampler,
                               input.uv + vec2<f32>(0.0, px.y * -1.0), 0.0).rgb * 0.6451613306999207;
    sum += textureSampleLevel(glow_h, linear_sampler, input.uv, 0.0).rgb;
    sum += textureSampleLevel(glow_h, linear_sampler,
                               input.uv + vec2<f32>(0.0, px.y * 1.0), 0.0).rgb * 0.6451613306999207;
    sum += textureSampleLevel(glow_h, linear_sampler,
                               input.uv + vec2<f32>(0.0, px.y * 2.0), 0.0).rgb * 0.3125;
    sum += textureSampleLevel(glow_h, linear_sampler,
                               input.uv + vec2<f32>(0.0, px.y * 3.0), 0.0).rgb * 0.16806721687316895;
    let rays = textureLoad(rays_hist, vec2<i32>(input.pixel), 0).rgb;
    return vec4<f32>(sum / 3.2514572143554688 + rays, 1.0);
}
