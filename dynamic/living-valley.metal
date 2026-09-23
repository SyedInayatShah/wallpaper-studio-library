// =====================================================================
//  Living Valley — real-time alpine valley that follows the user's clock.
//  Camera stands on the east shore of a calm lake, facing WEST.
//  Geometry: world-space depth slabs (vertical planes at true distances)
//  composited near -> far with analytic coverage AA; the lake is an exact
//  plane whose reflected ray re-enters the slab stack.  Sun shadows are
//  cast by testing the sun ray against the farther slab profiles.
// =====================================================================

constant float LVD = 0.017453292519943295;
constant float LV_CAMH = 4.0;
constant float LV_FOV  = 36.0;
constant float LV_PITCH = 3.2;     // deg up

constant int   LV_N = 6;
constant float LV_D[6]  = { 16000.0, 7800.0, 3700.0, 1700.0, 560.0, 190.0 };
constant float LV_TH[6] = {     0.0,    0.0,   24.0,   23.0,  25.0,  31.0 };   // tree height (m)
constant float LV_TC[6] = {     1.0,    1.0,   13.0,    6.5,   5.6,   6.0 };   // tree spacing (m)
constant float LV_CABX = -195.0;   // cabin x on the left promontory (slab 4)

struct LvRig {
    float3 sun, moon;
    float sunEl, moonEl;
    float3 Esun, Emoon;
    float3 Lz, Lb;           // sky ambient: zenith and back (east) horizon
    float night, moonPow, moonIl;
    float snowLine;
};

// ------------------------------------------------------------------ sky
inline float3 lv_atmos(float3 rd, float3 sun, int steps) {
    float3 r = normalize(float3(rd.x, max(rd.y, 0.0), rd.z));
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kM = 21e-6;
    float3 r0 = float3(0.0, Rp + 900.0, 0.0);
    float2 p = ws_raySphere(r0, r, Ra);
    p.x = max(p.x, 0.0);
    float iStep = (p.y - p.x) / float(steps);
    float iT = p.x;
    float3 totR = 0.0, totM = 0.0;
    float odR = 0.0, odM = 0.0;
    float mu = dot(r, sun), mumu = mu * mu, g = 0.76, gg = g * g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));
    for (int i = 0; i < steps; i++) {
        float3 iPos = r0 + r * (iT + iStep * 0.5);
        float iH = length(iPos) - Rp;
        float dR = exp(-iH / 8e3) * iStep, dM = exp(-iH / 1.2e3) * iStep;
        odR += dR; odM += dM;
        float2 sg = ws_raySphere(iPos, sun, Rp);
        if (sg.x <= sg.y && sg.x > 0.0) { iT += iStep; continue; }
        float jStep = ws_raySphere(iPos, sun, Ra).y / 3.0;
        float jR = 0.0, jM = 0.0;
        for (int j = 0; j < 3; j++) {
            float jH = length(iPos + sun * (jStep * (float(j) + 0.5))) - Rp;
            jR += exp(-jH / 8e3) * jStep; jM += exp(-jH / 1.2e3) * jStep;
        }
        float3 at = exp(-(kM * (odM + jM) + kR * (odR + jR)));
        totR += dR * at; totM += dM * at;
        iT += iStep;
    }
    float3 tr = exp(-(kR * odR + kM * odM));
    float su = smoothstep(-0.10, 0.30, sun.y);
    float3 ms = mix(float3(1.0, 0.60, 0.42), float3(0.62, 0.78, 1.0), smoothstep(0.00, 0.34, sun.y));
    float hzw = mix(exp(-max(r.y, 0.0) * 3.4), 1.0, smoothstep(0.02, 0.30, sun.y));
    // twilight: a cool blue wash high up keeps the sky from going olive
    float tw = smoothstep(0.10, -0.06, sun.y) * smoothstep(-0.22, -0.04, sun.y);
    float3 twc = float3(0.052, 0.075, 0.150) * tw * (0.35 + 0.65 * smoothstep(-0.05, 0.45, r.y));
    return 21.0 * (pR * kR * totR + pM * kM * totM) + ms * (1.0 - tr) * (0.34 * su * hzw) + twc;
}

inline float3 lv_sunT(float el) {
    float e = max(el, -1.2);
    float am = 1.0 / (sin(max(e, 0.35) * LVD) + 0.15 * pow(e + 3.885, -1.253));
    return exp(-float3(0.105, 0.19, 0.36) * min(am, 34.0));
}

inline float3 lv_clouds(float3 rd, LvRig L, float time, float3 sky, int lod, float calm) {
    if (rd.y < 0.004) return sky;
    float tC = 2600.0 / max(rd.y, 0.030);
    float2 q0 = float2(rd.x, rd.z) * tC / 2400.0 + float2(time * 0.0045, time * 0.0012);
    // a slow domain warp turns the smooth blobs into billowed, hooked cloud masses
    float wv = gnoise(q0 * 0.42 + 11.0);
    // open lanes and crowded belts, and cells that are not all the same oval
    float cover = 0.245 * gnoise(float2(q0.x * 0.085 + 3.0, q0.y * 0.10)) + 0.085 * wv;
    // The cloud field used to live at ~900 px per noise cell, so even its third
    // octave was 200 px across and every edge was a 30 px airbrushed ramp.
    // 2.7x finer puts real structure inside the pixel budget; the drift rate in
    // SCREEN space is unchanged because feature size scales with it.
    const float QS = 2.15;
    float2 q = (q0 + float2(0.40 * wv, 0.26 * wv)) * float2(QS, QS * (1.10 + 0.40 * wv));
    float dc = gnoise(q) * 0.5 + cover;
    if (dc < -0.07) return sky;                      // clearly clear sky: skip the expensive octaves
    float d = fbm(q, lod == 0 ? 3 : 2) + cover;
    if (lod == 0) {
        // Two billow octaves, sheared apart and warped by the mass below, so the
        // edge of a cloud breaks into lobes of several sizes instead of one
        // airbrushed contour.  Strongest near the rim, where a cloud frays.
        float edge = 0.42 + 0.58 * smoothstep(0.52, 0.14, abs(d - 0.38));
        float det = gnoise(float2(q.x * 3.10 + wv * 0.9, q.y * 2.70 - wv * 0.6));
        d += 0.175 * det * edge;
        float det2 = gnoise(float2(q.x * 7.40 - q.y * 2.10 + 1.7 * det,
                                   q.y * 6.30 + q.x * 1.40 - 0.8 * wv));
        d += 0.082 * det2 * edge;
    }
    // firm, sunlit core with a feathered rim
    float aOut = smoothstep(0.300, 0.372, d);
    float a = aOut * (0.45 + 0.55 * smoothstep(0.34, 0.60, d))
            * smoothstep(0.004, 0.05, rd.y) * calm * (0.92 - 0.55 * L.night);
    if (a < 0.002) return sky;
    // cheap sun-ward density tap: brighter where the density falls off toward the sun
    float ds = gnoise(q + float2(L.sun.x, L.sun.z) * float2(0.34, 0.46)) * 0.5 + cover;
    float lit = clamp(0.5 + (dc - ds) * 4.6, 0.0, 1.0);
    // the sun-facing edge of a cloud is a hard bright line, not a soft ramp
    float rim = smoothstep(0.42, 0.95, lit) * smoothstep(0.62, 0.30, d) * aOut;
    float thick = smoothstep(0.28, 0.86, d);
    float sf = max(dot(rd, L.sun), 0.0);
    float silver = pow(sf, 8.0) * 2.4 + pow(sf, 2.0) * 0.45;
    float3 amb = L.Lz * 1.35 + L.Lb * 0.35;
    float3 Ec = 16.0 * lv_sunT(L.sunEl + 2.4) * smoothstep(-5.0, 0.5, L.sunEl);
    // shaded base (cool, sky-lit) -> sunlit top; thick cores keep a heavy grey underside
    float3 cc = amb * (0.46 + 0.46 * (1.0 - thick)) * mix(float3(0.84, 0.89, 1.0), float3(1.0), lit)
              + Ec * (0.026 + 0.19 * lit + 0.16 * rim) * (0.6 + silver) * (1.0 - 0.55 * thick)
              + L.Emoon * 1.6 * (0.5 + lit);
    float hz = smoothstep(0.22, 0.004, rd.y);
    cc = mix(cc, sky, 0.10 + 0.75 * hz);
    return mix(sky, cc, a * (1.0 - 0.5 * hz));
}

