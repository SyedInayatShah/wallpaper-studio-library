// =====================================================================
//  Wallpaper Studio render prelude — prepended to every scene file.
//  A scene must define:
//      float3 scene(float2 fragCoord, WSCtx ctx);
//  fragCoord: pixel coords, origin bottom-left, pixel centers at +0.5
//  (Shadertoy convention). Return LINEAR color already tone-mapped into
//  [0,1] (e.g. via ws_acesFitted). The renderer handles supersampling,
//  sRGB encoding and dithering.
// =====================================================================
#include <metal_stdlib>
using namespace metal;

constant float PI  = 3.14159265358979323846;
constant float TAU = 6.28318530717958647692;

struct WSCtx {
    float2 res;      // image size in pixels
    float  t;        // loop phase in [0,1). Stills: 0 unless --t given
    float  duration; // loop length in seconds (0 for stills)
    float  time;     // t * duration (seconds) — NOT loop-safe on its own.
                     // Dynamic (real-time) wallpapers: continuous seconds, use for motion.
    float  aspect;   // res.x / res.y
    // ---- time of day (dynamic wallpapers; offline renders use --hour/--date) ----
    float3 sunDir;       // unit vector toward the sun. Frame: x = east, y = up, z = south (-z = north)
    float  sunElevation; // degrees above the horizon (negative = below)
    float3 moonDir;      // unit vector toward the moon (same frame)
    float  moonIllum;    // illuminated fraction: 0 new moon .. 1 full moon
    float  dayTime;      // local clock time in hours [0,24)
    float  dayOfYear;    // 1..366
    float  realtime;     // 1 when rendered live in the app, 0 offline
};

// Rotate a world vector about the vertical axis (e.g. to aim a scene's camera heading).
inline float3 ws_rotY(float3 v, float a) { float c = cos(a), s = sin(a); return float3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z); }

// ---------------------------------------------------------------- hashing
inline uint ws_pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
inline uint2 ws_pcg2(uint2 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * 1664525u; v.y += v.x * 1664525u;
    v = v ^ (v >> 16u);
    v.x += v.y * 1664525u; v.y += v.x * 1664525u;
    v = v ^ (v >> 16u);
    return v;
}
inline uint3 ws_pcg3(uint3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}
inline uint4 ws_pcg4(uint4 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    v ^= v >> 16u;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    return v;
}
constant float WS_INV_U32 = 1.0 / 4294967296.0;

// Float-input hashes: distinct float inputs -> independent values in [0,1).
inline float  hash11(float p)  { return float(ws_pcg(as_type<uint>(p))) * WS_INV_U32; }
inline float  hash12(float2 p) { return float(ws_pcg2(as_type<uint2>(p)).x) * WS_INV_U32; }
inline float2 hash22(float2 p) { return float2(ws_pcg2(as_type<uint2>(p))) * WS_INV_U32; }
inline float  hash13(float3 p) { return float(ws_pcg3(as_type<uint3>(p)).x) * WS_INV_U32; }
inline float3 hash33(float3 p) { return float3(ws_pcg3(as_type<uint3>(p))) * WS_INV_U32; }
inline float4 hash44(float4 p) { return float4(ws_pcg4(as_type<uint4>(p))) * WS_INV_U32; }
inline float4 hash24(float2 p) { return float4(ws_pcg4(uint4(as_type<uint2>(p), 0x9e3779b9u, 0x85ebca6bu))) * WS_INV_U32; }

// Integer-lattice hashes
inline float ws_h2i(int2 c) { return float(ws_pcg2(as_type<uint2>(c)).x) * WS_INV_U32; }
inline float ws_h3i(int3 c) { return float(ws_pcg3(as_type<uint3>(c)).x) * WS_INV_U32; }

// ---------------------------------------------------------------- noise
inline float2 ws_q5(float2 f) { return f * f * f * (f * (f * 6.0 - 15.0) + 10.0); }
inline float3 ws_q5(float3 f) { return f * f * f * (f * (f * 6.0 - 15.0) + 10.0); }
inline int ws_wrap(int v, int p) { return p > 0 ? ((v % p) + p) % p : v; }

