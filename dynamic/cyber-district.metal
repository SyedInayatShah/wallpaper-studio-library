// Cyber District — dynamic (time-of-day) cyberpunk street canyon seen from a rooftop.
// Analytic scene: per-lot facade rows traced with a short DDA, blade signs, rails,
// wet street with analytic blurred reflections, PB sky, clouds, rain, steam, traffic.
// View frame: camera looks down -z (world west), x = north(right), y = up.

constant float CW  = 20.0;   // canyon half-width to the nominal facade line
constant float LOT = 26.0;   // lot length along the street
constant float CAMY = 64.0;

struct CdLot { float off; float h; float sty; float h1; float sb; float dep; float4 a; float4 b; };

inline CdLot cdLot(float s, int i) {
    float fi = float(i);
    float4 a = hash24(float2(fi * 1.713 + 0.37, s * 5.19 + 11.0));
    float4 b = fract(a.wzyx * float4(13.13, 7.71, 5.37, 3.97) + float4(0.31, 0.57, 0.13, 0.79));
    CdLot L;
    L.off = floor(a.x * 3.0) * 1.8;
    float dz = -fi * LOT;
    L.h = s < 0.0 ? (a.w > 0.55 ? 210.0 + 220.0 * a.y : 85.0 + 80.0 * a.y)
                  : 50.0 + dz * 0.22 * (0.3 + 0.7 * a.y * a.y) + 80.0 * step(0.9, a.w) * step(450.0, dz);
    L.sty = floor(a.z * 3.0);
    L.a = a; L.b = b;
    bool pod = b.z > 0.45;
    L.h1 = pod ? 18.0 + 40.0 * fract(a.x * 9.7) : L.h;
    L.sb = pod ? 4.0 + 7.0 * fract(a.y * 5.3) : 0.0;
    L.dep = 26.0 + 22.0 * fract(a.z * 11.3);
    // composition: right side near the camera is a low block (open sky top-right)
    if (s > 0.0 && i >= -2) { L.h = 58.0; L.off = 1.8; L.sty = 1.0; L.h1 = L.h; L.sb = 0.0; }
    if (s < 0.0 && i >= -2) { L.h = 360.0; L.off = 0.0; L.sty = 2.0; L.h1 = L.h; L.sb = 0.0; }
    return L;
}

inline float3 cdNeon(float h) {
    if (h < 0.30) return float3(1.0, 0.06, 0.50);
    if (h < 0.55) return float3(0.04, 0.72, 1.0);
    if (h < 0.74) return float3(1.0, 0.36, 0.04);
    if (h < 0.84) return float3(1.0, 0.08, 0.10);
    if (h < 0.93) return float3(0.50, 0.16, 1.0);
    return float3(0.80, 0.90, 1.0);
}

struct CdSign { bool ok; float zc; float x0; float x1; float y0; float y1; float3 col; float I; float type; float seed; };

inline CdSign cdSignOf(CdLot L, float s, int i, float time, float neonOn) {
    CdSign g;
    float4 b = L.b;
    g.ok = b.x < 0.72 && !(s > 0.0 && i >= -2);
    g.zc = float(i) * LOT + LOT * (0.2 + 0.6 * b.y);
    float d = 2.4 + 3.2 * b.z;
    g.x1 = CW + L.off - 0.25;
    g.x0 = g.x1 - d;
    g.y0 = 8.0 + 40.0 * b.w;
    g.y1 = g.y0 + 7.0 + 16.0 * fract(L.a.w * 7.31);
    g.y1 = min(g.y1, L.h - 2.0);
    float hc = fract(b.x * 13.71 + b.y * 3.1);
    g.col = cdNeon(hc);
    g.seed = fract(b.z * 17.3 + b.w * 5.7);
    g.type = step(0.55, fract(b.w * 11.3));
    // switched on progressively at dusk
    float on = smoothstep(g.seed * 0.8, g.seed * 0.8 + 0.2, neonOn * 1.05);
    // broken tubes flicker
    float fl = 1.0;
    if (g.seed > 0.86) {
        float n = fract(sin(floor(time * 7.0 + g.seed * 97.0) * 12.9898) * 43758.5453);
        fl = n > 0.3 ? 1.0 : 0.2;
    }
    g.I = on * fl * (3.0 + 3.0 * fract(g.seed * 9.1));
    return g;
}

// box-filtered periodic pulse (1 on [a,b] each unit period), filter width w in period units
inline float cdPulse(float x, float a, float b, float w) {
    w = max(w, 1e-4);
    float x0 = x - 0.5 * w, x1 = x + 0.5 * w;
    float F1 = floor(x1) * (b - a) + clamp(fract(x1), a, b) - a;
    float F0 = floor(x0) * (b - a) + clamp(fract(x0), a, b) - a;
    return clamp((F1 - F0) / w, 0.0, 1.0);
}
inline float cdLine(float d, float w, float fp) {
    fp = max(fp, 1e-4);
    return clamp((0.5 * (w + fp) - d) / fp, 0.0, 1.0) * min(1.0, w / fp);
}

// slab test for an axis-aligned box
inline float cdBox(float3 ro, float3 rd, float3 bmin, float3 bmax, thread float3& n) {
    float3 inv = 1.0 / rd;
    float3 t0 = (bmin - ro) * inv, t1 = (bmax - ro) * inv;
    float3 tn = min(t0, t1), tx = max(t0, t1);
    float a = max(max(tn.x, tn.y), tn.z), b = min(min(tx.x, tx.y), tx.z);
    if (a > b || a < 0.0) return 1e9;
    n = (a == tn.x) ? float3(-sign(rd.x), 0, 0) : (a == tn.y) ? float3(0, -sign(rd.y), 0) : float3(0, 0, -sign(rd.z));
    return a;
}

// ------------------------------------------------------------------ tracing
struct CdHit { float t; int kind; float3 n; float s; int lot; float mc; float mt; float ml; };
// kind: 0 sky, 1 street, 2 facade, 3 roof, 4 sign, 5 rail, 6 train, 7 bridge, 8 ledge, 9 skybridge, 10 tank, 11 plant box
// mc/mt/ml: antenna-mast coverage, distance and lamp (thin masts are blended, not hit, so they never alias)

// rooftop clutter of one lot: a water tank on legs + a mechanical penthouse; masts as coverage
inline void cdClutter(float3 ro, float3 rd, CdLot L, float s, float za, float pa, float tLim,
                      thread float& tc, thread float3& nc, thread int& kc, thread CdHit& h) {
    float4 rc = fract(L.a.yzwx * 5.13 + L.b.zwxy * 3.7);
    float x0 = CW + L.off + L.sb;                       // tower front line (above the podium)
    float dep = L.dep - L.sb;
    // penthouse / plant box
    if (rc.w < 0.8) {
        float bw = dep * (0.35 + 0.3 * rc.x), bl = LOT * (0.3 + 0.35 * rc.y);
        float bx0 = x0 + 2.5 + (dep - bw - 5.0) * rc.z, bz0 = za + 2.0 + (LOT - bl - 4.0) * rc.x;
        float bh = 3.2 + 3.5 * rc.y;
        float3 bmin = float3(s > 0.0 ? bx0 : -(bx0 + bw), L.h, bz0);
        float3 bmax = float3(s > 0.0 ? bx0 + bw : -bx0, L.h + bh, bz0 + bl);
        float3 n;
        float t = cdBox(ro, rd, bmin, bmax, n);
        if (t < tc && t < tLim) { tc = t; nc = n; kc = 11; }
    }
    // water tank (vertical cylinder on a steel stand)
    if (rc.z < 0.55) {
        float R = 1.8 + 1.1 * rc.w;
        float2 c = float2(s * (x0 + R + 1.5 + (dep - 2.0 * R - 3.0) * fract(rc.x * 7.3)), za + R + 1.5 + (LOT - 2.0 * R - 3.0) * fract(rc.y * 5.1));
        float y0 = L.h + 2.2, y1 = y0 + 4.0 + 2.5 * rc.x;
        float2 oc = ro.xz - c;
        float a = dot(rd.xz, rd.xz), b = dot(oc, rd.xz), cc = dot(oc, oc) - R * R;
        float disc = b * b - a * cc;
        if (disc > 0.0) {
            float t = (-b - sqrt(disc)) / a;
            float y = ro.y + rd.y * t;
            if (t > 0.0 && t < tc && t < tLim && y > y0 && y < y1) { tc = t; kc = 10; nc = float3((ro.xz + rd.xz * t - c).x / R, 0.0, (ro.xz + rd.xz * t - c).y / R); }
            else if (rd.y < 0.0) {       // conical-ish lid seen from above: flat cap
                float tt = (y1 - ro.y) / rd.y;
                float2 q = ro.xz + rd.xz * tt - c;
                if (tt > 0.0 && tt < tc && tt < tLim && dot(q, q) < R * R) { tc = tt; kc = 10; nc = float3(0, 1, 0); }
            }
        }
    }
    // antenna mast (coverage only)
    if (rc.y > 0.45) {
        float2 c = float2(s * (x0 + 2.0 + (dep - 4.0) * fract(rc.w * 3.7)), za + 3.0 + (LOT - 6.0) * fract(rc.z * 9.1));
        float mh = 7.0 + 22.0 * rc.x * rc.x + (L.h > 150.0 ? 18.0 : 0.0);
        float2 oc = c - ro.xz;
        float a = dot(rd.xz, rd.xz);
        float tm = dot(oc, rd.xz) / a;
        if (tm > 0.0 && tm < min(tc, tLim)) {
            float d = length(ro.xz + rd.xz * tm - c);
            float y = ro.y + rd.y * tm;
            float fp = tm * pa;
            float rad = 0.22 + 0.1 * rc.w;
            float taper = clamp((L.h + mh - y) / mh, 0.25, 1.0);
            float cov = cdLine(d, 2.0 * rad * taper, fp) * clamp((y - L.h) / fp + 0.5, 0.0, 1.0) * clamp((L.h + mh - y) / fp + 0.5, 0.0, 1.0);
            if (cov > h.mc) { h.mc = cov; h.mt = tm; h.ml = exp(-(d * d + (y - L.h - mh) * (y - L.h - mh)) / max(fp * fp * 1.5, 0.09)) * min(1.0, 0.3 / fp); }
        }
    }
}

inline void cdSide(float3 ro, float3 rd, float s, thread CdHit& h, int nL, float pa, bool clutter) {
    if (s * rd.x <= 1e-5) return;
    float rdz = rd.z < 0.0 ? min(rd.z, -1e-6) : max(rd.z, 1e-6);
    float t0 = max((s * CW - ro.x) / rd.x, 0.0);
    if (t0 > h.t || t0 > 1300.0) return;      // beyond ~1.3 km the lots are sub-pixel: leave it to haze + skyline
    float z = ro.z + rdz * t0;
    int i = int(floor(z / LOT));
    int dir = rdz < 0.0 ? -1 : 1;
    for (int k = 0; k < nL; k++) {
        CdLot L = cdLot(s, i);
        float za = float(i) * LOT;
        float tEnter = ((dir < 0 ? za + LOT : za) - ro.z) / rdz;
        float tExit  = ((dir < 0 ? za : za + LOT) - ro.z) / rdz;
        if (tEnter > h.t) return;
        float tA = max(tEnter, 0.0);
        float tf = (s * (CW + L.off) - ro.x) / rd.x;
        float tu = (s * (CW + L.off + L.sb) - ro.x) / rd.x;
        float t1 = max(tA, tf);
        float tB = (s * (CW + L.off + L.dep) - ro.x) / rd.x;   // back of the building
        float bt = 1e9; int bk = 0; float3 bn = float3(0, 1, 0);
        if (t1 < min(tExit, tB)) {
            float y1 = ro.y + rd.y * t1;
            float t2 = max(tA, tu);
            if (y1 < L.h1 && y1 > 0.0) {
                bt = t1; bk = 2; bn = t1 == tf ? float3(-s, 0, 0) : float3(0, 0, -float(dir));
            } else if (rd.y < 0.0 && L.sb > 0.0 && (L.h1 - ro.y) / rd.y >= t1 && (L.h1 - ro.y) / rd.y < min(t2, tExit)) {
                bt = (L.h1 - ro.y) / rd.y; bk = 3; bn = float3(0, 1, 0);
            } else if (t2 < min(tExit, tB)) {
                float y2 = ro.y + rd.y * t2;
                if (y2 < L.h && y2 > 0.0) {
                    bt = t2; bk = 2; bn = t2 == tu ? float3(-s, 0, 0) : float3(0, 0, -float(dir));
                } else if (rd.y < 0.0) {   // main roof (visible on blocks lower than the camera)
                    float tr = (L.h - ro.y) / rd.y;
                    if (tr >= t2 && tr < min(tExit, tB)) { bt = tr; bk = 3; bn = float3(0, 1, 0); }
                }
            }
        }
        float tEnd = min(tExit, max(tB, tA));
        if (clutter && max(ro.y + rd.y * tA, ro.y + rd.y * tEnd) > L.h - 0.5) {
            float tc = 1e9; float3 nc = float3(0, 1, 0); int kc = 0;
            cdClutter(ro, rd, L, s, za, pa, min(h.t, bt), tc, nc, kc, h);
            if (tc < bt) { bt = tc; bk = kc; bn = nc; }
        }
        if (bk != 0 && bt < h.t) { h.t = bt; h.kind = bk; h.s = s; h.lot = i; h.n = bn; return; }
        i += dir;
    }
}

