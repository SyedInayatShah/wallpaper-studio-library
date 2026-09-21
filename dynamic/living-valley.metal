// =====================================================================
//  Living Valley — a real-time alpine valley driven by the user's clock.
//
//  A calm lake seen from a 60 m bluff, camera facing WEST so the sun sets
//  straight down the water.  Geometry is a stack of world-space "depth
//  slabs": each mountain / forest mass is a height profile evaluated on a
//  vertical plane at its true distance, composited NEAR -> FAR with
//  analytic coverage AA and early-out.  The lake is an exact plane whose
//  reflected ray re-enters the same slab stack, so reflections are
//  geometrically correct and cost no marching.
//
//  Light comes from ctx.sunDir / ctx.moonDir through ws_atmosphereFast, so
//  sunrise, midday, golden hour, sunset, blue hour and night fall out of
//  the physics.  Morning mist (5-9 am), drifting clouds, warm cabin
//  windows after dark, the real moon phase, a faint Milky Way and summer
//  fireflies are scheduled from ctx.dayTime / ctx.dayOfYear.
// =====================================================================

constant float LV_DEG   = 0.017453292519943295;
constant float LV_CAMH  = 60.0;     // camera height above the lake (m)
constant float LV_FOV   = 26.0;     // vertical field of view (deg)
constant float LV_PITCH = -1.585;   // deg — puts the horizon at 0.56 h

constant int   LV_N = 5;
constant float LV_D[5]    = { 11000.0, 5500.0, 2600.0, 1300.0, 480.0 };  // distance (m)
constant float LV_HS[5]   = {  3000.0, 1450.0,  720.0,  380.0, 145.0 };  // profile scale (m)
constant float LV_BASE[5] = {   560.0,  200.0,   55.0,    6.0,   2.0 };  // valley floor (m)
constant float LV_REL[5]  = {  1180.0,  430.0,  162.0,   30.0,   8.5 };  // relief (m)
constant float LV_TH[5]   = {     0.0,   14.0,   17.0,   22.0,  19.0 };  // tree height (m)
constant float LV_TC[5]   = {     1.0,    7.5,    8.0,    6.4,   5.0 };  // tree spacing (m)

constant float LV_SNOW = 730.0;     // snow line above lake level (m)
constant float LV_CABX = -112.0;    // cabin x on the spit (m)

// ------------------------------------------------------------------ light rig
struct LvLight {
    float3 sun;      // local-frame sun direction (camera faces -z = west)
    float3 moon;
    float  sunEl;    // degrees
    float  moonEl;
    float  moonIl;
    float3 Esun;     // direct sun irradiance, perpendicular surface
    float3 Emoon;
    float3 Lz;       // zenith sky radiance
    float3 Lh;       // sun-side low-sky radiance
    float  night;    // 0 day .. 1 deep night
};

// Single-scattering Rayleigh+Mie sky, 6 view x 3 light steps — the smooth
// function the app needs, at ~55% the cost of ws_atmosphereFast.
inline float3 lv_atmos(float3 rd, float3 sun) {
    float3 r = normalize(float3(rd.x, max(rd.y, -0.004), rd.z));
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kRlh = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kMie = 21e-6;
    const float shRlh = 8e3, shMie = 1.2e3;
    float3 r0 = float3(0.0, Rp + 1600.0, 0.0);
    float2 p = ws_raySphere(r0, r, Ra);
    if (p.x > p.y || p.y < 0.0) return float3(0.0);
    p.x = max(p.x, 0.0);
    float2 pg = ws_raySphere(r0, r, Rp);
    if (pg.x <= pg.y && pg.x > 0.0) p.y = min(p.y, pg.x);
    float iStep = (p.y - p.x) / 5.0;
    float iT = p.x;
    float3 totR = float3(0.0), totM = float3(0.0);
    float odR = 0.0, odM = 0.0;
    float mu = dot(r, sun), mumu = mu * mu, gg = 0.76 * 0.76;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) /
               (pow(1.0 + gg - 2.0 * mu * 0.76, 1.5) * (2.0 + gg));
    for (int i = 0; i < 5; i++) {
        float3 iPos = r0 + r * (iT + iStep * 0.5);
        float iH = length(iPos) - Rp;
        float dR = exp(-iH / shRlh) * iStep, dM = exp(-iH / shMie) * iStep;
        odR += dR; odM += dM;
        float2 sg = ws_raySphere(iPos, sun, Rp);
        if (sg.x <= sg.y && sg.x > 0.0) { iT += iStep; continue; }
        float jStep = ws_raySphere(iPos, sun, Ra).y / 3.0;
        float jR = 0.0, jM = 0.0;
        for (int j = 0; j < 3; j++) {
            float jH = length(iPos + sun * (jStep * (float(j) + 0.5))) - Rp;
            jR += exp(-jH / shRlh) * jStep;
            jM += exp(-jH / shMie) * jStep;
        }
        float3 attn = exp(-(kMie * (odM + jM) + kRlh * (odR + jR)));
        totR += dR * attn; totM += dM * attn;
        iT += iStep;
    }
    // single scattering alone leaves the horizon brown; add the multiply-scattered
    // light that makes a real daytime horizon pale and luminous
    float3 odT = kRlh * odR + kMie * odM;
    float3 tr = exp(-odT);
    float su = smoothstep(-0.10, 0.30, sun.y);
    float3 msT = mix(float3(1.00, 0.66, 0.40), float3(0.78, 0.88, 1.00), smoothstep(0.02, 0.40, sun.y));
    return 21.0 * (pR * kRlh * totR + pM * kMie * totM) + msT * (1.0 - tr) * (0.46 * su);
}

