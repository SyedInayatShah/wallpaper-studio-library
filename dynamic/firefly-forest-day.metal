// =====================================================================
//  Firefly Forest — ground-level night view into a clearing of an
//  old-growth fir forest. The moon sits out of frame (upper-left, in
//  front of the camera) so the fog is back-lit: shafts slant down
//  through canopy gaps, low ground fog drifts across the floor, and
//  ~64 fireflies drift on closed paths and pulse with staggered
//  rhythms.
//
//  Technique: 12 depth planes (2.4 .. 100 m) composited front to back.
//  Near planes carry hand-placed trunks with fissured bark + bump
//  shading, far planes are procedural fir silhouettes. Between planes
//  the fog volume (height haze + loop-safe ground fog) is integrated
//  with jittered sub-steps; moon light is shadowed by a canopy-gap
//  function projected along the moon direction (true volumetric god
//  rays). A thin-lens circle of confusion (focus ~12 m) softens near
//  silhouettes and bark, and fireflies bokeh accordingly. Fireflies
//  are composited inside the plane loop so they are occluded by trunks
//  and attenuated by fog physically.
// =====================================================================

constant float DEG = 0.017453292519943295;

constant float3 FF_RO    = float3(0.0, 1.42, 0.0);
// Camera heading. The world frame is x=east, y=up, z=south; the camera looks
// down -z, so rotating world vectors by FF_HEAD aims it roughly south-south-east:
// the morning sun comes through the canopy from the front-left (the same
// direction the moon sat in the night original) and evening light rakes in
// warm from the right.
constant float  FF_HEAD  = 2.79;
constant float  FF_PITCH = 4.0;
constant float  FF_FOV   = 50.0;
constant float  FF_HC    = 23.0;           // canopy shadow plane (m)
constant float  FF_SIGH  = 0.020;          // haze extinction at ground (1/m)
constant float  FF_HAZEH = 15.0;           // haze scale height
constant float  FF_SIGG  = 0.34;           // ground-fog peak extinction
constant float3 FF_MOONC = float3(0.66, 0.80, 1.00);

// Everything the lighting needs for the current instant, built once per pixel
// from ctx.sunDir / sunElevation / moonDir / moonIllum.
struct FFEnv {
    float3 L;        // unit vector toward the key light (sun by day, moon at night)
    float3 kc;       // key radiance: colour * irradiance
    float3 amb;      // ambient (sky) RADIANCE reaching the fog volume
    float3 ambS;     // ambient IRRADIANCE on a surface (~pi * radiance)
    float3 fogA;     // fog albedo
    float3 bounce;   // warm light bounced off the lit forest floor
    float3 fill;     // green light transmitted through the canopy (day)
    float3 leafA;    // foliage albedo
    float3 leafT;    // foliage transmission colour (backlit leaves)
    float  sigH;     // haze extinction at the ground
    float  sigG;     // ground-fog peak extinction
    float  hc;       // canopy plane height
    float  day;      // 0 = full night .. 1 = full day
    float  ffAmt;    // firefly visibility
    float  gap0;     // canopy openness away from the big holes
    float  dapple;   // strength of the fine sun-fleck field (day)
    float  rayB;     // volumetric in-scatter boost for the key light
    float  lowSun;   // 1 when the key is near the horizon (light comes sideways)
    float  fogK;     // skylight reaching the fog under a CLOSED canopy
    float  wind;     // seconds, drives canopy sway / fog drift
    float2 sway;     // canopy sway offset for this instant (precomputed)
    float  expo;
};
constant float3 FF_FFCOL = float3(0.86, 1.00, 0.30);   // firefly colour (mean)
constant float3 FF_FFWARM= float3(1.00, 0.80, 0.24);   // amber end of the range
constant float3 FF_FFCOOL= float3(0.60, 1.00, 0.34);   // green end of the range
constant float  FF_FFP   = 3200.0;                     // firefly power
constant float  FF_EXPO  = 1.45;
constant float  FF_FOCUS = 12.0;           // focus distance (m)
constant float  FF_APER  = 12.5;           // CoC px at 1600p for 1/m defocus

constant int   FF_NROW   = 7;
constant float FF_Z[12]   = { 2.4, 3.9, 6.0, 9.5, 15.0, 24.0, 38.0, 54.0, 72.0, 92.0, 110.0, 130.0 };
constant float FF_W[12]   = { 5.0, 4.5, 4.0, 3.9, 2.40, 2.15, 1.95, 1.9, 1.9, 1.9, 1.9, 1.9 };
constant float FF_DEN[12] = { 0.0, 0.0, 0.0, 0.0, 0.70, 0.80, 0.90, 0.92, 0.94, 0.96, 0.96, 0.96 };
// hand-placed near trunks: x, radius, lean, seed
constant float4 FF_NEAR[8] = {
    float4(-2.16, 0.46,  0.020, 1.0),
    float4( 2.62, 0.41, -0.015, 2.0),
    float4(-4.30, 0.38,  0.010, 3.0), float4( 5.70, 0.35, -0.020, 4.0),
    float4(-7.60, 0.40,  0.000, 5.0), float4(-2.90, 0.30,  0.030, 6.0),
    float4( 7.00, 0.36, -0.010, 7.0), float4(10.60, 0.30,  0.000, 8.0) };
constant int FF_NS[5] = { 0, 1, 2, 4, 8 };
// depth of each hand-placed trunk, for the contact shadow it casts on the floor
constant float FF_NZ[8] = { 2.4, 3.9, 6.0, 6.0, 9.5, 9.5, 9.5, 9.5 };
constant int FF_NFF = 28;

// ---------------------------------------------------------------- fast noise
// The canopy-gap, fog and tree-silhouette fields are evaluated tens of times
// per pixel, so they use a cheap float-hash value noise instead of the
// prelude's PCG gradient noise. Visually equivalent at these frequencies.
inline float ff_h2(float2 p) {
    float3 q = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}
inline float ff_vn(float2 p) {                       // value noise, ~[-1,1]
    float2 i = floor(p), f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = ff_h2(i),                b = ff_h2(i + float2(1.0, 0.0));
    float c = ff_h2(i + float2(0.0, 1.0)), d = ff_h2(i + float2(1.0, 1.0));
    return 2.0 * mix(mix(a, b, u.x), mix(c, d, u.x), u.y) - 1.0;
}
inline float4 ff_h4(float2 p) {                      // 4 decorrelated values
    float4 q = fract(float4(p.x, p.y, p.x, p.y) * float4(0.1031, 0.1030, 0.0973, 0.1099));
    q += dot(q, q.wzxy + 33.33);
    return fract((q.xxyz + q.yzzw) * q.zywx);
}
inline float ff_fbm2(float2 p) {                     // 2 octaves
    return 0.667 * ff_vn(p) + 0.333 * ff_vn(WS_ROT2 * p * 2.02 + float2(17.1, 3.7));
}

// ---------------------------------------------------------------- light
inline float ff_hg(float c, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(1.0 + gg - 2.0 * g * c, 1.5));
}
// canopy openness above the forest, sampled in the canopy plane (x, z)
inline float ff_gapWin(float2 xz) {
    float2 cq = (xz - float2(-20.0, -36.0)) * float2(0.62, 0.42);
    float2 cr = (xz - float2(-4.0, -30.0)) * float2(0.80, 0.55);
    return max(1.0 - smoothstep(1.0, 13.0, length(cq)),
               0.62 * (1.0 - smoothstep(0.5, 6.5, length(cr))));
}
inline float ff_gap(float2 xz, float hgt, thread const FFEnv &E, bool fine) {
    // the crowns sway, so the gaps -- and the shafts and floor dapples they
    // cast -- breathe slowly instead of standing still
    float2 sway = E.sway;
    xz += sway;
    float n1 = ff_vn(xz * 0.048 + float2(3.1, 7.7));            // broad boughs
    // the clutter layer shears with height, so a shaft is not a perfect prism
    float n2 = ff_vn(xz * 0.185 + float2(9.2, 1.3) + float2(0.021, -0.014) * hgt + sway * 0.8);
    // Main canopy opening, placed so its shafts land in the clearing ahead.
    float2 cq = (xz - float2(-20.0, -36.0)) * float2(0.62, 0.42);
    float pool = 1.0 - smoothstep(1.0, 13.0, length(cq));
    // a smaller second window, right of the first
    float2 cr = (xz - float2(-4.0, -30.0)) * float2(0.80, 0.55);
    float pool2 = 0.62 * (1.0 - smoothstep(0.5, 6.5, length(cr)));
    float sky = max(pool, pool2);
    float open  = smoothstep(-0.02, 0.38, n1) * (E.gap0 + (1.0 - E.gap0) * sky);
    float holes = smoothstep(0.28, 0.50, n2) * (E.gap0 * 1.15 + (1.0 - E.gap0 * 1.15) * sky);
    float g = max(open, holes);
    g = smoothstep(0.02, 0.62, g);                              // crisp shaft edges
    g = 0.012 + 0.988 * g * g;
    // Fine sun flecks: the thousands of small holes between needles and boughs.
    // These are what put moving coins of light on a real forest floor.
    if (fine && E.dapple > 0.01) {
        float2 dq = xz + float2(0.012, -0.009) * hgt;
        float d1 = ff_vn(dq * 0.79 + float2(4.2, 1.7) + sway * 1.5);
        float d2 = ff_vn(dq * 2.13 + float2(9.9, 2.4) - sway * 1.1);
        // a soft-ish threshold: too crisp and the value-noise lattice shows as
        // squared-off patches on the trunks when the sun is low
        float fl = smoothstep(0.04, 0.30, 0.66 * d1 + 0.52 * d2 + 0.10);
        g = max(g, E.dapple * fl * (0.62 + 0.38 * sky));
    }
    // turbulence along the shaft: the haze inside a beam is never uniform
    return g * (0.79 + 0.46 * smoothstep(-0.70, 0.70, n2));
}
// Ultra-cheap canopy openness for the fog volume: shafts are broad and soft,
// so one noise octave and the two sky windows are all they need.
inline float ff_gapV(float2 xz, float hgt, thread const FFEnv &E) {
    xz += E.sway;
    float n = ff_vn(xz * 0.115 + float2(9.2, 1.3) + float2(0.021, -0.014) * hgt);
    float2 cq = (xz - float2(-20.0, -36.0)) * float2(0.62, 0.42);
    float2 cr = (xz - float2(-4.0, -30.0)) * float2(0.80, 0.55);
    float sky = max(1.0 - smoothstep(1.0, 13.0, dot(cq, cq) * 0.14 + 0.2),
                    0.62 * (1.0 - smoothstep(0.5, 6.5, dot(cr, cr) * 0.30 + 0.1)));
    float g = smoothstep(0.10, 0.55, n) * (E.gap0 + (1.0 - E.gap0) * sky);
    g = smoothstep(0.02, 0.62, max(g, 0.85 * sky));
    return (0.012 + 0.988 * g * g) * (0.79 + 0.46 * smoothstep(-0.70, 0.70, n));
}
// direct moon-light factor at a point below the canopy (shadow + fog path)
inline float ff_key(float3 p, thread const FFEnv &E, bool fine = true) {
    float Ly = max(E.L.y, 0.12);
    float h = min(max(E.hc - p.y, 0.0) / Ly, 42.0);
    float2 q = p.xz + E.L.xz * h;
    float od = E.sigH * FF_HAZEH * (exp(-max(p.y, 0.0) / FF_HAZEH) - exp(-E.hc / FF_HAZEH)) / Ly;
    float g = ff_gap(q, p.y, E, fine);
    // low sun: the beam arrives between the trunks, broken into broad slabs
    if (E.lowSun > 0.012) {
        float2 ld = normalize(E.L.xz + float2(1e-4, 1e-4));
        float across = dot(p.xz, float2(-ld.y, ld.x));
        float along  = dot(p.xz, ld);
        float b1 = ff_vn(float2(across * 0.62, along * 0.045 + 5.3));
        float b2 = 0.5 * sin(across * 1.93 + along * 0.11 + b1 * 3.1);
        float lat = smoothstep(-0.26, 0.30, b1 + 0.62 * b2);
        lat = 0.055 + 0.945 * lat * lat;
        float bar = exp(-pow((across - 1.6 + 0.9 * b1) / 5.2, 2.0))
                  * (0.55 + 0.45 * smoothstep(-0.9, 0.6, b2));
        float bar2 = 0.55 * exp(-pow((across + 12.0 + 1.4 * b2) / 3.4, 2.0));
        lat = max(lat, 0.97 * max(bar, bar2));
        g = mix(g, lat, E.lowSun);
    }
    return g * exp(-0.6 * od);
}

