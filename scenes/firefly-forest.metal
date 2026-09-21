// =====================================================================
//  Firefly Forest — ground-level night view into a clearing of an
//  old-growth fir forest. Moon out of frame (upper-left, in front of
//  the camera) so the fog is back-lit: shafts slant down through canopy
//  gaps, low ground fog drifts across the floor, and ~64 fireflies drift
//  on closed paths and pulse with staggered rhythms.
//
//  Technique: 12 depth planes (2.4 .. 100 m) composited front to back.
//  Near planes carry hand-placed trunks with bark texture + bump
//  shading, far planes are procedural fir silhouettes. Between planes
//  the fog volume (height haze + loop-safe ground fog) is integrated
//  with sub-steps; moon light is shadowed by a canopy-gap function
//  projected along the moon direction (true volumetric god rays).
//  Fireflies are composited inside the plane loop so they are occluded
//  by trunks and attenuated by fog physically.
// =====================================================================

constant float DEG = 0.017453292519943295;

constant float3 FF_L     = float3(-0.5014, 0.6217, -0.6017);  // toward the moon
constant float3 FF_RO    = float3(0.0, 1.45, 0.0);
constant float  FF_PITCH = 5.0;
constant float  FF_FOV   = 50.0;
constant float  FF_HC    = 24.0;           // canopy shadow plane (m)
constant float  FF_SIGH  = 0.030;          // haze extinction at ground (1/m)
constant float  FF_HAZEH = 14.0;           // haze scale height
constant float  FF_SIGG  = 0.26;           // ground-fog peak extinction
constant float  FF_EM    = 8.0;            // moon irradiance (scene units)
constant float3 FF_MOONC = float3(0.70, 0.83, 1.00);
constant float3 FF_FOGA  = float3(0.60, 0.79, 0.84);   // fog albedo (blue-green)
constant float3 FF_AMB   = float3(0.10, 0.16, 0.30);   // ambient radiance in fog
constant float3 FF_FFCOL = float3(0.78, 1.00, 0.28);   // firefly colour
constant float  FF_FFP   = 3200.0;                     // firefly power
constant float  FF_EXPO  = 1.25;

constant int   FF_NROW   = 12;
constant float FF_Z[12]   = { 2.4, 3.8, 5.5, 8.0, 11.5, 16.0, 22.0, 30.0, 41.0, 56.0, 75.0, 100.0 };
constant float FF_W[12]   = { 5.0, 4.5, 4.0, 4.0, 3.8, 3.6, 3.5, 3.4, 3.3, 3.2, 3.0, 3.0 };
constant float FF_DEN[12] = { 0.0, 0.0, 0.0, 0.0, 0.55, 0.60, 0.66, 0.72, 0.80, 0.86, 0.92, 0.96 };
// hand-placed near trunks: x, radius, lean, seed
constant float4 FF_NEAR[8] = {
    float4(-1.75, 0.48,  0.020, 1.0),
    float4( 2.55, 0.42, -0.015, 2.0),
    float4(-4.30, 0.38,  0.010, 3.0), float4( 5.70, 0.35, -0.020, 4.0),
    float4(-7.60, 0.40,  0.000, 5.0), float4(-2.90, 0.30,  0.030, 6.0),
    float4( 7.00, 0.36, -0.010, 7.0), float4(10.60, 0.30,  0.000, 8.0) };
constant int FF_NS[5] = { 0, 1, 2, 4, 8 };
constant int FF_NFF = 64;

// ---------------------------------------------------------------- light
inline float ff_hg(float c, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(1.0 + gg - 2.0 * g * c, 1.5));
}
// canopy openness above the forest, in the canopy plane (x, z)
inline float ff_gap(float2 xz) {
    float n1 = fbm(xz * 0.085 + float2(3.1, 7.7), 3);
    float n2 = fbm(xz * 0.30 + float2(9.2, 1.3), 3);
    float2 cq = (xz - float2(2.5, -19.0)) * float2(1.0, 0.6);
    float pool = 1.0 - smoothstep(4.0, 12.0, length(cq));
    float open = smoothstep(-0.15, 0.40, n1 + 0.25) * pool;
    float holes = smoothstep(0.30, 0.55, n2) * (0.35 + 0.65 * smoothstep(-0.2, 0.3, n1));
    float g = max(open, holes);
    return 0.03 + 0.97 * g;
}
// direct moon-light factor at a point below the canopy (shadow + fog path)
inline float ff_moon(float3 p) {
    float h = max(FF_HC - p.y, 0.0) / FF_L.y;
    float2 q = p.xz + FF_L.xz * h;
    float od = FF_SIGH * FF_HAZEH * (exp(-max(p.y, 0.0) / FF_HAZEH) - exp(-FF_HC / FF_HAZEH)) / FF_L.y;
    return ff_gap(q) * exp(-0.6 * od);
}