inline float3 lv_night(float3 rd, LvRig L, float time, int lod) {
    float fade = smoothstep(-3.0, -11.0, L.sunEl);
    if (fade <= 0.001 || rd.y < -0.01) return 0.0;
    float2 sp = float2(atan2(rd.x, -rd.z), asin(clamp(rd.y, -1.0, 1.0)));
    float3 col = (lod == 0) ? ws_stars(sp * 0.45, 30.0, time * 0.013, 0.25) * 0.28 : float3(0.0);
    float3 g = normalize(float3(-0.62, 0.55, -0.56));
    float b = dot(rd, g);
    float band = exp(-b * b * 16.0);
    if (band > 0.02) {
        float dust = fbm(float2(sp.x * 2.4, sp.y * 4.0) + 3.0, lod == 0 ? 3 : 2);
        float lane = smoothstep(-0.25, 0.45, dust);
        float star = 0.55 + 0.55 * smoothstep(0.1, 0.7, dust * dust);
        col += mix(float3(0.78, 0.85, 1.0), float3(1.0, 0.92, 0.80), 0.4 * lane) * band * (0.0115 + 0.036 * lane * star);
    }
    col *= smoothstep(-0.01, 0.12, rd.y) * 0.8 + 0.2;
    col *= 1.0 - 0.6 * L.moonPow;
    // airglow: the night sky is never truly black
    col += float3(0.0026, 0.0036, 0.0058) * (0.55 + 0.75 * exp(-max(rd.y, 0.0) * 3.5));
    return col * fade;
}

inline float3 lv_moon(float3 rd, LvRig L) {
    float mr = 0.27 * LVD * 1.6;
    float c = dot(rd, L.moon);
    if (c < cos(mr * 40.0)) return 0.0;
    float vis = smoothstep(-1.5, 1.5, L.moonEl);
    if (vis <= 0.001) return 0.0;
    float3 mu = normalize(cross(float3(0, 1, 0), L.moon));
    float3 mv = cross(L.moon, mu);
    float2 q = float2(dot(rd, mu), dot(rd, mv)) / mr;
    float r2 = dot(q, q), rr = sqrt(r2);
    float3 col = 0.0;
    float edge = 1.0 - smoothstep(0.93, 1.05, rr);
    if (edge > 0.0) {
        float nz = sqrt(max(1.0 - r2, 0.0));
        float3 N = normalize(q.x * mu + q.y * mv - nz * L.moon);
        // terminator from the real phase: light direction around the limb
        float ci = clamp(2.0 * L.moonIl - 1.0, -1.0, 1.0);
        float3 perp = normalize(L.sun - dot(L.sun, L.moon) * L.moon + float3(1e-4, 0.0, 0.0));
        float3 sdir = ci * (-L.moon) + sqrt(max(1.0 - ci * ci, 0.0)) * perp;
        float lam = smoothstep(-0.03, 0.10, dot(N, sdir));
        float maria = 1.0 - 0.32 * smoothstep(0.0, 0.5, fbm(q * 1.8 + 4.0, 4));
        col += 1.25 * maria * lam * edge + 0.004 * edge;   // faint earthshine
    }
    float gl = max(rr - 0.95, 0.0);
    col += (0.022 * exp(-gl * 0.9) + 0.008 * exp(-gl * 0.12)) * (0.15 + 0.85 * L.moonIl) * float3(0.92, 0.96, 1.0);
    return col * vis * mix(float3(1.0), lv_sunT(L.moonEl), 0.6);
}

// ------------------------------------------------------------------ rock relief
// Multi-scale relief whose gradient becomes the rock normal.  Three octaves at
// deliberately incommensurate frequencies, each warped by the one below and
// stretched along a DIFFERENT axis (fall-line ribs / oblique crags / lateral
// strata), so no single pitch can dominate and read as a comb.  a2/a3 are
// band-limited by the caller from the pixel footprint: an octave fades out
// before its period approaches ~3 px, which is both cheaper and alias-free.
inline float lv_relief(float2 q, float wa, float wb, float a2, float a3) {
    // 1 — buttresses and gullies, stretched down the fall line.  A softened
    //     ridge (sharp crests, rounded troughs) is what erosion leaves behind.
    float2 p1 = float2(q.x * 0.86 + 0.85 * wa, q.y * 0.50 + 0.44 * wb);
    float g1 = gnoise(p1);
    float v = 1.55 * (0.34 - sqrt(g1 * g1 + 0.045));
    // 2 — oblique crags: sheared ~30 deg off the fall line and warped by 1, so
    //     its pitch never lines up with the ribs above it
    if (a2 > 0.004) {
        float2 p2 = float2(q.x * 2.90 + q.y * 1.70 + 1.20 * v,
                           q.y * 2.20 - q.x * 1.10 + 0.40 * wa);
        v += a2 * gnoise(p2);
    }
    // 3 — crag texture near the pixel footprint, sheared the OTHER way and
    //     warped again; this is what keeps the face from reading as clay
    if (a3 > 0.004) {
        float2 p3 = float2(q.x * 4.50 - q.y * 2.20 + 2.20 * v,
                           q.y * 3.70 + q.x * 1.70 + 1.10 * wb);
        v += a3 * gnoise(p3);
    }
    return v;
}

