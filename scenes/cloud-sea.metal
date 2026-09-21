// =====================================================================
//  Cloud Sea — sunrise above an undercast, seen from a high summit.
//
//  Units: km. Camera at origin looking down -z, +x right, y = altitude.
//  Earth curvature is folded into "altitude" cs_alt(p) = y + r^2/(2Re).
//
//  Deck   : heightfield-bounded volumetric stratocumulus (Worley cauliflower
//           domes under a convection mask, broad swells + valleys, 3D billow
//           erosion), raymarched with adaptive steps. Sun: 6-tap light march,
//           4 multi-scatter octaves (Wrenninge), dual-lobe HG, powder.
//           Ambient: sky irradiance with depth/valley occlusion.
//  Haze   : thin sun-lit scattering layer lying on the deck (soft horizon,
//           luminous valleys, golden path toward the sun).
//  Peaks  : ridged alpine massifs (elongated, multi-summit), sphere-traced,
//           soft shadows, snow on ledges, sky/cloud-bounce ambient; they also
//           cast kilometre-long shadows across the deck.
//  Sky    : ws_atmosphere at summit altitude + weak "high sun" term standing
//           in for multiple scattering (powder-blue zenith), aerial
//           perspective (Rayleigh + Mie) on everything, sun glare.
// =====================================================================

constant float CS_DEG   = 0.017453292519943295;
constant float CS_RE    = 6371.0;   // earth radius (km)
constant float CS_CAMH  = 3.30;     // camera altitude (km)
constant float CS_TOP   = 2.30;     // deck base-top altitude (km) — domes rise above it
constant float CS_MAXT  = 3.28;     // upper bound of cloud tops (incl. detail)
constant float CS_SIG   = 60.0;     // extinction in cloud core (1/km)
constant float CS_PITCH = -5.0;     // camera pitch (deg)
constant float CS_VFOV  = 38.0;
constant float CS_SUNEL = 1.6;      // sun elevation (deg)
constant float CS_SUNAZ = 11.0;     // sun azimuth, deg right of view axis
constant float CS_MIE   = 0.55;
constant float CS_EXPO  = 0.475;
constant float CS_BASE  = 1.5;      // terrain base altitude (hidden under deck)
constant float CS_HAZE  = 0.08;     // haze extinction at deck top (1/km)
constant float CS_HAZEH = 0.18;     // haze scale height (km)

// massifs: (x, z, summit altitude, radius) and (orientation, aspect, seed, crest freq)
#define CS_NPK 5
constant float4 CS_PK[CS_NPK] = {
    float4( -2.6, -10.0, 4.58, 2.75),  // hero summit
    float4( -0.9, -12.6, 3.82, 2.25),  // shoulder summit on the ridge toward the sun
    float4( 11.5, -33.0, 4.02, 3.40),  // right mid-distance
    float4(-19.0, -50.0, 3.66, 3.80),  // far left whisper
    float4( 25.0, -64.0, 3.80, 4.60)   // far right whisper
};
constant float4 CS_PK2[CS_NPK] = {
    float4( 0.34, 0.54, 1.0, 0.62),
    float4( 0.90, 0.55, 5.0, 0.62),
    float4(-0.45, 0.52, 2.0, 0.40),
    float4( 0.30, 0.45, 3.0, 0.40),
    float4( 0.95, 0.50, 4.0, 0.36)
};

// ------------------------------------------------------------ helpers
inline float cs_alt(float3 p) { return p.y + dot(p.xz, p.xz) * (0.5 / CS_RE); }

inline float cs_hg(float mu, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5));
}

// sun transmittance through the atmosphere from altitude altKm along sd
inline float3 cs_sunTrans(float altKm, float3 sd) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kRlh = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kMie = 21e-6 * CS_MIE * 1.11;
    float3 r0 = float3(0.0, Rp + altKm * 1000.0, 0.0);
    float L = ws_raySphere(r0, sd, Ra).y;
    float st = L / 20.0;
    float odR = 0.0, odM = 0.0;
    for (int i = 0; i < 20; i++) {
        float3 q = r0 + sd * (st * (float(i) + 0.5));
        float h = length(q) - Rp;
        odR += exp(-h / 8e3) * st;
        odM += exp(-h / 1.2e3) * st;
    }
    return exp(-(kRlh * odR + kMie * odM));
}

