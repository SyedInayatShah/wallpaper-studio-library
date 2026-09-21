// ============================================================================
//  Stellar Nursery — emission nebula. Volumetric (3D raymarched) dust cliffs
//  and pillars carved by a young blue-white cluster; HOO + gold ionised gas
//  behind; deep reddened star field.
//
//  Dust: 3D domain-warped fBm density on a sloped cliff + capsule pillars.
//  Lit by the cluster with a short shadow march: the UV (ionising) light dies
//  in a thin skin -> bright ionisation fronts on every surface facing the
//  cluster; softer scattered starlight reaches deeper (warm brown faces);
//  extinction is chromatic (dust reddens what shines through it).
//  Gas / stars: image-space layers behind the dust (multiplied by its
//  transmittance), cluster + bright field stars in front.
// ============================================================================

// ---------------------------------------------------------------- 2D noise (trig-free)
inline float2 sn_g2(int2 c) {
    uint h = ws_pcg(uint(c.x) * 73856093u ^ uint(c.y) * 19349663u);
    return float2(float(h & 0xffffu), float(h >> 16)) * (2.0 / 65535.0) - 1.0;
}
inline float sn_n2(float2 p) {
    float2 i = floor(p); float2 f = p - i; int2 c = int2(i);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(sn_g2(c),              f);
    float b = dot(sn_g2(c + int2(1, 0)), f - float2(1, 0));
    float d = dot(sn_g2(c + int2(0, 1)), f - float2(0, 1));
    float e = dot(sn_g2(c + int2(1, 1)), f - float2(1, 1));
    return 1.5 * mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}
constant float2x2 SN_R = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
inline float sn_fbm(float2 p, int oct, float gain) {
    float s = 0.0, a = 1.0, n = 0.0;
    for (int i = 0; i < oct; i++) {
        s += a * sn_n2(p); n += a;
        p = SN_R * p * 2.03 + float2(1.7, 9.2);
        a *= gain;
    }
    return s / n;
}
inline float sn_ridge(float2 p, int oct, float gain) {    // ~[0,1]
    float s = 0.0, a = 1.0, n = 0.0;
    for (int i = 0; i < oct; i++) {
        float r = 1.0 - abs(sn_n2(p));
        s += a * r * r; n += a;
        p = SN_R * p * 2.11 + float2(7.3, 2.9);
        a *= gain;
    }
    return s / n;
}
inline float sn_smax(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
    return mix(b, a, h) + k * h * (1.0 - h);
}
inline float sn_smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// ---------------------------------------------------------------- 3D noise (trig-free)
inline float3 sn_g3(int3 c) {
    uint h = ws_pcg(uint(c.x) * 73856093u ^ uint(c.y) * 19349663u ^ uint(c.z) * 83492791u);
    return float3(float(h & 1023u), float((h >> 10) & 1023u), float((h >> 20) & 1023u)) * (2.0 / 1023.0) - 1.0;
}
inline float sn_n3(float3 p) {
    float3 i = floor(p); float3 f = p - i; int3 c = int3(i);
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float n000 = dot(sn_g3(c),                f);
    float n100 = dot(sn_g3(c + int3(1, 0, 0)), f - float3(1, 0, 0));
    float n010 = dot(sn_g3(c + int3(0, 1, 0)), f - float3(0, 1, 0));
    float n110 = dot(sn_g3(c + int3(1, 1, 0)), f - float3(1, 1, 0));
    float n001 = dot(sn_g3(c + int3(0, 0, 1)), f - float3(0, 0, 1));
    float n101 = dot(sn_g3(c + int3(1, 0, 1)), f - float3(1, 0, 1));
    float n011 = dot(sn_g3(c + int3(0, 1, 1)), f - float3(0, 1, 1));
    float n111 = dot(sn_g3(c + int3(1, 1, 1)), f - float3(1, 1, 1));
    float nx00 = mix(n000, n100, u.x), nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x), nx11 = mix(n011, n111, u.x);
    return 1.1 * mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z);
}
constant float3x3 SN_R3 = float3x3(float3( 0.00,  0.80,  0.60),
                                   float3(-0.80,  0.36, -0.48),
                                   float3(-0.60, -0.48,  0.64));
inline float sn_fbm3(float3 p, int oct, float gain) {
    float s = 0.0, a = 1.0, n = 0.0;
    for (int i = 0; i < oct; i++) {
        s += a * sn_n3(p); n += a;
        p = SN_R3 * p * 2.05 + float3(1.3, 7.1, 3.9);
        a *= gain;
    }
    return s / n;
}
// ridged 3D fbm, ~[0,1] with mean ~0.5 -> sharp sheets and filaments
inline float sn_rfbm3(float3 p, int oct, float gain) {
    float s = 0.0, a = 1.0, n = 0.0;
    for (int i = 0; i < oct; i++) {
        float r = 1.0 - abs(sn_n3(p) * 1.35);
        s += a * r * r; n += a;
        p = SN_R3 * p * 2.11 + float3(5.1, 1.7, 8.3);
        a *= gain;
    }
    return s / n;
}

