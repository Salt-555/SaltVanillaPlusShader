// The bloom's bright pass: four-tap downsample and a normalised soft knee at white.
override bloom: f32 = 0.4;

fn post(input: PostInput) -> vec4<f32> {
    if bloom <= 0.0 {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let px = 1.0 / frame.resolution;
    var c = textureSampleLevel(scene_color, linear_sampler, input.uv + vec2<f32>(-1.0, -1.0) * px, 0.0).rgb;
    c += textureSampleLevel(scene_color, linear_sampler, input.uv + vec2<f32>(1.0, -1.0) * px, 0.0).rgb;
    c += textureSampleLevel(scene_color, linear_sampler, input.uv + vec2<f32>(-1.0, 1.0) * px, 0.0).rgb;
    c += textureSampleLevel(scene_color, linear_sampler, input.uv + vec2<f32>(1.0, 1.0) * px, 0.0).rgb;
    c *= 0.25;
    let l = luma(c);
    let knee = 1.0;
    let soft = clamp(l - knee + 0.5, 0.0, 1.0);
    let w = max(l - knee, soft * soft * 0.5) / max(l, 1e-4);
    let sky = select(1.0, 0.3, depth_at(input.uv) == 0.0);
    return vec4<f32>(c * w * bloom * sky, 1.0);
}