// neon sign emission (blur: extra softness in metres, bx horizontal, by vertical)
inline float4 cdSignEmit(CdSign g, float u, float v, float fp, float bx, float by, float time) {
    float w = g.x1 - g.x0, hgt = g.y1 - g.y0;
    // soft coverage of the panel
    float2 q = abs(float2(u - 0.5 * w, v - 0.5 * hgt)) - float2(0.5 * w, 0.5 * hgt);
    float sx = max(bx, fp) , sy = max(by, fp);
    float cov = clamp(0.5 - q.x / sx, 0.0, 1.0) * clamp(0.5 - q.y / sy, 0.0, 1.0);
    if (cov <= 0.0) return float4(0.0);
    float blurry = smoothstep(0.15, 0.8, max(bx, by));
    // glyph column: abstract stroke characters (neon tubes on a 3x4 node lattice)
    float cell = w * 0.64;
    float gu = (u - 0.18 * w) / cell;
    float pitch = cell * 1.25;
    float gv = (v - 0.45) / pitch;
    float rowId = floor(gv);
    float nrow = floor((hgt - 0.9) / pitch);
    float2 f = float2(gu, fract(gv) * 1.25);
    float stroke = 0.0;
    float fpc = fp / cell;
    if (gu > -0.2 && gu < 1.2 && rowId >= 0.0 && rowId < nrow && f.y < 1.1) {
        float4 gh = hash24(float2(rowId + g.seed * 91.0, g.seed * 37.0 + floor(time * 0.2 * step(0.8, g.seed))));
        uint bits = uint(gh.x * 131071.0) | 0x4001u;
        float2 fc = clamp(f, 0.0, 1.0);
        // horizontal strokes
        float r = clamp(floor(fc.y * 3.0 + 0.5), 0.0, 3.0);
        float ix = clamp(floor(fc.x * 2.0), 0.0, 1.0);
        float dh = (float((bits >> uint(r * 2.0 + ix)) & 1u) > 0.5) ? length(float2(max(abs(f.x - (ix + 0.5) * 0.5) - 0.25, 0.0), f.y - r / 3.0)) : 9.0;
        // vertical strokes
        float c = clamp(floor(fc.x * 2.0 + 0.5), 0.0, 2.0);
        float iy = clamp(floor(fc.y * 3.0), 0.0, 2.0);
        float dv = (float((bits >> uint(8.0 + c * 3.0 + iy)) & 1u) > 0.5) ? length(float2(f.x - c * 0.5, max(abs(f.y - (iy + 0.5) / 3.0) - 1.0 / 6.0, 0.0))) : 9.0;
        float d = min(dh, dv) * cell;
        stroke = cdLine(d, 0.17, fp) + 0.35 * exp(-d / 0.28);
    }
    float sAvg = 0.22 * step(-0.1, gu) * step(gu, 1.1) * step(0.0, v - 0.45) * step(v, 0.45 + nrow * pitch);
    stroke = mix(stroke, sAvg, max(smoothstep(0.08, 0.35, fpc), blurry));
    // neon border tube
    float dEdge = -max(q.x, q.y);
    float tube = cdLine(abs(dEdge - 0.2), 0.13, fp) + 0.25 * exp(-abs(dEdge - 0.2) / 0.3);
    tube = mix(tube, 0.14, max(smoothstep(0.1, 0.5, fp), blurry));
    float3 e;
    if (g.type < 0.5) {
        e = g.col * (stroke * 1.1 + tube * 1.1) + g.col * 0.02;
    } else {
        float3 pan = mix(g.col, float3(1.0), 0.08);
        e = pan * (0.085 - 0.065 * min(stroke, 1.0)) * (0.9 + 0.1 * sin(v * 0.6 + time * 0.8)) + g.col * tube * 0.6;
    }
    return float4(e * g.I * cov, min(stroke + tube, 1.0) * cov);
}

// signs of one side: nearest opaque sign hit (updates h) + halo accumulation
inline void cdSigns(float3 ro, float3 rd, float s, thread CdHit& h, float time, float neonOn,
                    float pa, float blur, thread float3& halo, thread float3& emit, int nL) {
    if (s * rd.x <= 1e-5) return;
    float rdz = min(rd.z, -1e-6);
    float tb = max((s * (CW - 6.0) - ro.x) / rd.x, 0.0);
    if (tb > h.t) return;
    int i = int(floor((ro.z + rdz * tb) / LOT));
    float zEnd = ro.z + rdz * h.t;
    for (int k = 0; k < nL; k++) {
        if (float(i + 1) * LOT < zEnd) break;
        CdLot L = cdLot(s, i);
        // cheap geometry first (same formulas as cdSignOf); colour/intensity only when it matters
        bool ok = L.b.x < 0.72 && !(s > 0.0 && i >= -2);
        float zc = float(i) * LOT + LOT * (0.2 + 0.6 * L.b.y);
        float tz = (zc - ro.z) / rdz;
        if (ok && tz > 0.0 && tz < h.t) {
            float x1 = CW + L.off - 0.25, x0 = x1 - (2.4 + 3.2 * L.b.z);
            float y0 = 8.0 + 40.0 * L.b.w;
            float y1 = min(y0 + 7.0 + 16.0 * fract(L.a.w * 7.31), L.h - 2.0);
            float3 p = ro + rd * tz;
            float u = s * p.x - x0, v = p.y - y0;
            float w = x1 - x0, hg = y1 - y0;
            float2 q = abs(float2(u - 0.5 * w, v - 0.5 * hg)) - float2(0.5 * w, 0.5 * hg);
            float dd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
            float fp = tz * pa / max(abs(rd.z), 0.2);
            float bx = blur * tz * 0.35, by = blur * tz * 2.2;
            float hr = 1.1 + 2.5 * blur * tz * 0.05;
            float dp = max(dd, 0.0);
            bool needHalo = neonOn > 0.001 && dp < hr * 22.0;
            float sxb = max(bx, fp) + 0.3, syb = max(by, fp) + 0.3;
            bool needEmit = blur > 0.0 && neonOn > 0.001 && q.x < 0.5 * sxb && q.y < 0.5 * syb;
            if (needHalo || needEmit) {
                CdSign g = cdSignOf(L, s, i, time, neonOn);
                if (needHalo) halo += g.col * g.I * (w * hg) * (0.0026 * exp(-dp / hr) + 0.0007 * exp(-dp / (hr * 4.0))) / (1.0 + 0.004 * tz);
                if (needEmit) {
                    float covb = clamp(0.5 - q.x / sxb, 0.0, 1.0) * clamp(0.5 - q.y / syb, 0.0, 1.0);
                    emit += g.col * g.I * covb * (g.type < 0.5 ? 0.3 : 0.12);
                }
            }
            if (dd < (blur > 0.0 ? -0.2 : 0.0)) { h.t = tz; h.kind = 4; h.s = s; h.lot = i; h.n = float3(0, 0, 1); return; }
        }
        i -= 1;
    }
}

// the scene's fixed structures (rail along the canyon, crossing bridge, train)
inline void cdStructs(float3 ro, float3 rd, float time, thread CdHit& h) {
    float3 n;
    float t = cdBox(ro, rd, float3(-15.4, 15.2, -4000.0), float3(-11.6, 16.8, -8.0), n);
    if (t < h.t) { h.t = t; h.kind = 5; h.n = n; }
    // train on the canyon rail, running away from the camera
    float zt = -fmod(time * 16.0, 2400.0) + 60.0;
    t = cdBox(ro, rd, float3(-15.0, 16.8, zt - 110.0), float3(-12.0, 20.0, zt), n);
    if (t < h.t) { h.t = t; h.kind = 6; h.n = n; }
    // enclosed skybridges between the towers
    t = cdBox(ro, rd, float3(-CW - 1.0, 40.0, -128.0), float3(CW + 2.0, 45.0, -122.0), n);
    if (t < h.t) { h.t = t; h.kind = 9; h.n = n; }
    t = cdBox(ro, rd, float3(-CW - 1.0, 27.0, -352.0), float3(CW + 2.0, 31.0, -347.0), n);
    if (t < h.t) { h.t = t; h.kind = 9; h.n = n; }
    // crossing viaduct
    t = cdBox(ro, rd, float3(-400.0, 52.0, -262.0), float3(400.0, 54.5, -256.0), n);
    if (t < h.t) { h.t = t; h.kind = 7; h.n = n; }
    // train crossing the viaduct
    float xt = fmod(time * 22.0, 1400.0) - 700.0;
    t = cdBox(ro, rd, float3(xt - 90.0, 54.5, -261.0), float3(xt, 57.6, -257.0), n);
    if (t < h.t) { h.t = t; h.kind = 6; h.n = n; }
}

inline CdHit cdTrace(float3 ro, float3 rd, float time, bool withLedge, int nL, float pa, bool clutter) {
    CdHit h; h.t = 1e9; h.kind = 0; h.n = float3(0, 1, 0); h.s = 0.0; h.lot = 0; h.mc = 0.0; h.mt = 1e9; h.ml = 0.0;
    if (withLedge && rd.y < 0.0) {
        float t = (CAMY - 1.05 - ro.y) / rd.y;
        float3 p = ro + rd * t;
        if (p.z > -2.1) { h.t = t; h.kind = 8; h.n = float3(0, 1, 0); return h; }
    }
    if (rd.y < 0.0) { h.t = -ro.y / rd.y; h.kind = 1; h.n = float3(0, 1, 0); }
    cdSide(ro, rd, 1.0, h, nL, pa, clutter);
    cdSide(ro, rd, -1.0, h, nL, pa, clutter);
    cdStructs(ro, rd, time, h);
    return h;
}

// ------------------------------------------------------------------ lighting helpers
inline float cdSunVis(float3 p, float3 sun) {
    if (sun.y <= -0.01) return 0.0;
    float sx = sun.x;
    if (abs(sx) < 1e-4) return 1.0;
    float s = sx > 0.0 ? 1.0 : -1.0;
    float t = max((s * CW - p.x) / sx, 0.0);
    float z = p.z + sun.z * t;
    int i = int(floor(z / LOT));
    CdLot L = cdLot(s, i);
    float t2 = max((s * (CW + L.off) - p.x) / sx, 0.0);
    float y = p.y + sun.y * t2;
    float pen = 0.4 + 0.01 * t2;
    return smoothstep(-pen, pen, y - L.h);
}

inline float3 cdSunColor(float elev) {
    float e = max(elev, -2.0);
    float am = 1.0 / (sin(max(e, 0.0) * PI / 180.0) + 0.50572 * pow(max(e + 6.07995, 0.1), -1.6364));
    float3 tau = float3(0.052, 0.105, 0.22) + 0.07; // rayleigh + urban haze
    return 20.0 * exp(-tau * am) * smoothstep(-2.0, 1.0, elev);
}

// average neon irradiance field (nearby signs of both sides + shopfront spill)
inline float3 cdNeonLight(float3 p, float3 n, float time, float neonOn) {
    float3 E = float3(0.0);
    float zl = p.z / LOT;
    int i0 = int(floor(zl));
    int i1 = fract(zl) < 0.5 ? i0 - 1 : i0 + 1;
    for (int side = 0; side < 2; side++) {
        float s = side == 0 ? -1.0 : 1.0;
        for (int k = 0; k < 2; k++) {
            int i = k == 0 ? i0 : i1;
            CdLot L = cdLot(s, i);
            if (L.b.x < 0.72 && !(s > 0.0 && i >= -2)) {
                // light-weight copy of cdSignOf (no flicker) for the irradiance field
                float4 b = L.b;
                float x1 = CW + L.off - 0.25, x0 = x1 - (2.4 + 3.2 * b.z);
                float y0 = 8.0 + 40.0 * b.w;
                float y1 = min(y0 + 7.0 + 16.0 * fract(L.a.w * 7.31), L.h - 2.0);
                float seed = fract(b.z * 17.3 + b.w * 5.7);
                float gI = smoothstep(seed * 0.8, seed * 0.8 + 0.2, neonOn * 1.05) * (3.0 + 3.0 * fract(seed * 9.1));
                float3 gcol = cdNeon(fract(b.x * 13.71 + b.y * 3.1));
                float3 c = float3(s * 0.5 * (x0 + x1), 0.5 * (y0 + y1), float(i) * LOT + LOT * (0.2 + 0.6 * b.y));
                float3 d = c - p;
                float r2 = dot(d, d);
                float3 l = d * rsqrt(r2);
                float area = (x1 - x0) * (y1 - y0);
                E += gcol * gI * area * (max(dot(n, l), 0.0) * 0.8 + 0.2) * (0.35 / (r2 + 20.0) + 0.9 / (r2 * r2 * 0.02 + 40.0));
            }
            // shopfront spill + street lamp, merged into one kerbside source per lot
            float3 sc = mix(float3(1.0, 0.62, 0.32), cdNeon(fract(L.a.z * 7.7 + L.b.y * 3.3)), 0.45);
            float3 c2 = float3(s * (CW - 3.5), 6.0, float(i) * LOT + 0.5 * LOT) - p;
            float r22 = dot(c2, c2);
            E += (sc * 0.6 + float3(1.0, 0.8, 0.55) * 0.6) * neonOn * 22.0 * (max(dot(n, c2 * rsqrt(r22)), 0.0) * 0.8 + 0.2) / (r22 + 30.0);
        }
    }
    return E;
}

// ------------------------------------------------------------------ sky
// compact single-scattering sky (same physics as ws_atmosphereFast, fewer steps)
inline float3 cdAtmo(float3 rd, float3 sunDir, int iSteps, int jSteps) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kRlh = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kMie = 21e-6 * 1.6;
    const float shRlh = 8e3, shMie = 1.2e3, g = 0.76;
    float3 r0 = float3(0.0, Rp + 120.0, 0.0);
    float3 r = normalize(rd);
    float2 p = ws_raySphere(r0, r, Ra);
    p.x = max(p.x, 0.0);
    float2 pg = ws_raySphere(r0, r, Rp);
    if (pg.x <= pg.y && pg.x > 0.0) p.y = min(p.y, pg.x);
    float iStep = (p.y - p.x) / float(iSteps);
    float3 totR = 0.0, totM = 0.0;
    float odR = 0.0, odM = 0.0;
    float mu = dot(r, sunDir), mumu = mu * mu, gg = g * g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));
    for (int i = 0; i < iSteps; i++) {
        float3 ip = r0 + r * (p.x + iStep * (float(i) + 0.5));
        float h = length(ip) - Rp;
        float dR = exp(-h / shRlh) * iStep, dM = exp(-h / shMie) * iStep;
        odR += dR; odM += dM;
        float2 sg = ws_raySphere(ip, sunDir, Rp);
        if (sg.x <= sg.y && sg.x > 0.0) continue;
        float jStep = ws_raySphere(ip, sunDir, Ra).y / float(jSteps);
        float jR = 0.0, jM = 0.0;
        for (int j = 0; j < jSteps; j++) {
            float jh = length(ip + sunDir * (jStep * (float(j) + 0.5))) - Rp;
            jR += exp(-jh / shRlh) * jStep; jM += exp(-jh / shMie) * jStep;
        }
        float3 at = exp(-(kMie * 1.1 * (odM + jM) + (kRlh + float3(0.55e-6, 1.6e-6, 0.07e-6)) * (odR + jR)));   // + ozone (Chappuis) for blue twilight
        totR += dR * at; totM += dM * at;
    }
    return 22.0 * (pR * kRlh * totR + pM * kMie * totM);
}