// ---------------------------------------------------------------- fog
inline float ff_haze(float y, thread const FFEnv &E) { return E.sigH * exp(-max(y, 0.0) / FF_HAZEH); }
inline float ff_gfog(float3 p, thread const FFEnv &E) {
    if (E.sigG < 0.048) {                                 // clear day: no banks to shape
        float h0 = smoothstep(2.9, -0.15, p.y);
        return h0 <= 0.0 ? 0.0 : E.sigG * h0 * h0 * 0.55;
    }
    if (p.y > 5.2) return 0.0;
    float2 q = p.xz * 0.20 + float2(0.016, 0.006) * E.wind;   // drifting banks
    // The bank's upper surface undulates on a much longer wavelength than its
    // internal density, so the two scales are taken from one noise lookup and
    // a pair of slow sines rather than from two lookups.
    float big = 0.62 * sin(q.x * 0.31 + 1.7) + 0.48 * sin(q.y * 0.27 - 2.3)
              + 0.30 * sin((q.x - q.y) * 0.19 + 4.1);
    float h = smoothstep(2.25 + 1.30 * big, -0.15, p.y);
    if (h <= 0.0) return 0.0;
    float n = ff_vn(q);
    float dens = smoothstep(-0.50, 0.62, n + 0.55 * big + 0.12);
    float wisp = 0.5 + 0.5 * sin(7.5 * (q.x * 0.45 + q.y) + 6.5 * n + 3.0 * big);
    dens *= 0.58 + 0.70 * wisp * smoothstep(0.05, 0.85, dens);
    float lay = 0.50 + 0.50 * smoothstep(1.9 + 0.9 * big, 0.20, p.y);
    return E.sigG * h * h * lay * (0.08 + 0.92 * dens);
}

// integrate fog along the ray from s0 to s1 (front to back)
inline void ff_fogSeg(thread float3 &col, thread float &T, float3 ro, float3 rd, float s0, float s1,
                      thread const FFEnv &E, float jit, float phase) {
    float len = s1 - s0;
    if (len <= 1e-4) return;
    float stepLen = 0.95 + 0.42 * s0;
    int nmax = 1;
    int n = clamp(int(len / stepLen) + 1, 1, nmax);
    float ds = len / float(n);
    for (int i = 0; i < n; i++) {
        float jw = 0.70 * (1.0 - smoothstep(5.0, 22.0, len));
        float j = mix(0.5, fract(jit + float(i) * 0.6180339887), jw);   // decorrelated jitter
        float sm = s0 + ds * (float(i) + j);
        float3 p = ro + rd * sm;
        float bank = ff_vn(p.xz * 0.030 + float2(0.010, 0.004) * E.wind
                           + float2(0.0, p.y * 0.012));
        float sig = ff_haze(p.y, E) * (0.52 + 0.96 * (0.5 + 0.5 * bank)) + ff_gfog(p, E);
        float mn;
        if (sm < 26.0) {
            float Ly = max(E.L.y, 0.12);
            float hh = min(max(E.hc - p.y, 0.0) / Ly, 42.0);
            mn = mix(ff_gapV(p.xz + E.L.xz * hh, p.y, E), 0.52, E.lowSun);
        } else {
            mn = mix(0.42, 0.52, E.lowSun);
        }
        // the volume only sees sky through the canopy it sits under
        float3 light = E.kc * (phase * mn * E.rayB * (0.55 + 0.75 * (0.5 + 0.5 * bank)))
                     + E.amb * (E.fogK + (1.0 - E.fogK) * mn) + E.fill * 0.5;
        float3 alb = E.fogA;
        // colour-temperature drift across the volume: warmer inside a shaft,
        // cooler in the deep shade between the trunks
        alb *= mix(float3(0.93, 0.99, 1.06), float3(1.12, 1.02, 0.88),
                   smoothstep(0.08, 0.80, mn));
        float tr = exp(-sig * ds);
        col += T * alb * light * (1.0 - tr);
        T *= tr;
    }
}

// ---------------------------------------------------------------- fireflies
struct FFly { float3 pos; float bright; };
// A flier's depth band never changes, so it can be recovered from one cheap
// hash. The slab walk tests 40 fliers per depth plane; doing that with the
// full three hash44 evaluations was the single biggest night-time cost.
inline float ff_flyCZ(int i) {
    float hz = ff_h2(float2(float(i) + 0.5, 7.31));
    return i < 2  ? (1.28 + 0.62 * hz)
         : i < 18 ? (1.9 + 3.4 * hz)
                  : 3.2 * exp(hz * 2.32);
}
inline FFly ff_fly(int i, float t) {
    float fi = float(i) + 0.5;
    float4 h1 = hash44(float4(fi, 1.3, 2.7, 9.1));
    float4 h2 = hash44(float4(fi, 5.9, 7.3, 3.7));
    float4 h3 = hash44(float4(fi, 8.1, 0.4, 6.6));
    // three depth bands: two hero lights right under the lens (big bokeh
    // discs low in frame), a near group, and the scattered mid/far cloud
    bool hero = i < 2;
    bool near = i < 18;
    float cz = ff_flyCZ(i);                          // 1.0 .. 33 m
    // spread wider and biased left: the right third stays calm for icons
    float sx = h1.y - 0.56;
    float cx = sx * ((hero ? 3.4 : near ? 5.2 : 7.4) + 0.62 * cz);
    if (hero) cx = (h1.y < 0.5 ? -1.0 : 1.0) * (0.85 + 1.35 * h1.y);
    float cy = hero ? (0.86 + 0.52 * h1.z) : (0.24 + 3.30 * pow(h1.z, 1.75));
    cy *= 1.0 - 0.64 * smoothstep(0.5, 8.0, cx);       // keep the top-right calm
    int k2 = 2 + int(h2.w * 2.0);
    float a1 = TAU * (t + h2.x), a2 = TAU * (float(k2) * t + h2.y), a3 = TAU * (t + h2.z);
    float r1 = 0.45 + 0.75 * h3.x;
    float3 p = float3(cx, cy, -cz);
    p += float3(r1 * cos(a1), 0.35 * r1 * sin(a3), 0.7 * r1 * sin(a1));
    p += 0.2 * float3(sin(a2), 0.5 * cos(a2 + 1.0), cos(a2));
    // Blink: a slow ramp up, a held glow, a slower decay -- Photinus, not a
    // strobe. 4..8 flashes per orbit puts a pulse every 2.4 .. 4.8 s.
    int kp = 4 + int(h3.y * 4.0);
    float u = fract(float(kp) * t + h3.z);
    float on = 0.26 + 0.20 * h3.w;
    float env = smoothstep(0.0, 0.10, u) * (1.0 - smoothstep(on * 0.55, on + 0.30, u));
    env = env * env * (3.0 - 2.0 * env);
    // never fully off: a firefly at rest still carries a faint ember
    env = max(env, 0.055);
    FFly f; f.pos = p; f.bright = env * (0.55 + 1.15 * h1.w * h1.w) * (hero ? 1.45 : 1.0);
    return f;
}
inline float3 ff_glow(float2 dpx, float R, float flux, float3 fc, float mist) {
    float r2 = dot(dpx, dpx);
    float rmax = 46.0 + 6.0 * R;
    if (r2 > rmax * rmax) return float3(0.0);
    float r = sqrt(r2);
    // defocused disc with a slightly brighter rim (real bokeh); the disc edge
    // lands at a marginally different radius per channel — lens CA
    float soft = max(1.05, R * 0.38);
    float3 Rc = R * float3(1.022, 1.000, 0.980);
    float3 disc = float3(1.0) - smoothstep(Rc - soft, Rc + soft, float3(r));
    float rim  = R > 3.0 ? 1.0 + 0.34 * smoothstep(R * 0.52, R * 0.97, r) : 1.0;
    float3 core = flux / (PI * R * R + 2.6) * disc * rim;
    // bloom: a tight halo plus a wide veil, both rolled off with disc area so
    // a big near bokeh blooms softly instead of blowing out
    float a2 = R * R + 11.0;
    float amp = flux / (1.0 + R * R / 17.0);
    // In still night air a firefly is a hard point. In mist it lights the
    // droplets around it and becomes a small lantern in a cloud, so the halo
    // and the wide veil both scale with how thick the air is.
    float halo = amp * (0.0148 + 0.0150 * mist) / (1.0 + r2 / a2);
    float veil = amp * (0.0033 + 0.0072 * mist) / (1.0 + r2 / (a2 * 7.0));
    float fade = 1.0 - smoothstep(rmax * 0.42, rmax, r);
    return mix(fc, float3(1.0), 0.09) * core + fc * (halo + veil) * fade;
}
// per-firefly bioluminescent colour: amber .. yellow-green
inline float3 ff_flyCol(int i) {
    float h = hash12(float2(float(i) * 1.7 + 0.31, 12.77));
    return mix(FF_FFWARM, FF_FFCOOL, h * h);
}
// warm light from nearby fireflies on a surface. Only the near group is
// considered (the rest are too far to deposit light) and positions are
// recomputed rather than stored, to keep the per-thread stack tiny.
inline float3 ff_flyLight(float3 P, float3 n, float t, float amt) {
    if (amt <= 0.001) return float3(0.0);
    float3 acc = float3(0.0);
    const float R2 = 7.3;            // ~2.7 m of useful reach
    for (int i = 0; i < 8; i++) {
        // only fliers whose band can reach this point are worth unpacking
        if (abs(ff_flyCZ(i) + P.z) > 3.4) continue;
        FFly f = ff_fly(i, t);
        if (f.bright <= 0.004) continue;
        float3 d = f.pos - P;
        float d2 = dot(d, d);
        if (d2 > R2) continue;
        float3 dn = d * rsqrt(d2);
        float ndl = max(dot(n, dn), 0.0);
        // a lantern this close is an area source, not a point: wrap the
        // terminator so a leaf edge-on to it still catches something
        ndl = ndl * 0.82 + 0.18 * (0.5 + 0.5 * dot(n, dn));
        float fall = 1.0 - d2 / R2;
        acc += f.bright * ndl / (d2 + 0.16) * fall * fall;
    }
    return acc * FF_FFCOL * (0.175 * amt);
}

