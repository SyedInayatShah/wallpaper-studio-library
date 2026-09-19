// =====================================================================
//  Pine Ridge Dusk — long-lens (~330 mm) view across seven receding,
//  spruce-fir covered ridges at early blue hour; full moon rising in the
//  anti-twilight above mist-filled valleys.
//
//  Technique: world-space 2.5D terrain. Each ridge is a family of depth
//  rows (front slope + crest + back slope) sampled at their true
//  distance; every row carries procedural spruce / fir silhouettes
//  (whorl tiers, leaders, snags). The ray is walked front-to-back through
//  the rows with analytic coverage AA, and closed-form volumetric fog
//  between them: chromatic exponential haze + per-valley sigmoid mist.
// =====================================================================

constant float DEG  = 0.017453292519943295;
constant float VFOV = 4.2;          // vertical field of view (deg)
constant float PY   = 0.0;          // vertical lens shift (p units)
constant float CAMH = 1600.0;       // camera altitude (m)
constant int   NL   = 7;
constant int   NBACK = 4;

constant float L_D[7]     = { 2800., 4700., 7600., 12000., 18500., 28000., 42000. };
constant float L_EL[7]    = { -1.38, -0.95, -0.66, -0.46, -0.31, -0.19, -0.08 };  // crest elevation (deg)
constant float L_REL[7]   = { 0.20, 0.30, 0.32, 0.32, 0.30, 0.28, 0.34 };         // relief (deg)
constant float L_SCL[7]   = { 300., 500., 700., 900., 1200., 1700., 2400. };       // profile scale (m)
constant float L_TILT[7]  = { 0.30, -0.20, 0.12, -0.10, 0.08, -0.06, 0.06 };       // deg at screen edge
constant float L_TH[7]    = { 21., 20.5, 20., 20., 20., 20., 20. };               // tree height (m)
constant float L_CELL[7]  = { 4.0, 3.3, 3.3, 3.5, 3.7, 3.9, 4.1 };                 // tree spacing (m)
constant float L_SLOPE[7] = { 0.55, 0.50, 0.48, 0.45, 0.42, 0.40, 0.38 };
constant int   L_ROWS[7]  = { 26, 14, 12, 10, 9, 8, 7 };
constant float L_DZ[7]    = { 4.0, 5.0, 7.0, 10.0, 14.0, 20.0, 28.0 };
constant float L_FILL[7]  = { 0.24, 0.30, 0.46, 0.58, 0.64, 0.68, 0.70 };
constant float L_HV[7]    = { 0.75, 0.62, 0.40, 0.26, 0.20, 0.18, 0.16 };
constant float L_MIST[7]  = { 0.0, 0.05, 0.14, 0.03, 0.12, 0.06, 0.10 };         // mist top above prev crest (deg)

constant float2 MOON_P = float2(-0.45, 0.28);   // screen position (p coords)
constant float  MOON_R = 0.27;                  // angular radius (deg)

// ------------------------------------------------------------ colour helpers
// Invert Hill's ACES fit so colours can be authored as display sRGB targets.
inline float pr_invCurve(float r) {
    r = clamp(r, 0.0, 0.995);
    float A = 0.983729 * r - 1.0, B = 0.4329510 * r - 0.0245786, C = 0.238081 * r + 0.000090537;
    float disc = max(B * B - 4.0 * A * C, 0.0);
    return (-B - sqrt(disc)) / (2.0 * A);
}
inline float3 pr_disp(uint hex) {
    float3 o = ws_hex(hex);
    float3 r = float3(dot(float3(0.643038, 0.311187, 0.045775), o),
                      dot(float3(0.059269, 0.931436, 0.009295), o),
                      dot(float3(0.005962, 0.063929, 0.930118), o));
    float3 i = float3(pr_invCurve(r.x), pr_invCurve(r.y), pr_invCurve(r.z));
    return max(float3(dot(float3( 1.764741, -0.675778, -0.088963), i),
                      dot(float3(-0.147028,  1.160252, -0.013224), i),
                      dot(float3(-0.036337, -0.162436,  1.198773), i)), 0.0);
}
inline float3 pr_dispF(float3 srgb) {
    float3 o = ws_srgb2lin(clamp(srgb, 0.0, 1.0));
    float3 r = float3(dot(float3(0.643038, 0.311187, 0.045775), o),
                      dot(float3(0.059269, 0.931436, 0.009295), o),
                      dot(float3(0.005962, 0.063929, 0.930118), o));
    float3 i = float3(pr_invCurve(r.x), pr_invCurve(r.y), pr_invCurve(r.z));
    return max(float3(dot(float3( 1.764741, -0.675778, -0.088963), i),
                      dot(float3(-0.147028,  1.160252, -0.013224), i),
                      dot(float3(-0.036337, -0.162436,  1.198773), i)), 0.0);
}
inline float pr_softplus(float x) { return x > 15.0 ? x : log(1.0 + exp(x)); }

