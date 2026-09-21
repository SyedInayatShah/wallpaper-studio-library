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
constant float NH_YAW   = 0.125;    // camera heading offset -> sun sits off-centre
constant float NH_CA    = 0.0016;   // lateral chromatic aberration (vintage glass)

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
constant float3 NH_CYN2 = float3(0.10, 0.78, 1.00);   // floor accent tubes

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
    fw = clamp(fw, 1e-4, 1e4);
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
    r = clamp(r, 1e-4, 24.0);           // beyond ~24 periods the halo is uniform anyway
    fw = clamp(fw, 1e-4, 1e4);
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
    // faint high-altitude nebulosity so the upper sky is never a dead gradient
    float ng = fbm(float2(az * 0.62 + 12.0, e * 1.25 + 4.0), 4);
    c *= 1.0 + 0.22 * (ng - 0.5) * smoothstep(0.08, 0.34, e);
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
    // bands: slightly uneven pitch + a shallow heat wobble, so they are not a ruled grating
    float sbw = 0.28 - v
              + 0.0085 * gnoise(float2(v * 3.1 + 11.0, 2.4))
              + 0.0040 * gnoise(float2(x / R * 4.1 + 3.0, v * 2.3 + 7.5));
    float band = 1.0;
    if (sbw > -0.1) {
        const float P = 0.19;
        float f = clamp(0.07 + 0.40 * max(sbw, 0.0), 0.0, 0.92);
        float fwb = max((sy / R) / P, 0.055);          // lens diffusion floor: no razor edges
        float g = nh_line(sbw / P - 0.5, f, fwb);
        float ph = fract(sbw / P) - 0.5;                // 0 at gap centre
        float dEdge = max(0.5 * f - abs(ph), 0.0) * P * R;  // rad to nearest band edge
        float glow = 0.05 + 0.30 * exp(-dEdge / 0.0016);
        band = 1.0 - g * (1.0 - glow) * smoothstep(-0.03, 0.03, sbw);
    }
    float rr = clamp((x * x + y * y) / (R * R), 0.0, 1.0);
    float limb = 0.63 + 0.37 * pow(max(1.0 - rr, 0.0), 0.33);
    // faint photospheric mottling so the disc is not a mathematically clean gradient
    float gran = fbm(float2(x, y) / R * 3.4 + 21.0, 4) - 0.5;
    float granA = 1.0 - smoothstep(0.02, 0.09, sy / R);
    return nh_sunGrad(v) * cx * cy * band * limb * (1.0 + 0.085 * gran * granA);
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
    float sd = smoothstep(0.30, -0.30, az);
    float r = ridged(float2(az * mix(5.0, 3.4, sd) + mix(2.3, 18.9, sd), mix(1.9, 6.4, sd)), 5);
    float amp = mix(0.030, 0.042, sd);
    return 0.003 + amp * r * r * (0.25 + 0.75 * smoothstep(mix(0.02, 0.07, sd), mix(0.42, 0.62, sd), abs(az)));
}
inline float nh_farC2(float az) {
    float sd = smoothstep(0.34, -0.34, az);
    float r = ridged(float2(az * mix(2.6, 3.7, sd) + mix(7.7, 23.1, sd), mix(5.3, 12.7, sd)), 5);
    float amp = mix(0.044, 0.062, sd);
    return 0.006 + amp * r * r * (0.35 + 0.65 * smoothstep(mix(0.05, 0.02, sd), mix(0.66, 0.50, sd), abs(az)));
}

