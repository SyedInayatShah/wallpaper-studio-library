// =====================================================================
//  Hidden Peak — dynamic (time-of-day) alpine landscape.
//
//  An invented granite pyramid stands at the head of a glacial valley.
//  The camera looks due WEST from a grassy rock prow on the valley's
//  north side: a meandering river threads the forested floor and the sun
//  sets beside the peak.  Raymarched procedural heightfield lit by a
//  physically based sky (ws_atmosphereFast), with drifting altocumulus
//  that shadows the land, cirrus, early-morning valley mist, stars /
//  Milky Way / phased moon at night, and a shepherd's hut whose window
//  lights after dark.
//
//  Performance: the march uses a coarse LOD of the height field while
//  normals, texture and shading use a much finer one — the silhouette
//  loses a few metres of detail, nothing else does.
// =====================================================================

constant float DEG = 0.017453292519943295;

// ---------------------------------------------------------------- camera
constant float3 HP_RO   = float3(0.0, 0.0, -774.0);    // y is taken from the terrain
constant float  HP_FOV  = 31.0;
constant float  HP_TILT = -3.0;

// ---------------------------------------------------------------- landform
constant float2 HP_PK   = float2(-17500.0, 2800.0);
constant float  HP_PKH  = 2080.0;
constant float  HP_PKR  = 1900.0;
constant float2 HP_SAT  = float2(-13600.0, 4500.0);
constant float  HP_SATH = 820.0;
constant float  HP_SATR = 1250.0;
constant float2 HP_HUT  = float2(-2560.0, -230.0);
constant float  HP_TOP  = 5400.0;                      // above every summit

constant float HP_CUMY  = 4700.0;
constant float HP_CUMS  = 0.000140;
constant float HP_CUMC  = 0.44;

// ---------------------------------------------------------------- noise (LOD aware)
inline float hp_fbm(float2 p, float lod) {
    float a = 0.5, s = 0.0;
    float2 q = p;
    for (int i = 0; i < 7; i++) {
        float w = a * clamp(lod - float(i), 0.0, 1.0);
        if (w <= 0.0) break;
        s += w * gnoise(q);
        q = WS_ROT2 * q * 2.03;
        a *= 0.5;
    }
    return s;
}
inline float hp_rdg(float2 p, float lod) {
    float a = 0.5, s = 0.0;
    float2 q = p;
    for (int i = 0; i < 7; i++) {
        float w = a * clamp(lod - float(i), 0.0, 1.0);
        if (w <= 0.0) break;
        float n = 1.0 - abs(gnoise(q));
        s += w * (n * n - 0.56);
        q = WS_ROT2 * q * 2.07;
        a *= 0.52;
    }
    return s;
}
inline float hp_pw(float x, float k) { return x * (1.0 - k + k * x); }   // ≈ pow(x, 1+k), k<1

// ---------------------------------------------------------------- terrain
inline float hp_axis(float xw) {
    return 360.0 * sin(xw * 0.00034) + 205.0 * sin(xw * 0.00091 + 1.7)
         +  95.0 * sin(xw * 0.00230 + 4.1);
}
inline float hp_floorY(float xw) {
    return 1118.0 + 0.0392 * xw + 108.0 * sin(xw * 0.00021 + 0.6);
}
inline float hp_riverW(float xw) { return max(56.0 - 0.0013 * xw, 17.0); }