// Kasten-Young airmass -> per-channel direct transmittance.
inline float3 lv_sunTransmit(float el) {
    float e = max(el, -1.2);
    float am = 1.0 / (sin(max(e, 0.35) * LV_DEG) + 0.15 * pow(e + 3.885, -1.253));
    am = min(am, 34.0);
    float3 tau = float3(0.119, 0.201, 0.366);
    return exp(-tau * am);
}

// Very cheap sky sample (4 x 2 steps) — only used for the ambient term.
inline float3 lv_atmosLite(float3 r, float3 sun) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kRlh = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kMie = 21e-6, shRlh = 8e3, shMie = 1.2e3;
    float3 r0 = float3(0.0, Rp + 1600.0, 0.0);
    float2 p = ws_raySphere(r0, r, Ra);
    if (p.x > p.y || p.y < 0.0) return float3(0.0);
    p.x = max(p.x, 0.0);
    float iStep = (p.y - p.x) / 4.0, iT = p.x;
    float3 totR = float3(0.0), totM = float3(0.0);
    float odR = 0.0, odM = 0.0;
    float mu = dot(r, sun), mumu = mu * mu, gg = 0.76 * 0.76;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) /
               (pow(1.0 + gg - 2.0 * mu * 0.76, 1.5) * (2.0 + gg));
    for (int i = 0; i < 4; i++) {
        float3 iPos = r0 + r * (iT + iStep * 0.5);
        float iH = length(iPos) - Rp;
        float dR = exp(-iH / shRlh) * iStep, dM = exp(-iH / shMie) * iStep;
        odR += dR; odM += dM;
        float2 sg = ws_raySphere(iPos, sun, Rp);
        if (sg.x <= sg.y && sg.x > 0.0) { iT += iStep; continue; }
        float jStep = ws_raySphere(iPos, sun, Ra).y / 2.0;
        float jR = 0.0, jM = 0.0;
        for (int j = 0; j < 2; j++) {
            float jH = length(iPos + sun * (jStep * (float(j) + 0.5))) - Rp;
            jR += exp(-jH / shRlh) * jStep;
            jM += exp(-jH / shMie) * jStep;
        }
        float3 attn = exp(-(kMie * (odM + jM) + kRlh * (odR + jR)));
        totR += dR * attn; totM += dM * attn;
        iT += iStep;
    }
    return 21.0 * (pR * kRlh * totR + pM * kMie * totM);
}

// ------------------------------------------------------------------ profiles
inline float lv_prof(int i, float x, int lod = 0) {
    float u = x / LV_HS[i];
    float sd = 7.31 * float(i) + 1.7;
    float env = gnoise(float2(u * 0.30, sd + 2.1));                    // massif envelope
    u += 0.34 * gnoise(float2(u * 0.23, sd + 4.2));
    float r = ridged(float2(u, sd), lod > 0 ? 2 : (i < 2 ? 4 : 3));
    float f = fbm(float2(u * 0.95, sd + 11.0), lod > 0 ? 2 : 3);
    float h = (r - 0.42) * 1.30 + 0.34 * f;
    h *= 0.50 + 0.88 * smoothstep(-0.55, 0.55, env);
    h = LV_BASE[i] + LV_REL[i] * max(h, -0.26);
    float taper = 1.0 - 0.40 * smoothstep(-0.25 * LV_HS[i], 1.5 * LV_HS[i], x);
    if (i == 0) h = LV_BASE[i] + (h - LV_BASE[i]) * taper;              // massif falls away east
    if (i == 1) h = LV_BASE[i] + (h - LV_BASE[i]) * mix(1.0, taper, 0.55);
    if (i == 2) {
        // valley walls: high at both edges, a saddle in the middle so the head
        // of the valley and its snow peaks stay open
        float w = abs(x) / 900.0;
        h = 34.0 + (h - 34.0) * (0.26 + 1.35 * smoothstep(0.10, 1.05, w));
        h += 120.0 * smoothstep(0.55, 1.35, w);
    }
    if (i == 3) h = max(h, 3.0 + 4.0 * smoothstep(-0.5, 0.5, sin(x / 130.0)));   // continuous shore
    if (i == 4) {
        float lft = smoothstep(-84.0, -140.0, x);                       // wooded spit (cabin)
        float rgt = smoothstep(102.0, 150.0, x);                        // near shoulder, right
        h = mix(-7.0, (h + 2.0) * (x > 0.0 ? 1.45 : 1.0), max(lft, rgt));
    }
    return h;
}

// Conifer canopy: signed horizontal distance (m, + inside).
inline float lv_trees(int i, float x, float y, float ghc, float slope,
                      float dens, thread float &depth) {
    float cell = LV_TC[i], H = LV_TH[i];
    float ci = floor(x / cell);
    float best = -1e9;
    depth = 0.0;
    for (int k = -1; k <= 1; k++) {
        float id = ci + float(k);
        float4 h = hash24(float2(id, 13.0 + float(i)));
        if (h.x > dens) continue;
        float cx = (id + 0.5 + (h.y - 0.5) * 0.62) * cell;
        float gh = ghc + slope * (cx - x);
        float th = H * (0.30 + 0.95 * h.z * h.z + (h.w > 0.88 ? 0.55 : 0.0));   // emergents
        float s = gh + th - y;
        float cand;
        if (s < 0.0) {
            cand = 1.8 * s - abs(x - cx);
        } else {
            float w = min((0.140 + 0.085 * h.w) * (s + 0.22 * H * h.w), cell * 0.72);
            w *= 1.0 + 0.17 * sin(s * (2.2 + 2.4 * h.w) + h.z * 9.0);
            cand = w - abs(x - cx);
        }
        if (cand > best) { best = cand; depth = max(s, 0.0) / max(H, 1.0); }
    }
    return best;
}

