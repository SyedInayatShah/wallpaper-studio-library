// =====================================================================
//  Neon Horizon — cinematic synthwave (rev B, rewritten)
//
//  * Glossy black floor with flush neon tubes, analytically box-filtered,
//    with world-space light spill and screen-space (energy conserving) bloom.
//  * Floor reflections: sharp mirror lobe (true trace of every layer) +
//    GGX glossy lobe integrated with stratified taps (long sun streak).
//  * Near range: exact DDA-traced triangulated mesh (glossy dark facets,
//    glowing cyan wireframe on the mesh edges).
//  * Mid range: raymarched natural ridged terrain, back-lit by the sun.
//  * Far ranges: 1D hazy silhouettes; banded retro sun behind the haze.
//  * Height haze + low neon mist, lens glare, filmic grade.
// =====================================================================

constant float NH_CAMY  = 1.0;
constant float NH_PITCH = 0.075;
constant float NH_FOVY  = 40.0;

constant float NH_CELL  = 0.5;      // floor grid pitch
constant float NH_TUBE  = 0.0085;    // neon tube width (world)

constant float NH_SUNEL = 0.100;    // sun centre elevation (rad)
constant float NH_SUNR  = 0.113;    // sun angular radius (rad)

constant float NH_MS    = 1.25;      // mesh vertex spacing (near range A)
constant float NH_AZ0   = 26.0;
constant float NH_AZ1   = 85.0;
constant float NH_AHMAX = 14.0;

constant float NH_BZ0   = 95.0;     // mid range B
constant float NH_BZ1   = 280.0;
constant float NH_BHMAX = 60.0;

constant float3 NH_MAG  = float3(1.00, 0.07, 0.50);
constant float3 NH_CYAN = float3(0.05, 0.55, 1.00);

inline float3 nh_sunDir() { return float3(0.0, sin(NH_SUNEL), -cos(NH_SUNEL)); }

inline float nh_erf(float x) {
    float x2 = x * x;
    float r = sqrt(max(1.0 - exp(-x2 * (1.2732395 + 0.147 * x2) / (1.0 + 0.147 * x2)), 0.0));
    return x < 0.0 ? -r : r;
}

// ------------------------------------------------------------ filtered lines
inline float nh_pulseI(float x, float w) {
    float xs = x + 0.5 * w;
    return floor(xs) * w + min(fract(xs), w);
}
// coverage of pulses (width w, centred on integers) box-filtered over fw
inline float nh_line(float x, float w, float fw) {
    fw = max(fw, 1e-4);
    x -= floor(x);
    return (nh_pulseI(x + 0.5 * fw, w) - nh_pulseI(x - 0.5 * fw, w)) / fw;
}
inline float nh_haloI(float x, float r) {
    float fl = floor(x); float u = x - fl;
    float E = exp(-1.0 / r);
    float g = r * (1.0 - exp(-u / r) + exp(-(1.0 - u) / r) - E) / (1.0 - E);
    return fl * 2.0 * r + g;
}
// periodic exponential halo around integers, box filtered; one line integrates to 1
inline float nh_halo(float x, float r, float fw) {
    r = max(r, 1e-4);
    fw = max(fw, 1e-4);
    x -= floor(x);
    return (nh_haloI(x + 0.5 * fw, r) - nh_haloI(x - 0.5 * fw, r)) / (fw * 2.0 * r);
}

// ------------------------------------------------------------ sky
inline float3 nh_skyGrad(float3 rd, float el, float az) {
    float e = max(el, 0.0);
    float3 zen = float3(0.0030, 0.0032, 0.0170);
    float3 pur = float3(0.040, 0.0090, 0.095);
    float3 mag = float3(0.220, 0.030, 0.150);
    float sunAz = exp(-az * az / 0.30);
    float3 c = zen + pur * exp(-e / 0.28) + mag * (exp(-e / 0.075) * (0.40 + 0.60 * sunAz) + 0.35 * exp(-e / 0.16));
    float mu = dot(rd, nh_sunDir());
    float psi = acos(clamp(mu, -1.0, 1.0));
    c += float3(1.0, 0.16, 0.34) * (0.16 * exp(-psi / 0.05) + 0.06 * exp(-psi / 0.18));
    c += float3(1.0, 0.22, 0.20) * 0.10 * exp(-e / 0.018) * exp(-az * az / 0.05);
    float ag = fbm(float2(az * 1.3 + 5.0, e * 3.0 + 1.0), 3);
    c *= 1.0 + 0.10 * ag * smoothstep(0.02, 0.2, e);
    return c;
}