inline float hp_h(float2 w, float lod) {
    float xw = max(-w.x, 0.0);
    float fl = hp_floorY(xw);
    float u  = w.y - hp_axis(xw);
    float a  = abs(u);
    float sgn = smoothstep(-260.0, 260.0, u);          // 0 = north bench, 1 = south wall

    float vN = smoothstep(210.0, 2050.0, a);
    float vS = smoothstep(240.0, 3500.0, a);
    float north = 880.0 * hp_pw(vN, 0.10) + 430.0 * smoothstep(1900.0, 6000.0, a);
    float south = 1180.0 * hp_pw(vS, 0.16) + 330.0 * smoothstep(3200.0, 9500.0, a);
    float h = fl + mix(north, south, sgn);

    // rock-and-grass prow the camera stands on; falls away west and south
    float2 kd = float2((xw + 330.0) / 1500.0, (u + 700.0) / 1000.0);
    h += 800.0 * exp(-dot(kd, kd)) * smoothstep(70.0, 820.0, a);

    float rm  = smoothstep(110.0, 900.0, a);
    float rel = (0.20 + 0.92 * mix(vN * 0.58, vS, sgn)) * rm;
    float oR  = min(lod, 5.2);
    float oM  = clamp(lod - 0.6, 0.0, 4.6);
    float oF  = clamp(lod - 2.4, 0.0, 3.6);
    float oV  = clamp(lod - 4.5, 0.0, 2.4);
    h += (400.0 + 0.0205 * xw) * rel * hp_rdg(w * 0.00046 + float2(3.1, 7.7), oR);
    h += (300.0 + 0.017 * xw) * rel * hp_rdg(w * 0.00162 + float2(11.3, 2.9), oM);
    if (oF > 0.0) h += 26.0 * (0.14 + 0.95 * rm) * hp_fbm(w * 0.0082 + float2(5.5, 1.3), oF);
    if (oV > 0.0) h += 2.9 * hp_fbm(w * 0.068 + float2(2.2, 9.1), oV);

    float far = smoothstep(18000.0, 38000.0, xw);
    if (far > 0.002)
        h += far * (380.0 + 900.0 * (hp_rdg(w * 0.00021 + float2(19.0, 4.0), min(lod, 3.6)) + 0.34));

    // hero peak: steep three-arête pyramid
    float2 dp = w - HP_PK;
    float rp = length(dp);
    if (rp < HP_PKR * 1.7) {
        float an = atan2(dp.y, dp.x + 1e-4);
        float ar = 1.0 + 0.235 * cos(3.0 * an + 0.55) + 0.10 * cos(5.0 * an - 1.9)
                       + 0.05  * cos(7.0 * an + 2.4);
        float q  = clamp(1.0 - rp / (HP_PKR * ar), 0.0, 1.0);
        float pk = HP_PKH * hp_pw(q, 0.30);
        pk += HP_PKH * 0.10 * q * q * (0.5 + 0.5 * cos(3.0 * an + 0.55));
        pk *= 1.0 + 0.060 * hp_fbm(dp * 0.0028, min(lod, 5.2));
        h += pk;
    }
    float2 ds = w - HP_SAT;
    float rs = length(ds);
    if (rs < HP_SATR * 1.8) {
        float an = atan2(ds.y, ds.x + 1e-4);
        float R  = HP_SATR * (1.0 + 0.20 * cos(2.0 * an - 1.1) + 0.09 * cos(4.0 * an + 0.4));
        float q  = clamp(1.0 - rs / R, 0.0, 1.0);
        h += HP_SATH * hp_pw(q, 0.22) * (1.0 + 0.06 * hp_fbm(ds * 0.0033, min(lod, 4.0)));
    }

    float rw = hp_riverW(xw);
    h -= (34.0 + 0.0009 * xw) * smoothstep(rw * 2.8, rw * 0.2, a);
    return h;
}

inline float hp_waterY(float2 w) { return hp_floorY(max(-w.x, 0.0)) - 7.0; }
inline bool  hp_inRiver(float2 w) {
    float xw = max(-w.x, 0.0);
    return abs(w.y - hp_axis(xw)) < hp_riverW(xw) * 3.2;
}
inline float hp_lodM(float t)   { return clamp(4.7 - 0.32 * log2(max(t, 60.0) / 60.0), 3.0, 4.7); }
inline float hp_lodS(float t)   { return clamp(6.8 - 0.30 * log2(max(t, 60.0) / 60.0), 3.9, 6.6); }

// ---------------------------------------------------------------- shadow
inline float hp_shadow(float3 p, float3 L) {
    if (L.y <= 0.015) return 0.0;
    float res = 1.0, t = 34.0;
    for (int i = 0; i < 10; i++) {
        float3 q = p + L * t;
        if (q.y > HP_TOP) break;
        float d = q.y - hp_h(q.xz, 2.5);
        if (d < -4.0) return 0.0;
        res = min(res, 8.0 * d / t);
        t += clamp(d * 1.35, 75.0, 2600.0);
        if (t > 20000.0) break;
    }
    return clamp(res, 0.0, 1.0);
}

// ---------------------------------------------------------------- light rig
struct HPLight { float3 sunCol, skyCol, moonCol; float dayW, expo, el; };

