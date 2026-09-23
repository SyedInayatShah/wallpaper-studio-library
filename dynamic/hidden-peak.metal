// =====================================================================
//  Hidden Peak — dynamic (time-of-day) alpine landscape.
//  An invented pyramid peak at the head of a glacial valley, camera
//  facing WEST so the sun sets beside it. Local frame: camera looks -z
//  (= west), +x = north, y up.  Everything in metres.
//  Performance: the march uses the macro landform + <=2 relief octaves;
//  normals use analytic noise gradients (one noise pass, 3 cheap macro taps).
// =====================================================================

constant float  HP_DEG = 0.017453292519943295;
constant float  HP_FOV = 34.0;
constant float2 HP_PK  = float2(-1750.0, -12600.0);   // peak base centre (x,z)
constant float  HP_PKH = 3300.0;
constant float  HP_PKR = 2800.0;
constant float2 HP_HUT = float2(-430.0, 2200.0);       // shepherd's hut (x,z), ~7 km down-valley
constant float  HP_CLY = 4200.0;                       // cloud deck altitude
constant float  HP_TOP = 3850.0;
constant float  HP_NS  = 0.00034;                      // relief noise scale
constant bool   HP_DBG = false;

// ---------------------------------------------------------------- noise
inline float hp_hash(int2 c) {
    uint h = uint(c.x) * 1597334677u ^ uint(c.y) * 3812015801u;
    h = (h ^ (h >> 15)) * 2246822519u; h ^= h >> 13;
    return float(h) * WS_INV_U32;
}
inline float3 hp_noised(float2 x) {          // value noise [0,1] + derivatives
    float2 i = floor(x), f = x - i; int2 c = int2(i);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float a = hp_hash(c), b = hp_hash(c + int2(1, 0)), cc = hp_hash(c + int2(0, 1)), d = hp_hash(c + int2(1, 1));
    float k1 = b - a, k2 = cc - a, k4 = a - b - cc + d;
    return float3(a + k1 * u.x + k2 * u.y + k4 * u.x * u.y, du * float2(k1 + k4 * u.y, k2 + k4 * u.x));
}
inline float hp_vn(float2 x) {
    float2 i = floor(x), f = x - i; int2 c = int2(i);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hp_hash(c), hp_hash(c + int2(1, 0)), u.x), mix(hp_hash(c + int2(0, 1)), hp_hash(c + int2(1, 1)), u.x), u.y);
}
// four independent value-noise fields from one hash per lattice corner
inline float4 hp_vn4(float2 x) {
    float2 i = floor(x), f = x - i; int2 c = int2(i);
    float2 u = f * f * (3.0 - 2.0 * f);
    uint ha = uint(c.x) * 1597334677u ^ uint(c.y) * 3812015801u;
    uint hb = uint(c.x + 1) * 1597334677u ^ uint(c.y) * 3812015801u;
    uint hc = uint(c.x) * 1597334677u ^ uint(c.y + 1) * 3812015801u;
    uint hd = uint(c.x + 1) * 1597334677u ^ uint(c.y + 1) * 3812015801u;
    ha = (ha ^ (ha >> 15)) * 2246822519u; hb = (hb ^ (hb >> 15)) * 2246822519u;
    hc = (hc ^ (hc >> 15)) * 2246822519u; hd = (hd ^ (hd >> 15)) * 2246822519u;
    float4 a = float4(uint4(ha, ha >> 8, ha >> 16, ha >> 24) & 255u);
    float4 b = float4(uint4(hb, hb >> 8, hb >> 16, hb >> 24) & 255u);
    float4 cc = float4(uint4(hc, hc >> 8, hc >> 16, hc >> 24) & 255u);
    float4 d = float4(uint4(hd, hd >> 8, hd >> 16, hd >> 24) & 255u);
    return mix(mix(a, b, u.x), mix(cc, d, u.x), u.y) * (1.0 / 255.0);
}
constant float2x2 HP_M2 = float2x2(float2(0.8, -0.6), float2(0.6, 0.8));
// cheap gradient noise (one hash per corner) with analytic derivative
inline float2 hp_grd(int2 c) {
    uint h = uint(c.x) * 1597334677u ^ uint(c.y) * 3812015801u;
    h = (h ^ (h >> 15)) * 2246822519u; h ^= h >> 13;
    return float2(float(h & 0xffffu), float(h >> 16)) * (2.0 / 65535.0) - 1.0;
}
inline float3 hp_gnD(float2 x) {
    float2 i = floor(x), f = x - i; int2 c = int2(i);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float2 ga = hp_grd(c), gb = hp_grd(c + int2(1, 0)), gc = hp_grd(c + int2(0, 1)), gd = hp_grd(c + int2(1, 1));
    float va = dot(ga, f), vb = dot(gb, f - float2(1.0, 0.0)), vc = dot(gc, f - float2(0.0, 1.0)), vd = dot(gd, f - float2(1.0, 1.0));
    float k = va - vb - vc + vd;
    float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
    float2 g = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) + du * (u.yx * k + float2(vb, vc) - va);
    return float3(v, g);
}
inline float hp_gn(float2 x) {
    float2 i = floor(x), f = x - i; int2 c = int2(i);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float va = dot(hp_grd(c), f), vb = dot(hp_grd(c + int2(1, 0)), f - float2(1.0, 0.0));
    float vc = dot(hp_grd(c + int2(0, 1)), f - float2(0.0, 1.0)), vd = dot(hp_grd(c + int2(1, 1)), f - float2(1.0, 1.0));
    return mix(mix(va, vb, u.x), mix(vc, vd, u.x), u.y);
}
// relief: ridged multifractal of gradient noise, returns ~[-0.3,0.5]
inline float hp_efbm(float2 p, float oct) {
    float s = 0.0, a = 0.5, w = 1.0;
    for (int i = 0; i < 7; i++) {
        float wt = clamp(oct - float(i), 0.0, 1.0);
        if (wt <= 0.0) break;
        float r = 1.0 - abs(hp_gn(p) * 1.6);
        r *= r;
        s += wt * a * r * w;
        w = clamp(r * 1.6, 0.0, 1.0);
        a *= 0.34; p = HP_M2 * p * 2.1;
    }
    return s - 0.3;
}
// same + analytic gradient (weights' derivatives ignored) + high-octave part
inline float4 hp_efbmD(float2 p, float oct) {
    float s = 0.0, a = 0.5, w = 1.0, hi = 0.0; float2 g = float2(0.0);
    float2x2 J = float2x2(float2(1.0, 0.0), float2(0.0, 1.0));
    for (int i = 0; i < 7; i++) {
        float wt = clamp(oct - float(i), 0.0, 1.0);
        if (wt <= 0.0) break;
        float3 n = hp_gnD(p) * 1.6;
        float r = 1.0 - abs(n.x);
        float2 dr = -sign(n.x) * (n.yz * J);
        float v = wt * a * r * r * w;
        s += v; if (i >= 2) hi += v - wt * a * w * 0.35;
        g += wt * a * w * 2.0 * r * dr;
        w = clamp(r * r * 1.6, 0.0, 1.0);
        a *= 0.34; p = HP_M2 * p * 2.1; J = HP_M2 * J * 2.1;
    }
    return float4(s - 0.3, g, hi);
}
// plain fBm of gradient-carrying value noise: (value, gradient)
inline float3 hp_fbmD(float2 p, float oct) {
    float a = 0.0, b = 0.5; float2 g = float2(0.0);
    float2x2 J = float2x2(float2(1.0, 0.0), float2(0.0, 1.0));
    for (int i = 0; i < 5; i++) {
        float w = clamp(oct - float(i), 0.0, 1.0);
        if (w <= 0.0) break;
        float3 n = hp_noised(p);
        a += w * b * (n.x - 0.5);
        g += w * b * (n.yz * J);
        b *= 0.5; p = HP_M2 * p * 2.03; J = HP_M2 * J * 2.03;
    }
    return float3(a, g);
}
inline float hp_fbmv(float2 p, float oct) {
    float a = 0.0, b = 0.5;
    for (int i = 0; i < 6; i++) {
        float w = clamp(oct - float(i), 0.0, 1.0);
        if (w <= 0.0) break;
        a += w * b * (hp_vn(p) - 0.5);
        b *= 0.5; p = HP_M2 * p * 2.03;
    }
    return a;
}

// ---------------------------------------------------------------- landform
inline float hp_riverX(float z) {
    return -330.0 + 300.0 * sin(z * 0.00043 + 0.9) + 140.0 * sin(z * 0.00127 + 2.2) + 55.0 * sin(z * 0.0033)
         + 2700.0 * smoothstep(-7500.0, -13000.0, z);
}
// river half-width (m): pools and narrows, plus gravel-bar constrictions
inline float hp_riverW(float z) {
    return 15.5 + 6.0 * sin(z * 0.00058 + 0.7) + 3.6 * sin(z * 0.00213 + 2.9) + 2.2 * sin(z * 0.0061 + 1.1)
         - 6.0 * smoothstep(-12500.0, -14500.0, z);
}
inline float hp_floor(float z) { return 30.0 + max(-z, 0.0) * 0.011; }
inline float hp_water(float z) { return hp_floor(z) - 3.0 - 400.0 * smoothstep(-13500.0, -15000.0, z); }   // river rises near the peak
inline float hp_smax(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0); return mix(b, a, h) + k * h * (1.0 - h); }

// landform for a given relief-noise value n (so normals can extrapolate n analytically)
inline float hp_baseN(float2 p, float n) {
    float z = p.y;
    float u = p.x - hp_riverX(z);
    float d = abs(u);
    float fl = hp_floor(z);
    float left = smoothstep(300.0, -300.0, u);             // 1 on the south (left) side
    float vl = smoothstep(160.0, 2300.0, d), vr = smoothstep(180.0, 2100.0, d);
    float wl = 1150.0 * vl * (0.45 + 0.55 * vl) + 420.0 * smoothstep(1700.0, 4600.0, d);
    float wr = mix(620.0, 1050.0, smoothstep(-6000.0, 0.0, z)) * vr * (0.5 + 0.5 * vr) + 380.0 * smoothstep(1900.0, 6000.0, d);
    float h = mix(wr, wl, left);
    float nearC = 1.0 - 0.55 * smoothstep(3500.0, 8500.0, z);
    h *= nearC;
    // relief
    float rel = smoothstep(60.0, 1300.0, d);
    h += rel * mix(800.0, 1300.0, left) * n * nearC;
    h = fl + h;                // soften the tallest wall summits
    // distant western ranges behind the peak, low on the right (open sunset saddle)
    float fr = smoothstep(-15000.0, -22000.0, z);
    if (fr > 0.0) h = hp_smax(h, fl + fr * (1150.0 + 650.0 * smoothstep(7000.0, -4000.0, p.x)) * (0.88 + 0.78 * n), 300.0);
    // the peak: three-face pyramid (front face toward the camera) with a shoulder on the right arete
    float2 q = p - HP_PK;
    float r2 = dot(q, q);
    if (r2 < HP_PKR * HP_PKR * 2.6) {
        float F = max(dot(q, float2(0.10, 0.995)) * 1.08, max(dot(q, float2(-0.93, -0.37)), dot(q, float2(0.86, -0.51)) * 0.92));
        F += 260.0 * hp_gn(q * 0.00055 + 2.0);
        float k = clamp(1.0 - F / HP_PKR, 0.0, 1.0);
        float pk = HP_PKH * k * (0.6 + 0.4 * k);
        float2 q2 = q - float2(1000.0, 500.0);
        float F2 = max(dot(q2, float2(0.2, 0.98)), max(dot(q2, float2(-0.9, -0.43)), dot(q2, float2(0.8, -0.6))));
        float k2 = clamp(1.0 - F2 / 2300.0, 0.0, 1.0);
        pk = hp_smax(pk, 1900.0 * k2 * (0.6 + 0.4 * k2), 160.0);
        pk += 420.0 * n * k * (1.0 - k * 0.45);
        h = hp_smax(h, fl + pk, 240.0);
    }
    // river channel (only on the valley floor), width tracking hp_riverW
    if (d < 55.0 && z > -15200.0) {
        float rwz = hp_riverW(z);
        h -= 9.0 * smoothstep(rwz * 1.5, rwz * 0.55, d) * smoothstep(-15000.0, -13500.0, z);
    }
    return h;
}
inline float hp_base(float2 p, float oc) { return hp_baseN(p, hp_efbm(p * HP_NS + float2(3.7, 1.3), oc)); }