// ---------------------------------------------------------------- trunks
// fissured conifer bark: vertical ridges, broken plates, fine grain
// Fissure height only. This is the part that gets finite-differenced for the
// normal, so it is kept as cheap as a ridged multifractal can be; the slower
// plate and cross-check modulation below is evaluated once, for albedo.
inline float ff_barkH(float u, float y, float seed) {
    float lf = ff_vn(float2(u * 1.15 + seed * 2.0, y * 0.42 + seed));
    float2 q = float2(u * (11.0 + 3.6 * lf) + seed * 3.0, y * (3.4 + 0.9 * lf) + seed * 1.7);
    float r1 = 1.0 - abs(ff_vn(q));
    float r2 = 1.0 - abs(ff_vn(q * 2.07 + float2(5.3, 9.1)));
    return 0.68 * r1 * r1 + 0.32 * r2 * r2;                      // ridged multifractal
}
inline float ff_barkTex(float fis, float u, float y, float seed) {
    float cross = 1.0 - abs(sin(y * 6.3 + seed * 4.3 + 0.9 * sin(u * 2.4 + seed))
                            * 0.72 + 0.28 * sin(y * 15.7 + u * 1.1));
    float plate = ff_vn(float2(u * 3.4 + seed * 2.1, y * 0.85 + seed));
    float b = smoothstep(0.10, 0.80, fis * 0.95 + 0.30 * plate + 0.20);
    b *= 0.68 + 0.32 * smoothstep(0.30, 0.90, cross);
    return 0.34 + 0.66 * b;
}

// signed half-width of a trunk silhouette at height y (metres)
inline float ff_trunkW(float y, float r0, float seed) {
    float w = r0 * (1.0 - 0.012 * y) + r0 * 0.78 * exp(-max(y, 0.0) * 1.6);
    // cheap non-repeating wobble: two incommensurate sines beat a noise lookup
    w *= 1.0 + 0.036 * sin(y * 2.13 + seed * 5.0) + 0.022 * sin(y * 0.71 + seed * 2.7);
    return w;
}
// plate cracks: a ridge field gives the broken-plate look of old fir bark
inline float ff_barkPlate(float u, float y, float seed) {
    float r = 1.0 - abs(ff_vn(float2(u * 19.0 + seed * 2.3, y * 2.3 + seed * 3.1)));
    return 0.66 + 0.34 * smoothstep(0.30, 0.92, r);
}

inline float3 ff_trunkShade(float3 P, float nx, float w, float seed, float fp,
                            float t, thread const FFEnv &E, bool detail, float soft) {
    // damp conifer bark: grey-brown, a touch warmer where the sun reaches it
    float3 alb = mix(float3(0.205, 0.163, 0.122), float3(0.150, 0.116, 0.086), E.day);
    float2 sv = float2(ff_h2(float2(seed * 5.3 + 2.0, 1.7)), ff_h2(float2(seed * 2.9 + 8.0, 6.1)));
    alb *= (0.66 + 0.78 * sv.x * sv.x)
         * mix(float3(1.14, 0.99, 0.82), float3(0.84, 0.95, 1.10), sv.y);
    float nz = sqrt(max(1.0 - nx * nx, 0.0));
    float3 n = float3(nx, 0.0, nz);
    float sharp = 1.0 / (1.0 + 0.45 * soft);      // defocus softens micro contrast
    if (detail) {
        float u = asin(clamp(nx, -1.0, 1.0)) * w;
        float e = max(0.006, fp);
        float f0 = ff_barkH(u, P.y, seed);
        float f1 = ff_barkH(u + e, P.y, seed);
        float f2 = ff_barkH(u, P.y + e, seed);
        float3 tang = float3(nz, 0.0, -nx);
        float bump = 0.062 * sharp;
        n = normalize(n - tang * ((f1 - f0) / e) * bump
                        - float3(0.0, 1.0, 0.0) * ((f2 - f0) / e) * bump * 0.7);
        float b0 = ff_barkTex(f0, u, P.y, seed);
        float plate = 0.66 + 0.34 * smoothstep(0.24, 0.86, 1.0 - abs(f1 - f2) * 9.0);
        alb *= mix(1.0, (0.42 + 1.08 * b0) * plate, sharp);
        // moss / lichen low on the trunk, favouring the damp shaded side.
        // Only the bottom few metres can carry any, so skip the lookup above it.
        float mh = smoothstep(3.0, 0.3, P.y) * smoothstep(-0.1, 0.8, nx);
        if (mh > 0.01) {
            float moss = smoothstep(0.34, 0.70, ff_fbm2(float2(u * 2.2 + seed * 9.0, P.y * 1.3))) * mh;
            alb = mix(alb, float3(0.088, 0.112, 0.070), moss * 0.45 * sharp);
        }
    }
    float key = ff_key(P, E, fp < 0.0055);
    float ndl = max(dot(n, E.L), 0.0);
    // by day the bark takes the sun as a broad diffuse term; at night only a
    // narrow rim survives, so the exponent relaxes as the sun comes up
    float3 ralb = mix(alb, float3(ws_luma(alb)), 0.44 * (1.0 - 0.7 * E.day));
    float direct = mix(ndl * ndl, ndl, E.day);
    // and what little arrives is scattered, so it is less saturated than the
    // disc itself
    float3 kcT = mix(E.kc, float3(ws_luma(E.kc)) * float3(1.12, 1.00, 0.84),
                     0.55 * E.lowSun * E.day);
    float3 col = ralb * kcT * (mix(0.52, 0.62, E.day) * key * direct
                               * (1.0 - 0.80 * E.lowSun * E.day));
    // the trunk sees the sky dome and the lit fog around it
    // Under starlight and moonlight bark keeps almost no hue: desaturate the
    // ambient-lit body too, or the near trunks read as warm brown cardboard.
    float3 aalb = mix(float3(ws_luma(alb)) * float3(0.90, 0.97, 1.12), alb, 0.30 + 0.70 * E.day);
    // scotopic vision loses hue, not detail: deepen the fissures at night so
    // the near boles stay carved rather than going to flat plaster
    aalb *= mix(0.72, 1.0, E.day) * (1.0 + (1.0 - E.day) * 0.55
            * (ws_luma(alb) / max(ws_luma(float3(0.255, 0.203, 0.150)), 1e-3) - 1.0));
    float3 dome = E.ambS * mix(0.40, 0.26, E.day) + E.fill * 0.42 + E.kc * (0.006 + 0.016 * key);
    float ao = (0.30 + 0.70 * nz * nz) * (0.48 + 0.52 * smoothstep(-0.3, 3.6, P.y));
    // and the open side of the canopy lights one flank more than the other
    float3 skyDirXZ = normalize(float3(-0.55, 0.0, -0.84));
    ao *= 0.70 + 0.52 * max(dot(n, skyDirXZ), 0.0);
    col += aalb * dome * ao;
    // light bounced up off the sunlit floor warms the lower trunk
    col += alb * E.bounce * mix(0.34, 1.0, E.day) * (0.30 + 0.70 * nz)
         * exp(-max(P.y, 0.0) * mix(0.90, 0.55, E.day));
    // the lit fog behind the trunk wraps its edges — keeps the dark framing
    // trunks from reading as flat black cut-outs
    float edge = pow(abs(nx), 5.0);
    float3 rimc = mix(E.fogA, float3(1.0), 0.15);
    col += rimc * (ws_luma(E.amb) * mix(0.42, 0.26, E.day) + ws_luma(E.kc) * 0.030 * key) * edge
         * (0.35 + 0.65 * smoothstep(-0.3, 4.0, P.y));
    col += aalb * ff_flyLight(P, n, t, E.ffAmt);
    return col;
}

