// Dune Sea — golden hour over a Namib-style sand sea.
// Raymarched heightfield of barchanoid / transverse dunes (gentle windward
// slopes, razor brinks, 32-degree slip faces with concave aprons), wind
// ripples with micro-shadowing, grain-flow streaks on slip faces, physically
// based sky (Rayleigh + Mie single scattering), cast sun shadows with a
// sun-disk penumbra, sky + ground-bounce light, curvature AO, aerial haze.

// 0 = final render, 1 = top-down map (debug)
constant int DS_MODE = 0;

// ------------------------------------------------------------ constants
constant float DS_SUN_EL  = 5.0;     // degrees above horizon
constant float DS_SUN_AZ  = 66.0;    // degrees from camera forward (+z) toward +x (screen left)
constant float DS_WIND_AZ = 195.0;   // downwind direction, deg in xz (x = cos, z = sin)
constant float DS_MAXH    = 230.0;   // conservative max terrain height (m)
constant float DS_EARTH_R = 6371e3;

// camera
constant float2 DS_CAM_XZ   = float2(0.0, 0.0);
constant float  DS_CAM_UP   = 32.0;   // camera height above the hero crest (m)
constant float  DS_CAM_YAW  = -4.0;   // deg toward +x (screen left)
constant float  DS_CAM_PITCH = -3.2;  // deg
constant float  DS_FOV      = 25.0;   // vertical fov (deg)

inline float3 ds_sunDir() {
    float el = DS_SUN_EL * PI / 180.0, az = DS_SUN_AZ * PI / 180.0;
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ------------------------------------------------------------ cheap noise
inline float2 ds_grad(int2 c) {
    uint h = ws_pcg2(as_type<uint2>(c)).x;
    return float2(float(h & 0xffffu), float(h >> 16)) * (2.0 / 65535.0) - 1.0;
}
inline float ds_noise(float2 p) {
    float2 i = floor(p); float2 f = p - i;
    int2 c = int2(i);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(ds_grad(c), f);
    float b = dot(ds_grad(c + int2(1, 0)), f - float2(1, 0));
    float d = dot(ds_grad(c + int2(0, 1)), f - float2(0, 1));
    float e = dot(ds_grad(c + int2(1, 1)), f - float2(1, 1));
    return 1.5 * mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}
inline float ds_fbm(float2 p, int oct) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < oct; i++) {
        s += a * ds_noise(p); n += a;
        p = WS_ROT2 * p * 2.03 + float2(13.7, 5.1);
        a *= 0.5;
    }
    return s / n;
}

// ------------------------------------------------------------ dunes
// Asymmetric dune cross-section, f in [0,1) along the wind, c = brink position.
inline float ds_windProfile(float x) {                                // concave toe, straight flank, slight shoulder
    return mix(x * x * (2.0 - x), pow(max(x, 0.0), 1.55), 0.6);
}
inline float ds_leeProfile(float s) {                                 // s: 1 at brink -> 0 at base
    const float a = 0.22;                                               // concave apron fraction
    s = clamp(s, 0.0, 1.0);
    float h = s > a ? (s - 0.5 * a) : (s * s / (2.0 * a));
    return h / (1.0 - 0.5 * a);                                         // planar 32-deg face + apron
}

// h: height; lee: 1 on slip faces; brink: distance (m) to the brink on the windward side; W: wind
struct DsDune { float h; float lee; float brink; float2 W; };