inline HPLight hp_light(WSCtx ctx) {
    HPLight L;
    float el = ctx.sunElevation;
    L.el = el;
    float s  = sin(max(el, -6.0) * DEG);
    float am = min(1.0 / max(s + 0.15 * pow(max(el + 3.885, 0.12), -1.253), 0.018), 42.0);
    float3 tau = float3(0.031, 0.095, 0.214) + 0.052;
    L.sunCol = 4.9 * exp(-tau * (am - 1.0)) * smoothstep(-2.4, 0.7, el);
    float3 zen = ws_atmosphereFast(float3(0.0, 1.0, 0.0), ctx.sunDir, 22.0);
    float lowW = 1.0 - smoothstep(-3.0, 14.0, el);
    L.skyCol = zen * mix(1.0, 1.55, lowW) * mix(float3(1.0), float3(1.20, 0.90, 0.72), 0.55 * lowW) * 0.62;
    float mi = clamp(ctx.moonIllum, 0.0, 1.0);
    L.moonCol = float3(0.58, 0.70, 1.0) * (0.042 * mi * mi * smoothstep(-0.02, 0.18, ctx.moonDir.y));
    L.dayW = smoothstep(-8.0, 2.5, el);
    L.expo = mix(6.2, 1.0, smoothstep(-15.0, 2.0, el));
    return L;
}

// ---------------------------------------------------------------- night sky
inline float3 hp_night(float3 rd, WSCtx ctx) {
    if (rd.y < -0.04) return float3(0.0);
    float3 gp = normalize(float3(0.58, 0.40, -0.71));
    float b = dot(rd, gp);
    float band = exp(-b * b / 0.028);
    float az = atan2(rd.z, rd.x);
    float3 col = float3(0.0);
    if (band > 0.006) {
        float2 mq = float2(az * 1.7, b * 7.5);
        float dust = fbm(mq * 1.4 + 4.0, 4);
        float cl   = fbm(mq * 3.2 + 11.0, 3);
        float mw = band * (0.52 + 0.95 * cl) * smoothstep(0.30, -0.12, dust);
        col += mix(float3(0.46, 0.52, 0.74), float3(0.80, 0.74, 0.62), 0.35 + 0.5 * cl) * mw * 0.0135;
    }
    float2 sp = float2(az * 0.36, asin(clamp(rd.y, -1.0, 1.0)) * 0.72);
    col += ws_stars(sp, 44.0, fract(ctx.time * 0.013), 0.30) * 0.030 * (0.7 + 0.8 * band);
    col += ws_stars(sp * 1.93 + 13.0, 76.0, fract(ctx.time * 0.009 + 0.3), 0.22) * 0.011;
    return col * smoothstep(-0.03, 0.11, rd.y);
}

inline float3 hp_moon(float3 rd, WSCtx ctx, float px) {
    float3 md = ctx.moonDir;
    float mi = clamp(ctx.moonIllum, 0.0, 1.0);
    float up = smoothstep(-0.09, 0.05, md.y);
    if (up <= 0.0) return float3(0.0);
    float c = dot(rd, md);
    if (c < 0.90) return float3(0.0);
    float R = 0.262 * DEG;
    float3 glow = float3(0.72, 0.78, 0.96)
                * (0.020 * pow(c, 2600.0) + 0.0055 * pow(c, 160.0)) * mi * up;
    if (c < cos(R * 1.7)) return glow;
    float3 mx = normalize(ctx.sunDir - md * dot(ctx.sunDir, md) + float3(1e-5, 1e-5, 0.0));
    float3 my = cross(md, mx);
    float2 q = float2(dot(rd, mx), dot(rd, my)) / R;
    float rr = length(q);
    float edge = clamp((1.0 - rr) / max(px / R, 1e-3) + 0.5, 0.0, 1.0);
    if (edge <= 0.0) return glow;
    float term = (1.0 - 2.0 * mi) * sqrt(max(1.0 - q.y * q.y, 0.0));
    float lit = smoothstep(-0.05, 0.07, q.x - term);
    float mu = sqrt(max(1.0 - rr * rr, 0.0));
    float alb = 0.82 + 0.26 * fbm(q * 2.4 + 7.0, 4) - 0.22 * smoothstep(0.20, 0.72, fbm(q * 1.05 + 2.0, 3) + 0.5);
    float3 mc = float3(0.98, 0.96, 0.91) * alb * (0.76 + 0.24 * sqrt(mu)) * lit * 0.24;
    mc += float3(0.10, 0.13, 0.20) * (1.0 - lit) * 0.016 * mi;
    return glow + mc * edge * up;
}

// ---------------------------------------------------------------- cloud decks
inline float2 hp_cloudUV(float2 world, float scale, float time, float wind) {
    return world * scale + float2(time * wind * 0.00060, time * wind * 0.00022);
}
inline float hp_cloudDen(float2 cp, float lod, float cover) {
    return smoothstep(cover, cover + 0.30, hp_fbm(cp, lod) + 0.5);
}