// ------------------------------------------------------------ terrain
inline float pr_profile(int L, float x) {
    float u = x / L_SCL[L];
    float seed = 13.7 * float(L) + 2.3;
    float r = ridged(float2(u * 0.6, seed), 5);
    float f = fbm(float2(u, seed + 5.1), 5);
    return (r - 0.45) * 1.3 + 0.75 * f;
}

// Spruce / fir silhouette: signed horizontal distance (m), + inside.
inline float pr_tree(float dx, float dy, float H, float4 h, float fp) {
    float s = H - dy;                                   // metres below the tip
    if (s < 0.0) return 1.5 * s - abs(dx);
    float h5 = fract(h.w * 13.7), h6 = fract(h.z * 3.7), h7 = fract(h.y * 7.31), h8 = fract(h.x * 5.13);
    dx -= (h.x - 0.5) * 0.04 * s + 0.12 * (h8 - 0.5) * sin(s * 0.45 + h5 * 6.0) * min(s * 0.15, 1.0);
    float adx = abs(dx);
    float side = dx > 0.0 ? 1.0 : -1.0;
    if (h.w < 0.025) {                                  // dead snag
        float w = 0.06 + 0.005 * s;
        float q = s / 0.8 + h.z * 5.0;
        float n = floor(q), ph = fract(q);
        float stub = hash12(float2(n, side + h.x * 91.0));
        float sw = stub > 0.6 ? (stub - 0.6) * 2.0 * smoothstep(0.0, 0.2, ph) * (1.0 - smoothstep(0.3, 0.5, ph)) : 0.0;
        return max(w, sw * min(s * 0.25, 1.2)) - adx;
    }
    float fir = step(0.62, h7);
    float taper = mix(0.17, 0.12, fir) * (0.7 + 0.65 * h6);
    float lead = mix(0.6, 0.9, fir) * (0.5 + 0.9 * h5);
    float asym = 1.0 + side * (h8 - 0.5) * 0.3;
    float env = max(0.03 + 0.01 * s, taper * (s - 0.6 * lead)) * asym;
    env *= 1.0 + 0.22 * gnoise(float2(s * 0.3 + h.x * 40.0, side * 3.7 + h.y * 13.0));
    float sp = (0.5 + 0.03 * s) * (0.8 + 0.4 * h.z) * mix(1.0, 0.8, fir);
    float q = max(s - lead * 0.8, 0.0) / sp + h.w * 3.0 + 0.45 * gnoise(float2(s * 0.45 + h.x * 17.0, side * 2.1));
    float n = floor(q), ph = fract(q);
    float hb = hash12(float2(n + h.x * 131.0, side + h.y * 71.0));
    float hi = hash12(float2(n * 1.7 + h.z * 37.0, side * 3.0 + 5.0));
    float Lb = hb < 0.1 ? 0.35 : 0.55 + 0.6 * hb;
    float inner = 0.42 + 0.3 * hi;
    float tier = Lb * (inner + (1.0 - inner) * pow(ph, 0.55)) * (1.0 - 0.3 * smoothstep(0.78, 1.0, ph));
    tier = mix(tier, 0.8 * Lb + 0.1, 0.3 * fir);
    float detail = 1.0 - smoothstep(sp * 0.25, sp * 0.9, fp);
    float w = env * mix(0.8, tier, detail);
    float rag = 0.6 * gnoise(float2(s * 2.3 + h.z * 17.0, side * 5.0 + h.x * 9.0 + n * 0.37))
              + 0.4 * gnoise(float2(s * 6.1 + h.y * 23.0, side * 11.0 + n * 0.71));
    float fine = 1.0 - smoothstep(0.08, 0.3, fp);
    w += env * detail * (0.12 + 0.09 * fine) * rag;
    return w - adx;
}