// ------------------------------------------------------------------ profiles (height above lake, m)
// lod 0: full detail (view), 1: medium (reflections / slopes), 2: macro only (shadow rays)
inline float lv_prof(int i, float x, int lod) {
    if (i == 0) {
        float dx = x + 2300.0;
        // Asymmetric massif: a long shoulder falling away to the north (left),
        // a markedly steeper south face — not a symmetric tent.
        // The decay length is blended SMOOTHLY across the summit and |dx| is
        // rounded: on a 2.5-D slab the profile's x-derivative is the shading
        // normal, so any kink in x paints a hard seam down the entire face.
        float sx = sqrt(dx * dx + 26000.0);                       // ~160 m rounding
        float decay = mix(1600.0, 2420.0, smoothstep(700.0, -700.0, dx));
        float m = 2810.0 * exp(-sx / decay) * (0.58 + 0.42 * exp(-dx * dx / 7.4e6));
        m += 560.0 * exp(-pow((x + 1820.0) / 520.0, 2.0));      // south shoulder
        m += 620.0 * exp(-pow((x + 3820.0) / 880.0, 2.0));      // subsidiary peak
        m -= 470.0 * exp(-pow((x + 3060.0) / 330.0, 2.0));      // the col between them
        m += 230.0 * exp(-pow((x + 640.0) / 640.0, 2.0));       // lower buttress
        float a1 = (x + 8300.0) / 2900.0, a2 = (x - 3500.0) / 2500.0, a3 = (x - 8200.0) / 3200.0;
        m += 1450.0 * exp(-a1 * a1) + 1150.0 * exp(-a2 * a2) + 750.0 * exp(-a3 * a3);
        m = max(m, 0.0);
        if (lod >= 2) return 520.0 + m * 1.02;
        float r = ridged(float2(x / 2000.0, 1.7), lod > 0 ? 2 : 3);
        float h0 = 520.0 + m * (0.78 + 0.30 * r) + 260.0 * (r - 0.5);
        // mid-scale crest relief: notches, gendarmes and sub-summits on the skyline
        h0 += 215.0 * (ridged(float2(x / 560.0, 3.9), lod > 0 ? 1 : 2) - 0.46) * smoothstep(400.0, 1500.0, m);
        if (lod == 0) h0 += 62.0 * gnoise(float2(x / 165.0, 5.7)) * smoothstep(700.0, 1600.0, h0);
        return h0;
    }
    if (i == 1) {
        float b1 = (x + 6500.0) / 1900.0, b2 = (x - 3500.0) / 1500.0, b3 = (x - 900.0) / 1100.0;
        float m = 720.0 * exp(-b1 * b1) + 650.0 * exp(-b2 * b2) + 330.0 * exp(-b3 * b3);
        if (lod >= 2) return 210.0 + m;
        float r = ridged(float2(x / 1500.0, 7.3), lod > 0 ? 2 : 3);
        float h1 = 150.0 + m * (0.7 + 0.45 * r) + 130.0 * r;
        h1 += 66.0 * (ridged(float2(x / 340.0, 2.1), lod > 0 ? 1 : 2) - 0.46) * smoothstep(110.0, 480.0, m);
        if (lod == 0) h1 += 26.0 * gnoise(float2(x / 120.0, 9.3));
        return h1;
    }
    if (i == 2) {
        float w = abs(x + 150.0) / 1150.0;
        float base = 25.0 + 250.0 * smoothstep(0.25, 1.1, w) + 60.0 * smoothstep(0.6, 1.2, w);
        float c1 = (x + 1250.0) / 520.0, c2 = (x - 1500.0) / 700.0;
        base += 120.0 * exp(-c1 * c1) + 95.0 * exp(-c2 * c2);
        if (lod >= 2) return base;
        float f = fbm(float2(x / 640.0, 3.1), lod > 0 ? 2 : 4);
        return base + 85.0 * f * (1.0 + 0.4 * smoothstep(0.25, 1.1, w));
    }
    if (i == 3) {
        float f = (lod >= 2) ? 0.0 : gnoise(float2(x / 380.0, 5.3));
        return 3.5 + 5.0 * (0.5 + 0.5 * f) + 36.0 * smoothstep(320.0, 750.0, abs(x + 60.0));
    }
    if (i == 4) {
        float f = (lod >= 2) ? 0.0 : fbm(float2(x / 60.0, 9.1), 2);
        float lft = smoothstep(-150.0, -212.0, x);
        float rgt = smoothstep(222.0, 262.0, x);
        float g = 3.5 + 3.0 * f + 13.0 * smoothstep(-235.0, -330.0, x) + 9.0 * smoothstep(260.0, 340.0, x);
        return mix(-5.0, g, max(lft, rgt));
    }
    float f = (lod >= 2) ? 0.0 : gnoise(float2(x / 11.0, 1.3));
    return mix(-8.0, 2.2 + 1.4 * f + 0.10 * max(-52.0 - x, 0.0), smoothstep(-30.0, -62.0, x));
}

// cheap smooth 1-D value noise — a full gnoise is wasted on per-cell clumping
inline float lv_vn1(float u, float sd) {
    float i0 = floor(u), f = u - i0;
    f = f * f * (3.0 - 2.0 * f);
    return mix(hash12(float2(i0, sd)), hash12(float2(i0 + 1.0, sd)), f);
}

// Spruce silhouette: signed horizontal distance (m, + inside).  s = metres below the tip.
inline float lv_spruce(float dx, float s, float4 h, float fp, thread float &tierOut) {
    if (s < 0.0) { tierOut = 0.0; return 1.5 * s - abs(dx); }
    float side = dx > 0.0 ? 1.0 : -1.0;
    dx -= (h.x - 0.5) * 0.105 * s;                                   // trees lean
    float env = max(0.05 + 0.010 * s, (0.105 + 0.105 * h.z) * (s - 0.30 - 0.7 * h.w));
    env *= 1.0 - 0.18 * smoothstep(0.0, 4.0, s) * (1.0 - smoothstep(4.0, 9.0, s));   // slight waist
    float sp = (0.30 + 0.020 * s) * (0.8 + 0.45 * h.y);
    float q = max(s - 0.4, 0.0) / sp + h.w * 3.0;
    float ph = fract(q), n = floor(q);
    float hb = hash12(float2(n + h.x * 131.0, side + h.y * 71.0));
    float hc = hash12(float2(n * 1.7 + h.z * 37.0, side * 3.0 + 5.0));
    float lb = hb < 0.10 ? 0.55 : 0.80 + 0.32 * hb;            // missing / long branches
    float tier = lb * (0.70 + 0.30 * pow(ph, 0.7)) * (1.0 - 0.22 * smoothstep(0.86, 1.0, ph));
    float detail = 1.0 - smoothstep(sp * 0.35, sp * 1.2, fp);
    float fine = 1.0 - smoothstep(0.045, 0.16, fp);            // needle-scale raggedness
    float w = env * mix(0.86, tier, detail);
    w *= 1.0 + detail * fine * 0.16 * (hc - 0.5) * 2.0;
    float trunk = (s > 6.0 && hc < 0.5) ? ((0.035 + 0.006 * s) - abs(dx)) : -1e3;   // bare trunk
    tierOut = mix(0.55, ph, detail);
    return max(w - abs(dx), trunk);
}

// one row of spruces on slab i. returns coverage.
inline float lv_forest(int i, float seed, float x, float y, float g, float slope, float dens, float hs, float fp,
                       thread float &nx, thread float &tier, thread float &tip) {
    float cell = LV_TC[i], H = LV_TH[i] * hs;
    float best = -1e9;
    nx = 0.0; tier = 0.5; tip = 0.0;
    float ci = floor(x / cell);
    for (int k = -1; k <= 1; k++) {
        float id = ci + float(k);
        float4 h = hash24(float2(id, seed));
        if (h.x > dens) continue;
        float cx = (id + 0.5 + (h.y - 0.5) * 0.85) * cell;
        // groves and clearings: a low-frequency field makes stands of tall trees
        // and thin, stunted patches instead of one uniform saw-tooth
        float clump = 0.55 + 0.80 * lv_vn1(id * 0.091, seed * 0.7);
        float th = H * clump * (0.42 + 0.72 * h.z * (0.6 + 0.6 * h.w) + (h.w > 0.93 ? 0.30 : 0.0));
        float s = g + clamp(slope, -1.2, 1.2) * (cx - x) + th - y;
        float tr;
        float d = lv_spruce(x - cx, s, h, fp, tr);
        if (d > best) {
            best = d;
            float env = max(0.05 + 0.010 * s, 0.17 * s) + 1e-3;
            nx = clamp((x - cx) / env, -1.0, 1.0);
            tier = tr; tip = clamp(1.0 - s / th, 0.0, 1.0);
        }
    }
    return smoothstep(-0.6, 0.6, best / fp);
}

// cheap canopy top (spike train) — distant forest and reflections
inline float lv_canopy(float x, float cell, float H, float dens, float seed, float fp, bool clumpOn) {
    float id0 = floor(x / cell);
    float detail = smoothstep(cell * 0.9, cell * 0.32, fp);     // fade the serration when a cell is sub-pixel
    float top = 0.0;
    // two neighbouring cells, so the profile is continuous across cell walls (no vertical steps)
    for (int k = 0; k <= 1; k++) {
        float id = id0 + float(k);
        float4 h = hash24(float2(id, seed));
        float cx = (id - 0.5 + (h.y - 0.5) * 0.5) * cell;
        float clump = clumpOn ? (0.55 + 0.80 * lv_vn1(id * 0.091, seed * 0.7)) : 1.0;
        float th = H * clump * (0.5 + 0.6 * h.z) * step(h.x, dens + 0.05);
        float spike = max(0.0, 1.0 - abs(x - cx) / (cell * (0.52 + 0.55 * h.w)));
        top = max(top, th * mix(0.45, spike, detail));
    }
    return top;
}