inline DsDune ds_system(float2 p, float angOff, float L, float seed, float ampScale, int detail) {
    float ang = (DS_WIND_AZ + angOff) * PI / 180.0;
    float2 W = float2(cos(ang), sin(ang));
    float2 V = float2(-W.y, W.x);
    float u = dot(p, W);
    float v = dot(p, V);
    // sinuous, barchanoid crest lines: |noise| gives crescents with horns downwind
    float2 q = float2(u * 0.25, v) * (1.0 / 1700.0);
    float warp = 420.0 * ds_fbm(q + seed * float2(3.1, 7.7), 3);
    warp += 170.0 * abs(ds_noise(float2(u * 0.15, v) * (1.0 / 560.0) + 11.3 + seed));
    warp += 55.0 * ds_noise(float2(u * 0.3, v) * (1.0 / 230.0) + 6.1 + seed);
    if (detail > 0) warp += 6.0 * ds_noise(float2(u * 0.5, v) * (1.0 / 60.0) + 2.9 + seed);
    float ph = (u + warp) / L;
    float f = ph - floor(ph);
    float A = ampScale * (0.6 + 0.7 * ds_noise(float2(u * 0.4, v) * (1.0 / 2300.0) + 1.7 + seed * 5.0));
    A *= 0.78 + 0.4 * ds_noise(float2(u * 0.3, v) * (1.0 / 520.0) + 4.4 + seed);   // peaks and saddles
    A = max(A, 2.0);
    float slipW = A / (0.62 * 0.89 * L);           // slip face at ~32 deg
    float c = clamp(1.0 - slipW, 0.45, 0.97);
    DsDune d;
    if (f < c) { d.h = A * ds_windProfile(f / c); d.lee = 0.0; d.brink = (c - f) * L; }
    else       { d.h = A * ds_leeProfile(1.0 - (f - c) / (1.0 - c)); d.lee = 1.0; d.brink = 0.0; }
    d.W = W;
    return d;
}

// ---- hero dune: a big linear dune whose crest snakes away from the camera
inline float ds_bump(float z, float c, float w) { float x = (z - c) / w; return exp(-x * x); }
inline float ds_heroX(float z) {       // crest line x(z); +x = screen left
    return -16.0 - 48.0 * smoothstep(0.0, 450.0, z) + 110.0 * smoothstep(380.0, 1000.0, z)
           - 130.0 * smoothstep(950.0, 1800.0, z) + 6.0 * ds_noise(float2(z * (1.0 / 80.0), 3.3));
}
inline float ds_heroA(float z) {       // crest height above the dune-sea floor
    return 92.0 - 30.0 * ds_bump(z, 430.0, 230.0) + 10.0 * ds_bump(z, 960.0, 260.0)
           - 60.0 * smoothstep(1150.0, 2400.0, z) - 40.0 * smoothstep(-100.0, -600.0, z);
}
inline DsDune ds_hero(float2 p) {
    float z = p.y;
    float xc = ds_heroX(z);
    float dx = (ds_heroX(z + 4.0) - ds_heroX(z - 4.0)) * (1.0 / 8.0);
    float d = (p.x - xc) / sqrt(1.0 + dx * dx);    // signed distance: + windward (left), - lee
    float A = ds_heroA(z);
    DsDune r;
    float2 W = normalize(float2(-1.0, dx));        // local downwind, across the crest
    if (d >= 0.0) {
        float Ww = A / 0.23;                       // ~13 deg mean windward slope
        r.h = A * ds_windProfile(clamp(1.0 - d / Ww, 0.0, 1.0));
        r.lee = 0.0; r.brink = d;
    } else {
        float Wl = A / (0.62 * 0.89);
        r.h = A * ds_leeProfile(1.0 + d / Wl);
        r.lee = 1.0; r.brink = 0.0;
    }
    r.W = W;
    return r;
}

inline float ds_smax(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return max(a, b) + 0.25 * k * h * h;
}