// Ridged rock detail on the peak (sharp aretes, buttresses). Shared by the march (2 octaves,
// so the silhouette is jagged) and shading (up to 4, faded by pixel footprint).
inline float3 hp_pkRock(float2 q, float fpx, int kmax) {
    float r2 = dot(q, q);
    float pkK = clamp(1.0 - sqrt(r2) / (HP_PKR * 1.1), 0.0, 1.0);
    if (pkK <= 0.0) return float3(0.0);
    float A = 132.0 * smoothstep(0.0, 0.35, pkK), f = 0.0016, w = 1.0, h = 0.0;
    float2 g = float2(0.0);
    for (int k = 0; k < 4; k++) {
        if (k >= kmax) break;
        float fade = clamp(1.0 / (f * fpx * 8.5) - 1.0, 0.0, 1.0);
        if (fade <= 0.0) break;
        float3 gn = hp_gnD(q * float2(1.0, 0.8) * f + float(k) * 3.7);
        // rounded crease: |x| -> sqrt(x^2+e^2), e growing with the pixel footprint, so the
        // sharpest feature stays wider than a pixel instead of firing single bright samples
        float ep = 0.055 + 0.9 * clamp(f * fpx, 0.0, 0.12);
        float ax = sqrt(gn.x * gn.x + ep * ep);
        float r = 1.0 - ax * 1.8;
        h += A * fade * w * (r * r - 0.5);
        g += A * fade * w * 2.0 * r * (-1.8 * gn.x / ax) * f * (gn.yz * float2(1.0, 0.8));
        w = clamp(r * r * 1.5, 0.42, 1.0);
        A *= 0.52; f *= 2.2;
    }
    return float3(h, g);
}

// vC is sampled on a domain-warped position, so clearings are torn, not ovoid
// value-only first octave of hp_pkRock, for the march (no gradient needed there)
inline float hp_pkRockH(float2 q, float fpx) {
    float pkK = clamp(1.0 - length(q) / (HP_PKR * 1.1), 0.0, 1.0);
    if (pkK <= 0.0) return 0.0;
    const float f = 0.0016;
    float fade = clamp(1.0 / (f * fpx * 5.0) - 1.0, 0.0, 1.0);
    if (fade <= 0.0) return 0.0;
    float r = 1.0 - abs(hp_gn(q * float2(f, f * 0.8))) * 1.8;
    return 130.0 * smoothstep(0.0, 0.35, pkK) * fade * (r * r - 0.5);
}

inline float hp_forestM(float2 p, float y, float4 vC, float4 vB) {
    float fl = hp_floor(p.y);
    float tl = 1250.0 + 300.0 * vC.w;                                 // ragged treeline
    float m = smoothstep(tl, tl - 120.0, y) * mix(0.55, 1.0, smoothstep(fl + 6.0, fl + 40.0, y));
    float patch = vC.y * 0.62 + vB.x * 0.38;
    m *= smoothstep(0.1, 0.34, patch + 0.3 * smoothstep(900.0, 350.0, y));
    return m;
}
inline float hp_lod(float t, float pix) {           // octave budget so the finest is ~2.5 px
    float fp = max(t * pix, 0.05);
    return clamp(log2(2940.0 / (fp * 2.5)) + 1.0, 1.5, 11.0);
}
inline float hp_hM(float3 p, float t, float pix) {
    float h = hp_base(p.xz, 1.0);
    float2 q = p.xz - HP_PK;
    if (dot(q, q) < HP_PKR * HP_PKR * 1.3) h += hp_pkRockH(q, t * pix);
    return max(h, hp_water(p.z));
}

// ---------------------------------------------------------------- lighting helpers
inline float3 hp_sunTrans(float el) {        // el: effective elevation (deg)
    float s = sin(max(el, 0.0) * HP_DEG);
    float am = 1.0 / (s + 0.15 * pow(max(el, 0.0) + 3.885, -1.253));
    float3 tau = float3(0.046, 0.108, 0.186) + 0.03;
    return exp(-tau * am) * smoothstep(-0.7, 0.35, el);
}
inline float hp_hg(float c, float g) { float g2 = g * g; return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * c, 1.5)); }

// Zenith sky radiance — cheap 4x3 integration of the same atmosphere
inline float3 hp_zenith(float3 sunDir) {
    const float Rp = 6371e3;
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6); const float kM = 21e-6;
    float mu = sunDir.y, gg = 0.758 * 0.758;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mu * mu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * 0.758, 1.5) * (2.0 + gg));
    float3 tR = float3(0.0), tM = float3(0.0);
    float oR = 0.0, oM = 0.0;
    const float hs[4] = {600.0, 2500.0, 7000.0, 20000.0};
    const float ws[4] = {1200.0, 2800.0, 7000.0, 30000.0};
    for (int i = 0; i < 4; i++) {
        float hR = exp(-hs[i] / 8e3) * ws[i], hM = exp(-hs[i] / 1.2e3) * ws[i];
        oR += hR; oM += hM;
        float3 pos = float3(0.0, Rp + hs[i], 0.0);
        float2 sg = ws_raySphere(pos, sunDir, Rp);
        if (sg.x <= sg.y && sg.x > 0.0) continue;
        float L = ws_raySphere(pos, sunDir, 6471e3).y;
        float jR = 0.0, jM = 0.0;
        for (int j = 0; j < 3; j++) {
            float s = L * (float(j) + 0.5) / 3.0;
            float3 jp = pos + sunDir * s;
            float jh = length(jp) - Rp;
            jR += exp(-jh / 8e3) * L / 3.0; jM += exp(-jh / 1.2e3) * L / 3.0;
        }
        float3 at = exp(-(kM * (oM + jM) + kR * (oR + jR)));
        tR += hR * at; tM += hM * at;
    }
    return 22.0 * (pR * kR * tR + pM * kM * tM);
}

// Same Rayleigh+Mie model (and constants) as the prelude's ws_atmosphereFast, but with
// quadratic step spacing (6 view x 2 light steps): cheaper, and more accurate along the long
// near-horizontal paths this camera looks down. Drives the whole sky, the haze and the tables.
inline float3 hp_atmoLite(float3 rd, float3 sunDir, float altitude) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kRlh = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kMie = 21e-6;
    float3 r0 = float3(0.0, Rp + altitude, 0.0);
    float2 pa = ws_raySphere(r0, rd, Ra);
    float2 pg = ws_raySphere(r0, rd, Rp);
    if (pg.x <= pg.y && pg.x > 0.0) pa.y = min(pa.y, pg.x);
    float3 totR = float3(0.0), totM = float3(0.0);
    float oR = 0.0, oM = 0.0, tPrev = 0.0;
    float mu = dot(rd, sunDir), gg = 0.758 * 0.758;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mu * mu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * 0.758, 1.5) * (2.0 + gg));
    const int N = 6;
    for (int i = 0; i < N; i++) {
        float x1 = float(i + 1) / float(N);
        float t1 = pa.y * x1 * x1;
        float tm = 0.5 * (tPrev + t1), ds = t1 - tPrev; tPrev = t1;
        float3 ip = r0 + rd * tm;
        float ih = length(ip) - Rp;
        float dR = exp(-ih / 8e3) * ds, dM = exp(-ih / 1.2e3) * ds;
        oR += dR * 0.5; oM += dM * 0.5;
        // Earth's shadow, smoothed: how far above the ground the sun ray from this sample passes
        float rl = length(ip), cd = dot(ip / rl, sunDir);
        float minAlt = (cd < 0.0 ? rl * sqrt(max(1.0 - cd * cd, 0.0)) : rl) - Rp;
        float vis = smoothstep(-7000.0, 7000.0, minAlt);
        if (vis > 0.0) {
            float L = ws_raySphere(ip, sunDir, Ra).y;
            float jR = 0.0, jM = 0.0;
            for (int j = 0; j < 2; j++) {
                float xj = (float(j) + 0.5) * 0.5;
                float3 jp = ip + sunDir * (L * xj * xj);
                float jh = length(jp) - Rp;
                float w = L * (j == 0 ? 0.25 : 0.75);
                jR += exp(-jh / 8e3) * w; jM += exp(-jh / 1.2e3) * w;
            }
            float3 at = exp(-(kMie * (oM + jM) + kRlh * (oR + jR))) * vis;
            totR += dR * at; totM += dM * at;
        }
        oR += dR * 0.5; oM += dM * 0.5;
    }
    return 22.0 * (pR * kRlh * totR + pM * kMie * totM);
}

