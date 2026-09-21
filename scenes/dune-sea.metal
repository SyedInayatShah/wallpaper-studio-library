// Dune Sea — golden hour over a Namib-style sand sea.
//
// Raymarched heightfield: a train of sinuous linear dunes (gentle convex
// windward flanks, razor brinks, planar 33-degree slip faces with concave
// aprons, peaks and saddles along the crests) with superimposed secondary
// dunes on the flanks, meso undulation, wind ripples (band-limited normal
// map), physically based sky (Rayleigh + Mie + ozone), cast shadows with a
// sun-disk penumbra, sky + sand-bounce light, curvature AO, aerial haze.

// 0 = final render, 1 = top-down map, 2 = sun only, 3 = sky only, 4 = bounce only
constant int DS_MODE = 0;

// ------------------------------------------------------------ constants
constant float DS_SUN_EL  = 10.0;      // degrees above the horizon
constant float DS_SUN_AZ  = 78.0;     // degrees from camera forward (+z) toward +x (screen LEFT)
constant float DS_WIND_AZ = 186.0;    // downwind direction, deg in xz (x = cos, z = sin)
constant float DS_MAXH    = 380.0;    // conservative max terrain height (m)
constant float DS_EARTH_R = 6371e3;

constant float DS_L1 = 980.0;         // primary crest spacing (m)
constant float DS_A1 = 120.0;         // primary dune amplitude (m)
constant float DS_L2 = 250.0;         // secondary (superimposed) spacing
constant float DS_A2 = 13.0;
constant float2 DS_HERO = float2(0.0, 900.0);   // hero amplitude envelope centre

// camera
constant float2 DS_CAM_SEED  = float2(-67.0, 0.0);  // snapped downwind to the next brink
constant float  DS_CAM_BACK  = 20.0;   // metres windward of that brink
constant float  DS_CAM_SIDE  = 0.0;    // metres along the crest (+V)
constant float  DS_CAM_UP    = 95.0;   // height above the terrain (m)
constant float  DS_CAM_YAW   = -38.0;  // deg toward +x (screen left)
constant float  DS_CAM_PITCH = -9.0;   // deg
constant float  DS_FOV       = 30.0;   // vertical fov (deg)