inline float2 ws_g2(int2 c) {
    uint h = ws_pcg2(as_type<uint2>(c)).x;
    float a = float(h) * (TAU * WS_INV_U32);
    return float2(cos(a), sin(a));
}
inline float3 ws_g3(int3 c) {
    uint3 h = ws_pcg3(as_type<uint3>(c));
    float z = float(h.x) * WS_INV_U32 * 2.0 - 1.0;
    float a = float(h.y) * WS_INV_U32 * TAU;
    float r = sqrt(max(0.0, 1.0 - z * z));
    return float3(r * cos(a), r * sin(a), z);
}

// 2D gradient noise, ~[-1,1]
inline float gnoise(float2 p) {
    float2 i = floor(p); float2 f = p - i;
    int2 c = int2(i);
    float2 u = ws_q5(f);
    float a = dot(ws_g2(c),              f);
    float b = dot(ws_g2(c + int2(1, 0)), f - float2(1, 0));
    float d = dot(ws_g2(c + int2(0, 1)), f - float2(0, 1));
    float e = dot(ws_g2(c + int2(1, 1)), f - float2(1, 1));
    return 1.4142 * mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

// 3D gradient noise, periodic along z with integer period (0 = not periodic). ~[-1,1]
inline float gnoise3p(float3 p, int periodZ) {
    float3 i = floor(p); float3 f = p - i;
    int3 c = int3(i);
    float3 u = ws_q5(f);
    int z0 = ws_wrap(c.z, periodZ);
    int z1 = ws_wrap(c.z + 1, periodZ);
    float n000 = dot(ws_g3(int3(c.x,     c.y,     z0)), f - float3(0, 0, 0));
    float n100 = dot(ws_g3(int3(c.x + 1, c.y,     z0)), f - float3(1, 0, 0));
    float n010 = dot(ws_g3(int3(c.x,     c.y + 1, z0)), f - float3(0, 1, 0));
    float n110 = dot(ws_g3(int3(c.x + 1, c.y + 1, z0)), f - float3(1, 1, 0));
    float n001 = dot(ws_g3(int3(c.x,     c.y,     z1)), f - float3(0, 0, 1));
    float n101 = dot(ws_g3(int3(c.x + 1, c.y,     z1)), f - float3(1, 0, 1));
    float n011 = dot(ws_g3(int3(c.x,     c.y + 1, z1)), f - float3(0, 1, 1));
    float n111 = dot(ws_g3(int3(c.x + 1, c.y + 1, z1)), f - float3(1, 1, 1));
    float nx00 = mix(n000, n100, u.x), nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x), nx11 = mix(n011, n111, u.x);
    return 1.1547 * mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z);
}
inline float gnoise(float3 p) { return gnoise3p(p, 0); }

// Value noise in [0,1] (cheaper, blobbier)
inline float vnoise(float2 p) {
    float2 i = floor(p); float2 f = p - i;
    int2 c = int2(i);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = ws_h2i(c), b = ws_h2i(c + int2(1, 0));
    float d = ws_h2i(c + int2(0, 1)), e = ws_h2i(c + int2(1, 1));
    return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}
inline float vnoise3p(float3 p, int periodZ) {
    float3 i = floor(p); float3 f = p - i;
    int3 c = int3(i);
    float3 u = f * f * (3.0 - 2.0 * f);
    int z0 = ws_wrap(c.z, periodZ), z1 = ws_wrap(c.z + 1, periodZ);
    float a = ws_h3i(int3(c.x, c.y, z0)),     b = ws_h3i(int3(c.x + 1, c.y, z0));
    float d = ws_h3i(int3(c.x, c.y + 1, z0)), e = ws_h3i(int3(c.x + 1, c.y + 1, z0));
    float a2 = ws_h3i(int3(c.x, c.y, z1)),     b2 = ws_h3i(int3(c.x + 1, c.y, z1));
    float d2 = ws_h3i(int3(c.x, c.y + 1, z1)), e2 = ws_h3i(int3(c.x + 1, c.y + 1, z1));
    return mix(mix(mix(a, b, u.x), mix(d, e, u.x), u.y),
               mix(mix(a2, b2, u.x), mix(d2, e2, u.x), u.y), u.z);
}
inline float vnoise(float3 p) { return vnoise3p(p, 0); }