// Precomputed (offline, same model as hp_zenith / hp_atmoLite) so per-pixel cost is a lookup:
// HP_ZEN[i]: zenith radiance for sun elevation -18+2i deg.
// HP_HAZE[i*13+j]: radiance 1.7 deg above the horizon, sun elevation -18+2i, azimuth offset 15j deg.
constant float3 HP_ZEN[40] = {float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0.00289172, 0.000611348, 5.11136e-05), float3(0.0129629, 0.0156169, 0.013007), float3(0.0312339, 0.0394222, 0.0404717), float3(0.0456209, 0.0685305, 0.0762188), float3(0.0528169, 0.0902797, 0.111656), float3(0.0569713, 0.104353, 0.138672), float3(0.0597986, 0.113793, 0.15809), float3(0.0620588, 0.120751, 0.172568), float3(0.064103, 0.126419, 0.184097), float3(0.0661061, 0.131439, 0.193913), float3(0.0681633, 0.136172, 0.202764), float3(0.0703319, 0.140828, 0.211106), float3(0.0726497, 0.145539, 0.219227), float3(0.075145, 0.150389, 0.227315), float3(0.0778417, 0.155436, 0.235495), float3(0.0807624, 0.160723, 0.243854), float3(0.0839302, 0.166284, 0.252454), float3(0.0873711, 0.172149, 0.261342), float3(0.0911149, 0.178348, 0.270557), float3(0.0951974, 0.184913, 0.280133), float3(0.0996618, 0.19188, 0.290106), float3(0.104561, 0.199295, 0.300514), float3(0.109961, 0.207212, 0.311404), float3(0.115944, 0.215699, 0.322834), float3(0.122609, 0.224845, 0.334877), float3(0.130085, 0.23476, 0.347628), float3(0.13853, 0.245586, 0.361211), float3(0.148144, 0.257504, 0.375785), float3(0.159179, 0.270744, 0.391557), float3(0.171954, 0.2856, 0.408796), float3(0.186875, 0.302452, 0.427846), float3(0.204455, 0.32178, 0.449153), float3(0.22535, 0.344202, 0.473292)};
constant float3 HP_HAZE[520] = {float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(8.48961e-09, 1.99771e-12, 3.31955e-17), float3(3.41336e-47, 2.39767e-53, 2.7266e-61), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0.000103103, 7.63055e-05, 3.06767e-05), float3(9.4048e-05, 6.42294e-05, 2.33478e-05), float3(5.32453e-05, 1.9083e-05, 3.09174e-06), float3(9.31951e-11, 7.58728e-15, 3.33353e-20), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0.000115524, 9.86441e-05, 4.74433e-05), float3(0.00011153, 9.49869e-05, 4.55359e-05), float3(9.99924e-05, 8.37497e-05, 3.93171e-05), float3(7.76254e-05, 5.64472e-05, 2.21979e-05), float3(8.58677e-06, 3.95984e-07, 4.91039e-09), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0.00559949, 0.0028424, 0.000723189), float3(0.00490594, 0.00218594, 0.000479487), float3(0.00271482, 0.000656538, 9.18595e-05), float3(0.000143252, 7.52966e-05, 3.59858e-05), float3(7.03178e-05, 5.64976e-05, 2.5177e-05), float3(1.88998e-05, 3.11617e-06, 1.90788e-07), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0.0081644, 0.00647305, 0.00291784), float3(0.00769102, 0.00615902, 0.00274585), float3(0.00674878, 0.00521593, 0.0022146), float3(0.00522417, 0.0035062, 0.00124943), float3(0.00262855, 0.000903759, 0.000152871), float3(6.43521e-05, 5.06546e-05, 2.32667e-05), float3(2.38664e-05, 5.87293e-06, 5.93941e-07), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0.0640614, 0.0337874, 0.00959853), float3(0.0601364, 0.0306693, 0.00849174), float3(0.0490284, 0.0223058, 0.00577659), float3(0.0309497, 0.0114667, 0.00303819), float3(0.00979503, 0.00432873, 0.00171413), float3(0.00359636, 0.00228296, 0.000759651), float3(0.00111487, 0.000194789, 2.96471e-05), float3(3.1364e-05, 1.02431e-05, 1.47704e-06), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0.15481, 0.0748037, 0.0256436), float3(0.139357, 0.0696332, 0.0240487), float3(0.111678, 0.0573151, 0.0198603), float3(0.0798062, 0.042098, 0.0143314), float3(0.0520742, 0.0278116, 0.00876911), float3(0.0333184, 0.0159174, 0.00421877), float3(0.0184438, 0.00625794, 0.00150898), float3(0.0041491, 0.0014333, 0.000325763), float3(0.000228355, 2.69206e-05, 5.35167e-06), float3(2.33566e-45, 1.8363e-51, 2.40489e-59), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0.440557, 0.180321, 0.0564666), float3(0.325274, 0.161157, 0.0525801), float3(0.245374, 0.134735, 0.044276), float3(0.192055, 0.10542, 0.0338881), float3(0.146778, 0.0773954, 0.0239358), float3(0.112062, 0.0551595, 0.0161523), float3(0.0884155, 0.0395457, 0.0107454), float3(0.0724521, 0.0282919, 0.00678461), float3(0.0574946, 0.0177261, 0.00327829), float3(0.0352141, 0.00642109, 0.000599531), float3(0.0128334, 0.00089193, 1.87364e-05), float3(0.00443304, 0.000181685, 2.04932e-06), float3(0.00296373, 0.00010872, 1.08424e-06), float3(2.13594, 0.651435, 0.16269), float3(1.07905, 0.426392, 0.127723), float3(0.559066, 0.29516, 0.100036), float3(0.388518, 0.226515, 0.0780721), float3(0.293489, 0.173547, 0.0586084), float3(0.233702, 0.135298, 0.0439393), float3(0.205167, 0.114, 0.0350876), float3(0.204176, 0.107302, 0.0308516), float3(0.221728, 0.10885, 0.0287681), float3(0.245891, 0.111647, 0.0266414), float3(0.26638, 0.11157, 0.023736), float3(0.277865, 0.109002, 0.0209835), float3(0.281152, 0.107484, 0.0198719), float3(4.28564, 1.67696, 0.507616), float3(1.97119, 0.921474, 0.320901), float3(0.878817, 0.538907, 0.216566), float3(0.567405, 0.396035, 0.165924), float3(0.420867, 0.306277, 0.128314), float3(0.33794, 0.24718, 0.10181), float3(0.30372, 0.219567, 0.0881185), float3(0.31304, 0.221742, 0.0862498), float3(0.355604, 0.245768, 0.092415), float3(0.415275, 0.279834, 0.101785), float3(0.473885, 0.312265, 0.110358), float3(0.515768, 0.3346, 0.115918), float3(0.530858, 0.342452, 0.117789), float3(5.3864, 2.63597, 1.02873), float3(2.46415, 1.39036, 0.600649), float3(1.06366, 0.763566, 0.373493), float3(0.671809, 0.548958, 0.281145), float3(0.495165, 0.425156, 0.219764), float3(0.398445, 0.347347, 0.178657), float3(0.360403, 0.314246, 0.159805), float3(0.374755, 0.324518, 0.162666), float3(0.430149, 0.368755, 0.18202), float3(0.507855, 0.430721, 0.209539), float3(0.585345, 0.491793, 0.236396), float3(0.641649, 0.535642, 0.255439), float3(0.662152, 0.551496, 0.26227), float3(5.73386, 3.25843, 1.52407), float3(2.69828, 1.7374, 0.882546), float3(1.17027, 0.939402, 0.532607), float3(0.735119, 0.669262, 0.397265), float3(0.540891, 0.518692, 0.311969), float3(0.435816, 0.426158, 0.256463), float3(0.395232, 0.388594, 0.232747), float3(0.412184, 0.404851, 0.240762), float3(0.474626, 0.464334, 0.273968), float3(0.56227, 0.547371, 0.320554), float3(0.650093, 0.630008, 0.366693), float3(0.714215, 0.68998, 0.399989), float3(0.737634, 0.711807, 0.412066), float3(5.60627, 3.53775, 1.87812), float3(2.77033, 1.95963, 1.11732), float3(1.23158, 1.06953, 0.673619), float3(0.775565, 0.760587, 0.500975), float3(0.571002, 0.590163, 0.394567), float3(0.460712, 0.486537, 0.326371), float3(0.418394, 0.445448, 0.298365), float3(0.436708, 0.465844, 0.310908), float3(0.503173, 0.536221, 0.356327), float3(0.59655, 0.634375, 0.419769), float3(0.690335, 0.732474, 0.482988), float3(0.75896, 0.803987, 0.528926), float3(0.784055, 0.830085, 0.545658), float3(5.20731, 3.55703, 2.07198), float3(2.73606, 2.07826, 1.28999), float3(1.26347, 1.16266, 0.790441), float3(0.801799, 0.829296, 0.588689), float3(0.591651, 0.64472, 0.464901), float3(0.478187, 0.532944, 0.386152), float3(0.434696, 0.489127, 0.354509), float3(0.453665, 0.51229, 0.370673), float3(0.52236, 0.590259, 0.42604), float3(0.618984, 0.699012, 0.503258), float3(0.716173, 0.807962, 0.580455), float3(0.787373, 0.887571, 0.636744), float3(0.813429, 0.916664, 0.65729), float3(4.68707, 3.41482, 2.13694), float3(2.6342, 2.11917, 1.404), float3(1.27496, 1.22706, 0.883579), float3(0.818475, 0.880876, 0.661058), float3(0.606126, 0.686692, 0.523604), float3(0.490933, 0.569092, 0.436386), float3(0.446686, 0.523208, 0.40174), float3(0.465868, 0.54815, 0.420656), float3(0.53563, 0.631277, 0.48379), float3(0.633893, 0.747296, 0.571816), float3(0.732836, 0.863707, 0.659994), float3(0.805379, 0.948886, 0.724421), float3(0.831938, 0.980039, 0.747965), float3(4.14408, 3.19182, 2.11658), float3(2.49328, 2.10613, 1.46998), float3(1.27181, 1.26933, 0.955828), float3(0.828338, 0.91944, 0.720047), float3(0.616331, 0.71927, 0.572284), float3(0.500497, 0.597693, 0.478463), float3(0.455822, 0.55029, 0.441394), float3(0.474921, 0.576295, 0.462319), float3(0.544939, 0.662767, 0.531331), float3(0.643716, 0.783566, 0.627585), float3(0.743268, 0.904915, 0.724144), float3(0.816301, 0.99379, 0.794785), float3(0.843046, 1.02631, 0.820619), float3(3.63375, 2.94234, 2.04831), float3(2.33398, 2.05847, 1.49988), float3(1.25802, 1.29458, 1.01045), float3(0.833119, 0.947963, 0.767756), float3(0.623436, 0.744721, 0.612611), float3(0.507821, 0.620659, 0.513813), float3(0.462987, 0.572199, 0.474837), float3(0.48179, 0.598734, 0.497158), float3(0.551463, 0.687165, 0.570462), float3(0.649921, 0.810846, 0.672778), float3(0.749233, 0.935207, 0.77553), float3(0.822126, 1.02635, 0.850773), float3(0.848826, 1.05972, 0.878304), float3(3.1811, 2.69775, 1.95822), float3(2.17048, 1.99071, 1.50439), float3(1.23656, 1.30673, 1.0505), float3(0.833982, 0.968604, 0.806054), float3(0.628198, 0.764656, 0.646039), float3(0.513507, 0.639339, 0.54367), float3(0.468741, 0.590213, 0.503241), float3(0.48709, 0.616873, 0.526458), float3(0.555949, 0.706178, 0.60273), float3(0.653437, 0.831247, 0.709296), float3(0.751849, 0.957109, 0.816418), float3(0.824112, 1.04941, 0.894916), float3(0.850587, 1.0832, 0.923648), float3(2.79276, 2.47343, 1.86228), float3(2.01182, 1.91307, 1.49199), float3(1.2097, 1.30884, 1.07865), float3(0.831753, 0.982948, 0.8365), float3(0.631129, 0.780235, 0.673762), float3(0.517955, 0.654693, 0.569035), float3(0.473453, 0.605241, 0.527558), float3(0.491225, 0.631707, 0.551257), float3(0.558892, 0.721012, 0.62939), float3(0.654881, 0.846266, 0.738686), float3(0.751858, 0.972415, 0.848644), float3(0.823097, 1.06497, 0.929268), float3(0.849202, 1.09887, 0.958788), float3(2.46575, 2.27498, 1.76913), float3(1.86319, 1.83232, 1.46897), float3(1.17918, 1.30329, 1.09715), float3(0.827048, 0.992193, 0.86037), float3(0.63259, 0.792309, 0.696735), float3(0.521441, 0.667419, 0.590705), float3(0.477377, 0.617938, 0.548537), float3(0.494473, 0.643954, 0.572379), float3(0.560632, 0.732543, 0.651436), float3(0.654682, 0.856992, 0.762175), float3(0.749779, 0.982425, 0.873674), float3(0.819664, 1.07449, 0.955468), float3(0.845277, 1.10822, 0.985424), float3(2.19291, 2.10271, 1.68277), float3(1.72708, 1.75264, 1.43971), float3(1.14638, 1.29196, 1.10785), float3(0.820343, 0.997259, 0.878704), float3(0.632848, 0.801516, 0.715725), float3(0.52416, 0.678031, 0.609311), float3(0.480691, 0.628783, 0.566772), float3(0.497031, 0.654145, 0.590471), float3(0.561415, 0.741417, 0.669656), float3(0.653152, 0.864231, 0.78074), float3(0.745988, 0.988111, 0.892673), float3(0.81424, 1.07908, 0.974824), float3(0.839259, 1.11241, 1.00492), float3(1.96596, 1.95443, 1.60456), float3(1.60422, 1.67638, 1.40715), float3(1.11234, 1.2763, 1.11228), float3(0.812019, 0.998872, 0.892353), float3(0.632102, 0.808345, 0.731345), float3(0.526257, 0.686917, 0.625354), float3(0.483523, 0.638137, 0.58273), float3(0.499041, 0.662674, 0.606048), float3(0.561422, 0.748125, 0.684676), float3(0.650523, 0.868599, 0.795163), float3(0.740772, 0.990214, 0.906579), float3(0.807149, 1.07955, 0.988385), float3(0.831485, 1.11229, 1.01836), float3(1.77694, 1.82702, 1.53442), float3(1.49429, 1.60469, 1.37316), float3(1.07785, 1.25747, 1.11167), float3(0.802391, 0.997618, 0.902022), float3(0.630511, 0.813179, 0.744094), float3(0.527838, 0.694375, 0.639232), float3(0.485968, 0.646273, 0.59678), float3(0.500612, 0.669847, 0.619517), float3(0.560793, 0.753044, 0.697002), float3(0.646977, 0.870575, 0.806075), float3(0.734356, 0.989316, 0.916152), float3(0.798649, 1.07658, 0.997008), float3(0.822224, 1.10856, 1.02664), float3(1.61887, 1.7172, 1.47163), float3(1.39635, 1.53796, 1.33888), float3(1.0435, 1.23634, 1.10705), float3(0.791721, 0.993973, 0.908299), float3(0.628204, 0.816323, 0.75438), float3(0.528988, 0.700636, 0.651268), float3(0.488098, 0.653402, 0.609221), float3(0.501825, 0.675897, 0.631208), float3(0.559636, 0.756472, 0.707041), float3(0.642661, 0.870544, 0.813995), float3(0.726923, 0.985887, 0.922019), float3(0.78895, 1.07069, 1.0014), float3(0.8117, 1.10177, 1.0305), float3(1.48587, 1.62198, 1.4152), float3(1.30922, 1.47613, 1.30496), float3(1.0097, 1.21362, 1.09921), float3(0.78023, 0.988336, 0.911678), float3(0.625287, 0.818027, 0.762541), float3(0.529772, 0.705884, 0.661724), float3(0.489968, 0.659689, 0.620292), float3(0.502744, 0.681012, 0.641387), float3(0.55804, 0.75865, 0.715131), float3(0.637699, 0.868818, 0.819353), float3(0.71863, 0.980312, 0.924707), float3(0.778234, 1.06232, 1.00216), float3(0.800099, 1.09238, 1.03055), float3(1.37312, 1.53874, 1.36416), float3(1.23166, 1.4189, 1.27174), float3(0.976737, 1.18981, 1.08881), float3(0.768107, 0.981042, 0.912582), float3(0.62185, 0.818497, 0.768862), float3(0.530242, 0.710267, 0.670816), float3(0.491621, 0.665265, 0.630186), float3(0.503421, 0.685341, 0.650273), float3(0.55608, 0.759774, 0.721551), float3(0.632193, 0.865658, 0.822512), float3(0.709612, 0.972917, 0.92466), float3(0.766658, 1.05184, 0.999786), float3(0.787589, 1.08078, 1.02733), float3(1.27673, 1.4653, 1.31758), float3(1.16242, 1.36586, 1.23937), float3(0.944812, 1.16533, 1.07638), float3(0.755516, 0.972375, 0.911372), float3(0.617973, 0.817908, 0.773583), float3(0.530441, 0.713905, 0.678722), float3(0.493089, 0.670235, 0.639065), float3(0.503898, 0.689006, 0.658047), float3(0.553819, 0.760009, 0.726538), float3(0.626236, 0.861287, 0.823783), float3(0.699988, 0.963982, 0.922263), float3(0.754363, 1.03958, 0.994724), float3(0.774317, 1.06731, 1.0213), float3(1.1936, 1.39986, 1.27469), float3(1.10041, 1.31657, 1.2079), float3(0.914035, 1.14049, 1.06235), float3(0.742596, 0.962582, 0.908361), float3(0.613725, 0.81641, 0.776912), float3(0.530407, 0.716899, 0.685591), float3(0.494402, 0.674684, 0.64706), float3(0.50421, 0.692106, 0.664861), float3(0.551313, 0.759494, 0.730292), float3(0.619911, 0.855897, 0.823434), float3(0.68987, 0.953753, 0.917853), float3(0.741478, 1.02582, 0.987358), float3(0.760422, 1.05227, 1.01285), float3(1.12125, 1.34099, 1.23482), float3(1.04462, 1.27058, 1.1773), float3(0.88447, 1.11551, 1.04706), float3(0.729469, 0.951876, 0.903822), float3(0.609169, 0.814132, 0.779029), float3(0.530169, 0.719333, 0.691551), float3(0.49558, 0.678682, 0.654281), float3(0.504386, 0.694724, 0.670842), float3(0.548609, 0.75835, 0.732986), float3(0.613293, 0.849658, 0.821701), float3(0.679357, 0.942449, 0.911727), float3(0.728124, 1.01083, 0.978031), float3(0.74603, 1.03592, 1.00236), float3(1.05772, 1.28752, 1.19744), float3(0.994191, 1.22752, 1.14756), float3(0.856141, 1.0906, 1.03082), float3(0.71624, 0.940442, 0.897996), float3(0.60436, 0.81119, 0.780092), float3(0.529754, 0.721277, 0.696709), float3(0.49664, 0.682286, 0.660819), float3(0.504451, 0.696933, 0.676097), float3(0.545752, 0.756681, 0.734772), float3(0.606451, 0.842721, 0.818793), float3(0.668546, 0.930268, 0.904153), float3(0.714415, 0.994817, 0.967053), float3(0.731261, 1.01851, 0.990135), float3(1.00145, 1.23854, 1.16215), float3(0.94839, 1.18704, 1.11861), float3(0.829048, 1.06588, 1.01385), float3(0.703001, 0.928447, 0.891094), float3(0.599352, 0.807685, 0.780239), float3(0.529186, 0.722791, 0.701157), float3(0.497599, 0.685544, 0.666753), float3(0.504426, 0.698791, 0.68072), float3(0.542783, 0.75458, 0.735783), float3(0.599451, 0.835224, 0.814898), float3(0.657526, 0.917392, 0.895372), float3(0.700459, 0.978012, 0.954706), float3(0.716232, 1.00027, 0.976484), float3(0.95121, 1.19332, 1.12862), float3(0.906595, 1.14885, 1.09043), float3(0.803175, 1.04149, 0.996372), float3(0.689833, 0.916035, 0.883308), float3(0.594191, 0.80371, 0.779596), float3(0.528486, 0.723931, 0.704977), float3(0.498467, 0.688496, 0.672147), float3(0.504331, 0.70035, 0.684791), float3(0.539737, 0.752131, 0.736137), float3(0.592353, 0.827292, 0.810184), float3(0.646383, 0.903989, 0.885606), float3(0.686359, 0.960609, 0.941248), float3(0.70105, 0.981401, 0.961677), float3(0.906014, 1.1513, 1.0966), float3(0.868286, 1.11273, 1.06298), float3(0.778497, 1.0175, 0.978557), float3(0.676805, 0.903337, 0.874807), float3(0.588922, 0.799347, 0.778275), float3(0.527671, 0.72474, 0.708239), float3(0.499256, 0.691175, 0.677059), float3(0.504181, 0.701656, 0.688379), float3(0.53665, 0.749407, 0.735939), float3(0.585218, 0.819041, 0.804807), float3(0.635199, 0.890214, 0.875058), float3(0.672215, 0.942795, 0.926919), float3(0.685824, 0.962109, 0.945965), float3(0.865085, 1.11204, 1.06594), float3(0.833032, 1.07846, 1.03627), float3(0.754986, 0.994009, 0.960562), float3(0.66398, 0.890472, 0.865745), float3(0.583585, 0.794672, 0.776377), float3(0.52676, 0.725261, 0.711003), float3(0.499973, 0.693611, 0.681535), float3(0.503993, 0.702746, 0.691544), float3(0.533555, 0.746477, 0.735283), float3(0.578099, 0.810579, 0.798908), float3(0.624054, 0.876215, 0.863915), float3(0.658123, 0.924744, 0.911941), float3(0.670654, 0.942576, 0.929583), float3(0.827807, 1.07521, 1.0365), float3(0.800478, 1.04592, 1.0103), float3(0.732611, 0.971082, 0.942525), float3(0.651412, 0.877546, 0.856262), float3(0.578218, 0.789755, 0.773994), float3(0.525767, 0.725529, 0.713326), float3(0.500626, 0.695826, 0.685618), float3(0.503779, 0.703656, 0.694339), float3(0.530481, 0.743404, 0.734257), float3(0.571052, 0.802004, 0.792617), float3(0.613023, 0.862129, 0.852354), float3(0.644176, 0.906623, 0.896523), float3(0.65564, 0.922978, 0.912753), float3(0.793688, 1.04056, 1.0082), float3(0.770333, 1.01498, 0.985075), float3(0.711344, 0.948786, 0.924574), float3(0.639152, 0.864656, 0.846484), float3(0.572857, 0.78466, 0.771212), float3(0.524707, 0.725578, 0.715255), float3(0.501222, 0.697844, 0.689342), float3(0.503551, 0.704416, 0.696812), float3(0.527457, 0.740245, 0.732938), float3(0.564126, 0.793412, 0.786056), float3(0.602181, 0.848087, 0.840539), float3(0.630464, 0.888588, 0.880858), float3(0.640877, 0.903482, 0.895679), float3(0.762342, 1.00789, 0.981022), float3(0.742363, 0.985573, 0.960638), float3(0.691162, 0.92718, 0.906823), float3(0.627242, 0.85189, 0.836528), float3(0.567534, 0.779447, 0.768106), float3(0.523593, 0.725437, 0.716834), float3(0.501764, 0.69968, 0.692738), float3(0.503321, 0.705053, 0.699004), float3(0.52451, 0.737052, 0.731397), float3(0.557372, 0.78489, 0.779337), float3(0.591597, 0.834212, 0.828621), float3(0.617073, 0.870789, 0.86513), float3(0.626459, 0.884245, 0.878556), float3(0.73346, 0.977062, 0.954935), float3(0.716376, 0.957634, 0.937027), float3(0.672043, 0.906321, 0.889381), float3(0.615722, 0.839331, 0.826501), float3(0.562282, 0.774169, 0.764748), float3(0.522438, 0.725132, 0.718103), float3(0.502259, 0.701352, 0.695834), float3(0.503098, 0.705591, 0.700951), float3(0.521667, 0.733874, 0.7297), float3(0.550836, 0.776522, 0.772565), float3(0.58134, 0.820621, 0.816745), float3(0.604087, 0.853366, 0.849512), float3(0.612473, 0.86542, 0.861567), float3(0.706802, 0.947988, 0.929953), float3(0.692219, 0.931131, 0.914289), float3(0.653971, 0.886265, 0.872348), float3(0.604628, 0.827053, 0.816502), float3(0.557128, 0.768879, 0.761203), float3(0.521252, 0.724687, 0.719096), float3(0.502709, 0.702872, 0.698653), float3(0.50289, 0.706052, 0.702687), float3(0.51895, 0.730757, 0.727906), float3(0.544562, 0.768384, 0.765835), float3(0.571476, 0.807423, 0.805046), float3(0.591586, 0.836454, 0.834164), float3(0.599005, 0.847147, 0.844883)};
inline float3 hp_zenT(float el) {
    float x = clamp((el + 18.0) * 0.5, 0.0, 38.999);
    int i = int(x); float f = x - float(i);
    return mix(HP_ZEN[i], HP_ZEN[i + 1], f);
}
inline float3 hp_hazeT(float el, float dAz) {
    float x = clamp((el + 18.0) * 0.5, 0.0, 38.999), y = clamp(dAz / 15.0, 0.0, 11.999);
    int i = int(x), j = int(y); float fx = x - float(i), fy = y - float(j);
    float3 a = mix(HP_HAZE[i * 13 + j], HP_HAZE[i * 13 + j + 1], fy);
    float3 b = mix(HP_HAZE[(i + 1) * 13 + j], HP_HAZE[(i + 1) * 13 + j + 1], fy);
    return mix(a, b, fx);
}