// ------------------------------------------------------------ fog integrals
// exponential haze sigma0*exp(-(y-CAMH)/H) along y = CAMH + b z, z in [z1,z2]
inline float pr_odExp(float z1, float z2, float b, float sigma0, float H) {
    float k = b / H;
    if (abs(k * (z2 - z1)) < 1e-4) return sigma0 * exp(-k * 0.5 * (z1 + z2)) * (z2 - z1);
    return sigma0 * (exp(-k * z1) - exp(-k * z2)) / k;
}
// sigmoid mist pool sigma/(1+exp((y-M)/w))
inline float pr_odMist(float z1, float z2, float b, float sigma, float M, float w) {
    float u1 = (CAMH + b * z1 - M) / w, u2 = (CAMH + b * z2 - M) / w;
    if (abs(u2 - u1) < 1e-3) return sigma * (z2 - z1) / (1.0 + exp(0.5 * (u1 + u2)));
    return sigma * (w / b) * (pr_softplus(-u1) - pr_softplus(-u2));
}


// one fog segment: chromatic haze + valley haze pool + textured dense mist + wisps
struct PrFog { float3 T; float3 acc; };
struct PrMist { float S, top, w, amp, lx, lz, seed; };
inline void pr_fogSeg(thread PrFog &F, float z1, float z2, float b, float bH, float ax,
                      float SH0, float HH, float3 chroma,
                      float vS, float vTop, float vW, PrMist m, float mScale,
                      float3 airCol, float3 mistCol) {
    float yLo = min(CAMH + b * z1, CAMH + b * z2);
    bool mistOn = m.S > 0.0 && yLo < m.top + m.amp + 8.0 * m.w + 3.0 * m.amp;
    int nSub = mistOn ? clamp(int((z2 - z1) / (0.06 * z2)) + 1, 1, 4) : 1;
    float za = z1;
    for (int i = 0; i < nSub; i++) {
        float zb = (i == nSub - 1) ? z2 : mix(z1, z2, float(i + 1) / float(nSub));
        float odH = pr_odExp(za, zb, bH, SH0, HH);
        float yMin = min(CAMH + b * za, CAMH + b * zb);
        if (vS > 0.0 && yMin < vTop + 8.0 * vW) odH += pr_odMist(za, zb, b, vS, vTop, vW);
        float odM = 0.0;
        if (mistOn && yMin < m.top + m.amp + 8.0 * m.w + 3.0 * m.amp) {
            float zq = mix(za, zb, 0.75);
            float2 np = float2(ax * zq / m.lx, zq / m.lz) + m.seed;
            float M = m.top + m.amp * fbm(np, 3);
            float dn = clamp(0.8 + 1.1 * fbm(np * 0.55 + 3.1, 3), 0.03, 1.9);
            odM = pr_odMist(za, zb, b, m.S * dn * mScale, M, m.w);
            float wn = fbm(float2(ax * zq / (m.lx * 0.7), zq / (m.lz * 0.35)) + m.seed + 11.0, 3);
            float wd = m.S * 0.30 * mScale * smoothstep(0.0, 0.45, wn);
            if (wd > 0.0) {
                float band = 2.2 * m.amp + 2.0 * m.w;
                odM += max(pr_odMist(za, zb, b, wd, M + band, 0.3 * band) - pr_odMist(za, zb, b, wd, M + 0.15 * band, 0.2 * band), 0.0);
            }
        }
        float3 odc = odH * chroma;
        float3 odt = odc + odM;
        float3 tr = exp(-odt);
        F.acc += F.T * (airCol * odc + mistCol * odM) / max(odt, 1e-6) * (1.0 - tr);
        F.T *= tr;
        za = zb;
    }
}

