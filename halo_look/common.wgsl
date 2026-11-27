// Shared by every stage of Halo Look. Linear light throughout: 1.0 is vanilla's white.
// No bindings and no entry points here; the prelude declares the stage's resources.

fn luma(c: vec3<f32>) -> f32 {
    return dot(c, frame.luminance);
}


// The shaft passes' forward-scatter constant, folded: k, its Schlick floor
// ((1-k)/(1+k))^3 and the renormalization 1/(1-floor_) as literals, shared by
// post/god_rays.wgsl and post/rays_accum.wgsl so the history's mirror of the
// march's bail can never drift. glow = w^3 * LOBE_C1 - LOBE_C0 for
// w = (1-k)/max(1-k*mu, 0.02); the floor subtraction that closes the lobe clean
// at mu = -1 is documented at its first use in the march.
const LOBE_K: f32 = 0.68;
const LOBE_C1: f32 = 1.0069587230682373;
const LOBE_C0: f32 = 0.00695878965780139;

// The shaft history's blend weight: pow(0.78, dt*60) == exp2(dt * KEEP_K), the
// dt-normalized 22%-fresh-per-60fps-frame keep (same time constant at any frame
// rate); the constant is 60*log2(0.78) in f32.
const KEEP_K: f32 = -21.507238388061523;

// Schlick's Fresnel, the share of light a surface mirrors at a grazing angle.
fn fresnel_schlick(cos_t: f32, f0: f32) -> f32 {
    let m = clamp(1.0 - cos_t, 0.0, 1.0);
    let m2 = m * m;
    return f0 + (1.0 - f0) * m2 * m2 * m;
}

// Largest component of a vector (a vec3's "any strength").
fn max3(v: vec3<f32>) -> f32 { return max(v.x, max(v.y, v.z)); }

// Blinn-Phong highlight, roughness as a perceptual smoothness (LabPBR's r).
fn shine(n: vec3<f32>, l: vec3<f32>, v: vec3<f32>, smoothness: f32) -> f32 {
    let rough = (1.0 - smoothness) * (1.0 - smoothness);
    let h = normalize(l + v);
    let power = 2.0 / max(rough * rough, 1e-4);
    return pow(max(dot(n, h), 0.0), min(power, 4096.0)) * max(dot(n, l), 0.0);
}

// A normal map's tangent-space normal into world axes.
fn mapped_normal(n: vec3<f32>, tangent: vec4<f32>, nm: vec4<f32>) -> vec3<f32> {
    let t = normalize(tangent.xyz);
    let b = cross(n, t) * tangent.w;
    // LabPBR: rg carry the normal (green along `b`, down the texture, matching
    // the engine's tangent frame); blue is ambient occlusion and alpha is the
    // height, so z is RECONSTRUCTED, never read off blue. Reading blue as z
    // tilted occluded texels' normals toward the tangent plane.
    let xy = nm.xy * 2.0 - 1.0;
    let tn = vec3<f32>(xy.x, xy.y, max(sqrt(max(1.0 - dot(xy, xy), 0.0)), 0.05));
    return normalize(t * tn.x + b * tn.y + n * tn.z);
}

// Camera-relative world position of a screen point at a reversed depth. The post prelude
// gives this as view_position; material does not, so it is rebuilt from the same matrices.
fn world_at(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let clip = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let v = frame.projection_inverse * clip;
    return (frame.view_inverse * vec4<f32>(v.xyz / v.w, 0.0)).xyz;
}

// The sky along a reflected ray: horizon colour to zenith, for water with no mirror bound.
fn sky_gradient(r: vec3<f32>) -> vec3<f32> {
    return mix(frame.fog_color, frame.sky_color, pow(clamp(r.y, 0.0, 1.0), 0.5));
}

// Value noise on an integer lattice with a bit-mixing hash. Exact u32 arithmetic, so it is
// stable at any world coordinate: the fract(sin(x)*43758.5453) family loses precision once
// its argument reaches a few thousand radians, which at a few hundred blocks out re-rolls
// the pattern on every camera move. u32 multiply wraps by definition in WGSL, and a negative
// i32 cast to u32 is two's complement, so the lattice is deterministic in every direction.
// One seed multiply-pair is shared by the four lattice corners: in this wrapping ring the
// x+1 and y+1 corners' seeds are the base plus the two constants, which is exact, and the
// pack's hottest shared helper stops paying four multiply-pairs for one (0.16.42).
fn hash2_tail(n: u32) -> f32 {
    var h = (n ^ (n >> 13u)) * 1274126177u;
    h = h ^ (h >> 16u);
    return f32(h) * (1.0 / 4294967295.0);
}