// Cloud deck: density plus its gradient, so the puffs can be shaded like real cumulus.
inline float3 hp_cloudD(float2 p, float time, float oct, float bias) {
    float2 q = (p + float2(-7.0, 2.5) * time) * 0.00042;
    float base = hp_vn(q * 0.11 + 7.0);
    float3 n = hp_fbmD(q + float2(0.004, -0.002) * time * 0.1, oct);
    float cov = -0.13 + 0.36 * base + bias;
    float d = (n.x + cov) * 3.4;
    return float3(clamp(d, 0.0, 1.0), d > 0.0 && d < 1.0 ? n.yz * 3.4 : float2(0.0));
}
inline float3 hp_skyDir(float3 rd) { return normalize(float3(rd.x, max(rd.y, 0.0) * 0.97 + 0.03, rd.z)); }

// Distant ranges beyond the marched world (> 33 km): two silhouette layers as a function of
// azimuth only — cheap, crisp and analytically anti-aliased.
inline float hp_ridge1(float x, float seed) {
    float s = 0.0, a = 0.5, w = 1.0;
    for (int i = 0; i < 2; i++) {
        float r = 1.0 - abs(hp_gn(float2(x, seed)) * 1.6);
        r *= r; s += a * r * w; w = clamp(r * 1.8, 0.0, 1.0);
        a *= 0.45; x = x * 2.13 + 1.7;
    }
    return s;
}