inline float3 nh_sunGrad(float v) {  // v: -1 bottom .. +1 top
    float3 c0 = float3(0.70, 0.015, 0.55);   // magenta
    float3 c1 = float3(1.00, 0.030, 0.26);   // hot pink
    float3 c2 = float3(1.00, 0.200, 0.05);   // orange
    float3 c3 = float3(1.00, 0.520, 0.03);   // gold
    float3 c = mix(c0, c1, smoothstep(-1.0, -0.45, v));
    c = mix(c, c2, smoothstep(-0.45, 0.35, v));
    c = mix(c, c3, smoothstep(0.35, 1.0, v));
    return c * mix(1.45, 2.35, smoothstep(-1.0, 1.0, v));
}

// banded sun disc; x,y angular offsets from centre; sx horizontal gaussian
// blur, sy vertical blur / footprint (rad)
inline float3 nh_sunDisc(float x, float y, float sx, float sy) {
    float R = NH_SUNR;
    sx = max(sx, 1e-5); sy = max(sy, 1e-5);
    if (abs(y) > R + 3.0 * sy || abs(x) > R + 4.0 * sx) return float3(0.0);
    float yc = clamp(y, -R, R);
    float w = sqrt(max(R * R - yc * yc, 0.0));
    float s = sx * 1.41421;
    float cx = 0.5 * (nh_erf((w - x) / s) + nh_erf((w + x) / s));
    float s2 = sy * 1.41421;
    float cy = 0.5 * (nh_erf((R - y) / s2) + nh_erf((R + y) / s2));
    float v = clamp(y / R, -1.0, 1.0);
    float sb = 0.28 - v;
    float band = 1.0;
    if (sb > -0.1) {
        const float P = 0.19;
        float f = clamp(0.07 + 0.40 * max(sb, 0.0), 0.0, 0.92);
        float g = nh_line(sb / P - 0.5, f, (sy / R) / P);
        float ph = fract(sb / P) - 0.5;                 // 0 at gap centre
        float dEdge = max(0.5 * f - abs(ph), 0.0) * P * R;  // rad to nearest band edge
        float glow = 0.05 + 0.30 * exp(-dEdge / 0.0012);
        band = 1.0 - g * (1.0 - glow) * smoothstep(-0.03, 0.03, sb);
    }
    return nh_sunGrad(v) * cx * cy * band;
}

inline float3 nh_hazeCol(float3 rd) {
    float az = atan2(rd.x, -rd.z);
    float3 h = normalize(float3(rd.x, 0.02, rd.z));
    float psi = acos(clamp(dot(h, nh_sunDir()), -1.0, 1.0));
    float3 c = float3(0.080, 0.022, 0.170);
    c += float3(0.200, 0.030, 0.120) * exp(-az * az / 0.10);
    c += float3(1.0, 0.18, 0.32) * (0.10 * exp(-psi / 0.06) + 0.04 * exp(-psi / 0.20));
    return c;
}

inline float nh_farC1(float az) {
    float r = ridged(float2(az * 5.0 + 2.3, 1.9), 5);
    return 0.003 + 0.034 * r * r * (0.25 + 0.75 * smoothstep(0.02, 0.5, abs(az)));
}
inline float nh_farC2(float az) {
    float r = ridged(float2(az * 2.6 + 7.7, 5.3), 5);
    return 0.006 + 0.05 * r * r * (0.35 + 0.65 * smoothstep(0.05, 0.6, abs(az)));
}