// ---------------------------------------------------------------- fog
inline float ff_haze(float y) { return FF_SIGH * exp(-max(y, 0.0) / FF_HAZEH); }
inline float ff_gfog(float3 p, float t) {
    float h = smoothstep(2.6, 0.0, p.y);
    if (h <= 0.0) return 0.0;
    float2 q = p.xz * 0.21;
    float w = abs(2.0 * fract(t) - 1.0);
    float2 drift = float2(3.2, 1.1) * 0.21;
    float nA = fbmLoop(q + drift * fract(t), t, 2, 1);
    float nB = fbmLoop(q + drift * fract(t + 0.5) + float2(31.7, 12.3), t, 2, 1);
    float n = mix(nA, nB, w) / sqrt(w * w + (1.0 - w) * (1.0 - w));
    float big = fbm(q * 0.33 + float2(1.7, 4.2), 2);
    float dens = smoothstep(-0.45, 0.55, n + 0.6 * big + 0.1);
    return FF_SIGG * h * h * (0.15 + 0.85 * dens);
}

// integrate fog along the ray from s0 to s1 (front to back)
inline void ff_fogSeg(thread float3 &col, thread float &T, float3 ro, float3 rd, float s0, float s1,
                      float t, float jit, float phase) {
    float len = s1 - s0;
    if (len <= 1e-4) return;
    float stepLen = 0.9 + 0.13 * s0;
    int n = clamp(int(len / stepLen) + 1, 1, 7);
    float ds = len / float(n);
    for (int i = 0; i < n; i++) {
        float sm = s0 + ds * (float(i) + jit);
        float3 p = ro + rd * sm;
        float sig = ff_haze(p.y) + ff_gfog(p, t);
        float3 light = FF_MOONC * (FF_EM * phase * ff_moon(p)) + FF_AMB;
        float tr = exp(-sig * ds);
        col += T * FF_FOGA * light * (1.0 - tr);
        T *= tr;
    }
}

// ---------------------------------------------------------------- fireflies
struct FFly { float3 pos; float bright; };
inline FFly ff_fly(int i, float t) {
    float fi = float(i) + 0.5;
    float4 h1 = hash44(float4(fi, 1.3, 2.7, 9.1));
    float4 h2 = hash44(float4(fi, 5.9, 7.3, 3.7));
    float4 h3 = hash44(float4(fi, 8.1, 0.4, 6.6));
    float cz = 3.2 * exp(h1.x * 2.3);                 // 3.2 .. 32 m
    float cx = (h1.y - 0.5) * (5.0 + 0.55 * cz);
    float cy = 0.3 + 2.4 * pow(h1.z, 1.6);
    int k2 = 2 + int(h2.w * 2.0);
    float a1 = TAU * (t + h2.x), a2 = TAU * (float(k2) * t + h2.y), a3 = TAU * (t + h2.z);
    float r1 = 0.45 + 0.75 * h3.x;
    float3 p = float3(cx, cy, -cz);
    p += float3(r1 * cos(a1), 0.35 * r1 * sin(a3), 0.7 * r1 * sin(a1));
    p += 0.2 * float3(sin(a2), 0.5 * cos(a2 + 1.0), cos(a2));
    int kp = 1 + int(h3.y * 3.0);
    float u = fract(float(kp) * t + h3.z);
    float on = 0.16 + 0.14 * h3.w;
    float env = smoothstep(0.0, 0.11, u) * (1.0 - smoothstep(on, on + 0.18, u));
    env = env * env * (3.0 - 2.0 * env);
    FFly f; f.pos = p; f.bright = env * (0.7 + 0.6 * h1.w);
    return f;
}
inline float3 ff_glow(float2 dpx, float R, float flux) {
    float r2 = dot(dpx, dpx);
    float rmax = 28.0 + 5.0 * R;
    if (r2 > rmax * rmax) return float3(0.0);
    float r = sqrt(r2);
    float disc = 1.0 - smoothstep(R - 0.9, R + 0.9, r);
    float core = flux / (PI * R * R + 2.0) * disc;
    float halo = flux * 0.007 / (1.0 + r2 / (R * R + 5.0)) * (1.0 - smoothstep(rmax * 0.5, rmax, r));
    return mix(FF_FFCOL, float3(1.0), 0.3) * core + FF_FFCOL * halo;
}
// warm light from nearby fireflies on a surface
inline float3 ff_flyLight(float3 P, float3 n, thread float4 *fp) {
    float3 acc = float3(0.0);
    for (int i = 0; i < FF_NFF; i++) {
        float4 f = fp[i];
        if (f.w <= 0.001) continue;
        float3 d = f.xyz - P;
        float d2 = dot(d, d);
        if (d2 > 36.0) continue;
        float ndl = max(dot(n, d * rsqrt(d2)), 0.0);
        acc += f.w * ndl / (d2 + 0.08) * (1.0 - d2 / 36.0);
    }
    return acc * FF_FFCOL * 0.5;
}