constant float3 CD_ZEN[39] = { float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(2.264e-05, 3.421e-05, 3.906e-05), float3(2.852e-05, 6.011e-05, 9.32e-05), float3(2.986e-05, 6.755e-05, 0.0001118), float3(3.227e-05, 6.939e-05, 0.0001166), float3(0.003988, 0.001413, 0.0005058), float3(0.009031, 0.009752, 0.008202), float3(0.01212, 0.01983, 0.02437), float3(0.01365, 0.02649, 0.03806), float3(0.01442, 0.03021, 0.04658), float3(0.01482, 0.03226, 0.05154), float3(0.01505, 0.03345, 0.05447), float3(0.0152, 0.0342, 0.05631), float3(0.01531, 0.03471, 0.05754), float3(0.01541, 0.0351, 0.05845), float3(0.0155, 0.03541, 0.05916), float3(0.01558, 0.0357, 0.05977), float3(0.01567, 0.03597, 0.06031), float3(0.01577, 0.03623, 0.06083), float3(0.01587, 0.0365, 0.06134), float3(0.01726, 0.03988, 0.0673), float3(0.01933, 0.04473, 0.07558), float3(0.02186, 0.05062, 0.08558), float3(0.02456, 0.05687, 0.09618), float3(0.02709, 0.06274, 0.1061), float3(0.02915, 0.06753, 0.1142), float3(0.03049, 0.07065, 0.1195), float3(0.03096, 0.07173, 0.1214) };
constant float3 CD_HOR[39] = { float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0, 0, 0), float3(0.004416, 0.0006003, 0.0001184), float3(0.08547, 0.01214, 0.003716), float3(0.2804, 0.09193, 0.03011), float3(0.4352, 0.2498, 0.1202), float3(0.5364, 0.4103, 0.252), float3(0.5973, 0.5323, 0.3747), float3(0.6331, 0.6155, 0.4686), float3(0.6541, 0.67, 0.535), float3(0.6659, 0.7053, 0.5806), float3(0.672, 0.7277, 0.6115), float3(0.6741, 0.7415, 0.632), float3(0.6734, 0.7491, 0.6451), float3(0.6705, 0.7522, 0.6528), float3(0.5721, 0.662, 0.5911), float3(0.4384, 0.5112, 0.4597), float3(0.3736, 0.437, 0.3942), float3(0.367, 0.43, 0.3885), float3(0.3675, 0.431, 0.3898), float3(0.3678, 0.4317, 0.3906), float3(0.368, 0.4321, 0.3911), float3(0.3681, 0.4322, 0.3913) };

// ambient zenith / horizon radiance vs. sun elevation, tabulated offline from cdAtmo(2,2) / cdAtmo(3,2)
// along a typical sun path (identical physics, but uniform per frame -> no per-pixel atmosphere cost)
inline float3 cdTab(constant float3* T, float e) {
    float x = e < 10.0 ? clamp(e, -20.0, 10.0) + 20.0 : 30.0 + clamp((e - 10.0) / 10.0, 0.0, 8.0);
    int i = min(int(x), 37);
    return mix(T[i], T[i + 1], x - float(i));
}

struct CdEnv { float twi; float3 sun; float3 moon; float3 sunCol; float3 zen; float3 hor; float3 glow; float night; float day; float neonOn; float time; float moonIllum; };

inline float cdCloud(float2 xz, float time, float lod) {
    float2 q = xz * 0.00045 + float2(time * 0.0016, time * 0.0007);
    float s = 0.0, a = 0.5, nrm = 0.0;
    for (int o = 0; o < 4; o++) {
        float fade = clamp(1.6 - lod * exp2(float(o)) * 1.2, 0.0, 1.0);
        s += a * gnoise(q) * fade; nrm += a;
        q = WS_ROT2 * q * 2.03 + float2(3.1, 1.7);
        a *= 0.5;
    }
    return s / nrm;
}

inline float3 cdSky(float3 rd, thread CdEnv& E, float pa, bool detail) {
    float3 d = normalize(float3(rd.x, max(rd.y, 0.0) + 0.035, rd.z));
    float3 col = detail ? cdAtmo(d, E.sun, E.night > 0.999 ? 3 : 6, E.night > 0.999 ? 2 : 3) : mix(E.hor, E.zen, smoothstep(0.0, 0.5, d.y));
    // city light pollution dome
    float hz = exp(-max(rd.y, 0.0) * 7.0);
    // multiple-scattering twilight (blue hour) that single scattering misses
    float muT = max(dot(normalize(float3(rd.x, 0.0, rd.z)), normalize(float3(E.sun.x, 0.0, E.sun.z) + 1e-5)), 0.0);
    col += E.twi * (mix(float3(0.010, 0.020, 0.050), float3(0.020, 0.026, 0.045), hz) + float3(0.07, 0.03, 0.012) * pow(muT, 3.0) * exp(-max(rd.y, 0.0) * 10.0));
    col += E.glow * (1.5 + 7.0 * hz * hz);
    if (detail) {
        // moon + a few stars through the smog
        float3 moonC = ws_sunDisk(rd, E.moon, 0.9, float3(1.2, 1.18, 1.1) * (0.3 + 1.2 * E.moonIllum));
        col += moonC * E.night * smoothstep(0.0, 0.05, E.moon.y);
        col += E.night * ws_stars(d.xz / (d.y + 0.35), 70.0, E.time * 0.02, 0.25) * 0.004 * smoothstep(0.1, 0.5, d.y);
        col += ws_sunDisk(rd, E.sun, 0.35, E.sunCol * 60.0);
    }
    // cloud / smog deck
    if (rd.y > 0.004) {
        float t = (1700.0 - CAMY) / rd.y;
        float2 xz = rd.xz * t;
        float lod = t * pa / max(rd.y, 0.05) * 0.00045 * 3.0;
        float n = cdCloud(xz, E.time, lod);
        float dens = smoothstep(0.0, 0.5, n - 0.02) * smoothstep(0.004, 0.09, rd.y);
        float mu = dot(rd, E.sun);
        float3 lit = E.sunCol * (0.018 + 0.05 * pow(max(mu, 0.0), 8.0)) * (1.0 - 0.5 * smoothstep(0.1, 0.6, n)) + E.zen * 0.75 + E.hor * 0.25;
        float3 under = E.glow * (5.0 + 12.0 * hz) * (0.6 + 0.6 * smoothstep(-0.1, 0.5, n));
        float3 cc = lit + under + col * 0.35;
        col = mix(col, cc, dens * 0.92);
    }
    return col;
}

// ------------------------------------------------------------------ far skyline (angular layers)
inline float4 cdSkyline(float3 rd, float pa, thread CdEnv& E, thread float& dist, thread float& yOut) {
    float az = atan2(rd.x, -rd.z);
    float el = rd.y / length(rd.xz);
    float4 res = float4(0.0);
    for (int k = 0; k < 3; k++) {
        float D = k == 0 ? 520.0 : (k == 1 ? 1000.0 : 1900.0);
        float bw = k == 0 ? 34.0 : (k == 1 ? 46.0 : 60.0);
        float xs = az * D;
        float cid = floor(xs / bw);
        float4 h = hash24(float2(cid + 17.0 * float(k), float(k) * 3.7 + 1.0));
        float fx = fract(xs / bw);
        float inset = 0.08 + 0.25 * h.z;
        float lat = abs((cid + 0.5) * bw);
        if (lat < CW + 14.0) continue;   // keep the canyon axis open
        float H = 90.0 + 320.0 * pow(h.y, 1.6) + (k == 2 ? 120.0 : 0.0);
        H *= az > 0.12 ? 0.5 : 1.0;                            // lower skyline on the right (calm top-right)
        bool land = k == 1 && abs(cid + 2.0) < 0.5;
        if (land) H = 760.0;                                   // landmark supertall
        bool rnd = !land && fract(h.x * 5.3) > 0.62;           // some towers are rounded / elliptical
        float fpA = pa * D;                                    // metres per pixel
        float yEl = el * D + CAMY;
        float y = yEl;
        // massing: base shaft, optional mid setback, crown tier
        float wx = min(fx - inset, 1.0 - inset - fx) * bw;      // metres inside the column edge
        float covX = clamp(wx / fpA + 0.5, 0.0, 1.0);
        float crownH = H * (0.08 + 0.1 * h.w);
        float inset2 = inset + 0.12 + 0.1 * h.x;
        float wx2 = min(fx - inset2, 1.0 - inset2 - fx) * bw;
        float covTop = clamp(wx2 / fpA + 0.5, 0.0, 1.0);
        float upper = clamp((y - (H - crownH)) / fpA + 0.5, 0.0, 1.0);
        covX = mix(covX, covTop, upper * step(0.35, h.z));
        if (fract(h.w * 3.1) > 0.5 && !land) {                 // mid-height setback
            float insM = inset + 0.05 + 0.04 * h.y;
            float wxm = min(fx - insM, 1.0 - insM - fx) * bw;
            float midU = clamp((y - H * (0.55 + 0.15 * h.x)) / fpA + 0.5, 0.0, 1.0);
            covX = min(covX, mix(1.0, clamp(wxm / fpA + 0.5, 0.0, 1.0), midU));
        }
        float covY = clamp((H - y) / fpA + 0.5, 0.0, 1.0);
        float cov = covX * covY;
        float mastW = 0.0;
        // rooftop plant box + mast on top (silhouette clutter)
        {
            float pc = inset2 + (1.0 - 2.0 * inset2) * (0.25 + 0.5 * h.w);
            float pwid = (1.0 - 2.0 * inset2) * bw * (0.18 + 0.2 * h.y);
            float pbx = clamp((0.5 * pwid - abs(fx - pc) * bw) / fpA + 0.5, 0.0, 1.0);
            float pby = clamp((H + 4.0 + 5.0 * h.x - y) / fpA + 0.5, 0.0, 1.0) * clamp((y - H + 1.0) / fpA + 0.5, 0.0, 1.0);
            cov = max(cov, pbx * pby * step(0.25, h.x));
        }
        if (h.z > 0.72) {
            float mx = 0.5 + (h.w - 0.5) * 0.3;
            float mast = clamp((0.35 + 0.0003 * D - abs(fx - mx) * bw) / fpA + 0.5, 0.0, 1.0) * min(1.0, 1.2 / fpA);
            float mtop = H + 40.0 + 60.0 * h.x;
            float mastY = clamp((mtop - y) / fpA + 0.5, 0.0, 1.0) * clamp((y - H + 2.0) / fpA + 0.5, 0.0, 1.0);
            mastW = mast * mastY * (1.0 - cov);
            cov = max(cov, mast * mastY);
        }
        // spire on the landmark
        if (land) {
            float sw = 2.0 + 6.0 * clamp((H + 160.0 - y) / 160.0, 0.0, 1.0);
            float sp = clamp((sw - abs(fx - 0.5) * bw) / fpA + 0.5, 0.0, 1.0) * clamp((H + 160.0 - y) / fpA + 0.5, 0.0, 1.0);
            cov = max(cov, sp);
        }
        if (cov > 0.002) {
            float u = fx * bw;
            // windows (grid averaged when small)
            float cwid = 1.7, fh = 3.6;
            float wu = cdPulse(u / cwid, 0.2, 0.8, fpA / cwid);
            float wv = cdPulse(y / fh, 0.25, 0.8, fpA / fh);
            float2 cc = floor(float2(u / cwid, y / fh));
            float lit = step(hash12(cc + cid * 13.0 + float(k) * 71.0), (0.04 + 0.16 * E.neonOn) * (0.5 + h.x));
            float lodB = smoothstep(0.35, 1.0, fpA / cwid);
            float wv2 = hash12(cc * 1.3 + 7.0);
            float wl = mix(lit * (0.2 + 0.8 * wv2 * wv2), (0.04 + 0.16 * E.neonOn) * (0.5 + h.x) * 0.5, lodB) * wu * wv;
            float3 wc = mix(float3(1.0, 0.68, 0.42), float3(0.7, 0.82, 1.0), h.w);
            // shading normal: rounded towers turn smoothly, box towers show two faces with a bevel
            float3 toCam = float3(-sin(az), 0.0, cos(az)), rgt = float3(cos(az), 0.0, sin(az));
            float3 fN;
            float split = 0.35 + 0.3 * h.z;
            if (rnd) {
                float th = clamp((fx - 0.5) / (0.5 - inset), -1.0, 1.0) * 1.35;
                fN = toCam * cos(th) + rgt * sin(th);
            } else {
                float3 fa = az > 0.0 ? float3(-1, 0, 0) : float3(0, 0, 1);
                float3 fb = az > 0.0 ? float3(0, 0, 1) : float3(1, 0, 0);
                float bev = smoothstep(-1.0, 1.0, (fx - split) * bw / max(1.2, fpA));
                fN = normalize(mix(fa, fb, bev));
            }
            float face = max(dot(fN, E.sun), 0.0);
            float glassT = step(0.5, h.w);
            float3 albB = glassT > 0.5 ? float3(0.05, 0.062, 0.075) : mix(float3(0.13, 0.125, 0.12), float3(0.22, 0.2, 0.18), h.x);
            float floorL = mix(cdLine(abs(fract(y / fh) - 0.1) * fh, 0.5, fpA), 0.13, smoothstep(0.3, 1.0, fpA / fh));
            albB *= 1.0 + (glassT > 0.5 ? 0.8 : -0.35) * floorL;
            // weathering: vertical rain streaks and big stains
            float wN = vnoise(float2(u * 0.9 + cid * 7.0, y * 0.012));
            float stain = vnoise(float2(u * 0.08 + cid * 3.0, y * 0.01 + float(k)));
            albB *= (0.8 + 0.3 * wN) * (0.8 + 0.35 * stain);
            // punched windows darken masonry towers by day
            float winS = glassT > 0.5 ? 0.0 : wu * wv;
            float3 lightB = E.zen * 0.7 + E.hor * 0.15 + E.sunCol * face / PI + E.glow * 1.5;
            // glass: sky reflection with panel-to-panel tint variation, mullions, sun glint
            float mull = mix(cdPulse(u / 1.5, 0.0, 0.1, fpA / 1.5), 0.1, smoothstep(0.3, 1.0, fpA / 1.5));
            float pan = mix(hash12(floor(float2(u / 1.5, y / 3.6)) + cid), 0.5, smoothstep(0.3, 1.0, fpA / 1.5));
            float rimF = pow(1.0 - abs(dot(fN, toCam)) * 0.9, 3.0);
            float3 rN = reflect(-toCam, fN);
            float3 refl = glassT * (mix(E.hor, E.zen, 0.35 + 0.3 * (fx - 0.5)) * (0.3 + 0.35 * rimF) * (0.75 + 0.5 * pan) * (1.0 - 0.6 * mull)
                        + E.sunCol * pow(max(dot(rN, E.sun), 0.0), 40.0) * 0.08 * (0.6 + 0.8 * pan));
            float3 body = albB * lightB * (1.0 - 0.7 * winS) + refl
                        + winS * (mix(E.hor, E.zen, 0.5) * 0.18 + E.sunCol * 0.004 * face);
            // crevice / edge occlusion at the silhouette sides
            float sideAO = rnd ? 1.0 : 1.0 - 0.12 * exp(-max(wx, 0.0) / 2.5);
            body *= sideAO;
            float3 em = wc * wl * 0.45 * E.neonOn;
            // rooftop crown + aviation light
            float crown = cdLine(abs(y - H + 3.0), 1.2, fpA) * step(0.6, h.x);
            em += cdNeon(h.z) * crown * 3.0 * E.neonOn;
            float blink = step(0.5, fract(E.time * 0.5 + h.x));
            float av = exp(-(pow((fx - 0.5) * bw, 2.0) + pow(y - H - 1.5, 2.0)) / max(fpA * fpA * 1.2, 1.0));
            em += float3(1.0, 0.05, 0.02) * av * blink * 6.0 * E.neonOn;
            float3 mastC = float3(0.035) * (E.zen * 0.8 + E.hor * 0.3 + E.glow * 1.5) + E.sunCol * 0.006 * max(E.sun.y, 0.0);
            body = mix(body, mastC, mastW / max(cov, 1e-3));
            res = float4(body + em, cov);
            dist = D;
            yOut = y;
            return res;
        }
    }
    return res;
}