// ------------------------------------------------------------------ clouds / sky
inline float3 lv_clouds(float3 rd, LvLight L, float time, float3 skyCol, float calm, int lod) {
    if (rd.y < 0.0035) return skyCol;
    float3 col = skyCol;
    float sf = max(dot(rd, L.sun), 0.0);

    // ---- mid-level cumulus deck
    float tC = min((3800.0 - LV_CAMH) / rd.y, 150000.0);
    float2 q = float2(rd.x, rd.z) * (tC / 2900.0);
    float2 dr = float2(time * 0.0030, time * 0.0012);
    float d = (lod == 0) ? fbm(q + dr, 4) * 0.80 + gnoise(q * 5.1 - dr * 1.8 + 8.3) * 0.20
                         : fbm(q + dr, 3);
    d = d * 0.5 + 0.5;
    float a = smoothstep(0.505, 0.700, d) * smoothstep(0.0035, 0.028, rd.y) * calm;
    if (a > 0.003) {
        float thick = smoothstep(0.505, 0.930, d);
        float hgF = pow(sf, 7.0);
        float3 amb = L.Lz * 1.75 + L.Lh * 0.55;
        float3 cc = amb * (0.32 + 0.50 * (1.0 - thick))
                  + L.Esun * (0.030 + 0.115 * exp(-thick * 3.0)) * (0.55 + 1.9 * hgF)
                  + L.Emoon * (0.5 + 1.8 * hgF) * (0.35 + 0.5 * (1.0 - thick));
        float hz = smoothstep(0.26, 0.008, rd.y);
        cc = mix(cc, skyCol, 0.14 + 0.78 * hz);
        a *= 1.0 - 0.58 * hz;
        col = mix(col, cc, clamp(a, 0.0, 1.0));
    }
    // ---- high cirrus
    float tH = min((9200.0 - LV_CAMH) / rd.y, 240000.0);
    float2 qh = float2(rd.x, rd.z) * (tH / 9000.0);
    float dh = fbm(float2(qh.x * 2.3, qh.y * 0.55) + float2(time * 0.0021, 0.0), 2);
    float ah = smoothstep(0.09, 0.46, dh) * smoothstep(0.010, 0.085, rd.y) * 0.40 * calm;
    if (ah > 0.003) {
        float3 cc = L.Lz * 2.1 + L.Esun * (0.020 + 0.075 * pow(sf, 5.0)) + L.Emoon * 1.2;
        col = mix(col, cc, clamp(ah, 0.0, 1.0));
    }
    return col;
}

inline float3 lv_nightSky(float3 rd, LvLight L, float time) {
    float fade = smoothstep(-0.5, -9.5, L.sunEl);
    if (fade <= 0.001) return float3(0.0);
    float2 sp = float2(atan2(rd.x, -rd.z), asin(clamp(rd.y, -1.0, 1.0)));
    float3 col = ws_stars(sp * 0.42, 33.0, time * 0.016, 0.28) * 0.0165;
    col += ws_stars(sp * 0.42 + 5.0, 71.0, time * 0.010, 0.20) * 0.0072;
    // Milky Way: a soft band with dust lanes across the southern sky
    float3 g = normalize(float3(-0.556, 0.606, -0.569));
    float b = dot(rd, g);
    float band = exp(-b * b * 20.0);
    if (band > 0.003) {
        float dust = fbm(float2(sp.x * 2.6, sp.y * 4.4) + 3.0, 5);
        float lane = smoothstep(-0.35, 0.45, dust);
        float3 mw = mix(float3(0.80, 0.86, 1.0), float3(1.0, 0.93, 0.82), 0.38 * lane);
        col += mw * band * (0.0034 + 0.0062 * lane);
    }
    col += float3(0.0013, 0.0021, 0.0037) * (0.5 + 0.5 * exp(-max(rd.y, 0.0) * 7.0));
    return col * fade;
}

inline float3 lv_moonDisk(float3 rd, LvLight L) {
    float mr = 0.262 * LV_DEG;
    if (dot(rd, L.moon) < cos(mr * 30.0)) return float3(0.0);
    float vis = smoothstep(-2.2, 2.0, L.moonEl);
    if (vis <= 0.001) return float3(0.0);
    float3 mu = normalize(cross(float3(0.0, 1.0, 0.0), L.moon));
    float3 mv = cross(L.moon, mu);
    float2 q = float2(dot(rd, mu), dot(rd, mv)) / mr;
    float r2 = dot(q, q), rr = sqrt(r2);
    float3 Tm = mix(float3(1.0), lv_sunTransmit(L.moonEl), 0.55);
    float3 col = float3(0.0);
    float edge = 1.0 - smoothstep(0.90, 1.06, rr);
    if (edge > 0.0) {
        float nz = sqrt(max(1.0 - r2, 0.0));
        float3 N = normalize(q.x * mu + q.y * mv - nz * L.moon);
        float mu0 = max(dot(N, L.sun), 0.0), mue = max(nz, 0.03);
        float lsm = mu0 / (mu0 + mue);
        float maria = 1.0 - 0.30 * smoothstep(0.05, 0.50, fbm(q * 2.1 + 4.0, 4))
                          - 0.07 * gnoise(q * 8.0 + 1.0);
        col += 1.15 * maria * lsm * edge;
    }
    float halo = 0.030 * exp(-max(rr - 0.9, 0.0) * 0.60) + 0.012 * exp(-max(rr - 0.9, 0.0) * 0.11);
    col += halo * float3(0.93, 0.96, 1.0) * (0.20 + 0.80 * L.moonIl);
    return col * Tm * vis;
}