// fir silhouette half-width for procedural rows (tiers above branch height)
inline float ff_firW(float y, float r0, float Hb, float Ht, float4 h, float fp, float reach) {
    if (y >= Ht) return -0.05 - 0.30 * (y - Ht);        // soft, AA-able falloff
    // the bole tapers into the leader instead of stopping flat at the top
    float w = ff_trunkW(y, r0, h.x * 10.0) * (1.0 - smoothstep(max(Hb, Ht - 9.0), Ht, y));
    if (y > Hb && y < Ht) {
        float s = Ht - y;
        float taper = 0.092 * (0.75 + 0.5 * h.y);
        float env = taper * (s + 0.4) * (1.0 + 0.22 * h.z) * (0.80 + 0.45 * smoothstep(0.0, 14.0, s));
        env *= smoothstep(0.0, 0.55, s);                    // the tip comes to a point
        float sp = (0.7 + 0.5 * h.z);
        // whorls are not evenly spaced on a real fir
        float q = s / sp + h.w * 3.0 + 0.40 * sin(s * 0.41 + h.x * 40.0) + 0.24 * sin(s * 0.17 + h.y * 11.0);
        // Whorls must be C0 across the boundary. The old profile jumped from
        // ~0.7 back to 0.42 at every wrap, and since this modulates the
        // SILHOUETTE that step drew a horizontal comb down every distant fir.
        float n = floor(q), ph = fract(q);
        float phs = ph * ph * (3.0 - 2.0 * ph);
        float tier = 1.0;
        if (fp < sp * 0.62) {
            float Lb0 = 0.5 + 0.6 * ff_h2(float2(n,      h.y * 71.0 + h.x * 131.0));
            float Lb1 = 0.5 + 0.6 * ff_h2(float2(n + 1.0, h.y * 71.0 + h.x * 131.0));
            tier = mix(Lb0, Lb1, phs) * (0.62 + 0.38 * sin(PI * ph));
        }
        // These whorl and rag terms modulate the SILHOUETTE, so at 1 spp they
        // alias into horizontal combing the moment a crown is more than a few
        // metres away and sits against bright sky. Roll them off far earlier
        // than a shaded texture would need to -- a distant fir is a soft
        // triangular smudge in a real photograph, not a comb.
        float det = 1.0 - smoothstep(sp * 0.16, sp * 0.62, fp);
        float dB = 1.0 - smoothstep(0.006, 0.026, fp);      // ~7/m detail
        // Once a pixel is wider than the whorl pitch none of this survives
        // resampling, so skip the noise entirely rather than paying for a
        // value that gets multiplied by ~0. This is most of the far rows.
        float rag = 0.0;
        if (det * 0.42 + dB > 0.012) {
            rag = (1.0 + 0.55 * dB) * ff_vn(float2(s * 3.1 + h.z * 17.0, n * 0.37 + h.x * 9.0));
            float ragA = (0.10 + 0.30 * dB) * (0.55 + 0.75 * smoothstep(0.0, 12.0, s));
            env *= mix(0.90, tier, det * 0.42) + ragA * rag;
        } else {
            env *= 0.96;
        }
        // ragged, gradual crown base — no mushroom cap
        float base = smoothstep(Hb, Hb + 5.5, y);
        base *= 0.70 + 0.30 * smoothstep(-0.4, 0.5, sin(y * 0.83 + h.z * 51.0) * 0.8);
        env *= base;
        // saturate smoothly at the cell reach: a hard min() leaves a flat
        // vertical edge, which reads as a rectangle pasted on the sky
        float wsat = reach * (1.0 - exp(-max(env, 0.0) / max(reach, 1e-3)));
        float rg2 = ff_vn(float2(s * 1.35 + h.z * 31.0, h.x * 57.0 + 3.0));
        float rgd = 0.74 + 0.30 * rg2 + (0.10 + 0.16 * dB) * rag;
        w = max(w, wsat * rgd);
    } else if (y >= Ht) {
        w = -0.05 - 0.30 * (y - Ht);                        // soft, AA-able falloff
    }
    return w;
}

// ---------------------------------------------------------------- undergrowth
// One pinnate frond / blade: thin rachis with leaflets, drooping under gravity.
inline float ff_frond(float2 d, float ang, float L, float w0, float bend, float pinna) {
    float2 dir = float2(cos(ang), sin(ang));
    float u = dot(d, dir);
    float axial = max(-u, u - L);                 // distance outside the blade span
    if (axial > 0.25 * L + 0.05) return 1e3;
    float v = dot(d, float2(-dir.y, dir.x));
    float k = clamp(u / L, 0.0, 1.0);
    float vc = bend * L * (k * k * (0.55 + 0.45 * k));      // arcing rachis
    float dv = abs(v - vc);
    float rach = dv - (0.0035 + 0.0075 * L * (1.0 - 0.8 * k));
    if (pinna > 0.0) {
        // lanceolate blade, widest a third of the way out, with fine leaflets
        float shape = pow(1.0 - k, 0.58) * smoothstep(0.0, 0.08, k);
        float lobe = 0.52 + 0.48 * pow(abs(sin(u * pinna)), 0.5);
        return max(min(rach, dv - w0 * shape * lobe), axial);
    }
    float blade = w0 * (1.0 - k) * (0.25 + 0.75 * smoothstep(0.0, 0.10, k));
    return max(min(rach, dv - blade), axial);
}
// min signed distance of an undergrowth cell at (x, y); base at cell centre
// A pinnate frond: arching rachis with discrete leaflets swept toward the tip.
// Only the two leaflet pairs straddling the sample are evaluated.
inline float ff_pinnate(float2 d, float ang, float L, float lmax, float bend, float nlf, float det) {
    float2 dir = float2(cos(ang), sin(ang));
    float u = dot(d, dir);
    float axial = max(-u, u - L);                 // distance outside the frond span
    if (axial > 0.25 * L + 0.05) return 1e3;
    float v = dot(d, float2(-dir.y, dir.x));
    float k = clamp(u / L, 0.0, 1.0);
    float vc = bend * L * (k * k * (0.55 + 0.45 * k));
    // rachis; as the frond shrinks under a couple of pixels (det -> 0) the
    // pinnae dissolve into a solid blade so nothing aliases
    float solid = (1.0 - det) * lmax * 0.92 * pow(1.0 - k, 0.55) * smoothstep(0.0, 0.08, k);
    float dm = max(abs(v - vc) - (0.0026 + 0.0050 * L * (1.0 - 0.75 * k) + solid), axial);
    if (det <= 0.03) return dm;
    float sp = L / nlf;
    float base = floor(k * nlf);
    for (int m = 0; m <= 0; m++) {
        float mi = base + float(m);
        for (int sg = 0; sg < 2; sg++) {
            float sv = sg == 0 ? 1.0 : -1.0;
            float ku = (mi + (sg == 0 ? 0.20 : 0.62)) / nlf;    // sub-opposite pairs
            if (ku <= 0.025 || ku >= 0.99) continue;
            float2 hs = hash22(float2(mi * 2.0 + float(sg), nlf + bend * 13.0 + L * 29.0));
            float hl = hs.x, hj = hs.y;
            ku += (hj - 0.5) * 0.46 / nlf;                  // spacing is never even
            if (ku <= 0.025 || ku >= 0.99) continue;
            float uu = ku * L;
            float vv = bend * L * (ku * ku * (0.55 + 0.45 * ku));
            float slope = bend * (1.10 * ku + 1.35 * ku * ku);
            float lf = det * lmax * pow(1.0 - ku, 0.58) * smoothstep(0.0, 0.07, ku)
                     * (0.62 + 0.78 * hl * hl);             // length varies a lot
            float2 q = float2(u - uu, v - vv);
            if (dot(q, q) > (lf + 0.01) * (lf + 0.01)) continue;
            float2 tg = normalize(float2(1.0, slope));
            float2 nm = float2(-tg.y, tg.x);
            float2 ax = normalize(tg * (0.26 + 0.44 * hj) + nm * sv * (1.05 + 0.26 * hl));
            float tt = clamp(dot(q, ax), 0.0, lf);
            float rr = (0.34 + 0.16 * hj) * sp * (1.0 - 0.70 * tt / max(lf, 1e-4))
                     + 0.020 * lf + 0.0006 + 0.0026 * hl;   // a few soft, fleshy edges
            dm = min(dm, length(q - ax * tt) - rr);
        }
    }
    return max(dm, axial);
}

// one ovate leaf as a tapered, slightly curved blade from the clump centre
inline float ff_leaf(float2 d, float ang, float L, float w0, float bend) {
    float2 dir = float2(cos(ang), sin(ang));
    float u = dot(d, dir);
    if (u < 0.0 || u > L) return 1e3;
    float v = dot(d, float2(-dir.y, dir.x));
    float k = u / L;
    float vc = bend * L * k * k;
    float w = w0 * sqrt(max(k, 0.0)) * (1.0 - k) * 2.0;
    return abs(v - vc) - w - 0.003;
}
inline float ff_plantD(float2 d, float4 h, float size, float det) {
    float dm = 1e3;
    float kind = h.x;
    if (kind < 0.72) {
        // --- fern clump: two crowns, long narrow pinnate fronds
        // fronds leave the crown nearly upright and arch outward under their
        // own weight — a shuttlecock, not a star
        int nf = 3;
        float spread = 0.50 + 0.38 * h.y;
        float lean = (h.z - 0.5) * 0.50;
        for (int j = 0; j < nf; j++) {
            float fj = (float(j) + 0.5) / float(nf) - 0.5;      // -0.5 .. 0.5
            float hj = hash12(float2(float(j) + h.y * 40.0, h.z * 90.0));
            float hk = hash12(float2(float(j) * 3.1 + h.w * 20.0, h.x * 70.0));
            float side = fj * 2.0;                               // -1 .. 1
            float ang = PI * 0.5 + 0.26 * side + 0.30 * (hj - 0.5) + lean * 0.35;
            float bend = spread * side * (0.55 + 0.80 * abs(side)) + lean + 0.12 * (hk - 0.5);
            float L = size * (0.50 + 0.40 * hk) * (1.0 - 0.24 * abs(side));
            float2 o = float2(0.09 * size * (hj - 0.5), 0.03 * size * hk);
            float lmax = 0.205 * L * (0.76 + 0.48 * hj * hk);   // pinna length
            float nlf = clamp(floor(L / (0.026 + 0.010 * hj)), 12.0, 38.0);
            dm = min(dm, ff_pinnate(d - o, ang, L, lmax, bend, nlf, det));
        }
    } else {
        // --- grass tuft: fine tapered blades arcing both ways
        int nf = 4;
        for (int j = 0; j < nf; j++) {
            float fj = (float(j) + 0.5) / float(nf);
            float hj = hash12(float2(float(j) + h.y * 40.0, h.z * 90.0));
            float hk = hash12(float2(float(j) * 3.1 + h.w * 20.0, h.x * 70.0));
            float side = (fj - 0.5) * 2.0;
            float ang = PI * 0.5 + 0.18 * side + 0.22 * (hj - 0.5);
            float L = size * (0.38 + 0.52 * hk * hk);
            float2 o = float2(0.16 * size * (hj - 0.5), 0.0);
            float bend = side * (0.70 + 1.15 * abs(side)) + 0.30 * (hk - 0.5);
            dm = min(dm, ff_frond(d - o, ang, L, 0.026 * size, bend, 0.0));
        }
    }
    return dm;
}