inline DsDune ds_dunes(float2 p, int detail) {
    float base = 30.0 * ds_noise(p * (1.0 / 4600.0) + 5.3);
    // the field is lower around the hero dune so that it dominates
    // windward flank of the hero is clean; on its lee side a flat interdune corridor
    float lat = p.x - ds_heroX(p.y);                 // + windward (left), - lee (right)
    float far = 1.0 - smoothstep(1400.0, 2600.0, p.y);
    float heroZone = (lat > 0.0 ? ds_bump(lat, 0.0, 520.0) : ds_bump(lat, -120.0, 260.0)) * far;
    float amp = 1.0 - 0.9 * heroZone;
    // large-scale domain warp: crest orientation drifts across the sand sea
    float2 pw = p + 420.0 * float2(ds_fbm(p * (1.0 / 3600.0) + 1.3, 2), ds_fbm(p * (1.0 / 3600.0) + 7.9, 2));
    DsDune a = ds_system(pw, 0.0, 1250.0, 0.0, 120.0 * amp, detail);        // big linear-ish ridges
    DsDune b = ds_system(pw, 22.0, 430.0, 3.7, 42.0 * amp, detail);         // crescentic dunes in corridors
    DsDune r = a.h > b.h ? a : b;
    float hh = ds_smax(a.h, b.h, 9.0);
    DsDune hd = ds_hero(p);
    if (hd.h > hh) r = hd;
    r.h = ds_smax(hh, hd.h, 14.0) + base;
    // meso relief: low undulations / small superimposed bedforms
    if (detail > 0) {
        float2 V = float2(-r.W.y, r.W.x);
        float m = ds_fbm(float2(dot(p, r.W) * 0.45, dot(p, V)) * (1.0 / 34.0) + 9.1, 3);   // wind-aligned
        r.h += 0.7 * m * (1.0 - r.lee) * smoothstep(0.0, 25.0, r.brink);
    }
    return r;
}

inline float ds_height(float2 p, int detail) {
    return ds_dunes(p, detail).h;
}

// ------------------------------------------------------------ atmosphere
// Same physical model as ws_atmosphere (Rayleigh + Mie single scattering with
// the Earth's shadow) plus ozone absorption (keeps the low-sun sky blue instead
// of olive), integrated with steps packed near the observer so the dense low
// desert haze at the horizon is resolved (no dark band).
constant float DS_RP = 6371e3;
constant float DS_RA = 6471e3;
constant float3 DS_KR = float3(5.8e-6, 13.5e-6, 33.1e-6);
constant float3 DS_KO = float3(0.650e-6, 1.881e-6, 0.085e-6);
constant float DS_KM0 = 21e-6;
constant float DS_MIE = 0.6;
constant float DS_DUST = 0.0;      // low desert dust layer (scale height 380 m)
constant float DS_ALT = 120.0;
constant float DS_SUNI = 22.0;

inline float ds_ozone(float h) { return max(0.0, 1.0 - abs(h - 25e3) / 15e3); }

// optical depth (rayleigh, mie, ozone) from pp toward dir, to the top of the atmosphere
inline float3 ds_opticalDepth(float3 pp, float3 dir) {
    float len = ws_raySphere(pp, dir, DS_RA).y;
    const int N = 8;
    float3 od = float3(0.0);
    float prev = 0.0;
    for (int i = 0; i < N; i++) {
        float s1 = float(i + 1) / float(N);
        float tt = len * s1 * s1;
        float dt = tt - prev;
        float3 q = pp + dir * (prev + 0.5 * dt);
        float hh = length(q) - DS_RP;
        od += float3(exp(-hh / 8e3), DS_MIE * exp(-hh / 1.2e3) + DS_DUST * exp(-hh / 380.0), ds_ozone(hh)) * dt;
        prev = tt;
    }
    return od;
}
inline float3 ds_extinct(float3 od) {
    return exp(-(DS_KR * od.x + DS_KM0 * 1.1 * od.y + DS_KO * od.z));
}

inline float3 ds_sunTransmittance(float3 sun) {
    return ds_extinct(ds_opticalDepth(float3(0.0, DS_RP + DS_ALT, 0.0), sun));
}