// ------------------------------------------------------------------ shadows from farther slabs
inline float lv_shadow(int i, float3 P, LvRig L, int lod) {
    if (L.sunEl < -1.5) return 0.0;
    if (L.sunEl > 26.0) return 1.0;                  // no ridge can shade anything with the sun this high
    float3 s = L.sun;
    float vis = 1.0;
    if (s.z < -0.03) {
        int jn = min(i, 2);                          // only the big ranges cast meaningful shadows
        for (int j = 0; j < jn; j++) {
            float tt = (LV_D[j] + P.z) / (-s.z);
            float yy = P.y + s.y * tt;
            const float SH_MAX[3] = { 4200.0, 1850.0, 690.0 };
            if (yy > SH_MAX[j] || tt <= 0.0) continue;
            float hj = lv_prof(j, P.x + s.x * tt, 2) + LV_TH[j] * 0.6;
            float pen = 8.0 + tt * 0.02;
            vis = min(vis, smoothstep(-pen, pen, yy - hj));
        }
    } else {
        // sun behind the camera: an unseen eastern ridge ~2.5 km behind, ~520 m high
        float tt = (2500.0 - P.z) / max(s.z, 0.03);
        float yy = P.y + s.y * tt;
        vis = smoothstep(-60.0, 60.0, yy - 520.0 - 110.0 * gnoise(float2((P.x + s.x * tt) / 900.0, 4.0)));
    }
    return vis;
}