constant float2x2 WS_ROT2 = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
constant float3x3 WS_ROT3 = float3x3(float3( 0.00,  0.80,  0.60),
                                     float3(-0.80,  0.36, -0.48),
                                     float3(-0.60, -0.48,  0.64));

// fBm of gradient noise, normalized to ~[-1,1]
inline float fbm(float2 p, int octaves) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < octaves; i++) {
        s += a * gnoise(p); n += a;
        p = WS_ROT2 * p * 2.02 + float2(17.1, 3.7);
        a *= 0.5;
    }
    return s / n;
}
inline float fbm(float3 p, int octaves) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < octaves; i++) {
        s += a * gnoise(p); n += a;
        p = WS_ROT3 * p * 2.03 + float3(11.3, 7.1, 3.9);
        a *= 0.5;
    }
    return s / n;
}
// Ridged multifractal in [0,1] — sharp crests (mountains, lightning, cracks)
inline float ridged(float2 p, int octaves) {
    float s = 0.0, a = 0.5, n = 0.0, w = 1.0;
    for (int i = 0; i < octaves; i++) {
        float r = 1.0 - abs(gnoise(p));
        r *= r * w;
        w = clamp(r * 2.0, 0.0, 1.0);
        s += a * r; n += a;
        p = WS_ROT2 * p * 2.05 + float2(5.3, 9.1);
        a *= 0.5;
    }
    return s / n;
}

// LOOP-SAFE evolving noise: the phase t in [0,1) drives a periodic lattice
// axis, so fbmLoop(p, 0) == fbmLoop(p, 1) exactly. `speed` = integer number
// of noise "cycles" per loop (higher = faster evolution).
inline float gnoiseLoop(float2 p, float t, int speed) {
    return gnoise3p(float3(p, t * float(speed)), speed);
}
inline float fbmLoop(float2 p, float t, int octaves, int speed) {
    float s = 0.0, a = 0.5, n = 0.0;
    int P = max(speed, 1);
    float z = t * float(P);
    for (int i = 0; i < octaves; i++) {
        s += a * gnoise3p(float3(p, z), P); n += a;
        p = WS_ROT2 * p * 2.02 + float2(17.1, 3.7);
        z *= 2.0; P *= 2;
        a *= 0.5;
    }
    return s / n;
}

// Worley / cellular: returns (F1, F2) distances
inline float2 worley(float2 p) {
    float2 i = floor(p); float2 f = p - i;
    float d1 = 8.0, d2 = 8.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float2 g = float2(x, y);
        float2 o = hash22(i + g);
        float d = length(g + o - f);
        if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
    }
    return float2(d1, d2);
}
// Animated, LOOP-SAFE Worley: feature points orbit their cell once per loop
inline float2 worleyLoop(float2 p, float t) {
    float2 i = floor(p); float2 f = p - i;
    float d1 = 8.0, d2 = 8.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float2 g = float2(x, y);
        float4 h = hash24(i + g);
        float ang = TAU * (t * (1.0 + floor(h.w * 2.0)) + h.z);
        float2 o = 0.5 + 0.38 * float2(cos(ang + h.x * TAU), sin(ang + h.y * TAU));
        float d = length(g + o - f);
        if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
    }
    return float2(d1, d2);
}

