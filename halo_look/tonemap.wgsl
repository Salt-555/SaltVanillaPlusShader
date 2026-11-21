// The filmic curve: the ACES RRT-and-ODT fit everybody ships in real time (Narkowicz 2015,
// https://therealmjp.github.io/posts/aces-tonemap/). Declaring [tonemap] hands the curve to
// the pack: without it Horizon maps SDR by clipping at white, which is where the flat,
// blown-out look of the sun on snow comes from. Paper white stays near 1.0 (gain nudges it
// above the curve's toe); everything above rolls off into it instead of slamming into it.
fn aces(x: vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn tonemap(input: TonemapInput) -> vec3<f32> {
    // Linear light in, 1.0 at paper white. SDR (headroom 1) gets the plain curve; an HDR
    // output works the same curve in units of its peak so the shoulder reaches the display.
    let h = max(frame.headroom, 1.0);
    let gain = 1.45 / h;
    return aces(max(input.color, vec3<f32>(0.0)) * gain) * h;
}
