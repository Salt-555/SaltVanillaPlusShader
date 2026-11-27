// The wave clock: one invocation per frame folds every frame-constant term of the water
// spectrum out of the fragment hot seat. Twenty-two quarter-throughput transcendentals per
// water pixel were re-deriving sin(t*a+b) of the SAME t every fragment; here it is once.
// The buffer (manifest [[resource]] wave_clock, 29 f32 slots) is read by [material] reads;
// material.wgsl's wave_field and the ripple scroll consume it by literal slot:
//   0..6   ENV[i]     = 0.65 + 0.35 * sin(t*WF_LIFER[i] + WF_LIFEP[i])   (life envelope)
//   7..13  TRAVEL[i]  = t * WF_OMEGA[i]                                  (travel angle)
//   14..20 SWAYED[i]  = WF_SWAYP[i] * sin(t*WF_PULSE[i] + WF_LIFEP[i])   (breathing sway)
//   21..24 SCROLL     = the four ripple drift sums (oa1, oa2, ob1, ob2)
//   25..28 LINEAR     = the four ripple net-drift terms (t*0.030, t*0.008, t*0.022, t*0.009)
// Values are the fragment stage's own expressions, in the fragment stage's own operation
// order — the only freedom left is the driver's fma contraction, worth at most one ulp of
// the argument and invisible at any amplitude. The tables come from common.wgsl (shared).
fn compute(input: ComputeInput) {
    if !input.in_bounds {
        return;
    }
    let t = frame.time;
    for (var i: u32 = 0u; i < 7u; i = i + 1u) {
        wave_clock[i] = 0.65 + 0.35 * sin(t * WF_LIFER[i] + WF_LIFEP[i]);
        wave_clock[7u + i] = t * WF_OMEGA[i];
        wave_clock[14u + i] = WF_SWAYP[i] * sin(t * WF_PULSE[i] + WF_LIFEP[i]);
    }
    wave_clock[21u] = sin(t * 0.110) * 0.34 + sin(t * 0.043) * 0.18;
    wave_clock[22u] = sin(t * 0.090 + 1.3) * 0.30 + sin(t * 0.031 + 2.4) * 0.16;
    wave_clock[23u] = sin(t * 0.083 + 2.1) * 0.30 + sin(t * 0.037 + 0.7) * 0.15;
    wave_clock[24u] = sin(t * 0.075 + 4.0) * 0.28 + sin(t * 0.029 + 5.1) * 0.14;
    wave_clock[25u] = t * 0.030;
    wave_clock[26u] = t * 0.008;
    wave_clock[27u] = t * 0.022;
    wave_clock[28u] = t * 0.009;
}