// sky radiance with a weak "high sun" term standing in for multiple scattering
inline float3 cs_ozone(float3 rd) {
    float ch = 1.0 / (max(rd.y, 0.0) + 0.16);
    return exp(-float3(0.45, 1.00, 0.05) * 0.048 * ch);
}
inline float3 cs_sky(float3 rd, float3 sunDir, float3 sunHi, float altM) {
    float3 a = ws_atmosphere(rd, sunDir, 22.0, 0.76, CS_MIE, altM);
    float3 b = ws_atmosphereFast(rd, sunHi, 22.0, 0.76, altM);
    return (a + 0.46 * b) * cs_ozone(rd);
}

inline float cs_billow(float2 p) { return 1.0 - abs(gnoise(p)); }

// proximity to a massif in [0,1] — drives orographic lift, convection and mist
inline float cs_oro(float2 xz) {
    float m = 0.0;
    for (int i = 0; i < CS_NPK; i++) {
        float4 P = CS_PK[i];
        float2 d = xz - P.xy;
        float r = length(d) / (P.w * 1.35);
        if (r > 1.0) continue;
        float f = 1.0 - r;
        m = max(m, f * f * smoothstep(0.02, 0.45, f));
    }
    return m;
}

// ------------------------------------------------------------ cloud deck
// LOD fade for a feature of wavelength lam (km) at pixel footprint fp (km)
inline float cs_lod(float lam, float fp) { return saturate(lam / max(fp, 1e-5) * 0.35 - 0.6); }

// Top surface altitude of the deck.
inline float cs_top(float2 xz, float fp) {
    float2 q = xz;
    float h = CS_TOP;
    // macro swells and broad valleys
    h += 0.14 * fbm(q * 0.038 + float2(3.1, 7.7), 3);
    h += 0.17 * gnoise(q * 0.0155 + float2(41.0, 13.0));   // very broad swells
    float vall = smoothstep(0.15, 0.65, gnoise(q * 0.055 + float2(17.3, 4.1)));
    h -= 0.32 * vall;
    float om = cs_oro(q);
    h += 0.095 * om * (0.12 + 1.75 * gnoise(q * 0.80 + float2(21.0, 5.0)));
    // convection mask: patches of vigorous cumulus vs flatter stratus
    float conv = smoothstep(-0.45, 0.5, gnoise(q * 0.085 + float2(9.2, 1.4)));
    conv = saturate(conv + 0.55 * om);   // forced lift boils up against the massifs
    // warped domain for the cells
    float2 w = 0.7 * float2(gnoise(q * 0.23 + 1.7), gnoise(q * 0.23 + float2(8.3, 2.9)));
    float2 qw = q + w;
    // cauliflower domes (Worley cells, hemispherical profile)
    float l1 = cs_lod(1.5, fp);
    if (l1 > 0.0) {
        float2 c1 = worley(qw * 0.68 + 2.3);
        float f1 = c1.x - 0.085 * (1.0 - smoothstep(0.0, 0.17, c1.y - c1.x));
        float d1 = sqrt(saturate(1.0 - f1 * f1 * 1.05));
        h += (0.09 + 0.20 * conv) * d1 * l1;
    } else {
        h += (0.09 + 0.20 * conv) * 0.55;
    }
    float l2 = cs_lod(0.6, fp);
    if (l2 > 0.0) {
        float2 c2 = worley(qw * 1.75 + 5.1);
        float f2 = c2.x - 0.075 * (1.0 - smoothstep(0.0, 0.15, c2.y - c2.x));
        float d2 = sqrt(saturate(1.0 - f2 * f2 * 1.1));
        h += (0.04 + 0.08 * conv) * d2 * l2;
    } else {
        h += (0.04 + 0.08 * conv) * 0.5;
    }
    // billowy irregularity
    float l3 = cs_lod(0.9, fp);
    if (l3 > 0.0) h += 0.07 * (cs_billow(qw * 1.15 + 4.4) - 0.6) * l3;
    float l4 = cs_lod(0.27, fp);
    if (l4 > 0.0) h += 0.035 * (cs_billow(qw * 3.8 + 9.2) - 0.6) * l4;
    float l5 = cs_lod(0.11, fp);
    if (l5 > 0.0) h += 0.016 * (cs_billow(qw * 9.5 + 1.3) - 0.6) * l5;
    float l6 = cs_lod(0.045, fp);
    if (l6 > 0.0) h += 0.0072 * (cs_billow(qw * 23.0 + 6.7) - 0.6) * l6;
    float l7 = cs_lod(0.018, fp);
    if (l7 > 0.0) h += 0.0032 * (cs_billow(qw * 57.0 + 2.2) - 0.6) * l7;
    return h;
}