// ---------------------------------------------------------------- sky
// Distant forest: everything past the last modelled row. Two hazed bands of
// canopy silhouette, so the eye never finds an open horizon between the
// trunks -- which is what a real wood looks like and what the depth planes
// are far too expensive to keep doing out to 150 m.
inline float3 ff_backdrop(float3 rd, thread const FFEnv &E, float3 sky) {
    if (rd.y > 0.52) return sky;
    float az = atan2(rd.x, -rd.z);
    float3 col = sky;
    // canopy mass radiance: mostly transmitted/filtered light, a little direct
    float3 mass = E.fill * 0.62 + E.amb * 0.075 + E.kc * 0.0060;
    for (int j = 0; j >= 0; j--) {
        float fj = float(j);
        float scl = mix(10.5, 4.6, fj);
        float n1 = ff_vn(float2(az * scl + fj * 31.0, 1.5 + fj));
        float n2 = ff_vn(float2(az * scl * 3.3 + fj * 7.0, 4.5 - fj));
        float top = 0.215 * (1.00 + 0.34 * n1 + 0.20 * n2);
        float aa = mix(0.0075, 0.014, fj) * (1.0 + 1.6 * abs(n2));
        float m = 1.0 - smoothstep(top - aa, top + aa, rd.y);
        m *= 1.0 - 0.45 * smoothstep(top * 0.35, top, rd.y);   // hazier at the tops
        // the nearer band is less washed out by air than the far one
        float3 band = mix(sky, mass * mix(0.34, 0.85, fj), mix(0.90, 0.96, fj));
        // trunk-scale striations and a shaded base, so the band reads as a
        // stand of trees receding into haze rather than a flat fog wall
        // Vertical trunk striation. High frequency in azimuth, very low in
        // elevation, so it reads as a stand of boles rather than as blotches.
        float ty = rd.y * 9.0 + fj * 3.0;
        float t1 = ff_vn(float2(az * scl * 21.0 + fj * 19.0, ty * 0.22));
        float t3 = ff_vn(float2(az * scl * 6.5 + fj * 5.0, ty * 0.55 + 2.0));
        // bars taper out into the crowns and die away below the litter line
        float taper = smoothstep(top * 0.95, top * 0.30, rd.y) * smoothstep(-0.055, 0.010, rd.y);
        float trunks = mix(0.62, smoothstep(-0.55, 0.65, t1 + 0.35 * t3), taper);
        band *= 0.86 + 0.28 * smoothstep(-0.8, 0.9, n2);
        band *= mix(1.0, 0.52 + 0.66 * trunks, 0.62);
        band *= 0.70 + 0.30 * smoothstep(-0.02, top * 0.9, rd.y);
        col = mix(col, band, m);
    }
    return col;
}

// The canopy roof. This wood is a closed stand: what is overhead is needle
// mass, not sky. It is built as three foliage shells at different heights --
// a single plane stretches into horizontal streaks near the horizon, three
// shells give the ceiling real depth and break that up -- and the openings in
// the highest shell are the SAME openings that cast the shafts on the floor.
inline float3 ff_roof(float3 rd, thread const FFEnv &E, float3 sky, float pixAng) {
    if (rd.y < 0.048) return sky;
    float ry = rd.y;
    // forward scatter through a bough: the hot gold rim next to the sun
    float fs = pow(max(dot(rd, E.L), 0.0), 7.0);
    float3 col = sky;
    // far -> near, so each shell paints over the one behind it
    for (int j = 0; j < 2; j++) {
        float fj = float(j) * 1.6;
        float hy  = 27.0 - 6.6 * fj;                  // 27, 20.4, 13.8 m
        float sC  = min((hy - FF_RO.y) / ry, 145.0);
        float2 q  = FF_RO.xz + rd.xz * sC + E.sway * (0.5 + 0.3 * fj);

        // Big bough masses are projected on the shell, so they keep real
        // perspective. The finer breakup is built in ANGLE instead: projected
        // on a plane it stretches into horizontal ellipses near the horizon,
        // which is what made the first version of this ceiling look like the
        // underside of a water surface.
        float sc1 = 0.052 + 0.030 * fj;
        float n1 = ff_vn(q * sc1 + float2(3.1 + fj * 21.0, 7.7 - fj * 13.0));
        float2 a2 = float2(atan2(rd.x, -rd.z) * 5.4, asin(clamp(rd.y, 0.0, 1.0)) * 5.4)
                  + float2(fj * 11.0, fj * 5.0) + E.sway * 0.05;
        float n2 = ff_vn(a2 * 2.6);
        float n3 = ff_vn(a2 * 7.1 + 3.3);
        float n5 = ff_vn(a2 * 21.0 + 8.8);
        // each octave dies as it goes under a pixel instead of crawling at 1 spp
        float px = pixAng * 5.4;
        float d2 = 1.0 - smoothstep(0.25, 0.85, px * 2.6);
        float d3 = 1.0 - smoothstep(0.25, 0.85, px * 7.1);
        float d5 = 1.0 - smoothstep(0.25, 0.85, px * 21.0);
        float f  = 0.62 * n1 + 0.42 * n2 * d2 + 0.28 * n3 * d3 + 0.17 * n5 * d5;
        float aw = 0.075 + 0.9 * px;
        float thr = f - (0.13 - 0.17 * fj);
        float cov = smoothstep(-aw - 0.26, aw + 0.05, thr);
        // and the fringe is not opaque: half-covered pixels stay half-covered
        cov *= 0.80 + 0.20 * smoothstep(-aw, aw + 0.22, thr);

        // The real windows in the top shell: the ones the shafts fall through.
        if (j == 0) {
            float2 cq = (q - float2(-20.0, -36.0)) * float2(0.62, 0.42);
            float2 cr = (q - float2(-4.0,  -30.0)) * float2(0.80, 0.55);
            float win = max(1.0 - smoothstep(2.0, 13.0, length(cq)),
                            0.78 * (1.0 - smoothstep(1.0, 6.5, length(cr))));
            cov *= 1.0 - win;
        }
        // Shallow rays run for hundreds of metres THROUGH the crowns, so the
        // ceiling closes up completely toward the treeline.
        cov *= smoothstep(0.045, 0.26, rd.y);

        // A needle mass seen from below is mostly transmitted light, dark, with
        // a gold edge where the sun is right behind it. Nearer shells are
        // darker: less air between them and the eye.
        float3 mass = E.leafT * (0.46 + 3.2 * fs) * (0.30 + 0.70 * E.day)
                    + E.amb * 0.042 + E.kc * (0.0016 + 0.011 * fs);
        mass *= (0.30 + 0.76 * smoothstep(-0.60, 0.90, 0.7 * n1 + 0.5 * n2 + 0.3 * n3 + 0.28 * n5 * d5)) * (1.0 - 0.16 * fj);
        // sun-side crowns are yellower and brighter than the shaded undersides
        mass *= mix(float3(0.86, 0.94, 1.06), float3(1.22, 1.08, 0.74),
                    smoothstep(-0.7, 0.8, n1 + 0.5 * n3));
        // Aerial perspective on the shallow part of the ceiling. The haze
        // inside a wood is lit by the canopy, not by open sky, so the target
        // is the fog colour under a closed roof -- far darker than the sky.
        float3 hazeC = E.fogA * (ws_luma(E.amb) * E.fogK * mix(2.1, 1.5, E.day));
        float aer = smoothstep(0.36, 0.045, rd.y) * (1.0 - 0.28 * fj);
        mass = mix(mass, hazeC, 0.85 * aer);
        col = mix(col, mass, cov);
    }
    return col;
}

inline float3 ff_sky(float3 rd, float t, thread const FFEnv &E, float pixAng) {
    if (E.day > 0.02) {
        // physically based sky: gives the right blue at noon and the right
        // orange low down near sunrise/sunset, for free
        float3 sky = ws_atmosphereFast(rd, E.L, 22.0) * 3.4;
        sky += ws_sunDisk(rd, E.L, 0.27, E.kc * 9.0);
        // Seen from inside a wood the low sky is a pale haze, not the saturated
        // Mie glow the open-horizon model gives; flatten it near the treeline.
        float hz = 1.0 - smoothstep(0.0, 0.34, rd.y);
        sky = mix(sky, float3(ws_luma(sky)) * float3(0.94, 1.00, 1.10),
                  0.80 * hz * (1.0 - E.lowSun));
        return ff_roof(rd, E, ff_backdrop(rd, E, sky * E.day), pixAng);
    }
    float3 sky = float3(0.010, 0.020, 0.048) * (1.0 + 0.7 * max(rd.y, 0.0));
    float c = dot(rd, E.L);
    sky += FF_MOONC * 0.035 * pow(max(c, 0.0), 5.0);
    float2 sp = float2(atan2(rd.x, -rd.z), asin(clamp(rd.y, -1.0, 1.0))) * 14.0;
    sky += ws_stars(sp, 6.0, t, 0.22) * 0.45;
    return ff_roof(rd, E, ff_backdrop(rd, E, sky), pixAng);
}

// Composite every firefly whose depth lies in (z0, z1] at the current
// transmittance. Recomputing the flier is cheaper than keeping an array of
// them alive across the whole plane walk (that spills to thread memory).
inline void ff_flySlab(thread float3 &col, float T, float z0, float z1, float t,
                       float2 fragCoord, float2 res, float3 ro, float3 fwd,
                       float3 right, float3 up, float k, thread const FFEnv &E) {
    if (E.ffAmt <= 0.002 || T <= 0.020) return;
    float rscale = res.y / 1600.0;
    for (int i = 0; i < FF_NFF; i++) {
        float D = ff_flyCZ(i);
        if (D <= z0 || D > z1) continue;
        FFly f = ff_fly(i, t);
        if (f.bright <= 0.001) continue;
        float3 v = f.pos - ro;
        float d = dot(v, fwd);
        if (d < 0.05) continue;
        float2 spx = float2(dot(v, right), dot(v, up)) / (d * k);
        float2 px = (spx * res.y + res) * 0.5;
        float R = max(2.05 * rscale, FF_APER * rscale * abs(1.0 / d - 1.0 / FF_FOCUS) * 2.3);
        float flux = FF_FFP * f.bright / pow(d, 1.75) * rscale * rscale * E.ffAmt;
        flux *= 0.17 + 0.83 * smoothstep(0.6, 3.8, d);
        float2 nuv = px / res;
        flux *= 1.0 - 0.80 * smoothstep(0.66, 0.96, nuv.y);
        flux *= 1.0 - 0.55 * smoothstep(0.56, 0.86, nuv.x) * smoothstep(0.42, 0.78, nuv.y);
        if (flux <= 1e-4) continue;
        // a flier deep in the fog bank is wrapped in more glow than one in
        // the clear air just under the lens
        float mist = clamp(E.sigG * 2.1 * smoothstep(3.4, 0.6, f.pos.y)
                         + E.sigH * 7.0 + 0.030 * d, 0.0, 1.1);
        col += T * ff_glow(fragCoord - px, R, flux, ff_flyCol(i), mist);
    }
}

