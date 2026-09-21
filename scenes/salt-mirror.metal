// =====================================================================
//  Salt Mirror — a flooded salt flat at dusk (salar-style mirror).
//
//  Camera 1.55 m above a thin sheet of water, pitch 0 so the horizon
//  splits the frame and the sky mirrors below.  Looks down -z, +x right.
//  Ground / water are in metres, clouds & atmosphere in kilometres.
//
//  Sky   : ws_atmosphere (Rayleigh + Mie), sun 1.4 deg up, 54 deg left of view.
//  Clouds: volumetric cumulus field (2-D coverage, flat bases, domed tops,
//          3-D billow erosion), sun light-march + multi-scatter octaves,
//          sky / flat-bounce ambient, finite-segment aerial perspective.
//  Water : flat Fresnel mirror, faint anisotropic wind ripple in patches,
//          glossy micro-jitter (resolved by supersampling).
//  Crust : hex-lattice Voronoi ridges (2-4 cm) on a floor that sinks
//          slowly with distance, so ridges pierce the surface only in the
//          foreground and dissolve into the mirror further out.
// =====================================================================

constant float SM_RE    = 6371.0;   // km
constant float SM_CAMH  = 1.55;     // m
constant float SM_FOVY  = 40.0;
constant float SM_SUNEL = 1.4;      // deg
constant float SM_SUNAZ = -102.0;   // deg, negative = left of view (behind-left: front/side-lit clouds)
constant float SM_SUNI  = 22.0;
constant float SM_MIE   = 1.3;
constant float SM_EXPO  = 1.3;
constant float SM_CBASE = 1.25;     // km cloud base
constant float SM_CTHK  = 1.6;      // km max cloud thickness
constant float SM_TMAX  = 60.0;     // km cloud march limit
constant float SM_SIG   = 45.0;     // 1/km extinction in cloud core
constant float SM_CELL  = 1.15;     // m salt polygon size

inline float3 sm_sunDir() {
    float el = SM_SUNEL * (PI / 180.0), az = SM_SUNAZ * (PI / 180.0);
    return float3(sin(az) * cos(el), sin(el), -cos(az) * cos(el));
}
inline float sm_hg(float mu, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5));
}

// ------------------------------------------------------------ atmosphere
// Sunlight transmittance to altitude altKm (same constants as ws_atmosphere).
inline float3 sm_sunTrans(float altKm, float3 sd) {
    const float Rp = 6371e3, Ra = 6471e3;
    float3 p0 = float3(0.0, Rp + altKm * 1000.0 + 1.0, 0.0);
    float L = ws_raySphere(p0, sd, Ra).y;
    float odR = 0.0, odM = 0.0, tPrev = 0.0;
    for (int i = 0; i < 12; i++) {
        float u = float(i + 1) / 12.0;
        float t1 = L * u * u;
        float tm = 0.5 * (tPrev + t1);
        float h = length(p0 + sd * tm) - Rp;
        float dt = t1 - tPrev;
        odR += exp(-h / 8e3) * dt; odM += exp(-h / 1.2e3) * dt;
        tPrev = t1;
    }
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    return exp(-(kR * odR + 21e-6 * SM_MIE * 1.1 * odM));
}

// In-scattered light and transmittance along a view ray from the camera to distKm.
inline float3 sm_airlight(float3 rd, float3 sd, float distKm, thread float3& Tair) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kM = 21e-6 * SM_MIE;
    const int N = 8, NL = 4;
    float dist = distKm * 1000.0;
    float3 r0 = float3(0.0, Rp + 2.0, 0.0);
    float mu = dot(rd, sd), mumu = mu * mu, g = 0.76, gg = g * g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));
    float3 tR = float3(0.0), tM = float3(0.0);
    float odR = 0.0, odM = 0.0, tPrev = 0.0;
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
    return SM_SUNI * (pR * kR * tR + pM * kM * tM);
}

inline float3 sm_sky(float3 rd, float3 sd) {
    float3 d = rd;
    d.y = max(d.y, 0.0006);
    d = normalize(d);
    return ws_atmosphere(d, sd, SM_SUNI, 0.76, SM_MIE, 2.0);
}