// ---------------------------------------------------------------- night sky
inline float3 hp_rotAxis(float3 v, float3 k, float a) {
    float c = cos(a), s = sin(a);
    return v * c + cross(k, v) * s + k * dot(k, v) * (1.0 - c);
}
inline float3 hp_stars(float3 rd, float pix, WSCtx ctx) {
    float3 pole = normalize(float3(0.852, 0.523, 0.0));   // celestial pole, north = +x
    float3 d = hp_rotAxis(rd, pole, -(ctx.dayTime + ctx.dayOfYear * 0.0657) * 0.2618);
    float3 col = float3(0.0);
    float3 gp = normalize(float3(0.25, 0.45, -0.86));
    float b = dot(d, gp);
    float band = exp(-b * b / 0.018);
    if (band > 0.01) {
        float3 t1 = normalize(cross(gp, float3(0.0, 0.0, 1.0)));
        float3 t2 = cross(gp, t1);
        float2 mq = float2(atan2(dot(d, t2), dot(d, t1)) * 9.0, b * 14.0);
        float cl = hp_fbmv(mq * 2.0, 5.0) + 0.5;
        float dust = hp_fbmv(mq * 3.3 + 11.0, 4.0);
        float lanes = mix(1.0, 0.3, smoothstep(-0.02, 0.16, dust));
        col += mix(float3(0.52, 0.58, 0.82), float3(0.96, 0.87, 0.72), cl * 0.6) * band * (0.55 + 0.75 * cl) * lanes * 0.0085;
    }
    for (int L = 0; L < 2; L++) {
        float N = L == 0 ? 150.0 : 300.0;
        float3 q = d * N + float(L) * 17.0;
        float3 c = floor(q);
        float3 h = hash33(c);
        float prob = L == 0 ? 0.30 : 0.35 * (0.5 + 1.5 * band);
        if (h.x < prob) {
            float3 sp = normalize((c + 0.2 + 0.6 * hash33(c + 5.0)) - float(L) * 17.0);
            float ang = length(d - sp);
            float sig = pix * 0.8;
            float mag = pow(h.y, 9.0) * (L == 0 ? 1.0 : 0.3);
            float gl = exp(-ang * ang / (2.0 * sig * sig));
            float3 tint = mix(float3(1.0, 0.78, 0.6), float3(0.75, 0.85, 1.0), h.z);
            col += tint * gl * (0.0007 + 0.07 * mag) * (L == 0 ? 1.0 : 0.6);
        }
    }
    return col;
}

inline float2 hp_box(float3 ro, float3 rd, float3 c, float3 hs) {
    float3 inv = 1.0 / rd;
    float3 t0 = (c - hs - ro) * inv, t1 = (c + hs - ro) * inv;
    float3 mn = min(t0, t1), mx = max(t0, t1);
    return float2(max(max(mn.x, mn.y), mn.z), min(min(mx.x, mx.y), mx.z));
}