// ------------------------------------------------------------------ one slab
inline float lv_slab(int i, float3 ro, float3 rd, LvRig L, float pixAng, float3 hazeCol,
                     float mistK, float time, int lod, thread float3 &outCol) {
    if (rd.z > -1e-5) return 0.0;
    float t = (LV_D[i] + ro.z) / (-rd.z);
    if (t <= 1.0) return 0.0;
    float y = ro.y + rd.y * t;
    const float HMAX[6] = { 4300.0, 1900.0, 700.0, 105.0, 80.0, 70.0 };
    if (y > HMAX[i] || y < -0.5) return 0.0;
    float fp = max(t * pixAng, 1e-3);
    float x = ro.x + rd.x * t;

    float TH = LV_TH[i];
    float p2 = 0.0;
    if (i <= 2) {
        const float MARG[3] = { 620.0, 320.0, 130.0 };
        p2 = lv_prof(i, x, 2);
        if (y > p2 + MARG[i] + TH * 1.5) return 0.0;
    }
    float h = lv_prof(i, x, lod);
    if (y > h + TH * 1.5 + 2.0 * fp) return 0.0;
    float e = max(fp * 2.0, 0.003 * LV_D[i]);
    int slod = (lod > 0 || i <= 2) ? 2 : 1;
    float sref = (slod == 2 && i <= 2) ? p2 : lv_prof(i, x - e, slod);
    float slope = (lv_prof(i, x + e, slod) - sref) / ((slod == 2 && i <= 2) ? e : 2.0 * e);
    slope = clamp(slope, -8.0, 8.0);
    float gs = fp * clamp(sqrt(1.0 + slope * slope), 1.0, 4.0);
    float covG = smoothstep(-0.6, 0.6, (h - y) / gs);

    // ------- forest density & canopy layers
    float dens = 0.0;
    if (TH > 0.0) {
        dens = 0.95 - 0.35 * smoothstep(0.8, 1.7, abs(slope));
        dens *= 0.86 + 0.2 * gnoise(float2(x / (LV_TC[i] * 7.0), 3.0 + float(i)));
        dens *= smoothstep(0.6, 2.4, h);
        if (i == 5) dens *= smoothstep(-46.0, -66.0, x);
        dens = clamp(dens, 0.0, 0.98);
    }
    float covB = 0.0, covT = 0.0, covF = 0.0;
    float ftn = 0.0, ftier = 0.5, ftip = 0.0;
    bool spires = false;
    float bodyTop = h;
    if (dens > 0.02) {
        // back canopy (cheap spikes, shadowed mass behind the front trees)
        float cb = lv_canopy(x, LV_TC[i] * 0.8, TH * 0.95, dens, 41.0 + float(i), fp, false);
        bodyTop = h + min(TH * 0.26 * smoothstep(0.3, 0.8, dens) + cb * 0.55, TH * 0.78);
        covB = (i == 5) ? 0.0 : smoothstep(-0.6, 0.6, (bodyTop - y) / gs);
        if ((lod == 0 && i >= 3) || (lod == 1 && i == 5)) {
            spires = true;
            covT = lv_forest(i, 17.0 + float(i), x, y, h + 1.0, slope, dens, 1.0, fp, ftn, ftier, ftip);
            if (i == 5 && lod == 0) {
                // a second, nearer row lower on the bank
                float n2, t2, p2;
                covF = lv_forest(i, 29.0 + float(i), x + LV_TC[i] * 0.37, y, h - 1.2, slope, dens * 0.8, 0.9, fp, n2, t2, p2);
                if (covF > 0.5 * covT) { ftn = n2; ftier = t2; ftip = p2; }
                covT = max(covT, covF);
            }
        } else {
            float ct = lv_canopy(x + LV_TC[i] * 0.5, LV_TC[i], TH * 1.25, dens, 17.0 + float(i), fp, true);
            covT = smoothstep(-0.6, 0.6, (h + ct - y) / gs) * step(0.001, ct);
            ftier = 0.55; ftip = 0.5;
        }
    }
    float cov = max(max(covG, covB), covT);

    // ------- cabin (slab 4)
    float cabin = 0.0, cabRoof = 0.0, cabWin = 0.0, cabEave = 0.0;
    if (i == 4) {
        float dx = x - LV_CABX;
        if (abs(dx) < 16.0) {
            float clr = smoothstep(8.0, 14.0, abs(dx));
            covT *= clr; covB = mix(smoothstep(-0.6, 0.6, (h + 0.6 - y) / gs), covB, clr);
            float gc = lv_prof(4, LV_CABX, 1);
            float dy = y - gc;
            // big enough that the gable roof reads as a building, not a light
            float wall = min(min(6.2 - abs(dx), dy + 0.7), 4.4 - dy);
            float rw = 7.4 - (dy - 4.3) * 1.30;
            float roof = min(min(rw - abs(dx), dy - 4.2), 8.9 - dy);
            float chim = min(0.55 - abs(dx - 3.3), min(dy - 5.6, 10.2 - dy));
            cabin = smoothstep(-0.5, 0.5, wall / fp);
            cabRoof = max(smoothstep(-0.5, 0.5, roof / fp), smoothstep(-0.5, 0.5, chim / fp));
            cabEave = smoothstep(0.9, 0.0, abs(dy - 4.25) / max(fp, 0.02)) * cabRoof;
            float w1 = min(0.92 - abs(dx + 2.7), 0.78 - abs(dy - 2.05));
            float w2 = min(0.92 - abs(dx - 2.9), 0.78 - abs(dy - 2.05));
            cabWin = smoothstep(-0.5, 0.5, max(w1, w2) / fp) * cabin * (1.0 - cabRoof);
            cov = max(max(max(covG, covB), covT), max(cabin, cabRoof));
        }
    }
    if (cov <= 0.002) return 0.0;

    float3 P = float3(x, y, -LV_D[i]);
    float sh = (lod == 0) ? lv_shadow(i, P, L, lod) : smoothstep(-1.5, 3.0, L.sunEl);
    float sdv = max(dot(rd, L.sun), 0.0);
    float sunBack = sdv * sdv; sunBack *= sunBack * sdv;      // ^5, broad aureole for haze
    float sunRim = sunBack * sunBack * sunBack;               // ^15, tight rim on silhouettes

    // ------- rock / snow / meadow
    float3 col;
    float fzOut = 0.0, velOut = 0.0, r0Out = 0.5;
    {
        float r0 = 0.5, rx = 0.0, ry = 0.0, rfine = 0.0, rlow = 0.0;
        float rscale = (i == 0 ? 300.0 : (i == 1 ? 190.0 : 110.0));
        float2 fq = float2(x, y) / rscale;
        if (i <= 1) {
            float wa = gnoise(fq * 0.37), wb = wa * wa * 1.7 - 0.7;
            rlow = wa;
            float2 wq = float2(fq.x + 0.45 * wa, fq.y * 0.38);
            if (lod == 0) {
                r0 = ridged(wq, 2);                       // couloirs: elongated down the fall line
                // band-limit the two fine octaves by the pixel footprint so neither
                // can beat against the sampling grid into a regular comb
                float fpq = fp / rscale;
                float a2 = 0.26 * (1.0 - smoothstep(0.090, 0.190, fpq));
                float a3 = (i == 0 ? 0.090 : 0.060) * (1.0 - smoothstep(0.045, 0.090, fpq));
                float ee = 0.045;
                float g0 = lv_relief(fq, wa, wb, a2, a3);
                rx = clamp((lv_relief(fq + float2(ee, 0.0), wa, wb, a2, a3) - g0) / ee * 0.62, -2.6, 2.6);
                ry = clamp((lv_relief(fq + float2(0.0, ee), wa, wb, a2, a3) - g0) / ee * 0.48, -2.6, 2.6);
                rx += (r0 - 0.45) * 1.05;
                rfine = g0 * 1.15;
            } else {
                r0 = 0.42 + 0.30 * gnoise(wq);
            }
        } else if (lod == 0) {
            float ee = 0.09;
            r0 = 0.5 + 0.5 * gnoise(fq);
            rx = clamp((gnoise(fq + float2(ee, 0.0)) * 0.5 + 0.5 - r0) / ee, -2.0, 2.0);
            ry = clamp((gnoise(fq + float2(0.0, ee)) * 0.5 + 0.5 - r0) / ee, -2.0, 2.0);
        }
        float facet = (i <= 1) ? 1.00 : (i == 2 ? 0.26 : 0.14);
        float fzs = (i == 1) ? smoothstep(L.snowLine * 0.60, L.snowLine * 0.34, y) : (i >= 2 ? 1.0 : 0.0);
        float facL = mix(facet, facet * 0.32, fzs);
        float3 n = normalize(float3(-slope * 0.95 - rx * facL, 0.50 - ry * facL * 0.40 + 0.20 * r0, i <= 1 ? 0.72 : 1.0));
        float sl = L.snowLine * (1.0 + 0.08 * gnoise(float2(x / 1500.0, 1.0)));
        float alt = y + 115.0 * (r0 - 0.5);
        // Alpine gneiss is DARK — a 16 km haze path already washes half the
        // contrast out of it, so a mid-grey albedo arrives as white plaster.
        float3 rock = mix(ws_hex(0x343238u), ws_hex(0x55503Fu), clamp(smoothstep(0.06, 0.90, r0) + 0.09 * rfine, 0.0, 1.0));
        rock = mix(rock, ws_hex(0x2E2A26u), 0.30 * smoothstep(0.45, 0.85, fract(r0 * 3.7)));
        // lichen / scree / strata: real alpine rock is not one flat blue-grey wash
        if (i <= 1 && lod == 0) {
            rock = mix(rock, ws_hex(0x565A44u), 0.32 * smoothstep(0.10, 0.85, rfine));
            rock = mix(rock, ws_hex(0x24232Au), 0.34 * smoothstep(-0.10, -0.70, rfine));
        }
        rock = mix(rock, ws_hex(0x3A4030u), 0.50 * smoothstep(sl * 0.78, sl * 0.40, alt));   // alpine turf
        float snow = 0.0;
        if (i <= 1) {
            // one signed snow field, thresholded near-hard: snow either lies or it does not.
            // altitude + couloirs (snow fills, ribs stay bare) + ledge angle + crag break-up.
            // altitude and ledge angle decide where snow LIES; the noise only
            // ragged-edges it.  Letting the noise dominate spots the face.
            // A LOW-frequency field has to carry the snow line, or the face
            // breaks into worms of snow and rock instead of coherent fields.
            // Altitude only biases; what really decides is whether the ledge is
            // flat enough to HOLD snow (n.y) and whether it is a gully or a rib.
            // A steep face stays bare rock hundreds of metres above the snow line.
            // The ledge angle must come from the MACRO form, not from the fine
            // relief normal: feeding the high-frequency normal into the snow
            // decision alternates snow and rock every few pixels and the face
            // turns to popcorn.  Big coherent snowfields, ragged at their edges.
            float mx = -slope * 0.95, my = 0.50 + 0.20 * rlow;
            float nyMac = my * rsqrt(mx * mx + my * my + 0.5184);
            float snowF = (alt - sl) / 900.0 - 0.85
                        + (nyMac - 0.40) * 4.0
                        + rlow * 1.05
                        + (0.55 - r0) * 1.35
                        + rfine * 0.26;
            float sw = 0.13 + fp / 210.0;                              // pixel-footprint AA
            snow = smoothstep(-sw, sw, snowF);
            snow = clamp(snow * (0.30 + 0.95 * smoothstep(sl - 20.0, sl + 800.0, y)), 0.0, 1.0);
        }
        float3 alb = mix(rock, float3(0.80, 0.825, 0.875), snow);
        float fz = 0.0;
        if (i == 1) fz = smoothstep(sl * 0.60, sl * 0.34, y + 130.0 * gnoise(float2(x / 620.0, y / 420.0)));
        if (i >= 2) {
            // |slope| is a function of x alone, so using it raw paints perfectly
            // vertical bands down the hillside; jitter it with a 2-D field first
            float sj = (lod == 0) ? gnoise(float2(x / 95.0, y / 62.0)) : 0.0;
            fz = 1.0 - 0.6 * smoothstep(1.4, 2.4, abs(slope) * (0.80 + 0.45 * sj) + 0.35 * sj);
        }
        float vel = 0.0;
        if (lod == 0 && i <= 2 && fz > 0.02) {
            float cs = (i == 1) ? 60.0 : 30.0;
            vel = gnoise(float2(x / cs, y / (cs * 0.8))) * 0.55 + 0.45 * gnoise(float2(x / (cs * 4.0) + 7.0, y / (cs * 3.0)));
            vel *= (i == 1) ? 0.85 : 0.95;
        }
        fzOut = fz; velOut = vel; r0Out = r0;
        float3 fcol = mix(ws_hex(0x0D1512u), ws_hex(0x1F2E1Bu), smoothstep(-0.6, 0.7, vel));
        fcol *= 0.86 + 0.24 * smoothstep(-0.55, 0.55, vel);
        alb = mix(alb, fcol, fz * (1.0 - snow));
        float shoreB = (i >= 3) ? (1.0 - smoothstep(0.35, 1.3, y)) * covG : 0.0;
        alb = mix(alb, ws_hex(0x6F6A5Du), shoreB * 0.85);
        float ndl = max(dot(n, L.sun), 0.0);
        if (i <= 1) {
            // Wrapped diffuse.  A 2.5-D slab has a hard crease at every ridge
            // crest, and snow/rock are rough enough to scatter well past the
            // geometric terminator — without this the shaded face flips
            // between lit and black pixel by pixel and reads as zebra stripes.
            // A light wrap softens the 2.5-D slab's hard crest crease and models
            // the rough scattering of snow and shattered rock past the geometric
            // terminator — but only lightly, or the whole face flattens to plaster.
            float dl = (dot(n, L.sun) + 0.06) / 1.06;
            ndl = max(dl, 0.0); ndl *= ndl * 1.02;
        }
        float ao = mix((i <= 1) ? 0.82 : 0.45, 1.0, clamp(r0 * 1.25, 0.0, 1.0));
        // gullies and the undercut side of every buttress sit in their own shade;
        // without it the relief is a pure shading gradient and reads as modelled clay
        if (i <= 1) ao *= 0.70 + 0.44 * smoothstep(-0.85, 0.10, rfine);
        float3 E = L.Esun * ndl * sh + L.Emoon * max(dot(n, L.moon), 0.0) * 1.3
                 + PI * (L.Lz * (0.35 + 0.45 * n.y) + L.Lb * 0.45 * n.z) * ao * (1.0 + 1.45 * snow);
        // Snow is a near-white diffuser under a huge bright sky: when the peak is
        // backlit the snowfields stay clearly visible while the rock goes to
        // silhouette.  Without this the whole summit flattens to one blue shape.
        if (i <= 1) E += PI * mix(L.Lz * 1.2, hazeCol, 0.45) * snow * 0.70 * (1.0 - 0.55 * L.night) * (0.35 + 0.65 * max(n.y, 0.0));
        col = alb * E / PI;
        col += L.Esun * sh * sunRim * 0.045 * (snow + 0.25) * smoothstep(5.0 * gs, 0.0, h - y);
        if (i <= 1) {
            float hi = smoothstep(L.snowLine * 0.55, L.snowLine * 1.15, y);
            // alpenglow: the reddened light of the low sun wraps onto the high faces
            float wrap = max(dot(n, L.sun) * 0.5 + 0.5, 0.0);
            float lowSun = smoothstep(9.0, -1.0, L.sunEl) * smoothstep(-2.5, 1.0, L.sunEl);
            col += alb * L.Esun * sh * wrap * wrap * lowSun * 0.55 * hi * float3(1.0, 0.62, 0.42);
            // snow is strongly forward-scattering: with the sun behind the ridge the
            // snowfields transmit a warm glow instead of going flat black
            float back = max(-dot(n, L.sun), 0.0);
            col += alb * L.Esun * sh * snow * back * back * 0.085
                 * smoothstep(10.0, -3.0, L.sunEl) * hi * float3(1.0, 0.70, 0.46);
        }
    }

    // ------- trees (silhouette spires, the canopy behind them, and closed forest on the slopes)
    float canopyIn = (i >= 2) ? covG * fzOut : 0.0;
    float tw = clamp(max(max(covT, covB * (1.0 - covG)), canopyIn) / max(cov, 1e-3), 0.0, 1.0);
    if (tw > 0.0 && TH > 0.0) {
        bool front = spires && covT > 0.5;
        float nxx = front ? ftn : 0.0;
        float3 n = normalize(float3(nxx * 0.8 - (front ? 0.0 : slope * 0.7),
                                    0.30 + 0.30 * ftip + (front ? 0.0 : 0.25),
                                    sqrt(max(1.0 - nxx * nxx * 0.64, 0.05))));
        float var = hash12(float2(floor(x / LV_TC[i]), 5.0 + float(i)));
        float3 alb = mix(ws_hex(0x0E1A11u), ws_hex(0x1C3020u), front ? var : (0.5 + 0.5 * velOut));
        float tr = front ? ftier : (0.45 + 0.35 * (0.5 + 0.5 * velOut));
        alb *= 0.55 + 0.6 * tr;
        float ndl = max(dot(n, L.sun), 0.0);
        // light falls on the crown and is eaten by the canopy lower down: this is what
        // turns a flat green silhouette into a tree with volume
        float occ = front ? (0.34 + 0.70 * ftip * ftip) : (0.55 + 0.35 * (0.5 + 0.5 * velOut));
        float3 E = L.Esun * ndl * sh * (0.3 + 0.7 * tr) * occ * float3(1.10, 1.00, 0.84)
                 + L.Emoon * max(dot(n, L.moon), 0.0) * occ
                 + PI * (L.Lz * (0.33 + 0.52 * ftip) + L.Lb * 0.46 * n.z) * (0.42 + 0.58 * tr) * occ;
        float3 tc = alb * E / PI;
        float edgeK = 1.0 - abs(covT - 0.5) * 2.0;
        // the bright sky shines through the needles right at the silhouette
        tc += hazeCol * edgeK * (0.25 + 0.75 * ftip) * 0.18 * (front ? 1.0 : 0.0);
        tc += L.Esun * sh * sunRim * 0.016 * edgeK * (front ? 1.0 : 0.3) * float3(1.0, 0.80, 0.45);
        if (front && fp < 0.25) {
            // sunlit needle sparkle and a soft sky-blue wash on the shaded side
            float nd = max(dot(n, L.sun), 0.0);
            float gl = 0.5 + 0.5 * gnoise(float2(x * 2.6, y * 2.2) + var * 31.0);
            tc += alb * L.Esun * sh * nd * gl * 0.30;
            tc += float3(0.26, 0.38, 0.58) * L.Lz * (1.0 - nd) * 0.10;
        }
        col = mix(col, tc, tw);
    }

    // ------- cabin shading
    if (cabin + cabRoof > 0.002) {
        float glow = smoothstep(1.5, -4.0, L.sunEl);
        float3 ambE = PI * (L.Lz * 0.6 + L.Lb * 0.55);
        float3 logs = ws_hex(0x5E4430u) * (0.82 + 0.22 * sin(y * 12.0) * (1.0 - smoothstep(0.03, 0.08, fp)));
        float3 cw = logs * (L.Esun * max(-L.sun.x * 0.3 + L.sun.z * 0.8 + 0.1, 0.0) * sh + ambE + L.Emoon) / PI;
        float3 lamp = float3(1.0, 0.58, 0.24) * 3.0;
        // lamplight spilling out of the windows washes the logs around them, so
        // the cabin reads as a lit building at night instead of a floating spark
        cw += logs * float3(1.0, 0.55, 0.22) * glow * 0.85;
        cw = mix(cw, mix(float3(0.03, 0.035, 0.04) * ambE, lamp, glow), cabWin);
        float3 cr = ws_hex(0x3A3B3Du) * (L.Esun * max(0.7 * L.sun.y + 0.5 * L.sun.z, 0.0) * sh + ambE * 1.35 + L.Emoon * 1.2) / PI;
        cr += ws_hex(0x3A3B3Du) * float3(1.0, 0.60, 0.26) * glow * 0.10;   // a little bounces onto the shingles
        cr *= 1.0 - 0.55 * cabEave;              // a dark eave line separates roof from wall
        float cA = cabin * (1.0 - cabRoof);
        col = mix(col, cw, clamp(cA / max(cov, 1e-3), 0.0, 1.0));
        col = mix(col, cr, clamp(cabRoof / max(cov, 1e-3), 0.0, 1.0));
    }

    // ------- aerial perspective
    float fa = ws_fogAmount(t, ro, rd, 1.0 / 30000.0, 1.0 / 3600.0);
    // Airlight over a SHORT path does not carry the full sky radiance: the sky's
    // colour includes multiple scattering gathered over the whole atmosphere.
    // Borrowing it undimmed sets a backlit treeline on fire at sunset.
    float nearK = 1.0 - 0.52 * smoothstep(6500.0, 900.0, t);
    // Mie forward scattering: looking within ~30 deg of a low sun, 16 km of air
    // glows warm.  This is what lifts a backlit peak out of flat silhouette —
    // the light is in the AIR in front of it, not painted on its shadowed face.
    float fwd = 0.10 + 0.55 * smoothstep(12.0, 0.5, L.sunEl) * smoothstep(-5.0, 0.5, L.sunEl);
    col = mix(col, hazeCol * nearK * (1.0 + fwd * sunBack), fa);
    if (i <= 3 && lod == 0) {
        float fv = ws_fogAmount(t, ro, rd, 1.0 / 44000.0, 1.0 / 130.0);
        // low-level valley haze is scattering-dominated: cooler and greyer
        col = mix(col, hazeCol * float3(0.84, 0.93, 1.12) * (0.62 + 0.10 * sunBack), fv * 0.85);
    }
    // ground mist: a shallow layer over the whole valley floor, so everything standing in
    // it is veiled together — near shore, far treeline and the feet of the ranges alike
    if (mistK > 0.01 && y < 170.0 && LV_D[i] < 4600.0) {
        float mtop = 140.0 + 44.0 * sin(x * 0.0041 + time * 0.021) + 30.0 * sin(x * 0.0017 - 1.3);  // undulating crest
        float mf = ws_fogAmount(min(t, 4600.0), ro, rd, mistK * 0.0020, 1.0 / 9.0)
                 * smoothstep(mtop, 10.0, y)
                 * smoothstep(60.0, 400.0, t);      // the nearest trees stand clear of the mist
        float br = 0.45 + 1.05 * smoothstep(-0.55, 0.65, gnoise(float2(x / 210.0 + time * 0.012, y / 55.0 + time * 0.005)));
        mf = clamp(mf * br, 0.0, 0.85);
        float3 mc = (L.Lz * 1.02 + L.Lb * 0.52) + L.Esun * 0.048 * (0.4 + sunBack * 2.2);
        col = mix(col, mc, mf);
    }
    outCol = col;
    return cov;
}