// ---------------------------------------------------------------- trunks
inline float ff_barkTex(float u, float y, float seed) {
    float f1 = fbm(float2(u * 9.0 + seed * 3.0, y * 1.2 + seed), 4);
    float f2 = fbm(float2(u * 28.0 + seed, y * 6.0), 2);
    return (0.4 + 0.6 * smoothstep(-0.55, 0.6, f1)) * (0.82 + 0.18 * f2);
}
// signed half-width of a trunk silhouette at height y (metres)
inline float ff_trunkW(float y, float r0, float seed) {
    float w = r0 * (1.0 - 0.012 * y) + r0 * 0.75 * exp(-max(y, 0.0) * 1.7);
    w *= 1.0 + 0.06 * gnoise(float2(y * 2.3 + seed * 5.0, seed * 7.0));
    return w;
}
inline float3 ff_trunkShade(float3 P, float nx, float w, float seed, float fp, thread float4 *fp4, bool detail) {
    float3 alb = float3(0.30, 0.235, 0.17);
    float nz = sqrt(max(1.0 - nx * nx, 0.0));
    float3 n = float3(nx, 0.0, nz);
    if (detail) {
        float u = asin(clamp(nx, -1.0, 1.0)) * w;
        float e = max(0.004, fp);
        float b0 = ff_barkTex(u, P.y, seed);
        float b1 = ff_barkTex(u + e, P.y, seed);
        float b2 = ff_barkTex(u, P.y + e, seed);
        float3 tang = float3(nz, 0.0, -nx);
        n = normalize(n - tang * ((b1 - b0) / e) * 0.05 - float3(0.0, 1.0, 0.0) * ((b2 - b0) / e) * 0.05);
        alb *= 0.55 + 0.7 * b0;
        // moss / lichen on the shaded (right) side, low on the trunk
        float moss = smoothstep(0.25, 0.6, fbm(float2(u * 2.5 + seed * 9.0, P.y * 1.5), 3))
                   * smoothstep(-0.2, 0.7, nx) * smoothstep(3.0, 0.5, P.y);
        alb = mix(alb, float3(0.22, 0.34, 0.16), moss * 0.7);
    }
    float moon = ff_moon(P);
    float3 col = alb * FF_MOONC * FF_EM * moon * max(dot(n, FF_L), 0.0);       // direct rim
    float wrap = max(dot(n, FF_L) + 0.6, 0.0) / 1.6;
    col += alb * FF_MOONC * (0.16 * wrap) * (0.35 + 0.65 * moon);            // soft fog light from moon side
    col += alb * FF_AMB * (0.9 + 0.5 * n.y);                                 // ambient
    col += alb * ff_flyLight(P, n, fp4);
    return col;
}