// ------------------------------------------------------------ clouds
// 2-D coverage in [0,1] and local thickness (km) at horizontal position q (km).
// Cellular: each Voronoi cell is one cumulus tower; a broad fbm mask groups them
// into clusters with clear sky between; the zenith is kept clear.
inline float sm_cov(float2 q, thread float& thick) {
    float hd = length(q);
    float w = smoothstep(4.0, 11.0, hd);
    float m = fbm(q * 0.045 + float2(3.7, -1.9), 3);
    float mask = smoothstep(-0.28, 0.30, m);
    float2 W1 = worley(q * (1.0 / 2.3) + 4.1);
    float2 W2 = worley(q * (1.0 / 1.15) + 9.7);
    float b1 = pow(saturate(1.0 - W1.x / 0.95), 1.3);
    float b2 = pow(saturate(1.0 - W2.x / 0.80), 1.3);
    float n = mask * max(b1, 0.55 * b2);
    float2 fc = q - float2(-3.5, -15.0);              // focal tower, left of centre
    n += 0.55 * exp(-dot(fc, fc) / (2.0 * 1.6 * 1.6));
    n *= w;
    float c = saturate(n);
    thick = 0.15 + SM_CTHK * c;
    return c;
}

// density in [0,1] at world position p (km); lod 0 = cheap (light march)
inline float sm_dens(float3 p, int lod) {
    float thick;
    float c = sm_cov(p.xz, thick);
    if (c < 0.14) return 0.0;
    float alt = p.y + dot(p.xz, p.xz) * (0.5 / SM_RE);
    float hf = (alt - SM_CBASE) / thick;
    if (hf < 0.0 || hf > 1.0) return 0.0;
    float d = c - 0.12 - 0.88 * hf * hf;
    d *= smoothstep(0.0, 0.04, alt - SM_CBASE);
    if (d <= 0.0) return 0.0;
    // billowy erosion (abs-noise creases -> cauliflower)
    float3 pp = p * 2.6 + float3(0.0, 0.0, 5.0);
    float e = 0.55 * abs(gnoise(pp)) + 0.30 * abs(gnoise(pp * 2.1 + 1.3));
    if (lod > 0) e += 0.15 * abs(gnoise(pp * 4.3 + 2.7));
    d -= (0.10 + 0.55 * hf) * e * (lod > 0 ? 1.0 : 0.9);
    return saturate(d * 5.0);
}

// Volumetric march. Returns un-fogged cloud radiance; T = transmittance,
// tMean = contribution-weighted distance (km) for aerial perspective.
inline float3 sm_clouds(float3 rd, float3 sd, float3 sunC, float3 ambSky, float3 ambGnd,
                        float2 fragCoord, thread float& T, thread float& tMean) {
    T = 1.0; tMean = 0.0;
    float3 col = float3(0.0);
    if (rd.y < 0.019) return col;
    float t0 = SM_CBASE / rd.y;
    if (t0 > SM_TMAX) return col;
    float t1 = min((SM_CBASE + SM_CTHK + 0.25) / rd.y, SM_TMAX);
    float wsum = 0.0;
    float t = t0 + hash12(fragCoord * 1.7 + 3.3) * clamp(t0 * 0.012, 0.04, 0.5);
    float mu = dot(rd, sd);
    float ph0 = 0.7 * sm_hg(mu, 0.75) + 0.3 * sm_hg(mu, -0.2);
    float ph1 = 0.7 * sm_hg(mu, 0.50) + 0.3 * sm_hg(mu, -0.1);
    float ph2 = 0.7 * sm_hg(mu, 0.25) + 0.3 * sm_hg(mu,  0.0);
    for (int i = 0; i < 140; i++) {
        if (t > t1 || T < 0.01) break;
        float3 p = rd * t;
        float ds = clamp(t * 0.012, 0.04, 0.5);
        float thick;
        float c = sm_cov(p.xz, thick);
        float alt = p.y + dot(p.xz, p.xz) * (0.5 / SM_RE);
        if (c < 0.16 || alt < SM_CBASE - 0.02 || alt > SM_CBASE + thick) { t += ds * 2.5; continue; }
        float d = sm_dens(p, 1);
        if (d < 0.004) { t += ds * 1.2; continue; }
        float hf = saturate((alt - SM_CBASE) / thick);
        // light march toward the (nearly horizontal) sun
        float od = 0.0, ls = 0.06, lt = 0.03;
        for (int k = 0; k < 5; k++) { od += sm_dens(p + sd * lt, 0) * ls; lt += ls; ls *= 1.9; }
        od *= SM_SIG;
        float sunL = exp(-od) * ph0 + 0.5 * exp(-0.5 * od) * ph1 + 0.25 * exp(-0.25 * od) * ph2;
        float3 amb = ambSky * mix(0.12, 1.0, pow(hf, 1.5)) + ambGnd * mix(1.0, 0.12, sqrt(hf));
        amb *= 1.0 - 0.45 * d;
        float3 S = sunC * sunL * 0.75 + amb;
        float Ts = exp(-SM_SIG * d * ds);
        float wgt = T * (1.0 - Ts);
        col += wgt * S; wsum += wgt; tMean += wgt * t;
        T *= Ts;
        t += ds;
    }
    tMean = wsum > 0.0 ? tMean / wsum : t0;
    return col;
}