// ------------------------------------------------------------------ facade shading
inline float3 cdFacade(float3 p, float3 n, float3 rd, CdLot L, float s, float t, float pa, thread CdEnv& E,
                       float sunV, bool simple, float3 neonE, int li) {
    bool front = abs(n.x) > 0.5;
    // ---- rounded / chamfered vertical edges (shading normal) + inner-corner occlusion
    float za = float(li) * LOT;
    float3 ns = n;
    float cornerAO = 1.0;
    float edgeHi = 0.0;
    {
        float fpE = t * pa;
        bool round = fract(L.a.w * 7.7) > 0.72 && L.h > 120.0;
        if (front) {
            float d0 = p.z - za, d1 = za + LOT - p.z;
            bool near0 = d0 < d1;
            float d = min(d0, d1);
            float R = round ? 5.0 : 0.35;
            if (d < max(R, 4.0)) {
            CdLot N = cdLot(s, li + (near0 ? -1 : 1));
            bool outer = N.off > L.off + 0.1 || N.h < p.y;       // neighbour recessed or lower: exposed corner
            if (outer) {
                float k = clamp(1.0 - d / R, 0.0, 1.0);
                float th = 0.785 * k;
                ns = normalize(n * cos(th) + float3(0, 0, near0 ? -1.0 : 1.0) * sin(th));
                edgeHi = cdLine(d, 0.12, fpE) * (round ? 0.0 : 1.0);
            } else if (N.off < L.off - 0.1) {
                cornerAO = 1.0 - 0.5 * exp(-d / 1.4) * smoothstep(4.0, 3.0, d);
            }
            }
        } else {
            float d = s * p.x - (CW + L.off);
            float R = round ? 5.0 : 0.35;
            float k = clamp(1.0 - d / R, 0.0, 1.0);
            float th = 0.785 * k;
            ns = normalize(n * cos(th) + float3(-s, 0, 0) * sin(th));
            edgeHi = cdLine(d, 0.12, fpE) * (round ? 0.0 : 1.0);
        }
    }
    float u = front ? p.z : p.x * s;
    float v = p.y;
    float cosi = max(abs(dot(rd, n)), 0.02);
    float fp = t * pa;
    float fpU = fp * max(1.0, (front ? abs(rd.z) : abs(rd.x)) / cosi);
    float fpV = fp * max(1.0, abs(rd.y) / cosi);
    if (simple) { fpU += 2.0; fpV += 2.0; }
    int sty = int(L.sty);
    bool podZ = v < L.h1 && L.sb > 0.0;
    if (podZ) sty = (sty + 1) % 3;
    float4 vr = fract(L.b * 7.31 + (podZ ? 0.5 : 0.0));
    float fh = 3.4 + 0.9 * vr.x;
    float cw = sty == 0 ? 1.4 + 0.6 * vr.y : (sty == 1 ? 1.7 + 1.1 * vr.y : 1.5);
    float ww = sty == 1 ? 0.3 + 0.25 * vr.z : 0.46;
    float wa = 0.5 - ww, wb = 0.5 + ww;
    float wh = sty == 0 ? 0.4 : (sty == 1 ? 0.22 + 0.12 * vr.w : 0.26 + 0.1 * vr.w);
    float va = 0.52 - wh, vb = 0.52 + wh;
    float winM = cdPulse(u / cw, wa, wb, fpU / cw) * cdPulse(v / fh, va, vb, fpV / fh);
    if (v < 6.0) winM = 0.0;
    float2 cid = floor(float2(u / cw, v / fh));
    float4 hc = hash24(cid + float2(s * 311.0 + L.a.x * 97.0, L.a.y * 131.0));
    float litP = mix(0.06, 0.42, E.neonOn) * (sty == 2 ? 0.45 : 1.0);
    float lit = step(hc.x, litP);
    float office = step(0.5, fract(L.a.w * 3.7));
    float tk = mix(0.15 + 0.35 * hc.y, 0.55 + 0.45 * hc.y, office);
    float3 wcol = mix(float3(1.0, 0.42, 0.13), float3(0.75, 0.88, 1.0), tk * tk) * (0.05 + 0.2 * hc.z * hc.z);
    if (sty == 2) wcol = mix(float3(0.35, 0.6, 1.0), float3(1.0, 0.55, 0.25), step(0.7, hc.y)) * (0.04 + 0.12 * hc.z);
    if (hc.w > 0.9) wcol = float3(0.25, 0.45, 1.0) * 0.08 * (0.6 + 0.4 * sin(E.time * 3.0 + hc.x * 40.0));   // TV glow
    if (hc.w > 0.97) wcol = cdNeon(hc.y) * 0.2;
    // slow life: some windows switch over minutes
    lit *= step(0.1, fract(hc.w * 7.0 + E.time * 0.004 * hc.z));
    // interior: ceiling-lit gradient + blinds pulled down part way
    float2 wf = float2(fract(u / cw), fract(v / fh));
    float lod = smoothstep(0.3, 1.1, max(fpU / cw, fpV / fh));
    float wy01 = clamp((wf.y - va) / (vb - va), 0.0, 1.0);
    float wx01 = clamp((wf.x - wa) / (wb - wa), 0.0, 1.0);
    float3 wl = float3(0.0);
    if (E.neonOn > 0.001) {
        float blind = hc.y > 0.45 ? smoothstep(0.0, 0.03, wy01 - (1.0 - (0.15 + 0.7 * fract(hc.x * 31.0)))) : 0.0;
        // curtains drawn in from the sides with soft folds
        float cur = fract(hc.z * 17.0);
        float curtain = cur > 0.55 ? smoothstep(0.02, 0.0, min(wx01, 1.0 - wx01) - (0.1 + 0.3 * fract(cur * 7.0))) : 0.0;
        float folds = 0.75 + 0.25 * sin(wx01 * 40.0 * (1.0 - lod));
        float grad = mix(0.45, 1.3, wy01);
        // furniture / people silhouettes against the lit interior
        float sil = step(0.6, fract(hc.w * 13.0)) * step(wy01, 0.3 + 0.3 * fract(hc.x * 5.0)) * step(abs(wx01 - fract(hc.y * 3.0)), 0.18);
        float mull = 1.0 - 0.8 * cdLine(abs(wf.x - 0.5) * cw, 0.08, fpU);
        float frameL = cdLine(min(min(wx01, 1.0 - wx01) * (wb - wa) * cw, min(wy01, 1.0 - wy01) * (vb - va) * fh), 0.07, max(fpU, fpV));
        float3 inner = lit * wcol * mix(grad, 0.3, blind * 0.85) * mix(1.0, folds * 0.55, curtain) * (1.0 - 0.75 * sil) * mull * (1.0 - 0.7 * frameL);
        inner = mix(inner, lit * wcol * 1.8 * float3(1.0, 0.85, 0.7), curtain * (1.0 - lod) * 0.25);
        float3 wAvg = float3(1.0, 0.7, 0.45) * 0.24 * 0.8 * litP;
        wl = mix(inner, wAvg, lod) * E.neonOn;
    }
    // architecture: pilasters every few bays, floor slabs with a lit top edge and a shadow line
    float bay = sty == 0 ? 6.0 : 4.0;
    float pil = cdPulse(u / (cw * bay), 0.0, sty == 0 ? 0.03 : 0.07, fpU / (cw * bay));
    winM *= 1.0 - pil;
    float slabTop = cdLine(abs(wf.y - 0.035) * fh, 0.1, fpV);
    float slabSh = cdLine(abs(wf.y - (va - 0.02)) * fh, 0.12, fpV) * 0.6;
    // wall albedo: large weathering stains, rain run-off streaks, dirt washed down from sills
    float xP = cdPulse(u / cw, wa, wb, fpU / cw);
    float lodS = smoothstep(0.25, 0.9, fpU * 1.5);
    float grime = vnoise(float2(u * 0.35, v * 0.035) + L.a.xy * 40.0);
    float stain = vnoise(float2(u * 0.06, v * 0.025) + L.a.zw * 30.0) * 2.0 - 1.0;
    float runN = vnoise(float2(u * 1.7, v * 0.06) + L.a.yx * 50.0);
    float run = mix(smoothstep(0.5, 0.95, runN), 0.18, lodS);
    float sillD = (va - wf.y) * fh;                                      // metres below the sill
    float below = mix(xP * (sillD > 0.0 ? exp(-sillD / 1.1) : 0.0) * (0.6 + 0.4 * hc.y), 0.12 * (wb - wa), lod);
    float topRun = exp(-max(L.h - v, 0.0) / 5.0);                         // run-off below the coping
    float baseDirt = 1.0 - 0.3 * exp(-max(v - 6.0, 0.0) / 10.0);
    float mh = fract(L.a.w * 5.77 + (podZ ? 0.37 : 0.0));
    float3 wall = mh < 0.3 ? float3(0.26, 0.25, 0.23) : (mh < 0.48 ? float3(0.33, 0.28, 0.21) : (mh < 0.62 ? float3(0.26, 0.14, 0.10)
                : (mh < 0.8 ? float3(0.12, 0.12, 0.13) : float3(0.42, 0.42, 0.41))));
    if (sty == 2) wall = float3(0.05, 0.053, 0.06);
    float3 gTint = mh < 0.4 ? float3(0.8, 0.95, 1.1) : (mh < 0.7 ? float3(0.85, 1.05, 0.95) : float3(1.1, 0.95, 0.8));
    float dirt = clamp(0.32 * run + 0.45 * below + 0.35 * topRun, 0.0, 0.8);
    wall *= (0.78 + 0.3 * grime) * (0.8 + 0.4 * (0.5 + 0.5 * stain)) * baseDirt;
    wall = mix(wall, wall * float3(0.55, 0.52, 0.48), dirt);
    wall *= 1.0 + 0.35 * slabTop - 0.45 * slabSh;
    wall = mix(wall, wall * 1.15, pil);
    // parapet coping band at the roof line
    float cop = clamp((v - (L.h - 0.9)) / fpV + 0.5, 0.0, 1.0);
    float copSh = cdLine(abs(v - (L.h - 1.05)), 0.18, fpV);
    wall = mix(wall * (1.0 - 0.5 * copSh), float3(0.24, 0.235, 0.22) * (0.8 + 0.3 * grime), cop);
    winM *= 1.0 - cop;
    // lighting (shading normal carries the edge rounding)
    float ndl = max(dot(ns, E.sun), 0.0);
    float skyV = clamp(0.2 + 0.7 * (v / max(L.h, 1.0)), 0.0, 1.0) * cornerAO;
    // sills cast a thin shadow line on the wall below them
    float snn = max(dot(n, E.sun), 1e-3);
    float sillSh = xP * clamp((0.1 * max(E.sun.y, 0.0) / snn - max(sillD, 0.0)) / fpV + 0.5, 0.0, 1.0) * step(0.0, sillD) * (1.0 - lod);
    float3 amb = (E.zen * 0.9 + E.hor * 0.25) * skyV + E.glow * 3.0 + E.sunCol * max(E.sun.y, 0.0) * 0.012 * (0.5 + skyV);
    // canyon inter-reflection: the sunlit opposite facades bounce warm light into the shaded side
    float oppLit = max(s * E.sun.x, 0.0) * smoothstep(-0.02, 0.1, E.sun.y);
    amb += E.sunCol * oppLit * 0.028 * (front ? 1.0 : 0.5) * (0.5 + 0.5 * smoothstep(0.0, 70.0, v));
    float3 lin = E.sunCol * ndl * sunV * (1.0 - 0.85 * sillSh) / PI + amb + neonE;
    float3 col = wall * lin;
    col += E.sunCol * sunV * ndl * edgeHi * 0.01 + (E.zen * 0.5) * edgeHi * 0.05;
    // glass: per-pane tilt breaks up the reflection; grazing views mirror the canyon's far end
    float cosi2 = max(abs(dot(rd, ns)), 0.02);
    float F = 0.04 + 0.96 * pow(1.0 - cosi2, 5.0);
    float3 r = reflect(rd, ns);
    float tilt = (hc.z - 0.5) * (1.0 - lod) * 0.18;
    r = normalize(r + float3(0.0, tilt, tilt * 0.5));
    float3 farC = E.hor * 0.9 + E.glow * 2.5 + E.sunCol * 0.02 * pow(max(dot(r, E.sun), 0.0), 6.0);
    float3 env = mix(farC, E.zen * 1.1, smoothstep(0.0, 0.5, r.y)) * (0.4 + 0.6 * skyV);
    env += neonE * 0.5;
    // glass mirrors the facades across the street (analytic plane at the opposite building line)
    if (front && !simple && E.day > 0.01) {
        float3 ro2 = reflect(rd, ns);
        float tO = (2.0 * CW + L.off) / max(abs(ro2.x), 1e-3);
        float3 po = p + ro2 * tO;
        if (ro2.x * s < 0.0 && po.y > 0.0) {
            CdLot O = cdLot(-s, int(floor(po.z / LOT)));
            float inO = clamp((O.h - po.y) / (tO * pa * 2.0 + 1.5) + 0.5, 0.0, 1.0);
            // shadow line cast by this side's roofs onto the opposite facade
            float shY = L.h - (2.0 * CW + L.off) * E.sun.y / max(abs(E.sun.x), 0.05);
            float oLit = max(dot(float3(s, 0, 0), E.sun), 0.0) * smoothstep(shY - 2.0, shY + 2.0, po.y);
            float oMh = fract(O.a.w * 5.77);
            float3 oAlb = O.sty == 2.0 ? float3(0.05) : (oMh < 0.3 ? float3(0.26, 0.25, 0.23) : (oMh < 0.48 ? float3(0.33, 0.28, 0.21) : (oMh < 0.62 ? float3(0.26, 0.14, 0.10) : float3(0.2))));
            float oWin = mix(0.55, 0.9, cdPulse(po.y / 3.8, 0.2, 0.75, tO * pa * 3.0 / 3.8));
            float3 oCol = oAlb * oWin * (E.sunCol * oLit / PI + E.zen * 0.6 + E.hor * 0.2 + E.glow * 3.0) + neonE * 0.3
                        + float3(1.0, 0.7, 0.45) * 0.03 * E.neonOn * (1.0 - oWin);
            env = mix(env, oCol, inO * 0.65 * (1.0 - lod * 0.3));
        }
    }
    // window reveal: the head and one jamb shade the recessed glass; sky is occluded near the frame
    float dRev = sty == 1 ? 0.3 : (sty == 0 ? 0.08 : 0.15);
    float3 tU = front ? float3(0, 0, 1) : float3(s, 0, 0);
    float suu = dot(E.sun, tU);
    float headSh = clamp((dRev * max(E.sun.y, 0.0) / snn - (vb - wf.y) * fh) / fpV + 0.5, 0.0, 1.0);
    float jambSh = clamp((dRev * abs(suu) / snn - (suu > 0.0 ? (wb - wf.x) : (wf.x - wa)) * cw) / fpU + 0.5, 0.0, 1.0);
    float revSh = mix(max(headSh, jambSh) * step(1e-3, dot(n, E.sun)), 0.25 * dRev * 3.0 * step(1e-3, dot(n, E.sun)), lod);
    float revAO = mix(smoothstep(0.0, dRev * 2.5 + 0.02, min(min(wx01, 1.0 - wx01) * (wb - wa) * cw, min(wy01, 1.0 - wy01) * (vb - va) * fh)), 0.8, lod);
    env *= mix(0.55, 1.0, revAO);
    env += E.sunCol * sunV * pow(max(dot(r, E.sun), 0.0), 350.0) * 6.0 * (1.0 - revSh);
    float warp = 0.72 + 0.55 * grime * (0.75 + 0.25 * hc.w) + 0.25 * (hc.y - 0.5) * (1.0 - lod);
    float3 glass = mix(float3(0.010, 0.012, 0.016) * lin * (1.0 - 0.6 * revSh) + wl, env * warp * gTint * (1.0 - 0.35 * revSh), min(F * 0.85, 1.0));
    // wet cladding: polished stone/metal panels mirror a little, rough concrete hardly at all
    float cladSpec = (mh >= 0.62 && mh < 0.8) || sty == 2 ? 0.6 : (mh >= 0.8 ? 0.3 : 0.14);
    col += (mix(E.hor * 0.9 + E.glow * 2.5, E.zen * 1.1, smoothstep(0.0, 0.5, r.y)) * (0.4 + 0.6 * skyV) + neonE * 0.5) * F * cladSpec * (1.0 - winM) * (1.0 - 0.5 * dirt);
    col = mix(col, glass, winM);
    // AC units hanging under some windows (residential)
    if (sty == 1 && lod < 0.9) {
        float2 ac = float2(wf.x - 0.3, wf.y - 0.1) * float2(cw, fh);
        float acm = step(hc.w, 0.35) * clamp((0.35 - abs(ac.x)) / fpU + 0.5, 0.0, 1.0) * clamp((0.28 - abs(ac.y)) / fpV + 0.5, 0.0, 1.0);
        col = mix(col, float3(0.2, 0.2, 0.19) * lin * (0.55 + 0.5 * smoothstep(-0.1, 0.2, ac.y)), acm * (1.0 - lod));
    }
    // LED strip facades (style 2): horizontal light lines per floor
    if (sty == 2) {
        float yy = fract(v / fh);
        float strip = cdLine(abs(yy - 0.02) * fh, 0.07, fpV) * step(0.5, fract(floor(v / fh) * 0.5));
        strip = mix(strip, 0.035 / fh, smoothstep(0.4, 1.2, fpV / fh * 3.0));
        col += cdNeon(fract(L.a.z * 3.3 + 0.3)) * strip * 1.6 * E.neonOn * step(6.0, v);
    }
    // ground-floor shops
    if (v < 6.0) {
        float3 sc = cdNeon(fract(L.a.z * 7.7 + L.b.y * 3.3));
        sc = mix(float3(1.0, 0.62, 0.32), sc, 0.55);
        float shop = smoothstep(0.6, 1.2, v) * smoothstep(4.8, 4.2, v) * (0.6 + 0.4 * cdPulse(u / 6.0, 0.1, 0.9, fpU / 6.0));
        col += sc * shop * 1.4 * E.neonOn;
    }
    // roof crown light
    float crown = cdLine(abs(v - L.h + 1.2), 0.25, fpV) * step(0.55, L.b.z);
    col += cdNeon(fract(L.b.z * 5.1)) * crown * 3.0 * E.neonOn;
    // big wall screen on some lots (flat billboards)
    if (front && L.b.w > 0.7 && L.h > 90.0) {
        float z0 = floor(p.z / LOT) * LOT;
        float bw = LOT - 8.0, bh = 13.0 + 8.0 * L.b.x;
        float by0 = 22.0 + 30.0 * L.b.y;
        float bu = (p.z - z0 - 4.0) / bw, bv = (v - by0) / bh;
        if (bu > 0.0 && bu < 1.0 && bv > 0.0 && bv < 1.0) {
            float3 c1 = cdNeon(fract(L.b.w * 9.1)), c2 = cdNeon(fract(L.b.w * 4.3 + 0.5));
            // abstract motion graphics: sweeping bars + a pulsing emblem
            float ph = E.time * 0.35 + L.a.x * 10.0;
            float bars = cdPulse(bu * 5.0 - ph, 0.0, 0.35, fpU / bw * 5.0);
            float2 ec = float2((bu - 0.5) * bw, (bv - 0.5) * bh);
            float ring = cdLine(abs(length(ec) - (3.0 + 1.5 * sin(ph * 2.0))), 0.8, max(fpU, fpV));
            float3 scr = mix(c1 * 0.25, c2, bars * 0.7) + c1 * ring * 1.5;
            float px = mix(0.75 + 0.25 * cdPulse(v / 0.5, 0.0, 0.6, fpV / 0.5), 0.9, smoothstep(0.3, 1.0, fpV / 0.5));
            float frame = smoothstep(0.0, 0.02, min(min(bu, 1.0 - bu), min(bv, 1.0 - bv)));
            col = mix(float3(0.02), scr * px * (0.9 + 0.9 * E.neonOn), frame);
        }
    }
    return col;
}