// full sky: gradient, stars, sun (prefiltered), far hazy ridges
inline float3 nh_sky(float3 rd, float sx, float sy, float starAmt) {
    float el = asin(clamp(rd.y, -1.0, 1.0));
    float az = atan2(rd.x, -rd.z);
    float3 base = nh_skyGrad(rd, el, az);
    float e = max(el, 0.0);
    float3 col = base;
    float3 T = exp(-(0.012 / (e + 0.012)) * float3(0.6, 1.4, 0.9));
    if (starAmt > 0.0) {
        float3 st = ws_stars(float2(az, el) + float2(3.1, 1.7), 60.0, 0.0, 0.0);
        col += st * 0.13 * starAmt * smoothstep(0.05, 0.35, e);
    }
    // faint horizontal striation of the low atmosphere across the sun
    float strat = gnoise(float2(el * 140.0, 3.3)) * 0.6 + gnoise(float2(el * 330.0 + az * 4.0, 7.9)) * 0.4;
    T *= 1.0 - 0.22 * smoothstep(0.09, 0.0, el) * (0.5 + 0.5 * strat);
    float3 sunL = nh_sunDisc(az * cos(el), el - NH_SUNEL, sx, sy) * T;
    // thin sunset stratus streaks (lit from behind/below by the sun)
    float cl = 0.0;
    if (el > 0.012 && el < 0.26) {
        float2 cq = float2(az * 1.9 + 0.3, el * 34.0);
        cq.y += 0.6 * gnoise(float2(az * 3.1, 1.7));
        float n = fbm(cq + float2(4.2, 0.0), 5);
        float n2 = gnoise(float2(az * 9.0, el * 120.0) + 2.0);
        float dens = smoothstep(0.05, 0.50, n + 0.12 * n2);
        float band = smoothstep(0.012, 0.05, el) * (1.0 - smoothstep(0.12, 0.26, el));
        float psiS = length(float2(az, el - NH_SUNEL));
        cl = dens * band * (0.25 + 0.75 * smoothstep(NH_SUNR * 0.9, NH_SUNR * 1.6, psiS));
    }
    if (cl > 0.0) {
        float mu = dot(rd, nh_sunDir());
        float psi = acos(clamp(mu, -1.0, 1.0));
        float3 lit = float3(1.0, 0.28, 0.30) * (0.35 * exp(-psi / 0.10) + 0.10 * exp(-psi / 0.35));
        float3 cc = base * 0.55 + lit;
        sunL *= 1.0 - 0.85 * cl;
        col = mix(col, cc, cl * 0.70);
    }
    col += sunL;
    float edge = max(sy, 2e-4);
    float3 hz = nh_hazeCol(rd);
    float c2 = nh_farC2(az);
    float m2 = 1.0 - smoothstep(c2 - edge, c2 + edge, el);
    float3 k2 = mix(hz * mix(1.20, 0.85, smoothstep(0.0, c2, el)), base, 0.35);
    col = mix(col, k2, m2);
    float c1 = nh_farC1(az);
    float m1 = 1.0 - smoothstep(c1 - edge, c1 + edge, el);
    float3 k1 = hz * mix(1.20, 0.66, smoothstep(0.0, max(c1, 0.004), el));
    col = mix(col, k1, m1);
    return col;
}


// ------------------------------------------------------------ terrain A (mesh)
inline float nh_envA(float2 xz) {
    float z = -xz.y;
    float az = xz.x / max(z, 1.0);
    float wob = gnoise(float2(xz.x * 0.09, 3.7)) * 6.0 + gnoise(float2(xz.x * 0.23, 8.1)) * 2.5;
    float side = smoothstep(0.10, 0.32, abs(az + 0.015) + gnoise(float2(z * 0.05, 1.3)) * 0.03);
    float zin = smoothstep(NH_AZ0 + 4.0 + wob, NH_AZ0 + 16.0 + wob, z) * (1.0 - smoothstep(NH_AZ1 - 22.0, NH_AZ1, z));
    return side * zin;
}
inline float nh_hA(float2 xz, int oct) {
    float e = nh_envA(xz);
    if (e <= 0.0) return -0.5;
    float r = ridged(xz * 0.040 + float2(1.7, 4.2), oct);
    float b = 0.60 + 0.40 * gnoise(xz * 0.012 + float2(7.3, 1.1));
    float z = -xz.y;
    float H = 0.13 * z * (0.25 * e + r * r) * b * 1.3;
    return min(e * H - (1.0 - e) * 0.5, NH_AHMAX - 0.01);
}
inline float nh_vA(int2 c) { return nh_hA(float2(c) * NH_MS, 4); }

struct NHHit { float t; float3 n; int kind; };