// ---------------------------------------------------------------- layout
constant float  SN_K  = 0.55;                          // tan(fov/2)
constant float3 SN_CL = float3(-2.55, 2.10, 11.0);     // ionising cluster (world), behind the crest
constant float2 SN_S  = float2(-0.4215, 0.347);         // its screen position

// lumpy capsule pillar (base a -> tip b); >0 inside
inline float sn_capsule(float3 P, float3 a, float3 b, float r0, float r1, float seed) {
    float3 ab = b - a; float L2 = dot(ab, ab);
    float t = clamp(dot(P - a, ab) / L2, 0.0, 1.0);
    float3 c = a + ab * t;
    c.x += 0.14 * sin(t * 2.2 + seed) * t;                     // gentle lean
    float d = length(P - c);
    float r = mix(r0, r1, pow(t, 0.8)) * (1.0 + 0.28 * sn_n2(float2(t * 5.0, seed)))
            + 0.75 * r1 * exp(-(t - 0.88) * (t - 0.88) * 42.0);   // knob at the tip
    return r - d;
}

// macro inside-ness in world units (>0 inside dust)
inline float sn_macro(float3 P) {
    float x = P.x, y = P.y, z = P.z;
    float2 xz = float2(x, z);
    float h = -3.15 + 0.10 * (z - 6.0);
    float nearL = smoothstep(-1.2, -7.5, x);
    h += 0.55 * nearL;
    h -= 0.55 * exp(-(x + 3.6) * (x + 3.6) * 0.06);        // cavity under the cluster
    h += 0.75 * smoothstep(1.0, 9.0, x);                   // ridge lifts again to the right
    h += 2.25 * sn_fbm(xz * 0.17 + 3.1, 4, 0.5);
    h += 0.80 * sn_fbm(xz * 0.50 + 7.0, 3, 0.5);
    h += 0.85 * pow(sn_ridge(xz * 0.42 + 2.4, 4, 0.55), 2.2);        // sharp spires on the crest
    // front wall facing the camera, leaning back with height; the crest is where it meets the top
    float2 xy = float2(x, y);
    float zw = 7.6 - 0.55 * nearL - 0.14 * (y + 2.0) + 1.25 * sn_fbm(xy * 0.24 + 5.5, 4, 0.5) + 0.42 * sn_fbm(xy * 0.62 + 2.2, 3, 0.5);
    float m = sn_smin(h - y, z - zw, 0.22);
    m = min(m, 13.8 - z);                                     // back wall
    // foreground bank of dust, well in front of the wall: the wall shadows it,
    // so it reads as a dark silhouette with only a thin rim where it rises clear
    {
        float zg = min(z - 2.9, 6.5 - z);
        float nearM = zg;
        if (zg > -4.4) {                    // outside the slab the bank cannot bind
            float2 nz = float2(x, z);
            float hn = -2.50 + 1.95 * smoothstep(-0.2, -5.2, x)
                     + 0.95 * sn_fbm(nz * 0.34 + 13.0, 4, 0.5)
                     + 0.60 * pow(sn_ridge(nz * 0.62 + 4.0, 4, 0.55), 2.0)
                     + 0.34 * sn_fbm(nz * 1.45 + 21.0, 5, 0.55)
                     + 0.20 * pow(sn_ridge(nz * 2.6 + 6.0, 4, 0.55), 2.5);   // eroded, serrated edge
            nearM = min(hn - y, zg);
        }
        m = sn_smax(m, nearM, 0.35);
    }
    float pl = -10.0;
    if (z > 5.5 && z < 14.0) {
    pl = max(pl, sn_capsule(P, float3( 0.40, -3.2, 8.6), float3( 0.02,  2.15, 8.4), 0.78, 0.17, 1.0));
    pl = max(pl, sn_capsule(P, float3( 2.20, -2.6, 9.6), float3( 1.55,  1.15, 9.4), 0.50, 0.16, 5.0));
    pl = max(pl, sn_capsule(P, float3(-3.30, -3.6, 7.2), float3(-3.90, -1.40, 7.1), 0.42, 0.18, 9.0));
    pl = max(pl, sn_capsule(P, float3( 4.60, -2.2, 11.0), float3( 4.00, -0.30, 10.9), 0.50, 0.20, 13.0));
    pl = max(pl, sn_capsule(P, float3(-1.55, -2.4, 8.0), float3(-2.05,  0.35, 7.9), 0.34, 0.13, 21.0));
    pl = max(pl, sn_capsule(P, float3( 6.90, -1.4, 12.2), float3( 6.35,  0.95, 12.1), 0.55, 0.20, 17.0));
    pl = max(pl, sn_capsule(P, float3(-5.40, -3.2, 9.0), float3(-5.85, -0.85, 8.9), 0.40, 0.15, 29.0));
    }
    return sn_smax(m, pl, 0.5);
}