inline float3 ds_sunDir() {
    float el = DS_SUN_EL * PI / 180.0, az = DS_SUN_AZ * PI / 180.0;
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ------------------------------------------------------------ dune profiles
inline float ds_windP(float x) {                 // concave toe, straight flank, convex shoulder
    x = clamp(x, 0.0, 1.0);
    return mix(x * x * (2.0 - x), pow(x, 1.55), 0.6);
}
inline float ds_leeP(float s) {                  // s: 1 at brink -> 0 at base; planar face + apron
    const float a = 0.26;
    s = clamp(s, 0.0, 1.0);
    float h = s > a ? (s - 0.5 * a) : (s * s / (2.0 * a));
    return h / (1.0 - 0.5 * a);
}

struct DsT { float h; float lee; float brink; float A; float f; float s; };

// Sawtooth dune train along u (downwind). Slip face at ~33 deg regardless of A.
inline DsT ds_train(float u, float L, float A) {
    float ph = u / L;
    float f = ph - floor(ph);
    float slipW = A / (0.58 * L);
    float c = clamp(1.0 - slipW, 0.5, 0.97);
    DsT r;
    if (f < c) { r.h = A * ds_windP(f / c); r.lee = 0.0; r.brink = (c - f) * L; r.s = 0.0; }
    else       { float s = 1.0 - (f - c) / (1.0 - c);
                 r.h = A * ds_leeP(s); r.lee = 1.0; r.brink = 0.0; r.s = s; }
    r.A = A; r.f = f;
    return r;
}

// Smooth asymmetric ridge train (superimposed dunes, no sharp brink)
inline float ds_soft(float u, float L, float A) {
    float f = u / L; f -= floor(f);
    const float c = 0.68;
    float x = f < c ? f / c : 1.0 - (f - c) / (1.0 - c);
    return A * x * x * (3.0 - 2.0 * x);
}

// ------------------------------------------------------------ terrain
struct DsS {
    float h;        // height
    float lee;      // 1 on a slip face (primary or secondary)
    float brink;    // distance (m) to the nearest brink on the windward side
    float2 W;       // local downwind direction
    float A;        // primary amplitude here
    float low;      // 1 in the interdune corridor
    float fl;       // smooth weight for avalanche fluting on the slip face
};

inline DsS ds_field(float2 p, int lod) {
    // slow bending of the whole field so crests are not parallel forever
    float2 q = p * (1.0 / 5200.0);
    float2 pw = p + 620.0 * float2(gnoise(q + 1.3), gnoise(q + 7.9));
    float a = DS_WIND_AZ * PI / 180.0;
    float2 W = float2(cos(a), sin(a)), V = float2(-W.y, W.x);
    float u = dot(pw, W), v = dot(pw, V);

    // ---- primary linear dunes: sinuous crests, peaks and saddles
    float2 s1 = float2(u * 0.35, v);
    float warp = 520.0 * fbm(s1 * (1.0 / 2300.0) + 3.1, 3)
               + 200.0 * gnoise(s1 * (1.0 / 700.0) + 11.0)
               + 50.0 * gnoise(s1 * (1.0 / 220.0) + 5.0)
               + 30.0 * gnoise(float2(u * 0.4, v) * (1.0 / 115.0) + 19.0);  // scalloped brink
    float2 s2 = float2(u * 0.5, v);
    float amp = 0.72 + 0.6 * fbm(s2 * (1.0 / 1400.0) + 5.7, 2)
              + 0.4 * gnoise(s2 * (1.0 / 600.0) + 2.2) + 0.15 * gnoise(s2 * (1.0 / 280.0) + 7.7);
    // hero envelope: elongated ALONG the crest and noise-warped, otherwise the
    // circular gaussian prints a perfectly round arc into the dune silhouette
    float2 hq = p - DS_HERO;
    hq += 430.0 * float2(gnoise(hq * (1.0 / 1900.0) + 2.7), gnoise(hq * (1.0 / 1900.0) + 8.3));
    float2 dh = float2(dot(hq, W) * (1.0 / 780.0), dot(hq, V) * (1.0 / 1650.0));
    float hero = 1.0 + 0.55 * exp(-dot(dh, dh));
    float A1 = DS_A1 * clamp(amp, 0.25, 1.8) * hero;
    DsT d1 = ds_train(u + warp, DS_L1, A1);

    DsS r;
    r.h = d1.h;
    r.lee = d1.lee;
    r.brink = d1.brink;
    r.W = W;
    r.A = A1;
    r.low = 1.0 - smoothstep(0.03, 0.2, d1.h / max(A1, 1.0));
    r.fl = d1.lee * smoothstep(0.0, 0.16, d1.s) * smoothstep(0.02, 0.22, 1.0 - d1.s);

    // ---- broad corrugation of the flanks. This lives OUTSIDE the lod gate so
    // the shadow march sees it too: at a 7-degree sun a 1 m height error walks
    // the terminator 8 m, and it is this relief that stops lit/shadow edges
    // from running dead straight across near-horizontal sand.
    {
        float um = dot(p, W), vm = dot(p, V);
        float w5 = 90.0 * gnoise(float2(um * 0.30, vm) * (1.0 / 780.0) + 12.3);
        r.h += 1.5 * ds_soft(um + w5, 430.0, 1.0);
        float w4 = 46.0 * gnoise(float2(um * 0.32, vm) * (1.0 / 420.0) + 2.9);
        r.h += 2.6 * ds_soft(um + w4, 205.0, 1.0);
        r.h += 2.3 * fbm(float2(um * 0.55, vm) * (1.0 / 150.0) + 6.2, 3);
    }

    // ---- interdune floor undulation + broad "belly" undulation of the flanks
    r.h += 22.0 * gnoise(p * (1.0 / 3900.0) + 5.3) + 5.0 * gnoise(p * (1.0 / 900.0) + 2.0);
    r.h += 5.0 * fbm(p * (1.0 / 420.0) + 8.4, 2) * (1.0 - d1.lee) * smoothstep(0.0, 40.0, d1.brink);

    // ---- secondary dunes: lower flanks and corridors only (never on a slip face)
    float rel = d1.h / max(A1, 1.0);
    float w2 = (1.0 - d1.lee) * smoothstep(0.0, 70.0, d1.brink) * (1.0 - smoothstep(0.55, 0.9, rel));
    w2 *= 0.45 + 0.55 * smoothstep(-0.35, 0.35, gnoise(p * (1.0 / 1100.0) + 3.9));
    if (w2 > 0.001) {
        float a2 = (DS_WIND_AZ + 14.0) * PI / 180.0;
        float2 W2 = float2(cos(a2), sin(a2)), V2 = float2(-W2.y, W2.x);
        float u2 = dot(pw, W2), v2 = dot(pw, V2);
        float warp2 = 45.0 * gnoise(float2(u2 * 0.35, v2) * (1.0 / 260.0) + 8.8)
                    + 14.0 * gnoise(float2(u2 * 0.5, v2) * (1.0 / 90.0) + 1.1);
        float amp2 = 0.55 + 0.5 * gnoise(float2(u2 * 0.5, v2) * (1.0 / 420.0) + 3.3);
        float A2 = DS_A2 * clamp(amp2, 0.15, 1.2) * w2;
        r.h += ds_soft(u2 + warp2, DS_L2, A2);
    }

    // ---- meso relief (shading scale): small bedforms and soft undulation
    if (lod > 0) {
        float wm = 1.0 - r.lee;
        float um = dot(p, r.W), vm = dot(p, float2(-r.W.y, r.W.x));
        // decametre bedforms. Under a 10-degree sun a 2% slope swings the
        // lambert term by ~20%, so these are what give kilometre-distant sand
        // its mottle once the ripples have been band-limited away.
        float w3 = 9.0 * gnoise(float2(um * 0.4, vm) * (1.0 / 70.0) + 4.4);
        float A3 = 0.38 * smoothstep(-0.2, 0.5, gnoise(float2(um * 0.5, vm) * (1.0 / 140.0) + 6.6)) * wm * smoothstep(0.0, 25.0, r.brink);
        r.h += ds_soft(um + w3, 34.0, A3);
        float w6 = 30.0 * gnoise(float2(um * 0.35, vm) * (1.0 / 240.0) + 15.2);
        float A6 = 0.45 * (0.45 + 0.55 * smoothstep(-0.4, 0.4, gnoise(float2(um * 0.45, vm) * (1.0 / 430.0) + 3.8))) * wm * smoothstep(0.0, 30.0, r.brink);
        r.h += ds_soft(um + w6, 95.0, A6);
        r.h += 0.13 * fbm(float2(um * 0.5, vm) * (1.0 / 28.0) + 9.1, 3) * wm;
        r.h += 0.55 * fbm(float2(um * 0.55, vm) * (1.0 / 66.0) + 3.4, 3) * wm;
        // avalanche fluting: on a slip face the flow lines run down the fall
        // line, so the bedforms are ridges along V, not along the wind
        if (r.fl > 0.002) {
            float wf = 26.0 * gnoise(float2(vm * 0.5, um) * (1.0 / 165.0) + 5.5);
            r.h += 2.30 * ds_soft(vm + wf, 68.0, 1.0) * r.fl;
            r.h += 0.85 * ds_soft(vm + 0.45 * wf, 23.0, 1.0) * r.fl;
            r.h += 0.45 * fbm(float2(vm * 0.55, um) * (1.0 / 40.0) + 2.2, 3) * r.fl;
        }
    }
    return r;
}

inline float ds_height(float2 p, int lod) { return ds_field(p, lod).h; }

// terrain with Earth curvature relative to the camera
inline float ds_terrain(float2 xz, float2 camXZ, int lod) {
    float2 d = xz - camXZ;
    return ds_height(xz, lod) - dot(d, d) / (2.0 * DS_EARTH_R);
}

// Snap the camera onto the nearest brink downwind of the seed (all inputs are
// compile-time constants, so this folds away).
inline float2 ds_camXZ() {
    float a = DS_WIND_AZ * PI / 180.0;
    float2 W = float2(cos(a), sin(a)), V = float2(-W.y, W.x);
    float2 p = DS_CAM_SEED;
    for (int i = 0; i < 40; i++) { if (ds_field(p, 0).lee < 0.5) break; p -= W * 9.0; }
    float2 lo = p, hi = p + W * 1400.0;
    for (int i = 0; i < 40; i++) {
        float2 q = p + W * (float(i + 1) * 35.0);
        if (ds_field(q, 0).lee > 0.5) { hi = q; break; }
        lo = q;
    }
    for (int i = 0; i < 22; i++) {
        float2 m = 0.5 * (lo + hi);
        if (ds_field(m, 0).lee > 0.5) hi = m; else lo = m;
    }
    return lo - W * DS_CAM_BACK + V * DS_CAM_SIDE;
}

// ------------------------------------------------------------ atmosphere
// Rayleigh + Mie single scattering with the Earth's shadow, plus ozone
// absorption (keeps the low-sun sky blue instead of olive). Steps are packed
// near the observer so the dense low haze at the horizon is resolved.
constant float DS_RP = 6371e3;
constant float DS_RA = 6471e3;
constant float3 DS_KR = float3(5.8e-6, 13.5e-6, 33.1e-6);
constant float3 DS_KO = float3(0.650e-6, 1.881e-6, 0.085e-6);
constant float DS_KM0 = 27e-6;
constant float DS_MIE = 0.75;
constant float DS_ALT = 140.0;
constant float DS_SUNI = 22.0;

inline float ds_ozone(float h) { return max(0.0, 1.0 - abs(h - 25e3) / 15e3); }

inline float3 ds_opticalDepth(float3 pp, float3 dir, int N) {
    float len = ws_raySphere(pp, dir, DS_RA).y;
    float3 od = float3(0.0);
    float prev = 0.0;
    for (int i = 0; i < N; i++) {
        float s1 = float(i + 1) / float(N);
        float tt = len * s1 * s1;
        float dt = tt - prev;
        float3 q = pp + dir * (prev + 0.5 * dt);
        float hh = length(q) - DS_RP;
        od += float3(exp(-hh / 8e3), DS_MIE * exp(-hh / 1.2e3), ds_ozone(hh)) * dt;
        prev = tt;
    }
    return od;
}
inline float3 ds_extinct(float3 od) {
    return exp(-(DS_KR * od.x + DS_KM0 * 1.1 * od.y + DS_KO * od.z));
}
inline float3 ds_sunTransmittance(float3 sun) {
    return ds_extinct(ds_opticalDepth(float3(0.0, DS_RP + DS_ALT, 0.0), sun, 8));
}

inline float3 ds_skyN(float3 rd, float3 sun, int N, int NJ) {
    float3 r0 = float3(0.0, DS_RP + DS_ALT, 0.0);
    float2 pa = ws_raySphere(r0, rd, DS_RA);
    float tEnd = pa.y;
    float2 pg = ws_raySphere(r0, rd, DS_RP);
    if (pg.x <= pg.y && pg.x > 0.0) tEnd = min(tEnd, pg.x);
    float3 od = float3(0.0);
    float prev = 0.0;
    float3 sR = float3(0.0), sM = float3(0.0);
    for (int i = 0; i < N; i++) {
        float s1 = float(i + 1) / float(N);
        float tt = tEnd * s1 * s1 * s1;
        float dt = tt - prev;
        float3 pp = r0 + rd * (prev + 0.5 * dt);
        float hh = length(pp) - DS_RP;
        float3 dd = float3(exp(-hh / 8e3), DS_MIE * exp(-hh / 1.2e3), ds_ozone(hh)) * dt;
        float3 oMid = od + 0.5 * dd;
        od += dd;
        prev = tt;
        float2 sg = ws_raySphere(pp, sun, DS_RP);
        if (sg.x <= sg.y && sg.x > 0.0) continue;
        float3 attn = ds_extinct(oMid + ds_opticalDepth(pp, sun, NJ));
        sR += dd.x * attn; sM += dd.y * attn;
    }
    float mu = dot(rd, sun), g = 0.76, gg = g * g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mu * mu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));
    return DS_SUNI * (pR * DS_KR * sR + pM * DS_KM0 * sM) * float3(1.0, 0.92, 1.0);
}
inline float3 ds_sky(float3 rd, float3 sun) { return ds_skyN(rd, sun, 20, 8); }