// ------------------------------------------------------------ moon
constant float4 PR_MARIA[58] = {        // (latA, lonA, latB, lonB), (radius deg, darkness): capsules on the sphere
    float4(45.0, -50.0, 5.0, -60.0), float4(12.0, 0.88, 0, 0),
    float4(25.0, -45.0, 0.0, -50.0), float4(9.0, 0.85, 0, 0),
    float4(10.0, -40.0, -8.0, -45.0), float4(7.0, 0.80, 0, 0),
    float4(50.0, -40.0, 56.0, -56.0), float4(5.0, 0.75, 0, 0),
    float4(-3.0, -62.0, -10.0, -55.0), float4(6.0, 0.80, 0, 0),
    float4(35.0, -18.0, 35.0, -18.0), float4(16.0, 0.95, 0, 0),
    float4(28.0, -6.0, 25.0, 2.0), float4(5.0, 0.85, 0, 0),
    float4(45.0, -32.0, 45.0, -32.0), float4(5.0, 0.80, 0, 0),
    float4(55.0, -40.0, 60.0, -10.0), float4(4.0, 0.68, 0, 0),
    float4(60.0, -10.0, 57.0, 20.0), float4(4.0, 0.68, 0, 0),
    float4(57.0, 20.0, 54.0, 40.0), float4(3.5, 0.60, 0, 0),
    float4(28.0, 17.5, 28.0, 17.5), float4(10.0, 0.92, 0, 0),
    float4(13.0, 24.0, 4.0, 38.0), float4(9.0, 1.00, 0, 0),
    float4(2.0, 28.0, 2.0, 28.0), float4(7.0, 0.95, 0, 0),
    float4(13.0, 4.0, 13.0, 4.0), float4(4.0, 0.70, 0, 0),
    float4(2.0, 1.0, 2.0, 1.0), float4(3.0, 0.50, 0, 0),
    float4(-18.0, -20.0, -25.0, -12.0), float4(8.0, 0.75, 0, 0),
    float4(-10.0, -23.0, -10.0, -23.0), float4(5.0, 0.70, 0, 0),
    float4(8.0, -27.0, 11.0, -36.0), float4(6.0, 0.80, 0, 0),
    float4(-24.5, -38.5, -24.5, -38.5), float4(5.5, 0.85, 0, 0),
    float4(17.0, 59.0, 17.0, 59.0), float4(8.5, 1.00, 0, 0),
    float4(1.0, 50.0, -15.0, 52.0), float4(7.0, 0.85, 0, 0),
    float4(-15.0, 35.0, -15.0, 35.0), float4(4.5, 0.80, 0, 0),
    float4(5.0, 68.0, 5.0, 68.0), float4(3.0, 0.70, 0, 0),
    float4(-5.2, -68.6, -5.2, -68.6), float4(2.8, 1.00, 0, 0),
    float4(51.6, -9.4, 51.6, -9.4), float4(1.6, 1.00, 0, 0),
    float4(38.0, 30.0, 38.0, 30.0), float4(4.0, 0.50, 0, 0),
    float4(-32.0, -28.0, -32.0, -28.0), float4(3.0, 0.60, 0, 0),
    float4(-5.0, 27.0, -5.0, 27.0), float4(3.0, 0.70, 0, 0) };
constant float4 PR_CRATERS[10] = {      // lat, lon, halo radius (deg), brightness
    float4(-43.3, -11.2, 1.6, 0.55), float4(  9.6, -20.1, 1.3, 0.40), float4(  8.1, -38.0, 0.9, 0.30),
    float4( 23.7, -47.4, 0.8, 0.60), float4( 16.1,  46.8, 0.8, 0.30), float4( 16.3,  16.0, 0.7, 0.25),
    float4( -8.9,  61.0, 1.0, 0.20), float4(-32.5,  54.2, 0.8, 0.25), float4(-24.5, -63.7, 0.8, 0.25),
    float4( 73.4, -10.1, 1.0, 0.25) };
