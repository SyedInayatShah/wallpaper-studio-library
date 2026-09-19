// =====================================================================
//  Golden Swell — open ocean at golden hour, camera 1.5 m above the sea.
//  Units: metres. y up, camera looks toward +z. Mean sea level y = 0.
//  Earth curvature is modelled (horizon ~4.4 km away).
// =====================================================================

constant float GS_RE    = 6371e3;
constant float GS_CAMH  = 1.5;
constant float GS_FOVY  = 34.0;       // vertical field of view (deg)
constant float GS_HOR   = 0.42;       // horizon height as fraction of frame (from bottom)
constant float GS_SUNEL = 4.8;        // sun elevation (deg)
constant float GS_SUNAZ = -6.5;       // sun azimuth (deg, negative = left of frame centre)
constant float GS_SUNI  = 22.0;       // sun irradiance scale for ws_atmosphere
constant float GS_MIE   = 0.6;        // marine aerosol strength
constant float GS_EXPO  = 0.42;
#ifndef GS_DBG
#define GS_DBG 0
#endif
#ifndef GS_LIVECONST
#define GS_LIVECONST 0
#endif

// cloud deck
constant float GS_CB = 1500.0;        // cloud base (m)
constant float GS_CT = 1900.0;        // cloud top  (m)

// waves (spectral Gerstner sum)
constant int   GS_NW     = 160;       // wave components
constant float GS_LAM0   = 110.0;     // longest wavelength (m)
constant float GS_LAMMIN = 0.025;     // shortest wavelength (m)
constant float GS_STEEP  = 0.016;     // per-component steepness (a*k) in the equilibrium range
constant float GS_CHOP   = 1.6;       // Gerstner choppiness
constant float GS_WIND   = 3.40;      // wind-sea propagation angle (rad), ~toward camera
constant float GS_SWELL  = 2.80;      // swell propagation angle (rad)

inline float3 gs_sunDir() {
    float el = GS_SUNEL * (PI / 180.0), az = GS_SUNAZ * (PI / 180.0);
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ------------------------------------------------------------ atmosphere helpers
// Transmittance of sunlight reaching altitude `alt` (Rayleigh + Mie, same constants as ws_atmosphere)
inline float3 gs_sunTrans(float alt, float3 sd) {
    const float Rp = 6371e3, Ra = 6471e3;
    float3 p0 = float3(0.0, Rp + alt, 0.0);
    float L = ws_raySphere(p0, sd, Ra).y;
    const int N = 12;
    float odR = 0.0, odM = 0.0;
    float tPrev = 0.0;
    for (int i = 0; i < N; i++) {
        float u1 = float(i + 1) / float(N);
        float t1 = L * u1 * u1;
        float tm = 0.5 * (tPrev + t1);
        float h = length(p0 + sd * tm) - Rp;
        float dt = t1 - tPrev;
        odR += exp(-h / 8e3) * dt;
        odM += exp(-h / 1.2e3) * dt;
        tPrev = t1;
    }
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    float kM = 21e-6 * GS_MIE;
    return exp(-(kR * odR + kM * 1.1 * odM));
}

// In-scattered light (airlight) and transmittance along a view ray from the camera to `dist`
// (same Rayleigh + Mie model as ws_atmosphere, but for a finite segment).
inline float3 gs_airlight(float3 rd, float3 sd, float dist, thread float3& Tair) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kM = 21e-6 * GS_MIE;
    const int N = 10, NL = 6;
    float3 r0 = float3(0.0, Rp + 2.0, 0.0);
    float mu = dot(rd, sd), mumu = mu * mu, g = 0.78, gg = g * g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));
    float3 tR = float3(0.0), tM = float3(0.0);
    float odR = 0.0, odM = 0.0;
    float tPrev = 0.0;
    for (int i = 0; i < N; i++) {
        float u1 = float(i + 1) / float(N);
        float t1 = dist * u1 * u1;
        float tm = 0.5 * (tPrev + t1), dt = t1 - tPrev;
        tPrev = t1;
        float3 pos = r0 + rd * tm;
        float h = length(pos) - Rp;
        float dR = exp(-h / 8e3) * dt, dM = exp(-h / 1.2e3) * dt;
        odR += dR; odM += dM;
        float jl = ws_raySphere(pos, sd, Ra).y;
        float jR = 0.0, jM = 0.0, jp = 0.0;
        for (int j = 0; j < NL; j++) {
            float v1 = float(j + 1) / float(NL);
            float j1 = jl * v1 * v1;
            float jm = 0.5 * (jp + j1);
            float hj = length(pos + sd * jm) - Rp;
            jR += exp(-hj / 8e3) * (j1 - jp);
            jM += exp(-hj / 1.2e3) * (j1 - jp);
            jp = j1;
        }
        float3 att = exp(-(kR * (odR + jR) + kM * 1.1 * (odM + jM)));
        tR += dR * att; tM += dM * att;
    }
    Tair = exp(-(kR * odR + kM * 1.1 * odM));
    return GS_SUNI * (pR * kR * tR + pM * kM * tM);
}