// Full sky radiance for a direction (no clouds), given the atmosphere term.
inline float3 lv_skyFrom(float3 atm, float3 rd, LvLight L, float time) {
    float3 col = atm;
    col += ws_sunDisk(rd, L.sun, 0.268, lv_sunTransmit(L.sunEl) * 34.0
                      * smoothstep(-1.0, 0.4, L.sunEl));
    col += lv_nightSky(rd, L, time);
    col += lv_moonDisk(rd, L);
    return col;
}
inline float3 lv_skyBase(float3 rd, LvLight L, float time) {
    return lv_skyFrom(lv_atmos(rd, L.sun), rd, L, time);
}

// ------------------------------------------------------------------ one depth slab
inline float lv_slab(int i, float3 ro, float3 rd, LvLight L, float pixAng,
                     float3 hazeCol, float mistK, float time, int lod, thread float3 &outCol) {
    if (rd.z > -1e-5) return 0.0;
    float t = (LV_D[i] + ro.z) / (-rd.z);
    if (t <= 1.0) return 0.0;
    float y = ro.y + rd.y * t;
    float fp = max(t * pixAng, 1e-4);
    float hmax = LV_BASE[i] + LV_REL[i] * 1.12 + LV_TH[i] * 1.5;
    if (y > hmax + 3.0 * fp) return 0.0;
    float x = ro.x + rd.x * t;

    float h  = lv_prof(i, x, lod);
    float slope;
    // the silhouette derivative only matters near the edge and under the canopy;
    // deep inside the mass the visible surface is described by the facet noise
    if (lod == 0 && (h + LV_TH[i] * 0.45 - y) < max(5.0 * fp, LV_TH[i] * 1.30)) {
        float e = max(1.1 * fp, LV_HS[i] * 0.0020);
        slope = (lv_prof(i, x + e) - h) / e;
    } else {
        // reflections are smeared by the ripples — a statistical slope is enough
        slope = (LV_REL[i] / LV_HS[i]) * 2.4 * gnoise(float2(x / (LV_HS[i] * 0.16) + 5.0, 3.0 + float(i)));
    }

    float gscale = fp * sqrt(slope * slope + 1.0);
    float covT = smoothstep(-0.55, 0.55, (h - y) / gscale);

    // where forest grows: above the waterline, below the tree line, off the steeps
    float sl0 = LV_SNOW * (1.0 + 0.24 * gnoise(float2(x / 2200.0, 1.7)));
    float dens = 0.0, canopy = 0.0;
    if (LV_TH[i] > 0.0) {
        dens = 0.94 - 0.36 * smoothstep(0.60, 1.8, abs(slope));
        dens *= 0.62 + 0.52 * smoothstep(-0.45, 0.45, gnoise(float2(x / (LV_HS[i] * 0.42), 3.1 + float(i))));
        dens *= smoothstep(0.4, 4.5, h);                              // no trees in the lake
        dens *= 1.0 - smoothstep(sl0 * 0.52, sl0 * 0.80, h);          // tree line
        dens = clamp(dens, 0.0, 0.97);
        canopy = LV_TH[i] * 0.34 * smoothstep(0.15, 0.75, dens)
               * (0.78 + 0.55 * (0.5 + 0.5 * gnoise(float2(x / (LV_TC[i] * 2.4), 7.0 + float(i)))));
    }
    float hc = h + canopy;
    float covC = smoothstep(-0.55, 0.55, (hc - y) / gscale);
    covT = max(covT, covC);

    float tcov = 0.0, tdepth = 0.0;
    if (lod == 0 && dens > 0.02 && covT < 0.999) {
        float sd = lv_trees(i, x, y, h, slope, dens, tdepth);
        tcov = smoothstep(-0.55, 0.55, sd / fp);
    }
    float cov = max(covT, tcov);
    if (cov <= 0.002) return 0.0;

    // ------------- surface -------------
    float alt = max(y, 0.0);
    float below = max(hc - y, 0.0);
    float front = 0.28 + 0.60 * smoothstep(0.0, LV_REL[i] * 0.5, below);
    float fx = x / (LV_HS[i] * 0.055), fy = y / max(LV_REL[i] * 0.22, 9.0);
    float2 fn = (lod == 0) ? float2(fbm(float2(fx + 3.0, fy), 3), gnoise(float2(fx * 0.47 + 21.0, fy * 0.47 + 9.0)))
                           : float2(gnoise(float2(fx + 3.0, fy)), gnoise(float2(fx + 21.0, fy + 9.0)));
    float rough = (i < 2) ? 1.45 : 0.70;
    float3 n = normalize(float3(-slope * 1.05 + fn.x * rough,
                                0.74 + 0.32 * (1.0 - front),
                                front + fn.y * rough * 0.5));

    // rock / scree
    float rn = 0.5 + 0.5 * fn.x;
    float3 alb = mix(ws_hex(0x4A4C50u), ws_hex(0x6E6E6Bu), rn);          // granite / schist
    alb = mix(alb, ws_hex(0x5B5147u), 0.26 * smoothstep(0.35, 0.95, fn.y * 0.5 + 0.5));
    alb = mix(alb, ws_hex(0x3E4A3Cu), 0.30 * smoothstep(0.6, 0.0, alt / max(sl0, 1.0)));  // alpine turf

    // snow — gathers on crests and gentle shoulders above the snow line
    float snow = smoothstep(sl0 - 190.0, sl0 + 200.0, alt);
    snow *= smoothstep(1.95, 0.65, abs(slope));
    snow *= smoothstep(0.92, 0.40, front);
    snow *= 0.28 + 0.72 * smoothstep(-0.50, 0.35, fn.y);     // couloirs / rock ribs
    snow = clamp(snow, 0.0, 1.0);
    alb = mix(alb, float3(0.82, 0.85, 0.90), snow);

    // wet shingle / bleached shoreline just above the waterline
    float shore = (LV_TH[i] > 0.0) ? (1.0 - smoothstep(0.6, 4.2, h)) * (1.0 - smoothstep(2.6, 7.0, alt)) : 0.0;
    alb = mix(alb, ws_hex(0x8B8578u), 0.65 * shore);

    // forest
    float forest = 0.0;
    if (dens > 0.02) {
        forest = clamp(max(tcov, smoothstep(-1.0, 6.0, below) * smoothstep(0.15, 0.6, dens)) * (1.0 - 0.85 * shore), 0.0, 1.0);
        float3 fcol = mix(ws_hex(0x14291Fu), ws_hex(0x2C4A33u), 0.5 + 0.5 * fn.y);
        fcol = mix(fcol, ws_hex(0x415B33u), 0.45 * tdepth);              // sunlit crowns
        fcol = mix(fcol, ws_hex(0x2A3A44u), 0.30 * smoothstep(0.35, 0.85, alt / max(sl0, 1.0)));
        if (lod == 0) fcol *= 0.80 + 0.40 * smoothstep(-0.5, 0.5, gnoise(float2(x / (LV_TC[i] * 2.6), y / (LV_TH[i] * 0.9))));
        alb = mix(alb, fcol, forest * (1.0 - snow * 0.75));
        // canopy breaks the normal up
        n = normalize(mix(n, normalize(n + float3(fn.x * 0.55, 0.30, 0.60)), forest * 0.6));
    }

    // ------------- lighting -------------
    // valley shadow: as the sun drops, the shadow line climbs the slopes
    float shAlt = mix(-120.0, 2950.0, smoothstep(7.0, -1.6, L.sunEl));
    shAlt *= 1.0 + 0.18 * fbm(float2(x / 1700.0 + 4.0, 0.7), 3);
    float sh = smoothstep(shAlt - 120.0, shAlt + 120.0, alt);
    sh = mix(1.0, sh, smoothstep(12.0, 3.0, L.sunEl));

    float ndl = max(dot(n, L.sun), 0.0);
    float ndlM = max(dot(n, L.moon), 0.0);
    float sky = 0.55 + 0.45 * n.y;                           // sky visibility
    float ao = mix(0.55, 1.0, sky) * mix(1.0, 0.72, forest);
    float3 sunH = normalize(float3(L.sun.x, 0.30, L.sun.z));
    float3 Eamb = PI * (1.05 * L.Lz * (0.42 + 0.58 * max(n.y, 0.0))
                      + 0.70 * L.Lh * max(dot(n, sunH), 0.0));

    float3 col = alb * (1.0 / PI) * (L.Esun * ndl * sh + L.Emoon * ndlM * 0.9 + Eamb * ao);
    // translucent snow / forward scatter on backlit ridges
    float rim = pow(max(dot(rd, L.sun), 0.0), 6.0) * smoothstep(0.30, 0.02, abs(dot(n, rd)));
    col += L.Esun * (0.018 + 0.055 * snow) * rim * sh;
    // bounce from the lit valley
    col += alb * L.Esun * 0.016 * (1.0 - n.y) * sh;

    // ------------- aerial perspective -------------
    float3 haze = hazeCol;
    float fa = ws_fogAmount(t, ro, rd, 1.0 / 9500.0, 1.0 / 1500.0);
    float hv = 0.74 + 0.55 * (0.5 + 0.5 * gnoise(float2(rd.x * 9.0, max(rd.y, 0.0) * 34.0) + 2.4));
    fa = 1.0 - pow(max(1.0 - fa, 1e-5), max(hv, 0.18));
    col = mix(col, haze * 1.06, clamp(fa, 0.0, 1.0));

    // ------------- morning mist -------------
    if (mistK > 0.001 && lod == 0) {
        float mf = ws_fogAmount(t, ro, rd, mistK * 0.0042, 1.0 / 30.0);
        float breathe = 0.62 + 0.62 * gnoise(float2(x / 260.0 + time * 0.010, t / 900.0 + 3.0));
        mf = clamp(mf * breathe, 0.0, 1.0);
        float3 mcol = (L.Lz * 2.6 + L.Lh * 1.5 + L.Esun * 0.055) * 0.55;
        col = mix(col, mcol, mf);
    }

    // ------------- the cabin -------------
    if (i == 4) {
        float gc = h + slope * (LV_CABX - x);
        float dx = x - LV_CABX, dy = y - gc;
        float aa = max(fp, 1e-4);
        float wall = min(min((4.3 - abs(dx)), dy + 0.3), 4.9 - dy);
        float rw = 5.3 * (1.0 - clamp((dy - 4.9) / 3.5, 0.0, 1.0));
        float roof = min(min(rw - abs(dx), dy - 4.9), 8.5 - dy);
        float cc = smoothstep(-0.5, 0.5, wall / aa);
        float rc = smoothstep(-0.5, 0.5, roof / aa);
        if (cc + rc > 0.003) {
            float glow = smoothstep(2.0, -4.0, L.sunEl);
            float3 wallCol = ws_hex(0x3B2F25u);
            if (lod == 0) wallCol *= 0.85 + 0.30 * smoothstep(-0.4, 0.4, gnoise(float2(dx * 2.2, dy * 5.5)));
            float3 nW = normalize(float3(0.10, 0.12, 1.0));
            float3 cw = wallCol * (1.0 / PI) * (L.Esun * max(dot(nW, L.sun), 0.0) * sh + L.Emoon * 0.6)
                      * (1.0 / PI) + wallCol * Eamb * (0.7 / PI);
            // windows
            float w1 = min(1.55 - abs(dx + 2.0), 0.85 - abs(dy - 2.6));
            float w2 = min(1.20 - abs(dx - 2.1), 0.80 - abs(dy - 2.6));
            float win = max(smoothstep(-0.5, 0.5, w1 / aa), smoothstep(-0.5, 0.5, w2 / aa));
            float3 lampC = float3(1.0, 0.52, 0.17);
            cw = mix(cw, mix(ws_hex(0x171A1Fu) * 0.4 * Eamb * (0.6 / PI), lampC * 3.4, glow), win);
            // door
            float dr = min(0.62 - abs(dx - 0.1), 1.65 - abs(dy - 1.55));
            cw = mix(cw, mix(wallCol * 0.35 * Eamb * (0.6 / PI), lampC * 0.55, glow * 0.7),
                     smoothstep(-0.5, 0.5, dr / aa) * (1.0 - win));
            float3 roofCol = ws_hex(0x2A2B2Eu);
            float3 nR = normalize(float3(sign(dx) * 0.85, 0.62, 0.30));
            float3 cr = roofCol * (1.0 / PI) * (L.Esun * max(dot(nR, L.sun), 0.0) * sh + L.Emoon * 0.7)
                      * (1.0 / PI) + roofCol * Eamb * (1.05 / PI);
            float faC = ws_fogAmount(t, ro, rd, 1.0 / 9500.0, 1.0 / 1500.0);
            cw = mix(cw, haze * 1.06, faC * 0.9);
            cr = mix(cr, haze * 1.06, faC * 0.9);
            col = mix(col, cw, cc * (1.0 - rc));
            col = mix(col, cr, rc);
            cov = max(cov, max(cc, rc));
        }
    }

    outCol = col;
    return cov;
}