// ---------------------------------------------------------------- scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float3 sun = ws_rotY(ctx.sunDir, -PI * 0.5);
    float3 moon = ws_rotY(ctx.moonDir, -PI * 0.5);
    float el = ctx.sunElevation;
    float pix = 2.0 * tan(HP_FOV * 0.5 * HP_DEG) / ctx.res.y;

    float3 ro = float3(700.0, 1500.0, 9000.0);
    float3 ta = float3(-1000.0, 1250.0, -12600.0);
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ta, HP_FOV);

    // --- weather that varies over the day, so the hours are different pictures, not one filter
    float dt = ctx.dayTime;
    float cBias = 0.085 * sin((dt - 7.4) * 0.2618) - 0.02;            // cumulus build through the afternoon
    float clyH = 3450.0 + 1300.0 * smoothstep(6.5, 14.0, dt) - 520.0 * smoothstep(16.5, 21.0, dt);
    float hazeK = 0.80 + 0.52 * smoothstep(5.0, 14.5, dt) * (1.0 - 0.42 * smoothstep(16.0, 21.5, dt));
    // --- light rig
    float3 zen = hp_zenT(el);
    float night = 1.0 - smoothstep(-15.0, -4.0, el);
    float mUp = smoothstep(-0.04, 0.15, moon.y);
    float3 nightFloor = float3(0.0016, 0.0022, 0.0042) * (1.0 + 1.8 * ctx.moonIllum * mUp);
    float3 ambSky = zen + nightFloor;
    float3 sunI = float3(4.4);
    float3 moonI = float3(0.55, 0.66, 0.95) * 0.016 * ctx.moonIllum * mUp;
    float expo = min(0.42 / pow(ws_luma(ambSky), 0.72), 38.0) * mix(1.0, 0.62, night);
    expo *= 1.0 - 0.35 * smoothstep(12.0, 3.0, el) * smoothstep(-8.0, -1.0, el);   // keep the sunset glow saturated

    // --- terrain march (secant refine)
    // terrain within 3 km of the camera stays below ~910 m: start the march where it could first be hit
    float t = min(3000.0, (ro.y - 950.0) / max(-rd.y, 1e-4)), tHit = -1.0;
    float minR = 1e9, tMin = 0.0;
    float lastT = t, lastD = 0.0, tGr = -1.0;
    int it = 0;
    float2 rh = normalize(rd.xz);
    float2 pc = HP_PK - ro.xz;
    bool viaPk = abs(rh.x * pc.y - rh.y * pc.x) < HP_PKR * 1.5 && dot(rh, pc) > 0.0;
    float topL = viaPk ? HP_TOP : 2150.0;          // nothing but the peak rises above ~2070 m
    if (rd.y > 0.36) t = 1e6;
    for (int i = 0; i < 46; i++) {
        it++;
        float3 p = ro + rd * t;
        if (p.y > topL && rd.y > 0.0) break;
        float dd = p.y - hp_hM(p, t, pix);
        if (dd < 0.0) {
            // regula falsi refinement (2 extra evaluations) for a stable hit position
            float ta = lastT, da = lastD, tb = t, db = dd;
            for (int j = 0; j < 1; j++) {
                float tm = ta + (tb - ta) * da / max(da - db, 1e-3);
                float3 pm = ro + rd * tm;
                float dm = pm.y - hp_hM(pm, tm, pix);
                if (dm > 0.0) { ta = tm; da = dm; } else { tb = tm; db = dm; }
            }
            tHit = ta + (tb - ta) * da / max(da - db, 1e-3);
            break;
        }
        float ratio = dd / (t * pix);
        if (ratio < minR && t > 1500.0) { minR = ratio; tMin = t; }
        if (ratio < 0.35 && tGr < 0.0) tGr = t;              // grazed a crest within a third of a pixel
        lastT = t; lastD = dd;
        float dpk = viaPk ? length(p.xz - HP_PK) - HP_PKR * 1.5 : 1e5;
        bool nearPk = dpk < 0.0 && p.y < HP_TOP;
        float L = nearPk ? 1.7 : 0.5;
        float st = max(dd * (nearPk ? 1.12 : 1.2) / max(L - rd.y, 0.12), 0.4 + t * (nearPk ? 0.003 : 0.0135 * clamp(dd / (t * 0.02), 0.30, 1.0)));
        if (dpk > 0.0) st = min(st, max(dpk, 60.0) / max(length(rd.xz), 0.1));
        t += st;
        if (t > 33000.0) break;
    }
    // a crest the coarse steps jumped through: keep it instead of the terrain behind it
    if (tGr > 0.0 && tHit > tGr * 1.15) tHit = tGr;
    // ran out of steps while grazing the ground: it is terrain, not a crack of sky
    if (tHit < 0.0 && it >= 46 && (rd.y < 0.0 || lastD < 1.5 * pix * lastT)) tHit = lastT;
    if (HP_DBG) return float3(float(it) / 40.0, float(it) > 40.0 ? 1.0 : 0.0, 0.0);

    // ---------------- terrain
    float cover = 0.0;
    float tS = tHit;
    if (tHit < 0.0 && minR < 1.0 && tMin > 0.0) {
        // partial silhouette coverage from the ray's closest approach (in pixels); squared so
        // only a near-graze reads as solid rock and the crest fringe stays soft
        float u = 1.0 - clamp(minR, 0.0, 1.0); tS = tMin; cover = u * u * 0.9;
    }
    else if (tHit > 0.0) cover = 1.0;

    bool needSky = tS < 0.0 || cover < 1.0;
    float dAz = acos(clamp(dot(normalize(rd.xz), normalize(sun.xz + float2(1e-6, 0.0))), -1.0, 1.0)) / HP_DEG;
    float3 skyE = hp_hazeT(el, dAz) + nightFloor;          // haze / horizon colour (table lookup)
    float3 skyV = skyE;
    if (needSky) {
        skyV = hp_atmoLite(hp_skyDir(rd), sun, 1200.0);
    }
    // ---------------- sky
    float3 skyCol = float3(0.0);
    if (needSky) {
        float3 s = skyV + nightFloor * (1.0 + 2.5 * pow(1.0 - max(rd.y, 0.0), 6.0));
        if (night > 0.0) s += hp_stars(rd, pix, ctx) * night * smoothstep(0.0, 0.06, rd.y);
        // moon (phase from the real sun direction)
        float mr = 0.42 * HP_DEG;
        float ma = acos(clamp(dot(rd, moon), -1.0, 1.0));
        if (ma < mr * 1.5 && moon.y > -0.03) {
            float3 mu = normalize(cross(moon, float3(0.0, 1.0, 0.0)));
            float3 mv = cross(mu, moon);
            float2 mp = float2(dot(rd, mu), dot(rd, mv)) / mr;
            float rr = length(mp);
            float3 nrm = mp.x * mu + mp.y * mv - sqrt(max(1.0 - rr * rr, 0.0)) * moon;
            float lit = smoothstep(-0.06, 0.08, dot(nrm, sun));
            float mare = 0.78 + 0.5 * hp_fbmv(mp * 1.8 + 4.0, 3.0);
            float edge = 1.0 - smoothstep(1.0 - 1.5 * pix / mr, 1.0, rr);
            float3 mcol = float3(1.0, 0.97, 0.9) * (mare * lit + 0.02) * 0.12;
            s = mix(s, s * 0.35 + mcol, edge);
        }
        s += float3(0.55, 0.65, 0.9) * 0.0012 * ctx.moonIllum * mUp * exp(-ma * 14.0);
        s += ws_sunDisk(rd, sun, 0.29, hp_sunTrans(el + 0.2) * 4000.0);
        // multi-scale forward glow around the disc (aureole → wide bloom), warmed by the same transmittance
        { float sa = max(1.0 - dot(rd, sun), 0.0);
          float3 sg = hp_sunTrans(el + 0.2) * sunI;
          s += sg * (0.26 * exp(-sa * 26000.0) + 0.085 * exp(-sa * 2600.0)
                   + 0.026 * exp(-sa * 320.0) + 0.0075 * exp(-sa * 44.0)); }
        // clouds
        if (rd.y > 0.0) {
            float tc = (clyH - ro.y) / rd.y;
            float2 cp = ro.xz + rd.xz * tc;
            float coc = clamp(log2(2400.0 / max(tc * pix * 3.0, 1.0)), 1.0, 3.1);
            float3 cD = hp_cloudD(cp, ctx.time, coc, cBias);
            float cd = cD.x;
            if (cd > 0.001) {
                float3 Ls = normalize(float3(sun.x, max(sun.y, 0.03), sun.z));
                float cs = hp_cloudD(cp + Ls.xz * 500.0, ctx.time, 1.0, cBias).x;
                float dip = sqrt(2.0 * clyH / 6.371e6) / HP_DEG;
                float3 sT = hp_sunTrans(el + dip);
                float ph = 0.35 + 5.0 * hp_hg(dot(rd, sun), 0.6);
                // fake relief: treat density as cloud-top height, light its slopes
                float3 cn = normalize(float3(-cD.y * 900.0, 1.0, -cD.z * 900.0));
                float form = 0.45 + 0.85 * max(dot(cn, Ls), 0.0);
                float3 lit = sT * sunI * 0.22 * (exp(-cs * 2.0) * ph * form + 0.15) + (ambSky * 1.1 + skyV * 0.35) + moonI * 0.3;
                lit *= mix(1.0, 0.62, cd * cd);
                float a = smoothstep(0.0, 0.7, cd) * smoothstep(0.0, 0.08, rd.y) * mix(0.5, 1.0, smoothstep(-12.0, 1.0, el));
                s = mix(s, mix(lit, skyV, 1.0 - exp(-tc * 0.000022)), a * 0.94);
            }
        }
        // distant backdrop ranges
        if (rd.y < 0.09) {
            float az = atan2(rd.x, -rd.z);
            float e = rd.y / length(rd.xz);
            float covered = 0.0;
            for (int L = 0; L < 2; L++) {
                if (covered >= 0.999) break;
                float D = L == 0 ? 36000.0 : 52000.0;
                float hgt = L == 0 ? 700.0 + 1300.0 * hp_ridge1(az * 8.0 + 11.0, 3.1) : 1100.0 + 1700.0 * hp_ridge1(az * 5.0 + 2.0, 7.3);
                float eTop = (hgt - ro.y) / D - D / 12742000.0;
                float cv = clamp((eTop - e) / pix + 0.5, 0.0, 1.0);
                if (cv > 0.0) {
                    float yA = 0.5 * (ro.y + hgt * 0.6);
                    float fA = 1.0 - exp(-D * hazeK * (0.000013 + 0.000055 * exp(-max(yA - 100.0, 0.0) / 1300.0)));
                    float dipB = sqrt(2.0 * hgt / 6.371e6) / HP_DEG;
                    float3 sTb = hp_sunTrans(el + dipB);
                    float rim = smoothstep(0.004, 0.0, eTop - e) * 0.6;
                    float3 cB = float3(0.07, 0.075, 0.08) * (ambSky * 1.3 + sTb * sunI * (0.12 + rim * max(dot(normalize(float3(rd.x, 0.0, rd.z)), sun), 0.0)) + moonI * 0.3 + nightFloor);
                    float3 fogB = mix(skyE, float3(ws_luma(skyE)), 0.25) * min(1.0, mix(1.15, 1.8, smoothstep(2.0, 20.0, el)) * ws_luma(ambSky) / max(ws_luma(skyE), 1e-5)) + nightFloor * 1.5;
                    float3 layer = mix(cB, fogB, fA);
                    s = L == 0 ? mix(s, layer, cv) : mix(mix(s, layer, cv), s, covered);
                    covered = max(covered, cv);
                }
            }
        }
        s = mix(s, float3(ws_luma(s)), 0.3 * night);
        skyCol = s;
    }
    float3 col = skyCol;

    // hut (ray/box: walls + slate roof)
    float3 hutC = float3(HP_HUT.x, 59.0, HP_HUT.y);           // ground height at the hut
    float2 hw = hp_box(ro, rd, hutC + float3(0.0, 2.0, 0.0), float3(5.0, 2.6, 3.2));
    float2 hr = hp_box(ro, rd, hutC + float3(0.0, 5.0, 0.0), float3(5.6, 0.7, 3.8));
    bool hutWall = hw.x < hw.y && hw.x > 0.0 && (tS < 0.0 || hw.x < tS);
    bool hutRoof = hr.x < hr.y && hr.x > 0.0 && (tS < 0.0 || hr.x < tS) && (!hutWall || hr.x < hw.x);
    if (hutRoof) hutWall = false;
    bool hut = hutWall || hutRoof;
    float dayK = smoothstep(-3.0, 4.0, el);

    if (tS > 0.0 || hut) {
        float tt = hutWall ? hw.x : (hutRoof ? hr.x : tS);
        float3 p = ro + rd * tt;
        float lod = hp_lod(tt, pix);
        float wl = hp_water(p.z);
        float4 vA = hp_vn4(p.xz * 0.0021 + 0.37);
        float4 vB = hp_vn4(p.xz * 0.0087 + 5.1);
        // forest/clearing field is sampled on a doubly domain-warped position, so the
        // underlying noise ellipses come out torn and organic instead of stamped ovals
        float2 wp = p.xz + (vA.zw - 0.5) * 900.0 + (vB.zw - 0.5) * 170.0;
        float4 vC = hp_vn4(wp * 0.0019 + 6.3);
        float fm = hp_forestM(p.xz, p.y, vC, vB);
        // height + normal: analytic noise gradients, macro by 3 taps
        float e = max(tt * pix, 0.5);
        float4 nE = hp_efbmD(p.xz * HP_NS + float2(3.7, 1.3), min(lod - 1.5, 2.0));
        float2 gN = nE.yz * HP_NS;
        float h0 = hp_baseN(p.xz, nE.x);
        float hx = hp_baseN(p.xz + float2(e, 0.0), nE.x + gN.x * e);
        float hz = hp_baseN(p.xz + float2(0.0, e), nE.x + gN.y * e);
        float2 grad = float2(hx - h0, hz - h0) / e;
        float slopeM = 1.0 / sqrt(1.0 + dot(grad, grad));
        float fpx = tt * pix;
        // river: wandering banks, width that pools and narrows along its length
        float rcx = hp_riverX(p.z);
        float rw = max(hp_riverW(p.z) + 5.0 * (vB.x - 0.5), 3.5);
        float dr = abs(p.x - rcx);
        float dmask = smoothstep(40.0, 300.0, dr);
        float3 fD = float3(0.0);
        // rock-ridge relief on steep ground (ridged gradient noise, octaves faded by footprint)
        float2 q = p.xz - HP_PK;
        float qr = length(q);
        float pkK = clamp(1.0 - qr / (HP_PKR * 1.1), 0.0, 1.0);
        float gl = length(grad);
        // macro fall-line frame (varies over kilometres only, so the pattern does not swirl)
        float su = p.x - hp_riverX(p.z);
        float2 wallDir = normalize(float2(su >= 0.0 ? 1.0 : -1.0, 0.25 * sin(p.z * 0.0004 + p.x * 0.0003)));
        float2 gdir = normalize(mix(wallDir, q / max(qr, 1.0), smoothstep(0.0, 0.25, pkK)));
        float2 gac = float2(-gdir.y, gdir.x);
        float steep = smoothstep(0.12, 0.7, gl) * dmask;
        // erosion gullies: ridged noise STRETCHED ALONG THE FALL LINE, so walls read as
        // water-carved spurs and re-entrants rather than isotropic "fingerprint" worms
        if (steep > 0.0 && pkK < 0.6 && fpx < 12.0) {
            float A = 92.0 * steep * (1.0 - pkK) * (0.45 + 1.1 * vA.x), f = 0.0019, w = 1.0;
            float2 ax0 = float2(dot(p.xz, gac), dot(p.xz, gdir));
            float2 warp = float2(0.0);
            for (int k = 0; k < 3; k++) {
                float fade = clamp(1.0 / (f * fpx * (8.5 + 7.0 * float(k))) - 1.0, 0.0, 1.0);
                if (fade <= 0.0) break;
                // octave 0 runs down the fall line (gullies), octave 1 across it (benches and
                // spurs), octave 2 isotropic — a crosshatch instead of a parallel comb
                float2 sc = k == 0 ? float2(1.0, 0.52) : (k == 1 ? float2(0.40, 1.0) : float2(1.0, 0.9));
                float3 gn = hp_gnD(ax0 * sc * f + warp + float(k) * 5.13);
                float ep = 0.06 + 0.9 * clamp(f * fpx, 0.0, 0.12);
                float axs = sqrt(gn.x * gn.x + ep * ep);
                float r = 1.0 - axs * 1.8;
                float v = A * fade * w * (r * r - 0.5);
                h0 += v; fD.x += v;
                float2 g2 = A * fade * w * 2.0 * r * (-1.8 * gn.x / axs) * f * gn.yz * sc;
                grad += g2.x * gac + g2.y * gdir;
                warp += gn.yz * 0.55;                      // each octave meanders on the last
                w = clamp(r * r * 1.5, 0.35, 1.0);
                A *= 0.58; f *= 2.35;
            }
        }
        // the peak: isotropic ridged rock detail (sharp aretes and buttresses)
        float3 pr = hp_pkRock(q, fpx, 3);
        float rockD = pr.x;
        h0 += pr.x; grad += pr.yz;
        float3 nB = normalize(float3(-grad.x, 1.0, -grad.y));
        bool water = !hut && h0 < wl + 0.3 && dr < rw * 1.45;
        float cav = clamp(0.5 + (nE.w * 600.0 + fD.x) / 50.0, 0.0, 1.0);
        if (!hut) p.y = water ? wl : h0;

        float slope = mix(slopeM, nB.y, 0.10);   // material masks follow macro relief, not micro bumps
        float relH = p.y - hp_floor(p.z);
        float nz1 = vB.y;
        float nz2 = mix(0.5, hp_vn(p.xz * 0.043 + 3.0), clamp(8.0 / fpx - 0.5, 0.0, 1.0));
        float mbr2 = nz2 - 0.5;                                                      // fine edge tear
        float mbr = (vB.w - 0.5) * 0.66 + (vB.z - 0.5) * 0.28 + mbr2 * 0.46;          // multi-scale breakup
        // rock: grey-brown, faint tilted bedding
        float3 rock = mix(float3(0.13, 0.13, 0.135), float3(0.26, 0.25, 0.24), nz1 * 0.7 + nz2 * 0.3);
        float strata = 0.5 + 0.5 * sin((p.y + 0.25 * p.x + 120.0 * vA.w) * 0.035);
        rock *= 0.82 + 0.3 * strata;
        rock = mix(rock, rock * float3(1.18, 0.97, 0.8), smoothstep(0.5, 0.85, vB.w * 0.4 + vA.z * 0.6));
        // below the treeline the ground between trees is dark soil and duff, not pale granite
        rock = mix(float3(0.050, 0.046, 0.036) * (0.7 + 0.7 * nz2), rock, smoothstep(1050.0, 1950.0, p.y + 320.0 * (nz1 - 0.5)));
        // meadows: lush on the floor, tawny alpine grass higher up
        float3 grass = mix(float3(0.045, 0.065, 0.024), float3(0.085, 0.10, 0.042), nz2);
        grass *= 0.85 + 0.3 * vB.z;
        grass = mix(grass, float3(0.105, 0.105, 0.062), smoothstep(900.0, 1700.0, p.y + 250.0 * nz1));
        grass *= mix(0.72, 1.0, smoothstep(400.0, 60.0, relH));
        float grassK = smoothstep(0.44, 0.78, slope + 0.25 * mbr + 0.20 * mbr2 - 0.0011 * clamp(fD.x, 0.0, 70.0)) * smoothstep(2250.0, 1700.0, p.y + 350.0 * nz1);
        // scree below rock bands
        float scree = smoothstep(1500.0, 1900.0, p.y + 200.0 * mbr) * smoothstep(0.62, 0.72, slope) * (1.0 - smoothstep(0.76, 0.88, slope)) * 0.45;
        float outcrop = smoothstep(30.0, 68.0, fD.x) * smoothstep(0.8, 0.6, slope) * smoothstep(350.0, 650.0, relH);
        float3 alb = mix(rock, grass, max(grassK, fm * 0.9) * (1.0 - outcrop));
        alb = mix(alb, float3(0.21, 0.205, 0.19) * (0.8 + 0.4 * nz2), scree);
        // conifer forest: avalanche paths stretched down the fall line + multi-frequency edge tear
        float aval = hp_vn(float2(dot(p.xz, gac) * 0.0035, dot(p.xz, gdir) * 0.0007) + 4.0);
        float fmS = smoothstep(0.35, 0.65, fm + 0.5 * mbr + 0.42 * mbr2 + 0.45 * (aval - 0.5)) * smoothstep(0.40, 0.62, slope + 0.2 * mbr);
        // --- canopy: crown-level relief that lights per crown, faded out by pixel footprint
        float canT = 0.5, canAO = 1.0;
        if (fmS > 0.006) {
            float f1 = clamp(44.0 / max(fpx * 7.0, 0.05) - 1.0, 0.0, 1.0);     // ~44 m stand structure
            float f2 = clamp(21.0 / max(fpx * 7.0, 0.05) - 1.0, 0.0, 1.0);     // ~21 m crown clumps
            float f3 = clamp(6.0 / max(fpx * 3.2, 0.05) - 1.0, 0.0, 1.0);      // ~6 m crowns, albedo only
            float A1 = 12.0 * f1, A2 = 8.6 * f2;
            float2 cg = float2(0.0); float hC = 0.0, hN = 1e-3;
            if (A1 > 0.0) { float3 k1 = hp_noised(p.xz * 0.023 + 13.0); hC += A1 * (k1.x - 0.5); cg += A1 * 0.023 * k1.yz; hN += A1; }
            if (A2 > 0.0) { float3 k2 = hp_noised(p.xz * 0.048 + 2.3);  hC += A2 * (k2.x - 0.5) * 1.15; cg += A2 * 0.048 * k2.yz * 1.15; hN += A2 * 1.15; }
            grad += cg * fmS;
            canT = clamp(0.5 + hC / hN + (f3 > 0.0 ? (hp_vn(p.xz * 0.17 + 5.7) - 0.5) * 1.3 * f3 : 0.0), 0.0, 1.0);
            canAO = mix(1.0, mix(0.40, 1.04, canT), fmS * max(f1, max(f2, f3 * 0.6)));
        }
        // cap the total slope: keeps a rare grazing detail normal from firing a lone bright sample
        { float gm = length(grad); if (gm > 3.1) grad *= 3.1 / gm; }
        float3 n = normalize(float3(-grad.x, 1.0, -grad.y));
        float3 pine = mix(float3(0.0050, 0.0106, 0.0066), float3(0.051, 0.069, 0.034), canT * canT * 0.65 + canT * 0.35) * (0.82 + 0.36 * nz2);
        alb = mix(alb, pine, fmS);
        // snow: fields above the snowline, gullies and ledges hold it longer
        float snowL = 2350.0 + 380.0 * (vA.z - 0.5);
        float snow = smoothstep(snowL - 120.0, snowL + 260.0, p.y) * smoothstep(0.52, 0.72, slope + 0.1 * nz2 + 0.35 * mbr + 0.4 * (cav - 0.5));
        snow = max(snow, smoothstep(snowL + 700.0, snowL + 1300.0, p.y) * smoothstep(0.4, 0.62, slope + 0.2 * nz2 + 0.35 * (cav - 0.5)));
        if (pkK > 0.0) {
            // peak: snow on everything flat enough to hold it (ledges, crest shoulders, hollows)
            float hiK = smoothstep(1300.0, 2100.0, p.y + 250.0 * (nz1 - 0.5));
            float hold = smoothstep(0.50, 0.80, nB.y + 0.12 * mbr + 0.34 * mbr2 - 0.0036 * rockD + 0.12 * smoothstep(2400.0, 3300.0, p.y));
            snow = mix(snow, hiK * hold, smoothstep(0.0, 0.3, pkK));
        }
        if (pkK > 0.0) {
            // dark gneiss, two decorrelated sets of tilted bedding bands
            float bph = p.y * 0.58 + 0.70 * p.x - 0.42 * p.z;     // bedding dips ~30 deg
            float band = 0.5 + 0.5 * sin(bph * 0.019 + 5.0 * mbr + 3.0 * nz1);
            float band2 = 0.5 + 0.5 * sin(bph * 0.071 + 6.5 * mbr + 2.0 * nz2);
            float bandM = clamp(band * (0.48 + 0.52 * band2) * 1.18 - 0.06, 0.0, 1.0);
            float3 pkRockC = mix(float3(0.044, 0.042, 0.046), float3(0.132, 0.122, 0.109), bandM) * (0.84 + 0.32 * nz2);
            pkRockC *= 1.0 - 0.28 * smoothstep(20.0, -40.0, rockD);        // shaded rib hollows
            alb = mix(alb, pkRockC, smoothstep(0.0, 0.3, pkK) * (1.0 - grassK));
        }
        // snow: granular, footprint-faded micro-relief so the fields are not glassy facets
        float snMic = 0.0;
        if (snow > 0.0) {
            float sf = clamp(2.6 / max(fpx * 2.5, 0.05) - 0.4, 0.0, 1.0);
            if (sf > 0.0) {
                float3 sg = hp_noised(p.xz * 0.42 + 8.0);
                n = normalize(float3(-(grad.x + sg.y * 0.42 * 2.6 * sf * snow), 1.0, -(grad.y + sg.z * 0.42 * 2.6 * sf * snow)));
                snMic = (sg.x - 0.5) * sf;
            }
        }
        alb = mix(alb, float3(0.80, 0.83, 0.88) * (0.92 + 0.08 * nz2 + 0.05 * snMic), snow);
        // river: wet stones and gravel along the water line
        alb = mix(alb, float3(0.135, 0.132, 0.122) * (0.75 + 0.5 * nz2), smoothstep(rw * 2.0, rw * 1.05, dr) * smoothstep(12.0, 3.0, relH));
        if (hutWall) { alb = float3(0.42, 0.40, 0.37); n = normalize(float3(0.35, 0.0, sign(ro.z - p.z))); }
        if (hutRoof) { alb = float3(0.06, 0.055, 0.05); n = float3(0.0, 1.0, 0.0); }

        // sun, with Earth-shadow height correction (alpenglow on the summit)
        float dipT = sqrt(2.0 * max(p.y, 0.0) / 6.371e6) / HP_DEG;
        float3 sT = hp_sunTrans(el + dipT);
        float sh = 1.0;
        float3 Ls = normalize(float3(sun.x, max(sun.y, 0.0) + 0.004, sun.z));
        float ndl0 = dot(n, sun);
        if (ws_luma(sT) > 0.0004 && ndl0 > 0.0 && tt < 16000.0) {
            float3 pS = ro + rd * tt + float3(0.0, 4.0, 0.0);
            float st = 10.0 + tt * 0.004, res = 1.0;
            int nSh = el > 25.0 ? 1 : 2;
            for (int i = 0; i < nSh; i++) {
                float3 sp = pS + Ls * st;
                if (sp.y > HP_TOP) break;
                float dq = sp.y - hp_base(sp.xz, 1.0) + 30.0;
                res = min(res, 4.0 * dq / st);
                if (res < -0.05) break;
                st += clamp(dq * 2.2, 150.0 + st * 2.5, 7000.0);
                if (st > 26000.0) break;
            }
            sh = smoothstep(0.0, 1.0, res);
            float tcl = (clyH - p.y) / max(Ls.y, 0.06);
            float cd = hp_cloudD(p.xz + Ls.xz * tcl, ctx.time, 1.0, cBias).x;
            sh *= 1.0 - 0.62 * smoothstep(0.03, 0.8, cd) * smoothstep(0.0, 0.1, Ls.y);
        }
        // sky light arriving from the horizon the surface faces (Belt-of-Venus pink on east faces at dusk)
        float2 nh = n.xz + float2(1e-5, 0.0);
        float dAzN = acos(clamp(dot(normalize(nh), normalize(sun.xz + float2(1e-6, 0.0))), -1.0, 1.0)) / HP_DEG;
        float3 skyN = hp_hazeT(el, dAzN) * 0.8 + nightFloor;
        float ndl = max(dot(n, sun), 0.0);
        float skyW = 0.5 + 0.5 * n.y;
        float ao = mix(0.34, 1.0, cav) * (1.0 - 0.5 * fmS) * canAO * (hutWall ? 0.8 : 1.0);
        // warm ground bounce from the sunlit opposite wall — strongest when the sun is low
        float lowS = smoothstep(14.0, 1.0, el) * smoothstep(-5.0, 2.0, el);
        float3 bounce = sT * sunI * (0.022 + 0.052 * lowS) * mix(float3(1.0), float3(1.85, 1.05, 0.48), lowS);
        float3 lin = sT * sunI * ndl * sh
                   + (ambSky * skyW * 1.15 + skyN * (1.0 - skyW) * 0.5 + nightFloor * 1.5) * ao
                   + moonI * max(dot(n, moon), 0.0) * ao
                   + bounce * (1.0 - skyW) * ao;
        float3 c = alb * lin;
        // snow sheen: broad rough lobe plus a granular, footprint-faded glint (never sub-pixel)
        if (snow > 0.0) {
            float sp0 = max(dot(reflect(rd, n), sun), 0.0);
            c += snow * sT * sunI * sh * (0.022 * pow(sp0, 5.0) + 0.030 * pow(sp0, 40.0) * (0.45 + 0.9 * (0.5 + snMic)));
        }

        if (water) {
            float tW = ctx.time;
            float2 wq = p.xz * float2(0.048, 0.012);
            float wv = hp_vn(wq + float2(0.0, tW * 0.05)) - hp_vn(wq * 1.7 + float2(3.1, -tW * 0.04));
            float wf = clamp(2.2 / max(fpx * 2.5, 0.05) - 0.3, 0.0, 1.0);          // fine chop, faded by footprint
            float wv2 = wf > 0.0 ? (hp_vn(p.xz * float2(0.33, 0.085) + float2(0.7, -tW * 0.10)) - 0.5) * wf : 0.0;
            float3 wn = normalize(float3(wv * 0.055 + wv2 * 0.19, 1.0, wv * 0.028 + wv2 * 0.07));
            float3 rr = reflect(rd, wn);
            float fres = 0.025 + 0.975 * pow(1.0 - max(dot(-rd, wn), 0.0), 5.0);
            float dAzR = acos(clamp(dot(normalize(rr.xz), normalize(sun.xz + float2(1e-6, 0.0))), -1.0, 1.0)) / HP_DEG;
            float3 refl = mix(hp_hazeT(el, dAzR), zen * 1.3, smoothstep(0.02, 0.5, rr.y)) + nightFloor;
            // a shallow reflected ray leaves the channel into the opposite valley wall, not the sky:
            // that is what stops the river reading as a uniform glowing inlay at low sun
            float wallK = smoothstep(0.46, 0.13, rr.y) * 0.82;
            refl = mix(refl, alb * lin * 1.15 + ambSky * 0.35, wallK);
            float3 deep = float3(0.020, 0.036, 0.038) * (ambSky * 1.5 + sT * sunI * 0.10 * sh);
            float3 wcol = mix(deep, refl, clamp(fres, 0.02, 0.92));
            // broken sun glitter rather than one clipped ribbon
            float gsp = pow(max(dot(rr, sun), 0.0), 320.0);
            wcol += sT * sunI * sh * gsp * 1.3 * smoothstep(0.30, 0.80, 0.5 + wv2 + 0.35 * wv);
            // white water: rapids where the bed steepens, slack pools between
            float rapN = hp_vn(float2(p.z * 0.0032, p.x * 0.011) + 31.0);
            float rap = smoothstep(0.50, 0.82, rapN + 0.45 * (hp_vn(p.xz * 0.055 + 7.0) - 0.5)) * smoothstep(rw, rw * 0.35, dr);
            float3 foamL = sT * sunI * max(sun.y, 0.0) * sh * 0.85 + ambSky * 2.1 + nightFloor * 2.0;
            wcol = mix(wcol, float3(0.50, 0.53, 0.56) * foamL, rap * 0.85);
            float bank = smoothstep(rw * 0.70, rw, dr);
            c = mix(wcol, c, bank);
        }
        if (hutWall) {
            float3 lp = p - hutC;
            float win = step(abs(lp.x - 1.1), 0.7) * step(abs(lp.y - 1.9), 0.6);
            c = mix(c, float3(1.0, 0.55, 0.22) * 0.25 * (1.0 - dayK), win * (1.0 - dayK));
        }

        // aerial perspective (fog colour capped so the sun's glow cannot wash the valley)
        float yAv = 0.5 * (ro.y + p.y);
        float fogA = 1.0 - exp(-tt * hazeK * (1.0 + 1.15 * smoothstep(11000.0, 30000.0, tt)) * (0.000013 + 0.000055 * exp(-max(yAv - 100.0, 0.0) / 1300.0)));
        float glow = 1.0 + 1.3 * pow(max(dot(rd, sun), 0.0), 24.0) * (1.0 - smoothstep(8.0, 25.0, el));
        float3 fogC = mix(skyV, float3(ws_luma(skyV)), 0.25) * min(1.0, mix(1.15, 1.8, smoothstep(2.0, 20.0, el)) * glow * ws_luma(ambSky) / max(ws_luma(skyV), 1e-5)) + nightFloor * 1.5;
        c = mix(c, fogC, fogA);
        // morning valley mist (and a thin evening one)
        float morning = smoothstep(4.3, 6.0, ctx.dayTime) * (1.0 - smoothstep(8.3, 10.3, ctx.dayTime));
        float evening = 0.52 * smoothstep(19.0, 20.8, ctx.dayTime) * (1.0 - smoothstep(22.6, 23.9, ctx.dayTime));
        float mistK = max(morning, evening);
        if (mistK > 0.0) {
            float2 mq = p.xz * 0.0011 + float2(ctx.time * 0.0035, ctx.time * 0.0012);
            float mh = 55.0 + 45.0 * hp_vn(mq * 0.7);
            float dens = 0.0030 * clamp(0.12 + 1.9 * hp_fbmv(mq, 3.0), 0.0, 1.0);
            float od = dens * mh / max(-rd.y, 0.04) * exp(-max(relH, 0.0) / mh);   // ray integral through the layer
            float mm = (1.0 - exp(-od)) * smoothstep(250.0, 1500.0, tt);
            float3 mistC = sT * sunI * 0.28 * (0.4 + 4.0 * hp_hg(dot(rd, sun), 0.55)) + ambSky * 1.5 + nightFloor * 2.0;
            c = mix(c, mistC, clamp(mm * mistK, 0.0, 0.84));
        }
        col = hut ? c : mix(skyCol, c, cover);
    }

    // window glow halo (analytic, stable at 1 spp)
    {
        float3 wp = hutC + float3(1.1, 1.9, 3.25);
        float ang = length(normalize(wp - ro) - rd);
        float g = exp(-ang * ang / (2.0 * pix * pix * 2.0)) * 0.7 + 0.1 * exp(-ang / (pix * 7.0)) + 0.02 * exp(-ang / (pix * 22.0));
        col += float3(1.0, 0.56, 0.22) * g * (1.0 - dayK) * 0.23;
    }

    col *= expo;
    float warmK = smoothstep(-3.0, 3.0, el) * (1.0 - smoothstep(6.0, 22.0, el));
    col *= mix(float3(1.0), float3(1.08, 1.0, 0.86), warmK);
    float2 uv = fragCoord / ctx.res;
    col *= ws_vignette(uv, 0.3);
    float3 o = ws_acesFitted(col);
    o = mix(o, o * o * (3.0 - 2.0 * o), 0.12);                 // gentle S-curve
    o += ws_grain(fragCoord, 0.37) * 0.0045 * (0.25 + 0.75 * ws_luma(o));
    return clamp(o, 0.0, 1.0);
}