// ---------------------------------------------------------------- color
inline float  ws_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
inline float3 ws_srgb2lin(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
inline float3 ws_lin2srgb(float3 c) { return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308); }
inline float3 ws_hex(uint rgb) { // sRGB hex -> linear
    return ws_srgb2lin(float3((rgb >> 16) & 255u, (rgb >> 8) & 255u, rgb & 255u) / 255.0);
}
inline float3 ws_hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}
// Blackbody-ish color for temperature in Kelvin (1000..12000), linear, normalized
inline float3 ws_blackbody(float k) {
    float t = clamp(k, 1000.0, 12000.0) / 100.0;
    float r = t <= 66.0 ? 1.0 : clamp(1.2929 * pow(t - 60.0, -0.1332), 0.0, 1.0);
    float g = t <= 66.0 ? clamp(0.3901 * log(t) - 0.6318, 0.0, 1.0)
                        : clamp(1.1298 * pow(t - 60.0, -0.0755), 0.0, 1.0);
    float b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : clamp(0.5432 * log(t - 10.0) - 1.1963, 0.0, 1.0));
    return ws_srgb2lin(float3(r, g, b));
}

// Tone mapping (input: linear HDR scene radiance * exposure)
inline float3 ws_aces(float3 x) {  // Narkowicz approximation
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}
inline float3 ws_acesFitted(float3 v) {  // Hill's fitted ACES RRT+ODT (better hues)
    float3 i = float3(dot(float3(0.59719, 0.35458, 0.04823), v),
                      dot(float3(0.07600, 0.90834, 0.01566), v),
                      dot(float3(0.02840, 0.13383, 0.83777), v));
    float3 a = i * (i + 0.0245786) - 0.000090537;
    float3 b = i * (0.983729 * i + 0.4329510) + 0.238081;
    float3 r = a / b;
    float3 o = float3(dot(float3( 1.60475, -0.53108, -0.07367), r),
                      dot(float3(-0.10208,  1.10813, -0.00605), r),
                      dot(float3(-0.00327, -0.07276,  1.07602), r));
    return clamp(o, 0.0, 1.0);
}
inline float3 ws_saturate(float3 c, float s) { return mix(float3(ws_luma(c)), c, s); }
inline float ws_vignette(float2 uv01, float strength) {
    float2 q = uv01 - 0.5;
    return 1.0 - strength * dot(q, q) * 1.6;
}
// Subtle film grain in [-1,1]; loop-safe (identical at t=0 and t=1)
inline float ws_grain(float2 fragCoord, float t) {
    uint seed = uint(fract(t) * 4096.0);
    uint3 h = ws_pcg3(uint3(uint2(fragCoord), seed));
    return (float(h.x & 0xffffu) + float(h.y & 0xffffu)) / 65535.0 - 1.0;
}

// ---------------------------------------------------------------- camera / rays
inline float2x2 ws_rot(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, s), float2(-s, c)); }

// Pinhole camera. ro: eye, ta: look-at target, fovY in degrees.
inline float3 ws_camRay(float2 fragCoord, float2 res, float3 ro, float3 ta, float fovYDeg, float roll = 0.0) {
    float3 f = normalize(ta - ro);
    float3 r = normalize(cross(f, float3(sin(roll), cos(roll), 0.0)));
    float3 u = cross(r, f);
    float2 p = (2.0 * fragCoord - res) / res.y;
    float k = tan(fovYDeg * (PI / 180.0) * 0.5);
    return normalize(f + (p.x * r + p.y * u) * k);
}

// Ray-sphere (sphere at origin, rd normalized): returns (tNear, tFar);
// tNear > tFar means miss. Numerically stable even at planet scale.
inline float2 ws_raySphere(float3 ro, float3 rd, float r) {
    float lr = length(ro);
    float b = dot(ro, rd);
    float c = (lr - r) * (lr + r);
    float d = b * b - c;
    if (d < 0.0) return float2(1e5, -1e5);
    float sq = sqrt(d);
    float q = -b - (b >= 0.0 ? sq : -sq);
    float t0 = q;
    float t1 = (q != 0.0) ? c / q : -b;
    return float2(min(t0, t1), max(t0, t1));
}