// Suspended dust: a warm, noisy, horizon-hugging layer. It gives the sky
// texture and golden-hour warmth, and — applied to the aerial-perspective
// colour as well — stops the distant ranges reading as flat grey cut-outs.
inline float3 ds_dust(float3 rd, float3 sun, float3 c) {
    float h = max(rd.y, 0.0);
    float ang = atan2(rd.x, rd.z);
    float band = exp(-h * (1.0 / 0.085)) * 0.82 + exp(-h * (1.0 / 0.020)) * 0.35;
    float tex = 0.50 + 0.72 * fbm(float2(ang * 3.1, h * 19.0) + 4.7, 4)
                     + 0.13 * gnoise(float2(ang * 9.5, h * 46.0) + 1.9);
    float2 s2 = normalize(sun.xz);
    float2 r2 = normalize(float2(rd.x, rd.z) + 1e-5);
    float sunw = pow(clamp(0.5 + 0.5 * dot(s2, r2), 0.0, 1.0), 1.3);
    // the dust layer is lit by the low sun from the side: it stays warm even
    // looking away from it, which is what makes a desert horizon glow
    float a = clamp(band * tex * (0.72 + 0.28 * sunw), 0.0, 1.0);
    float L = ws_luma(c);
    float3 warm = float3(1.52, 0.88, 0.40) * L * (1.06 + 0.45 * sunw);
    c = mix(c, warm, clamp(a * 1.35, 0.0, 0.92));
    // high, thin haze striations well above the horizon: keeps the upper sky
    // from being a perfectly clean two-stop ramp
    float hi = smoothstep(0.025, 0.26, h) * smoothstep(0.80, 0.22, h);
    float ht = fbm(float2(ang * 1.35, h * 7.5) + 8.2, 4) - 0.5;
    c *= 1.0 + 0.075 * hi * ht;
    c = mix(c, c * float3(1.10, 1.01, 0.88), 0.30 * hi * smoothstep(0.0, 1.0, sunw));
    return c;
}