inline float3 ds_sky(float3 rd, float3 sun) {
    float3 r0 = float3(0.0, DS_RP + DS_ALT, 0.0);
    float2 pa = ws_raySphere(r0, rd, DS_RA);
    float tEnd = pa.y;
    float2 pg = ws_raySphere(r0, rd, DS_RP);
    if (pg.x <= pg.y && pg.x > 0.0) tEnd = min(tEnd, pg.x);
    const float kM = DS_KM0;
    const int N = 20;
    float3 od = float3(0.0);
    float prev = 0.0;
    float3 sR = float3(0.0), sM = float3(0.0);
    for (int i = 0; i < N; i++) {
        float s1 = float(i + 1) / float(N);
        float tt = tEnd * s1 * s1 * s1;
        float dt = tt - prev;
        float3 pp = r0 + rd * (prev + 0.5 * dt);
        float hh = length(pp) - DS_RP;
        float3 dd = float3(exp(-hh / 8e3), DS_MIE * exp(-hh / 1.2e3) + DS_DUST * exp(-hh / 380.0), ds_ozone(hh)) * dt;
        float3 oMid = od + 0.5 * dd;
        od += dd;
        prev = tt;
        float2 sg = ws_raySphere(pp, sun, DS_RP);
        if (sg.x <= sg.y && sg.x > 0.0) continue;       // in Earth's shadow
        float3 attn = ds_extinct(oMid + ds_opticalDepth(pp, sun));
        sR += dd.x * attn; sM += dd.y * attn;
    }
    float mu = dot(rd, sun), g = 0.76, gg = g * g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mu * mu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));
    // spectral correction for what single scattering misses at low sun (multiply
    // scattered violet-blue light, stronger Chappuis absorption): less green
    return DS_SUNI * (pR * DS_KR * sR + pM * kM * sM) * float3(1.0, 0.92, 1.0);
}