inline float3 hp_cloud(float3 ro, float3 rd, float Y, float maxDist, WSCtx ctx, HPLight L,
                       float3 skyBg, float scale, float opacity, float cover, float wind,
                       thread float &alpha) {
    alpha = 0.0;
    float ry = rd.y;
    if (ry < 0.004) return float3(0.0);
    float td = (Y - ro.y) / ry;
    if (td <= 0.0) return float3(0.0);
    float2 cp0 = hp_cloudUV(ro.xz + rd.xz * min(td, maxDist), scale, ctx.time, wind);
    td = (Y + 1000.0 * hp_fbm(cp0, 2.4) - ro.y) / ry;     // bumpy deck: not a flat plane
    if (td <= 0.0 || td > maxDist) return float3(0.0);
    float2 cp = hp_cloudUV(ro.xz + rd.xz * td, scale, ctx.time, wind);
    float lod = clamp(4.8 - 0.75 * log2(max(td, 6000.0) / 6000.0), 1.7, 4.8);
    float d = hp_cloudDen(cp, lod, cover);
    d *= (1.0 - smoothstep(0.30 * maxDist, maxDist, td)) * smoothstep(0.004, 0.030, ry);
    if (d <= 0.003) return float3(0.0);

    float2 sv = normalize(ctx.sunDir.xz + float2(1e-4, 0.0)) * (scale * 1350.0);
    float ds = hp_cloudDen(cp + sv, min(lod, 3.4), cover);
    float lit = exp(-2.6 * ds) * (0.20 + 0.80 * clamp(ctx.sunDir.y * 4.0 + 0.28, 0.0, 1.0));
    float mu = dot(rd, ctx.sunDir);
    float fwd = 1.0 + 3.4 * pow(max(mu, 0.0), 9.0);
    float3 col = L.sunCol * (0.195 * lit * fwd + 0.020) + L.skyCol * (0.24 + 0.22 * lit);
    col += L.moonCol * 5.0 * lit;
    col = mix(col, skyBg, 1.0 - exp(-td * 1.1e-5));
    alpha = clamp(d * opacity, 0.0, 1.0);
    return col;
}

inline float hp_cloudShadow(float3 pos, WSCtx ctx) {
    float sy = ctx.sunDir.y;
    if (sy < 0.06) return 1.0;
    float s = (HP_CUMY - pos.y) / sy;
    if (s <= 0.0) return 1.0;
    float2 cp = hp_cloudUV(pos.xz + ctx.sunDir.xz * s, HP_CUMS, ctx.time, 1.0);
    return 1.0 - 0.70 * hp_cloudDen(cp, 3.0, HP_CUMC);
}

// ---------------------------------------------------------------- sky
inline float3 hp_sky(float3 rd, WSCtx ctx, HPLight L, float px) {
    float3 rs = rd;
    // lift rays off the geometric horizon (ws_atmosphereFast clips on the planet)
    // and never let a downward ray take a longer air path than the horizon itself.
    rs.y = max(0.5 * (rd.y + sqrt(rd.y * rd.y + 0.0020)), 0.014);
    float3 col = ws_atmosphereFast(normalize(rs), ctx.sunDir, 22.0);
    if (L.dayW < 0.995) {
        float nightW = 1.0 - L.dayW * 0.97;
        col += hp_night(rd, ctx) * nightW;
        col += hp_moon(rd, ctx, px) * nightW;
    }
    if (ctx.sunDir.y > -0.10 && dot(rd, ctx.sunDir) > 0.9985) {
        float s  = sin(max(L.el, -6.0) * DEG);
        float am = min(1.0 / max(s + 0.15 * pow(max(L.el + 3.885, 0.12), -1.253), 0.018), 42.0);
        col += ws_sunDisk(rd, ctx.sunDir, 0.27, 165.0 * exp(-(float3(0.031, 0.095, 0.214) + 0.075) * am));
    }
    return col;
}

// ---------------------------------------------------------------- surface
struct HPSurf { float3 alb; float spec, rough, forest, canopy, snow; };