// smooth large-scale top (for valley occlusion and the haze layer)
inline float cs_topSmooth(float2 xz) {
    float h = CS_TOP + 0.14 * fbm(xz * 0.038 + float2(3.1, 7.7), 3);
    h += 0.17 * gnoise(xz * 0.0155 + float2(41.0, 13.0));
    float vall = smoothstep(0.15, 0.65, gnoise(xz * 0.055 + float2(17.3, 4.1)));
    float conv = smoothstep(-0.45, 0.5, gnoise(xz * 0.085 + float2(9.2, 1.4)));
    h -= 0.32 * vall;
    h += 0.062 * cs_oro(xz);
    h += (0.09 + 0.20 * conv) * 0.6 + (0.04 + 0.08 * conv) * 0.5;
    return h;
}

// 3D billow erosion in ~[-1,1]
inline float cs_detail(float3 p, float fp) {
    float3 q = p * 8.0;
    float n = 0.0, a = 0.5, nrm = 0.0, freq = 8.0;
    for (int i = 0; i < 5; i++) {
        float fade = cs_lod(1.0 / freq, fp);
        if (fade <= 0.0) break;
        n += a * fade * (1.0 - 2.0 * abs(gnoise(q)));
        nrm += a;
        q = WS_ROT3 * q * 2.15 + float3(3.3, 1.7, 5.1);
        freq *= 2.15;
        a *= 0.5;
    }
    return nrm > 0.0 ? n / nrm : 0.0;
}

// ------------------------------------------------------------ terrain
inline float cs_smax(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (a - b) / k);
    return mix(b, a, h) + k * h * (1.0 - h);
}

inline float cs_peakAlt(float2 xz, int oct) {
    float best = CS_BASE;
    for (int i = 0; i < CS_NPK; i++) {
        float4 P = CS_PK[i];
        float4 Q = CS_PK2[i];
        float2 d = xz - P.xy;
        float R = P.w;
        if (dot(d, d) > R * R) continue;
        float fi = Q.z;
        float ca = cos(Q.x), sa = sin(Q.x);
        float2 e = float2(ca * d.x + sa * d.y, -sa * d.x + ca * d.y) / float2(R, R * Q.y);
        // warp the massif outline
        float2 wv = 0.30 * float2(fbm(xz * 0.34 + fi * 11.0, 4), fbm(xz * 0.34 + fi * 5.0 + 7.0, 4));
        float2 es = e + wv;
        es.x *= mix(1.20, 0.74, smoothstep(-0.30, 0.30, es.x));
        float ee = length(es);
        float shape = pow(saturate(1.0 - ee), 1.15);
        // crest skeleton: ridged noise gives aretes and several summits
        float crest = ridged(xz * Q.w + fi * 3.7, oct);
        float relief = P.z - CS_BASE;
        float spine = exp(-2.6 * pow(abs(e.y * 1.7 + 0.42 * sin(e.x * 2.3 + fi)), 1.4));
        float hgt = CS_BASE + relief * shape * (0.46 + 0.42 * crest + 0.16 * spine);
        // secondary ridges / gullies
        float m = smoothstep(0.05, 0.5, shape);
        hgt += relief * m * 0.06 * (ridged(xz * 1.7 + fi * 9.1, max(oct - 2, 2)) - 0.5);
        if (oct >= 6) hgt += relief * m * 0.022 * (ridged(xz * 6.3 + fi * 3.0, 2) - 0.5);
        best = cs_smax(best, hgt, 0.05);
    }
    return best;
}

