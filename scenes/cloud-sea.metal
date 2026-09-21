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
constant float CS_MAXT  = 3.02;     // upper bound of cloud tops (incl. detail)
constant float CS_SIG   = 60.0;     // extinction in cloud core (1/km)
constant float CS_PITCH = -5.0;     // camera pitch (deg)
constant float CS_VFOV  = 38.0;
constant float CS_SUNEL = 3.0;      // sun elevation (deg)
constant float CS_SUNAZ = 16.0;     // sun azimuth, deg right of view axis
constant float CS_MIE   = 0.8;
constant float CS_EXPO  = 0.42;
constant float CS_BASE  = 1.5;      // terrain base altitude (hidden under deck)
constant float CS_HAZE  = 0.08;     // haze extinction at deck top (1/km)
constant float CS_HAZEH = 0.18;     // haze scale height (km)

// massifs: (x, z, summit altitude, radius) and (orientation, aspect, seed, crest freq)
constant float4 CS_PK[4] = {
    float4(-3.6,  -9.0, 4.00, 2.6),
    float4( 5.6, -17.0, 3.95, 3.2),
    float4(-12.5, -34.0, 3.65, 4.4),
    float4( 16.0, -40.0, 3.60, 4.0)
};
constant float4 CS_PK2[4] = {
    float4( 0.55, 0.50, 1.0, 0.55),
    float4(-0.40, 0.55, 2.0, 0.45),
    float4( 0.25, 0.45, 3.0, 0.40),
    float4( 0.9, 0.5, 4.0, 0.42)
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
inline float3 cs_sky(float3 rd, float3 sunDir, float3 sunHi, float altM) {
    float3 a = ws_atmosphere(rd, sunDir, 22.0, 0.76, CS_MIE, altM);
    float3 b = ws_atmosphereFast(rd, sunHi, 22.0, 0.76, altM);
    return a + 0.6 * b;
}

inline float cs_billow(float2 p) { return 1.0 - abs(gnoise(p)); }

// ------------------------------------------------------------ cloud deck
// LOD fade for a feature of wavelength lam (km) at pixel footprint fp (km)
inline float cs_lod(float lam, float fp) { return saturate(lam / max(fp, 1e-5) * 0.35 - 0.6); }

// Top surface altitude of the deck.
inline float cs_top(float2 xz, float fp) {
    float2 q = xz;
    float h = CS_TOP;
    // macro swells and broad valleys
    h += 0.14 * fbm(q * 0.038 + float2(3.1, 7.7), 3);
    float vall = smoothstep(0.15, 0.65, gnoise(q * 0.055 + float2(17.3, 4.1)));
    h -= 0.22 * vall;
    // convection mask: patches of vigorous cumulus vs flatter stratus
    float conv = smoothstep(-0.45, 0.5, gnoise(q * 0.085 + float2(9.2, 1.4)));
    // warped domain for the cells
    float2 w = 0.7 * float2(gnoise(q * 0.23 + 1.7), gnoise(q * 0.23 + float2(8.3, 2.9)));
    float2 qw = q + w;
    // cauliflower domes (Worley cells, hemispherical profile)
    float l1 = cs_lod(1.5, fp);
    if (l1 > 0.0) {
        float2 c1 = worley(qw * 0.68 + 2.3);
        float d1 = sqrt(saturate(1.0 - c1.x * c1.x * 1.05));
        h += (0.09 + 0.20 * conv) * d1 * l1;
    } else {
        h += (0.09 + 0.20 * conv) * 0.55;
    }
    float l2 = cs_lod(0.6, fp);
    if (l2 > 0.0) {
        float2 c2 = worley(qw * 1.75 + 5.1);
        float d2 = sqrt(saturate(1.0 - c2.x * c2.x * 1.1));
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
    return h;
}

// smooth large-scale top (for valley occlusion and the haze layer)
inline float cs_topSmooth(float2 xz) {
    float h = CS_TOP + 0.14 * fbm(xz * 0.038 + float2(3.1, 7.7), 3);
    float vall = smoothstep(0.15, 0.65, gnoise(xz * 0.055 + float2(17.3, 4.1)));
    float conv = smoothstep(-0.45, 0.5, gnoise(xz * 0.085 + float2(9.2, 1.4)));
    h -= 0.22 * vall;
    h += (0.09 + 0.20 * conv) * 0.6 + (0.04 + 0.08 * conv) * 0.5;
    return h;
}

// 3D billow erosion in ~[-1,1]
inline float cs_detail(float3 p, float fp) {
    float3 q = p * 8.0;
    float n = 0.0, a = 0.5, nrm = 0.0, freq = 8.0;
    for (int i = 0; i < 4; i++) {
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
    for (int i = 0; i < 4; i++) {
        float4 P = CS_PK[i];
        float4 Q = CS_PK2[i];
        float2 d = xz - P.xy;
        float R = P.w;
        if (dot(d, d) > R * R) continue;
        float fi = Q.z;
        float ca = cos(Q.x), sa = sin(Q.x);
        float2 e = float2(ca * d.x + sa * d.y, -sa * d.x + ca * d.y) / float2(R, R * Q.y);
        // warp the massif outline
        float2 wv = 0.22 * float2(fbm(xz * 0.4 + fi * 11.0, 3), fbm(xz * 0.4 + fi * 5.0 + 7.0, 3));
        float ee = length(e + wv);
        float shape = pow(saturate(1.0 - ee), 1.45);
        // crest skeleton: ridged noise gives aretes and several summits
        float crest = ridged(xz * Q.w + fi * 3.7, oct);
        float relief = P.z - CS_BASE;
        float hgt = CS_BASE + relief * shape * (0.42 + 0.58 * crest);
        // secondary ridges / gullies
        float m = smoothstep(0.05, 0.5, shape);
        hgt += relief * m * 0.06 * (ridged(xz * 1.7 + fi * 9.1, max(oct - 2, 2)) - 0.5);
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
    for (int i = 0; i < 4; i++) {
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
    float t = max(pr.x, 0.01);
    for (int i = 0; i < 30; i++) {
        if (t > pr.y) break;
        float3 q = p + sd * t;
        if (q.y > 4.3) break;
        float h = cs_terrH(q.xz, oct);
        float d = q.y - h;
        res = min(res, saturate(d / (soft * t + 0.002)));
        if (res < 0.01) break;
        t += clamp(d * 0.7, 0.01, 0.4);
    }
    return res;
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
    float3 skyZen = ws_atmosphereFast(float3(0, 1, 0), sunDir, 22.0, 0.76, altM) + 0.6 * ws_atmosphereFast(float3(0, 1, 0), sunHi, 22.0, 0.76, altM);
    float3 skyS   = ws_atmosphereFast(normalize(float3(sunDir.x, 0.35, sunDir.z)), sunDir, 22.0, 0.76, altM) + 0.6 * ws_atmosphereFast(normalize(float3(sunDir.x, 0.35, sunDir.z)), sunHi, 22.0, 0.76, altM);
    float3 skyA   = ws_atmosphereFast(normalize(float3(-sunDir.x, 0.35, -sunDir.z)), sunDir, 22.0, 0.76, altM) + 0.6 * ws_atmosphereFast(normalize(float3(-sunDir.x, 0.35, -sunDir.z)), sunHi, 22.0, 0.76, altM);
    float3 skyAmb = PI * (0.45 * skyZen + 0.3 * skyS + 0.25 * skyA) * 1.1;

    // horizon sky in this azimuth (aerial-perspective in-scatter)
    float3 rdH = normalize(float3(rd.x, max(rd.y, 0.006), rd.z));
    float3 skyH = cs_sky(rdH, sunDir, sunHi, altM);

    float jit = hash12(fragCoord + float2(ctx.t * 17.0, 0.0));

    // ---------------- terrain
    float tTer = 1e9;
    float3 terCol = float3(0.0);
    float2 pr = cs_peakRange(ro, rd);
    if (pr.y > pr.x && rd.y < 0.12) {
        float t = pr.x;
        float tPrev = t;
        bool hit = false;
        for (int i = 0; i < 220; i++) {
            if (t > pr.y) break;
            float3 p = ro + rd * t;
            if (p.y < 2.0 - dot(p.xz, p.xz) * (0.5 / CS_RE)) break;   // under the deck: invisible
            float h = cs_terrH(p.xz, 6);
            float d = p.y - h;
            if (d < 0.0) {
                float a = tPrev, b = t;
                for (int k = 0; k < 6; k++) {
                    float m = 0.5 * (a + b);
                    float3 q = ro + rd * m;
                    if (q.y - cs_terrH(q.xz, 6) < 0.0) b = m; else a = m;
                }
                t = 0.5 * (a + b);
                hit = true;
                break;
            }
            tPrev = t;
            t += max(d * 0.4, 0.0015 + t * pixAng * 0.6);
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
            float3 rock = mix(float3(0.060, 0.056, 0.052), float3(0.15, 0.13, 0.11),
                              saturate(0.45 + 0.6 * nz + 0.3 * strata));
            rock = mix(rock, float3(0.11, 0.09, 0.075), 0.3 * saturate(strata));
            float snowMask = smoothstep(0.55, 0.78, n.y + 0.2 * nz + 0.08 * (alt - 3.2));
            snowMask *= smoothstep(2.45, 2.75, alt);
            float3 alb = mix(rock, float3(0.80, 0.83, 0.88), snowMask);
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
            col += snowMask * sunEhi * sh * 0.05 * pow(max(dot(n, hv), 0.0), 24.0);
            // rock rim light (backlit edges)
            float rim = pow(saturate(1.0 + dot(n, rd)), 3.0);
            col += rock * sunEhi * sh * 0.06 * rim * saturate(dot(n, sunDir) + 0.4);
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
            for (int i = 0; i < 200; i++) {
                if (t > t1 || cloudT < 0.004) break;
                float3 p = ro + rd * t;
                float alt = cs_alt(p);
                float fp = t * pixAng;
                float top = cs_top(p.xz, fp);
                float h = top - alt;
                float stepIn = 0.005 + t * 0.004;
                if (h < -0.07) {
                    // empty air above the deck: big steps; integrate the haze layer analytically
                    float dt = max((-h - 0.06) * 0.9 / (abs(rd.y) + 0.8), 0.02 + t * 0.03);
                    dt = min(dt, t1 - t + 1e-3);
                    float topS = cs_topSmooth(p.xz);
                    float hz = CS_HAZE * exp(-max(alt - topS, 0.0) / CS_HAZEH);
                    float od = hz * dt;
                    if (od > 1e-4) {
                        float Th = exp(-od);
                        float3 S = sunE * hazePhase * 0.9 + skyAmb / PI * 0.35;
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
                float den = CS_SIG * smoothstep(0.0, 0.025 + fp * 0.5, dd);
                // haze inside the fine-step zone too
                float topS = cs_topSmooth(p.xz);
                float hz = CS_HAZE * exp(-max(alt - topS, 0.0) / CS_HAZEH);
                if (den > 0.02) {
                    if (terSh < 0.0) terSh = cs_terrShadow(p, sunDir, 4, 0.02);
                    // light march toward the sun
                    float od = 0.0;
                    float ls = 0.014, lt = 0.0;
                    for (int j = 0; j < 6; j++) {
                        float3 q = p + sunDir * (lt + ls * 0.5);
                        float qa = cs_alt(q);
                        float qt = cs_top(q.xz, max(fp, lt * 0.08));
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
                    float valley = saturate((topS - top) * 2.5);
                    float ao = exp(-max(dd, 0.0) * 5.0) * (1.0 - 0.6 * valley);
                    float3 La = skyAmb / PI * (0.3 + 0.7 * ao);
                    // faint warm bounce from neighbouring sunlit tops
                    La += sunE * 0.02 * terSh * (1.0 - 0.5 * valley);
                    float3 S = (Ls + La) * 0.99;
                    float Ts = exp(-den * dt);
                    float wgt = cloudT * (1.0 - Ts);
                    cloudL += cloudT * S * (1.0 - Ts);
                    tW += wgt * t; wSum += wgt;
                    cloudT *= Ts;
                } else if (hz > 1e-3) {
                    float Th = exp(-hz * dt);
                    float3 S = sunE * hazePhase * 0.9 + skyAmb / PI * 0.35;
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
    float3 sun = ws_sunDisk(rd, sunDir, 0.27, sunEhi * 6000.0);
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
    col += sunEhi * (0.45 * exp(-ang * 90.0) + 0.08 * exp(-ang * 22.0) + 0.016 * exp(-ang * 5.0));

    col *= CS_EXPO;
    col = ws_acesFitted(col);
    col += 0.004 * ws_grain(fragCoord, ctx.t);
    return saturate(col);
}