inline float3 sm_skyClouds(float3 rd, float3 sd, float3 sunC, float3 ambSky, float3 ambGnd, float2 fragCoord) {
    float3 sky = sm_sky(rd, sd);
    float T, tMean;
    float3 cl = sm_clouds(rd, sd, sunC, ambSky, ambGnd, fragCoord, T, tMean);
    if (T > 0.999) return sky;
    float3 Tair;
    float3 air = sm_airlight(rd, sd, tMean, Tair);
    return cl * Tair + air * (1.0 - T) + sky * T;
}

// ------------------------------------------------------------ salt crust
// Hex-lattice Voronoi: (F1, F2) in lattice units
inline float2 sm_hexVor(float2 q) {
    const float RH = 0.8660254;
    float2 g = float2(q.x, q.y / RH);
    float2 i = floor(g);
    float d1 = 9.0, d2 = 9.0;
    for (int dy = -1; dy <= 1; dy++)
    for (int dx = -1; dx <= 1; dx++) {
        float2 c = i + float2(dx, dy);
        float odd = fract(c.y * 0.5) * 2.0;           // 0 or 1
        float2 center = float2(c.x + 0.5 * odd + 0.5, (c.y + 0.5) * RH);
        center += (hash22(c) - 0.5) * 0.30;
        float d = length(q - center);
        if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
    }
    return float2(d1, d2);
}

// ridge height (m) at q (m); e = edge distance, hv = local ridge amplitude
inline float sm_crust(float2 q, thread float& e, thread float& hv) {
    float2 F = sm_hexVor(q / SM_CELL);
    e = abs(F.y - F.x + 0.035 * gnoise(q * 2.6));
    hv = 0.026 + 0.012 * gnoise(q * 0.45 + 7.0);
    float wdt = 0.045 + 0.02 * gnoise(q * 1.7 + 3.0);    // ridge width varies along the line
    float prof = exp(-e * e / (2.0 * wdt * wdt));
    // fine secondary cracks inside the polygons (thin, low)
    float2 F2 = worley(q * 3.3 + 11.0);
    float e2 = F2.y - F2.x;
    float fine = 0.0025 * exp(-e2 * e2 / (2.0 * 0.05 * 0.05));
    return hv * prof + fine + 0.0015 * gnoise(q * 7.0);
}
inline float sm_floor(float2 q) {
    float e, hv;
    float dist = length(q);
    return -(0.012 + 0.0012 * dist) + sm_crust(q, e, hv);
}