inline float3 gs_skyRad(float3 rd, float3 sd) {
    float3 d = rd;
    d.y = max(d.y, 0.0005);
    d = normalize(d);
    return ws_atmosphere(d, sd, GS_SUNI, 0.78, GS_MIE, 2.0);
}

// ------------------------------------------------------------ clouds
inline float gs_remap(float v, float a, float b, float c, float d) {
    return c + (d - c) * clamp((v - a) / (b - a), 0.0, 1.0);
}

// 2D cloud field (0 = clear, 1 = thick) at horizontal position q (metres)
// Broken stratocumulus: irregular rolls across the wind + cells, large holes, ragged far edge.
inline float gs_cloudField(float2 q, int lod) {
    float2 wq = q + 1500.0 * float2(gnoise(q * (1.0 / 8000.0) + 1.3), gnoise(q * (1.0 / 8000.0) + 7.9));
    float cov = fbm(wq * (1.0 / 8000.0) + float2(1.3, 6.2), 3) * 0.5 + 0.5;
    float edge = q.y + 2600.0 * gnoise(q * (1.0 / 4500.0) + 2.2) + 1200.0 * gnoise(q * (1.0 / 1500.0) + 5.1);
    cov = cov * 1.2 + 0.32 - 1.3 * smoothstep(11000.0, 17000.0, edge);
    // calmer upper-right of the frame (desktop icons)
    cov -= 0.22 * smoothstep(0.0, 5000.0, q.x) * (1.0 - smoothstep(6000.0, 11000.0, q.y));
    if (cov <= 0.0) return 0.0;
    // rolls (crests across the wind), irregular
    float ra = 0.34 + 0.35 * gnoise(q * (1.0 / 14000.0) + 8.8);
    float2 rdir = float2(sin(ra), cos(ra));
    float s = dot(wq, rdir) * (1.0 / 1500.0) + 0.9 * gnoise(wq * (1.0 / 3000.0) + 4.4);
    float roll = 0.5 + 0.5 * sin(TAU * s);
    // cells elongated along the roll axis
    float2 rp = float2(dot(wq, float2(rdir.y, -rdir.x)) * 0.55, dot(wq, rdir)) * (1.0 / 950.0);
    float cell = clamp(1.0 - worley(rp).x * 1.05, 0.0, 1.0);
    // domain-warped fractal detail (crisp, intricate edges)
    float2 dq = wq + 380.0 * float2(fbm(wq * (1.0 / 1300.0) + 1.7, 3), fbm(wq * (1.0 / 1300.0) + 9.2, 3));
    float n = fbm(dq * (1.0 / 520.0) + 3.3, lod == 0 ? 7 : 3) * 0.5 + 0.5;
    float F = cov * (0.30 * roll + 0.35 * cell + 0.5 * n);
    F = gs_remap(F, 0.44, 0.92, 0.0, 1.0);
    if (F <= 0.0) return 0.0;
    // small cloudlets (~250 m) separated by thin gaps where the deck is thin
    float cm;
    if (lod == 0) {
        float2 cw = wq * (1.0 / 230.0) + float2(5.5, 1.1) + 0.8 * float2(gnoise(wq * (1.0 / 700.0)), gnoise(wq * (1.0 / 700.0) + 3.3));
        float2 w2 = worley(cw);
        cm = smoothstep(0.0, 0.5, w2.y - w2.x);
    } else {
        cm = 0.8;
    }
    F *= mix(0.55 + 0.45 * cm, 1.0, smoothstep(0.35, 0.8, F));
    return F;
}