// Shading for one procedural fir row. Kept out of the cell-scan loop: the
// scan only needs coverage, and holding this many live values inside the loop
// costs occupancy on every pixel in the frame.
inline float3 ff_treeShade(float3 P, float nx, float w, float Hb, float cell, float Z,
                           float fp, float3 rd, float soft, bool detail, float seed,
                           float t, thread const FFEnv &E) {
float3 sc;
    if (detail && P.y <= Hb) {
        sc = ff_trunkShade(P, nx, w, seed, fp, t, E, true, soft);
    } else {
        // cheap far-tree shading: bole and crown share one
        // graded material so the crown base is not a hard line
        float mn = ff_key(P, E, false);
        float nzc = sqrt(max(1.0 - nx * nx, 0.0));
        float lat = max(dot(float3(nx, 0.0, nzc), E.L), 0.0);  // cylinder normal
        lat = 0.22 + 0.78 * lat;
        float vg  = 0.30 + 0.70 * smoothstep(-0.8, 9.0, P.y);  // dark at the base
        float crown = smoothstep(Hb - 2.0, Hb + 3.0, P.y);
        // structure: bough clumping + bark banding, faded out
        // as the row shrinks so nothing shimmers
        float dt = 1.0 - smoothstep(0.018, 0.085, fp);
        float bn = ff_fbm2(float2(P.y * 0.85 + cell * 6.1,
              nx * 1.9 + cell * 2.3));
        float bk = ff_vn(float2(P.y * 5.5 + cell * 17.0, nx * 4.0 + cell));
        float tx = 0.80 + 0.46 * bn * (0.45 + 0.55 * dt)
                 + 0.15 * bk * dt * (1.0 - crown);
        // depth through the crown: thin at the silhouette, thick in the middle
        float thick = sqrt(max(1.0 - nx * nx, 0.0));
        tx *= mix(1.0, 0.46 + 0.62 * thick, crown);
        // bough clumps at a scale you can actually see from here
        tx *= mix(1.0, 0.68 + 0.66 * smoothstep(-0.75, 0.75, bk * 1.6 + bn * 0.7),
                  crown * (0.35 + 0.65 * dt));
        // limbs catch the moon on their upper faces
        float lit = 1.0 + 0.55 * crown * dt
                  * smoothstep(0.15, 0.85, bn) * smoothstep(0.1, 0.9, mn);
        float2 hv = float2(ff_h2(float2(cell * 3.7 + 11.0, 2.1)),
                           ff_h2(float2(cell * 9.1 + 4.0, 7.3)));
        float3 balb = mix(mix(float3(0.128, 0.108, 0.086),
          float3(0.148, 0.112, 0.078), E.day),
                          E.leafA, crown);
        balb *= (0.62 + 0.82 * hv.x * hv.x)
              * mix(float3(1.10, 0.98, 0.84), float3(0.86, 0.94, 1.06), hv.y);
        sc = balb * tx * (E.ambS * ((0.85 + 0.5 * vg) * mix(0.62, 0.55, E.day))
             + E.fill * (0.6 + 0.6 * vg)
             + E.kc * (mix(0.16, 0.46, E.day) * mn * lat * vg * lit));
        // needles are thin: the sun shines THROUGH the crown,
        // which is what makes a sunlit canopy glow
        float fwd2 = max(dot(rd, E.L), 0.0);
        float trans = crown * mn * vg * pow(fwd2, 2.4);
        sc += E.leafT * E.kc * (0.085 * trans);
        // aerial perspective: distant rows lose saturation and
        // contrast and pick up a cool haze veil
        float aer = smoothstep(16.0, 78.0, Z);
        float3 hazeT = E.fogA * (ws_luma(E.amb) * E.fogK * mix(1.9, 1.20, E.day));
        sc = mix(sc, hazeT, 0.86 * aer);
    }
    return sc;
}