// ---------------------------------------------------------------- sky
// Physically based single-scattering atmosphere (Rayleigh + Mie).
// rd: view dir (y up). sunDir: direction TO the sun (normalized).
// Returns linear radiance; typical exposure before tone mapping ~0.5–2.
inline float3 ws_atmosphere(float3 rd, float3 sunDir, float sunIntensity = 22.0,
                            float mieG = 0.758, float mieStrength = 1.0, float altitude = 100.0) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kRlh = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kMie = 21e-6 * mieStrength;
    const float shRlh = 8e3, shMie = 1.2e3;
    const int iSteps = 16, jSteps = 8;
    float3 r0 = float3(0.0, Rp + max(altitude, 1.0), 0.0);
    float3 r = normalize(rd);
    float2 p = ws_raySphere(r0, r, Ra);
    if (p.x > p.y || p.y < 0.0) return float3(0.0);
    p.x = max(p.x, 0.0);
    float2 pg = ws_raySphere(r0, r, Rp);
    if (pg.x <= pg.y && pg.x > 0.0) p.y = min(p.y, pg.x);
    float iStep = (p.y - p.x) / float(iSteps);
    float iTime = p.x;
    float3 totRlh = float3(0.0), totMie = float3(0.0);
    float iOdRlh = 0.0, iOdMie = 0.0;
    float mu = dot(r, sunDir), mumu = mu * mu, gg = mieG * mieG;
    float pRlh = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pMie = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) /
                 (pow(1.0 + gg - 2.0 * mu * mieG, 1.5) * (2.0 + gg));
    for (int i = 0; i < iSteps; i++) {
        float3 iPos = r0 + r * (iTime + iStep * 0.5);
        float iH = length(iPos) - Rp;
        float odR = exp(-iH / shRlh) * iStep;
        float odM = exp(-iH / shMie) * iStep;
        iOdRlh += odR; iOdMie += odM;
        // Earth's shadow: sample points whose sun ray hits the planet get no direct light.
        float2 sg = ws_raySphere(iPos, sunDir, Rp);
        if (sg.x <= sg.y && sg.x > 0.0) { iTime += iStep; continue; }
        float jStep = ws_raySphere(iPos, sunDir, Ra).y / float(jSteps);
        float jTime = 0.0, jOdRlh = 0.0, jOdMie = 0.0;
        for (int j = 0; j < jSteps; j++) {
            float3 jPos = iPos + sunDir * (jTime + jStep * 0.5);
            float jH = length(jPos) - Rp;
            jOdRlh += exp(-jH / shRlh) * jStep;
            jOdMie += exp(-jH / shMie) * jStep;
            jTime += jStep;
        }
        float3 attn = exp(-(kMie * (iOdMie + jOdMie) + kRlh * (iOdRlh + jOdRlh)));
        totRlh += odR * attn;
        totMie += odM * attn;
        iTime += iStep;
    }
    return sunIntensity * (pRlh * kRlh * totRlh + pMie * kMie * totMie);
}