// p = (x, altitude, z) in metres. lod 0 = full detail, 1 = cheap.
// Returns density; topOut = normalised height of the local cloud top (for ambient occlusion)
inline float gs_cloudDensT(float3 p, int lod, thread float& topOut) {
    topOut = 0.0;
    float h = (p.y - GS_CB) / (GS_CT - GS_CB);
    if (h <= 0.0 || h >= 1.0) return 0.0;
    float F = gs_cloudField(p.xz, lod);
    if (F <= 0.0) return 0.0;
    // sharp condensation base that hangs lower under the thick parts; domed top
    float bot = 0.24 * (1.0 - F) + (lod == 0 ? 0.035 * gnoise(p.xz * (1.0 / 260.0)) : 0.0);
    float top = 0.4 + 0.6 * F;
    topOut = top;
    float prof = smoothstep(bot, bot + 0.04, h) * (1.0 - smoothstep(top - 0.3, top, h));
    float d = sqrt(F) * prof;
    if (d <= 0.0) return 0.0;
    if (lod == 0) {
        // multiplicative mottling at two scales (no subtractive erosion: it draws iso-contours)
        float det = fbm(p * float3(1.0 / 240.0, 1.0 / 130.0, 1.0 / 240.0), 2);
        float det2 = fbm(p * float3(1.0 / 70.0, 1.0 / 45.0, 1.0 / 70.0) + 7.7, 2);
        d *= clamp(1.0 + 0.7 * det + 0.35 * det2, 0.15, 1.8);
    }
    return d;
}
inline float gs_cloudDens(float3 p, int lod) { float t; return gs_cloudDensT(p, lod, t); }

inline float gs_hg(float c, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(1.0 + gg - 2.0 * g * c, 1.5));
}