// magnitude-distributed stars: size / brightness / colour-temperature spread,
// faint diffraction spikes on the brightest few. p in radians, fw = pixel footprint (rad).
inline float3 nh_starLayer(float2 p, float cells, float fw, float gain, float occ, float spikes) {
    float2 q = p * cells;
    float2 ic = floor(q);
    float3 acc = float3(0.0);
    float sgP = max(fw * cells * 0.70, 0.052);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 c = ic + float2(i, j);
            float4 h = hash24(c + 7.31);
            if (h.z > occ) continue;
            float2 sp = c + 0.12 + 0.76 * h.xy;
            float m = pow(h.w, 3.4);                    // power-law magnitudes
            float sgI = sgP * (1.0 + 1.7 * m);
            float2 d = q - sp;
            float k = (sgP * sgP) / (sgI * sgI);
            float3 ct = ws_blackbody(mix(3000.0, 12000.0, fract(h.z * 41.3)));
            ct /= max(ws_luma(ct), 1e-3);
            float amp = gain * (0.05 + m);
            acc += ct * amp * k * exp(-dot(d, d) / (2.0 * sgI * sgI));
            if (spikes > 0.0 && m > 0.30) {
                float sw = sgI * 0.55;
                float sl = sgI * (1.6 + 4.0 * m);
                float a = exp(-abs(d.x) / sl) * exp(-(d.y * d.y) / (2.0 * sw * sw));
                float b = exp(-abs(d.y) / sl) * exp(-(d.x * d.x) / (2.0 * sw * sw));
                acc += ct * amp * spikes * (a + b);
            }
        }
    }
    return acc;
}

// full sky: gradient, stars, sun (prefiltered), far hazy ridges
inline float3 nh_sky(float3 rd, float sx, float sy, float starAmt, float2 ca = float2(0.0)) {
    float el = asin(clamp(rd.y, -1.0, 1.0));
    float az = atan2(rd.x, -rd.z);
    float3 base = nh_skyGrad(rd, el, az);
    float e = max(el, 0.0);
    float3 col = base;
    float3 T = exp(-(0.012 / (e + 0.012)) * float3(0.6, 1.4, 0.9));
    if (starAmt > 0.0) {
        float2 sp = float2(az * cos(el), el) + float2(3.1, 1.7);
        float fwp = max(sx, sy);
        float3 st = nh_starLayer(sp, 155.0, fwp, 0.42, 0.34, 0.0)
                  + nh_starLayer(sp + 4.7, 41.0, fwp, 1.05, 0.13, 0.055);
        col += st * 0.30 * starAmt * smoothstep(0.03, 0.30, e);
    }
    // faint horizontal striation of the low atmosphere across the sun
    float strat = gnoise(float2(el * 140.0, 3.3)) * 0.6 + gnoise(float2(el * 330.0 + az * 4.0, 7.9)) * 0.4;
    T *= 1.0 - 0.22 * smoothstep(0.09, 0.0, el) * (0.5 + 0.5 * strat);
    // low-atmosphere refraction: lower limb gets laterally stepped/shimmered and slightly lifted
    float rw = smoothstep(0.065, 0.0, el);
    float sxo = rw * (0.0022 * gnoise(float2(el * 260.0, 1.3)) + 0.0010 * gnoise(float2(el * 700.0, 4.1)));
    float syo = rw * 0.0015 * gnoise(float2(el * 180.0, 8.8));
    float sX = az * cos(el) + sxo * sign(az);
    float sY = el - NH_SUNEL + syo;
    float3 sunL;
    if (ca.x != 0.0 || ca.y != 0.0) {          // lateral chromatic aberration on the hot edge
        float3 dR = nh_sunDisc(sX + ca.x, sY + ca.y, sx, sy);
        float3 dG = nh_sunDisc(sX, sY, sx, sy);
        float3 dB = nh_sunDisc(sX - ca.x, sY - ca.y, sx, sy);
        sunL = float3(dR.r, dG.g, dB.b) * T;
    } else {
        sunL = nh_sunDisc(sX, sY, sx, sy) * T;
    }
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
    float3 k2 = mix(hz * mix(1.20, 0.85, smoothstep(0.0, c2, el) * smoothstep(0.008, 0.03, c2)), base, 0.35);
    col = mix(col, k2, m2);
    // crest rim: backlit ridge line of the far range 2
    float rim2 = exp(-max(c2 - el, 0.0) / 0.0060) * m2;
    col += float3(1.0, 0.36, 0.52) * 0.040 * rim2 * (0.35 + 0.65 * exp(-az * az / 1.1));
    float c1 = nh_farC1(az);
    float m1 = 1.0 - smoothstep(c1 - edge, c1 + edge, el);
    float3 k1 = hz * mix(1.20, 0.66, smoothstep(0.0, max(c1, 0.004), el) * smoothstep(0.006, 0.022, c1));
    col = mix(col, k1, m1);
    float rim1 = exp(-max(c1 - el, 0.0) / 0.0048) * m1;
    col += float3(1.0, 0.34, 0.50) * 0.050 * rim1 * (0.35 + 0.65 * exp(-az * az / 1.1));
    return col;
}