inline NHHit nh_traceA(float3 ro, float3 rd, float tmax) {
    NHHit H; H.t = tmax; H.n = float3(0.0, 1.0, 0.0); H.kind = 0;
    if (rd.z > -1e-4) return H;
    float t0 = max((-NH_AZ0 - ro.z) / rd.z, 0.0);
    float t1 = min((-NH_AZ1 - ro.z) / rd.z, tmax);
    if (rd.y > 0.0) t1 = min(t1, (NH_AHMAX - ro.y) / rd.y);
    if (t0 >= t1) return H;
    float2 o = ro.xz / NH_MS, d = rd.xz / NH_MS;
    float2 g0 = o + d * t0;
    int2 c = int2(floor(g0));
    int sx = d.x >= 0.0 ? 1 : -1;
    int sz = d.y >= 0.0 ? 1 : -1;
    float2 tDelta = float2(abs(d.x) > 1e-7 ? 1.0 / abs(d.x) : 1e30, 1.0 / max(abs(d.y), 1e-7));
    float nbx = sx > 0 ? float(c.x + 1) : float(c.x);
    float nbz = sz > 0 ? float(c.y + 1) : float(c.y);
    float2 tNext = float2(abs(d.x) > 1e-7 ? (nbx - o.x) / d.x : 1e30, (nbz - o.y) / d.y);
    float h00 = nh_vA(c), h10 = nh_vA(c + int2(1, 0));
    float h01 = nh_vA(c + int2(0, 1)), h11 = nh_vA(c + int2(1, 1));
    float tin = t0;
    for (int i = 0; i < 110; i++) {
        float tout = min(min(tNext.x, tNext.y), t1);
        float hmax = max(max(h00, h10), max(h01, h11));
        float ymin = ro.y + rd.y * (rd.y < 0.0 ? tout : tin);
        if (ymin < hmax) {
            float2 cf = float2(c);
            float2 ga = o + d * tin - cf, gb = o + d * tout - cf;
            float da = ga.x - ga.y, db = gb.x - gb.y;
            float tm = (da * db < 0.0) ? tin + (tout - tin) * da / (da - db) : tout;
            for (int s = 0; s < 2; s++) {
                float ta = s == 0 ? tin : tm;
                float tb = s == 0 ? tm : tout;
                if (tb <= ta + 1e-6) continue;
                float2 fa = o + d * ta - cf, fb = o + d * tb - cf;
                float2 fm = 0.5 * (fa + fb);
                bool up = fm.x >= fm.y;
                float ax  = up ? (h10 - h00) : (h11 - h01);
                float azz = up ? (h11 - h10) : (h01 - h00);
                float ha = h00 + ax * fa.x + azz * fa.y;
                float hb = h00 + ax * fb.x + azz * fb.y;
                float ea = ro.y + rd.y * ta - ha;
                float eb = ro.y + rd.y * tb - hb;
                if (ea >= 0.0 && eb < 0.0) {
                    H.t = ta + (tb - ta) * ea / (ea - eb);
                    H.n = normalize(float3(-ax / NH_MS, 1.0, -azz / NH_MS));
                    H.kind = 1;
                    return H;
                }
            }
        }
        if (tout >= t1) break;
        if (tNext.x < tNext.y) {
            c.x += sx; tNext.x += tDelta.x;
            if (sx > 0) { h00 = h10; h01 = h11; h10 = nh_vA(c + int2(1, 0)); h11 = nh_vA(c + int2(1, 1)); }
            else        { h10 = h00; h11 = h01; h00 = nh_vA(c); h01 = nh_vA(c + int2(0, 1)); }
        } else {
            c.y += sz; tNext.y += tDelta.y;
            if (sz > 0) { h00 = h01; h10 = h11; h01 = nh_vA(c + int2(0, 1)); h11 = nh_vA(c + int2(1, 1)); }
            else        { h01 = h00; h11 = h10; h00 = nh_vA(c); h10 = nh_vA(c + int2(1, 0)); }
        }
        tin = tout;
    }
    return H;
}

// ------------------------------------------------------------ terrain B (natural ridges)
inline float nh_envB(float2 xz) {
    float z = -xz.y;
    float az = xz.x / max(z, 1.0);
    float side = smoothstep(0.09, 0.45, abs(az - 0.02));
    float zin = smoothstep(NH_BZ0, NH_BZ0 + 30.0, z) * (1.0 - smoothstep(NH_BZ1 - 60.0, NH_BZ1, z));
    return side * zin;
}
inline float nh_hB(float2 xz, int oct) {
    float e = nh_envB(xz);
    if (e <= 0.001) return -1.0;
    float2 q = xz * 0.0105 + float2(4.1, 9.3);
    float big = clamp(0.55 + 0.55 * fbm(q * 0.75, 3), 0.0, 1.0);
    float2 w = q * 1.7 + 0.45 * float2(gnoise(q * 1.3 + 3.1), gnoise(q * 1.3 + 8.7));
    float r = ridged(w, oct);
    float h = (0.28 + 0.72 * big) * (0.22 + 0.78 * r * sqrt(r));
    return min(e * h * 48.0 - (1.0 - e), NH_BHMAX - 0.01);
}