// Volumetric cloud deck. Coarse steps through empty space, fine steps inside cloud.
// returns (rgb scattered radiance, transmittance); dist = mean scattering distance
inline float4 gs_clouds(float3 rd, float3 sd, float3 sunCol, float3 ambTop, float3 ambBot,
                        int steps, int lsteps, int lod, float jitter, thread float& dist) {
    float3 ro = float3(0.0, GS_RE + GS_CAMH, 0.0);
    dist = 0.0;
    if (rd.y < 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    float t0 = ws_raySphere(ro, rd, GS_RE + GS_CB).y;
    float t1 = ws_raySphere(ro, rd, GS_RE + GS_CT).y;
    t1 = min(t1, t0 + 9000.0);
    if (t0 > 120000.0) return float4(0.0, 0.0, 0.0, 1.0);
    float dtc = (t1 - t0) / float(steps);
    float dtf = lod == 0 ? clamp(t0 * 0.0014, 9.0, 60.0) : max(dtc * 0.35, 30.0);
    dtf = min(dtf, dtc);
    int maxIt = lod == 0 ? steps + 96 : steps + 12;
    float mu = dot(rd, sd);
    float T = 1.0;
    float3 L = float3(0.0);
    float wsum = 0.0, dsum = 0.0;
    const float sigma = 0.045;                       // extinction per metre at density 1
    float phs[3];
    for (int o = 0; o < 3; o++) {
        float g = 0.85 * pow(0.5, float(o));
        phs[o] = mix(gs_hg(mu, g), gs_hg(mu, -0.2 * pow(0.5, float(o))), 0.25);
    }
    float t = t0 + dtc * jitter;
    bool fine = false;
    int empty = 0;
    for (int i = 0; i < maxIt; i++) {
        if (t > t1 || T < 0.01) break;
        float3 P = ro + rd * t;
        float alt = length(P) - GS_RE;
        float3 pc = float3(P.x, alt, P.z);
        float ctop;
        float d = gs_cloudDensT(pc, lod, ctop);
        if (!fine && d > 0.003) {                 // entered a cloud: back up and refine
            fine = true; empty = 0;
            t = max(t0, t - dtc) + dtf * jitter;
            continue;
        }
        float dt = fine ? dtf : dtc;
        if (d > 0.003) {
            empty = 0;
            float tauL = 0.0;
            float ls = lod == 0 ? 15.0 : 40.0;
            float3 lp = pc;
            for (int j = 0; j < lsteps; j++) {
                lp += sd * ls;
                tauL += gs_cloudDens(lp, 1) * ls;
                ls *= 2.0;
            }
            tauL *= sigma;
            float hfr = clamp((alt - GS_CB) / (GS_CT - GS_CB), 0.0, 1.0);
            float3 sunS = float3(0.0);
            float a = 1.0, b = 1.0;
            for (int o = 0; o < 3; o++) {
                sunS += a * exp(-tauL * b) * phs[o];
                a *= 0.25; b *= 0.28;
            }
            // sky light from above is occluded by the cloud mass overhead; bases see the sea + horizon
            float tauUp = sigma * d * max(ctop - hfr, 0.0) * (GS_CT - GS_CB) * 0.8;
            float tauDn = sigma * d * hfr * (GS_CT - GS_CB) * 0.8;
            float3 amb = ambTop * (exp(-tauUp) * 0.6 + 0.4 * exp(-tauUp * 0.25)) * 0.8
                       + ambBot * (exp(-tauDn) * 0.6 + 0.4 * exp(-tauDn * 0.25));
            float3 S = sunCol * sunS + amb;
            if (GS_DBG == 9) S = sunCol * sunS;
            if (GS_DBG == 10) S = amb;
            float se = d * sigma;
            float Ts = exp(-se * dt);
            L += T * S * (1.0 - Ts);                 // energy-conserving (albedo 1)
            wsum += T * (1.0 - Ts); dsum += T * (1.0 - Ts) * t;
            T *= Ts;
        } else if (fine) {
            empty++;
            if (empty > 10) fine = false;
        }
        t += dt;
    }
    dist = wsum > 0.0 ? dsum / wsum : t0;
    return float4(L, T);
}

// ------------------------------------------------------------ ocean
// Spectral sea: GS_NW Gerstner components, stratified in log-wavenumber (long -> short),
// Phillips-like equilibrium range (constant steepness per component), directional spreading
// that widens for short waves, a gentle swell, and wind-roughness patches for short waves.
inline void gs_wave(int i, thread float2& dir, thread float& k, thread float& a, thread float& ph) {
    float fi = float(i);
    float4 h = hash44(float4(fi, 17.0, 3.0, 11.0));
    float u = (fi + h.x) / float(GS_NW);
    k = (TAU / GS_LAM0) * exp(u * log(GS_LAM0 / GS_LAMMIN));
    float lam = TAU / k;
    // directional spreading (approx. gaussian via sum of two uniforms)
    float g = (h.y + h.w - 1.0);
    bool swell = (lam > 45.0) && (h.z < 0.6);
    float spread = mix(0.45, 1.25, smoothstep(30.0, 1.0, lam));
    float ang = swell ? GS_SWELL + 0.25 * g : GS_WIND + spread * g * 1.4;
    dir = float2(sin(ang), cos(ang));
    // steepness: spectral peak ~ 30 m, equilibrium range below, weaker capillary tail
    float steep = GS_STEEP * smoothstep(GS_LAM0 * 1.05, 28.0, lam) * (1.0 + 0.5 * smoothstep(1.5, 0.2, lam));
    if (swell) steep = 0.012;
    a = steep / k;
    ph = fract(h.z * 7.13 + h.x * 3.1) * TAU;
}

inline float gs_roughPatch(float2 x) {
    return clamp(0.8 + 0.75 * fbm(x * (1.0 / 180.0) + float2(7.0, 2.0), 3), 0.25, 1.5);
}
inline float gs_fw(float lam, float fp) { return smoothstep(1.2, 2.5, lam / max(fp, 1e-4)); }

// Horizontal Gerstner displacement at undisplaced position x0 (waves longer than lamMin)
inline float2 gs_disp(float2 x0, float fp, float lamMin) {
    float2 D = float2(0.0);
    for (int i = 0; i < GS_NW; i++) {
        float2 dir; float k, a, ph;
        gs_wave(i, dir, k, a, ph);
        float lam = TAU / k;
        if (lam < lamMin) break;
        float w = gs_fw(lam, fp);
        if (w <= 0.0) break;
        float th = dot(dir, x0) * k + ph;
        D += dir * (GS_CHOP * a * w * sin(th));
    }
    return D;
}

// Height of the sea at world xz (fixed-point Gerstner inversion)
inline float gs_seaH(float2 x, float fp, float lamMin, int iters) {
    float2 x0 = x;
    for (int it = 0; it < iters; it++) x0 = x + gs_disp(x0, fp, lamMin);
    float h = 0.0;
    for (int i = 0; i < GS_NW; i++) {
        float2 dir; float k, a, ph;
        gs_wave(i, dir, k, a, ph);
        float lam = TAU / k;
        if (lam < lamMin) break;
        float w = gs_fw(lam, fp);
        if (w <= 0.0) break;
        h += a * w * cos(dot(dir, x0) * k + ph);
    }
    return h;
}

struct GSSurf { float3 n; float var; float h; float jac; float rough; };

inline GSSurf gs_seaSurf(float2 x, float fp) {
    GSSurf s;
    float2 x0 = x;
    for (int it = 0; it < 3; it++) x0 = x + gs_disp(x0, fp, 1.0);
    float rp = gs_roughPatch(x);
    float3 nrm = float3(0.0, 1.0, 0.0);
    float h = 0.0, var = 0.0;
    float jxx = 1.0, jzz = 1.0, jxz = 0.0;
    for (int i = 0; i < GS_NW; i++) {
        float2 dir; float k, a, ph;
        gs_wave(i, dir, k, a, ph);
        float lam = TAU / k;
        float amp = a * (lam < 3.0 ? mix(1.0, rp, smoothstep(3.0, 1.0, lam)) : 1.0);
        float w = gs_fw(lam, fp);
        float st = amp * k;
        var += (1.0 - w * w) * st * st * 0.5;
        if (w <= 0.0) continue;
        amp *= w;
        float th = dot(dir, x0) * k + ph;
        float S = sin(th), C = cos(th);
        float wa = k * amp;
        float q = GS_CHOP;
        h += amp * C;
        nrm.x += dir.x * wa * S;
        nrm.z += dir.y * wa * S;
        nrm.y -= q * wa * C;
        jxx -= q * wa * dir.x * dir.x * C;
        jzz -= q * wa * dir.y * dir.y * C;
        jxz -= q * wa * dir.x * dir.y * C;
    }
    var += 0.0035 * rp;             // capillary micro-roughness (never resolved)
    s.n = normalize(float3(nrm.x, max(nrm.y, 0.05), nrm.z));
    s.var = var;
    s.h = h;
    s.jac = jxx * jzz - jxz * jxz;
    s.rough = rp;
    return s;
}

// ------------------------------------------------------------ shading helpers
inline float gs_ggx(float nh, float a2) {
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}
inline float gs_fresnel(float c) {
    float m = clamp(1.0 - c, 0.0, 1.0);
    float m2 = m * m;
    return 0.02 + 0.98 * m2 * m2 * m;
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
#ifdef GS_CROP
    // 1:1 window of the 3840x2400 frame; GS_CROP = top-left corner (x, y from top)
    fragCoord = fragCoord + float2(GS_CROP.x, 2400.0 - GS_CROP.y - ctx.res.y);
    ctx.res = float2(3840.0, 2400.0);
#endif
    float3 sd = gs_sunDir();
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
    if (GS_DBG == 8) {   // top-down map of the cloud field, 50 km wide, camera at bottom centre
        float2 q = float2(p.x, p.y + 1.0) * 25000.0 * float2(1.0, 0.8);
        float F = gs_cloudField(q, 0);
        float3 c = float3(F);
        // frame wedge
        float ang = atan2(q.x, q.y);
        if (abs(ang) < 0.47 && abs(abs(ang) - 0.47) < 0.004) c = float3(1, 0, 0);
        return c;
    }
    if (GS_DBG == 6 || GS_DBG == 7) {   // top-down view of the sea
        float2 xz = float2(p.x, p.y) * 30.0 + float2(0.0, 80.0);
        float fpd = 60.0 / ctx.res.y;
        GSSurf s = gs_seaSurf(xz, fpd);
        float3 n = s.n;
        float h0 = s.h;
        if (GS_DBG == 7) return float3(clamp(h0 * 0.8 + 0.5, 0.0, 1.0), clamp(h0 * 0.8 + 0.5, 0.0, 1.0), clamp(h0 * 0.8 + 0.5, 0.0, 1.0) + smoothstep(0.4, 0.0, s.jac));
        float3 L = normalize(float3(0.4, 0.8, 0.3));
        float dif = max(dot(n, L), 0.0);
        return clamp(float3(0.15, 0.3, 0.45) * (0.2 + dif) * 0.8, 0.0, 1.0);
    }
    float kf = tan(GS_FOVY * (PI / 180.0) * 0.5);
    float dip = sqrt(2.0 * GS_CAMH / GS_RE);
    float pitch = atan((1.0 - 2.0 * GS_HOR) * kf) - dip;
    float3 f = float3(0.0, sin(pitch), cos(pitch));
    float3 r = float3(1.0, 0.0, 0.0);
    float3 u = cross(f, r);
    float3 rd = normalize(f + (p.x * r + p.y * u) * kf);
    float3 ro = float3(0.0, GS_CAMH, 0.0);
    float pixAng = 2.0 * kf / ctx.res.y;
    float jit = hash12(fragCoord * 1.37 + 0.123);

    // light
#if GS_LIVECONST
    float3 sunE0 = GS_SUNI * gs_sunTrans(2.0, sd);                       // direct irradiance at sea level
    float3 sunEc = GS_SUNI * gs_sunTrans(0.5 * (GS_CB + GS_CT), sd);     // at the cloud deck
#else
    // image constants measured with GS_DBG 12 (sun 4.8 deg, Mie 0.6) — re-measure if lighting changes
    const float3 sunE0 = float3(11.612, 6.236, 2.859);
    const float3 sunEc = float3(14.551, 8.799, 4.682);
#endif
    float3 sdH = normalize(float3(sd.x, 0.0, sd.z));
    // sky-dome ambient for clouds: from above (blue) and from below (horizon glow + dark sea)
#if GS_LIVECONST
    float3 skyUp = 0.5 * (gs_skyRad(normalize(float3(0.0, 0.8, -0.6)), sd) + gs_skyRad(normalize(sdH + float3(0.0, 1.2, 0.0)), sd));
    float3 skyHz = 0.5 * (gs_skyRad(normalize(sdH + float3(0.0, 0.05, 0.0)), sd) + gs_skyRad(normalize(float3(-sdH.x, 0.05, -sdH.z)), sd));
    float3 skyZen = gs_skyRad(float3(0.0, 1.0, 0.0), sd);
#else
    const float3 skyUp  = float3(0.08253, 0.13814, 0.16418);
    const float3 skyHz  = float3(4.28953, 2.25371, 0.94524);
    const float3 skyZen = float3(0.04568, 0.07916, 0.09646);
#endif
    float3 ambTop = mix(skyUp, skyZen, 0.5) * 1.1;
    float muV = max(dot(rd, sd), 0.0);
    // cloud bases see the dark sea (reflecting the blue upper sky) plus the horizon glow,
    // which forward-scatters toward the viewer mostly in the sun's direction
    float3 ambBot = skyZen * 1.3 + skyHz * 0.012 * (0.4 + 5.0 * pow(muV, 8.0));

    float3 col;
    if (GS_DBG == 12) {   // constant light values encoded as swatches (decoded by readvals.py)
        int ix = int(fragCoord.x / ctx.res.x * 6.0);
        float2 uv = fragCoord / ctx.res;
        float sdist3;
        float4 sc = gs_clouds(sd, sd, sunEc, ambTop, ambBot, 8, 1, 1, 0.5, sdist3);
        float3 v = ix == 0 ? sunE0 : ix == 1 ? sunEc : ix == 2 ? skyUp : ix == 3 ? skyHz : ix == 4 ? skyZen : float3(sc.a);
        float sc2 = ix == 0 || ix == 1 || ix == 3 ? 32.0 : ix == 5 ? 1.0 : 2.0;
        return v / (uv.y > 0.5 ? sc2 : sc2 * 0.125);
    }
    if (GS_DBG == 11) {
        float2 uv = fragCoord / ctx.res;
        float sdist3;
        float4 sc = gs_clouds(sd, sd, sunEc, ambTop, ambBot, 8, 1, 1, 0.5, sdist3);
        float3 c = uv.x < 0.2 ? skyZen : uv.x < 0.4 ? ambTop : uv.x < 0.6 ? ambBot : uv.x < 0.8 ? sunE0 * 0.05 : float3(sc.a);
        return ws_acesFitted(c * (uv.y > 0.5 ? GS_EXPO : GS_EXPO * 4.0));
    }

    // ---------------------------------------------------- ocean intersection
    bool hitSea = false;
    float tHit = 0.0;
    const float HMAX = 1.2, HMIN = -1.2;
    if (rd.y < 0.0) {
        float t = max(0.0, (GS_CAMH - HMAX) / -rd.y);
        float tPrev = t;
        for (int i = 0; i < 180; i++) {
            float3 pp = ro + rd * t;
            float fp = t * pixAng / sqrt(max(-rd.y, 0.002));
            float curv = (t * t) / (2.0 * GS_RE);
            float d = pp.y + curv - gs_seaH(pp.xz, fp * 1.5, 2.0, 1);
            if (d < 0.0) {
                float a = tPrev, b = t;
                for (int j = 0; j < 7; j++) {
                    float m = 0.5 * (a + b);
                    float3 pm = ro + rd * m;
                    float fpm = m * pixAng / sqrt(max(-rd.y, 0.002));
                    float dm = pm.y + m * m / (2.0 * GS_RE) - gs_seaH(pm.xz, fpm * 1.5, 2.0, 2);
                    if (dm < 0.0) b = m; else a = m;
                }
                tHit = 0.5 * (a + b);
                hitSea = true;
                break;
            }
            tPrev = t;
            float step = d / (-rd.y + 0.3);
            float minStep = 0.02 + t * 0.002 + t * t * pixAng * 0.3;
            t += max(step, minStep);
            if (t > 7000.0 || pp.y + curv < HMIN) break;
        }
    }

    if (hitSea) {
        float3 P = ro + rd * tHit;
        float fp = tHit * pixAng / sqrt(max(-rd.y, 0.002));
        GSSurf s = gs_seaSurf(P.xz, fp);
        float var = s.var;
        float h0 = s.h;
        float3 n = s.n;
        float3 v = -rd;
        // at grazing angles the visible facets tilt toward the viewer
        float sig = sqrt(var);
        float3 toCam = normalize(float3(v.x, 0.0, v.z));
        float3 ne = normalize(n + toCam * sig * 0.8 * (1.0 - smoothstep(0.0, 0.3, dot(n, v))));
        float nv = max(dot(ne, v), 1e-3);
        float3 R = reflect(rd, ne);
        if (R.y < 0.0) R.y = -R.y * 0.6;
        R = normalize(R);
        float F = gs_fresnel(nv);
        float3 skyR = gs_skyRad(R, sd);
        float cd;
        float4 cl = gs_clouds(R, sd, sunEc, ambTop, ambBot, 12, 3, 1, jit, cd);
        float hzR = 1.0 - exp(-cd / 55000.0);
        float3 reflCol = mix(cl.rgb + cl.a * skyR, skyR, hzR);
        // sun specular (GGX with unresolved slope variance)
        float a2 = clamp(var, 0.0008, 0.5);
        float3 hv = normalize(sd + v);
        float nl = max(dot(n, sd), 0.0);
        float nh = max(dot(n, hv), 0.0);
        float nvs = max(dot(n, v), 1e-3);
        float D = gs_ggx(nh, a2);
        float Fs = gs_fresnel(max(dot(hv, v), 0.0));
        float k2 = a2 * 0.5;
        float G = (nl / (nl * (1.0 - k2) + k2)) * (nvs / (nvs * (1.0 - k2) + k2));
        float3 spec = sunE0 * D * Fs * G / (4.0 * nvs + 1e-3);
        // water body (upwelling light) + light transmitted through backlit crests
        float3 Ed = sunE0 * sd.y + skyZen * 3.0;
        float3 deep = float3(0.0015, 0.0055, 0.0075) * Ed * 3.0;
        float3 rdH = normalize(float3(rd.x, 0.0, rd.z));
        float back = pow(clamp(dot(rdH, sdH), 0.0, 1.0), 2.0);
        float crest = smoothstep(-0.15, 0.45, h0);
        float face = smoothstep(0.03, 0.25, dot(n, -sdH));                // face tilted toward the camera, away from the sun
        float3 trans = float3(0.08, 0.85, 0.70);                          // water absorption on the sun's path
        float3 sss = trans * sunE0 * 0.03 * back * crest * face * smoothstep(160.0, 15.0, tHit);
        float3 body = (deep + sss) * (1.0 - F);
        col = reflCol * F + spec + body;
        // foam: compressed Gerstner crests + faint wind-aligned streaks
        {
            float2 wdir = float2(sin(GS_WIND), cos(GS_WIND));
            float2 fq = float2(dot(P.xz, wdir), dot(P.xz, float2(-wdir.y, wdir.x)));
            float streak = fbm(float2(fq.x * 0.06, fq.y * 0.55) + float2(3.1, 8.4), 5) * 0.5 + 0.5;
            float speck = fbm(P.xz * 1.7 + 11.0, 3) * 0.5 + 0.5;
            float cap = smoothstep(0.45, 0.05, s.jac) * (0.5 + speck);
            float lace = smoothstep(0.66, 0.86, streak) * smoothstep(0.35, 0.75, speck) * 0.35;
            float foam = clamp(cap + lace, 0.0, 1.0) * smoothstep(900.0, 150.0, tHit);
            foam *= 0.55;
            float3 foamE = sunE0 * clamp(dot(n, sd) * 0.8 + 0.2, 0.0, 1.0) + skyZen * 3.0 + skyHz * 0.15;
            float3 foamCol = foamE * (0.75 / PI);
            col = mix(col, foamCol, foam);
        }
        if (GS_DBG == 1) return n * 0.5 + 0.5;
        if (GS_DBG == 2) return ws_acesFitted(spec * GS_EXPO);
        if (GS_DBG == 3) return ws_acesFitted(reflCol * F * GS_EXPO);
        if (GS_DBG == 4) return float3(sig * 3.0, F, 0.0);
        // aerial perspective over the sea
        float3 hazeCol = gs_skyRad(normalize(float3(rd.x, 0.002, rd.z)), sd);
        float haze = 1.0 - exp(-tHit / 24000.0);
        col = mix(col, hazeCol, haze);
    } else {
        // ---------------------------------------------------- sky
        float3 sky = gs_skyRad(rd, sd);
        float3 sun = ws_sunDisk(rd, sd, 0.27, sunE0 * 1.5e4);
        float cd;
        float4 cl = gs_clouds(rd, sd, sunEc, ambTop, ambBot, 36, 6, 0, jit, cd);
        float3 Tair;
        float3 air = min(gs_airlight(rd, sd, max(cd, 1.0), Tair), sky) * 0.55;
        Tair = mix(float3(1.0), Tair, 0.55);
        col = air + Tair * cl.rgb + cl.a * (max(sky - air, 0.0) + sun);
        if (GS_DBG == 3) col = sky;
    }

    // camera veiling glare around the sun (lens PSF), scaled by sun visibility
    {
        float ang = acos(clamp(dot(rd, sd), -1.0, 1.0));
        float3 glare = sunE0 * (1.2 * exp(-ang / 0.005) + 0.12 * exp(-ang / 0.025) + 0.02 * exp(-ang / 0.12));
        col += glare;
    }
    col *= GS_EXPO;
    col = ws_acesFitted(col);
    // gentle photographic split-tone: cool shadows, warm highlights
    float lum = ws_luma(col);
    col += float3(-0.010, 0.000, 0.018) * (1.0 - smoothstep(0.0, 0.35, lum)) * smoothstep(0.0, 0.05, lum);
    col *= mix(float3(1.0), float3(1.02, 1.0, 0.97), smoothstep(0.3, 0.9, lum));
    return clamp(col, 0.0, 1.0);
}