inline HPSurf hp_albedo(float3 pos, float3 n, float lod, float dayOfYear) {
    HPSurf S;
    float y = pos.y;
    float sl = clamp(n.y, 0.0, 1.0);
    float l3 = min(lod, 3.0), lf = clamp(lod - 1.6, 0.0, 3.0), lc = clamp(lod - 1.1, 0.0, 4.2);
    float xw = max(-pos.x, 0.0);
    float fl = hp_floorY(xw);
    float au = abs(pos.z - hp_axis(xw));

    // shared noise fields
    float nL = hp_fbm(pos.xz * 0.00072 + 31.0, l3);       // landscape scale
    float nM = hp_fbm(pos.xz * 0.0031 + 21.0, l3);        // patch scale
    float nC = hp_fbm(pos.xz * 0.0125 + 3.0, lc);         // canopy / boulders
    float nF = hp_fbm(pos.xz * 0.019, lf);                // fine texture
    float nX = hp_fbm(pos.xz * 0.155 + 7.3, clamp(lod - 4.3, 0.0, 2.4));   // near-field grain

    // ---- stratified rock
    float sb = y * 0.0040 + pos.x * 0.00026 - pos.z * 0.00018 + 1.6 * nL;
    float band  = 0.5 + 0.5 * sin(sb * 6.2831);
    float band2 = 0.5 + 0.5 * sin(sb * 16.1 + 1.1);
    float3 rock = mix(float3(0.100, 0.094, 0.093), float3(0.196, 0.180, 0.157), band);
    rock = mix(rock, float3(0.172, 0.126, 0.082), 0.44 * band2 * smoothstep(0.30, 0.85, band));
    rock *= 0.66 + 0.60 * (nF + nC * 0.5 + 0.5) + 0.34 * nX;
    float lich = smoothstep(0.55, 0.86, sl) * (1.0 - smoothstep(2300.0, 2950.0, y))
               * smoothstep(0.08, 0.50, nM + 0.5);
    rock = mix(rock, float3(0.130, 0.140, 0.088), 0.42 * lich);
    rock = mix(rock, float3(0.180, 0.168, 0.154),
               0.32 * smoothstep(0.74, 0.92, sl) * (1.0 - smoothstep(3200.0, 3650.0, y)));

    // ---- alpine meadow
    float3 grass = mix(float3(0.042, 0.060, 0.032), float3(0.098, 0.130, 0.062),
                       clamp(0.5 + nM * 1.5 + nL * 1.4, 0.0, 1.0));
    grass *= 0.78 + 0.44 * (nF + 0.5) + 0.30 * nX;
    float meadow = smoothstep(0.58, 0.84, sl) * (1.0 - smoothstep(2280.0, 2720.0, y));

    // ---- conifer forest
    float treeline = 2150.0 + 300.0 * nL;
    float forest = smoothstep(0.46, 0.74, sl)
                 * (1.0 - smoothstep(treeline - 180.0, treeline + 120.0, y))
                 * smoothstep(0.16, 0.56, nL + 0.5 + 0.5 * nC);
    float3 tree = mix(float3(0.0080, 0.0145, 0.0105), float3(0.0270, 0.0415, 0.0215),
                      clamp(0.5 + nC * 2.3 + nF * 0.6 + nX * 0.5, 0.0, 1.0));

    float3 alb = rock;
    alb = mix(alb, grass, meadow * 0.92);
    alb = mix(alb, tree, forest * 0.96);

    // ---- gravel bars along the river corridor only
    float rw = hp_riverW(xw);
    float bank = smoothstep(rw * 6.0, rw * 1.25, au) * (1.0 - smoothstep(4.0, 34.0, abs(y - fl)))
               * smoothstep(0.80, 0.95, sl) * smoothstep(0.02, 0.45, nM + 0.5);
    alb = mix(alb, float3(0.215, 0.202, 0.182), 0.82 * bank);

    // ---- snow
    float seas = 150.0 * cos((dayOfYear - 28.0) * 0.0172);
    float snowline = 3280.0 + seas - 250.0 * clamp(-n.z, 0.0, 1.0) + 200.0 * clamp(n.z, 0.0, 1.0);
    float sn = smoothstep(snowline - 220.0, snowline + 340.0, y + nL * 640.0);
    sn *= smoothstep(0.26, 0.62, sl);
    sn *= 0.46 + 0.54 * smoothstep(-0.26, 0.30, nM * 1.6 + nC * 0.7);
    sn = max(sn, smoothstep(0.38, 0.70, sl) * smoothstep(4150.0, 4560.0, y));
    sn = clamp(sn, 0.0, 1.0);
    alb = mix(alb, float3(0.80, 0.83, 0.89) * (0.94 + 0.10 * (nF + 0.5)), sn);

    S.alb = alb;
    S.spec = mix(0.026, 0.060, sn);
    S.rough = mix(0.88, 0.52, sn);
    S.forest = forest * (1.0 - sn);
    S.canopy = nC;
    S.snow = sn;
    return S;
}