inline NHHit nh_traceB(float3 ro, float3 rd, float tmax, int oct) {
    NHHit H; H.t = tmax; H.n = float3(0.0, 1.0, 0.0); H.kind = 0;
    if (rd.z > -1e-4) return H;
    float t0 = max((-NH_BZ0 - ro.z) / rd.z, 0.0);
    float t1 = min((-NH_BZ1 - ro.z) / rd.z, tmax);
    if (rd.y > 0.0) t1 = min(t1, (NH_BHMAX - ro.y) / rd.y);
    if (t0 >= t1) return H;
    float t = t0, tp = t0;
    for (int i = 0; i < 140; i++) {
        float3 p = ro + rd * t;
        float h = p.y - nh_hB(p.xz, oct);
        if (h < 0.0) {
            float a = tp, b = t;
            for (int k = 0; k < 7; k++) {
                float m = 0.5 * (a + b);
                float3 q = ro + rd * m;
                if (q.y - nh_hB(q.xz, oct) < 0.0) b = m; else a = m;
            }
            H.t = 0.5 * (a + b); H.kind = 2;
            return H;
        }
        tp = t;
        t += max(h * 0.4, 0.0015 * t);
        if (t > t1) break;
    }
    return H;
}
inline float3 nh_normalB(float2 xz, float t) {
    float e = max(0.01, 0.0035 * t);
    float hx = nh_hB(xz + float2(e, 0.0), 8) - nh_hB(xz - float2(e, 0.0), 8);
    float hz = nh_hB(xz + float2(0.0, e), 8) - nh_hB(xz - float2(0.0, e), 8);
    return normalize(float3(-hx, 2.0 * e, -hz));
}

// horizon (skyline) tangent-elevation of A+B seen from o along horizontal dir
inline float nh_skyline(float3 o, float2 dir) {
    float m = -1.0;
    for (int i = 0; i < 40; i++) {
        float d = 20.0 * pow(15.0, (float(i) + 0.5) / 40.0);
        float2 q = o.xz + dir * d;
        float h = max(nh_hA(q, 3), nh_hB(q, 4));
        m = max(m, (h - o.y) / d);
    }
    return m;
}

// ------------------------------------------------------------ shading
inline float3 nh_fog(float3 col, float3 ro, float3 rd, float t) {
    float fa = ws_fogAmount(t, ro, rd, 0.0036, 0.040);
    col = mix(col, nh_hazeCol(rd), fa);
    // low valley haze layer (height scale ~4): bases glow, peaks stay dark
    float fl = ws_fogAmount(t, ro, rd, 0.0050, 0.25);
    col = mix(col, nh_hazeCol(rd) * 1.2, fl);
    float fm = ws_fogAmount(t, ro, rd, 0.020, 1.6);
    col += NH_MAG * 0.10 * fm;
    return col;
}

inline float3 nh_shadeA(float3 rd, float3 p, float3 n, float2 fwc, float resY) {
    float3 L = nh_sunDir();
    float3 sunC = float3(1.0, 0.42, 0.30) * 2.2;
    float ndl = max(dot(n, L), 0.0);
    float3 alb = float3(0.018, 0.016, 0.024);
    float3 amb = float3(0.045, 0.014, 0.090) * (0.6 + 0.4 * n.y);
    float3 bnc = NH_MAG * 0.05 * (0.6 - 0.4 * n.y) * exp(-max(p.y, 0.0) * 0.35);
    float3 c = alb * (sunC * ndl + amb + bnc);
    // glossy dark facet
    float nv = clamp(dot(n, -rd), 0.0, 1.0);
    float F = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
    float3 r = reflect(rd, n);
    float3 sr = r.y > 0.0 ? nh_sky(r, 0.03, 0.03, 0.0) : NH_MAG * 0.04;
    c += F * sr;
    // wireframe on mesh edges
    float2 g = p.xz / NH_MS;
    const float WW = 0.022;
    float lx = nh_line(g.x, WW, fwc.x), lz = nh_line(g.y, WW, fwc.y);
    float cov = lx + lz - lx * lz;
    float hx = nh_halo(g.x, 0.06, fwc.x), hz = nh_halo(g.y, 0.06, fwc.y);
    float2 gc = floor(g + 0.5);
    float vx = 0.80 + 0.35 * hash12(float2(gc.x, floor(g.y)) + 3.7);
    float vz = 0.80 + 0.35 * hash12(float2(floor(g.x), gc.y) + 9.1);
    float3 wc = mix(NH_CYAN, float3(0.30, 0.35, 1.0), smoothstep(2.0, 9.0, p.y));
    // screen-space bloom (radius in px -> cell units via the footprint), energy conserving
    float2 ppx = fwc / 0.8;
    float r1 = 0.0035 * resY, r2 = 0.016 * resY;
    float b1 = nh_halo(g.x, r1 * ppx.x, fwc.x) * vx + nh_halo(g.y, r1 * ppx.y, fwc.y) * vz;
    float b2 = nh_halo(g.x, r2 * ppx.x, fwc.x) * vx + nh_halo(g.y, r2 * ppx.y, fwc.y) * vz;
    float3 wire = wc * (3.2 * (lx * vx + lz * vz - lx * lz * 0.5 * (vx + vz)) + 0.9 * WW * (hx * vx + hz * vz)
                        + 3.2 * WW * (0.16 * b1 + 0.07 * b2));
    return c * (1.0 - cov) + wire;
}