// ------------------------------------------------------------------ sky for a direction
inline float3 lv_sky(float3 rd, float3 atm, LvRig L, float time, int lod, float calm) {
    float3 c = atm;
    float3 sunRad = lv_sunT(L.sunEl) * 34.0 * smoothstep(-1.0, 0.3, L.sunEl);
    c += ws_sunDisk(rd, L.sun, 0.30 + 0.10 * smoothstep(6.0, 0.0, L.sunEl), sunRad);
    float sa = acos(clamp(dot(rd, L.sun), -1.0, 1.0));
    c += sunRad * (0.055 * exp(-sa * 22.0) + 0.020 * exp(-sa * 5.0)) * smoothstep(-0.6, 3.0, L.sunEl);
    c += lv_night(rd, L, time, lod) + lv_moon(rd, L);
    return lv_clouds(rd, L, time, c, lod, calm);
}

// ------------------------------------------------------------------ water
inline float3 lv_waves(float2 xz, float2 vh, float fpT, float fpL, float time, thread float &gustOut) {
    float2 g = 0.0;
    const float LAM[3] = { 14.0, 5.0, 1.8 };
    const int NW = 3;
    const float AMP[3] = { 0.0052, 0.0046, 0.0038 };
    const float ANG[3] = { 0.30, -0.72, 1.05 };
    float gust = smoothstep(-0.35, 0.75, gnoise(xz * float2(0.006, 0.016) + float2(time * 0.018, time * 0.004)));
    gustOut = gust;
    // A handful of straight wave trains produces regular chevrons under the sun
    // column.  One shared jitter field, entered at a different rate by each
    // train, scrambles their relative phase and amplitude into broken chop.
    float jit = gnoise(xz * float2(0.075, 0.135) + float2(time * 0.031, -time * 0.017));
    float jit2 = jit * jit * 1.8 - 0.8;
    for (int k = 0; k < NW; k++) {
        float w = TAU / LAM[k];
        float2 dir = float2(cos(ANG[k]), sin(ANG[k]));
        float c = dot(dir, vh);
        float fpd = sqrt(c * c * fpL * fpL + (1.0 - c * c) * fpT * fpT);
        float damp = 1.0 - smoothstep(LAM[k] * 0.26, LAM[k] * 1.35, fpd);
        if (damp <= 0.003) continue;
        float spd = sqrt(9.81 / w);
        float ph = dot(xz, dir) * w - time * spd * w * 0.8 + float(k) * 2.3 + gust * 2.6
                 + jit * (2.4 + 1.9 * float(k)) + jit2 * 1.7;
        float a = AMP[k] * (0.25 + 1.1 * gust * (k < 2 ? 0.6 : 1.0))
                * (0.46 + 0.78 * (0.5 + 0.5 * (k < 2 ? jit2 : jit)));
        g += dir * (a * w * cos(ph)) * damp;
    }
    return normalize(float3(-g.x, 1.0, -g.y));
}