// Sky + slab stack for an arbitrary ray (used for the view and the reflection).
inline float3 lv_stack(float3 ro, float3 rd, LvLight L, float pixAng, float3 hazeCol,
                       float mistK, float time, float calm, bool wantClouds) {
    float3 acc = float3(0.0);
    float trans = 1.0;
    for (int i = LV_N - 1; i >= 2; i--) {
        float3 c = float3(0.0);
        float cv = lv_slab(i, ro, rd, L, pixAng, hazeCol, mistK, time, 1, c);
        if (cv > 0.002) {
            acc += trans * cv * c;
            trans *= 1.0 - cv;
            if (trans < 0.004) break;
        }
    }
    if (trans > 0.004) {
        float3 s = lv_skyBase(rd, L, time);
        if (wantClouds) s = lv_clouds(rd, L, time, s, calm, 1);
        acc += trans * s;
    }
    return acc;
}

// ------------------------------------------------------------------ lake
inline float3 lv_waveNormal(float2 xz, float2 vh, float fpT, float fpL, float time, thread float &residual) {
    float2 g = float2(0.0);
    residual = 0.0;
    float patch = 0.55 + 0.90 * (0.5 + 0.5 * gnoise(xz * 0.055 + float2(time * 0.05, 0.0)));
    float patch2 = 0.50 + 1.00 * (0.5 + 0.5 * gnoise(xz * 0.44 + float2(0.0, time * 0.09)));
    const float LAM[5] = { 24.0, 9.5, 3.9, 1.55, 0.60 };
    const float AMP[5] = { 0.0125, 0.0105, 0.0082, 0.0052, 0.0030 };
    const float SPD[5] = {  0.42,  0.66,  1.00,  1.50,  2.20 };
    const float ANG[5] = {  0.28, -0.44,  0.78, -0.16,  1.02 };
    for (int k = 0; k < 5; k++) {
        float w = TAU / LAM[k];
        float2 dir = float2(cos(ANG[k]), sin(ANG[k]));
        // the lake is seen at a grazing angle: one pixel covers far more ground
        // along the view direction than across it — filter anisotropically
        float c = dot(dir, vh);
        float fpd = sqrt(c * c * fpL * fpL + max(1.0 - c * c, 0.0) * fpT * fpT);
        float damp = 1.0 - smoothstep(LAM[k] * 0.22, LAM[k] * 0.85, fpd);
        if (damp <= 0.003) { residual += AMP[k] * AMP[k] * w * w * 0.5; continue; }
        float pa = (k < 2) ? patch : patch2;
        float ph = dot(xz, dir) * w + time * SPD[k] * w * 0.16 + float(k) * 2.7;
        g += dir * (AMP[k] * pa * w * cos(ph)) * damp;
        if (k < 3) {
            float2 d2 = float2(cos(ANG[k] + 1.9), sin(ANG[k] + 1.9));
            float ph2 = dot(xz, d2) * w * 0.71 - time * SPD[k] * w * 0.11 + float(k) * 1.3;
            g += d2 * (AMP[k] * 0.48 * pa * w * 0.71 * cos(ph2)) * damp;
        }
    }
    residual = sqrt(residual) * 1.25;
    return normalize(float3(-g.x, 1.0, -g.y));
}