// scaled field: m>0 inside. oct = fractal octaves. mlow = smooth (macro) part.
inline float sn_field(float3 P, int oct, thread float& mlow) {
    float3 q = P * 0.42;
    float3 w = float3(sn_n3(q + float3(1.7, 9.2, 3.1)),
                      sn_n3(q + float3(8.3, 2.8, 5.7)),
                      sn_n3(q + float3(4.1, 6.6, 1.2)));
    float3 W = P + 0.95 * w;
    float m = sn_macro(W) / 0.9;
    mlow = m;
    if (m < -1.4) return m;                                   // far outside: no detail needed
    if (oct <= 2) {          // shadow / gradient taps: macro shape only, no fine warp
        float3 ldc = normalize(SN_CL - W);
        float3 Wc = W - ldc * (dot(W, ldc) * 0.18);
        m += 0.80 * sn_fbm3(Wc * 1.05, 2, 0.705);
        m += 0.265 * (sn_rfbm3(Wc * 1.45, 2, 0.62) - 0.46);
        return m;
    }
    // fine turbulent warp -> wisps and swirls instead of cauliflower.
    // the warp amplitude itself varies through space, so no one shear scale
    // stamps a repeating rhythm on the folds.
    float wv = 0.5 + 0.5 * sn_n3(W * 0.265 + 91.0);
    float3 q2 = W * (1.75 + 1.25 * wv);
    W += (0.17 + 0.24 * wv) * float3(sn_n3(q2 + float3(3.3, 1.1, 7.7)), sn_n3(q2 + float3(6.2, 8.9, 0.4)), sn_n3(q2 + float3(0.9, 4.4, 5.5)));
    // erosion is anisotropic: compress the noise domain along the line to the
    // ionising cluster so wisps stream away from it (elephant-trunk look)
    float3 ld = normalize(SN_CL - W);
    float3 Wa = W - ld * (dot(W, ld) * 0.18);
    m += 0.80 * sn_fbm3(Wa * 1.05, oct, 0.705);
    // filaments / sheets. Drift the ridged term's base frequency AND amplitude
    // through the volume: at a fixed frequency it lays down parallel ripples of
    // one wavelength, which reads as procedural drapery rather than turbulence.
    float fq = 1.45 * exp(1.05 * (wv - 0.5));
    m += (0.16 + 0.21 * wv) * (sn_rfbm3(Wa * fq, max(oct - 2, 3), 0.62) - 0.46);
    if (oct >= 5) {
        // filaments inside filaments: a far finer ridged octave, gated to the
        // skin (|m| small) where it is visible instead of everywhere
        float band = exp(-m * m * 2.4);
        m += (0.085 + 0.060 * (1.0 - wv)) * band * (sn_rfbm3(Wa * (5.3 * fq) + 71.0, 3, 0.58) - 0.44);
    }
    if (oct >= 6 && P.z < 7.8) {              // near bank: it is magnified, so it needs more scales
        float nf = smoothstep(7.8, 3.2, P.z);
        m += 0.125 * nf * sn_fbm3(W * 5.6 + 33.0, 4, 0.60);
        m += 0.085 * nf * exp(-m * m * 3.2) * (sn_rfbm3(W * 15.0 + 5.0, 3, 0.58) - 0.44);
        // steepen the field near the camera: at this magnification a soft ramp
        // reads as mush, and the silhouette has to cut
        m *= 1.0 + 0.40 * nf;
    }
    return m;
}
inline float sn_densOf(float m) {
    float d = smoothstep(0.0, 0.035, m);
    return d * (0.06 + 0.94 * smoothstep(0.0, 0.80, m));
}
// lognormal clumping of the medium (knots and sheets)
inline float sn_clump(float3 P) { return exp(0.8 * sn_fbm3(P * 3.1 + 17.0, 3, 0.6)) * 0.75; }