inline float3 nh_shadeB(float3 rd, float3 p, float3 n) {
    float3 L = nh_sunDir();
    float3 sunC = float3(1.0, 0.36, 0.34) * 7.0;
    float ndl = max(dot(n, L), 0.0);
    float3 alb = float3(0.050, 0.036, 0.052);
    float3 amb = float3(0.045, 0.014, 0.090) * (0.55 + 0.45 * n.y);
    float3 bnc = NH_MAG * 0.03 * (0.6 - 0.4 * n.y);
    float3 c = alb * (sunC * ndl + amb + bnc);
    float nv = clamp(dot(n, -rd), 0.0, 1.0);
    float F = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
    float3 r = reflect(rd, n);
    if (r.y > 0.0) c += 0.5 * F * nh_sky(r, 0.12, 0.12, 0.0);
    float rim = pow(1.0 - nv, 4.0) * smoothstep(-0.2, 0.4, n.y) * smoothstep(0.5, 0.0, abs(n.x));
    c += float3(1.0, 0.25, 0.40) * 0.06 * rim;
    return c;
}

// ------------------------------------------------------------ main
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 res = ctx.res;
    float3 ro = float3(0.0, NH_CAMY, 0.0);
    float3 fwd = float3(0.0, sin(NH_PITCH), -cos(NH_PITCH));
    float3 rgt = float3(1.0, 0.0, 0.0);
    float3 up = cross(rgt, fwd);
    float kf = tan(NH_FOVY * PI / 360.0);
    float2 pp = (2.0 * fragCoord - res) / res.y;
    float du = 2.0 / res.y;
    float3 rd  = normalize(fwd + (pp.x * rgt + pp.y * up) * kf);
    float3 rdx = normalize(fwd + ((pp.x + du) * rgt + pp.y * up) * kf);
    float3 rdy = normalize(fwd + (pp.x * rgt + (pp.y + du) * up) * kf);
    float pix = du * kf;
    float jit = hash12(fragCoord * 1.37 + 11.0);

    float tFloor = rd.y < 0.0 ? ro.y / -rd.y : 1e9;
    float tLim = min(tFloor, 3000.0);
    NHHit hit = nh_traceA(ro, rd, tLim);
    if (hit.kind == 0) hit = nh_traceB(ro, rd, tLim, 6);

    float3 col;
    if (hit.kind == 1) {
        float3 p = ro + rd * hit.t;
        float3 n = hit.n;
        float3 px = ro + rdx * (dot(p - ro, n) / dot(rdx, n));
        float3 py = ro + rdy * (dot(p - ro, n) / dot(rdy, n));
        float2 fw = (abs(px.xz - p.xz) + abs(py.xz - p.xz)) / NH_MS;
        col = nh_shadeA(rd, p, n, fw * 0.8, res.y);
        col = nh_fog(col, ro, rd, hit.t);
    } else if (hit.kind == 2) {
        float3 p = ro + rd * hit.t;
        float3 n = nh_normalB(p.xz, hit.t);
        col = nh_shadeB(rd, p, n);
        col = nh_fog(col, ro, rd, hit.t);
    } else if (rd.y < 0.0) {
        // ---------------- glossy floor
        float t = tFloor;
        float3 p = ro + rd * t;
        float3 px = ro + rdx * (ro.y / max(-rdx.y, 1e-6));
        float3 py = ro + rdy * (ro.y / max(-rdy.y, 1e-6));
        float2 dx = (px.xz - p.xz) / NH_CELL, dy = (py.xz - p.xz) / NH_CELL;
        // thin-lens depth of field (focus on the ranges): widen the line filter by the CoC
        float cocPx = 0.007 * abs(1.0 / t - 1.0 / 60.0) / pix;
        float2 fw0 = abs(dx) + abs(dy);
        float2 fw = fw0 * (0.8 + cocPx);
        float2 fwS = fw0 * (0.8 + 0.35 * cocPx);        // peaked (disc-like) defocus profile
        float2 g = p.xz / NH_CELL;
        const float LW = NH_TUBE / NH_CELL;
        float cx = 0.5 * (nh_line(g.x, LW, fw.x) + nh_line(g.x, LW, fwS.x));
        float cz = 0.5 * (nh_line(g.y, LW, fw.y) + nh_line(g.y, LW, fwS.y));
        float kx = 0.5 * (nh_line(g.x, LW * 0.4, fw.x) + nh_line(g.x, LW * 0.4, fwS.x));
        float kz = 0.5 * (nh_line(g.y, LW * 0.4, fw.y) + nh_line(g.y, LW * 0.4, fwS.y));
        // per-tube brightness variation (manufacturing spread), faded where lines merge
        float vgx = mix(1.0, 0.90 + 0.18 * hash11(floor(g.x + 0.5) + 0.31), smoothstep(0.6, 0.15, fw.x));
        float vgz = mix(1.0, 0.90 + 0.18 * hash11(floor(g.y + 0.5) + 7.17), smoothstep(0.6, 0.15, fw.y));
        cx *= vgx; kx *= vgx; cz *= vgz; kz *= vgz;
        float cov = cx + cz - cx * cz;
        float core = kx + kz - kx * kz;
        float sx = nh_halo(g.x, 0.05, fw.x), sz = nh_halo(g.y, 0.05, fw.y);
        float gxp = length(float2(dx.x, dy.x)), gzp = length(float2(dx.y, dy.y));
        float rb1 = 0.004 * res.y, rb2 = 0.020 * res.y;
        float bx1 = nh_halo(g.x, rb1 * gxp, fw.x), bz1 = nh_halo(g.y, rb1 * gzp, fw.y);
        float bx2 = nh_halo(g.x, rb2 * gxp, fw.x), bz2 = nh_halo(g.y, rb2 * gzp, fw.y);
        float gfade = 0.35 + 0.65 * exp(-t / 45.0);
        cov *= gfade; core *= gfade; sx *= gfade; sz *= gfade;
        bx1 *= gfade; bz1 *= gfade; bx2 *= gfade; bz2 *= gfade;
        float3 tube = NH_MAG * 4.0 * cov + float3(1.0, 0.55, 0.85) * 3.0 * core;
        float3 spill = NH_MAG * 4.0 * LW * 0.6 * (sx + sz);
        float3 bloom = NH_MAG * 4.0 * LW * (0.18 * (bx1 + bz1) + 0.08 * (bx2 + bz2));

        // surface normal: gentle undulation + per-panel tilt
        float2 tid = floor(g);
        float2 th = hash22(tid + 0.37) - 0.5;
        float2 q = p.xz * float2(0.22, 0.16);
        float ea = 0.05;
        float n0 = fbm(q, 3);
        float2 grad = float2(fbm(q + float2(ea, 0.0), 3) - n0, fbm(q + float2(0.0, ea), 3) - n0) / ea;
        float fwm = max(fw.x, fw.y);
        float detail = 1.0 - smoothstep(0.2, 0.8, fwm);
        float3 n = normalize(float3(grad.x * 0.0012 + th.x * 0.0006 * detail, 1.0, grad.y * 0.0012 + th.y * 0.0006 * detail));
        float smudge = smoothstep(0.25, 0.75, 0.5 + 0.9 * fbm(p.xz * float2(0.30, 0.18) + 5.0, 5));
        float aS = mix(0.014, 0.040, smudge);
        float wS = mix(0.85, 0.65, smudge);

        float3 r = reflect(rd, n);
        r.y = max(r.y, 1e-4); r = normalize(r);
        float e = max(-rd.y, 1e-3);
        float elr = asin(r.y);
        float azr = atan2(r.x, -r.z);

        // main glossy lobe: stratified GGX-marginal taps (vertical), each fully traced
        const int KM = 3;
        float3 sharp = float3(0.0);
        float jm = fract(jit * 7.31 + 0.13);
        for (int k = 0; k < KM; k++) {
            float u = (float(k) + jm) / float(KM);
            float xx = clamp(2.0 * u - 1.0, -0.985, 0.985);
            float sl = xx / sqrt(1.0 - xx * xx);
            float elk = abs(elr + 2.0 * atan(aS * sl));
            elk = clamp(elk, 1e-4, 1.3);
            float spc = min(4.0 * aS / pow(1.0 - xx * xx, 1.5) / float(KM), 0.3);
            float3 rk = float3(sin(azr) * cos(elk), sin(elk), -cos(azr) * cos(elk));
            NHHit rh = nh_traceA(p, rk, 1500.0);
            if (rh.kind == 0) rh = nh_traceB(p, rk, 1500.0, 5);
            float3 ck;
            if (rh.kind == 1) {
                float3 qp = p + rk * rh.t;
                float fwr = (pix * (t + rh.t) + spc * rh.t) / NH_MS;
                ck = nh_shadeA(rk, qp, rh.n, float2(fwr), res.y);
                ck = nh_fog(ck, p, rk, rh.t);
            } else if (rh.kind == 2) {
                float3 qp = p + rk * rh.t;
                ck = nh_shadeB(rk, qp, nh_normalB(qp.xz, rh.t * 3.0));
                ck = nh_fog(ck, p, rk, rh.t);
            } else {
                ck = nh_sky(rk, 2.0 * aS * e + pix, spc + pix, 0.3);
            }
            sharp += ck;
        }
        sharp /= float(KM);

        // glossy lobe: stratified GGX-marginal taps
        float skyl = atan(nh_skyline(p, normalize(r.xz)));
        const int K = 8;
        const float aG = 0.15;
        float3 mAvg = float3(0.008, 0.005, 0.016) + NH_CYAN * 0.04 * smoothstep(0.1, 0.3, abs(azr));
        float3 gl = float3(0.0);
        for (int k = 0; k < K; k++) {
            float u = (float(k) + jit) / float(K);
            float xx = clamp(2.0 * u - 1.0, -0.995, 0.995);
            float sl = xx / sqrt(1.0 - xx * xx);
            float elk = elr + 2.0 * atan(aG * sl);
            float spc = 2.0 * aG * 2.0 / pow(1.0 - xx * xx, 1.5) / float(K);
            spc = min(spc, 0.3);
            if (elk < 0.0) continue;
            elk = min(elk, 1.3);
            if (elk < skyl) { gl += mAvg; continue; }
            float3 dk = float3(sin(azr) * cos(elk), sin(elk), -cos(azr) * cos(elk));
            gl += nh_sky(dk, 2.0 * aG * e + pix, spc + pix, 0.0);
        }
        gl /= float(K);
        float3 refl = mix(gl, sharp, wS);
        // subtle real-floor mottling (polish swirls / dust) visible in bright reflections
        float mott = fbm(p.xz * float2(1.1, 0.8) + 17.0, 4);
        refl *= 0.90 + 0.20 * (0.5 + 0.5 * mott) * detail + 0.10 * (1.0 - detail);

        float cth = clamp(dot(-rd, n), 0.0, 1.0);
        float F = 0.04 + 0.96 * pow(1.0 - cth, 5.0);
        float3 base = float3(0.002, 0.0015, 0.003) + spill * (1.0 - F);
        col = (base + F * refl) * (1.0 - cov) + tube + bloom;
        col = nh_fog(col, ro, rd, t);
    } else {
        col = nh_sky(rd, pix * 0.7, pix * 0.7, 1.0);
        float fm = ws_fogAmount(3000.0, ro, rd, 0.020, 1.6);
        col += NH_MAG * 0.10 * fm;
    }

    // ---------------- lens glare from the sun
    {
        float psi = acos(clamp(dot(rd, nh_sunDir()), -1.0, 1.0));
        float ds = max(psi - NH_SUNR, 0.0);
        col += float3(1.0, 0.25, 0.35) * (0.16 * exp(-ds / 0.008) + 0.07 * exp(-ds / 0.040) + 0.03 * exp(-ds / 0.16));
        float3 ms = float3(0.0, -sin(NH_SUNEL), -cos(NH_SUNEL));
        float psm = acos(clamp(dot(rd, ms), -1.0, 1.0));
        float dm = max(psm - NH_SUNR, 0.0);
        col += float3(1.0, 0.30, 0.25) * 0.35 * (0.10 * exp(-dm / 0.010) + 0.06 * exp(-dm / 0.045));
    }

    float3 c = ws_acesFitted(col * 1.0);
    c = mix(c, c * c * (3.0 - 2.0 * c), 0.12);          // gentle filmic S-curve
    float2 uv = fragCoord / res;
    c *= ws_vignette(uv, 0.30);
    c += ws_grain(fragCoord, 0.0) * 0.004 * sqrt(max(ws_luma(c), 0.0) + 0.02);
    return max(c, 0.0);
}