inline float3 ds_moonDir() {
    float el = 3.3 * PI / 180.0, az = -27.0 * PI / 180.0;
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ------------------------------------------------------------ ripples
// Aeolian ripple field, shading only: returns the gradient of ripple height.
// Asymmetric profile (gentle stoss, steep lee). Band-limited by the pixel
// footprint so it never aliases or turns into moire.
//
// The crest field is a VECTOR domain warp of world space, p -> p + D(p), with
// |dD/dp| held well below 1 so the map never folds. Phase is then a plain
// plane wave in the warped domain, which guarantees the crest contours can
// never close into rings. (Rotating the wave vector per point instead —
// dot(p, W(p)) — is what produced the concentric "fingerprint" whorls: the
// p . dW/dp term scales with |p| and swamps the real wave vector.)
inline float2 ds_rippleWarp(float2 p) {
    float2 d = 16.0 * float2(gnoise(p * (1.0 / 270.0) + 3.7),
                             gnoise(p * (1.0 / 270.0) + 9.1));
    d += 5.6 * float2(gnoise(p * (1.0 / 82.0) + 1.3),
                      gnoise(p * (1.0 / 82.0) + 5.9));
    d += 1.55 * float2(gnoise(p * (1.0 / 23.0) + 7.1),
                       gnoise(p * (1.0 / 23.0) + 2.5));
    return d;
}
inline float ds_ripplePhase(float2 p, float2 W, float lam, float seed) {
    // slow along-train phase drift: crests merge and terminate instead of
    // running forever in lockstep (still |grad| << 1/lam, so no whorls)
    float w = 0.42 * gnoise(p * (1.0 / (26.0 * lam)) + seed)
            + 0.13 * gnoise(p * (1.0 / (9.0 * lam)) + seed * 2.3);
    return dot(p, W) / lam + w;
}
// first-order crest normal of the warped field: W + J^T W
inline float2 ds_rippleDir(float2 p, float2 D0, float2 W) {
    const float eh = 1.5;
    float2 Dx = ds_rippleWarp(p + float2(eh, 0.0));
    float2 Dz = ds_rippleWarp(p + float2(0.0, eh));
    float2 Jw = float2(dot(Dx - D0, W), dot(Dz - D0, W)) * (1.0 / eh);
    return normalize(W + Jw);
}
inline float ds_rippleGrad(float2 p, float2 W, float fp, float lam) {
    float ph1 = ds_ripplePhase(p, W, lam, 0.0);
    const float s = 0.72;
    float f1 = fract(ph1);
    float d1 = (f1 < s) ? 1.0 / s : -1.0 / (1.0 - s);
    d1 *= smoothstep(0.0, 0.06, f1) * smoothstep(0.0, 0.06, abs(f1 - s)) * 0.6 + 0.4;
    // replace the harmonic-rich sawtooth by its fundamental, then fade out
    float q = smoothstep(0.035 * lam, 0.11 * lam, fp);
    d1 = mix(d1, 2.4 * sin(TAU * (f1 - 0.1)), q);
    float amp = 1.0 / 12.5;                        // height / wavelength
    float dd = d1 * amp;
    dd *= 0.55 + 0.45 * gnoise(p * (1.0 / (85.0 * lam)) + 3.3);
    dd *= 0.78 + 0.34 * gnoise(p * (1.0 / (13.0 * lam)) + 8.7);
    dd *= 1.0 - smoothstep(0.10 * lam, 0.26 * lam, fp);
    return dd;
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float3 sun = ds_sunDir();
    if (DS_MODE == 1) {
        float2 uv = (fragCoord - 0.5 * ctx.res) / ctx.res.y * 4000.0;
        float2 pm = float2(-uv.x, uv.y) + ds_camXZ() + float2(0.0, 1000.0);
        float e = 3.0;
        DsS fc = ds_field(pm, 0);
        float hc = fc.h;
        float hx = ds_height(pm + float2(e, 0), 0), hz = ds_height(pm + float2(0, e), 0);
        float3 nn = normalize(float3(-(hx - hc) / e, 1.0, -(hz - hc) / e));
        float dif = max(dot(nn, normalize(float3(sun.x, 0.35, sun.z))), 0.0);
        float3 mc = float3(0.8, 0.55, 0.35) * (0.08 + 1.2 * dif) + float3(0.0, 0.0, hc / 600.0);
        if (fc.lee > 0.5) mc *= float3(0.6, 0.6, 1.0);
        float2 dc = pm - ds_camXZ();
        if (length(dc) < 20.0) mc = float3(0, 1, 0);
        float hf = atan(tan(DS_FOV * 0.5 * PI / 180.0) * ctx.aspect);
        float an = atan2(dc.x, dc.y);
        if (dc.y > 0.0 && abs(abs(an) - hf) < 0.004) mc = float3(0, 1, 0);
        if (fract(pm.x / 500.0) < 0.004 || fract(pm.y / 500.0) < 0.004) mc = mix(mc, float3(1, 1, 1), 0.5);
        if (abs(pm.x) < 4.0 || abs(pm.y) < 4.0) mc = float3(1, 1, 0);
        return ws_acesFitted(mc);
    }

    // ---- camera
    float2 camXZ = ds_camXZ();
    float camY = ds_height(camXZ, 0) + DS_CAM_UP;
    float yaw = DS_CAM_YAW * PI / 180.0, pit = DS_CAM_PITCH * PI / 180.0;
    float3 ro = float3(camXZ.x, camY, camXZ.y);
    float3 fwd = float3(sin(yaw) * cos(pit), sin(pit), cos(yaw) * cos(pit));
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ro + fwd, DS_FOV);
    float pixAng = (DS_FOV * PI / 180.0) / ctx.res.y;

    float3 Esun = DS_SUNI * ds_sunTransmittance(sun);

    // ---- raymarch the heightfield
    const float TMAX = 30000.0;
    float tmax = TMAX;
    if (rd.y > 0.0) tmax = min(tmax, (DS_MAXH - ro.y) / rd.y);
    float t = 1.0, tprev = 1.0;
    bool hit = false;
    float dlast = 1e9;
    for (int i = 0; i < 1100 && t < tmax; i++) {
        float3 p = ro + rd * t;
        float d = p.y - ds_terrain(p.xz, camXZ, 0);
        if (d < 0.0) { hit = true; break; }
        dlast = d;
        tprev = t;
        t += max(d * 0.45, 0.00025 * t + 0.02);
    }
    if (!hit && t < tmax && dlast < 0.003 * t + 0.4) { hit = true; tprev = t; }

    float3 hazeDir = normalize(float3(rd.x, max(rd.y, 0.004), rd.z));
    float3 col;
    if (hit) {
        float ta = tprev, tb = t;
        for (int j = 0; j < 16; j++) {
            float tm = 0.5 * (ta + tb);
            float3 p = ro + rd * tm;
            if (p.y - ds_terrain(p.xz, camXZ, 0) < 0.0) tb = tm; else ta = tm;
        }
        t = 0.5 * (ta + tb);
        float3 pos = ro + rd * t;
        float2 xz = pos.xz;

        DsS dn = ds_field(xz, 1);
        float fp = t * pixAng;                             // pixel footprint (m)
        float e = max(0.04, 0.6 * fp);
        float hx0 = ds_height(xz - float2(e, 0), 1), hx1 = ds_height(xz + float2(e, 0), 1);
        float hz0 = ds_height(xz - float2(0, e), 1), hz1 = ds_height(xz + float2(0, e), 1);
        float2 grad = float2(hx1 - hx0, hz1 - hz0) / (2.0 * e);
        float3 nGeo = normalize(float3(-grad.x, 1.0, -grad.y));
        float cosV = max(abs(dot(rd, nGeo)), 0.06);
        float fpS = fp / cosV;

        // --- zones
        float slope = length(grad);
        float slipZone = dn.lee;
        float windward = (1.0 - slipZone) * (1.0 - smoothstep(0.62, 0.88, slope));

        // --- wind ripples (normal perturbation)
        float2 W = dn.W;
        float2 V = float2(-W.y, W.x);
        float3 va = rd - nGeo * dot(rd, nGeo);
        va = dot(va, va) > 1e-8 ? normalize(va) : float3(1, 0, 0);
        float wa = dot(normalize(float3(W.x, dot(grad, W), W.y)), va);
        float fpW = fp * sqrt(wa * wa / (cosV * cosV) + max(1.0 - wa * wa, 0.0));
        // the near-surface wind wanders, so ripple crests sweep in long curves:
        // one shared vector warp of the ground plane, so every train at every
        // scale follows the SAME flow lines (as a real wind field does)
        float2 D0 = ds_rippleWarp(xz);
        float2 xw = xz + D0;
        float2 Wl = ds_rippleDir(xz, D0, W);
        // a faint train at a few degrees off the main one: where the two go out
        // of phase the crests fork and die, which is how real ripple fields
        // look. Too large an angle and it reads as woven cloth, so keep it small.
        const float dw = 7.0 * PI / 180.0;
        float2 W2r = float2(W.x * cos(dw) - W.y * sin(dw), W.x * sin(dw) + W.y * cos(dw));
        float rgs = 1.00 * ds_rippleGrad(xw, W, fpW, 0.80);
        rgs += 0.40 * ds_rippleGrad(xw + 31.0, W2r, fpW, 0.80);
        rgs += 0.55 * ds_rippleGrad(xw + 57.0, W, fpW, 1.75);
        rgs += 0.34 * ds_rippleGrad(xw + 113.0, W, fpW, 3.9);
        float2 rg = Wl * rgs;
        float patch = smoothstep(-0.50, 0.40, fbm(xz * (1.0 / 130.0) + 12.0, 3))
                    * (0.30 + 0.70 * smoothstep(-0.45, 0.45, gnoise(xz * (1.0 / 620.0) + 21.0)));
        float crestSmooth = smoothstep(1.0, 10.0, dn.brink);
        rg *= windward * mix(0.16, 1.22, patch) * mix(0.25, 1.0, crestSmooth);
        // grain-flow streaks down the slip face
        float streak = gnoise(float2(dot(xz, V) * (1.0 / 1.6), dot(xz, W) * (1.0 / 22.0)) + 4.1)
                     + 0.5 * gnoise(float2(dot(xz, V) * (1.0 / 0.6), dot(xz, W) * (1.0 / 9.0)) + 8.3);
        float fpV = fp * sqrt(dot(float3(V.x, 0, V.y), va) * dot(float3(V.x, 0, V.y), va) / (cosV * cosV) + 1.0);
        float streakAA = 1.0 - smoothstep(0.3, 1.2, fpV);
        float2 sg = V * (0.08 * streakAA * slipZone) * gnoise(float2(dot(xz, V) * (1.0 / 1.1), dot(xz, W) * (1.0 / 14.0)) + 1.9);
        // avalanche chutes: crests run down the fall line, so the ripple direction is V
        float fpC = fp * sqrt(dot(float3(V.x, 0, V.y), va) * dot(float3(V.x, 0, V.y), va) / (cosV * cosV) + 1.0);
        float2 sw = xz + 0.45 * D0;                        // gentler warp on the face
        float2 Vl = normalize(V + 0.45 * (ds_rippleDir(xz, D0, V) - V));
        sg += Vl * (1.30 * slipZone * ds_rippleGrad(sw + 91.0, V, fpC, 5.5));
        sg += Vl * (0.70 * slipZone * ds_rippleGrad(sw + 17.0, normalize(V + 0.10 * W), fpC, 1.7));
        sg += Vl * (0.40 * slipZone * ds_rippleGrad(sw + 41.0, V, fpC, 17.0));
        // faint apron ripples where the slip face meets the interdune floor
        rg += Wl * (0.35 * dn.low * ds_rippleGrad(xw + 63.0, W, fpW, 0.9));
        // grain-scale normal jitter (filtered)
        float gj = 1.0 - smoothstep(0.02, 0.11, fpS);
        float2 jit = gj * 0.075 * float2(gnoise(xz * 41.0 + 2.0), gnoise(xz * 41.0 + 9.0));
        jit += (1.0 - smoothstep(0.07, 0.30, fpS)) * 0.035
             * float2(gnoise(xz * 11.0 + 5.0), gnoise(xz * 11.0 + 13.0));
        float3 n = normalize(float3(-(grad.x + rg.x + sg.x + jit.x), 1.0, -(grad.y + rg.y + sg.y + jit.y)));

        // --- cast shadow toward the sun (0.53 deg disk -> crisp penumbra)
        float sh = 1.0;
        {
            float st = 0.25;
            float3 o = pos + nGeo * 0.1;
            for (int k = 0; k < 320; k++) {
                float3 qq = o + sun * st;
                if (qq.y > DS_MAXH) break;
                float dq = qq.y - ds_height(qq.xz, 0);
                sh = min(sh, 52.0 * dq / st);
                if (sh < 0.0) break;
                st += clamp(dq * 0.30, 0.12 + 0.004 * st, 7.5);
            }
            sh = clamp(sh, 0.0, 1.0);
            sh = sh * sh * (3.0 - 2.0 * sh);
        }

        // --- curvature ambient occlusion (height above the tangent plane)
        float occ = 0.0;
        {
            float h0 = dn.h;
            for (int k = 0; k < 8; k++) {
                float a = float(k) * (TAU / 8.0) + 0.4;
                float r = (k & 1) ? 60.0 : 18.0;
                float2 o = float2(cos(a), sin(a)) * r;
                float hs = ds_height(xz + o, 0);
                occ += max(hs - (h0 + dot(grad, o)), 0.0) / r;
            }
            occ = clamp(1.0 - 0.5 * occ, 0.45, 1.0);
        }

        // --- albedo: Namib iron-oxide sand
        float3 albBase = ws_hex(0xDCA067u);
        float big = fbm(xz * (1.0 / 380.0) + 2.0, 3);
        float3 alb = albBase * (1.0 + 0.10 * big + 0.06 * gnoise(xz * (1.0 / 1500.0) + 4.6));
        alb = mix(alb, alb * float3(0.93, 0.95, 1.03), 0.5 + 0.5 * gnoise(xz * (1.0 / 900.0)));
        alb *= 1.0 + slipZone * (0.04 + 0.05 * streak * streakAA);
        alb = mix(alb, alb * float3(1.02, 0.97, 0.90), 0.55 * dn.low);
        float g1 = gnoise(xz * 22.0) * (1.0 - smoothstep(0.02, 0.08, fpS));
        float g2 = gnoise(xz * 5.0 + 3.0) * (1.0 - smoothstep(0.08, 0.3, fpS));
        float g3 = gnoise(xz * 1.3 + 7.0) * (1.0 - smoothstep(0.3, 1.2, fpS));
        float g4 = fbm(xz * (1.0 / 4.5) + 7.0, 2) * (1.0 - smoothstep(1.0, 4.0, fpS));
        float g5 = fbm(xz * (1.0 / 26.0) + 13.0, 3) * (1.0 - smoothstep(6.0, 22.0, fpS));
        float g6 = fbm(xz * (1.0 / 88.0) + 21.0, 3) * (1.0 - smoothstep(24.0, 80.0, fpS));
        alb *= 1.0 + 0.07 * g1 + 0.05 * g2 + 0.04 * g3 + 0.06 * g4 + 0.075 * g5 + 0.065 * g6;
        // mineral variation: local warm/cool drift rather than one flat hue
        alb = mix(alb, alb * float3(1.05, 0.985, 0.90), 0.40 * smoothstep(-0.3, 0.4, big));
        alb = mix(alb, alb * float3(0.94, 0.97, 1.05), 0.34 * smoothstep(0.3, -0.3, g5 - 0.5 + 0.4 * big));

        // --- lighting
        float ndl = max(dot(n, sun), 0.0);
        float2 sxz = normalize(sun.xz);
        float2 pxz = float2(-sxz.y, sxz.x);
        // sky irradiance from a zenith + 4 low-sky samples, clamped-cosine weighted
        const float ce = 0.966, se = 0.259;
        float3 dS = float3(sxz.x * ce, se, sxz.y * ce), dA = float3(-sxz.x * ce, se, -sxz.y * ce);
        float3 dL = float3(pxz.x * ce, se, pxz.y * ce),  dR = float3(-pxz.x * ce, se, -pxz.y * ce);
        float3 LZ = ds_skyN(float3(0.0, 1.0, 0.0001), sun, 8, 4);
        float3 LS = ds_skyN(dS, sun, 8, 4), LA = ds_skyN(dA, sun, 8, 4);
        float3 LL = ds_skyN(dL, sun, 8, 4), LR = ds_skyN(dR, sun, 8, 4);
        // sharp, directional lobes: a golden-hour sky is far from uniform, and this
        // is what lets ripples read inside the shadow
        float wZ = max(n.y, 0.0);
        float wS = max(dot(n, dS), 0.0), wA = max(dot(n, dA), 0.0);
        float wL = max(dot(n, dL), 0.0), wR = max(dot(n, dR), 0.0);
        float3 Esky = PI * (0.25 * LZ * wZ + 0.75 * 0.5 * (LS * wS + LA * wA + LL * wL + LR * wR));
        Esky *= float3(0.40, 0.75, 2.20);                    // multiply-scattered skylight, photo-contrast
        // Oren-Nayar rough diffuse (sand, sigma ~ 0.55)
        float3 vdir = -rd;
        float ndv = max(dot(n, vdir), 0.05);
        const float sg2 = 0.55 * 0.55;
        float onA = 1.0 - 0.5 * sg2 / (sg2 + 0.33), onB = 0.45 * sg2 / (sg2 + 0.09);
        float sAng = dot(sun, vdir) - ndl * ndv;
        // guard the max(ndl,ndv) denominator: on a razor brink both terms go to
        // zero at once and the Oren-Nayar ratio blows up into white specks
        float tAng = sAng <= 0.0 ? 1.0 : max(max(ndl, ndv), 0.22);
        float brdfSun = min(onA + onB * max(sAng, 0.0) / tAng, 1.75);
        float3 direct = alb / PI * Esun * ndl * brdfSun * sh;
        float3 ambient = alb / PI * Esky * occ;
        // one-bounce from surrounding sunlit sand: slip faces look straight at the
        // lit windward flank of the next dune downwind
        float towardSun = dot(nGeo.xz, sxz);
        float3 Llit = alb / PI * (Esun * 0.085 * float3(1.10, 0.90, 0.66) + Esky * 0.40);
        float seeLit = 0.34 * max(-towardSun, 0.0) + 0.10 * (1.0 - n.y) + 0.03;
        float3 bounce = alb * Llit * seeLit * (1.7 - occ) * 0.6;
        col = direct + ambient + bounce;
        if (DS_MODE == 2) col = direct;
        if (DS_MODE == 3) col = ambient;
        if (DS_MODE == 4) col = bounce;

        // --- aerial perspective
        float3 fogCol = ds_dust(hazeDir, sun, ds_sky(hazeDir, sun));
        fogCol *= float3(1.07, 1.00, 0.88);
        float fa = ws_fogAmount(t, ro, rd, 1.0 / 8500.0, 1.0 / 800.0);
        // the haze is not uniform: patchy density dissolves the far silhouettes
        // unevenly instead of leaving hard, evenly toned vector edges
        float hang = atan2(rd.x, rd.z);
        float hv = 0.70 + 0.62 * fbm(float2(hang * 3.6, max(rd.y, 0.0) * 26.0) + 2.4, 3)
                        + 0.16 * gnoise(float2(hang * 12.0, max(rd.y, 0.0) * 64.0) + 6.1);
        fa = 1.0 - pow(max(1.0 - fa, 1e-5), max(hv, 0.15));
        col = mix(col, fogCol, clamp(fa, 0.0, 1.0));
    } else {
        float3 sd = rd.y > 0.0 ? rd : hazeDir;
        col = ds_dust(sd, sun, ds_sky(sd, sun));
        // faint crescent moon, lit by the real sun direction (phase from geometry)
        float3 md = ds_moonDir();
        float mr = 0.27 * PI / 180.0;
        float ca = dot(rd, md);
        if (ca > cos(mr * 9.0)) {
            float3 mu = normalize(cross(float3(0.0, 1.0, 0.0), md));
            float3 mv = cross(md, mu);
            float2 q = float2(dot(rd, mu), dot(rd, mv)) / mr;
            float r2 = dot(q, q);
            float rr = sqrt(r2);
            // low sun, thick horizon air: the limb is softened, with a small halo
            float edge = 1.0 - smoothstep(0.86, 1.07, rr);
            float halo = 0.055 * exp(-max(rr - 0.8, 0.0) * 1.35);
            if (edge > 0.0 || halo > 0.0008) {
                float nz = sqrt(max(1.0 - r2, 0.0));
                float3 N = normalize(q.x * mu + q.y * mv - nz * md);
                float mu0 = max(dot(N, sun), 0.0), mue = max(nz, 0.02);
                float lsm = mu0 / (mu0 + mue);
                float maria = 1.0 - 0.28 * smoothstep(0.05, 0.45, fbm(q * 2.2 + 4.0, 4)) - 0.08 * gnoise(q * 9.0 + 1.0);
                float3 Tm = ds_extinct(ds_opticalDepth(float3(0.0, DS_RP + DS_ALT, 0.0), md, 8));
                float3 Lm = 0.12 * maria * DS_SUNI * 2.0 * lsm * Tm * 1.15;
                Lm += 0.004 * maria * float3(0.6, 0.7, 1.0);
                col += Lm * edge + (0.11 * DS_SUNI * halo) * Tm * float3(1.0, 0.98, 0.95);
            }
        }
    }
    // lens veiling glare
    col += float3(0.55, 0.42, 0.30) * 0.005;
    float2 uvv = fragCoord / ctx.res;
    col *= ws_vignette(uvv, 0.27);
    // gentle cool fall-off into the icon corner (top-right)
    float trc = smoothstep(0.50, 1.0, uvv.x) * smoothstep(0.58, 1.0, uvv.y);
    col *= mix(float3(1.0), float3(0.945, 0.972, 1.045), trc);
    // deepen the very top of the sky: calmer menu-bar strip, better icon contrast
    col *= 1.0 - 0.085 * smoothstep(0.78, 1.0, uvv.y);
    // white balance + exposure
    col *= float3(0.94, 0.955, 1.10) * 1.34;
    { float Lw = ws_luma(col); col = max(mix(float3(Lw), col, 1.14), 0.0); }
    float3 oA = ws_acesFitted(col);
    float Lc = max(ws_luma(col), 1e-6);
    float3 oL = col * (ws_luma(ws_acesFitted(float3(Lc))) / Lc);
    oL /= max(1.0, max(oL.r, max(oL.g, oL.b)));
    float3 o = mix(oA, oL, 0.45);
    float lo = 1.0 - smoothstep(0.02, 0.60, ws_luma(o));
    o = mix(o, o * float3(0.845, 0.925, 1.28), lo * 0.90);
    o += (ws_grain(fragCoord, 0.37) * 0.0055) * (0.4 + 0.6 * sqrt(max(ws_luma(o), 0.0)));
    return clamp(o, 0.0, 1.0);
}