// Smooth aperiodic noise, 0..1. Four hashes and a smoothstep interpolation, no trig.
fn vnoise(p: vec2<f32>) -> f32 {
    let i = vec2<i32>(floor(p));
    let f = p - vec2<f32>(i);
    let u = f * f * (3.0 - 2.0 * f);
    let n = u32(i.x) * 374761393u + u32(i.y) * 668265263u;
    let a = hash2_tail(n);
    let b = hash2_tail(n + 374761393u);
    let c = hash2_tail(n + 668265263u);
    let d = hash2_tail(n + 1043026656u);   // 374761393 + 668265263
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// The spectrum's seven sample points, folded to module tables. var<private>,
// NOT const: the API doc's warning is explicit — a runtime-indexed read of a
// module-level const array re-stores the whole array to a temporary on every
// loop turn on Vulkan. The sea's consumer (material.wgsl's wave_field) reads
// these tables by literal index, hand-unrolled, so the spill never fires; every
// module array in the pack is one of these, and the module consts that remain
// are scalars, which cannot spill.
// WF_OMEGA, WF_PULSE, WF_SWAYP, WF_LIFER and WF_LIFEP are read only by the
// pre/wave_clock.wgsl pass — they parameterize the frame-constant folds (travel
// angle, life envelope, breathing sway) it hands the fragment stage raw.
// Values are identical; only the storage class moves. The fine end of the
// spectrum is NOT here by design: it is the two tileable ripple normal maps in
// material.wgsl's detail layer, which buy finer structure for two filtered fetches
// and stay out of the distance-shimmer band live high-k waves would enter. Every
// quantity of the spectrum except the live heading, the phases and the life sines
// is a function of the component index alone: the wavenumber cascade, each
// bearing's fixed angle off the wind, the deep-water dispersion, the life-cycle rates.
// Travel rates, rad/s: deep-water dispersion — omega = sqrt(g k) with
// g = 1.74 blocks/s^2, so phase speed falls with the square root of wavenumber and
// the long swell visibly outruns the chop (2.7 down to 1.2 blocks/s along the cascade).
var<private> WF_OMEGA : array<f32, 7> = array<f32, 7>(
    0.6506943983, 0.7467409286, 0.8569645226, 0.9834578029, 1.1286222762, 1.2952139265,
    1.4863955378);
// Breathing rates, rad/s (periods ~36-65 s, pairwise irrational). Pure travel reads
// as a conveyor; pure standing-wave sway reads as dead water. This
// superposes both: each train's speed modulates around its travel rate — crests surge,
// ease, surge — and no two trains breathe together.
var<private> WF_PULSE : array<f32, 7> = array<f32, 7>(
    0.161, 0.119, 0.143, 0.097, 0.127, 0.173,
    0.107);
// Breathing amplitude, phase-radians. Tuned so Omega - SWAYP*PULSE stays positive for
// every train: the pulse modulates up to about 42% of a train's own speed and
// never cancels it. Flow always advances.
var<private> WF_SWAYP : array<f32, 7> = array<f32, 7>(
    1.7, 1.5, 1.8, 1.4, 1.6, 1.9,
    1.5);
var<private> WF_CC : array<f32, 7> = array<f32, 7>(       // cos of the component's fixed angle
    0.997185, 0.990509, 0.973976, 0.947210, 0.907777, 0.854459, 0.781520);
var<private> WF_CS : array<f32, 7> = array<f32, 7>(       // sin of it: one swell, narrow irrational fan
    -0.074979, 0.137445, -0.226651, 0.320613, -0.419452, 0.519519, -0.623880);
var<private> WF_K : array<f32, 7> = array<f32, 7>(        // the wavenumber cascade itself
    0.243, 0.320031, 0.421480827, 0.5550902492, 0.7310538581, 0.9627979312,
    1.2680048754);
var<private> WF_LIFER : array<f32, 7> = array<f32, 7>(    // life-cycle rate, and phase, per train
    0.019, 0.027303658, 0.024607316, 0.021910974, 0.019214632, 0.02751829,
    0.024821948);
var<private> WF_LIFEP : array<f32, 7> = array<f32, 7>(
    0.0, 2.39996, 4.79992, 7.19988, 9.59984, 11.9998,
    14.39976);
var<private> WF_STEEP : array<f32, 7> = array<f32, 7>(
    0.3, 0.331, 0.362, 0.393, 0.424, 0.455,
    0.486);
var<private> WF_SHORE : array<f32, 7> = array<f32, 7>(    // 1: long swell reads the shoreline
    1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0);

// Domain warp and live wind heading, shared by the swell and the ripple textures so
// both wander under the same hand. `bend` is fed the crest-wander slider (wave_bend).
fn wave_warp(q0: vec2<f32>, t: f32, bend: f32) -> vec2<f32> {
    let wx = vnoise(q0 * 0.016 + vec2<f32>(t * 0.020, -t * 0.013)) - 0.5;
    let wy = vnoise(q0 * 0.016 + vec2<f32>(31.7 - t * 0.017, 17.3 + t * 0.011)) - 0.5;
    return vec2<f32>(wx, wy) * bend * 3.0;
}

fn wind_heading(q0: vec2<f32>, t: f32) -> f32 {
    // Center bearing in world xz (+x east, +z south): this one number sets which way
    // the whole sea runs — swell fan, chop drift, boil advection, everything.
    // 0.523+pi, not 0.523: field checks at 4K showed the plain east-southeast run
    // reads backwards off the shore. Settled decision — do not re-flip it.
    return 0.523 + 3.14159 + 1.1 * (vnoise(q0 * 0.0043 + vec2<f32>(t * 0.0062, -t * 0.0041)) - 0.5);
}

// Integer hashes for the sky and for things that re-roll in time. They never seed a
// world-scale pattern on water (a cheap re-rolling hash tiles there, the pack's standing
// rule); for sky cells and time draws they are exact, cheap, and period-free.
// The avalanche tail both integer hashes share.
fn avalanche(x: u32) -> u32 {
    var h = (x ^ (x >> 16u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266648917u;
    return h ^ (h >> 16u);
}

fn h31(v: vec3<u32>) -> u32 {
    return avalanche(v.x * 19349663u + v.y * 96925573u + v.z * 14163547u);
}

fn h21(x: u32, y: u32) -> u32 {
    return avalanche(x * 19349663u + y * 96925573u);
}

fn unit(u: u32) -> f32 { return f32(u >> 8u) * (1.0 / 16777216.0); }

// Unit world direction of a pixel's view ray: the engine's own view_position
// recipe at the far plane (this engine's depth is reversed, so NDC z 0 is far),
// full matrix product — stays true however view bob or roll ride the projection.
// Shared by the shaft march and its history accumulator; reads only frame
// uniforms, so it compiles in every stage.
fn ray_dir(uv: vec2<f32>) -> vec3<f32> {
    let x_ndc = uv.x * 2.0 - 1.0;
    let y_ndc = 1.0 - uv.y * 2.0;
    let v = frame.projection_inverse * vec4<f32>(x_ndc, y_ndc, 0.0, 1.0);
    return normalize((frame.view_inverse * vec4<f32>(v.xyz / v.w, 0.0)).xyz);
}

// One storm's lightning: seven-second windows, each drawing its own lottery; an event is
// a two-stroke flicker - instant rise and ring-down, a second stroke about two beats late.
// The only input is frame.time, so every patch of sky brightens in the same instant —
// the trick to reading as weather instead of as an effect. The ground half of a storm
// is the engine's own bolt flash; the pack's lightning stays sky-shell only.
fn lightning(t: f32) -> f32 {
    let bin = floor(t * (1.0 / 7.0));
    let draw = unit(h21(u32(bin), 0xA17A1u));
    if draw < 0.42 {
        return 0.0;
    }
    let lt = t - bin * 7.0 - draw * 5.2;
    if lt < 0.0 || lt > 1.8 {
        return 0.0;
    }
    var f = exp(-lt * 5.5) * (0.55 + 0.45 * cos(lt * 21.0) * exp(-lt * 2.0));
    if lt > 0.55 {
        f += 0.6 * exp(-(lt - 0.55) * 7.0);
    }
    return clamp(f, 0.0, 1.5);
}