inline float cs_terrH(float2 xz, int oct) {
    return cs_peakAlt(xz, oct) - dot(xz, xz) * (0.5 / CS_RE);   // flat-world y
}

inline float3 cs_terrN(float2 xz, float e, int oct) {
    float hx = cs_terrH(xz + float2(e, 0), oct) - cs_terrH(xz - float2(e, 0), oct);
    float hz = cs_terrH(xz + float2(0, e), oct) - cs_terrH(xz - float2(0, e), oct);
    return normalize(float3(-hx, 2.0 * e, -hz));
}

// ray vs union of massif bounding cylinders -> [t0, t1]; t1 < t0 = miss
inline float2 cs_peakRange(float3 ro, float3 rd) {
    float t0 = 1e9, t1 = -1e9;
    for (int i = 0; i < CS_NPK; i++) {
        float4 P = CS_PK[i];
        float2 oc = ro.xz - P.xy;
        float a = dot(rd.xz, rd.xz);
        float b = dot(oc, rd.xz);
        float R = P.w * 1.05;
        float c = dot(oc, oc) - R * R;
        float disc = b * b - a * c;
        if (disc <= 0.0) continue;
        float s = sqrt(disc);
        float ta = (-b - s) / a, tb = (-b + s) / a;
        if (tb < 0.0) continue;
        t0 = min(t0, max(ta, 0.0));
        t1 = max(t1, tb);
    }
    return float2(t0, t1);
}