// ------------------------------------------------------------------ main
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 uv = fragCoord / ctx.res;
    float time = ctx.time;

    // ---- light rig
    LvLight L;
    L.sun   = normalize(ws_rotY(ctx.sunDir,  -PI * 0.5));
    L.moon  = normalize(ws_rotY(ctx.moonDir, -PI * 0.5));
    L.sunEl = ctx.sunElevation;
    L.moonEl = asin(clamp(L.moon.y, -1.0, 1.0)) / LV_DEG;
    L.moonIl = clamp(ctx.moonIllum, 0.0, 1.0);
    L.night = smoothstep(1.0, -11.0, L.sunEl);
    float3 sunT = lv_sunTransmit(L.sunEl);
    L.Esun = 4.20 * sunT * smoothstep(-1.15, 0.55, L.sunEl);
    float moonPow = pow(L.moonIl, 1.6) * smoothstep(-1.5, 5.0, L.moonEl) * L.night;
    L.Emoon = float3(0.0090, 0.0118, 0.0190) * moonPow;

    float3 Lavg = lv_atmosLite(normalize(float3(L.sun.x * 0.38, 0.92, L.sun.z * 0.38)), L.sun);
    L.Lz = Lavg * float3(0.92, 0.97, 1.08);
    L.Lh = Lavg * mix(float3(1.05, 1.02, 1.0), float3(3.4, 1.55, 0.62), smoothstep(14.0, -0.5, L.sunEl));
    // twilight / night ambient floor so nothing goes to pure black
    float3 nightAmb = float3(0.00075, 0.00118, 0.00215) * L.night
                    + float3(0.0028, 0.0040, 0.0072) * moonPow;
    L.Lz += nightAmb;
    L.Lh += nightAmb * 0.8;

    // ---- camera
    float3 ro = float3(0.0, LV_CAMH, 0.0);
    float pit = LV_PITCH * LV_DEG;
    float3 fwd = float3(0.0, sin(pit), -cos(pit));
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ro + fwd, LV_FOV);
    float pixAng = (LV_FOV * LV_DEG) / ctx.res.y;

    // ---- scheduled effects
    float mistK = smoothstep(4.2, 5.7, ctx.dayTime) * (1.0 - smoothstep(7.9, 9.7, ctx.dayTime));
    mistK *= 0.55 + 0.45 * smoothstep(-6.0, 6.0, L.sunEl);
    float summer = smoothstep(134.0, 152.0, ctx.dayOfYear) * (1.0 - smoothstep(238.0, 258.0, ctx.dayOfYear));
    float fireN = summer * smoothstep(-2.5, -8.5, L.sunEl);

    // ---- base sky in the view direction (also the aerial-perspective colour)
    float calm = 1.0 - 0.30 * smoothstep(0.80, 1.0, uv.y);   // quieter menu-bar strip
    float3 atmView = lv_atmos(rd, L.sun);
    float3 skyCol = lv_skyFrom(atmView, rd, L, time);
    float3 hazeCol = atmView * 1.04
                   + float3(0.0010, 0.0016, 0.0029) * L.night
                   + float3(0.0030, 0.0043, 0.0076) * moonPow;

    // ---- composite near -> far, inserting the lake at its depth
    float3 acc = float3(0.0);
    float trans = 1.0;
    float waterDepth = 1e9, tw = 0.0;
    if (rd.y < -1e-4) { tw = LV_CAMH / (-rd.y); waterDepth = -rd.z * tw; }
    bool waterDone = (waterDepth > 1e8);

    for (int i = LV_N - 1; i >= 0; i--) {
        if (!waterDone && waterDepth < LV_D[i]) break;
        float3 c = float3(0.0);
        float cv = lv_slab(i, ro, rd, L, pixAng, hazeCol, mistK, time, 0, c);
        if (cv > 0.002) {
            acc += trans * cv * c;
            trans *= 1.0 - cv;
            if (trans < 0.004) break;
        }
    }

    if (trans > 0.004 && !waterDone) {
        // ---------------- the lake ----------------
        float3 P = ro + rd * tw;
        float fpW = tw * pixAng;
        float sinG = max(-rd.y, 0.0025);
        float fpL = min(fpW / sinG, 900.0);                 // along the view direction
        float2 vh = normalize(float2(rd.x, rd.z) + 1e-6);
        float resid = 0.0;
        float3 nW = lv_waveNormal(P.xz, vh, fpW, fpL, time, resid);
        // gusts: the ripple field is not uniform
        float gust = 0.55 + 0.75 * fbm(P.xz * 0.0022 + float2(time * 0.0055, 0.0), 3);
        nW = normalize(mix(float3(0.0, 1.0, 0.0), nW, clamp(gust, 0.15, 1.6)));

        float3 R = reflect(rd, nW);
        R.y = max(R.y, 0.0035);
        R = normalize(R);
        float3 refl = lv_stack(P, R, L, pixAng * (1.0 + 2.2 * resid), hazeCol, mistK, time, calm, true);

        float cosI = clamp(dot(-rd, nW), 0.0, 1.0);
        float F = 0.020 + 0.980 * pow(1.0 - cosI, 5.0);

        // body: dark alpine water, sky-lit
        float3 bodyAlb = ws_hex(0x0E2A2Du);
        float3 body = bodyAlb * (L.Lz * 2.0 + L.Lh * 0.35) * 1.4 + bodyAlb * L.Esun * 0.030;
        float3 col = mix(body, refl, F);

        // specular: statistical GGX whose roughness carries the unresolved ripples
        float rgh = clamp(0.045 + resid * 1.25 + 0.035 * (1.0 - gust), 0.035, 0.42);
        float a2 = rgh * rgh * rgh * rgh;
        float3 hv = normalize(L.sun - rd);
        float ndh = max(dot(nW, hv), 0.0);
        float dgx = a2 / (PI * pow(ndh * ndh * (a2 - 1.0) + 1.0, 2.0) + 1e-7);
        float ndv = max(dot(nW, -rd), 0.02), ndlS = max(dot(nW, L.sun), 0.0);
        col += L.Esun * dgx * F * ndlS / (4.0 * ndv + 0.05) * 0.85;
        float3 hm = normalize(L.moon - rd);
        float ndhm = max(dot(nW, hm), 0.0);
        float dgm = a2 / (PI * pow(ndhm * ndhm * (a2 - 1.0) + 1.0, 2.0) + 1e-7);
        col += L.Emoon * dgm * F * max(dot(nW, L.moon), 0.0) / (4.0 * ndv + 0.05) * 6.0;

        // aerial perspective + morning mist on the water
        float fa = ws_fogAmount(tw, ro, rd, 1.0 / 9500.0, 1.0 / 1500.0);
        col = mix(col, hazeCol * 1.06, clamp(fa, 0.0, 1.0));
        if (mistK > 0.001) {
            float mf = ws_fogAmount(tw, ro, rd, mistK * 0.0042, 1.0 / 30.0);
            float breathe = 0.62 + 0.62 * gnoise(float2(P.x / 260.0 + time * 0.010, tw / 900.0 + 3.0));
            mf = clamp(mf * breathe, 0.0, 1.0);
            float3 mcol = (L.Lz * 2.6 + L.Lh * 1.5 + L.Esun * 0.055) * 0.55;
            col = mix(col, mcol, mf);
        }
        acc += trans * col;
        trans = 0.0;
    }

    if (trans > 0.004) acc += trans * lv_clouds(rd, L, time, skyCol, calm, 0);

    float3 col = acc;

    // ---- cabin lamp glow + its smeared reflection in the lake
    {
        float glow = smoothstep(2.0, -4.5, L.sunEl);
        if (glow > 0.003) {
            float3 r0 = normalize(float3(0.0, sin(pit), -cos(pit)));
            float3 rr = normalize(cross(r0, float3(0.0, 1.0, 0.0)));
            float3 uu = cross(rr, r0);
            float3 Pc = float3(LV_CABX, 4.6, -LV_D[4]) - ro;
            float zc = dot(Pc, r0);
            float2 pc = float2(dot(Pc, rr), dot(Pc, uu)) / (zc * tan(LV_FOV * 0.5 * LV_DEG));
            float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
            float2 dq = p - pc;
            float g = exp(-dot(dq, dq) / (0.0090 * 0.0090)) * 0.55
                    + exp(-dot(dq, dq) / (0.055 * 0.055)) * 0.075;
            // reflected column: mirrored vertically, smeared along y by the ripples
            float2 pm = float2(pc.x, -pc.y - 2.0 * (LV_CAMH / (zc)) / tan(LV_FOV * 0.5 * LV_DEG) * 0.0);
            pm.y = pc.y - 2.0 * (pc.y - (-atan(LV_CAMH / zc) / (tan(LV_FOV * 0.5 * LV_DEG))));
            float2 dm = p - pm;
            float glint = exp(-dm.x * dm.x / (0.016 * 0.016)) * exp(-max(dm.y, 0.0) * 14.0)
                        * step(0.0, dm.y * -1.0 + 0.5);
            glint *= 0.35 * (0.6 + 0.4 * sin(time * 1.7 + p.y * 40.0));
            col += float3(1.0, 0.48, 0.15) * glow * (g * 0.85 + max(glint, 0.0) * 0.55);
        }
    }

    // ---- fireflies along the shore
    if (fireN > 0.004) {
        float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
        if (p.x < -0.30 && p.y > -0.42 && p.y < 0.02) {
            float2 q = p * 11.0;
            float2 id = floor(q), f = q - id;
            float3 fl = float3(0.0);
            for (int j = 0; j < 4; j++) {
                float2 o = float2(float(j & 1), float(j >> 1)) - 0.5;
                float4 h = hash24(id + o + 31.0);
                float2 c = o + float2(h.x, h.y) - f + 0.5;
                c.x += 0.22 * sin(time * (0.35 + 0.4 * h.z) + h.w * 9.0);
                c.y += 0.16 * sin(time * (0.27 + 0.3 * h.w) + h.x * 7.0);
                float blink = pow(max(sin(time * (0.9 + 1.3 * h.z) + h.w * 12.0), 0.0), 9.0);
                float d2 = dot(c, c);
                fl += float3(1.0, 0.78, 0.26) * exp(-d2 / 0.0022) * blink * step(h.z, 0.33);
            }
            float band = smoothstep(-0.42, -0.30, p.y) * (1.0 - smoothstep(-0.10, 0.02, p.y));
            col += fl * 0.030 * fireN * band;
        }
    }

    // ---- exposure, tone map, finish
    float expo = 1.45 + 4.30 * smoothstep(1.0, -15.0, L.sunEl);
    expo *= 1.0 + 0.10 * exp(-pow((L.sunEl - 3.0) / 6.0, 2.0));     // lift golden hour
    col *= expo;
    col += float3(0.42, 0.34, 0.28) * 0.0035;                        // veiling glare

    col *= ws_vignette(uv, 0.26);
    float trc = smoothstep(0.52, 1.0, uv.x) * smoothstep(0.58, 1.0, uv.y);
    col *= mix(float3(1.0), float3(0.955, 0.978, 1.035), trc);       // calm icon corner
    col *= 1.0 - 0.075 * smoothstep(0.80, 1.0, uv.y);                // calm menu bar

    col *= float3(0.985, 0.995, 1.025);
    { float Lw = ws_luma(col); col = max(mix(float3(Lw), col, 1.10), 0.0); }
    float3 oA = ws_acesFitted(col);
    float Lc = max(ws_luma(col), 1e-6);
    float3 oL = col * (ws_luma(ws_acesFitted(float3(Lc))) / Lc);
    oL /= max(1.0, max(oL.r, max(oL.g, oL.b)));
    float3 o = mix(oA, oL, 0.40);
    float lo = 1.0 - smoothstep(0.02, 0.55, ws_luma(o));
    o = mix(o, o * float3(0.88, 0.945, 1.20), lo * 0.75);            // cool the shadows
    o += (ws_grain(fragCoord, 0.37) * 0.0050) * (0.4 + 0.6 * sqrt(max(ws_luma(o), 0.0)));
    return clamp(o, 0.0, 1.0);
}