// ------------------------------------------------------------------ street traffic (decals + lights + wet streaks)
struct CdCar { float mask; float3 alb; float3 emit; float3 wash; };
inline CdCar cdCars(float3 p, float fpX, float fpZ, float time, float neonOn, thread float& shadowOut) {
    CdCar c; c.mask = 0.0; c.alb = 0.0; c.emit = 0.0; c.wash = 0.0;
    if (abs(p.x) > 14.0) return c;
    float li = floor((p.x + 14.0) / 3.5);
    float xc = -14.0 + 3.5 * (li + 0.5);
    float dir = li < 4.0 ? 1.0 : -1.0;
    float4 lh = hash24(float2(li, 5.0));
    float speed = 9.0 + 6.0 * lh.x;
    float zz = p.z - dir * speed * time;
    float cell0 = floor(zz / 15.0);
    float fpm = max(fpX, fpZ);
    for (int k = 0; k < 3; k++) {
        float cell = cell0 + float(k) * dir;   // this cell and the ones whose streaks reach us
        if (k == 2) cell = cell0 - dir;
        float4 h = hash24(float2(cell, li * 7.0 + 1.0));
        if (h.x > 0.42) continue;
        float len = 4.3 + 0.8 * h.z;
        float zc = cell * 15.0 + 4.0 + h.y * 6.5;
        float dz = zz - zc;
        float dx = p.x - xc - (h.w - 0.5) * 0.7;
        // body
        if (k == 0) {
            float bx = clamp((0.92 - abs(dx)) / fpX + 0.5, 0.0, 1.0);
            float bz = clamp((0.5 * len - abs(dz)) / fpZ + 0.5, 0.0, 1.0);
            float m = bx * bz;
            float3 paint = h.w < 0.3 ? float3(0.02) : (h.w < 0.55 ? float3(0.35, 0.36, 0.37) : (h.w < 0.7 ? float3(0.5, 0.05, 0.04) : float3(0.08, 0.1, 0.14)));
            float dzl = dz * dir;
            float glass = (step(abs(dzl - 0.55), 0.38) + step(abs(dzl + 1.25), 0.25)) * step(abs(dx), 0.78);
            c.alb = mix(paint, float3(0.01), glass * 0.9);
            c.mask = m;
            // contact shadow
            float sh = exp(-pow(max(abs(dx) - 0.8, 0.0) / 0.6, 2.0)) * exp(-pow(max(abs(dz) - 0.5 * len, 0.0) / 0.9, 2.0));
            c.mask = max(c.mask, 0.0);
            c.alb = mix(float3(0.0), c.alb, 1.0);
            c.mask = max(c.mask, 0.0); c.alb = c.alb; shadowOut = sh;
        }
        // lights: front (head) and rear (tail) pairs
        float zf = zc + dir * 0.5 * len, zr = zc - dir * 0.5 * len;
        float r = max(0.22, fpm * 0.6);
        float nrm = 0.05 / (r * r);
        float ax = abs(abs(dx) - 0.62);
        float head = exp(-(ax * ax + (zz - zf) * (zz - zf)) / (r * r)) * nrm;
        float tail = exp(-(ax * ax + (zz - zr) * (zz - zr)) / (r * r)) * nrm;
        c.emit += float3(1.0, 0.92, 0.78) * head * 14.0 * neonOn + float3(1.0, 0.04, 0.02) * tail * (6.0 * neonOn + 0.6);
        // wet-road streaks toward the camera (+z) and headlight wash ahead of oncoming cars
        float sw = exp(-dx * dx / 0.5);
        float dF = p.z - (zf + dir * 0.0);
        float dR = p.z - zr;
        float hs = dF > 0.0 ? exp(-dF / 7.0) : 0.0;
        float ts = dR > 0.0 ? exp(-dR / 5.0) : 0.0;
        c.wash += (float3(1.0, 0.9, 0.75) * hs * 0.5 * (dir > 0.0 ? 1.0 : 0.25) + float3(1.0, 0.05, 0.02) * ts * 0.28) * sw * neonOn;
        float ahead = (p.z - zf) * dir;
        if (ahead > 0.0) c.wash += float3(1.0, 0.9, 0.78) * 0.05 * exp(-ahead / 14.0) * exp(-dx * dx / (1.2 + 0.08 * ahead * ahead * 0.1)) * neonOn;
    }
    return c;
}