// soft shadow toward the sun from a point (terrain occluders only)
inline float cs_terrShadow(float3 p, float3 sd, int oct, float soft) {
    float2 pr = cs_peakRange(p, sd);
    if (pr.y < pr.x) return 1.0;
    float res = 1.0;
    float tHit = 0.0;
    float t = max(pr.x, 0.01);
    for (int i = 0; i < 30; i++) {
        if (t > pr.y) break;
        float3 q = p + sd * t;
        if (q.y > 4.4) break;
        float h = cs_terrH(q.xz, oct);
        float d = q.y - h;
        float r = saturate(d / (soft * t + 0.002));
        if (r < res) { res = r; tHit = t; }
        if (res < 0.01) break;
        t += clamp(d * 0.7, 0.01, 0.4);
    }
    // scattered light fills long shadows in: they fade over tens of km
    return mix(1.0, res, exp(-tHit * 0.080));
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float3 ro = float3(0.0, CS_CAMH, 0.0);
    float pitch = CS_PITCH * CS_DEG;
    float3 fwd = float3(0.0, sin(pitch), -cos(pitch));
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ro + fwd, CS_VFOV);
    float pixAng = 2.0 * tan(CS_VFOV * 0.5 * CS_DEG) / ctx.res.y;

    float se = CS_SUNEL * CS_DEG, sa = CS_SUNAZ * CS_DEG;
    float3 sunDir = normalize(float3(sin(sa) * cos(se), sin(se), -cos(sa) * cos(se)));
    float seH = (CS_SUNEL + 15.0) * CS_DEG;
    float3 sunHi = normalize(float3(sin(sa) * cos(seH), sin(seH), -cos(sa) * cos(seH)));
    float mu = dot(rd, sunDir);

    float altM = CS_CAMH * 1000.0;
    float3 sunE   = 22.0 * cs_sunTrans(CS_TOP + 0.35, sunDir);   // at deck level
    float3 sunEhi = 22.0 * cs_sunTrans(3.6, sunDir);             // at the summits
    // ambient sky irradiance (hemisphere approx.)
    float3 dZ = float3(0, 1, 0);
    float3 dS = normalize(float3(sunDir.x, 0.35, sunDir.z));
    float3 dA = normalize(float3(-sunDir.x, 0.35, -sunDir.z));
    float3 skyZen = (ws_atmosphereFast(dZ, sunDir, 22.0, 0.76, altM) + 0.46 * ws_atmosphereFast(dZ, sunHi, 22.0, 0.76, altM)) * cs_ozone(dZ);
    float3 skyS   = (ws_atmosphereFast(dS, sunDir, 22.0, 0.76, altM) + 0.46 * ws_atmosphereFast(dS, sunHi, 22.0, 0.76, altM)) * cs_ozone(dS);
    float3 skyA   = (ws_atmosphereFast(dA, sunDir, 22.0, 0.76, altM) + 0.46 * ws_atmosphereFast(dA, sunHi, 22.0, 0.76, altM)) * cs_ozone(dA);
    float3 skyAmb = PI * (0.62 * skyZen + 0.14 * skyS + 0.24 * skyA) * 1.85;

    // horizon sky in this azimuth (aerial-perspective in-scatter)
    float3 rdH = normalize(float3(rd.x, max(rd.y, 0.006), rd.z));
    float3 skyH = cs_sky(rdH, sunDir, sunHi, altM);

    float jit = hash12(fragCoord + float2(ctx.t * 17.0, 0.0));

    // ---------------- terrain
    float tTer = 1e9;
    float3 terCol = float3(0.0);
    float2 pr = cs_peakRange(ro, rd);
    if (pr.y > pr.x && rd.y < 0.22) {
        float t = pr.x;
        float tPrev = t;
        bool hit = false;
        for (int i = 0; i < 260; i++) {
            if (t > pr.y) break;
            float3 p = ro + rd * t;
            if (p.y < 2.0 - dot(p.xz, p.xz) * (0.5 / CS_RE)) break;   // under the deck: invisible
            float h = cs_terrH(p.xz, 6);
            float d = p.y - h;
            if (d < 0.0) {
                float a = tPrev, b = t;
                for (int k = 0; k < 9; k++) {
                    float m = 0.5 * (a + b);
                    float3 q = ro + rd * m;
                    if (q.y - cs_terrH(q.xz, 6) < 0.0) b = m; else a = m;
                }
                t = 0.5 * (a + b);
                hit = true;
                break;
            }
            tPrev = t;
            t += max(d * 0.28, 0.0010 + t * pixAng * 0.45);
        }
        if (hit) {
            tTer = t;
            float3 p = ro + rd * t;
            float e = max(0.002, t * pixAng * 1.2);
            float3 n = cs_terrN(p.xz, e, 9);
            float alt = cs_alt(p);
            // materials
            float nz = fbm(p.xz * 5.0, 4);
            float strata = gnoise(float2(alt * 30.0 + nz * 2.5, p.x * 0.4 + p.z * 0.2));
            float3 rock = mix(float3(0.075, 0.070, 0.066), float3(0.19, 0.165, 0.140),
                              saturate(0.45 + 0.6 * nz + 0.3 * strata));
            rock = mix(rock, float3(0.11, 0.09, 0.075), 0.3 * saturate(strata));
            float snowMask = smoothstep(0.42, 0.72, n.y + 0.22 * nz + 0.30 * (alt - 3.3));
            snowMask *= smoothstep(2.55, 3.05, alt);
            float3 alb = mix(rock, float3(0.82, 0.85, 0.90), snowMask);
            float sh = cs_terrShadow(p + n * 0.004, sunDir, 5, 0.03);
            float dif = max(dot(n, sunDir), 0.0);
            // ambient: sky from above, bright sunlit deck from below
            float3 deckUp = (sunE * 0.06 + skyAmb / PI * 0.45);
            float occ = 0.5 + 0.5 * saturate(0.55 + 0.7 * nz);
            float up = 0.5 + 0.5 * n.y;
            float3 amb = skyAmb / PI * up * up + deckUp * (1.0 - up) * (1.0 + 1.5 * saturate((3.0 - alt) * 2.0));
            float3 col = alb * (sunEhi * dif * sh / PI + amb * occ);
            // snow sheen / sun glint toward the sun
            float3 hv = normalize(sunDir - rd);
            col += snowMask * sunEhi * sh * 0.06 * pow(max(dot(n, hv), 0.0), 20.0);
            // backlit rim: grazing sun catches the ridge edges
            float rim = pow(saturate(1.0 + dot(n, rd)), 2.4);
            float graze = pow(saturate(dot(n, sunDir) + 0.55), 2.0);
            col += mix(rock, float3(0.34, 0.30, 0.27), 0.65) * sunEhi * sh * 0.30 * rim * graze;
            terCol = col;
        }
    }

    // ---------------- clouds + haze
    float3 cloudL = float3(0.0);
    float cloudT = 1.0;
    float tW = 0.0, wSum = 0.0;
    bool cloudRay = false;
    float phaseMS[4];
    for (int o = 0; o < 4; o++) {
        float g = 0.78 * pow(0.5, float(o));
        phaseMS[o] = mix(cs_hg(mu, g), cs_hg(mu, -0.2 * pow(0.5, float(o))), 0.3);
    }
    float hazePhase = 0.55 * cs_hg(mu, 0.66) + 0.45 * cs_hg(mu, 0.1);
    {
        float k = (1.0 - rd.y * rd.y) * (0.5 / CS_RE);
        float c = ro.y - CS_MAXT;
        float disc = rd.y * rd.y - 4.0 * k * c;
        if (rd.y < 0.0 && disc > 0.0) {
            cloudRay = true;
            float sq = sqrt(disc);
            float t0 = (2.0 * c) / (-rd.y + sq);
            float t1 = min((-rd.y + sq) / (2.0 * k), 260.0);
            t1 = min(t1, tTer);
            float t = t0;
            float terSh = -1.0;
            bool first = true;
            for (int i = 0; i < 250; i++) {
                if (t > t1 || cloudT < 0.004) break;
                float3 p = ro + rd * t;
                float alt = cs_alt(p);
                float fp = t * pixAng;
                float top = cs_top(p.xz, fp);
                float h = top - alt;
                float stepIn = 0.005 + t * 0.004;
                if (h < -0.07) {
                    // empty air above the deck: big steps; integrate the haze layer analytically
                    float dt = max((-h - 0.06) * 0.9 / (abs(rd.y) + 1.25), 0.02 + t * 0.017);
                    dt = min(dt, t1 - t + 1e-3);
                    float topS = cs_topSmooth(p.xz);
                    float oroP = cs_oro(p.xz);
                    float mistM = oroP * oroP * oroP * max(0.0, 0.30 + 1.40 * gnoise(p.xz * 0.75 + 13.0));
                    float hz = CS_HAZE * (1.0 + 2.4 * mistM) * exp(-max(alt - topS, 0.0) / (CS_HAZEH * (1.0 + 0.9 * mistM)));
                    float od = hz * dt;
                    if (od > 1e-4) {
                        if (terSh < 0.0 && hz > 0.004) terSh = cs_terrShadow(p, sunDir, 4, 0.055);
                        float sh = max(terSh, 0.0);
                        float Th = exp(-od);
                        float3 S = sunE * hazePhase * 0.9 * mix(1.0, (terSh < 0.0 ? 1.0 : sh), saturate(1.0 - t / 26.0)) + skyAmb / PI * 0.35;
                        cloudL += cloudT * S * (1.0 - Th);
                        tW += cloudT * (1.0 - Th) * (t + 0.5 * dt); wSum += cloudT * (1.0 - Th);
                        cloudT *= Th;
                    }
                    t += dt;
                    continue;
                }
                float dt = stepIn;
                if (first) { first = false; t += dt * jit; p = ro + rd * t; alt = cs_alt(p); h = top - alt; }
                float det = cs_detail(p, fp);
                float dd = h + 0.035 * det;
                float oroP = cs_oro(p.xz);
                float den = CS_SIG * smoothstep(0.0, 0.025 + fp * 0.5 + 0.022 * oroP, dd);
                // haze inside the fine-step zone too
                float topS = cs_topSmooth(p.xz);
                float mistM = oroP * oroP * oroP * max(0.0, 0.30 + 1.40 * gnoise(p.xz * 0.75 + 13.0));
                float hz = CS_HAZE * (1.0 + 2.4 * mistM) * exp(-max(alt - topS, 0.0) / (CS_HAZEH * (1.0 + 0.9 * mistM)));
                if (den > 0.02) {
                    if (terSh < 0.0) terSh = cs_terrShadow(p, sunDir, 4, 0.055);
                    // light march toward the sun
                    float od = 0.0;
                    float ls = 0.014, lt = 0.0;
                    for (int j = 0; j < 6; j++) {
                        float3 q = p + sunDir * (lt + ls * 0.5);
                        float qa = cs_alt(q);
                        float qt = cs_top(q.xz, max(fp, max(0.013, lt * 0.08)));
                        float qh = qt - qa;
                        if (j < 2) qh += 0.035 * cs_detail(q, fp * 2.0);
                        od += CS_SIG * smoothstep(0.0, 0.025, qh) * ls;
                        lt += ls;
                        ls *= 2.2;
                    }
                    float3 Ls = float3(0.0);
                    float aa = 1.0, bb = 1.0;
                    for (int o = 0; o < 4; o++) {
                        Ls += bb * phaseMS[o] * exp(-od * aa);
                        aa *= 0.5; bb *= 0.5;
                    }
                    float powder = 1.0 - 0.6 * exp(-max(dd, 0.0) * 35.0);
                    Ls *= sunE * terSh * mix(1.0, powder, 0.7);
                    // ambient: sky from above, occluded with depth / in valleys
                    float valley = saturate((topS - top) * 3.0);
                    float ao = exp(-max(dd, 0.0) * 8.0) * (1.0 - 0.80 * valley);
                    float3 ambCol = mix(skyZen * 1.30, skyAmb / PI, ao * ao);
                    float3 La = ambCol * (0.32 + 0.68 * ao);
                    // faint warm bounce from neighbouring sunlit tops
                    La += sunE * 0.016 * mix(0.40, 1.0, terSh) * (1.0 - 0.55 * valley);
                    float3 S = (Ls + La) * 0.99;
                    float Ts = exp(-den * dt);
                    float wgt = cloudT * (1.0 - Ts);
                    cloudL += cloudT * S * (1.0 - Ts);
                    tW += wgt * t; wSum += wgt;
                    cloudT *= Ts;
                } else if (hz > 1e-3) {
                    if (terSh < 0.0) terSh = cs_terrShadow(p, sunDir, 4, 0.055);
                    float Th = exp(-hz * dt);
                    float3 S = sunE * hazePhase * 0.9 * mix(1.0, max(terSh, 0.0), saturate(1.0 - t / 26.0)) + skyAmb / PI * 0.35;
                    cloudL += cloudT * S * (1.0 - Th);
                    tW += cloudT * (1.0 - Th) * t; wSum += cloudT * (1.0 - Th);
                    cloudT *= Th;
                }
                t += dt;
            }
        }
    }

    // ---------------- compose
    // aerial perspective (clear air at ~3 km)
    float3 betaR = float3(5.5e-3, 13.0e-3, 22.4e-3) * exp(-2.9 / 8.0);
    float betaM = 21e-3 * CS_MIE * 1.11 * exp(-2.9 / 1.2);
    float3 beta = betaR + betaM;

    float3 sky = cs_sky(rd, sunDir, sunHi, altM);
    float3 sun = ws_sunDisk(rd, sunDir, 0.30, sunEhi * 380.0);
    float3 bg = sky + sun;

    float3 col;
    if (tTer < 1e8) {
        float3 Tf = exp(-beta * tTer);
        bg = terCol * Tf + skyH * (1.0 - Tf);
    }
    if (cloudRay && wSum > 0.0) {
        float td = tW / wSum;
        float3 Tf = exp(-beta * td);
        float3 cl = cloudL * Tf + skyH * (1.0 - Tf) * (1.0 - cloudT);
        col = cl + bg * cloudT;
    } else {
        col = bg;
    }
    // veiling glare around the sun
    float ang = acos(clamp(mu, -1.0, 1.0));
    col += sunEhi * (1.70 * exp(-ang * 180.0) + 0.80 * exp(-ang * 72.0) + 0.090 * exp(-ang * 20.0) + 0.008 * exp(-ang * 6.5));

    col *= CS_EXPO;
    col *= ws_vignette(fragCoord / ctx.res, 0.22);
    col = ws_acesFitted(col);
    col = ws_saturate(col, 1.03);
    col += 0.004 * ws_grain(fragCoord, ctx.t);
    return saturate(col);
}