inline float3 pr_selen(float lat, float lon) {
    float a = lat * DEG, o = lon * DEG;
    return float3(cos(a) * sin(o), sin(a), cos(a) * cos(o));
}
// Albedo of the lunar near side; q = unit disk coords (north up, Crisium right)
inline float pr_moonAlbedo(float2 q) {
    float3 P0 = float3(q, sqrt(max(0.0, 1.0 - dot(q, q))));
    float3 P = normalize(P0 + 0.075 * float3(fbm(P0 * 3.5 + 1.1, 4), fbm(P0 * 3.5 + 5.3, 4), fbm(P0 * 3.5 + 9.7, 4))
                            + 0.025 * float3(fbm(P0 * 11.0 + 2.1, 3), fbm(P0 * 11.0 + 6.3, 3), fbm(P0 * 11.0 + 8.7, 3)));
    float warp = fbm(P * 5.0 + 2.7, 4);
    float warp2 = fbm(P * 16.0 + 9.1, 3);
    float m = 0.0;
    for (int i = 0; i < 29; i++) {
        float4 M = PR_MARIA[2 * i];
        float2 R = PR_MARIA[2 * i + 1].xy;
        float3 A = pr_selen(M.x, M.y), B = pr_selen(M.z, M.w);
        float3 AB = B - A;
        float hh = clamp(dot(P - A, AB) / max(dot(AB, AB), 1e-6), 0.0, 1.0);
        float d = length(P - A - AB * hh) / DEG;           // chord ~ angle (deg)
        float r = R.x * (1.0 + 0.22 * warp + 0.14 * warp2) * (0.85 + 0.3 * hh * (1.0 - hh) * 4.0 * (0.5 + 0.5 * warp2));
        float mi = R.y * smoothstep(r * 1.12, r * 0.80, d);
        m = 1.0 - (1.0 - m) * (1.0 - mi);
    }
    float tex = fbm(P * 9.0 + 7.7, 4);
    float mv = fbm(P * 5.0 + 1.9, 4) + 0.6 * fbm(P * 14.0 + 4.4, 3);
    float hl = fbm(P * 2.5 + 6.2, 3);
    float alb = mix(1.0 + 0.12 * tex + 0.10 * hl, 0.50 + 0.20 * mv, min(m, 1.0)) * (1.0 + 0.06 * fbm(P * 30.0, 3));
    // bright craters, haloes and ray systems
    for (int i = 0; i < 10; i++) {
        float4 C = PR_CRATERS[i];
        float3 c = pr_selen(C.x, C.y);
        float d = acos(clamp(dot(P, c), -1.0, 1.0)) / DEG;
        alb += C.w * exp(-d * d / (C.z * C.z * 0.35));
        if (i == 0) alb -= 0.07 * exp(-pow((d - 2.2) / 0.8, 2.0));
        if (i < 2) {
            float3 t1 = normalize(cross(c, float3(0.0, 1.0, 0.0)));
            float3 t2 = cross(c, t1);
            float ang = atan2(dot(P, t2), dot(P, t1));
            float rays = pow(max(0.0, gnoise(float2(ang * (i == 0 ? 4.0 : 6.0), 1.7 + float(i)))), 1.6) * (0.6 + 0.4 * gnoise(float2(ang * 13.0, d * 0.12)));
            alb += (i == 0 ? 0.30 : 0.18) * rays * exp(-d / (i == 0 ? 26.0 : 12.0)) * smoothstep(2.5, 6.0, d);
        }
    }
    // crater fields: small fresh bright craters (more in the highlands) and a few dark-floored ones
    for (int l = 0; l < 2; l++) {
        float sc = l == 0 ? 16.0 : 38.0;
        float2 cq = q * sc + float(l) * 17.3;
        float2 ci = floor(cq);
        float4 hc = hash24(ci + 5.0);
        float2 cp = ci + 0.2 + 0.6 * hc.xy;
        float cd = length(cq - cp);
        float cr = 0.10 + 0.14 * hc.z;
        float rim = exp(-pow((cd - cr) / (0.05 + 0.03 * hc.z), 2.0));
        float fl = smoothstep(cr, cr * 0.5, cd);
        float on = step(hc.w, l == 0 ? 0.55 : 0.45) * (1.0 - 0.65 * m);
        alb += on * step(0.8, hc.z) * 0.22 * exp(-cd * cd / 0.012) * (l == 0 ? 1.0 : 0.7);
    }
    return alb;
}