// ------------------------------------------------------------------ reflection lookup (simplified)
inline float3 cdReflect(float3 ro, float3 rd, float blur, float pa, thread CdEnv& E, float sunV) {
    CdHit h = cdTrace(ro, rd, E.time, false, 3, pa, false);
    float3 halo = 0.0, emit = 0.0;
    cdSigns(ro, rd, 1.0, h, E.time, E.neonOn, pa, blur, halo, emit, 2);
    cdSigns(ro, rd, -1.0, h, E.time, E.neonOn, pa, blur, halo, emit, 2);
    float3 col;
    float3 p = ro + rd * h.t;
    if (h.kind == 0) {
        col = mix(E.hor, E.zen, smoothstep(0.0, 0.5, rd.y)) + E.glow * (1.2 + 2.0 * exp(-max(rd.y, 0.0) * 5.0));
        col = mix(col, E.hor * 0.5 + E.glow * 3.0, smoothstep(0.12, 0.0, rd.y) * 0.6);
        float mu = max(dot(rd, E.sun), 0.0);
        col += E.sunCol * sunV * (pow(mu, 2000.0) * 40.0 + pow(mu, 60.0) * 0.6 * blur * 40.0) * 0.5;
    } else if (h.kind == 2) {
        CdLot L = cdLot(h.s, h.lot);
        // cheap averaged facade for blurred reflections
        float litP = mix(0.06, 0.42, E.neonOn);
        float3 em = float3(1.0, 0.7, 0.46) * 0.09 * litP * E.neonOn;
        if (L.sty == 2.0) em += cdNeon(fract(L.a.z * 3.3 + 0.3)) * 0.07 * E.neonOn;
        float3 sc = mix(float3(1.0, 0.62, 0.32), cdNeon(fract(L.a.z * 7.7 + L.b.y * 3.3)), 0.55);
        em += sc * 0.8 * E.neonOn * smoothstep(6.0, 4.5, p.y) * smoothstep(0.5, 1.0, p.y);
        float3 wall = mix(float3(0.12), float3(0.22), L.a.w);
        float sunV2 = abs(h.n.x) > 0.5 ? max(dot(h.n, E.sun), 0.0) * smoothstep(L.h * 0.5, L.h, p.y) : 0.0;
        col = wall * (E.zen * 0.7 + E.hor * 0.3 + E.glow * 2.0 + E.sunCol * sunV2 / PI) + em;
    } else if (h.kind == 4) {
        col = float3(0.01);
    } else if (h.kind == 6) {
        col = float3(0.9, 0.95, 1.0) * 1.2 * (0.3 + E.neonOn) * step(17.8, p.y) * step(p.y, 19.4);
    } else {
        col = float3(0.03) * (E.zen + E.glow * 2.0);
    }
    col += emit + halo;
    float fog = ws_fogAmount(h.t, ro, rd, 0.0016, 0.004);
    return mix(col, E.hor + E.glow * 2.0, fog);
}

// ------------------------------------------------------------------ hologram (focal point)
__attribute__((noinline)) float3 cdHolo(float3 ro, float3 rd, float tMax, float pa, thread CdEnv& E) {
    float zH = -372.0;
    float t = (zH - ro.z) / rd.z;
    if (t <= 0.0 || t > tMax) return float3(0.0);
    float3 p = ro + rd * t;
    const float HS = 1.4;
    float2 c = float2(p.x - 9.0, p.y - 92.0) / HS;
    float2 hs = float2(22.0, 30.0);
    float2 q = abs(c) - hs;
    if (max(q.x, q.y) > 6.0) return float3(0.0);
    float fp = t * pa / HS;
    float edge = clamp(-max(q.x, q.y) / 4.0, 0.0, 1.0);
    // glitch displacement bands
    float gb = floor(c.y / 3.0 + floor(E.time * 3.0) * 7.0);
    float gl = step(0.93, hash11(gb * 0.37 + floor(E.time * 3.0))) * (hash11(gb) - 0.5) * 6.0;
    float2 cc = float2(c.x + gl, c.y);
    float r = length(cc);
    float a = atan2(cc.y, cc.x);
    // concentric broken rings
    float3 col = float3(0.0);
    for (int k = 0; k < 3; k++) {
        float R = 8.0 + 6.5 * float(k);
        float spin = E.time * (0.25 - 0.18 * float(k)) + float(k) * 1.7;
        float seg = step(0.35, fract((a + spin) / TAU * (5.0 + 3.0 * float(k))));
        float ring = cdLine(abs(r - R), 0.9 - 0.2 * float(k), fp) * seg;
        col += mix(float3(0.1, 0.8, 1.0), float3(1.0, 0.1, 0.7), float(k) * 0.5) * ring * 1.6;
    }
    // central abstract glyph: slowly turning hexagon around a live waveform
    float ha = a + E.time * 0.15;
    float hexR = 5.2 * cos(PI / 6.0) / cos(fmod(ha + TAU * 4.0, PI / 3.0) - PI / 6.0);
    float hexL = cdLine(abs(r - hexR), 0.55, fp);
    float wave = cc.y - 1.6 * sin(cc.x * 1.3 + E.time * 2.2) * exp(-cc.x * cc.x * 0.06) * (0.6 + 0.4 * sin(E.time * 0.7));
    float waveL = cdLine(abs(wave), 0.45, fp) * step(abs(cc.x), 4.2);
    col += float3(1.0, 0.3, 0.8) * hexL * 1.8 + float3(0.45, 0.95, 1.0) * waveL * 1.8 + float3(0.4, 0.8, 1.0) * exp(-r * 0.45) * 0.35;
    // glyph columns on the sides
    float gx = (abs(cc.x) - 17.0) / 3.0;
    if (gx > 0.0 && gx < 1.0) {
        float row = floor((cc.y + E.time * 4.0) / 3.2);
        float fr = fract((cc.y + E.time * 4.0) / 3.2);
        float bitv = step(0.45, hash12(float2(row, sign(cc.x) + floor(gx * 3.0) * 5.0)));
        float m = cdPulse(gx * 3.0, 0.15, 0.85, fp / 1.0) * cdPulse(fr, 0.15, 0.8, fp / 3.2);
        col += float3(0.2, 0.9, 1.0) * bitv * m * 1.2;
    }
    // scanlines (filtered)
    float scan = mix(0.55 + 0.45 * cdPulse(c.y / 1.6, 0.0, 0.5, fp / 1.6), 0.78, smoothstep(0.4, 1.0, fp / 1.6));
    float flick = 0.9 + 0.1 * sin(E.time * 23.0) * sin(E.time * 7.3);
    float amount = smoothstep(0.02, 0.5, E.neonOn) * 0.3 + 0.7 * E.neonOn;
    return col * scan * flick * edge * amount * 1.4;
}

// ------------------------------------------------------------------ volumetric extras
inline float3 cdSearch(float3 ro, float3 rd, float tMax, float3 S, float ang, float el, float3 c) {
    float3 D = float3(sin(el) * cos(ang), cos(el), sin(el) * sin(ang));
    float3 w0 = ro - S;
    float b = dot(rd, D), d = dot(rd, w0), e = dot(D, w0);
    float den = max(1.0 - b * b, 1e-4);
    float tr = clamp((b * e - d) / den, 0.0, tMax);
    float ub = max(e + b * tr, 0.0);
    float3 dv = (ro + rd * tr) - (S + D * ub);
    float dist2 = dot(dv, dv);
    float w = 6.0 + 0.045 * ub;
    return c * exp(-dist2 / (w * w)) * exp(-ub * 0.0009) * (w0.y < 0.0 ? 1.0 : 1.0) * (18.0 / w);
}

inline float3 cdTraffic(float3 ro, float3 rd, float tMax, float pa, float time) {
    float3 acc = float3(0.0);
    for (int k = 0; k < 4; k++) {
        float zl = -520.0 - 330.0 * float(k);
        float t = (zl - ro.z) / rd.z;
        if (t <= 0.0 || t > tMax) continue;
        float3 p = ro + rd * t;
        float yl = 110.0 + 42.0 * float(k) + 9.0 * sin(float(k) * 2.3);
        float spd = (k % 2 == 0 ? 1.0 : -1.0) * (26.0 + 6.0 * float(k));
        float sp = 70.0 + 25.0 * float(k);
        float xs = p.x - spd * time;
        float cell = floor(xs / sp);
        float4 h = hash24(float2(cell, float(k) * 7.0));
        if (h.x > 0.55) continue;
        float cx = (h.y - 0.5) * sp * 0.4;
        float dx = xs - (cell + 0.5) * sp - cx;
        float dy = p.y - yl - (h.z - 0.5) * 16.0;
        float fp = max(t * pa, 0.05);
        float r = max(0.5, fp * 0.8);
        float dot0 = exp(-(dx * dx + dy * dy) / (r * r)) * (0.5 * 0.5) / (r * r);
        // trail behind motion direction
        float back = -dx * sign(spd);
        float trail = (back > 0.0 ? exp(-back / 16.0) : 0.0) * exp(-dy * dy / (r * r)) * (0.5 / r) * 0.35;
        float3 hc = h.w > 0.5 ? float3(1.0, 0.9, 0.8) : float3(0.4, 0.9, 1.0);
        acc += hc * dot0 * 9.0 + float3(1.0, 0.15, 0.1) * trail * 2.5;
    }
    return acc;
}

inline float4 cdSteam(float3 ro, float3 rd, float tMax, float pa, thread CdEnv& E, float3 ambC) {
    float4 acc = float4(0.0);
    for (int k = 0; k < 4; k++) {
        float zv = -64.0 - 48.0 * float(k) - 13.0 * float(k * k % 3);
        float xv = k == 0 ? 5.0 : (k == 1 ? -6.5 : (k == 2 ? 9.0 : -1.5));
        float t = (zv - ro.z) / rd.z;
        if (t <= 0.0 || t > tMax) continue;
        float3 p = ro + rd * t;
        float y = p.y;
        if (y < 0.0 || y > 40.0) continue;
        float sway = sin(y * 0.18 - E.time * 0.35 + float(k)) * 1.2 + y * 0.12;
        float wdt = 1.6 + 0.45 * y;
        float dx = (p.x - xv - sway) / wdt;
        if (abs(dx) > 1.6) continue;
        float n = fbm(float2(p.x * 0.22 + float(k) * 3.0, y * 0.16 - E.time * 0.5), 2);
        float d = exp(-dx * dx * 1.8) * smoothstep(0.0, 1.5, y) * exp(-y * 0.1) * clamp(0.55 + 0.9 * n, 0.0, 1.0);
        float a = d * 0.6;
        float3 c = ambC * (0.9 + 0.5 * n);
        acc.rgb += (1.0 - acc.a) * a * c;
        acc.a += (1.0 - acc.a) * a;
    }
    return acc;
}

inline float cdRain(float2 fc, float2 res, float time) {
    float2 uv = fc / res.y;
    float acc = 0.0;
    for (int k = 0; k < 2; k++) {
        float sc = k == 0 ? 1.0 : 2.1;
        float cols = 55.0 * sc;
        float x = (uv.x + uv.y * 0.06) * cols;
        float ci = floor(x);
        uint hb = ws_pcg(uint(int(ci) + 4096) * 3u + uint(k) * 0x9E3779B9u);
        if ((hb & 1023u) > 307u) continue;                       // ~30% of columns carry a streak
        float hx = float((hb >> 10) & 1023u) / 1023.0;
        float hy = float((hb >> 20) & 1023u) / 1023.0;
        float hz = float(ws_pcg(hb) & 65535u) / 65535.0;
        float fx = x - ci;
        float speed = (k == 0 ? 1.9 : (k == 1 ? 1.4 : 1.0)) * (0.85 + 0.3 * hy);
        float cy = fract(uv.y * sc * 0.9 + time * speed * sc * 0.5 + hz * 10.0);
        float len = k == 0 ? 0.16 : 0.12;
        float along = smoothstep(0.0, len * 0.5, cy) * smoothstep(len, len * 0.5, cy);
        float pxPerCell = res.y / cols;
        float wdt = max(0.75 / pxPerCell, 0.02);
        float dx = (fx - 0.15 - 0.7 * hx) / wdt;
        float across = max(1.0 - dx * dx * 0.5, 0.0); across *= across;
        float bright = (k == 0 ? 0.5 : (k == 1 ? 0.4 : 0.3)) * min(1.0, 1.0 / (wdt * pxPerCell));
        acc += along * across * bright;
    }
    return acc;
}