// ================================================================= scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    // Firefly clock. This is a dynamic scene: nothing loops, so the flight
    // paths and the blink cycles run off continuous seconds. 19 s per orbit.
    float t = ctx.time * (1.0 / 19.0) + fract(ctx.t);
    float2 res = ctx.res;
    float3 ro = FF_RO;
    float3 fwd = float3(0.0, sin(FF_PITCH * DEG), -cos(FF_PITCH * DEG));
    float3 rd = ws_camRay(fragCoord, res, ro, ro + fwd, FF_FOV);
    float3 right = float3(1.0, 0.0, 0.0);
    float3 up = cross(right, fwd);
    float k = tan(FF_FOV * DEG * 0.5);
    float pixAng = 2.0 * k / res.y;
    float rscale = res.y / 1600.0;
    float jit = hash12(fragCoord + float2(0.37, 1.91));

    // ---------------- time of day ----------------
    FFEnv E;
    float3 sunS  = normalize(ws_rotY(ctx.sunDir,  FF_HEAD));
    float3 moonS = normalize(ws_rotY(ctx.moonDir, FF_HEAD));
    float  el    = ctx.sunElevation;
    E.wind = ctx.time;
    {   float w = E.wind;
        E.sway = float2(0.85 * sin(0.21 * w) + 0.40 * sin(0.53 * w + 1.3),
                        0.55 * cos(0.17 * w) + 0.28 * sin(0.47 * w + 0.7)); }
    E.day   = smoothstep(-9.5, 4.5, el);
    // Fireflies come out with the dark. They start as the last colour leaves
    // the sky (civil dusk) and are fully out by nautical twilight, so the
    // transition is a slow kindling rather than a switch.
    E.ffAmt = 1.0 - smoothstep(-10.5, 0.5, el);
    E.ffAmt = E.ffAmt * E.ffAmt * (3.0 - 2.0 * E.ffAmt);   // smooth at both ends

    // Direct sun: reddened and extinguished as it sinks. A real sun low in a
    // forest is dim and deeply orange; at noon it is a hard neutral key.
    float  hsun  = clamp(sunS.y, 0.0, 1.0);
    // Relative air mass, floored: the true horizon value (~38) would kill the
    // beam completely, and a real sunset still lays warm light through a wood.
    float  airm  = 1.0 / max(hsun + 0.115, 0.12);
    float3 sunTint = ws_blackbody(mix(2450.0, 6050.0, smoothstep(0.02, 0.46, hsun)));
    // Very low sun inside a wood is never a clean beam: most of what reaches
    // the bark has bounced or scattered, so pull the tint back toward the
    // skylight instead of painting the trunks tangerine.
    sunTint = mix(sunTint, mix(sunTint, float3(1.0), 0.20), 1.0 - smoothstep(0.015, 0.13, hsun));
    float  sunE  = 11.5 * smoothstep(-0.055, 0.16, sunS.y) * exp(-0.112 * (airm - 1.0));

    // Moon key for the night half (Step 2 refines this).
    // Moon key. Illumination scales faster than the phase fraction (a half
    // moon is ~1/10 of a full one), and the disc reddens and dims through the
    // air mass exactly as the sun does when it is low.
    float  mi    = clamp(ctx.moonIllum, 0.0, 1.0);
    float  mAir  = 1.0 / max(moonS.y + 0.06, 0.08);
    float3 moonC = mix(float3(1.00, 0.72, 0.46), FF_MOONC, smoothstep(0.02, 0.30, moonS.y));
    float  moonE = 7.6 * (0.18 * mi + 0.82 * mi * mi * mi)
                 * smoothstep(-0.03, 0.16, moonS.y) * exp(-0.13 * (mAir - 1.0));
    // With the moon below the horizon there is no key at all, but the night sky
    // is still ~10x brighter than the floor and it pours through the canopy
    // gaps from overhead. Lean the "key" direction up so the gap projection
    // keeps producing honest vertical shafts instead of shearing to infinity.
    float3 nightL = normalize(mix(normalize(float3(-0.34, 0.90, -0.28)), moonS,
                                  smoothstep(-0.02, 0.22, moonS.y)));
    // Sun and moon are ONE key, blended by how much energy each is actually
    // delivering. Switching between them on a threshold puts a visible jump in
    // the shaft direction right at dusk; this crosses over continuously, and
    // through the crossover both are nearly dark anyway.
    float  wSun = sunE / (sunE + moonE + 1e-3);
    E.L  = normalize(mix(nightL, sunS, wSun) + 1e-5);
    E.kc = sunTint * sunE + moonC * moonE;

    // Skylight: the blue dome, warmed and dimmed through twilight.
    float3 skyDay = float3(0.480, 0.580, 0.840);
    float3 skyLow = float3(0.690, 0.480, 0.330);   // sun on the horizon
    float3 skyTwi = float3(0.150, 0.215, 0.430);   // the blue hour after it
    float3 skyC   = mix(skyLow, skyDay, smoothstep(0.4, 17.0, el));
    // Cross-fade LATE. Blending the sunset orange against the blue hour over a
    // wide window just averages them into brown-grey, which is what made the
    // half hour around sunset read as mud rather than as a sunset.
    skyC          = mix(skyTwi, skyC, smoothstep(-7.0, -1.8, el));
    float  skyE   = mix(0.09, 1.70, smoothstep(-7.0, 22.0, el)) + 0.16 * exp(-pow((el - 1.0) / 6.0, 2.0));
    // Night ambient is starlight plus whatever the moon puts into the sky.
    // Under a new moon the wood is genuinely dark (but never black); under a
    // full moon the dome lifts and turns cold blue.
    // Starlight and airglow. A moonless wood really is close to black, but the
    // eye that has been out in it for an hour is not: this is the dark-adapted
    // level, which also keeps the picture from ever clipping to nothing.
    float3 starA = float3(0.0345, 0.0430, 0.0700);
    float3 moonA = FF_MOONC * (0.0052 * moonE);
    E.amb  = mix(starA + moonA, skyC * skyE, E.day);
    // Light that has been THROUGH the canopy: green, diffuse, and the reason a
    // wood at noon is not a black box. It is not occluded by the canopy again.
    float3 warmK = mix(float3(1.0), sunTint, 0.55 + 0.45 * smoothstep(0.02, 0.22, hsun));
    E.fill = warmK * float3(0.118, 0.205, 0.082) * (0.108 * sunE * E.day);

    // Ground bounce: warm light kicked back up off the sunlit litter.
    E.bounce = warmK * float3(1.00, 0.86, 0.62) * (0.055 * sunE * E.day);

    // Air: clear and thin by day, thick mist at dawn, the night's fog bank after dark.
    float mistAM = 0.72 * exp(-pow((ctx.dayTime - 6.6) / 1.9, 2.0));   // dawn mist
    E.sigH = mix(0.0135, 0.0052 + 0.013 * mistAM, E.day);
    E.sigG = mix(0.225,  0.030 + 0.26 * mistAM,   E.day);
    E.hc   = FF_HC;
    // fog albedo is near-neutral: the colour of night mist comes from the
    // light falling on it, not from the droplets
    E.fogA = mix(float3(0.560, 0.640, 0.720), float3(0.330, 0.385, 0.360), E.day);
    E.leafA = mix(float3(0.030, 0.046, 0.020), float3(0.0640, 0.0955, 0.0330), E.day);
    E.leafT = mix(float3(0.040, 0.066, 0.038), float3(0.105, 0.185, 0.052), E.day);
    // At night the mist is itself a large, close area source: a luminous
    // ceiling a couple of metres above the floor. That is what keeps a foggy
    // night readable instead of flat black, and it is why the floor of a
    // moonlit wood is cold grey-blue rather than the colour of its litter.
    E.bounce += E.fogA * (ws_luma(E.amb) * (2.4 + 7.0 * min(E.sigG, 0.5)) * (1.0 - E.day));
    // A surface integrates the whole dome, so it collects ~pi times the
    // radiance the fog volume sees along one direction. The day half was tuned
    // with that factor already folded into its constants; the night half needs
    // it explicitly or every surface sits ten stops under the mist.
    E.ambS = E.amb * mix(PI, 1.0, E.day);
    E.gap0 = mix(0.07, 0.30, E.day);
    E.dapple = 1.00 * E.day;
    E.rayB   = mix(1.0, 1.60, E.day);
    // With the key near the horizon its rays reach a point almost horizontally,
    // so the canopy-plane projection runs away and the gap field turns into
    // stripes. Fade to a soft lateral openness instead.
    E.lowSun = 1.0 - smoothstep(0.045, 0.42, max(E.L.y, 0.0));
    // foliage loses its green as the light reddens: a fern at sunset is a
    // dark warm shape, not a lit green one
    E.leafA = mix(E.leafA, E.leafA * float3(1.18, 0.86, 0.62), 0.55 * E.lowSun * E.day);
    // At sunset the brightest thing in a wood is the lit air between the
    // boles, and it works as a large warm source on everything below it.
    // Without it the floor sits in mud while the treeline glows.
    E.bounce += E.fogA * float3(1.34, 1.02, 0.72)
              * (ws_luma(E.amb) * 2.3 * E.lowSun * E.day);
    // At night the sky is a uniform dim dome, so the fog sees all of it.
    // By day the canopy is an opaque lid: shaded haze is far darker than
    // haze inside a shaft, and that contrast is what reads as depth.
    // Even at night the canopy shapes what the mist sees: without this the
    // whole volume lifts to one flat slab of blue.
    E.fogK = mix(0.46, 0.235, E.day);
    E.expo = mix(1.74, 1.02 * (1.0 + 0.55 * E.lowSun), E.day);
    // Through twilight a real photographer opens up two-thirds of a stop as
    // the light goes; without it the half-hour after sunset falls off a cliff.
    E.expo *= 1.0 + 0.50 * exp(-pow((el + 3.2) / 5.2, 2.0));
    // Auto-iris for the night half. The moon rises and sets on its own clock,
    // so without this the wallpaper sags into a hole on the hours either side
    // of moonrise. A dark-adapted eye does exactly this: opens up when there
    // is less to see, and stops down again once the moon is over the trees.
    float keyLvl = ws_luma(E.amb) + 0.055 * ws_luma(E.kc) * (1.0 - E.day);
    E.expo *= mix(1.0, clamp(0.080 / max(keyLvl, 0.015), 1.0, 2.05), 1.0 - E.day);

    float phase = 0.62 * ff_hg(dot(rd, E.L), 0.55) + 0.38 / (4.0 * PI);

    float3 col = float3(0.0);
    float T = 1.0;
    float sPrev = 0.0, zPrev = 0.0;
    float sG = rd.y < -1e-4 ? -ro.y / rd.y : 1e9;   // ground hit
    bool done = false;

    for (int kx = 0; kx < FF_NROW && !done; kx++) {
        float Z = FF_Z[kx];
        float s = Z / max(-rd.z, 1e-4);
        // ground before this plane?
        if (sG < s && sG < 38.0) {
            ff_fogSeg(col, T, ro, rd, sPrev, sG, E, jit, phase);
            ff_flySlab(col, T, zPrev, sG * (-rd.z), t, fragCoord, res, ro, fwd, right, up, k, E);
            float3 G = ro + rd * sG;
            // Each layer of floor texture is faded out against its OWN scale,
            // at the point where a pixel stops resolving it. The old code
            // faded every layer on one threshold tuned for the finest of them,
            // which stripped the litter off the floor from about fourteen
            // metres out and left a bald sand-coloured bank across the frame.
            float fpG = sG * pixAng;
            float dLit = 1.0 - smoothstep(0.050, 0.165, fpG);   // 4.5 /m
            float dCld = 1.0 - smoothstep(0.170, 0.520, fpG);   // 1.4 /m
            float dTwg = 1.0 - smoothstep(0.100, 0.330, fpG);   // 2.2 /m
            float dFin = 1.0 - smoothstep(0.009, 0.028, fpG);   // 13-23 /m
            float ndl  = dFin;
            float litter = 0.30 + 0.78 * mix(0.5, ff_fbm2(G.xz * 4.5), dLit);
            float clod   = 0.62 + 0.38 * mix(0.5, ff_fbm2(G.xz * 1.4 + 7.0), 0.35 + 0.65 * dCld);
            float twig   = 0.0;
            if (dTwg > 0.01) twig = dTwg * smoothstep(0.62, 0.90, 1.0 - abs(ff_vn(G.xz * 2.2 + 13.0)));
            if (dFin > 0.02) {
                litter *= 1.0 - 0.34 * dFin * smoothstep(0.34, 0.90, 1.0 - abs(ff_vn(G.xz * float2(23.0, 9.0) + 4.0)));
                litter *= 0.88 + 0.24 * dFin * ff_vn(G.xz * 13.0 + 21.0);
            }
            float mn0 = ff_vn(G.xz * 0.85 + 3.0);
            float mn1 = ff_vn(G.xz * 2.9 + 11.0);
            float moss = smoothstep(0.16, 0.78, 0.72 * mn0 + 0.45 * mn1);
            litter *= 1.0 - 0.45 * twig;
            // needle litter over moss; both warm up and gain saturation in daylight
            float3 litC = mix(float3(0.115, 0.086, 0.058), float3(0.126, 0.090, 0.056), E.day);
            float3 mosC = mix(float3(0.072, 0.116, 0.050), float3(0.062, 0.104, 0.038), E.day);
            float3 galb = mix(litC, mosC, moss) * litter * clod;
            // wet duff and bare earth read darker than needle litter
            galb *= 0.80 + 0.34 * (0.5 + 0.5 * mn0) * (0.82 + 0.36 * clod);
            float3 gn = normalize(float3(0.11 * mn1, 1.0, 0.11 * (clod * 2.0 - 1.3)));
            float kg = ff_key(G, E, ndl > 0.01);           // dappled sunlight through the canopy
            float sky = 0.55 + 0.45 * smoothstep(0.0, 0.5, kg);   // open floor sees more sky
            float3 gl = E.kc * (mix(0.85, 1.80, E.day) * kg * max(dot(gn, E.L), 0.0))
                      + E.ambS * (mix(5.7, 0.50, E.day) * sky)
                      + E.bounce * (2.0 + 1.4 * sky) + E.fill * (0.40 + 0.55 * sky)
                      + ff_flyLight(G, gn, t, E.ffAmt);
            float occ = 1.0;
            for (int j = 0; j < 8; j++) {
                float2 dq = G.xz - float2(FF_NEAR[j].x + FF_NEAR[j].z * 0.4, -FF_NZ[j]);
                float r2n = dot(dq, dq);
                occ *= 1.0 - 0.80 * exp(-r2n * 2.6) - 0.34 * exp(-r2n * 0.26);
            }
            occ = max(occ, 0.07);
            float3 gsc = galb * gl * occ;
            // Aerial perspective is a blend toward the radiance of the AIR,
            // and the air inside a wood is lit by the canopy, not by the open
            // sky. Blending toward the floor's own luminance instead was what
            // painted the cream-coloured strip across the mid distance.
            float3 hazeG = E.fogA * (ws_luma(E.amb) * E.fogK * mix(1.9, 1.10, E.day));
            float gaer = smoothstep(4.5, 27.0, sG);
            gsc = mix(gsc, hazeG, 0.95 * gaer);
            col += T * gsc;
            T = 0.0;
            done = true;
            break;
        }
        if ((kx % 3) == 2 || kx == FF_NROW - 1) {
            ff_fogSeg(col, T, ro, rd, sPrev, s, E, jit, phase);
            sPrev = s;
        }
        ff_flySlab(col, T, zPrev, Z, t, fragCoord, res, ro, fwd, right, up, k, E);
        zPrev = Z;
        if (T < 0.015) { done = true; break; }

        float3 P = ro + rd * s;
        float fp = s * pixAng;
        // thin-lens circle of confusion at this depth, in world units at that depth
        float cocPx = FF_APER * rscale * abs(1.0 / s - 1.0 / FF_FOCUS);
        // silhouette anti-aliasing width: the circle of confusion when the
        // plane is defocused, but never less than ~2.3 px, so near-focus
        // trunk edges resolve smoothly instead of staircasing
        float fpB = fp * max(1.0 + cocPx, 2.30) * (1.0 + 0.030 * Z);
        float soft = cocPx;
        float cov = 0.0;
        float3 rc = float3(0.0);
        bool detail = kx < 4;

        // ---- trunks / trees
        if (P.y >= -0.05 && P.y < 41.5) {
            if (kx < 4) {
                float bw = 0.0, bnx = 0.0, bSeed = 0.0;
                for (int j = FF_NS[kx]; j < FF_NS[kx + 1]; j++) {
                    float4 tr = FF_NEAR[j];
                    float cx = tr.x + tr.z * P.y;
                    float w = ff_trunkW(P.y, tr.y, tr.w);
                    float dx = P.x - cx;
                    float c = clamp(0.5 - (abs(dx) - w) / fpB, 0.0, 1.0);
                    if (c > cov) { cov = c; bw = w; bnx = clamp(dx / w, -1.0, 1.0); bSeed = tr.w; }
                }
                // Past ~7 m a bark fissure is under a pixel: the three-tap normal there is
                // paying for detail that only aliases, so it drops to the shaded body.
                if (cov > 0.0) rc = ff_trunkShade(P, bnx, bw, bSeed, fp, t, E, fp < 0.0092, soft);
            } else {
                float W = FF_W[kx];
                float ci = floor(P.x / W - 0.25);
                float bw = 0.0, bnx = 0.0, bHb = 0.0, bCell = 0.0, bSeed = 0.0;
                int nscan = 0;
                for (int di = 0; di <= nscan; di++) {
                    float cell = ci + float(di);
                    float4 h = ff_h4(float2(cell * 7.3 + 1.1, float(kx) * 13.7 + 2.9));
                    // clearing mask
                    float cx = (cell + 0.5 + 0.7 * (h.x - 0.5)) * W;
                    float cw = 7.5 * smoothstep(5.0, 12.0, Z) * (1.0 - smoothstep(28.0, 60.0, Z)) + 2.5 * (1.0 - smoothstep(5.0, 12.0, Z));
                    float clr = 1.0 - smoothstep(cw * 0.6, cw * 1.4, abs(cx - 1.0));
                    if (h.y > FF_DEN[kx] * (1.0 - clr)) continue;
                    // Below the lowest possible crown base the tree is just a
                    // bole a few tens of centimetres wide, so a pixel further
                    // out than that cannot be on it. Rejecting here skips the
                    // second hash and the whole crown profile for every pixel
                    // in the lower half of the frame -- most of the frame.
                    if (P.y < 3.8 && abs(P.x - cx) > 0.95 + 3.0 * fpB) continue;
                    float4 h2 = ff_h4(float2(cell * 3.1 + 5.7, float(kx) * 5.3 + 7.1));
                    float Ht = 24.0 + 16.0 * h2.y;
                    // The cut has to clear the anti-aliasing footprint, or the
                    // crown's soft edge is sliced off flat at the tip height
                    // and the sky gets a horizontal seam across every cell.
                    if (P.y > Ht + 0.15 + 10.0 * fpB) continue;
                    float r0 = 0.22 + 0.3 * h.z;
                    float lean = (h.w - 0.5) * 0.06;
                    float Hb = mix(15.5, 4.0, smoothstep(20.0, 42.0, Z)) + 6.5 * h2.x;
                    float cxy = cx + lean * P.y;
                    // Reach both soft-saturates the crown (so neighbours merge
                    // into one canopy mass instead of standing apart like
                    // cypresses) and bounds it inside the two cells this loop
                    // scans. Varying it per tree is what stops every big crown
                    // pinning to the same width and drawing rectangles.
                    float w = ff_firW(P.y, r0, Hb, Ht, h2, fp,
                                      W * (0.74 + 0.40 * h2.z));
                    // anti-alias the silhouette in 2D: normalise the horizontal
                    // footprint by the slope of the edge, so shallow crown and
                    // leader edges get the same softness as vertical ones
                    // crown/leader edges are shallow: widen the AA footprint by a
                    // fixed factor instead of a second (expensive) width probe
                    float aaw = fpB * mix(1.15, 4.5, smoothstep(Hb - 2.0, Hb + 2.5, P.y));
                    if (w <= -aaw) continue;
                    float dx = P.x - cxy;
                    float c = clamp(0.5 - (abs(dx) - w) / aaw, 0.0, 1.0);
                    if (c > cov) {
                        cov = c;
                        bw = w; bnx = clamp(dx / w, -1.0, 1.0);
                        bHb = Hb; bCell = cell; bSeed = h.x * 10.0;
                    }
                }
                if (cov > 0.0)
                    rc = ff_treeShade(P, bnx, bw, bHb, bCell, Z, fp, rd, soft,
                                      detail && P.y <= bHb, bSeed, t, E);
            }
        }
        // ---- undergrowth (ferns / grass)
        if (kx == 0 && P.y < 1.8 && P.y > -0.4 && cov < 0.999) {
            float Wu = 0.74 + 0.058 * Z;
            float ci = floor(P.x / Wu);
            for (int di = 0; di <= 1; di++) {
                float cell = ci + float(di);
                for (int sb = 0; sb < 1; sb++) {
                float sc2 = cell * 2.0 + float(sb);
                float4 h = ff_h4(float2(sc2 * 11.3 + 0.7, float(kx) * 3.7 + 19.1));
                if (h.w < 0.14) continue;
                float bx = (cell - 0.05 + 0.44 * (h.y - 0.5)) * Wu;
                float by = -0.34 + 0.52 * h.z * h.z;
                float size = (0.52 + 1.50 * h.x * h.x) * mix(1.0, 1.20, smoothstep(2.4, 22.0, Z));
                size = min(size, 1.30 * Wu);        // must stay inside the scanned cells
                float2 d = float2(P.x - bx, P.y - by);
                if (abs(d.x) > size * 1.50 || d.y > size * 1.55 || d.y < -0.12) continue;
                float det = 1.0 - smoothstep(0.0040, 0.0165, fp);
                float sd = ff_plantD(d, ff_h4(float2(sc2 * 5.1 + 3.3, float(kx) * 7.9 + 1.7)), size, det);
                float c = clamp(0.5 - sd / (fpB * 2.1), 0.0, 1.0);
                if (c > 0.0) {
                    float mn = ff_key(P, E);
                    // leaf orientation varies across the clump: tonal life, not a flat cutout
                    float lv = ff_fbm2(float2(P.x * 7.0 + cell, P.y * 7.0 + float(kx) * 3.0));
                    float up = 0.45 + 0.55 * smoothstep(-0.6, 0.7, lv);
                    float3 n = normalize(float3(0.30 * lv, 0.30 + 0.55 * up, 0.86));
                    // every clump is a slightly different plant: colour, age, health
                    float3 dayA = float3(0.0560, 0.0930, 0.0350)
                                * mix(0.62, 1.34, h.z)
                                * mix(float3(1.10, 0.92, 0.80), float3(0.84, 1.06, 0.92), h.y);
                    float3 palb = mix(float3(0.0400, 0.0530, 0.0305), dayA, E.day)
                                * mix(float3(1.0), float3(1.22, 0.84, 0.58), 0.82 * E.lowSun * E.day)
                                * (0.62 + 0.76 * up)
                                * (1.0 - 0.34 * smoothstep(6.0, 18.0, Z));
                    // self-shadowing inside the clump: the crown catches the sun,
                    // the skirt sits in its own shade
                    float aoC = 0.34 + 0.66 * smoothstep(-0.05, 0.55 * size, d.y);
                    float3 sc = palb * (E.ambS * (mix(1.55, 0.62, E.day) * aoC)
                                        + E.fill * (0.72 * aoC)
                                        + E.kc * (mix(0.13, 0.58, E.day) * mn * aoC
                                        * max(dot(n, E.L), 0.0)) + E.bounce * 0.8
                                        + ff_flyLight(P, n, t, E.ffAmt));
                    // a fern frond is one cell thick: lit from behind it turns into
                    // a lantern. This is the signature of a sunlit forest floor.
                    float edge = 1.0 - smoothstep(0.0, 3.2 * fpB, -sd);
                    float fwd3 = max(dot(rd, E.L), 0.0);
                    float thru = mn * (0.20 + 0.80 * pow(fwd3, 1.8));
                    sc += E.leafT * (E.amb.g * 1.1 + ws_luma(E.kc) * 0.085 * thru)
                          * (0.30 + 0.70 * edge) * (1.0 - 0.68 * smoothstep(5.0, 17.0, Z));
                    rc = mix(rc, sc, c > cov ? 1.0 : 0.0);
                    cov = max(cov, c);
                }
                }
            }
        }
        if (cov > 0.0) {
            col += T * cov * rc;
            T *= (1.0 - cov);
        }
    }
    if (!done && T > 0.002) {
        ff_fogSeg(col, T, ro, rd, sPrev, 150.0, E, jit, phase);
        col += T * ff_sky(rd, t, E, pixAng);
    }

    // ---- finish
    col *= E.expo;
    float2 uv = fragCoord / res;
    col *= ws_vignette(uv, mix(0.24, 0.34, E.day));
    col *= 1.0 - mix(0.26, 0.23, E.day) * smoothstep(0.58, 1.0, uv.y);          // calm menu-bar strip
    col *= 1.0 - 0.13 * smoothstep(0.15, 0.0, uv.y);          // calm Dock strip
    // low-light colour: let the blue midtones breathe so the warm fireflies
    // read as the focal contrast, and let the grade drift warm/cool slowly
    float tw = 0.62 * sin(uv.x * 4.7 + 1.3) + 0.48 * sin(uv.y * 3.1 - 2.2)
            + 0.30 * sin((uv.x + uv.y) * 7.9 + 0.6);
    col *= mix(float3(0.955, 0.995, 1.045), float3(1.070, 1.010, 0.935),
               smoothstep(-0.45, 0.55, tw));
    col = ws_saturate(col, mix(0.90, 1.16, E.day) + 0.13 * E.lowSun * E.day);

    float3 o = ws_acesFitted(col);
    // sensor grain: fine luminance noise everywhere plus cooler chroma noise
    // lifted in the shadows, where a real low-light frame is noisiest
    float g1 = ws_grain(fragCoord, 0.0);
    float g2 = ws_grain(fragCoord + float2(53.7, 91.3), 0.0);
    float g3 = -0.72 * g1 + 0.42 * g2;
    float sh = 1.0 - smoothstep(0.015, 0.30, ws_luma(o));
    float gAmt = mix(1.0, 0.34, E.day);          // a daylight frame is not noisy
    o += g1 * 0.0032 * gAmt;
    o += float3(g2, g1, g3) * float3(0.8, 0.6, 1.25) * (0.0016 + 0.0028 * sh) * gAmt;
    return clamp(o, 0.0, 1.0);
}