// ------------------------------------------------------------ sky
inline float3 pr_skyGrad(float t) {
    // keys at tw = 0,1/6..1 with tw = t^0.6 (denser near the horizon)
    float tw = pow(clamp(t, 0.0, 1.0), 0.6) * 6.0;
    int i = min(int(tw), 5);
    float f = tw - float(i);
    float3 k[7] = { pr_disp(0xa893ad), pr_disp(0xc493a0), pr_disp(0xa07fa6), pr_disp(0x72629c),
                    pr_disp(0x4a4787), pr_disp(0x2f306a), pr_disp(0x1f2254) };
    float3 p0 = k[max(i - 1, 0)], p1 = k[i], p2 = k[i + 1], p3 = k[min(i + 2, 6)];
    float f2 = f * f, f3 = f2 * f;   // Catmull-Rom
    return max(0.5 * ((2.0 * p1) + (-p0 + p2) * f + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f2 +
                      (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f3), 0.0);
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
    float2 uv = fragCoord / ctx.res;
    float k = tan(VFOV * 0.5 * DEG);
    float ax = p.x * k;
    float b  = (p.y + PY) * k;
    float bH = b + 14.0 * max(b, 0.0);             // haze thins quickly for rays above the horizon
    float pxA = 2.0 * k / ctx.res.y;               // radians per pixel
    float xs = p.x / ctx.aspect;                    // [-1,1] across the frame

    // --- moon geometry
    float2 dm = (p - MOON_P) * k / DEG;              // offset from moon centre (deg)
    float thM = length(dm);
    float gM = max(thM - MOON_R, 0.0);
    float3 moonCol = float3(1.0, 0.86, 0.70);

    // --- light / medium colours (scene-linear)
    float3 airCol  = pr_disp(0x9589a8);
    float3 mistCol = pr_disp(0xbdb5cb);
    float3 forest  = pr_disp(0x06070e);
    float moonPh   = 0.020 * exp(-gM / 0.6) + 0.012 * exp(-gM / 2.5);
    airCol  += moonCol * moonPh * 1.6;
    mistCol += moonCol * (0.16 * exp(-gM / 0.9) + 0.08 * exp(-gM / 3.0));
    const float3 chroma = float3(0.80, 0.93, 1.12);
    const float SH0 = 1.5e-5, HH = 700.0;

    PrFog F; F.T = float3(1.0); F.acc = float3(0.0);
    float zPrev = 1.0;

    for (int L = 0; L < NL; L++) {
        if (max(F.T.x, max(F.T.y, F.T.z)) < 0.004) break;
        float D = L_D[L];
        float dz = L_DZ[L];
        float zEnd = D + float(NBACK) * dz;
        float zBeg = D - float(L_ROWS[L] - 1) * dz;
        float TH = L_TH[L];
        float slope = L_SLOPE[L];
        int Lp = max(L - 1, 0);

        // valley L: broad haze pool (top near previous crest) + dense mist
        float vS = 0.0, vTop = 0.0, vW = 1.0;
        PrMist mist; mist.S = 0.0; mist.top = 0.0; mist.w = 1.0; mist.amp = 0.0; mist.lx = 1.0; mist.lz = 1.0; mist.seed = 0.0;
        if (L > 0) {
            float Dp = L_D[Lp];
            vS = 0.32 / (D - Dp);
            vW = 0.0035 * D;
            vTop = CAMH + Dp * tan(L_EL[Lp] * DEG) - 0.3 * vW;
            mist.S = 22.0 / D;
            mist.w = 2.5 + 0.0005 * D;
            mist.top = CAMH + zBeg * tan((L_EL[Lp] + L_MIST[L]) * DEG);
            mist.amp = 0.0009 * D;
            mist.lx = 160.0 + 0.045 * D;
            mist.lz = 120.0 + 0.06 * D;
            mist.seed = float(L) * 7.31;
        }

        float yAtD = CAMH + b * D;
        float layerMax = CAMH + D * tan((L_EL[L] + L_REL[L] * 1.3 + abs(L_TILT[L])) * DEG) + TH * 1.3 + 4.0;
        if (yAtD < layerMax) {
            float xD = ax * D;
            float prof = pr_profile(L, xD);
            float base = CAMH + D * tan(L_EL[L] * DEG) + D * tan(L_TILT[L] * DEG) * xs + D * tan(L_REL[L] * DEG) * prof;
            float spur = fbm(float2(xD / (L_SCL[L] * 0.12), 0.37 * float(L) + 4.0), 3);
            float stand = 0.84 + 0.30 * fbm(float2(xD / 70.0, float(L) * 1.7), 3);
            float bald = (L >= 1 && L <= 5) ? smoothstep(0.42, 0.58, fbm(float2(xD / (L_SCL[L] * 0.7), float(L) * 5.3 + 2.0), 3)) : 0.0;
            for (int jj = L_ROWS[L] - 1; jj >= -NBACK; jj--) {
                float j = float(jj);
                float z = D - j * dz;
                float y = CAMH + b * z;
                float x = ax * z;
                float drop = jj >= 0 ? slope * j * dz * (1.0 + 0.45 * spur) : 0.3 * slope * (-j) * dz * (1.0 - 0.1 * j);
                float g = base - drop;
                float bound = g + 0.5 * slope * dz + 2.0 + TH * stand * 1.25;
                if (y > bound) continue;
                g += 1.2 * gnoise(float2(x / 23.0, j * 0.71 + float(L) * 11.0));

                float fp = z * pxA * (1.0 + z / 9000.0);
                float rowSeed = float(L) * 97.0 + j * 13.0 + 0.5;
                // lower canopy: bumpy crowns of smaller trees
                float cn = gnoise(float2(x * 0.42, rowSeed));
                float fillTop = g + (1.0 - 0.85 * bald) * (TH * stand * (L_FILL[L] + 0.24 * smoothstep(1.0, 5.0, j)) + 3.2 * (1.0 - abs(cn)) - 1.6) + 0.8 * gnoise(float2(x * 1.3, rowSeed + 5.0));
                float best = fillTop - y;
                float tone = 0.1;
                if (best < fp) {
                    float dens = smoothstep(-0.75, 0.25, gnoise(float2(x / 28.0, float(L) * 3.1 + j * 0.23)));
                    float cs = L_CELL[L];
                    float ci = floor(x / cs);
                    for (int kk = -2; kk <= 2; kk++) {
                        float c = ci + float(kk);
                        float4 h = hash24(float2(c, rowSeed));
                        if (fract(h.y * 3.3 + h.w) > (0.3 + 0.68 * dens) * (1.0 - bald)) continue;   // clustered gaps, balds
                        float xk = (c + 0.5 + (h.x - 0.5) * 0.9) * cs;
                        float hv = L_HV[L];
                        float H = TH * stand * (1.1 - hv + hv * 1.5 * pow(h.y, 1.5));
                        float gb = g + (h.z - 0.5) * slope * dz;
                        float d = pr_tree(x - xk, y - gb, H, h, fp);
                        if (d > best) { best = d; tone = clamp((y - gb) / H, 0.0, 1.0) * (0.6 + 0.8 * fract(h.x * 9.7)); }
                    }
                }
                if (best < fp && bald < 0.5 && y - g < TH * stand * 0.75 + slope * dz) {
                    float cs2 = L_CELL[L] * 0.6;
                    float ci2 = floor(x / cs2 + 0.5);
                    for (int kk = -1; kk <= 1; kk++) {
                        float c = ci2 + float(kk);
                        float4 h = hash24(float2(c + 0.5, rowSeed + 71.0));
                        float xk = (c + (h.x - 0.5) * 0.9) * cs2;
                        float H = TH * stand * (0.38 + 0.30 * h.y);
                        float gb = g + (h.z - 0.5) * slope * dz;
                        float sd = H - (y - gb);
                        float wv = 0.19 * sd * (1.0 + 0.3 * gnoise(float2(sd * 0.9 + h.w * 30.0, h.x * 20.0 + step(xk, x))));
                        float d = sd < 0.0 ? 1.5 * sd - abs(x - xk) : wv - abs(x - xk);
                        if (d > best) { best = d; tone = clamp((y - gb) / H, 0.0, 1.0) * 0.7; }
                    }
                }
                float a = clamp(0.5 + best / fp, 0.0, 1.0);
                if (a <= 0.0) continue;

                if (zPrev < zBeg) {
                    float zm = min(z, zBeg);
                    pr_fogSeg(F, zPrev, zm, b, bH, ax, SH0, HH, chroma, vS, vTop, vW, mist, 1.0, airCol, mistCol);
                    zPrev = zm;
                }
                if (z > zPrev) pr_fogSeg(F, zPrev, z, b, bH, ax, SH0, HH, chroma, 0.0, vTop, vW, mist, 0.0, airCol, mistCol);
                zPrev = z;
                float3 fc = forest * (0.7 + 0.5 * tone);
                F.acc += F.T * a * fc;
                F.T *= 1.0 - a;
                if (max(F.T.x, max(F.T.y, F.T.z)) < 0.004) break;
            }
        }
        if (zEnd > zPrev && max(F.T.x, max(F.T.y, F.T.z)) >= 0.004) {
            if (zPrev < zBeg) {
                pr_fogSeg(F, zPrev, zBeg, b, bH, ax, SH0, HH, chroma, vS, vTop, vW, mist, 1.0, airCol, mistCol);
                zPrev = zBeg;
            }
            pr_fogSeg(F, zPrev, zEnd, b, bH, ax, SH0, HH, chroma, 0.0, vTop, vW, mist, 0.0, airCol, mistCol);
            zPrev = zEnd;
        }
    }
    float3 T = F.T;
    float3 acc = F.acc;

    if (max(T.x, max(T.y, T.z)) >= 0.004) {
        float t = clamp((p.y + PY) / (1.0 + PY), 0.0, 1.0);
        float3 sky = pr_skyGrad(t);
        // moon disk
        float rr = thM / MOON_R;
        if (rr < 1.03) {
            float2 q = ws_rot(-0.5) * (dm / MOON_R);
            float bl = 1.3 * pxA / (MOON_R * DEG);          // ~1.3 px optical softness
            float alb = 0.4 * pr_moonAlbedo(q) + 0.15 * (pr_moonAlbedo(q + float2(bl, 0.0)) + pr_moonAlbedo(q - float2(bl, 0.0))
                                                       + pr_moonAlbedo(q + float2(0.0, bl)) + pr_moonAlbedo(q - float2(0.0, bl)));
            float mu = sqrt(max(0.0, 1.0 - rr * rr));
            float limb = 0.84 + 0.16 * pow(mu, 0.5);
            float edgeW = 1.2 * pxA / (MOON_R * DEG);
            float edge = clamp((1.0 - rr) / edgeW + 0.5, 0.0, 1.0);
            float ext = 1.0 - 0.10 * (1.0 - clamp(dm.y / MOON_R * 0.5 + 0.5, 0.0, 1.0));   // lower limb through more air
            float3 mc = pr_dispF(float3(0.925, 0.905, 0.865) * pow(max(alb * limb * ext, 0.0), 0.9) * mix(float3(1.0, 0.94, 0.88), float3(1.0), ext * 10.0 - 9.0));
            sky = mix(sky, mc, edge);
        }
        sky += moonCol * (0.14 * exp(-gM / 0.06) + 0.08 * exp(-gM / 0.30) + 0.045 * exp(-gM / 1.5));
        // sparse faint stars (upper sky only)
        float2 sq = p * 9.0;
        float2 id = floor(sq);
        float4 hs = hash24(id + 3.0);
        if (hs.x < 0.16) {
            float2 spos = id + 0.5 + (hs.yz - 0.5) * 0.7;
            float d = length(sq - spos) / 9.0;
            float sig = max(0.75 * pxA / k, 0.0006);
            float st = exp(-d * d / (2.0 * sig * sig)) * (0.015 + 0.20 * pow(hs.w, 5.0));
            float3 tint = mix(float3(1.0, 0.85, 0.72), float3(0.82, 0.88, 1.0), hs.y);
            sky += tint * st * smoothstep(0.35, 0.8, t) * (1.0 - 0.6 * smoothstep(0.55, 1.2, p.x));
        }
        acc += T * sky;
    }

    float3 col = acc;
    col *= ws_vignette(uv, 0.30);
    col = ws_acesFitted(col);
    col += ws_grain(fragCoord, ctx.t) * 0.005 * sqrt(max(col, 0.0));
    return col;
}