// ---------------------------------------------------------------- stars
inline float3 sn_starColor(float h) {
    float T = h < 0.12 ? mix(2800.0, 3700.0, h / 0.12)
            : h < 0.55 ? mix(3700.0, 5600.0, (h - 0.12) / 0.43)
            : h < 0.85 ? mix(5600.0, 7500.0, (h - 0.55) / 0.30)
            :            mix(7500.0, 12000.0, (h - 0.85) / 0.15);
    float3 c = ws_blackbody(T);
    return c / max(ws_luma(c), 1e-3);
}
inline float sn_psf(float r2, float sig) {
    float core = exp(-r2 / (2.0 * sig * sig)) / (6.2832 * sig * sig);
    const float a2 = 9.0;
    float q = 1.0 + r2 / a2;
    float halo = (1.0 / (3.1416 * a2)) / (q * q);
    const float b2 = 1600.0;
    float q2 = 1.0 + r2 / b2;
    float wide = (0.5 / (3.1416 * b2)) / (q2 * sqrt(q2));
    return 0.90 * core + 0.085 * halo + 0.015 * wide;
}
inline float sn_flux(float m) { return pow(10.0, -0.4 * (m - 12.0)); }
// Diffraction spikes. Real ones are never a clean symmetric asterisk: the arms
// differ in length and brightness, sit a fraction of a degree off the ideal
// angle, and are ragged along their length. seed varies all of that per star.
inline float sn_spikes(float2 d, float sig, float seed, float lenS) {
    float s = 0.0;
    float4 ha = hash24(float2(seed * 1.7 + 3.3, 3.77));
    float4 hb = hash24(float2(seed * 1.7 + 3.3, 8.13));
    for (int k = 0; k < 4; k++) {
        float a = PI * 0.5 + float(k) * (PI / 3.0);
        float w = 1.0;
        if (k == 3) { a = 0.0; w = 0.35; }
        float hk = ha[k], hl = hb[k];
        a += (hk - 0.5) * 0.085;
        w *= 0.42 + 1.20 * hl;
        float len = (2.1 + 2.6 * hk) * lenS;
        float2 dir = float2(cos(a), sin(a));
        float along = abs(dot(d, dir));
        float perp = dot(d, float2(-dir.y, dir.x));
        float wob = 0.55 + 0.75 * (0.5 + 0.5 * sn_n2(float2(along * 0.024 + seed * 2.7, float(k) * 5.9)));
        s += w * wob * exp(-perp * perp / (2.0 * sig * sig * 1.3)) / pow(1.0 + along / len, 2.1);
    }
    return s;
}
// PSF with a real optical system's faults: lateral chromatic aberration and
// radial coma that both grow toward the frame corners.
inline float3 sn_psfC(float2 d, float sig, float2 rv) {
    float q = dot(rv, rv);
    float rr = min(q * 0.281, 1.0);          // 1.0 at the frame corners
    float2 rdir = q > 1e-9 ? rv * rsqrt(q) : float2(1.0, 0.0);
    float el = 1.0 + 0.45 * rr;
    float sh = 1.7 * rr;
    float3 o;
    for (int c = 0; c < 3; c++) {
        float2 dc = d + rdir * (sh * (float(c) - 1.0));
        float al = dot(dc, rdir), pe = dot(dc, float2(-rdir.y, rdir.x));
        o[c] = sn_psf((al * al) / (el * el) + pe * pe, sig);
    }
    return o;
}
inline float3 sn_starLayer(float2 qpx, float cellPx, float prob, float mBright, float mFaint,
                           float sig, float seed, bool nb) {
    float3 acc = float3(0.0);
    float2 id0 = floor(qpx / cellPx);
    int R = nb ? 1 : 0;
    for (int j = -R; j <= R; j++)
    for (int i = -R; i <= R; i++) {
        float2 id = id0 + float2(i, j);
        float4 h = hash24(id + seed);
        if (h.x > prob) continue;
        float4 h2 = hash24(id + seed + 71.3);
        float2 pos = (id + 0.5 + (h.yz - 0.5) * (nb ? 0.9 : 0.62)) * cellPx;
        float2 d = qpx - pos;
        float m = max(mFaint + log10(max(h2.w, 1e-6)) / 0.33, mBright);
        float r2 = dot(d, d);
        float psf = nb ? sn_psf(r2, sig) : exp(-r2 / (2.0 * sig * sig)) / (6.2832 * sig * sig);
        if (m < 6.0) psf += 0.00034 * sn_spikes(d, sig, dot(id, float2(1.0, 37.0)) + seed, 0.55) * smoothstep(6.0, 4.6, m);
        // an evolved field: skew the temperature distribution cool so orange and
        // red giants punctuate the blue-white, instead of one uniform cast
        acc += sn_starColor(pow(h2.x, 1.55)) * sn_flux(m) * psf;
    }
    return acc;
}