// ---------------------------------------------------------------- scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 uv = fragCoord / ctx.res;
    float3 ro = HP_RO;
    ro.y = hp_h(HP_RO.xz, 6.0) + 15.0;
    float3 fwd = normalize(float3(-1.0, tan(HP_TILT * DEG), 0.0));
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ro + fwd * 10000.0, HP_FOV);
    float px = 2.0 * tan(HP_FOV * 0.5 * DEG) / ctx.res.y;

    HPLight L = hp_light(ctx);
    float3 sun = ctx.sunDir;

    // ---------------------------------------------------------- march
    float t = 25.0, tHit = -1.0, tWat = -1.0;
    float minAng = 1e9, tMin = 0.0, prevD = 1e9, prevT = t;
    bool spent = true;
    for (int i = 0; i < 128; i++) {
        float3 q = ro + rd * t;
        if (q.y > HP_TOP && rd.y > 0.0) { spent = false; break; }
        float hh = hp_h(q.xz, hp_lodM(t));
        float d = q.y - hh;
        if (tWat < 0.0 && d > 0.0 && q.y < hp_waterY(q.xz) && hp_inRiver(q.xz)) tWat = t;
        if (d < 0.0) { tHit = mix(prevT, t, clamp(prevD / max(prevD - d, 1e-4), 0.0, 1.0)); spent = false; break; }
        float ang = d / t;
        if (ang < minAng) { minAng = ang; tMin = t; }
        prevD = d; prevT = t;
        t += max(0.42 * d, 0.0105 * t + 2.5);
        if (t > 48000.0) { spent = false; break; }
    }
    // a descending ray that simply ran out of iterations is still on the land:
    // shade where it stopped rather than letting the sky show through.
    if (tHit < 0.0 && spent && rd.y < 0.0) tHit = t;
    float cov = 1.0;
    if (tHit < 0.0) {
        cov = 1.0 - smoothstep(0.0, 1.4 * px, minAng);
        if (cov > 0.002) tHit = tMin;
    }
    float wAlpha = 0.0;
    if (tWat > 0.0 && rd.y < -1e-4 && (tHit < 0.0 || tWat < tHit + 60.0)) {
        float tw = tWat;
        for (int k = 0; k < 3; k++) tw = (hp_waterY((ro + rd * tw).xz) - ro.y) / rd.y;
        float3 wp = ro + rd * tw;
        float depth = hp_waterY(wp.xz) - hp_h(wp.xz, hp_lodS(tw));
        wAlpha = hp_inRiver(wp.xz) ? smoothstep(0.0, 1.8 + 0.0050 * tw, depth) : 0.0;
        if (wAlpha > 0.002 && (tHit < 0.0 || tw < tHit + 60.0)) { tHit = tw; cov = 1.0; }
        else wAlpha = 0.0;
    }

    // ---------------------------------------------------------- sky + clouds
    float3 skyBg = hp_sky(rd, ctx, L, px);
    float3 col = skyBg;
    float aC = 0.0, aH = 0.0;
    float cloudMax = (tHit > 0.0 && cov > 0.5) ? tHit : 1e9;
    float3 cir = hp_cloud(ro, rd, 9600.0, min(cloudMax, 240000.0), ctx, L, skyBg,
                          0.000075, 0.34, 0.50, 1.9, aH);
    col = mix(col, cir, aH);
    float3 cum = hp_cloud(ro, rd, HP_CUMY, min(cloudMax, 130000.0), ctx, L, skyBg,
                          HP_CUMS, 0.96, HP_CUMC, 1.0, aC);
    col = mix(col, cum, aC);
    float3 bg = col;

    // ---------------------------------------------------------- land
    if (tHit > 0.0 && cov > 0.002) {
        float3 pos = ro + rd * tHit;
        float lod = hp_lodS(tHit);
        float mu = dot(rd, sun);
        float e = max(0.9, 0.0024 * tHit);
        float h0 = hp_h(pos.xz, lod);
        float hx = hp_h(pos.xz + float2(e, 0.0), lod);
        float hz = hp_h(pos.xz + float2(0.0, e), lod);
        float3 n = normalize(float3(h0 - hx, e, h0 - hz));
        float3 gp = float3(pos.x, h0, pos.z);
        HPSurf S = hp_albedo(gp, n, lod, ctx.dayOfYear);

        float nearW = 1.0 - smoothstep(4000.0, 15000.0, tHit);
        if (S.forest > 0.03 && nearW > 0.02) {
            float sc = 0.0125, ee = 14.0, lc = clamp(lod - 1.1, 0.0, 4.2);
            float cx = hp_fbm((gp.xz + float2(ee, 0.0)) * sc + 3.0, lc);
            float cz = hp_fbm((gp.xz + float2(0.0, ee)) * sc + 3.0, lc);
            float amp = 56.0 * S.forest * nearW;
            n = normalize(n - float3((cx - S.canopy) / ee * amp, 0.0, (cz - S.canopy) / ee * amp));
        }

        float sh = hp_shadow(gp + n * 2.5, sun) * hp_cloudShadow(gp, ctx);
        float ndl = max(dot(n, sun), 0.0);
        float ao = clamp(0.32 + 0.76 * n.y, 0.0, 1.0) * (1.0 - 0.34 * S.forest);
        float3 direct = L.sunCol * ndl * sh;
        float3 amb = L.skyCol * (0.40 + 0.60 * clamp(n.y * 0.5 + 0.5, 0.0, 1.0)) * ao
                   * mix(float3(1.0), float3(0.84, 0.94, 1.18), S.snow);
        // snow forward-scatters a little light through thin edges
        direct += L.sunCol * S.snow * 0.09 * pow(max(dot(n, sun) * 0.5 + 0.5, 0.0), 2.0) * sh;
        float3 bnc = L.sunCol * 0.050 * clamp(0.42 - n.y * 0.34, 0.0, 1.0)
                   * float3(0.60, 0.52, 0.40) * max(sun.y, 0.0) * (0.3 + 0.7 * sh);
        float3 mool = L.moonCol * (max(dot(n, ctx.moonDir), 0.0) * (0.35 + 0.65 * ao) + 0.20 * ao);
        float3 surf = S.alb * (direct + amb + bnc + mool);

        float3 hv = normalize(sun - rd);
        float nh = max(dot(n, hv), 0.0);
        float a2 = S.rough * S.rough * S.rough * S.rough + 0.003;
        float dsp = a2 / (PI * pow(nh * nh * (a2 - 1.0) + 1.0, 2.0));
        surf += L.sunCol * min(dsp, 60.0) * S.spec * sh * ndl;

        if (L.dayW < 0.9) {
            float3 hutP = float3(HP_HUT.x, hp_floorY(-HP_HUT.x) + 4.0, HP_HUT.y);
            float hd2 = dot(gp - hutP, gp - hutP);
            surf += S.alb * float3(1.0, 0.48, 0.16) * 2.6 * exp(-hd2 / 2600.0)
                  * (1.0 - L.dayW) * clamp(n.y, 0.0, 1.0);
        }

        // -------------------------------------------------- river surface
        if (wAlpha > 0.002) {
            float2 wq = pos.xz * 0.115;
            float ti = ctx.time;
            float w1 = gnoise(wq + float2(ti * 0.55, ti * 0.10));
            float w2 = gnoise(wq * 2.7 + float2(ti * 0.95, -ti * 0.20));
            float w3 = gnoise(wq * 6.3 + float2(ti * 1.8, ti * 0.42));
            float amp = 1.0 / (1.0 + tHit * 0.0011);
            float2 g = float2(w1 * 0.9 + w2 * 0.5 + w3 * 0.20,
                              w2 * 0.8 + w1 * 0.45 + w3 * 0.24) * 0.085 * amp;
            float3 wn = normalize(float3(g.x, 1.0, g.y));
            float3 rrd = normalize(reflect(rd, wn) + float3(0.0, 0.03, 0.0));
            rrd.y = abs(rrd.y);
            rrd = normalize(rrd);
            float3 rs = rrd; rs.y = max(0.5 * (rrd.y + sqrt(rrd.y * rrd.y + 0.0020)), 0.014);
            float3 refl = ws_atmosphereFast(normalize(rs), sun, 22.0) + L.skyCol * 0.22 * (1.0 - L.dayW);
            float F = clamp(0.021 + 0.979 * pow(1.0 - clamp(dot(-rd, wn), 0.0, 1.0), 5.0), 0.02, 1.0);
            float3 bedC = S.alb * 0.55 * (L.skyCol * 0.85 + L.sunCol * 0.18 * max(sun.y, 0.0) * sh);
            float3 whv = normalize(sun - rd);
            float wnh = max(dot(wn, whv), 0.0);
            float wa2 = 0.0040;
            float wsp = wa2 / (PI * pow(wnh * wnh * (wa2 - 1.0) + 1.0, 2.0));
            float3 water = mix(bedC, refl, F) + L.sunCol * min(wsp, 700.0) * 0.012 * sh;
            surf = mix(surf, water, wAlpha);
        }

        // -------------------------------------------------- aerial perspective
        float fog = ws_fogAmount(tHit, ro, rd, 4.2e-5 * (1.0 + 0.40 * L.dayW), 0.00046);
        surf = mix(surf, bg * (1.0 + 1.6 * pow(max(mu, 0.0), 10.0) * L.dayW), fog);

        // -------------------------------------------------- early-morning valley mist
        float hr = ctx.dayTime;
        float mistT = smoothstep(2.4, 4.6, hr) * (1.0 - smoothstep(7.2, 10.8, hr));
        if (mistT > 0.004) {
            float top = hp_floorY(max(-pos.x, 0.0)) + 250.0;
            float texn = hp_fbm(pos.xz * 0.00078 + float2(ctx.time * 0.0013, ctx.time * 0.0007), 3.5);
            float band = 1.0 - smoothstep(top - 200.0 + texn * 330.0, top + 150.0, pos.y);
            float m = clamp(mistT * band * (1.0 - exp(-tHit * 0.00040)) * 1.6, 0.0, 0.96);
            surf = mix(surf, L.skyCol * 0.62 + L.sunCol * 0.055 * (1.0 + 2.4 * pow(max(mu, 0.0), 6.0)), m);
        }
        col = mix(bg, surf, cov);
    }

    // ---------------------------------------------------------- shepherd's hut
    {
        float3 hg = float3(HP_HUT.x, hp_floorY(-HP_HUT.x) + 1.0, HP_HUT.y);
        float3 toH = hg - ro;
        float hdist = length(toH);
        if (dot(rd, toH / hdist) > 0.9975) {
            hg.y = hp_h(HP_HUT, 5.0);
            float3 bc = hg + float3(0.0, 3.4, 0.0);
            float3 be = float3(6.6, 3.5, 4.4);
            float3 m = 1.0 / rd;
            float3 k = abs(m) * be;
            float3 o = -m * (ro - bc);
            float3 t1 = o - k, t2 = o + k;
            float tN = max(max(t1.x, t1.y), t1.z);
            float tF = min(min(t2.x, t2.y), t2.z);
            if (tN < tF && tN > 0.0 && (tHit < 0.0 || tN < tHit)) {
                float3 hp = ro + rd * tN;
                float3 hn = -sign(rd) * step(t1.yzx, t1.xyz) * step(t1.zxy, t1.xyz);
                float3 lp = (hp - bc) / be;
                float3 alb = mix(float3(0.075, 0.060, 0.046), float3(0.046, 0.044, 0.043), step(0.70, lp.y));
                float sh = hp_shadow(hp + hn * 0.6, sun);
                float3 sc = alb * (L.sunCol * max(dot(hn, sun), 0.0) * sh
                                 + L.skyCol * (0.42 + 0.58 * max(hn.y, 0.0))
                                 + L.moonCol * max(dot(hn, ctx.moonDir), 0.0));
                float win = max(step(0.55, hn.z) * step(abs(lp.x - 0.20), 0.17),
                                step(0.55, hn.x) * step(abs(lp.z + 0.06), 0.19))
                          * step(abs(lp.y + 0.08), 0.24);
                sc = mix(sc, float3(1.0, 0.50, 0.16) * 0.62, win * (1.0 - L.dayW));
                sc = mix(sc, bg, ws_fogAmount(tN, ro, rd, 4.2e-5, 0.00046));
                col = sc;
                tHit = tN;
            }
            float3 tw = hg + float3(3.6, 3.4, 4.4) - ro;
            float dw = length(tw);
            float ca = dot(rd, tw / dw);
            if (ca > 0.9985 && (tHit < 0.0 || dw < tHit + 30.0))
                col += float3(1.0, 0.46, 0.15) * 0.10 * pow(ca, 900.0) * (1.0 - L.dayW);
        }
    }

    // ---------------------------------------------------------- grade
    col *= L.expo;
    col *= ws_vignette(uv, 0.28);
    col = ws_acesFitted(col);
    col += ws_grain(fragCoord, ctx.time * 0.017) * 0.0045 * sqrt(max(col, 0.0));
    return col;
}