// ------------------------------------------------------------------ main
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 uv = fragCoord / ctx.res;
    float time = ctx.time;

    LvRig L;
    L.sun  = normalize(ws_rotY(ctx.sunDir,  -PI * 0.5));
    L.moon = normalize(ws_rotY(ctx.moonDir, -PI * 0.5));
    L.sunEl = ctx.sunElevation;
    L.moonEl = asin(clamp(L.moon.y, -1.0, 1.0)) / LVD;
    L.night = smoothstep(0.0, -12.0, L.sunEl);
    // Sun-to-sky ratio: at 24 the direct beam was ~8x the sky radiance, which
    // blew every sunlit face to chalk and crushed every shaded one to a black
    // cutout.  A dimmer beam with a longer exposure holds both ends.
    L.Esun = 15.0 * lv_sunT(L.sunEl) * smoothstep(-1.0, 0.8, L.sunEl);
    L.moonIl = clamp(ctx.moonIllum, 0.0, 1.0);
    L.moonPow = pow(L.moonIl, 1.5) * smoothstep(-1.0, 6.0, L.moonEl) * L.night;
    L.Emoon = float3(0.055, 0.068, 0.100) * L.moonPow;
    float3 zen = lv_atmos(float3(0.0, 1.0, 0.0), L.sun, 1);
    float3 bk  = lv_atmos(normalize(float3(0.0, 0.15, 1.0)), L.sun, 1);
    float3 nAmb = float3(0.0070, 0.0092, 0.0155) * L.night + float3(0.0060, 0.0078, 0.0130) * L.moonPow;
    L.Lz = zen * 0.9 + nAmb;
    float bov = smoothstep(4.0, -3.0, L.sunEl) * smoothstep(-8.0, -2.0, L.sunEl);
    L.Lb = bk * 0.8 * mix(float3(1.0), float3(2.6, 1.35, 1.25), bov) + nAmb;
    float winter = 0.5 + 0.5 * cos(TAU * (ctx.dayOfYear - 20.0) / 365.0);
    L.snowLine = mix(2250.0, 1300.0, winter);

    float3 ro = float3(0.0, LV_CAMH, 0.0);
    float pit = LV_PITCH * LVD;
    float3 fwd = float3(0.0, sin(pit), -cos(pit));
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ro + fwd, LV_FOV);
    float pixAng = (LV_FOV * LVD) / ctx.res.y;

    float mistK = 0.52 * smoothstep(4.3, 5.8, ctx.dayTime) * (1.0 - smoothstep(7.6, 9.3, ctx.dayTime));
    float summer = smoothstep(135.0, 150.0, ctx.dayOfYear) * (1.0 - smoothstep(240.0, 255.0, ctx.dayOfYear));
    float fireN = summer * smoothstep(-3.0, -9.0, L.sunEl);
    // desktop hygiene: thin the cloud field under the menu bar and behind the
    // top-right icon column, and keep the Dock strip's reflections quiet
    float calm = 1.0 - 0.60 * smoothstep(0.74, 1.0, uv.y) - 0.42 * smoothstep(0.52, 1.0, uv.x) * smoothstep(0.56, 1.0, uv.y);

    float3 atmV = lv_atmos(rd, L.sun, 3);
    float3 hazeCol = atmV + nAmb * 0.8;

    float3 acc = 0.0; float trans = 1.0;
    float waterDist = 1e9, tw = 0.0;
    if (rd.y < -1e-4) { tw = LV_CAMH / (-rd.y); waterDist = -rd.z * tw; }

    // nothing in the valley subtends more than ~16 deg: high sky rays skip the slab stack outright
    for (int i = (rd.y < 0.30) ? LV_N - 1 : -1; i >= 0; i--) {
        if (waterDist < LV_D[i]) break;
        float3 c = 0.0;
        float cv = lv_slab(i, ro, rd, L, pixAng, hazeCol, mistK, time, 0, c);
        if (cv > 0.002) { acc += trans * cv * c; trans *= 1.0 - cv; if (trans < 0.004) break; }
    }

    if (trans > 0.004) {
        float3 col;
        if (waterDist < 1e8) {
            float3 P = ro + rd * tw;
            float fpW = tw * pixAng;
            float fpL = min(fpW / max(-rd.y, 0.002), 2000.0);
            float2 vh = normalize(rd.xz);
            float gust;
            float3 nW = lv_waves(P.xz, vh, fpW, fpL, time, gust);
            float3 R = reflect(rd, nW);
            R.y = max(R.y, 0.0015);
            R = normalize(R);
            float3 atmR = lv_atmos(R, L.sun, 2);
            float3 hzR = atmR + nAmb * 0.8;
            float3 refl = 0.0; float tr = 1.0;
            float pa = pixAng * (1.3 + 2.0 * gust);
            // nothing in this valley rises above ~14 deg seen from the water
            for (int i = (R.y < 0.215 ? LV_N - 1 : -1); i >= 0; i--) {
                if (i == 1 || i == 2) continue;   // the far ranges add nothing readable in the water
                float3 c = 0.0;
                float cv = lv_slab(i, P, R, L, pa, hzR, mistK, time, 1, c);
                if (cv > 0.002) { refl += tr * cv * c; tr *= 1.0 - cv; if (tr < 0.01) break; }
            }
            // The near water is rough, so its reflection of a bright cloud is
            // washed out — which also keeps the Dock strip calm.
            float calmW = calm * (0.30 + 0.70 * smoothstep(-0.04, 0.42, uv.y));
            if (tr > 0.01) refl += tr * lv_sky(R, atmR, L, time, 1, calmW);
            float cosI = clamp(dot(-rd, nW), 0.0, 1.0);
            float F = 0.02 + 0.98 * pow(1.0 - cosI, 5.0);
            float3 wc = ws_hex(0x0B2023u);
            float3 body = wc * (L.Lz * 1.1 + L.Lb * 0.4) + wc * L.Esun * 0.035;
            col = mix(body, refl, F);
            float rough = 0.072 + 0.085 * gust + 0.130 * smoothstep(30.0, 900.0, tw);
            float a2 = rough * rough * rough * rough;
            float3 hv = normalize(L.sun - rd);
            float ndh = max(dot(nW, hv), 0.0);
            float D = a2 / (PI * pow(ndh * ndh * (a2 - 1.0) + 1.0, 2.0));
            col += L.Esun * D * F * max(dot(nW, L.sun), 0.0) * 0.2 * lv_shadow(5, float3(P.x, 0.5, P.z), L, 0);
            float3 hm = normalize(L.moon - rd);
            float ndhm = max(dot(nW, hm), 0.0);
            float Dm = a2 / (PI * pow(ndhm * ndhm * (a2 - 1.0) + 1.0, 2.0));
            col += L.Emoon * Dm * F * 2.0;
            float fa = ws_fogAmount(tw, ro, rd, 1.0 / 30000.0, 1.0 / 2900.0);
            col = mix(col, hazeCol, fa);
            if (tw > 120.0) col = mix(col, hazeCol * float3(0.94, 0.99, 1.10), ws_fogAmount(tw, ro, rd, 1.0 / 44000.0, 1.0 / 130.0));
            if (mistK > 0.01 && tw > 70.0) {
                float mf = ws_fogAmount(min(tw, 4600.0), ro, rd, mistK * 0.0020, 1.0 / 9.0) * smoothstep(70.0, 260.0, tw);
                float br = 0.45 + 1.05 * smoothstep(-0.55, 0.65, gnoise(float2(P.x / 210.0 + time * 0.012, P.z / 300.0 + time * 0.005)));
                mf = clamp(mf * br, 0.0, 0.85);
                float3 mc = (L.Lz * 1.02 + L.Lb * 0.52) + L.Esun * 0.048 * (0.4 + 2.2 * pow(max(dot(rd, L.sun), 0.0), 5.0));
                col = mix(col, mc, mf);
            }
        } else {
            col = lv_sky(rd, atmV, L, time, 0, calm);
        }
        acc += trans * col;
    }
    float3 col = acc;

    // ---- window glow halo (and its reflection streak) after sunset
    float glow = smoothstep(1.5, -4.0, L.sunEl);
    if (glow > 0.003) {
        float3 Pc = float3(LV_CABX, lv_prof(4, LV_CABX, 1) + 2.05, -LV_D[4]) - ro;
        float3 dirC = normalize(Pc);
        float3 dirM = normalize(float3(Pc.x, -Pc.y - 2.0 * LV_CAMH, Pc.z));
        float a = acos(clamp(dot(rd, dirC), -1.0, 1.0)) / pixAng;
        float2 dm = float2(rd.x - dirM.x, rd.y - dirM.y) / pixAng;
        // keep the halo tight: a wide soft bloom turns the cabin into a stray light
        float g1 = 0.022 * exp(-a * a / 14.0) + 0.0030 * exp(-a / 20.0);
        float g2 = 0.042 * exp(-dm.x * dm.x / 14.0) * exp(-abs(dm.y) / 45.0) * (0.75 + 0.25 * sin(time * 1.3 + dm.y * 0.2));
        col += float3(1.0, 0.52, 0.18) * glow * (g1 + g2 * step(rd.y, 0.0));
    }

    // ---- fireflies near the left shore
    if (fireN > 0.004) {
        float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
        if (p.x < -0.18 && p.y > -0.72 && p.y < -0.02) {
            float2 q = p * 13.0;
            float2 id = floor(q), f = q - id;
            float3 fl = 0.0;
            float r = 2.4 * 13.0 * 2.0 / ctx.res.y;   // ~2.4 px glow, in cell-local units
            for (int j = 0; j < 4; j++) {
                float2 o = float2(float(j & 1), float(j >> 1)) - 0.5;
                float4 h = hash24(id + o + 31.0);
                if (h.z > 0.30) continue;
                float2 c = o + h.xy - f + 0.5;
                c.x += 0.25 * sin(time * (0.3 + 0.35 * h.z) + h.w * 9.0);
                c.y += 0.18 * sin(time * (0.23 + 0.3 * h.w) + h.x * 7.0);
                float blink = pow(max(sin(time * (0.7 + 1.1 * h.z) + h.w * 12.0), 0.0), 6.0);
                float rr = r * (0.55 + 0.85 * h.x);            // they are not all the same size
                float d2 = dot(c, c);
                fl += float3(1.0, 0.86, 0.34) * blink
                    * (exp(-d2 / (rr * rr)) + 0.22 * exp(-d2 / (rr * rr * 7.0)));
            }
            col += fl * 0.065 * fireN;
        }
    }

    // ---- exposure & tone
    float expo = 0.84 + 6.3 * smoothstep(2.0, -14.0, L.sunEl);
    col *= expo;
    col *= ws_vignette(uv, 0.22);
    col *= 1.0 - 0.06 * smoothstep(0.82, 1.0, uv.y);
    float3 o = ws_acesFitted(col);
    o += ws_grain(fragCoord, 0.37) * 0.0055 * (0.62 + 0.38 * sqrt(max(ws_luma(o), 0.0)));
    return clamp(o, 0.0, 1.0);
}