// ---------------------------------------------------------------- scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
    float  pxScale = 2400.0 / ctx.res.y;
    float2 qpx = fragCoord * pxScale;
    float  sig = max(0.85, 0.5 * pxScale);
    float  rnd = hash12(fragCoord * 1.37 + 0.5);

    // Off the stock Hubble-palette split on purpose: H-alpha sits at a true
    // hydrogen red rather than magenta, and the O III cavity is a duller,
    // greener aqua than the usual saturated cyan, so the two-colour separation
    // reads as chemistry rather than as a preset grade.
    const float3 cHa   = float3(1.00, 0.120, 0.150);
    const float3 cO3   = float3(0.075, 0.575, 0.610);
    const float3 cGold = float3(1.00, 0.52, 0.17);
    const float3 cRefl = float3(0.52, 0.68, 1.00);

    float2 rel = p - SN_S;
    float  rS  = length(rel);

    // ================================================ background gas (H II region)
    float2 bq = float2(sn_fbm(p * 0.9 + 3.3, 5, 0.5), sn_fbm(p * 0.9 + 7.1, 5, 0.5));
    float2 bw = p + 0.18 * bq;
    bw += 0.018 * float2(sn_fbm(bw * 11.0 + 1.3, 4, 0.5), sn_fbm(bw * 11.0 + 6.1, 4, 0.5));
    float2 bc = (bw - SN_S) * float2(0.88, 1.05);
    float rb = length(bc);
    float ab = atan2(bc.y, bc.x);
    float R0 = 0.66 + 0.16 * sn_fbm(float2(ab * 1.3, 1.7), 3, 0.5);
    float dr = rb - R0;
    float side = 0.35 + 0.65 * smoothstep(-0.3, 0.8, dot(normalize(bc), normalize(float2(0.9, -0.6))));
    float shell = exp(-dr * dr / (dr < 0.0 ? 0.030 : 0.10)) * side;
    float inner = smoothstep(R0 + 0.05, 0.0, rb * (1.0 + 0.35 * sn_fbm(bw * 2.0 + 31.0, 4, 0.5)));
    float halo  = exp(-rb * rb / 2.4);
    float big   = sn_fbm(bw * 1.7 + 11.0, 8, 0.60);
    float fine  = sn_fbm(bw * 7.0 + 2.0 * bq + 3.0, 6, 0.62);
    float fil   = sn_ridge(bw * 3.0 + 1.3 * bq, 5, 0.55);
    float fine2 = sn_fbm(p * 22.0 + 0.6 * bq, 5, 0.6);
    float fil2  = sn_ridge(bw * 8.5 + 2.2 * bq + 6.7, 4, 0.55);
    float fil3  = sn_ridge(bw * 15.0 + 3.1 * bq + 12.9, 4, 0.55);
    float dHa   = exp(2.6 * big + 0.8 * fine + 0.45 * fine2)
                * (0.46 + 1.15 * pow(fil, 5.0) + 0.55 * pow(fil2, 7.0) + 0.40 * pow(fil3, 9.0));
    float dO3   = exp(2.8 * sn_fbm(bw * 2.4 + 23.0, 7, 0.62) + 0.7 * fine + 0.5 * fine2) * 0.7;
    float tauL  = 0.44 * exp(3.2 * sn_fbm(bw * 2.3 + 5.0, 8, 0.60));
    {   // winding translucent dust lane crossing the upper-left glow
        float2 lw = p + 0.06 * bq + 0.012 * float2(sn_fbm(p * 14.0 + 2.0, 4, 0.55), 0.0);
        float yc = 0.64 - 0.24 * smoothstep(-1.75, -0.70, lw.x) + 0.035 * sin(4.0 * lw.x + 1.0);
        float wd = 0.062 * (0.35 + 0.65 * smoothstep(-0.70, -1.05, lw.x));
        float dl = abs(lw.y - yc) / wd;
        float lane = exp(-dl * dl * 1.6) * smoothstep(-0.66, -0.98, lw.x);
        tauL += 1.2 * lane * exp(1.2 * sn_fbm(p * 18.0 + 8.0, 5, 0.6));
    }
    tauL += 0.24 * exp(2.6 * sn_fbm(bw * 9.0 + 0.8 * bq + 3.0, 6, 0.6));
    tauL += 0.55 * pow(sn_ridge(bw * 2.1 + 0.9 * bq + 44.0, 5, 0.55), 6.0);   // dark dust filaments
    tauL += 0.62 * pow(sn_ridge(bw * 1.35 + 0.6 * bq + 61.0, 4, 0.52), 5.0)
          * smoothstep(0.25, -1.20, p.x);
    float sheet = pow(sn_ridge(bw * 4.5 + 0.7 * float2(fine, fine2) + 9.0, 5, 0.5), 10.0);
    float calm = smoothstep(0.96, 0.40, p.y) * (1.0 - 0.94 * smoothstep(0.15, 1.15, p.x) * smoothstep(-0.1, 0.62, p.y));
    float absb = exp(-tauL);
    float mott = 0.5 + 0.5 * fine;
    // dense bright gas piled up against the cliff (bottom of the glow)
    float crestY = -0.28 + 0.10 * sn_fbm(float2(p.x * 1.4, 2.7), 4, 0.55) + 0.08 * smoothstep(-0.6, 1.0, p.x);
    float bar = exp(-max(p.y - crestY, 0.0) / 0.22) * smoothstep(1.7, 0.5, rS) * 0.45;
    float haI = (shell * 1.0 + halo * 0.30 + bar * 1.2) * dHa * absb * calm * 0.52 * (0.85 + 1.4 * sheet);
    float glowLoc = (shell + halo * 0.4 + inner * 0.5) * calm;
    float o3I = inner * dO3 * exp(-tauL * 0.8) * calm * 0.55;
    float3 cHaB = float3(1.00, 0.255, 0.290);
    float3 haCol = mix(cHa, cHaB, smoothstep(0.1, 0.6, shell * mott));
    // the two species are mixed, not zoned: mottle the hue at the boundary so
    // the transition is continuous ionised gas, not a two-tone wash
    float xm = 0.5 + 0.5 * sn_fbm(bw * 3.1 + 77.0, 4, 0.55);
    float3 o3C = mix(cO3, float3(0.235, 0.610, 0.470), xm);
    haCol = mix(haCol, mix(haCol, cGold, 0.185), xm * xm);
    float3 back = haCol * haI * 0.55 + o3C * o3I * 0.80
                + cGold * (0.135 * shell * pow(fil, 2.0) + 0.42 * bar) * dHa * absb * calm;
    back += cRefl * (exp(-rS * rS / 0.004) * 0.10 + exp(-rS * rS / 0.03) * 0.06) + cO3 * exp(-rS * rS / 0.08) * 0.05;
    back = mix(back, float3(ws_luma(back)), 0.022);   // real narrowband never separates this cleanly

    // ================================================ background stars
    float sDen = exp(0.9 * sn_fbm(p * 1.3 + 40.0, 4, 0.5));
    float3 starsBg = sn_starLayer(qpx, 4.5, 0.34 * sDen, 13.8, 17.0, sig, 9.0, false)
                   + sn_starLayer(qpx, 6.0, 0.34 * sDen, 13.4, 16.6, sig, 7.0, false)
                   + sn_starLayer(qpx, 10.0, 0.38 * sDen, 12.0, 15.8, sig, 1.0, false)
                   + sn_starLayer(qpx, 20.0, 0.30 * sDen, 10.2, 14.4, sig, 5.0, false)
                   + sn_starLayer(qpx, 60.0, 0.34, 7.0, 12.5, sig, 2.0, true);
    starsBg += float3(0.0030, 0.0026, 0.0022) * sDen * sDen;
    for (int g = 0; g < 7; g++) {
        float4 hg = hash24(float2(float(g) * 7.3, 3.1));
        float2 gp = float2(mix(0.35, 1.55, hg.x), mix(-0.95, 0.85, hg.y));
        float2 dg = ws_rot(hg.z * PI) * (p - gp) * ctx.res.y * 0.5 * pxScale;
        float ax = 3.0 + 7.0 * hg.w, ay = ax * mix(0.3, 0.8, fract(hg.w * 7.1));
        float rg = length(dg / float2(ax, ay));
        starsBg += float3(1.0, 0.85, 0.70) * 0.035 * (exp(-rg * rg * 1.5) + 0.35 * exp(-rg * 1.4));
    }
    starsBg *= exp(-tauL * 1.0) * (0.55 + 0.45 * calm);

    // ================================================ volumetric dust (raymarch)
    float3 ro = float3(0.0);
    float3 rd = normalize(float3(p * SN_K, 1.0));
    float3 T = float3(1.0);
    float3 acc = float3(0.0);
    float depthSum = 0.0, depthW = 0.0;
    {
        float t0 = 2.75 / rd.z;
        float t1 = 13.9 / rd.z;
        if (rd.y > 0.0) t1 = min(t1, 1.9 / rd.y);            // nothing above y = 1.9
        float t = t0 + rnd * 0.08;
        float dtp = 0.02;
        for (int i = 0; i < 152; i++) {
            if (t > t1) break;
            // stratified jitter of the SAMPLE point inside the segment: a fixed
            // per-ray offset (what this had) leaves a static dither pattern and
            // stair-step contours in the deep shadow; decorrelating per step
            // turns both into smooth gradient.
            float jit = fract(rnd + float(i) * 0.61803399) - 0.5;
            float3 P = ro + rd * (t + dtp * jit * 0.9);
            float mlow;
            float m = sn_field(P, 7, mlow);
            float dens = sn_densOf(m);
            float cl0 = 1.0;
            if (dens > 0.0035) { cl0 = sn_clump(P); dens *= cl0; }
            float dt;
            float Tm = max(T.x, max(T.y, T.z));
            if (dens > 0.0035 && Tm < 0.58) {
                // already optically deep: absorb only, skip the expensive shading
                dt = 0.062 * (t / 8.0) * (1.0 + 1.0 * smoothstep(7.4, 3.2, t));
                T *= exp(-dens * dt * float3(12.6, 15.6, 19.6));
                depthSum += t * dens * dt; depthW += dens * dt;
                if (Tm < 0.012) break;
                t += dt;
                continue;
            }
            if (dens > 0.0035) {
                // --- light from the cluster
                float3 Lv = SN_CL - P;
                float dl2 = dot(Lv, Lv);
                float3 ld = Lv * rsqrt(dl2);
                float flux = 26.0 / (pow(dl2, 1.35) + 2.0);
                flux *= 0.09 + 0.91 * smoothstep(-5.8, -0.8, P.y);
                float tau = 0.0;
                {
                    float s = 0.030, ds = 0.052;
                    for (int k = 0; k < 4; k++) {
                        float ml2;
                        float mk = sn_field(P + ld * s, k < 1 ? 4 : 2, ml2);
                        tau += sn_densOf(mk) * ds;
                        s *= 4.10; ds *= 3.95;
                    }
                }
                // The ionisation skin is not a shell of constant thickness. Its
                // optical depth swings by an order of magnitude along the
                // surface, so the lit edge is patchy incidental fluorescence,
                // not an outline of constant width and hue.
                float na = sn_n3(P * 1.85 + 61.0);
                float nb = sn_n3(P * 5.90 + 13.0);
                float nc = sn_n3(P * 0.62 + 19.0);
                float nd = sn_n3(P * 17.5 + 3.0);
                // skin optical depth swings over ~2 decades along the surface
                float skin = exp(1.55 * na + 0.95 * nb + 0.52 * nd);
                float uv = exp(-tau * (128.0 * skin));               // ionising light: very thin skin
                float sc = exp(-tau * 14.0);                        // scattered light: deeper
                float3 lightCol = exp(-tau * float3(0.25, 0.75, 1.40));  // reddened by dust
                float cosT = dot(-ld, rd);
                float g = 0.45;
                float hg = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cosT, 1.5);
                float phase = 0.30 + 0.70 * min(hg, 3.2) * 0.33;
                // ionisation front: bright gold-white where fully lit, orange-red deeper
                // surface normal from the field gradient -> real modelling on the fronts
                float ml3;
                const float2 kk = float2(1.0, -1.0);
                const float he = 0.040;
                float3 gn = kk.xyy * sn_field(P + kk.xyy * he, 2, ml3)
                          + kk.yyx * sn_field(P + kk.yyx * he, 2, ml3)
                          + kk.yxy * sn_field(P + kk.yxy * he, 2, ml3)
                          + kk.xxx * sn_field(P + kk.xxx * he, 2, ml3);
                float gl = length(gn);
                float3 nrm = gl > 1e-5 ? -gn / gl : -ld;
                float ndl = max(dot(nrm, ld), 0.0);
                // roughen the terminator too, so the band edge is ragged
                float shape = 0.07 + 0.93 * clamp(ndl * (0.52 + 0.80 * (0.5 + 0.5 * nb)), 0.0, 1.0);
                float uvc = pow(uv, 0.62);
                float3 skinC = mix(float3(0.95, 0.13, 0.07),
                                   mix(float3(1.00, 0.42, 0.11), float3(1.00, 0.84, 0.52), uvc * uvc),
                                   uvc);
                float hv = clamp(0.5 + 0.30 * nc + 0.34 * nb + 0.20 * nd, 0.0, 1.0);
                skinC *= mix(float3(1.16, 0.70, 0.46), float3(0.84, 1.14, 1.36), hv);
                // brightness is patchy at yet another scale, and sometimes the
                // front is simply not lit: real fluorescence is not a band
                float pb = 0.12 + 1.75 * pow(clamp(0.5 + 0.42 * na + 0.30 * nb, 0.0, 1.0), 2.1);
                float3 e = skinC * (pow(dens, 1.42) * uv * flux * 142.0 * shape * pb);
                // scattered starlight on lit faces (warm brown dust)
                e += float3(0.70, 0.24, 0.095) * lightCol * (pow(dens, 1.42) * sc * flux * 0.40 * phase * (0.14 + 0.86 * ndl));
                // ambient nebular light on the outer skin, none deep inside
                // reflection nebula: unreddened blue-white starlight scattered off the skin
                // blue reflection skin, patchy on its OWN noise: where it wins,
                // the rim goes cool blue-white instead of tan
                float rp = 0.35 + 1.55 * pow(clamp(0.5 - 0.45 * na + 0.40 * nd, 0.0, 1.0), 1.8);
                float refl = exp(-tau * (68.0 * skin)) * pow(dens, 1.8);
                e += cRefl * (refl * flux * 1.35 * (0.06 + 0.94 * ndl) * phase * rp);
                // ambient falls off far faster with depth, and is modulated by
                // the local clumping: the body is black WITH STRUCTURE, not a
                // smooth brown gradient with nothing in it
                float amb = exp(-max(mlow, 0.0) * 3.1) * (0.35 + 0.80 * cl0);
                e += float3(0.34, 0.10, 0.05) * (dens * amb * 0.019);
                e += float3(0.050, 0.130, 0.170) * (dens * amb * 0.048);   // cool fill from the H II cavity
                // step ~ t keeps the step constant in SCREEN space; the old
                // 3.4x near-field stretch is exactly what blurred the near bank
                dt = 0.040 * (t / 8.0) * (1.0 + 0.50 * smoothstep(7.4, 3.2, t)) * (0.70 + 0.30 * (1.0 - Tm));
                acc += T * e * dt;
                T *= exp(-dens * dt * float3(12.6, 15.6, 19.6));
                depthSum += t * dens * dt; depthW += dens * dt;
                if (max(T.x, max(T.y, T.z)) < 0.015) break;
            } else {
                // ionised gas evaporating off the lit surfaces (just outside the dust)
                float shellW = smoothstep(-0.34, -0.06, mlow) * (1.0 - smoothstep(-0.06, 0.16, mlow));
                if (shellW > 0.01) {
                    float3 Lv = SN_CL - P;
                    float dl2 = dot(Lv, Lv);
                    float flux = 14.0 / (pow(dl2, 1.15) + 2.0);
                    float3 dir = -Lv * rsqrt(dl2);
                    float r = sqrt(dl2);
                    float a1 = atan2(dir.y, dir.x), a2 = acos(clamp(dir.z, -1.0, 1.0));
                    float streak = exp(1.0 * sn_fbm3(float3(a1 * r * 7.0, a2 * r * 7.0, r * 1.1), 3, 0.55)) * 0.6;
                    float3 ev = mix(float3(1.0, 0.12, 0.20), float3(1.0, 0.45, 0.25), shellW) * (shellW * flux * streak * 0.085);
                    float dtE = clamp(-m * 0.30, 0.05, 0.30) * (t / 8.0);
                    acc += T * ev * dtE;
                    dt = dtE;
                } else {
                    dt = clamp(-m * 0.30, 0.05, 0.55) * (t / 8.0);
                }
            }
            dtp = dt;
            t += dt;
        }
    }
    float alpha = 1.0 - ws_luma(T);

    // ================================================ cluster & bright foreground stars
    float2 clPx = (SN_S * 2400.0 + float2(3840.0, 2400.0)) * 0.5;
    float3 cl = float3(0.0);
    float2 rvC = (SN_S) * float2(1.0, 1.0);
    for (int i = 0; i < 16; i++) {
        float4 hh = hash24(float2(float(i) * 3.1, 9.7));
        float a = hh.x * TAU, rr = pow(hh.y, 1.25) * 355.0;
        if (i == 0) rr = 0.0;
        float2 d = qpx - (clPx + float2(cos(a), sin(a)) * rr);
        // one dominant hero with clearly subordinate companions, so the spikes
        // do not cross into a glare tangle that competes with itself
        float mg = (i == 0) ? -1.35 : (i < 4 ? 1.15 + 1.5 * hh.z : 2.8 + 4.0 * hh.z);
        float fl = sn_flux(mg);
        float3 sc = mix(float3(0.62, 0.74, 1.0), float3(0.86, 0.90, 1.0), hh.w);
        float spkW = (i == 0) ? 0.00058 : (i < 4 ? 0.00015 : 0.0);
        float spkL = (i == 0) ? 1.0 : 0.42;
        float3 e = sn_psfC(d, sig, rvC);
        if (spkW > 0.0) e += spkW * sn_spikes(d, sig, float(i) * 11.3 + 2.0, spkL);
        cl += sc * fl * e;
    }
    float3 starsFg = sn_starLayer(qpx, 300.0, 0.30, 4.5, 9.0, sig, 4.0, true);
    {
        const float2 fp[3] = { float2(-1.30, -0.04), float2(1.10, -0.40), float2(0.64, 0.50) };
        const float  fm[3] = { 2.6, 3.0, 3.4 };
        const float  ft[3] = { 0.92, 0.18, 0.62 };
        for (int i = 0; i < 3; i++) {
            float2 d = qpx - (fp[i] * 1200.0 + float2(1920.0, 1200.0));
            starsFg += sn_starColor(ft[i]) * sn_flux(fm[i])
                     * (sn_psfC(d, sig, fp[i]) + 0.00034 * sn_spikes(d, sig, float(i) * 6.7 + 31.0, 0.65));
        }
    }

    // ================================================ composite
    float3 col = (back + starsBg) * T + acc + cl;
    // thin foreground emission veil in front of the dust
    col += haCol * (halo * 0.5 + shell * 0.25) * (0.5 + 0.5 * mott) * calm * 0.03 * alpha;
    // embedded young stars glowing inside the cloud (reddened)
    for (int i = 0; i < 9; i++) {
        float4 hh = hash24(float2(float(i) * 5.7, 1.3));
        float2 sp = float2(mix(-1.3, 1.5, hh.x), mix(-0.95, -0.15, hh.y));
        float2 d = qpx - (sp * 1200.0 + float2(1920.0, 1200.0));
        float fl = sn_flux(3.8 + 3.0 * hh.z) * smoothstep(0.35, 0.9, alpha);
        float r2 = dot(d, d);
        col += float3(1.0, 0.42, 0.20) * fl * (sn_psf(r2, sig) + 0.00028 * sn_spikes(d, sig, float(i) * 4.3 + 77.0, 0.5))
             + float3(0.9, 0.35, 0.25) * fl * 0.00018 * exp(-sqrt(r2) / (14.0 + 30.0 * hh.w));
    }
    col += starsFg;

    // a real optical system: gentle falloff to the corners
    col *= mix(1.0, ws_vignette(fragCoord / ctx.res, 0.34), 0.9);
    // dust motes on the front element, far out of focus: barely-there discs
    for (int i = 0; i < 3; i++) {
        float4 hh = hash24(float2(float(i) * 9.13 + 4.0, 21.7));
        float2 mp = float2(mix(-1.50, 1.50, hh.x), mix(-0.95, -0.35, hh.y));
        float r = length(p - mp) * (1.0 / (0.075 + 0.055 * hh.z));
        float disc = smoothstep(1.0, 0.80, r) * (0.45 + 0.55 * smoothstep(0.45, 0.96, r));
        col += float3(0.60, 0.56, 0.52) * disc * (0.0016 + 0.0018 * hh.w);
    }
    col = ws_acesFitted(col * 1.65);
    return max(col, 0.0);
}