// Cheaper sky for REAL-TIME (dynamic) wallpapers: 8 view steps x 4 light steps
// (~4x faster than ws_atmosphere, visually very close).
inline float3 ws_atmosphereFast(float3 rd, float3 sunDir, float sunIntensity = 22.0,
                                float mieG = 0.758, float altitude = 100.0) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kRlh = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kMie = 21e-6;
    const float shRlh = 8e3, shMie = 1.2e3;
    const int iSteps = 8, jSteps = 4;
    float3 r0 = float3(0.0, Rp + max(altitude, 1.0), 0.0);
    float3 r = normalize(rd);
    float2 p = ws_raySphere(r0, r, Ra);
    if (p.x > p.y || p.y < 0.0) return float3(0.0);
    p.x = max(p.x, 0.0);
    float2 pg = ws_raySphere(r0, r, Rp);
    if (pg.x <= pg.y && pg.x > 0.0) p.y = min(p.y, pg.x);
    float iStep = (p.y - p.x) / float(iSteps);
    float iTime = p.x;
    float3 totRlh = float3(0.0), totMie = float3(0.0);
    float iOdRlh = 0.0, iOdMie = 0.0;
    float mu = dot(r, sunDir), mumu = mu * mu, gg = mieG * mieG;
    float pRlh = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pMie = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) /
                 (pow(1.0 + gg - 2.0 * mu * mieG, 1.5) * (2.0 + gg));
    for (int i = 0; i < iSteps; i++) {
        float3 iPos = r0 + r * (iTime + iStep * 0.5);
        float iH = length(iPos) - Rp;
        float odR = exp(-iH / shRlh) * iStep;
        float odM = exp(-iH / shMie) * iStep;
        iOdRlh += odR; iOdMie += odM;
        float2 sg = ws_raySphere(iPos, sunDir, Rp);
        if (sg.x <= sg.y && sg.x > 0.0) { iTime += iStep; continue; }
        float jStep = ws_raySphere(iPos, sunDir, Ra).y / float(jSteps);
        float jTime = 0.0, jOdRlh = 0.0, jOdMie = 0.0;
        for (int j = 0; j < jSteps; j++) {
            float3 jPos = iPos + sunDir * (jTime + jStep * 0.5);
            float jH = length(jPos) - Rp;
            jOdRlh += exp(-jH / shRlh) * jStep;
            jOdMie += exp(-jH / shMie) * jStep;
            jTime += jStep;
        }
        float3 attn = exp(-(kMie * (iOdMie + jOdMie) + kRlh * (iOdRlh + jOdRlh)));
        totRlh += odR * attn;
        totMie += odM * attn;
        iTime += iStep;
    }
    return sunIntensity * (pRlh * kRlh * totRlh + pMie * kMie * totMie);
}

// Soft sun disk with limb darkening; add on top of the sky.
inline float3 ws_sunDisk(float3 rd, float3 sunDir, float angularRadiusDeg, float3 radiance) {
    float c = dot(normalize(rd), sunDir);
    float r = angularRadiusDeg * (PI / 180.0);
    float ang = acos(clamp(c, -1.0, 1.0));
    float x = clamp(ang / r, 0.0, 1.0);
    float limb = sqrt(max(0.0, 1.0 - x * x));
    float edge = 1.0 - smoothstep(0.92, 1.0, ang / r);
    return radiance * edge * (0.4 + 0.6 * limb);
}

// Star field on any 2D domain (use direction-derived coords for skies).
// cells: stars per unit (e.g. 40–120). Twinkle is loop-safe.
inline float3 ws_stars(float2 p, float cells, float t, float twinkle = 0.35) {
    float3 col = float3(0.0);
    for (int layer = 0; layer < 3; layer++) {
        float sc = cells * (1.0 + float(layer) * 1.618);
        float2 q = p * sc + float(layer) * 37.17;
        float2 id = floor(q);
        float2 f = q - id - 0.5;
        float4 h = hash24(id + float(layer) * 101.0);
        if (h.x > 0.42) continue;
        float2 pos = (h.yz - 0.5) * 0.72;
        float d = length(f - pos);
        float mag = pow(h.w, 7.0);
        float size = 0.035 + 0.05 * mag;
        float core = exp(-d * d / (size * size * 0.18));
        float tw = 1.0 - twinkle + twinkle * (0.5 + 0.5 * sin(TAU * (t * (1.0 + floor(h.y * 3.0)) + h.z)));
        float3 tint = mix(float3(1.0, 0.72, 0.52), float3(0.68, 0.8, 1.0), smoothstep(0.1, 0.9, h.y));
        col += tint * core * (0.15 + 2.2 * mag) * tw / (1.0 + float(layer));
    }
    return col;
}

// Exponential height fog / aerial perspective blend factor
inline float ws_fogAmount(float dist, float3 ro, float3 rd, float density, float heightFalloff) {
    float k = rd.y * heightFalloff;
    float integral = abs(k) < 1e-4 ? dist : (1.0 - exp(-dist * k)) / k;
    float fog = density * exp(-ro.y * heightFalloff) * integral;
    return clamp(1.0 - exp(-fog), 0.0, 1.0);
}