inline float3 ds_moonDir() {
    float el = 6.6 * PI / 180.0, az = 9.0 * PI / 180.0;
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ------------------------------------------------------------ terrain w/ earth curvature
inline float ds_terrain(float2 xz, float2 camXZ, int detail) {
    float2 d = xz - camXZ;
    return ds_height(xz, detail) - dot(d, d) / (2.0 * DS_EARTH_R);
}

// ------------------------------------------------------------ ripples
// Aeolian ripple field (shading only). Returns gradient of ripple height in xz.
// Asymmetric profile: gentle stoss (72%), steep lee (28%), ripple index ~18.
inline float ds_ripplePhase(float2 p, float2 W, float lam, float seed) {
    float u = dot(p, W);
    float w = 0.6 * ds_noise(p * (1.0 / 26.0) + seed) + 0.25 * ds_noise(p * (1.0 / 9.0) + seed * 2.3)
            + 0.07 * ds_noise(p * (1.0 / 4.3) + seed * 1.7);
    return (u + w) / lam;
}
inline float2 ds_rippleGrad(float2 p, float2 W, float fp, float lam) {
    // two slightly different ripple trains; a noise mask switches between them
    // which produces the characteristic terminations and Y-junctions
    float ph1 = ds_ripplePhase(p, W, lam, 0.0);
    float ph2 = ds_ripplePhase(p, W, lam * 0.87, 19.3);
    float m = smoothstep(-0.15, 0.15, ds_noise(p * (1.0 / 6.5) + 7.7));
    const float s = 0.72;
    float f1 = fract(ph1), f2 = fract(ph2);
    // smoothed asymmetric sawtooth derivative
    float d1 = (f1 < s) ? 1.0 / s : -1.0 / (1.0 - s);
    float d2 = (f2 < s) ? 1.0 / s : -1.0 / (1.0 - s);
    // soften the crest/trough corners a little
    d1 *= smoothstep(0.0, 0.06, f1) * smoothstep(0.0, 0.06, abs(f1 - s)) * 0.6 + 0.4;
    d2 *= smoothstep(0.0, 0.06, f2) * smoothstep(0.0, 0.06, abs(f2 - s)) * 0.6 + 0.4;
    // band-limit: as the pixel footprint approaches the ripple wavelength the sharp
    // sawtooth (rich in harmonics) is replaced by its fundamental, then faded out
    float q = smoothstep(0.07 * lam, 0.22 * lam, fp);
    d1 = mix(d1, 2.4 * sin(TAU * (f1 - 0.1)), q);
    d2 = mix(d2, 2.4 * sin(TAU * (f2 - 0.1)), q);
    float amp = 1.0 / 18.0;                         // height / wavelength
    float dd = mix(d1, d2, m) * amp;                // slope along W
    // amplitude varies in patches
    dd *= 0.65 + 0.35 * ds_noise(p * (1.0 / 14.0) + 3.3);
    // footprint anti-aliasing
    dd *= 1.0 - smoothstep(0.16 * lam, 0.42 * lam, fp);
    return W * dd;
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float3 sun = ds_sunDir();
    if (DS_MODE == 1) {
        float2 uv = (fragCoord - 0.5 * ctx.res) / ctx.res.y * 7000.0;
        float2 pm = float2(-uv.x, uv.y) + DS_CAM_XZ + float2(0.0, 3000.0);
        float e = 2.0;
        float hc = ds_height(pm, 1);
        float hx = ds_height(pm + float2(e, 0), 1), hz = ds_height(pm + float2(0, e), 1);
        float3 nn = normalize(float3(-(hx - hc) / e, 1.0, -(hz - hc) / e));
        float dif = max(dot(nn, normalize(float3(sun.x, 0.5, sun.z))), 0.0);
        float3 mc = float3(0.8, 0.55, 0.35) * (0.08 + 1.2 * dif) + float3(0.0, 0.0, hc / 500.0);
        float2 dc = pm - DS_CAM_XZ;
        if (length(dc) < 25.0) mc = float3(0, 1, 0);
        float hf = atan(tan(DS_FOV * 0.5 * PI / 180.0) * ctx.aspect);
        float an = atan2(dc.x, dc.y);
        if (dc.y > 0.0 && abs(abs(an) - hf) < 0.004) mc = float3(0, 1, 0);
        return ws_acesFitted(mc);
    }

    // ---- camera
    float2 camXZ = DS_CAM_XZ;
    float camY = ds_height(float2(ds_heroX(0.0), 0.0), 0) + DS_CAM_UP;
    float yaw = DS_CAM_YAW * PI / 180.0, pit = DS_CAM_PITCH * PI / 180.0;
    float3 ro = float3(camXZ.x, camY, camXZ.y);
    float3 fwd = float3(sin(yaw) * cos(pit), sin(pit), cos(yaw) * cos(pit));
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ro + fwd, DS_FOV);
    float pixAng = (DS_FOV * PI / 180.0) / ctx.res.y;

    float3 Esun = DS_SUNI * ds_sunTransmittance(sun);

    // ---- raymarch the heightfield
    const float TMAX = 26000.0;
    float tmax = TMAX;
    if (rd.y > 0.0) tmax = min(tmax, (DS_MAXH - ro.y) / rd.y);
    float t = 2.0, tprev = 2.0;
    bool hit = false;
    float dlast = 1e9;
    for (int i = 0; i < 640 && t < tmax; i++) {
        float3 p = ro + rd * t;
        float d = p.y - ds_terrain(p.xz, camXZ, 0);
        if (d < 0.0) { hit = true; break; }
        dlast = d;
        tprev = t;
        t += max(d * 0.75, 0.0011 * t + 0.03);
    }
    // step budget exhausted while grazing a crest: the ray is within dlast of the surface
    if (!hit && t < tmax && dlast < 0.004 * t + 0.5) { hit = true; tprev = t; }

    float3 hazeDir = normalize(float3(rd.x, max(rd.y, 0.004), rd.z));
    float3 col;
    if (hit) {
        float ta = tprev, tb = t;
        for (int j = 0; j < 12; j++) {
            float tm = 0.5 * (ta + tb);
            float3 p = ro + rd * tm;
            if (p.y - ds_terrain(p.xz, camXZ, 0) < 0.0) tb = tm; else ta = tm;
        }
        t = 0.5 * (ta + tb);
        float3 pos = ro + rd * t;
        float2 xz = pos.xz;

        DsDune dn = ds_dunes(xz, 1);
        float fp = t * pixAng;                             // pixel footprint (m)
        // geometric normal, footprint-filtered
        float e = max(0.05, 0.7 * fp);
        float hx0 = ds_height(xz - float2(e, 0), 1), hx1 = ds_height(xz + float2(e, 0), 1);
        float hz0 = ds_height(xz - float2(0, e), 1), hz1 = ds_height(xz + float2(0, e), 1);
        float2 grad = float2(hx1 - hx0, hz1 - hz0) / (2.0 * e);
        float3 nGeo = normalize(float3(-grad.x, 1.0, -grad.y));
        float cosV = max(abs(dot(rd, nGeo)), 0.06);
        float fpS = fp / cosV;                             // footprint stretched on the surface

        // --- surface zones
        float slope = length(grad);
        float slipZone = dn.lee;
        float windward = (1.0 - slipZone) * (1.0 - smoothstep(0.42, 0.58, slope));
        float nearBrink = 1.0 - smoothstep(0.5, 6.0, dn.brink);

        // --- wind ripples (normal perturbation) on windward slopes & interdunes
        float2 W = dn.W;
        float2 V = float2(-W.y, W.x);
        // anisotropic footprint along the ripple-normal direction W
        float3 va = rd - nGeo * dot(rd, nGeo);
        va = dot(va, va) > 1e-8 ? normalize(va) : float3(1, 0, 0);
        float wa = dot(normalize(float3(W.x, dot(grad, W), W.y)), va);
        float fpW = fp * sqrt(wa * wa / (cosV * cosV) + max(1.0 - wa * wa, 0.0));
        float2 W2 = normalize(W + 0.25 * V);
        float wa2 = dot(normalize(float3(W2.x, dot(grad, W2), W2.y)), va);
        float fpW2 = fp * sqrt(wa2 * wa2 / (cosV * cosV) + max(1.0 - wa2 * wa2, 0.0));
        float2 rg = ds_rippleGrad(xz, W, fpW, 0.85);
        rg += 0.18 * ds_rippleGrad(xz * 1.0 + 31.0, W2, fpW2, 0.38);
        float patch = smoothstep(-0.45, 0.35, ds_fbm(xz * (1.0 / 45.0) + 12.0, 2));
        float crestSmooth = smoothstep(2.0, 14.0, dn.brink);
        rg *= windward * mix(0.25, 1.0, patch) * mix(0.2, 1.0, crestSmooth);
        // grain-flow streaks down the slip face
        float streak = ds_noise(float2(dot(xz, V) * (1.0 / 1.6), dot(xz, W) * (1.0 / 22.0)) + 4.1)
                     + 0.5 * ds_noise(float2(dot(xz, V) * (1.0 / 0.6), dot(xz, W) * (1.0 / 9.0)) + 8.3);
        float fpV = fp * sqrt(dot(float3(V.x, 0, V.y), va) * dot(float3(V.x, 0, V.y), va) / (cosV * cosV) + 1.0);
        float streakAA = 1.0 - smoothstep(0.3, 1.2, fpV);
        float2 sg = V * (0.035 * streakAA * slipZone) * ds_noise(float2(dot(xz, V) * (1.0 / 1.1), dot(xz, W) * (1.0 / 14.0)) + 1.9);
        float3 n = normalize(float3(-(grad.x + rg.x + sg.x), 1.0, -(grad.y + rg.y + sg.y)));

        // --- cast shadow toward the sun (0.53 deg disk -> crisp penumbra)
        float sh = 1.0;
        {
            float st = 0.3;
            float3 o = pos + nGeo * 0.12;
            for (int k = 0; k < 110; k++) {
                float3 q = o + sun * st;
                if (q.y > DS_MAXH) break;
                float dq = q.y - ds_height(q.xz, 0);
                sh = min(sh, 160.0 * dq / st);
                if (sh < 0.0) break;
                st += clamp(dq * 0.6, 0.25, 35.0);
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
                float r = (k & 1) ? 55.0 : 16.0;
                float2 o = float2(cos(a), sin(a)) * r;
                float hs = ds_height(xz + o, 0);
                occ += max(hs - (h0 + dot(grad, o)), 0.0) / r;
            }
            occ = clamp(1.0 - 0.45 * occ, 0.5, 1.0);
        }

        // --- albedo: Namib iron-oxide sand with subtle variation
        float3 albBase = ws_hex(0xD9A273u);
        float big = ds_fbm(xz * (1.0 / 380.0) + 2.0, 3);
        float3 alb = albBase * (1.0 + 0.07 * big);
        alb = mix(alb, alb * float3(0.93, 0.95, 1.02), 0.5 + 0.5 * ds_noise(xz * (1.0 / 900.0)));
        // lee faces: fresh avalanche sand slightly lighter; streaks
        alb *= 1.0 + slipZone * (0.04 + 0.05 * streak * streakAA);
        // interdune corridors: a touch greyer/darker (coarser, compacted sand)
        float low = 1.0 - smoothstep(4.0, 22.0, dn.h - 30.0 * ds_noise(xz * (1.0 / 4600.0) + 5.3));
        float crestLight = (1.0 - smoothstep(0.0, 18.0, dn.brink)) * (1.0 - slipZone);
        alb = mix(alb, alb * float3(0.9, 0.88, 0.9), 0.5 * low);
        // grain-scale speckle (filtered)
        float g1 = ds_noise(xz * 22.0) * (1.0 - smoothstep(0.02, 0.08, fpS));
        float g2 = ds_noise(xz * 5.0 + 3.0) * (1.0 - smoothstep(0.08, 0.3, fpS));
        alb *= 1.0 + 0.06 * g1 + 0.05 * g2;

        // --- lighting
        float ndl = max(dot(n, sun), 0.0);
        float2 sxz = normalize(sun.xz);
        float2 pxz = float2(-sxz.y, sxz.x);
        // sky irradiance from a zenith + 4 low-sky samples, clamped-cosine weighted
        const float ce = 0.94, se = 0.34;                  // 20 deg elevation
        float3 dS = float3(sxz.x * ce, se, sxz.y * ce), dA = float3(-sxz.x * ce, se, -sxz.y * ce);
        float3 dL = float3(pxz.x * ce, se, pxz.y * ce),  dR = float3(-pxz.x * ce, se, -pxz.y * ce);
        float3 LZ = ds_sky(float3(0.0, 1.0, 0.0001), sun);
        float3 LS = ds_sky(dS, sun), LA = ds_sky(dA, sun), LL = ds_sky(dL, sun), LR = ds_sky(dR, sun);
        float wZ = max(n.y + 0.25, 0.0);
        float wS = max(dot(n, dS) + 0.25, 0.0), wA = max(dot(n, dA) + 0.25, 0.0);
        float wL = max(dot(n, dL) + 0.25, 0.0), wR = max(dot(n, dR) + 0.25, 0.0);
        // normalisation: a flat surface gets E = pi * (0.55 Lzen + 0.45 <Lhorizon>)
        float3 Esky = PI * (0.55 * LZ * wZ / 1.25 + 0.45 * 0.25 * (LS * wS + LA * wA + LL * wL + LR * wR) / 0.59);
        // single scattering misses the multiply-scattered skylight (large at low sun, bluish)
        Esky *= float3(1.5, 1.75, 2.15);
        float towardSun = dot(nGeo.xz, sxz);
        // rough-diffuse sand: Lambert blended with a flatter Lommel-Seeliger lobe
        float mu0 = ndl, muv = max(dot(n, -rd), 0.02);
        float ls = 2.0 * mu0 / (mu0 + muv);
        float brdfSun = mix(1.0, ls * 0.8, 0.25);
        float3 direct = alb / PI * Esun * ndl * brdfSun * sh;
        float3 ambient = alb / PI * Esky * occ;
        // one-bounce from the surrounding sunlit sand (seen mostly by steep, sun-averted faces)
        float3 Lground = alb / PI * (Esun * 0.14 + Esky * 0.8);
        float seeGround = 0.5 - 0.5 * n.y;
        float3 bounce = alb * Lground * (seeGround + 0.12 * max(-towardSun, 0.0)) * (1.6 - occ) * 0.8;
        col = direct + ambient + bounce;

        // --- aerial perspective
        float3 fogCol = ds_sky(hazeDir, sun);
        float fa = ws_fogAmount(t, ro, rd, 1.0 / 9000.0, 1.0 / 700.0);
        col = mix(col, fogCol, fa);
    } else {
        col = ds_sky(rd.y > 0.0 ? rd : hazeDir, sun);
        // faint crescent moon, lit by the real sun direction (phase from geometry)
        float3 md = ds_moonDir();
        float mr = 0.27 * PI / 180.0;
        float ca = dot(rd, md);
        if (ca > cos(mr * 1.6)) {
            float3 mu = normalize(cross(float3(0.0, 1.0, 0.0), md));
            float3 mv = cross(md, mu);
            float2 q = float2(dot(rd, mu), dot(rd, mv)) / mr;
            float r2 = dot(q, q);
            float edge = 1.0 - smoothstep(0.93, 1.02, sqrt(r2));
            if (edge > 0.0) {
                float nz = sqrt(max(1.0 - r2, 0.0));
                float3 N = normalize(q.x * mu + q.y * mv - nz * md);
                float mu0 = max(dot(N, sun), 0.0), mue = max(nz, 0.02);
                float lsm = mu0 / (mu0 + mue);                     // Lommel-Seeliger (flat lunar disk)
                float maria = 1.0 - 0.28 * smoothstep(0.05, 0.45, ds_fbm(q * 2.2 + 4.0, 4))
                                  - 0.08 * ds_noise(q * 9.0 + 1.0);
                float3 Tm = ds_extinct(ds_opticalDepth(float3(0.0, DS_RP + DS_ALT, 0.0), md));
                float3 Lm = 0.12 * maria * DS_SUNI * 2.0 * lsm * Tm * 0.55;
                Lm += 0.004 * maria * float3(0.6, 0.7, 1.0);        // earthshine
                col += Lm * edge;
            }
        }
    }
    // lens veiling glare: a small fraction of the average scene radiance scattered
    // across the frame (lifts and warms the deepest shadows like a real lens)
    col += float3(0.55, 0.42, 0.30) * 0.008;
    // natural lens vignetting (cos^4-ish falloff, very gentle)
    float2 uvv = fragCoord / ctx.res;
    col *= ws_vignette(uvv, 0.22);
    // camera white balance (daylight-ish: keeps sun warm, skylight cool) + exposure
    col *= float3(0.92, 0.955, 1.14) * 1.42;
    // tone map: fitted ACES blended with a hue-preserving (luminance) variant so the
    // bright orange horizon glow does not skew to olive-yellow
    float3 oA = ws_acesFitted(col);
    float Lc = max(ws_luma(col), 1e-6);
    float3 oL = col * (ws_luma(ws_acesFitted(float3(Lc))) / Lc);
    oL /= max(1.0, max(oL.r, max(oL.g, oL.b)));
    float3 o = mix(oA, oL, 0.45);
    // gentle split-tone: cool the shadows a touch, as a colourist would
    float lo = 1.0 - smoothstep(0.02, 0.25, ws_luma(o));
    o = mix(o, o * float3(0.94, 0.97, 1.10), lo * 0.6);
    // very fine film grain (luminance), amplitude well under the banding threshold
    o += (ws_grain(fragCoord, 0.37) * 0.0045) * (0.4 + 0.6 * sqrt(max(ws_luma(o), 0.0)));
    return clamp(o, 0.0, 1.0);
}