// fir silhouette half-width for procedural rows (tiers above branch height)
inline float ff_firW(float y, float r0, float Hb, float Ht, float4 h, float fp) {
    float w = ff_trunkW(y, r0, h.x * 10.0);
    if (y > Hb && y < Ht) {
        float s = Ht - y;
        float taper = 0.16 * (0.75 + 0.5 * h.y);
        float env = taper * (s + 0.4) * (1.0 + 0.2 * gnoise(float2(s * 0.35 + h.x * 40.0, h.y * 13.0)));
        float sp = (0.7 + 0.5 * h.z);
        float q = s / sp + h.w * 3.0;
        float n = floor(q), ph = fract(q);
        float Lb = 0.5 + 0.6 * hash12(float2(n + h.x * 131.0, h.y * 71.0));
        float tier = Lb * (0.42 + 0.58 * pow(ph, 0.6)) * (1.0 - 0.3 * smoothstep(0.8, 1.0, ph));
        float det = 1.0 - smoothstep(sp * 0.25, sp * 0.9, fp);
        float rag = gnoise(float2(s * 2.5 + h.z * 17.0, n * 0.37 + h.x * 9.0));
        env *= mix(0.8, tier, det) + 0.15 * det * rag;
        // fade tiers in near the branch base
        env *= smoothstep(Hb, Hb + 2.5, y);
        w = max(w, env);
    } else if (y >= Ht) {
        w = -1.0;
    }
    return w;
}

// ---------------------------------------------------------------- undergrowth
inline float ff_frond(float2 d, float ang, float L, float w0, float droop, float pinna) {
    float2 dir = float2(cos(ang), sin(ang));
    float u = dot(d, dir);
    if (u < 0.0 || u > L) return 1e3;
    float v = dot(d, float2(-dir.y, dir.x));
    float vc = -droop * cos(ang) * u * u / L;
    float k = u / L;
    float w = w0 * (1.0 - k);
    if (pinna > 0.0) w *= (0.3 + 0.7 * abs(sin(u * pinna))) * smoothstep(0.0, 0.1, k) + 0.12;
    return abs(v - vc) - w - 0.004;
}
// min signed distance of an undergrowth cell at (x, y); base at cell centre
inline float ff_plantD(float2 d, float4 h, float size) {
    float dm = 1e3;
    bool fern = h.x < 0.6;
    int nf = fern ? 7 : 6;
    for (int j = 0; j < nf; j++) {
        float hj = hash12(float2(float(j) + h.y * 40.0, h.z * 90.0));
        float hk = hash12(float2(float(j) * 3.1 + h.w * 20.0, h.x * 70.0));
        float ang, L, w0, droop, pin;
        if (fern) {
            ang = (18.0 + 144.0 * (float(j) + 0.5) / float(nf) + 14.0 * (hj - 0.5)) * DEG;
            L = size * (0.55 + 0.45 * hk) * (0.75 + 0.25 * abs(sin(ang)));
            w0 = 0.09 * size;
            droop = 0.55;
            pin = PI * (12.0 + 5.0 * hj) / L;
        } else {
            ang = (40.0 + 100.0 * (float(j) + 0.5) / float(nf) + 20.0 * (hj - 0.5)) * DEG;
            L = size * (0.5 + 0.5 * hk);
            w0 = 0.014;
            droop = 0.35;
            pin = 0.0;
        }
        dm = min(dm, ff_frond(d, ang, L, w0, droop, pin));
    }
    return dm;
}

// ---------------------------------------------------------------- sky
inline float3 ff_sky(float3 rd, float t) {
    float3 sky = float3(0.012, 0.022, 0.05) * (1.0 + 0.6 * max(rd.y, 0.0));
    float c = dot(rd, FF_L);
    sky += FF_MOONC * 0.03 * pow(max(c, 0.0), 6.0);
    float2 sp = float2(atan2(rd.x, -rd.z), asin(clamp(rd.y, -1.0, 1.0))) * 14.0;
    sky += ws_stars(sp, 6.0, t, 0.25) * 0.5;
    return sky;
}