// ------------------------------------------------------------ terrain A (mesh)
inline float nh_envA(float2 xz) {
    float z = -xz.y;
    float az = xz.x / max(z, 1.0);
    float wob = gnoise(float2(xz.x * 0.09, 3.7)) * 6.0 + gnoise(float2(xz.x * 0.23, 8.1)) * 2.5;
    float a = az + 0.015;
    float sd = smoothstep(0.05, -0.05, a);        // left bank is closer & steeper
    float e0 = mix(0.115, 0.082, sd), e1 = mix(0.355, 0.270, sd);
    float side = smoothstep(e0, e1, abs(a) + gnoise(float2(z * 0.05, 1.3)) * 0.03);
    float zin = smoothstep(NH_AZ0 + 4.0 + wob, NH_AZ0 + 16.0 + wob, z) * (1.0 - smoothstep(NH_AZ1 - 22.0, NH_AZ1, z));
    return side * zin * mix(0.90, 1.0, sd);
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
    float a = az - 0.02;
    float sd = smoothstep(0.05, -0.05, a);
    float side = smoothstep(mix(0.115, 0.075, sd), mix(0.50, 0.38, sd), abs(a));
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
    float sd = mix(0.88, 1.12, smoothstep(12.0, -12.0, xz.x));   // left range rides higher
    return min(e * h * 48.0 * sd - (1.0 - e), NH_BHMAX - 0.01);
}