// ------------------------------------------------------------------ main
float3 scene(float2 fragCoord, WSCtx ctx) {
    float rainV = cdRain(fragCoord, ctx.res, ctx.time);
    CdEnv E;
    E.sun = ws_rotY(ctx.sunDir, -PI * 0.5);
    E.moon = ws_rotY(ctx.moonDir, -PI * 0.5);
    E.time = ctx.time;
    E.moonIllum = ctx.moonIllum;
    float elev = ctx.sunElevation;
    E.day = smoothstep(-6.0, 10.0, elev);
    E.night = smoothstep(-3.0, -12.0, elev);
    E.neonOn = smoothstep(6.0, -7.0, elev);
    E.sunCol = cdSunColor(elev);
    E.twi = smoothstep(1.0, -3.0, elev) * smoothstep(-15.0, -6.0, elev);
    float3 sunA = E.sun;
    E.zen = cdTab(CD_ZEN, elev) * mix(1.0, 2.4, E.day);   // 2-step zenith underestimates the skylight dome
    E.hor = cdTab(CD_HOR, elev) * 0.8 + E.zen * 0.2;   // horizon haze away from the sunset side
    // smoggy haze: desaturate the horizon a touch
    E.hor = mix(E.hor, float3(ws_luma(E.hor)), 0.3);
    E.zen += E.twi * float3(0.010, 0.020, 0.050);
    E.hor += E.twi * float3(0.018, 0.022, 0.040);
    E.glow = (float3(0.028, 0.012, 0.030) * 0.08 + float3(0.02, 0.009, 0.004) * 0.05) * E.neonOn * mix(0.35, 1.0, E.night);

    float3 ro = float3(0.0, CAMY, 0.0);
    float3 ta = float3(11.0, CAMY - 11.0, -100.0);
    float fov = 50.0;
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ta, fov);
    float pa = 2.0 * tan(fov * PI / 360.0) / ctx.res.y;

    CdHit h = cdTrace(ro, rd, E.time, true, 4, pa, true);
    float3 halo = 0.0, emitDummy = 0.0;
    bool ledge = h.kind == 8;
    CdHit hs = h;
    if (!ledge) {
        cdSigns(ro, rd, 1.0, hs, E.time, E.neonOn, pa, 0.0, halo, emitDummy, 4);
        cdSigns(ro, rd, -1.0, hs, E.time, E.neonOn, pa, 0.0, halo, emitDummy, 4);
    }
    h = hs;
    float3 p = ro + rd * h.t;
    float3 col;
    float dist = h.t;
    float muS = max(dot(normalize(float3(rd.x, 0.05, rd.z)), E.sun), 0.0);
    float3 fogC = E.hor + E.sunCol * (0.016 * pow(muS, 3.0) + 0.045 * pow(muS, 20.0)) * smoothstep(-0.05, 0.05, E.sun.y) + E.glow * 2.5;

    float3 nlAll = float3(0.0);
    float fogD = mix(0.0010, 0.0015, E.neonOn);
    if (E.neonOn > 0.001 && h.kind != 0 && h.kind != 4 && h.kind != 6) nlAll = cdNeonLight(p, h.n, E.time, E.neonOn);
    if (h.kind == 0) {
        col = cdSky(rd, E, pa, true);
        float sd = 0.0, sy = 0.0;
        float4 sl = cdSkyline(rd, pa, E, sd, sy);
        if (sl.a > 0.0) {
            float fg = ws_fogAmount(sd, ro, rd, 0.00055, 0.005);
            fg = 1.0 - (1.0 - fg) * (1.0 - 0.55 * exp(-max(sy, 0.0) / 140.0));   // ground haze thickens toward the street
            float3 skyBehind = col;
            float3 b = mix(sl.rgb, mix(fogC, skyBehind, 0.6), fg);
            col = mix(col, b, sl.a);
        }
        dist = 0.0;
    } else if (h.kind == 4) {
        CdLot L = cdLot(h.s, h.lot);
        CdSign g = cdSignOf(L, h.s, h.lot, E.time, E.neonOn);
        float fp = h.t * pa / max(abs(rd.z), 0.2);
        float4 e4 = cdSignEmit(g, h.s * p.x - g.x0, p.y - g.y0, fp, 0.0, 0.0, E.time);
        float3 e = e4.rgb;
        float print = e4.a;
        // unlit by day: painted steel backer with pale glass tubes, or a milky acrylic light-box
        float su = h.s * p.x - g.x0, sv2 = p.y - g.y0;
        float dirtS = vnoise(float2(su * 1.5, sv2 * 0.4) + g.seed * 40.0);
        float3 backer = mix(float3(0.05, 0.05, 0.055), g.col * 0.08 + 0.03, 0.4) * (0.75 + 0.4 * dirtS);
        float3 tubeG = mix(float3(0.42, 0.44, 0.46), g.col * 0.5 + 0.12, 0.35);
        float3 acryl = mix(float3(0.55), g.col, 0.45) * 0.55 * (0.85 + 0.2 * dirtS);
        float3 face = g.type < 0.5 ? mix(backer, tubeG, min(print, 1.0)) : acryl * (1.0 - 0.7 * min(print, 1.0));
        face *= mix(0.7, 1.0, smoothstep(0.0, 2.0, sv2));                      // grime at the bottom edge
        float3 base = face * (E.zen * 0.8 + E.hor * 0.4 + E.sunCol * max(E.sun.z, 0.0) * cdSunVis(p, E.sun) / PI)
                    + (E.zen * 0.6 + E.hor * 0.2) * 0.12 * min(print, 1.0) * step(g.type, 0.5);   // tube glass sheen
        col = base * (1.0 - E.neonOn * 0.8) + e;
    } else if (h.kind == 2) {
        CdLot L = cdLot(h.s, h.lot);
        float sv = cdSunVis(p, E.sun);
        col = cdFacade(p, h.n, rd, L, h.s, h.t, pa, E, sv, false, nlAll, h.lot);
    } else if (h.kind == 1 || h.kind == 3 || h.kind == 8) {
        // wet ground (street or rooftop ledge)
        float3 n = float3(0, 1, 0);
        float fp = h.t * pa;
        float cosi = max(-rd.y, 0.02);
        float fpX = fp * max(1.0, abs(rd.x) / cosi), fpZ = fp * max(1.0, abs(rd.z) / cosi);
        float3 alb; float puddle; float blur; float3 carE = 0.0; float3 carSh = 0.0; float carM = 0.0;
        float sv = cdSunVis(p, E.sun);
        if (ledge) {
            // precast concrete coping: joints, aggregate, lichen, shallow rain puddles with ripples
            float g = vnoise(p.xz * float2(3.0, 5.0)) * 2.0 - 1.0;
            float agg = mix(vnoise(p.xz * 60.0), 0.5, smoothstep(0.002, 0.008, fp));
            float jx = abs(fract((p.x + 1.05) / 1.5 + 0.5) - 0.5) * 1.5;
            float joint = cdLine(jx, 0.012, fpX);
            float jAO = 1.0 - 0.35 * exp(-jx / 0.05);
            float lich = smoothstep(0.62, 0.9, vnoise(p.xz * float2(1.1, 3.0) + 7.0)) * smoothstep(-0.2, 0.3, jx);
            float dip = fbm(p.xz * float2(0.9, 2.4) + 3.0, 2) - 0.25 * smoothstep(-1.6, -2.05, p.z);
            puddle = smoothstep(0.04, 0.16, dip);
            float wetEdge = smoothstep(-0.1, 0.06, dip);
            alb = mix(float3(0.11, 0.105, 0.098), float3(0.07, 0.068, 0.064), wetEdge) * (0.8 + 0.3 * g) * (0.9 + 0.2 * agg);
            alb = mix(alb, float3(0.07, 0.075, 0.05), lich * 0.5 * (1.0 - puddle));
            alb *= jAO * (1.0 - 0.7 * joint);
            blur = mix(0.12, 0.003, puddle);
            // rain ripples in the puddles
            float2 rq = p.xz * float2(9.0, 7.0);
            float2 ci = floor(rq);
            float2 rf = fract(rq) - 0.5;
            float4 rh = hash24(ci);
            float ph = fract(E.time * 1.3 + rh.x);
            float rr = length(rf - (rh.yz - 0.5) * 0.4);
            float ring = sin((rr - ph * 0.45) * 38.0) * exp(-ph * 4.0) * smoothstep(0.45 * ph + 0.1, 0.45 * ph, rr) * smoothstep(0.0, 0.12, rr);
            float rip = ring * puddle * smoothstep(0.05, 0.01, fp) * 0.3;
            // rounded bullnose on the street-side edge tips the normal toward the canyon
            float bn = smoothstep(-1.93, -2.1, p.z);
            n = normalize(float3(rip * 0.25 * rf.x, 1.0 - 0.8 * bn, rip * 0.25 * rf.y - 0.9 * bn));
            puddle *= 1.0 - bn;
            // shadow of the stair tower behind the camera (keeps the foreground calm and grounded)
            float shs = 1.0, tt = 0.05;
            for (int j = 0; j < (E.sun.y > -0.01 ? 10 : 0); j++) {
                float3 q = p + E.sun * tt;
                float3 d1 = abs(q - float3(-8.1, CAMY + 1.65, 3.35)) - float3(5.9, 2.85, 5.65);
                float3 d2 = abs(q - float3(3.85, CAMY + 0.8, 1.85)) - float3(0.35, 2.0, 0.35);
                float sd = min(length(max(d1, 0.0)) + min(max(d1.x, max(d1.y, d1.z)), 0.0),
                               length(max(d2, 0.0)) + min(max(d2.x, max(d2.y, d2.z)), 0.0));
                shs = min(shs, 18.0 * sd / tt);
                tt += clamp(sd, 0.1, 2.0);
                if (shs < 0.01 || tt > 25.0) break;
            }
            sv = step(0.0, E.sun.y) * smoothstep(0.0, 1.0, clamp(shs, 0.0, 1.0));
        } else if (h.kind == 3) {
            // roofs: wet membrane with seams, parapets, rooftop plant with contact shadows
            CdLot L = cdLot(h.s, h.lot);
            bool podR = abs(p.y - L.h1) < 0.5 && L.sb > 0.0;
            float ax = h.s * p.x;
            float xEdge = CW + L.off + (podR ? 0.0 : L.sb);
            float za = float(h.lot) * LOT;
            float dEdge = min(ax - xEdge, min(p.z - za, za + LOT - p.z));
            float g = vnoise(p.xz * 0.8) * 2.0 - 1.0;
            puddle = smoothstep(0.0, 0.3, fbm(p.xz * 0.12 + L.a.xy * 9.0, 2));
            alb = mix(float3(0.07, 0.07, 0.075), float3(0.11, 0.10, 0.095), L.a.z) * (0.8 + 0.4 * g);
            float seam = cdLine(abs(fract(p.x / 1.6 + 0.5) - 0.5) * 1.6, 0.05, fpX) + cdLine(abs(fract(p.z / 6.0 + 0.5) - 0.5) * 6.0, 0.05, fpZ);
            alb *= 1.0 - 0.3 * min(seam, 1.0);
            float2 cellS = float2(5.0, 6.0);
            float2 uc = fract(p.xz / cellS) - 0.5;
            float2 ui = floor(p.xz / cellS);
            float4 uh = hash24(ui + L.a.zw * 50.0);
            float2 hb = float2(0.3 + 0.12 * uh.y, 0.26 + 0.1 * uh.z) ;
            float2 qd = (abs(uc) - hb) * cellS;                      // metres outside the unit
            float dU = max(qd.x, qd.y);
            bool hasU = uh.x < 0.35 && dEdge > 3.0;
            float fpm = max(fpX, fpZ);
            float unit = hasU ? clamp(-dU / fpm + 0.5, 0.0, 1.0) : 0.0;
            float ao = hasU ? 1.0 - 0.55 * exp(-max(dU, 0.0) / 0.9) : 1.0;
            float bev = hasU ? smoothstep(0.0, 0.35, -dU) : 0.0;
            float3 unitC = mix(float3(0.13, 0.135, 0.14), float3(0.28, 0.28, 0.27), uh.w) * (0.55 + 0.6 * bev);
            float fan = hasU && uh.w > 0.6 ? cdLine(abs(length(uc * cellS) - 0.5), 0.12, fpm) : 0.0;
            unitC *= 1.0 - 0.5 * fan;
            alb = mix(alb * ao, unitC, unit);
            // parapet along the roof edges
            float par = clamp((0.45 - dEdge) / fpm + 0.5, 0.0, 1.0);
            float parSh = exp(-max(dEdge - 0.45, 0.0) / 0.7) * (1.0 - par);
            alb = mix(alb * (1.0 - 0.45 * parSh), float3(0.2, 0.19, 0.18), par);
            puddle *= (1.0 - unit) * (1.0 - par);
            blur = mix(0.08, 0.01, puddle);
            carE = float3(0.0);
            float skyl = (hasU && uh.z > 0.8) ? unit * (0.5 + 0.5 * bev) : 0.0;
            carE += mix(float3(1.0, 0.8, 0.6), cdNeon(uh.y), 0.4) * 0.06 * skyl * E.neonOn;
            // red aviation lamps on parapet corners
            float2 cq = float2(ax - xEdge, min(p.z - za, za + LOT - p.z));
            float lamp = exp(-dot(cq - 0.3, cq - 0.3) / max(fpm * fpm, 0.04)) * min(1.0, 0.04 / (fpm * fpm));
            carE += float3(1.0, 0.03, 0.02) * lamp * 4.0 * step(0.5, fract(E.time * 0.6 + L.a.x)) * E.neonOn;
        } else {
            float side = abs(p.x);
            bool walk = side > CW - 5.5;
            float g = vnoise(p.xz * 0.6) * 2.0 - 1.0;
            puddle = smoothstep(0.08, 0.3, fbm(p.xz * float2(0.07, 0.045) + 1.3, 2) + 0.08 * g);
            alb = walk ? float3(0.12, 0.115, 0.11) : float3(0.045, 0.045, 0.05);
            alb *= 0.8 + 0.4 * g;
            // lane markings
            float lm = abs(fract((p.x + 14.0) / 3.5 + 0.5) - 0.5) * 3.5;
            float lane = cdLine(lm, 0.15, fpX) * cdPulse(p.z / 9.0, 0.0, 0.45, fpZ / 9.0) * step(side, 12.5);
            float centre = cdLine(abs(abs(p.x) - 0.2), 0.14, fpX);
            float kerb = cdLine(abs(side - (CW - 5.5)), 0.35, fpX);
            alb += float3(0.3) * lane * (1.0 - 0.6 * puddle) + float3(0.35, 0.3, 0.1) * centre + float3(0.1) * kerb;
            blur = mix(0.09, 0.012, puddle) * (walk ? 1.3 : 1.0);
            float csh = 0.0;
            CdCar cc = cdCars(p, fpX, fpZ, E.time, E.neonOn, csh);
            alb = mix(alb, cc.alb, cc.mask);
            carM = cc.mask;
            puddle *= 1.0 - cc.mask;
            carE = cc.emit + cc.wash * (0.4 + 0.6 * puddle) * (1.0 - cc.mask);
            carSh = float3(-0.7 * csh * (1.0 - cc.mask));
        }
        float3 r = reflect(rd, n);
        float cr = max(dot(-rd, n), 0.0);
        float F = 0.02 + 0.98 * pow(1.0 - cr, 5.0);
        F *= mix(h.kind == 3 ? 0.3 : 0.55, 1.0, puddle);
        F = min(F, mix(0.22, 1.0, puddle));        // rough membrane / asphalt never turns into a mirror
        float3 refl = cdReflect(p + n * 0.02, r, blur, pa, E, sv);
        if (ledge) refl = mix((E.hor * 0.5 + E.zen * 0.4) * 0.7 + E.glow * 3.0 + float3(0.5, 0.2, 0.5) * 0.02 * E.neonOn, refl, puddle);
        float3 nl = nlAll;
        float skyV = (ledge || h.kind == 3) ? 0.95 : 0.3 + 0.2 * smoothstep(CW - 6.0, 4.0, abs(p.x));
        float3 lin = E.sunCol * max(E.sun.y, 0.0) * sv / PI + (E.zen * 0.8 + E.hor * 0.4) * skyV + E.glow * 2.0 + nl;
        col = alb * (1.0 - 0.6 * puddle) * lin * (1.0 + min(carSh, 0.0)) + refl * F + carE;
        // car roofs and glass pick up a soft sky sheen
        col += carM * (E.zen * 0.9 + E.hor * 0.3 + E.glow * 3.0 + nl * 0.5) * 0.07;
        if (ledge) {
            // shallow contact darkening toward the camera side keeps the Dock area calm
            col *= mix(0.55, 1.0, smoothstep(-0.9, -1.9, p.z));
            // the neon canyon below washes the rounded street-side edge and the wet film with colour
            float3 up = (float3(0.9, 0.25, 0.7) * 0.6 + float3(0.2, 0.6, 1.0) * 0.4) * E.neonOn;
            col += up * (0.05 * smoothstep(-1.93, -2.1, p.z) + 0.006 * (0.4 + puddle)) * smoothstep(-1.2, -2.05, p.z);
        }
    } else if (h.kind == 10 || h.kind == 11) {
        // rooftop plant: weathered steel water tanks and concrete penthouses with louvres
        CdLot L = cdLot(h.s, h.lot);
        float fp = h.t * pa;
        float sv = cdSunVis(p, E.sun);
        float ndl = max(dot(h.n, E.sun), 0.0);
        float hy = p.y - L.h;
        float3 alb;
        if (h.kind == 10) {
            float ang = atan2(h.n.z, h.n.x);
            float stave = mix(0.85 + 0.15 * cdPulse(ang * 9.0, 0.0, 0.2, fp * 4.0), 0.88, smoothstep(0.2, 0.8, fp * 4.0));
            float hoop = 1.0 - 0.35 * cdPulse((hy - 2.2) / 1.3, 0.0, 0.1, fp / 1.3);
            float rust = vnoise(float2(ang * 4.0, hy * 1.5) + L.a.xy * 20.0);
            alb = mix(float3(0.16, 0.13, 0.10), float3(0.24, 0.12, 0.06), rust) * stave * hoop;
            alb *= mix(0.7, 1.0, smoothstep(2.2, 4.5, hy));          // rain-darkened base
            if (h.n.y > 0.5) alb = float3(0.09, 0.085, 0.08);
        } else {
            bool top = h.n.y > 0.5;
            float uu = abs(h.n.x) > 0.5 ? p.z : p.x;
            float louv = top ? 0.0 : mix(cdPulse(hy / 0.35, 0.0, 0.45, fp / 0.35), 0.45, smoothstep(0.3, 1.0, fp / 0.35)) * step(1.0, hy) * step(hy, 2.8) * cdPulse(uu / 5.0, 0.15, 0.55, fp / 5.0);
            float stain = vnoise(float2(uu * 0.5, hy * 0.25) + L.a.zw * 30.0);
            alb = mix(float3(0.20, 0.195, 0.185), float3(0.30, 0.29, 0.27), L.b.x) * (0.75 + 0.35 * stain) * (1.0 - 0.55 * louv);
            alb *= mix(0.72, 1.0, smoothstep(0.0, 1.2, hy));        // splash-back grime at the foot
            if (top) alb *= 0.6;
        }
        float ao = h.n.y > 0.5 ? 1.0 : mix(0.55, 1.0, smoothstep(0.0, 2.5, hy));
        float3 lin = E.sunCol * ndl * sv / PI + (E.zen * 0.8 + E.hor * 0.35) * ao * (h.n.y > 0.5 ? 1.0 : 0.6) + E.glow * 2.0 + nlAll;
        col = alb * lin;
        // wet top sheen
        col += (E.zen * 0.6 + E.glow * 2.0) * 0.08 * step(0.5, h.n.y);
    } else if (h.kind == 9) {
        float fp = h.t * pa;
        float3 lin = E.sunCol * max(dot(h.n, E.sun), 0.0) * cdSunVis(p, E.sun) / PI + E.zen * 0.6 + E.hor * 0.3 + E.glow * 2.0 + nlAll;
        float y0 = p.y > 35.0 ? 40.0 : 27.0;
        float band = cdPulse((p.y - y0) / (p.y > 35.0 ? 5.0 : 4.0), 0.25, 0.8, fp * 1.5 / 4.5);
        float mull = cdPulse(p.x / 2.0, 0.08, 1.0, fp * 1.5 / 2.0);
        float side = step(0.5, abs(h.n.z));
        col = float3(0.09, 0.095, 0.1) * lin * (1.0 - band * side);
        float3 env = mix(E.hor, E.zen, 0.4) * 0.3 * (1.0 - 0.55 * (1.0 - mull)) * (0.8 + 0.3 * vnoise(p.xy * float2(0.15, 0.6)));
        float bayLit = step(0.55, hash11(floor(p.x / 2.0) + y0 * 3.1));
        col += band * side * ((float3(1.0, 0.7, 0.42) * 0.16 * bayLit + float3(0.01)) * E.neonOn * mull + env + nlAll * 0.08);
        col += float3(0.1, 0.8, 1.0) * cdLine(abs(p.y - y0 - 0.3), 0.15, fp) * 2.0 * E.neonOn * side;
        if (h.n.y > 0.5) col = float3(0.07) * lin + float3(0.02) * E.zen;
    } else if (h.kind == 5 || h.kind == 7) {
        float3 lin = E.sunCol * max(dot(h.n, E.sun), 0.0) * cdSunVis(p, E.sun) / PI + E.zen * 0.5 + E.hor * 0.3 + E.glow * 2.0;
        float3 alb = float3(0.10, 0.10, 0.11) * (0.8 + 0.3 * vnoise(p.xz * 0.2));
        col = alb * lin;
        if (h.kind == 5) {
            col += nlAll * alb;
            // underside running light strip
            float fp = h.t * pa;
            float strip = cdLine(abs(p.y - 15.35), 0.15, fp * 2.0) * step(0.5, h.n.x + 0.6);
            col += float3(0.1, 0.8, 1.0) * strip * 2.5 * E.neonOn;
        } else {
            float fp = h.t * pa;
            float strip = cdLine(abs(p.y - 52.4), 0.25, fp) + cdLine(abs(p.y - 54.2), 0.2, fp);
            col += float3(1.0, 0.25, 0.05) * strip * 2.0 * E.neonOn * step(0.5, h.n.z);
        }
    } else {
        // trains: dark shell with lit window band
        float fp = h.t * pa;
        float yb = (h.lot == 0) ? 0.0 : 0.0;
        float wy = p.y - (p.y > 40.0 ? 54.5 : 16.8);
        float band = cdPulse(wy / 3.2, 0.42, 0.7, fp * 2.0 / 3.2);
        float uu = abs(h.n.x) > 0.5 ? p.z : p.x;
        float win = band * cdPulse(uu / 2.2, 0.1, 0.9, fp * 2.0 / 2.2);
        float3 lin = E.sunCol * max(dot(h.n, E.sun), 0.0) / PI + E.zen * 0.5 + E.glow * 2.0;
        col = float3(0.16, 0.17, 0.19) * lin + float3(0.85, 0.92, 1.0) * win * (0.35 + 1.3 * E.neonOn) + yb;
        // headlight
        col += float3(1.0, 0.95, 0.8) * step(0.5, abs(h.n.z)) * band * 3.0 * E.neonOn;
    }

    // aerial perspective / wet smog
    if (h.kind != 0) {
        float fog = ws_fogAmount(dist, ro, rd, fogD * mix(1.0, 0.8, E.day), 0.006);
        // sun-side forward scatter in the haze
        float mu = max(dot(rd, E.sun), 0.0);
        float3 fc = fogC + E.sunCol * (0.012 + 0.08 * pow(mu, 12.0)) * E.day;
        // air down in the shaded canyon scatters far less daylight than the open haze above the roofs
        float yMid = 0.5 * (ro.y + p.y);
        fc = mix(fc, fc * mix(0.42, 1.0, smoothstep(12.0, 95.0, yMid)) + E.glow * 1.5, E.day);
        col = mix(col, fc, fog);
    }
    // antenna masts (analytic coverage) with their own haze + blinking lamps
    if (h.mc > 0.0) {
        float3 pm = ro + rd * h.mt;
        float3 mcCol = float3(0.05, 0.05, 0.055) * (E.zen * 0.7 + E.hor * 0.4 + E.glow * 2.0) + E.sunCol * 0.012 * max(E.sun.y, 0.0);
        float mf = ws_fogAmount(h.mt, ro, rd, fogD, 0.006);
        mcCol = mix(mcCol, fogC, mf);
        col = mix(col, mcCol, h.mc * 0.95);
        col += float3(1.0, 0.04, 0.02) * h.ml * 5.0 * step(0.5, fract(E.time * 0.7 + pm.x * 0.013)) * (0.15 + 0.85 * E.neonOn) * (1.0 - 0.7 * mf);
    }
    float tMax = h.kind == 0 ? 6000.0 : h.t;
    // neon-lit wet haze inside the canyon (in-scatter sampled mid-path)
    {
        float tc = min(tMax, 260.0);
        float3 pm = ro + rd * tc * 0.55;
        if (abs(pm.x) < CW + 6.0 && pm.y < 120.0) {
            float3 hz = nlAll * 0.22;
            float path = 1.0 - exp(-tc * 0.004);
            col += hz * path * 1.4 * smoothstep(120.0, 20.0, pm.y);
        }
    }
    col += halo * (1.0 - 0.6 * E.day);
    // hologram
    if (E.neonOn > 0.02) col += cdHolo(ro, rd, tMax, pa, E);
    // overhead cables strung across the canyon (thin catenaries, silhouetted against the glow)
    for (int k = 0; k < 5; k++) {
        float zc = -46.0 - 37.0 * float(k) - 9.0 * float(k * k % 3);
        float tcb = (zc - ro.z) / rd.z;
        if (tcb <= 0.0 || tcb > tMax) continue;
        float3 pc = ro + rd * tcb;
        if (abs(pc.x) > CW + 1.0) continue;
        float ya = 18.0 + 11.0 * float(k % 3) + 4.0 * sin(float(k) * 2.1);
        float yb = ya + 5.0 * sin(float(k) * 1.3);
        float u = pc.x / CW;
        float sag = 3.5 + 1.5 * float(k % 2);
        float yc = mix(ya, yb, 0.5 + 0.5 * u) - sag * (1.0 - u * u) + 0.25 * sin(E.time * 0.8 + float(k)) * (1.0 - u * u);
        float fpc = tcb * pa;
        float cov = cdLine(abs(pc.y - yc), 0.06, fpc) + cdLine(abs(pc.y - yc + 0.9), 0.04, fpc) * step(1.5, float(k % 3));
        float3 cabC = float3(0.012) + E.zen * 0.05 + E.glow * 0.5;
        col = mix(col, cabC, clamp(cov, 0.0, 1.0) * 0.9);
    }
    // steam
    float3 ambC = E.zen * 0.9 + E.hor * 0.6 + E.glow * 8.0 + float3(0.22, 0.08, 0.2) * E.neonOn + E.sunCol * 0.01;
    float4 st = cdSteam(ro, rd, tMax, pa, E, ambC);
    col = col * (1.0 - st.a) + st.rgb;
    // air traffic + searchlights (night)
    if (E.neonOn > 0.01) {
        col += cdTraffic(ro, rd, tMax, pa, E.time) * E.neonOn;
        if (E.night > 0.005) {
            float3 sl = cdSearch(ro, rd, tMax, float3(-420.0, 0.0, -1500.0), E.time * 0.21, 0.42, float3(0.6, 0.7, 1.0));
            sl += cdSearch(ro, rd, tMax, float3(520.0, 0.0, -1900.0), -E.time * 0.17 + 2.0, 0.5, float3(0.7, 0.75, 1.0));
            sl += cdSearch(ro, rd, tMax, float3(150.0, 0.0, -1100.0), E.time * 0.13 + 4.0, 0.35, float3(1.0, 0.5, 0.9));
            col += sl * 0.045 * E.night;
        }
    }
    // veiling glare when the low sun sits in the canyon slot (lens + wet-air forward scatter)
    if (E.sun.y > -0.02) {
        float sv0 = cdSunVis(ro + float3(0.0, 0.0, -30.0), E.sun);
        float ang = acos(clamp(dot(rd, E.sun), -1.0, 1.0));
        float lowSun = smoothstep(25.0, 3.0, elev) * smoothstep(-1.0, 0.5, elev);
        col += E.sunCol * sv0 * lowSun * (0.03 * exp(-ang / 0.035) + 0.008 * exp(-ang / 0.25));
    }
    // rain
    float3 rainC = E.zen * 0.5 + E.hor * 0.6 + E.glow * 12.0 + (float3(0.03, 0.03, 0.04) + col * 0.6) * E.neonOn;
    col += rainC * rainV * mix(0.12, 0.45, E.neonOn);

    // exposure + grade
    // camera auto-exposure through the day/twilight/night (neon keeps the night bright)
    float expo = elev > 0.0 ? mix(1.6, 1.2, smoothstep(0.0, 10.0, elev))
                            : mix(mix(1.6, 3.2, smoothstep(0.0, -5.0, elev)), 2.3, smoothstep(-6.0, -13.0, elev));
    col *= expo;
    float2 uv = fragCoord / ctx.res;
    col *= ws_vignette(uv, 0.55);
    col = ws_acesFitted(col);
    col += ws_grain(fragCoord, fract(E.time * 0.37)) * 0.004;
    return max(col, 0.0);
}