// water ripple height (m)
inline float sm_ripple(float2 q) {
    float2 s = float2(q.x * 1.0, q.y * 2.4);
    float patch = smoothstep(-0.2, 0.5, gnoise(q * 0.08 + 2.0));
    return patch * (0.0010 * gnoise(s * 4.0) + 0.0005 * gnoise(s * 9.3 + 5.0));
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
    float k = tan(SM_FOVY * 0.5 * PI / 180.0);
    float3 rd = normalize(float3(p.x * k, p.y * k, -1.0));
    float3 ro = float3(0.0, SM_CAMH, 0.0);
    float3 sd = sm_sunDir();

    // per-pixel lighting constants
    float3 sunG = SM_SUNI * sm_sunTrans(0.002, sd);
    float3 sunC = SM_SUNI * sm_sunTrans(1.9, sd);
    float3 skyZ = ws_atmosphereFast(float3(0.0, 1.0, 0.0), sd, SM_SUNI, 0.76, 2.0);
    float3 hs = normalize(float3(sd.x, 0.0, sd.z));
    float3 skyS = ws_atmosphereFast(normalize(hs * 0.98 + float3(0.0, 0.2, 0.0)), sd, SM_SUNI, 0.76, 2.0);
    float3 skyA = ws_atmosphereFast(normalize(-hs * 0.98 + float3(0.0, 0.2, 0.0)), sd, SM_SUNI, 0.76, 2.0);
    float3 skyH = 0.5 * (skyS + skyA);
    float3 Lavg = 0.45 * skyZ + 0.55 * skyH;      // mean sky radiance
    float3 ambSky = 0.5 * Lavg;
    float3 ambGnd = 0.5 * Lavg * 0.6;              // the flooded flat bounces ~60 % of the sky

    float3 col;
    if (rd.y >= 0.0) {
        col = sm_skyClouds(rd, sd, sunC, ambSky, ambGnd, fragCoord);
    } else {
        float tw = SM_CAMH / (-rd.y);              // water surface hit
        bool dry = false;
        float3 hp = float3(0.0);
        if (tw < 48.0) {
            float ta = (SM_CAMH - 0.05) / (-rd.y);
            float dt = (tw - ta) / 28.0;
            float tprev = ta;
            float t = ta + dt * hash12(fragCoord * 0.73 + 9.1);
            for (int i = 0; i < 28; i++) {
                float3 q = ro + rd * t;
                if (q.y < sm_floor(q.xz)) {
                    float a = tprev, b = t;
                    for (int j = 0; j < 4; j++) {
                        float m = 0.5 * (a + b);
                        float3 qm = ro + rd * m;
                        if (qm.y < sm_floor(qm.xz)) b = m; else a = m;
                    }
                    hp = ro + rd * 0.5 * (a + b);
                    dry = true;
                    break;
                }
                tprev = t; t += dt;
            }
        }
        if (dry) {
            // dry salt ridge above the water line
            float eps = 0.008;
            float2 q = hp.xz;
            float3 n = normalize(float3(sm_floor(q - float2(eps, 0.0)) - sm_floor(q + float2(eps, 0.0)), 2.0 * eps,
                                        sm_floor(q - float2(0.0, eps)) - sm_floor(q + float2(0.0, eps))));
            float3 alb = float3(0.88, 0.87, 0.84) * (0.93 + 0.07 * gnoise(q * 25.0));
            float up = 0.5 + 0.5 * n.y;
            float3 Ldiff = alb * (mix(Lavg * 0.6, mix(skyH, skyZ, saturate(n.y)), up));
            float vis = smoothstep(0.0, 0.025, hp.y) * 0.7;
            float3 Lsun = alb / PI * sunG * max(dot(n, sd), 0.0) * vis;
            col = Ldiff + Lsun;
        } else {
            float3 wp = ro + rd * tw;
            float2 q = wp.xz;
            // ripple normal (fades with distance) + glossy micro-jitter
            float eps = 0.012;
            float fade = smoothstep(120.0, 15.0, tw);
            float3 n = float3(0.0, 1.0, 0.0);
            if (fade > 0.0) {
                float hx = sm_ripple(q + float2(eps, 0.0)) - sm_ripple(q - float2(eps, 0.0));
                float hz = sm_ripple(q + float2(0.0, eps)) - sm_ripple(q - float2(0.0, eps));
                n = normalize(float3(-hx * fade, 2.0 * eps, -hz * fade));
            }
            float2 jit = (hash22(fragCoord * 3.1 + 17.0) - 0.5) * 0.004;
            n = normalize(n + float3(jit.x, 0.0, jit.y));
            float cosT = saturate(-dot(rd, n));
            float F = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
            float3 rr = reflect(rd, n);
            float3 refl = sm_skyClouds(rr, sd, sunC, ambSky, ambGnd, fragCoord);

            // bottom seen through the water
            float2 qb = q;
            if (tw < 48.0) {
                float3 rt = refract(rd, n, 1.0 / 1.333);
                float3 uq = wp;
                float dsu = 0.007 / max(-rt.y, 0.2);
                for (int i = 0; i < 10; i++) {
                    uq += rt * dsu;
                    if (uq.y < sm_floor(uq.xz)) break;
                }
                qb = uq.xz;
            }
            float e, hv;
            float r = sm_crust(qb, e, hv);
            float3 alb = mix(float3(0.62, 0.60, 0.56), float3(0.82, 0.81, 0.78), smoothstep(0.0, 0.7, r / hv));
            alb *= 0.92 + 0.08 * gnoise(qb * 2.3) + 0.04 * gnoise(qb * 11.0);
            float3 albAvg = float3(0.68, 0.66, 0.62);
            alb = mix(alb, albAvg, smoothstep(35.0, 80.0, tw));
            float3 Lbot = alb * Lavg * 0.93 * float3(0.97, 1.0, 0.99);
            col = F * refl + (1.0 - F) * Lbot;
        }
    }

    col *= SM_EXPO;
    col = ws_acesFitted(col);
    float2 uv = fragCoord / ctx.res;
    col *= ws_vignette(uv, 0.12);
    col += ws_grain(fragCoord, ctx.t) * 0.004;
    return clamp(col, 0.0, 1.0);
}