// ================================================================= scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float t = fract(ctx.t);
    float2 res = ctx.res;
    float3 ro = FF_RO;
    float3 fwd = float3(0.0, sin(FF_PITCH * DEG), -cos(FF_PITCH * DEG));
    float3 rd = ws_camRay(fragCoord, res, ro, ro + fwd, FF_FOV);
    float3 right = float3(1.0, 0.0, 0.0);
    float3 up = cross(right, fwd);
    float k = tan(FF_FOV * DEG * 0.5);
    float pixAng = 2.0 * k / res.y;
    float jit = 0.25 + 0.5 * hash12(fragCoord + 0.37);
    float phase = 0.62 * ff_hg(dot(rd, FF_L), 0.55) + 0.38 / (4.0 * PI);

    // ---- fireflies (positions, projections)
    float4 fP[64];   // world pos, brightness
    float4 fS[64];   // pixel x, y, bokeh radius, flux
    for (int i = 0; i < FF_NFF; i++) {
        FFly f = ff_fly(i, t);
        fP[i] = float4(f.pos, f.bright);
        float3 v = f.pos - ro;
        float d = dot(v, fwd);
        float2 sp = float2(dot(v, right), dot(v, up)) / (d * k);
        float2 px = (sp * res.y + res) * 0.5;
        float R = max(1.4, 34.0 * abs(1.0 / d - 1.0 / 12.0)) * res.y / 1600.0;
        float flux = FF_FFP * f.bright / pow(d, 1.75);
        fS[i] = float4(px, R, flux);
    }

    float3 col = float3(0.0);
    float T = 1.0;
    float sPrev = 0.0, zPrev = 0.0;
    float sG = rd.y < -1e-4 ? -ro.y / rd.y : 1e9;   // ground hit
    bool done = false;

    for (int kx = 0; kx < FF_NROW && !done; kx++) {
        float Z = FF_Z[kx];
        float s = Z / max(-rd.z, 1e-4);
        // ground before this plane?
        if (sG < s) {
            ff_fogSeg(col, T, ro, rd, sPrev, sG, t, jit, phase);
            for (int i = 0; i < FF_NFF; i++) {
                float D = -fP[i].z;
                if (D > zPrev && D <= sG * (-rd.z) && fP[i].w > 0.001)
                    col += T * ff_glow(fragCoord - fS[i].xy, fS[i].z, fS[i].w);
            }
            float3 G = ro + rd * sG;
            float gtex = 0.55 + 0.45 * fbm(G.xz * 2.2, 3);
            float moss = smoothstep(0.1, 0.5, fbm(G.xz * 0.6 + 3.0, 2));
            float3 galb = mix(float3(0.16, 0.12, 0.08), float3(0.10, 0.16, 0.07), moss) * gtex;
            float3 gn = float3(0.0, 1.0, 0.0);
            float3 gl = FF_MOONC * FF_EM * ff_moon(G) * FF_L.y + FF_AMB * 0.8 + ff_flyLight(G, gn, fP);
            col += T * galb * gl;
            T = 0.0;
            done = true;
            break;
        }
        ff_fogSeg(col, T, ro, rd, sPrev, s, t, jit, phase);
        // fireflies between the previous plane and this one
        for (int i = 0; i < FF_NFF; i++) {
            float D = -fP[i].z;
            if (D > zPrev && D <= Z && fP[i].w > 0.001)
                col += T * ff_glow(fragCoord - fS[i].xy, fS[i].z, fS[i].w);
        }
        sPrev = s; zPrev = Z;
        if (T < 0.004) { done = true; break; }

        float3 P = ro + rd * s;
        float fp = s * pixAng;
        float cov = 0.0;
        float3 rc = float3(0.0);
        bool detail = kx < 5;

        // ---- trunks / trees
        if (P.y >= -0.05) {
            if (kx < 4) {
                for (int j = FF_NS[kx]; j < FF_NS[kx + 1]; j++) {
                    float4 tr = FF_NEAR[j];
                    float cx = tr.x + tr.z * P.y;
                    float w = ff_trunkW(P.y, tr.y, tr.w);
                    float dx = P.x - cx;
                    float c = clamp(0.5 - (abs(dx) - w) / fp, 0.0, 1.0);
                    if (c > 0.0) {
                        float nx = clamp(dx / w, -1.0, 1.0);
                        float3 sc = ff_trunkShade(P, nx, w, tr.w, fp, fP, true);
                        rc = mix(rc, sc, c > cov ? 1.0 : 0.0);
                        cov = max(cov, c);
                    }
                }
            } else {
                float W = FF_W[kx];
                float ci = floor(P.x / W);
                for (int di = -1; di <= 1; di++) {
                    float cell = ci + float(di);
                    float4 h = hash24(float2(cell * 7.3 + 1.1, float(kx) * 13.7 + 2.9));
                    // clearing mask
                    float cx = (cell + 0.5 + 0.7 * (h.x - 0.5)) * W;
                    float cw = 7.5 * smoothstep(5.0, 12.0, Z) * (1.0 - smoothstep(28.0, 60.0, Z)) + 2.5 * (1.0 - smoothstep(5.0, 12.0, Z));
                    float clr = 1.0 - smoothstep(cw * 0.6, cw * 1.4, abs(cx - 2.0));
                    if (h.y > FF_DEN[kx] * (1.0 - clr)) continue;
                    float4 h2 = hash24(float2(cell * 3.1 + 5.7, float(kx) * 5.3 + 7.1));
                    float r0 = 0.22 + 0.3 * h.z;
                    float lean = (h.w - 0.5) * 0.06;
                    float Hb = 6.0 + 8.0 * h2.x + (kx < 6 ? 4.0 : 0.0);
                    float Ht = 24.0 + 16.0 * h2.y;
                    float cxy = cx + lean * P.y;
                    float w = ff_firW(P.y, r0, Hb, Ht, h2, fp);
                    if (w <= 0.0) continue;
                    float dx = P.x - cxy;
                    float c = clamp(0.5 - (abs(dx) - w) / fp, 0.0, 1.0);
                    if (c > 0.0) {
                        float nx = clamp(dx / w, -1.0, 1.0);
                        float3 sc;
                        if (P.y > Hb) {
                            float3 calb = float3(0.05, 0.07, 0.04);
                            sc = calb * (FF_AMB * 0.8 + FF_MOONC * 0.1 * ff_moon(P));
                        } else {
                            sc = ff_trunkShade(P, nx, w, h.x * 10.0, fp, fP, detail);
                        }
                        rc = mix(rc, sc, c > cov ? 1.0 : 0.0);
                        cov = max(cov, c);
                    }
                }
            }
        }
        // ---- undergrowth (ferns / grass)
        if (kx <= 6 && P.y < 1.7 && P.y > -0.4 && cov < 0.999) {
            float Wu = 0.75 + 0.06 * Z;
            float ci = floor(P.x / Wu);
            for (int di = -1; di <= 1; di++) {
                float cell = ci + float(di);
                float4 h = hash24(float2(cell * 11.3 + 0.7, float(kx) * 3.7 + 19.1));
                if (h.w < 0.12) continue;
                float bx = (cell + 0.5 + 0.5 * (h.y - 0.5)) * Wu;
                float by = -0.12 + 0.22 * h.z;
                float size = 0.7 + 0.5 * h.x;
                float2 d = float2(P.x - bx, P.y - by);
                if (abs(d.x) > size * 1.1 || d.y > size * 1.1 || d.y < -0.05) continue;
                float sd = ff_plantD(d, hash24(float2(cell * 5.1 + 3.3, float(kx) * 7.9 + 1.7)), size);
                float c = clamp(0.5 - sd / fp, 0.0, 1.0);
                if (c > 0.0) {
                    float3 n = float3(0.0, 0.3, 0.95);
                    float3 palb = float3(0.06, 0.10, 0.04);
                    float3 sc = palb * (FF_AMB * 1.2 + FF_MOONC * FF_EM * 0.05 * ff_moon(P) + ff_flyLight(P, n, fP));
                    rc = mix(rc, sc, c > cov ? 1.0 : 0.0);
                    cov = max(cov, c);
                }
            }
        }
        if (cov > 0.0) {
            col += T * cov * rc;
            T *= (1.0 - cov);
        }
    }
    if (!done && T > 0.002) {
        ff_fogSeg(col, T, ro, rd, sPrev, 240.0, t, jit, phase);
        col += T * ff_sky(rd, t);
    }

    // ---- finish
    col *= FF_EXPO;
    float2 uv = fragCoord / res;
    col *= ws_vignette(uv, 0.22);
    float3 o = ws_acesFitted(col);
    o += ws_grain(fragCoord, t) * 0.004;
    return clamp(o, 0.0, 1.0);
}