inline NHHit nh_traceB(float3 ro, float3 rd, float tmax, int oct) {
    NHHit H; H.t = tmax; H.n = float3(0.0, 1.0, 0.0); H.kind = 0;
    if (rd.z > -1e-4) return H;
    float t0 = max((-NH_BZ0 - ro.z) / rd.z, 0.0);
    float t1 = min((-NH_BZ1 - ro.z) / rd.z, tmax);
    if (rd.y > 0.0) t1 = min(t1, (NH_BHMAX - ro.y) / rd.y);
    if (t0 >= t1) return H;
    float t = t0, tp = t0;
    for (int i = 0; i < 230; i++) {
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
        t += max(h * 0.17, 0.0011 * t);
        if (t > t1) break;
    }
    return H;
}
inline float3 nh_normalB(float2 xz, float e, int oct) {
    e = max(e, 0.02);
    float hx = nh_hB(xz + float2(e, 0.0), oct) - nh_hB(xz - float2(e, 0.0), oct);
    float hz = nh_hB(xz + float2(0.0, e), oct) - nh_hB(xz - float2(0.0, e), oct);
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

// coverage of the two floor tube families at grid coords g
inline float2 nh_floorCov(float2 g, float2 lw, float2 fw, float2 fwS) {
    return float2(0.5 * (nh_line(g.x, lw.x, fw.x) + nh_line(g.x, lw.x, fwS.x)),
                  0.5 * (nh_line(g.y, lw.y, fw.y) + nh_line(g.y, lw.y, fwS.y)));
}

// ------------------------------------------------------------ shading
inline float3 nh_fog(float3 col, float3 ro, float3 rd, float t) {
    float fa = ws_fogAmount(t, ro, rd, 0.0052, 0.038);
    float3 hz = nh_hazeCol(rd);
    // distant layers also lose contrast and go cooler/violet, not just fade
    float dsat = smoothstep(60.0, 260.0, t);
    col = mix(col, hz * mix(1.0, 0.86, dsat) + float3(0.012, 0.004, 0.030) * dsat, fa);
    // low valley haze layer (height scale ~4): bases glow, peaks stay dark
    float fl = ws_fogAmount(t, ro, rd, 0.0050, 0.25);
    col = mix(col, nh_hazeCol(rd) * 1.2, fl);
    float fm = ws_fogAmount(t, ro, rd, 0.020, 1.6);
    col += NH_MAG * 0.10 * fm;
    return col;
}

inline float3 nh_shadeA(float3 rd, float3 p, float3 n, float2 fwc, float2 gca, float resY) {
    float3 L = nh_sunDir();
    float3 sunC = float3(1.0, 0.42, 0.30) * 2.2;
    float3 nf = n;
    // meso-scale rock bump on the facets (faded out once a facet is a few pixels wide)
    float bs = 1.0 - smoothstep(0.10, 0.50, max(fwc.x, fwc.y));
    float b0 = fbm(p.xz * 0.85 + 3.3, 4);
    if (bs > 0.01) {
        const float be = 0.30;
        float2 bg = float2(fbm((p.xz + float2(be, 0.0)) * 0.85 + 3.3, 4) - b0,
                           fbm((p.xz + float2(0.0, be)) * 0.85 + 3.3, 4) - b0) / be;
        nf = normalize(n + float3(-bg.x, 0.0, -bg.y) * 0.75 * bs);
    }
    float ndl = max(dot(nf, L), 0.0);
    // ambient occlusion: crevices sit below the smooth macro shape and lose the sky
    float hsm = nh_hA(p.xz, 2);
    float ao = clamp(0.22 + 0.78 * smoothstep(-2.0, 1.6, p.y - hsm), 0.0, 1.0);
    ao *= 0.50 + 0.50 * clamp(0.5 + 0.5 * nf.y, 0.0, 1.0);
    float3 alb = float3(0.027, 0.023, 0.036) * (0.72 + 0.56 * b0);
    float3 amb = float3(0.045, 0.014, 0.090) * (0.6 + 0.4 * nf.y) * ao;
    float3 bnc = NH_MAG * 0.055 * (0.6 - 0.4 * nf.y) * exp(-max(p.y, 0.0) * 0.35) * ao;
    float3 c = alb * (sunC * ndl + amb + bnc);
    // glossy dark facet, roughness-broadened and modulated by the rock micro-surface
    float nv = clamp(dot(nf, -rd), 0.0, 1.0);
    float F = (0.04 + 0.96 * pow(1.0 - nv, 5.0)) * (0.45 + 0.55 * b0) * (0.35 + 0.65 * ao);
    float3 r = reflect(rd, nf);
    float rg = 0.13 + 0.10 * b0;
    float3 sr = r.y > 0.0 ? nh_sky(r, rg, rg, 0.0) : NH_MAG * 0.12 * smoothstep(-0.6, 0.0, r.y);
    c += F * sr;
    // wireframe on mesh edges
    float2 g = p.xz / NH_MS;
    fwc = max(fwc, 0.0075);                 // lens diffusion: never a razor-sharp stroke
    float2 gx = g + gca, gz = g - gca;      // lateral CA across the tube
    const float WW = 0.024;
    float2 gcv = floor(g + 0.5);
    float res1 = smoothstep(0.55, 0.12, fwc.x), res2 = smoothstep(0.55, 0.12, fwc.y);
    // per-tube manufacturing spread: width as well as brightness
    float wwx = WW * mix(1.0, 0.68 + 0.66 * hash11(gcv.x * 1.7 + 0.13), res1);
    float wwz = WW * mix(1.0, 0.68 + 0.66 * hash11(gcv.y * 1.7 + 5.31), res2);
    float lx = nh_line(g.x, wwx, fwc.x), lz = nh_line(g.y, wwz, fwc.y);
    float lxR = nh_line(gx.x, wwx, fwc.x), lzR = nh_line(gz.y, wwz, fwc.y);
    float lxB = nh_line(gz.x, wwx, fwc.x), lzB = nh_line(gx.y, wwz, fwc.y);
    float cov = lx + lz - lx * lz;
    float hx = nh_halo(g.x, 0.095, fwc.x), hz = nh_halo(g.y, 0.095, fwc.y);
    float2 gc = gcv;
    // uneven gas fill / ageing along each tube
    float vx = (0.72 + 0.44 * hash12(float2(gc.x, floor(g.y)) + 3.7)) * (0.80 + 0.32 * fbm(float2(gc.x * 3.1, p.z * 0.22), 3));
    float vz = (0.72 + 0.44 * hash12(float2(floor(g.x), gc.y) + 9.1)) * (0.80 + 0.32 * fbm(float2(gc.y * 3.1, p.x * 0.22), 3));
    float3 wc = mix(NH_CYAN, float3(0.30, 0.35, 1.0), smoothstep(2.0, 9.0, p.y));
    wc *= 0.86 + 0.28 * hash11(gc.x * 2.3 + gc.y * 0.7);
    // screen-space bloom (radius in px -> cell units via the footprint), energy conserving
    float2 ppx = fwc / 0.8;
    float r1 = 0.0035 * resY, r2 = 0.016 * resY;
    float b1 = nh_halo(g.x, r1 * ppx.x, fwc.x) * vx + nh_halo(g.y, r1 * ppx.y, fwc.y) * vz;
    float b2 = nh_halo(g.x, r2 * ppx.x, fwc.x) * vx + nh_halo(g.y, r2 * ppx.y, fwc.y) * vz;
    float3 wireM = wc * (3.1 * (lx * vx + lz * vz - lx * lz * 0.5 * (vx + vz)) + 1.25 * WW * (hx * vx + hz * vz)
                        + 3.2 * WW * (0.34 * b1 + 0.19 * b2));
    float3 wire = wireM;
    if (gca.x != 0.0 || gca.y != 0.0) {
        wire.r = wc.r * 3.1 * (lxR * vx + lzB * vz - lxR * lzB * 0.5 * (vx + vz)) + (wireM.r - wc.r * 3.1 * (lx * vx + lz * vz - lx * lz * 0.5 * (vx + vz)));
        wire.b = wc.b * 3.1 * (lxB * vx + lzR * vz - lxB * lzR * 0.5 * (vx + vz)) + (wireM.b - wc.b * 3.1 * (lx * vx + lz * vz - lx * lz * 0.5 * (vx + vz)));
    }
    return c * (1.0 - cov) + wire;
}

// n  : footprint-matched surface normal (diffuse)
// ns : heavily smoothed macro normal -- every grazing / rim term is driven by this
//      one only, so no sub-pixel geometry can turn into a hard bright sliver.
inline float3 nh_shadeB(float3 rd, float3 p, float3 n, float3 ns) {
    float3 L = nh_sunDir();
    float3 sunC = float3(1.0, 0.37, 0.34) * 4.0;
    float ndl = max(dot(n, L), 0.0);
    float ao = 0.30 + 0.70 * clamp(ns.y, 0.0, 1.0);
    float3 alb = float3(0.052, 0.038, 0.056);
    float3 amb = float3(0.045, 0.014, 0.090) * (0.55 + 0.45 * n.y) * ao;
    float3 bnc = NH_MAG * 0.03 * (0.6 - 0.4 * n.y);
    float3 c = alb * (sunC * ndl * (0.35 + 0.65 * ao) + amb + bnc);
    c *= 0.72 + 0.56 * fbm(p.xz * 0.022 + 13.0, 3);      // large-scale albedo / shadow banding
    float nvs = clamp(dot(ns, -rd), 0.0, 1.0);
    float F = 0.04 + 0.96 * pow(1.0 - nvs, 5.0);
    float3 r = reflect(rd, ns);
    if (r.y > 0.0) c += 0.45 * F * nh_sky(r, 0.15, 0.15, 0.0);
    float sunW = 0.35 + 0.65 * smoothstep(-0.20, 0.60, dot(normalize(float3(p.x, 1e-4, p.z)), -L));
    // backlit crest scatter (broad, smooth): the ridge separates from the sky
    float rim = pow(1.0 - nvs, 2.4) * smoothstep(-0.30, 0.55, ns.y);
    c += float3(1.0, 0.29, 0.44) * 0.145 * rim * (0.40 + 0.60 * sunW);
    c += float3(1.0, 0.46, 0.42) * 0.075 * pow(1.0 - nvs, 5.0) * smoothstep(0.0, 0.5, ns.y) * sunW;
    return c;
}

// ------------------------------------------------------------ main
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 res = ctx.res;
    float3 ro = float3(0.0, NH_CAMY, 0.0);
    float cy = cos(NH_YAW), sy2 = sin(NH_YAW);
    float3 fwd = normalize(float3(sy2 * cos(NH_PITCH), sin(NH_PITCH), -cy * cos(NH_PITCH)));
    float3 rgt = float3(cy, 0.0, sy2);
    float3 up = normalize(cross(rgt, fwd));
    float kf = tan(NH_FOVY * PI / 360.0);
    float2 pp = (2.0 * fragCoord - res) / res.y;
    float du = 2.0 / res.y;
    float3 rd  = normalize(fwd + (pp.x * rgt + pp.y * up) * kf);
    float3 rdx = normalize(fwd + ((pp.x + du) * rgt + pp.y * up) * kf);
    float3 rdy = normalize(fwd + (pp.x * rgt + (pp.y + du) * up) * kf);
    float pix = du * kf;
    float jit = hash12(fragCoord * 1.37 + 11.0);

    // lateral chromatic aberration (radial, ~1.5 px at the corners)
    float2 cc = pp * 0.5;
    float2 caPx = cc * (NH_CA * length(cc)) * res.y * 0.5;
    float2 caAng = caPx * pix;

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
        float2 ddx = (px.xz - p.xz) / NH_MS, ddy = (py.xz - p.xz) / NH_MS;
        float2 fw = (abs(ddx) + abs(ddy)) * 0.8;
        float2 gca = (ddx * caPx.x + ddy * caPx.y);
        col = nh_shadeA(rd, p, n, fw, gca, res.y);
        col = nh_fog(col, ro, rd, hit.t);
    } else if (hit.kind == 2) {
        float3 p = ro + rd * hit.t;
        float3 n  = nh_normalB(p.xz, max(0.45, 2.2 * pix * hit.t), 6);
        float3 ns = nh_normalB(p.xz, max(3.0, 0.022 * hit.t), 3);
        col = nh_shadeB(rd, p, n, ns);
        col = nh_fog(col, ro, rd, hit.t);
    } else if (rd.y < 0.0 && tFloor > 3500.0) {
        col = nh_fog(float3(0.0), ro, rd, 3500.0);
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
        float2 fw = fw0 * (1.05 + cocPx);               // 1.05px box == slight lens diffusion
        float2 fwS = fw0 * (0.85 + 0.35 * cocPx);       // peaked (disc-like) defocus profile
        float2 gca = dx * caPx.x + dy * caPx.y;
        // the tubes were laid by hand: very slight lateral wander, not a ruled grating
        float2 g = p.xz / NH_CELL
                 + float2(0.030 * gnoise(float2(p.y + p.z * 0.055 + 2.0, 1.3)) + 0.018 * gnoise(float2(p.z * 0.19 + 6.1, 5.0)),
                          0.030 * gnoise(float2(p.x * 0.049 + 8.0, 4.1)) + 0.018 * gnoise(float2(p.x * 0.17 + 2.7, 9.3)));
        float2 rsv = float2(smoothstep(0.55, 0.10, fw.x), smoothstep(0.55, 0.10, fw.y));
        float2 idx = floor(g + 0.5);
        const float LW = NH_TUBE / NH_CELL;
        // per-tube spread: width and brightness both vary a little
        float2 lw = LW * float2(mix(1.0, 0.78 + 0.46 * hash11(idx.x + 0.31), rsv.x),
                                mix(1.0, 0.78 + 0.46 * hash11(idx.y + 7.17), rsv.y));
        float2 vg = float2(mix(1.0, 0.88 + 0.22 * hash11(idx.x * 3.1 + 0.9), rsv.x),
                           mix(1.0, 0.88 + 0.22 * hash11(idx.y * 3.1 + 4.4), rsv.y));
        // uneven gas fill along each tube + dust patches on the glass
        vg.x *= 0.84 + 0.30 * fbm(float2(idx.x * 2.7, p.z * 0.085), 3);
        vg.y *= 0.84 + 0.30 * fbm(float2(idx.y * 2.7, p.x * 0.085), 3);
        float2 cG = nh_floorCov(g, lw, fw, fwS) * vg;
        float2 cR = nh_floorCov(g + gca, lw, fw, fwS) * vg;
        float2 cB = nh_floorCov(g - gca, lw, fw, fwS) * vg;
        float2 k  = nh_floorCov(g, lw * 0.4, fw, fwS) * vg;
        float cov = cG.x + cG.y - cG.x * cG.y;
        float core = k.x + k.y - k.x * k.y;
        float sx = nh_halo(g.x, 0.05, fw.x) * vg.x, sz = nh_halo(g.y, 0.05, fw.y) * vg.y;
        float gxp = length(float2(dx.x, dy.x)), gzp = length(float2(dx.y, dy.y));
        float rb1 = 0.004 * res.y, rb2 = 0.020 * res.y;
        float bx1 = nh_halo(g.x, rb1 * gxp, fw.x), bz1 = nh_halo(g.y, rb1 * gzp, fw.y);
        float bx2 = nh_halo(g.x, rb2 * gxp, fw.x), bz2 = nh_halo(g.y, rb2 * gzp, fw.y);
        float gfade = 0.35 + 0.65 * exp(-t / 45.0);
        // near-field rolloff: keep the dock strip calm and the sun the focal point
        gfade *= mix(0.48, 1.0, smoothstep(3.5, 15.0, t));
        // and taper toward the left/right frame edges so the eye runs to the sun
        gfade *= 1.0 - 0.34 * smoothstep(0.22, 0.52, abs(fragCoord.x / res.x - 0.5));
        // two-tone neon: every fourth longitudinal tube is cyan, transverse tubes
        // cool toward the horizon -- ties the floor to the cyan wireframe ranges
        float cyX = 1.0 - step(0.125, fract(idx.x * 0.25));
        float wX = mix(0.24, cyX, rsv.x);
        float wZ = 0.08 + 0.26 * smoothstep(18.0, 110.0, t);
        float3 colX = mix(NH_MAG, NH_CYN2, wX);
        float3 colZ = mix(NH_MAG, NH_CYN2, wZ);
        float3 hotX = mix(float3(1.0, 0.55, 0.85), float3(0.60, 0.92, 1.0), wX);
        float3 hotZ = mix(float3(1.0, 0.55, 0.85), float3(0.60, 0.92, 1.0), wZ);
        float3 emX = colX * 4.0 * gfade, emZ = colZ * 4.0 * gfade;
        float3 tube = float3(emX.r * cR.x + emZ.r * cR.y, emX.g * cG.x + emZ.g * cG.y, emX.b * cB.x + emZ.b * cB.y)
                    - 0.5 * (emX + emZ) * cG.x * cG.y
                    + (hotX * k.x + hotZ * k.y - 0.5 * (hotX + hotZ) * k.x * k.y) * 3.0 * gfade;
        float3 spill = (colX * sx + colZ * sz) * 4.0 * LW * 0.6 * gfade;
        float3 bloom = (colX * (0.18 * bx1 + 0.08 * bx2) + colZ * (0.18 * bz1 + 0.08 * bz2)) * 4.0 * LW * gfade;
        cov *= gfade;

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
        float aS = mix(0.013, 0.048, smudge);
        float wS = mix(0.88, 0.58, smudge);

        float3 r = reflect(rd, n);
        r.y = max(r.y, 1e-4); r = normalize(r);
        float e = max(-rd.y, 1e-3);
        float elr = asin(r.y);
        float azr = atan2(r.x, -r.z);

        // main glossy lobe: stratified GGX-marginal taps (vertical), each fully traced
        const int KM = 3;
        float3 sharp = float3(0.0);
        float jm = fract(jit * 7.31 + 0.13);
        for (int kk = 0; kk < KM; kk++) {
            float u = (float(kk) + jm) / float(KM);
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
                ck = nh_shadeA(rk, qp, rh.n, float2(fwr), float2(0.0), res.y);
                ck = nh_fog(ck, p, rk, rh.t);
            } else if (rh.kind == 2) {
                float3 qp = p + rk * rh.t;
                float3 nn = nh_normalB(qp.xz, max(0.6, 2.5 * (pix * (t + rh.t) + spc * rh.t)), 5);
                float3 nss = nh_normalB(qp.xz, max(3.0, 0.022 * rh.t), 3);
                ck = nh_shadeB(rk, qp, nn, nss);
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
        for (int kk = 0; kk < K; kk++) {
            float u = (float(kk) + jit) / float(K);
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
        // real-floor micro-imperfection: polish swirls, dust film, a few fine scratches
        float mott = fbm(p.xz * float2(1.1, 0.8) + 17.0, 4);
        float dust = fbm(p.xz * float2(0.55, 0.40) + 43.0, 4);
        float scr = smoothstep(0.86, 0.99, ridged(p.xz * float2(0.9, 0.06) + 71.0, 3));
        refl *= 0.86 + 0.26 * (0.5 + 0.5 * mott) * detail + 0.10 * (1.0 - detail);
        refl *= 1.0 - 0.30 * dust * detail;
        refl = mix(refl, refl * 0.55 + float3(ws_luma(refl)) * 0.55, scr * detail * 0.8);

        float cth = clamp(dot(-rd, n), 0.0, 1.0);
        float F = 0.04 + 0.96 * pow(1.0 - cth, 5.0);
        float3 base = float3(0.002, 0.0015, 0.003) + spill * (1.0 - F);
        col = (base + F * refl) * (1.0 - cov) + tube + bloom;
        col = nh_fog(col, ro, rd, t);
    } else {
        col = nh_sky(rd, pix * 0.7, pix * 0.7, 1.0, caAng);
        float fm = ws_fogAmount(3000.0, ro, rd, 0.020, 1.6);
        col += NH_MAG * 0.10 * fm;
    }

    float2 uv = fragCoord / res;

    // ---------------- lens: glare, dirty front element, faint horizontal veil
    {
        float dirt = 0.78 + 0.44 * fbm(uv * float2(6.0, 3.6) + 31.0, 4);
        float psi = acos(clamp(dot(rd, nh_sunDir()), -1.0, 1.0));
        float ds = max(psi - NH_SUNR, 0.0);
        col += float3(1.0, 0.25, 0.35) * dirt * (0.155 * exp(-ds / 0.008) + 0.068 * exp(-ds / 0.040) + 0.030 * exp(-ds / 0.16));
        float3 ms = float3(0.0, -sin(NH_SUNEL), -cos(NH_SUNEL));
        float psm = acos(clamp(dot(rd, ms), -1.0, 1.0));
        float dm = max(psm - NH_SUNR, 0.0);
        col += float3(1.0, 0.30, 0.25) * 0.35 * (0.10 * exp(-dm / 0.010) + 0.06 * exp(-dm / 0.045));
        float dyA = asin(clamp(rd.y, -1.0, 1.0)) - NH_SUNEL;
        float dxA = atan2(rd.x, -rd.z);
        col += float3(1.0, 0.32, 0.42) * 0.024 * dirt * exp(-abs(dyA) / 0.0105) * exp(-abs(dxA) / 0.30);
        // lens ghosts: faint aperture images on the sun->centre axis
        float zc = dot(nh_sunDir(), fwd);
        if (zc > 0.2) {
            float2 sp2 = float2(dot(nh_sunDir(), rgt), dot(nh_sunDir(), up)) / (zc * kf);
            const float3 gt[3] = { float3(1.0, 0.55, 0.30), float3(0.35, 0.85, 1.0), float3(1.0, 0.35, 0.65) };
            const float gk[3] = { -0.42, -0.95, -1.55 };
            const float gr[3] = { 0.070, 0.115, 0.055 };
            const float ga[3] = { 0.016, 0.011, 0.020 };
            for (int gi = 0; gi < 3; gi++) {
                float d = length(pp - sp2 * gk[gi]) / gr[gi];
                float disc = smoothstep(1.0, 0.86, d) * (0.55 + 0.45 * smoothstep(0.60, 0.98, d));
                col += gt[gi] * ga[gi] * disc * dirt;
            }
        }
    }

    float3 c = ws_acesFitted(col * 1.0);
    c = mix(c, c * c * (3.0 - 2.0 * c), 0.12);          // gentle filmic S-curve
    c *= ws_vignette(uv, 0.32);
    // film grain: strongest in the mid tones, mostly luminance with a little chroma
    float l = ws_luma(c);
    float gA = 0.0135 * (0.55 + 0.45 * smoothstep(0.004, 0.10, l)) * (1.0 - 0.50 * smoothstep(0.42, 0.96, l));
    float3 gn = float3(ws_grain(fragCoord, 0.0), ws_grain(fragCoord + 51.3, 0.0), ws_grain(fragCoord + 113.7, 0.0));
    c += gA * mix(float3(dot(gn, float3(1.0 / 3.0))), gn, 0.45);
    return max(c, 0.0);
}
