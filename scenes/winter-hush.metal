// =====================================================================
//  Winter Hush — blue hour in a silent, snowing spruce forest.
//
//  Eye-level 30° lens across a snow clearing: snow-laden spruces frame
//  the left edge and recede as a diagonal forest edge; a log cabin at
//  44 m (ray-traced convex solids: log walls, snow-loaded gable roof,
//  chimney) glows warm through its windows; a wall of spruce rows from
//  64 m to 300 m fades into chromatic height haze and drifting ground
//  mist. Ten depth layers of snowflakes fall with thin-lens bokeh
//  (near flakes = soft translucent discs, far = tiny), swaying and
//  drifting — every motion is an integer number of cycles per loop.
// =====================================================================

constant float DEG   = 0.017453292519943295;
constant float VFOV  = 30.0;      // vertical field of view (deg)
constant float PY    = 0.14;      // lens shift: horizon at 43% height
constant float CAMH  = 1.7;       // eye height (m)
constant float ZF    = 44.0;      // focus distance (m)
constant float APER  = 0.011;     // aperture diameter (m)
constant float EXPO  = 1.7;

// ---- forest rows (depth along the forward axis, m)
constant int   NROWS = 22;
constant float ROW_Z[22] = { 5.0, 6.8, 9.0, 11.8, 15.0, 19.0, 24.0, 30.0, 37.0, 45.0, 54.0,
                             64.0, 74.0, 86.0, 100.0, 116.0, 134.0, 155.0, 180.0, 210.0, 245.0, 290.0 };
constant float TREE_H = 14.0;

// ---- snowflake layers
constant int   NFL = 10;
constant float FL_Z[10] = { 0.55, 0.85, 1.3, 2.0, 3.0, 4.5, 6.8, 10.0, 15.0, 23.0 };
constant float FL_C[10] = { 0.30, 0.32, 0.34, 0.36, 0.40, 0.45, 0.55, 0.65, 0.80, 1.00 };
constant int   FL_K[10] = { 12, 12, 12, 12, 11, 10, 9, 8, 7, 6 };   // cells fallen per loop
constant float FLAKE_R = 0.0028;                                     // flake radius (m)

// ---- cabin (local frame: u = width, y = up, v = depth; floor buried 0.5 m)
constant float3 CAB_C   = float3(6.5, -0.5, 44.0);
constant float  CAB_YAW = 25.0 * DEG;
constant float  CAB_W   = 3.0;    // half width
constant float  CAB_D   = 3.6;    // half depth
constant float  CAB_WH  = 3.0;    // eave height
constant float  CAB_RH  = 4.7;    // ridge height
constant float  CAB_OV  = 0.45;   // roof overhang
constant float  CAB_ST  = 0.32;   // snow on the roof
constant float  CAB_RT  = 0.22;   // roof board thickness

// ---- fog
constant float S_HAZE = 0.0085, H_HAZE = 30.0;
constant float S_MIST = 0.022, MIST_TOP = 3.2, MIST_W = 1.4;

// ---- colours (linear)
constant float3 SKY_Z   = float3(0.050, 0.072, 0.150);
constant float3 SKY_H   = float3(0.175, 0.205, 0.300);
constant float3 FOGC    = float3(0.165, 0.195, 0.280);
constant float3 SKY_E   = float3(0.125, 0.150, 0.235);   // hemispherical sky irradiance / pi
constant float3 SNOW_A  = float3(0.80, 0.86, 0.94);
constant float3 WARM    = float3(1.00, 0.46, 0.13);      // ~2300 K
constant float3 FOL_A   = float3(0.030, 0.052, 0.036);

// ------------------------------------------------------------ helpers
inline float wh_softplus(float x) { return x > 15.0 ? x : log(1.0 + exp(x)); }

// gradient noise periodic along y (integer period) — for scrolling smoke
inline float wh_pnoise(float2 p, int py) {
    float2 i = floor(p); float2 f = p - i; int2 c = int2(i);
    float2 u = ws_q5(f);
    int y0 = ws_wrap(c.y, py), y1 = ws_wrap(c.y + 1, py);
    float a = dot(ws_g2(int2(c.x, y0)), f);
    float b = dot(ws_g2(int2(c.x + 1, y0)), f - float2(1, 0));
    float d = dot(ws_g2(int2(c.x, y1)), f - float2(0, 1));
    float e = dot(ws_g2(int2(c.x + 1, y1)), f - float2(1, 1));
    return 1.4142 * mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}
inline float wh_fbmScroll(float2 p, float t, int oct, int P) {
    float s = 0.0, a = 0.5, n = 0.0, sc = 1.0; int per = P;
    for (int i = 0; i < oct; i++) {
        s += a * wh_pnoise(float2(p.x * sc + 17.0 * float(i), (p.y - t * float(P)) * sc), per); n += a;
        sc *= 2.0; per *= 2; a *= 0.5;
    }
    return s / n;
}

// ------------------------------------------------------------ terrain
inline float wh_rise(float z) { return 0.012 * max(z - 30.0, 0.0); }
inline float wh_edgeL(float z) { return -3.4 - 0.15 * z + 1.5 * gnoise(float2(z * 0.045, 1.7)); }
inline float wh_edgeR(float z) { return  4.0 + 0.36 * z + 2.5 * gnoise(float2(z * 0.040, 7.3)); }

inline float wh_gCoarse(float2 xz) {
    return 0.22 * gnoise(xz * 0.16 + 3.1) + 0.09 * gnoise(xz * 0.42 + 7.7) + wh_rise(xz.y);
}
inline float wh_gFull(float2 xz, float fp) {
    float g = wh_gCoarse(xz);
    float med = 1.0 - smoothstep(0.02, 0.12, fp);
    if (med > 0.0) g += med * (0.030 * gnoise(xz * 1.7 + 1.3) + 0.012 * gnoise(xz * 4.6 + 9.2));
    float fine = 1.0 - smoothstep(0.004, 0.02, fp);
    if (fine > 0.0) g += fine * 0.0035 * gnoise(xz * 22.0 + 4.4);
    return g;
}
// depth (along forward axis) of the ground hit, or -1
inline float wh_groundHit(float ax, float b) {
    if (b > -0.0045) return -1.0;
    float z = (0.45 - CAMH) / b;
    if (z > 30.0) z = (0.45 - 0.36 - CAMH) / (b - 0.012);
    z = max(z, 0.05);
    for (int i = 0; i < 44; i++) {
        float zn = z + 0.04 + 0.11 * z;
        float d = CAMH + b * zn - wh_gCoarse(float2(ax * zn, zn));
        if (d < 0.0) {
            float za = z, zb = zn;
            for (int j = 0; j < 5; j++) {
                float zm = 0.5 * (za + zb);
                float dm = CAMH + b * zm - wh_gCoarse(float2(ax * zm, zm));
                if (dm < 0.0) zb = zm; else za = zm;
            }
            return 0.5 * (za + zb);
        }
        z = zn;
        if (z > 160.0) return 160.0;
    }
    return 160.0;
}

// ------------------------------------------------------------ fog
inline float wh_odHaze(float zA, float zB, float b) {
    float k = b / H_HAZE;
    float base = S_HAZE * exp(-CAMH / H_HAZE);
    if (abs(k * (zB - zA)) < 1e-4) return base * exp(-k * 0.5 * (zA + zB)) * (zB - zA);
    return base * (exp(-k * zA) - exp(-k * zB)) / k;
}
inline float wh_odMist(float zA, float zB, float b, float S, float M, float w) {
    float u1 = (CAMH + b * zA - M) / w, u2 = (CAMH + b * zB - M) / w;
    if (abs(u2 - u1) < 1e-3) return S * (zB - zA) / (1.0 + exp(0.5 * (u1 + u2)));
    return S * (w / b) * (wh_softplus(-u1) - wh_softplus(-u2));
}
inline void wh_fog(thread float3 &acc, thread float3 &T, float zA, float zB, float ax, float b,
                   float len, float t, float3 fogCol) {
    if (zB <= zA) return;
    float odH = wh_odHaze(zA, zB, b) * len;
    float odM = 0.0;
    float yLo = min(CAMH + b * zA, CAMH + b * zB);
    if (yLo < MIST_TOP + 5.0 * MIST_W) {
        float zq = mix(zA, zB, 0.6);
        float dn = clamp(0.75 + 0.9 * fbmLoop(float2(ax * zq, zq) * 0.045 + 2.0, t, 2, 1), 0.1, 1.8);
        odM = wh_odMist(zA, zB, b, S_MIST * dn, MIST_TOP, MIST_W) * len;
    }
    float3 od = odH * float3(0.85, 1.0, 1.2) + odM;
    float3 tr = exp(-od);
    acc += T * fogCol * (1.0 - tr);
    T *= tr;
}

// ------------------------------------------------------------ lights (cabin windows)
struct WhLight { float3 pos; float3 nrm; float I; };
inline float3x3 wh_cabRot() {
    float c = cos(CAB_YAW), s = sin(CAB_YAW);
    return float3x3(float3(c, 0.0, -s), float3(0.0, 1.0, 0.0), float3(s, 0.0, c));   // columns: local u, y, v -> world
}
inline void wh_lights(thread WhLight *L) {
    float3x3 R = wh_cabRot();
    float3 nF = R * float3(0.0, 0.0, -1.0);     // front face normal (gable, -v)
    float3 nS = R * float3(1.0, 0.0, 0.0);      // +u side face
    L[0].pos = CAB_C + R * float3(-1.65, 1.85, -CAB_D - 0.08); L[0].nrm = nF; L[0].I = 2.6;
    L[1].pos = CAB_C + R * float3( 1.65, 1.85, -CAB_D - 0.08); L[1].nrm = nF; L[1].I = 2.6;
    L[2].pos = CAB_C + R * float3( 0.0,  2.75, -CAB_D - 0.12); L[2].nrm = nF; L[2].I = 0.9;   // porch lamp
    L[3].pos = CAB_C + R * float3( CAB_W + 0.08, 1.85, -1.3);  L[3].nrm = nS; L[3].I = 2.2;
    L[4].pos = CAB_C + R * float3( CAB_W + 0.08, 1.85,  1.3);  L[4].nrm = nS; L[4].I = 2.2;
}
inline float3 wh_warm(float3 P, float3 n, thread WhLight *L, float wrap) {
    float3 e = float3(0.0);
    for (int i = 0; i < 5; i++) {
        float3 d = L[i].pos - P;
        float d2 = max(dot(d, d), 0.25);
        float3 l = d * rsqrt(d2);
        float em = max(dot(L[i].nrm, -l), 0.0);
        float nl = max(dot(n, l) * (1.0 - wrap) + wrap, 0.0);
        e += L[i].I * em * nl / d2;
    }
    return WARM * e;
}

// ------------------------------------------------------------ spruce silhouette
// signed horizontal distance (m, + inside); snow mask & top-lit factor
inline float wh_tree(float dx, float dy, float H, float4 h, float fp, thread float &snow, thread float &lit) {
    float s = H - dy;
    snow = 0.0; lit = 0.0;
    if (s < 0.0) return 1.5 * s - abs(dx);
    float h5 = fract(h.w * 13.7), h6 = fract(h.z * 3.7), h8 = fract(h.x * 5.13);
    dx -= (h.x - 0.5) * 0.03 * s + 0.10 * (h8 - 0.5) * sin(s * 0.5 + h5 * 6.0) * min(s * 0.15, 1.0);
    float adx = abs(dx);
    float side = dx > 0.0 ? 1.0 : -1.0;
    float taper = 0.165 * (0.75 + 0.5 * h6);
    float lead = 0.7 * (0.5 + 0.9 * h5);
    float env = max(0.03 + 0.012 * s, taper * (s - 0.6 * lead)) * (1.0 + side * (h8 - 0.5) * 0.25);
    env *= 1.0 + 0.20 * gnoise(float2(s * 0.3 + h.x * 40.0, side * 3.7 + h.y * 13.0));
    float sp = (0.48 + 0.03 * s) * (0.8 + 0.4 * h.z);
    float q = max(s - lead * 0.8, 0.0) / sp + h.w * 3.0 + 0.4 * gnoise(float2(s * 0.45 + h.x * 17.0, side * 2.1));
    float n = floor(q), ph = fract(q);
    float hb = hash12(float2(n + h.x * 131.0, side + h.y * 71.0));
    float Lb = 0.55 + 0.55 * hb;
    float tier = Lb * (0.32 + 0.68 * pow(ph, 0.6)) * (1.0 - 0.38 * smoothstep(0.78, 1.0, ph));
    float detail = 1.0 - smoothstep(sp * 0.25, sp * 0.9, fp);
    float w = env * mix(0.8, tier, detail);
    float rag = 0.6 * gnoise(float2(s * 2.3 + h.z * 17.0, side * 5.0 + h.x * 9.0 + n * 0.37))
              + 0.4 * gnoise(float2(s * 6.1 + h.y * 23.0, side * 11.0 + n * 0.71));
    float fine = 1.0 - smoothstep(0.08, 0.3, fp);
    w += env * detail * (0.12 + 0.09 * fine) * rag;
    float vfine = 1.0 - smoothstep(0.01, 0.05, fp);
    if (vfine > 0.0) w += env * vfine * 0.05 * gnoise(float2(s * 17.0 + h.y * 9.0, dx * 14.0 + n * 1.3));
    // snow skirt at the base
    float skirt = smoothstep(1.4, 0.0, dy);
    w += 0.9 * skirt * skirt;
    float d = w - adx;
    // snow: outer/upper parts of each tier; dark underside band
    float r = adx / max(w, 0.02);
    float patches = 0.5 + 0.5 * gnoise(float2(s * 1.6 + h.x * 50.0, dx * 1.7 + h.y * 30.0));
    float under = smoothstep(0.72, 1.0, ph) * (1.0 - smoothstep(0.80, 1.0, r));
    float sn = smoothstep(0.10, 0.85, r) * (0.55 + 0.45 * patches) * (1.0 - 0.75 * under) * detail
             + 0.25 * (1.0 - detail);
    sn = smoothstep(0.30, 0.62, sn + 0.12 * patches);
    snow = max(sn, skirt);
    lit = mix(0.35, 1.0, (1.0 - ph)) * mix(0.55, 1.0, r);
    lit = mix(lit, 0.75, skirt);
    return d;
}

// ------------------------------------------------------------ cabin (convex solids)
struct WhHit { float t; int face; float3 n; float3 pl; };
// planes: inside if dot(n, p) <= d ; returns entering t and plane index
inline bool wh_convex(float3 ro, float3 rd, constant float4 *pl, int np, thread float &tN, thread float &tF, thread int &iN) {
    tN = -1e9; tF = 1e9; iN = -1;
    for (int i = 0; i < np; i++) {
        float3 n = pl[i].xyz; float d = pl[i].w;
        float den = dot(n, rd), num = d - dot(n, ro);
        if (abs(den) < 1e-7) { if (num < 0.0) return false; continue; }
        float t = num / den;
        if (den > 0.0) { if (t < tF) tF = t; }
        else { if (t > tN) { tN = t; iN = i; } }
        if (tN > tF) return false;
    }
    return tF > 0.0 && tN < tF;
}
constant float4 WH_WALL[6] = {
    float4( 1.0, 0.0, 0.0, CAB_W), float4(-1.0, 0.0, 0.0, CAB_W),
    float4( 0.0, 0.0, 1.0, CAB_D), float4( 0.0, 0.0,-1.0, CAB_D),
    float4( 0.0, 1.0, 0.0, CAB_WH + 0.05), float4( 0.0,-1.0, 0.0, 0.6) };
constant float WH_SLOPE = (CAB_RH - CAB_WH) / CAB_W;
constant float WH_SN = 1.0 / sqrt(1.0 + WH_SLOPE * WH_SLOPE);
constant float4 WH_ROOF[8] = {
    float4( 1.0, 0.0, 0.0, CAB_W + CAB_OV), float4(-1.0, 0.0, 0.0, CAB_W + CAB_OV),
    float4( 0.0, 0.0, 1.0, CAB_D + CAB_OV), float4( 0.0, 0.0,-1.0, CAB_D + CAB_OV),
    float4( WH_SLOPE * WH_SN, WH_SN, 0.0, (CAB_RH + CAB_ST) * WH_SN),
    float4(-WH_SLOPE * WH_SN, WH_SN, 0.0, (CAB_RH + CAB_ST) * WH_SN),
    float4(-WH_SLOPE * WH_SN,-WH_SN, 0.0, -(CAB_RH - CAB_RT) * WH_SN),
    float4( WH_SLOPE * WH_SN,-WH_SN, 0.0, -(CAB_RH - CAB_RT) * WH_SN) };
constant float2 CHIM = float2(1.0, 0.9);   // (u, v) of the chimney
constant float4 WH_CHIM[6] = {
    float4( 1.0, 0.0, 0.0, CHIM.x + 0.36), float4(-1.0, 0.0, 0.0, -CHIM.x + 0.36),
    float4( 0.0, 0.0, 1.0, CHIM.y + 0.36), float4( 0.0, 0.0,-1.0, -CHIM.y + 0.36),
    float4( 0.0, 1.0, 0.0, CAB_RH + 1.15), float4( 0.0,-1.0, 0.0, -(CAB_RH - 1.5)) };

// window rectangle mask helpers (local wall coords a = along, y = up)
inline float wh_rect(float2 p, float2 c, float2 h) {
    float2 d = abs(p - c) - h;
    return max(d.x, d.y);   // <0 inside
}

// shade a cabin hit; P local point, face normal local, returns radiance
inline float3 wh_cabinShade(int solid, int face, float3 Pl, float3 nl, float3x3 R, thread WhLight *L, float fp, float t) {
    float3 nW = R * nl;
    float3 Pw = CAB_C + R * Pl;
    float skyUp = 0.5 + 0.5 * nW.y;
    float3 col = float3(0.0);
    if (solid == 0) {                      // ---- log walls
        bool gable = (face == 2 || face == 3);
        float a = gable ? Pl.x : Pl.z;                  // along-wall coord
        float logH = 0.31;
        float ly = (Pl.y + 0.6) / logH;
        float li = floor(ly), lf = fract(ly);
        float prof = sin(PI * lf);
        float ny = -cos(PI * lf);
        float grain = 0.5 + 0.5 * gnoise(float2(a * 9.0 + li * 3.1, Pl.y * 40.0));
        float3 wood = float3(0.19, 0.115, 0.065) * (0.75 + 0.35 * grain) * (0.55 + 0.45 * prof);
        float chink = smoothstep(0.06, 0.14, lf) * smoothstep(0.98, 0.90, lf);
        wood = mix(wood * 0.35, wood, chink);
        float3 alb = wood;
        float snowLine = smoothstep(0.70, 0.86, lf) * (0.6 + 0.4 * gnoise(float2(a * 6.0, li * 7.0)));
        snowLine = smoothstep(0.35, 0.75, snowLine);
        alb = mix(alb, SNOW_A, snowLine);
        float nyEff = mix(ny, 0.8, snowLine);
        float3 E = SKY_E * (0.5 + 0.5 * nyEff) * 0.55;    // walls see half the sky, occluded by eaves
        E *= 0.6 + 0.4 * smoothstep(-0.2, 1.4, Pl.y);      // snow bank / ground occlusion at the base
        // window rectangles on the front (gable) face and the +u side
        float2 wp = float2(a, Pl.y);
        float glass = 1.0, frame = 1.0, door = 1.0;
        float2 wh = float2(0.50, 0.55);
        if (face == 3) {                                   // front gable (-v)
            glass = min(wh_rect(wp, float2(-1.65, 1.85), wh), wh_rect(wp, float2(1.65, 1.85), wh));
            door = wh_rect(wp, float2(0.0, 1.35), float2(0.48, 1.05));
            glass = min(glass, wh_rect(wp, float2(0.0, 3.55), float2(0.28, 0.32)));   // small gable window
        } else if (face == 0) {                            // +u side
            glass = min(wh_rect(wp, float2(-1.3, 1.85), wh), wh_rect(wp, float2(1.3, 1.85), wh));
        }
        frame = glass - 0.09;
        float3 spill = wh_warm(Pw, nW, L, 0.35) * 0.5;     // warm glow on the wall around windows
        col = alb * (E + spill);
        if (door < 0.0) {
            float3 dcol = float3(0.11, 0.07, 0.04) * (0.7 + 0.3 * gnoise(float2(a * 30.0, Pl.y * 3.0)));
            float planks = 0.8 + 0.2 * smoothstep(0.02, 0.06, abs(fract(a * 4.0) - 0.5));
            col = dcol * planks * (E * 0.8 + spill);
            float knob = smoothstep(0.05, 0.03, length(wp - float2(0.34, 1.3)));
            col = mix(col, float3(0.4, 0.3, 0.15) * (E + spill), knob);
        }
        if (frame < 0.0) {                                 // window frame + sill (snow dusted)
            float3 fcol = mix(float3(0.35, 0.30, 0.24), SNOW_A, smoothstep(-0.05, 0.05, -(wp.y - (1.85 - 0.55 - 0.02))) * 0.0);
            col = fcol * (E * 1.1 + spill * 1.2);
            float sill = smoothstep(0.0, -0.06, glass) * smoothstep(1.85 - 0.55 - 0.10, 1.85 - 0.55 - 0.03, wp.y) * step(wp.y, 1.85 - 0.55 + 0.02);
            col = mix(col, SNOW_A * SKY_E * 0.9, sill);
        }
        if (glass < 0.0) {                                 // glowing interior
            float2 lw = wp - float2(round(wp.x / 1.65) * 1.65, 1.85);
            if (face == 0) lw = wp - float2(round(wp.x / 1.3) * 1.3, 1.85);
            if (face == 3 && wp.y > 3.0) lw = wp - float2(0.0, 3.55);
            float mull = min(abs(lw.x), abs(lw.y));
            float bar = smoothstep(0.02, 0.035, mull);
            float curtain = 0.75 + 0.25 * gnoise(float2(lw.x * 5.0, lw.y * 1.5 + 3.0));
            curtain *= 0.85 + 0.15 * smoothstep(-0.5, 0.5, lw.y);
            float warmth = 0.85 + 0.15 * sin(TAU * (t * 2.0 + lw.x));                 // slow lamp flicker
            float3 g = WARM * 7.0 * curtain * warmth;
            g = mix(g, float3(1.0, 0.75, 0.45) * 5.0, 0.35 * smoothstep(0.2, 0.5, abs(lw.x)));
            col = mix(float3(0.02, 0.012, 0.006), g, bar);
        }
        // porch lamp
        float2 lp = float2(0.0, 2.75);
        if (face == 3) {
            float dl = length(wp - lp);
            col += WARM * 9.0 * smoothstep(0.10, 0.06, dl);
            col = mix(col, float3(0.05, 0.04, 0.03), smoothstep(0.13, 0.10, dl) * smoothstep(0.09, 0.12, dl));
        }
    } else if (solid == 1) {               // ---- roof
        if (face == 4 || face == 5) {      // snow top surfaces
            float2 sp = float2(Pl.x, Pl.z);
            float und = 0.03 * gnoise(sp * 1.5 + 2.0) + 0.012 * gnoise(sp * 5.0 + 6.0);
            float3 n2 = normalize(nW + float3(und * 3.0, 0.0, und * 2.0));
            float edgeU = smoothstep(0.55, 0.0, (CAB_W + CAB_OV) - abs(Pl.x));
            float edgeV = smoothstep(0.35, 0.0, (CAB_D + CAB_OV) - abs(Pl.z));
            float ny = mix(n2.y, 0.35, max(edgeU, edgeV) * 0.7);   // rounded snow lip
            float3 E = SKY_E * (0.5 + 0.5 * ny) * (0.85 + 0.15 * gnoise(sp * 0.7));
            col = SNOW_A * E;
            col += SNOW_A * wh_warm(Pw, n2, L, 0.2) * 0.3;
        } else if (face == 6 || face == 7) {   // underside of the roof boards
            col = float3(0.05, 0.035, 0.022) * SKY_E * 0.5 + float3(0.05, 0.035, 0.022) * wh_warm(Pw, nW, L, 0.3);
        } else {                            // roof edge faces: snow layer above the board
            float yTop = CAB_RH + CAB_ST - WH_SLOPE * abs(Pl.x);
            float dTop = yTop - Pl.y;
            float snowPart = smoothstep(CAB_ST + 0.02, CAB_ST - 0.02, dTop);
            float lip = 0.35 + 0.65 * smoothstep(CAB_ST * 0.9, 0.0, dTop);    // rounded: brighter toward the top
            float3 sn = SNOW_A * SKY_E * (0.45 + 0.4 * lip) * (0.9 + 0.1 * gnoise(float2(Pl.z * 6.0, Pl.x * 6.0)));
            float3 board = float3(0.07, 0.045, 0.03) * SKY_E * 0.6;
            col = mix(board, sn, snowPart);
            col += mix(board, SNOW_A, snowPart) * wh_warm(Pw, nW, L, 0.3) * 0.5;
            // icicles
            float ic = gnoise(float2((face < 2 ? Pl.z : Pl.x) * 9.0, 3.0));
            float icl = smoothstep(0.3, 0.7, ic) * smoothstep(CAB_ST + 0.30, CAB_ST + 0.02, dTop) * step(CAB_ST, dTop);
            col = mix(col, SNOW_A * SKY_E * 0.7, icl * 0.8);
        }
    } else {                               // ---- chimney
        float2 sp = float2(Pl.x + Pl.z, Pl.y);
        float stone = 0.5 + 0.5 * gnoise(sp * 6.0);
        float3 alb = float3(0.16, 0.14, 0.13) * (0.6 + 0.5 * stone);
        float mortar = smoothstep(0.42, 0.5, worley(sp * 4.0).x);
        alb *= mix(0.55, 1.0, mortar);
        float capY = CAB_RH + 1.15;
        float snowCap = smoothstep(0.16, 0.04, capY - Pl.y) * 0.9 + step(0.99, nl.y);
        alb = mix(alb, SNOW_A, clamp(snowCap, 0.0, 1.0));
        float ny = mix(nW.y, 0.9, clamp(snowCap, 0.0, 1.0));
        col = alb * SKY_E * (0.5 + 0.5 * ny) * 0.9;
    }
    return col;
}

// ------------------------------------------------------------ smoke plume (loop-safe)
inline float wh_smoke(float2 xy, float3 top, float t) {
    float dh = xy.y - top.y;
    if (dh < -0.1 || dh > 12.0) return 0.0;
    float sway = 0.22 * sin(1.1 * dh - TAU * (t + 0.3)) + 0.12 * sin(2.3 * dh + TAU * (2.0 * t + 0.1));
    float xc = top.x + 0.42 * dh + 0.018 * dh * dh + sway * min(dh * 0.8, 1.0);
    float width = 0.20 + 0.36 * dh;
    float dxp = (xy.x - xc) / width;
    float g = exp(-1.8 * dxp * dxp);
    float dens = exp(-dh / 4.2) * (1.0 - exp(-(dh + 0.1) / 0.45));
    float tex = 0.5 + 0.5 * wh_fbmScroll(float2(xy.x - xc, dh) * float2(2.2, 1.0), t, 3, 6);
    tex = smoothstep(0.25, 0.85, tex + 0.15 * (1.0 - min(dh, 1.0)));
    return g * dens * tex;
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
    float2 uv = fragCoord / ctx.res;
    float t = ctx.t;
    float k = tan(VFOV * 0.5 * DEG);
    float ax = p.x * k;
    float b  = (p.y + PY) * k;
    float pxA = 2.0 * k / ctx.res.y;                 // radians per pixel
    float len = sqrt(1.0 + ax * ax + b * b);
    float3 rdn = float3(ax, b, 1.0) / len;
    float3 ro = float3(0.0, CAMH, 0.0);

    WhLight L[5];
    wh_lights(L);
    float3x3 R = wh_cabRot();
    float3 fogCol = FOGC;

    // ---- cabin intersection (parameter = forward depth z)
    float zCab = 1e9; int cabSolid = -1, cabFace = -1; float3 cabPl = float3(0.0), cabNl = float3(0.0);
    float3 dirZ = float3(ax, b, 1.0);
    {
        float3 rel = CAB_C - ro;
        float3 cl = rel - dirZ * dot(rel, dirZ) / dot(dirZ, dirZ);
        float3 roL = transpose(R) * (ro - CAB_C);
        float3 rdL = transpose(R) * dirZ;
        if (dot(cl, cl) < 64.0) {
            float tN, tF; int iN;
            if (wh_convex(roL, rdL, WH_WALL, 6, tN, tF, iN) && tN < zCab) { zCab = tN; cabSolid = 0; cabFace = iN; cabNl = WH_WALL[iN].xyz; }
            if (wh_convex(roL, rdL, WH_ROOF, 8, tN, tF, iN) && tN < zCab) { zCab = tN; cabSolid = 1; cabFace = iN; cabNl = WH_ROOF[iN].xyz; }
            if (wh_convex(roL, rdL, WH_CHIM, 6, tN, tF, iN) && tN < zCab) { zCab = tN; cabSolid = 2; cabFace = iN; cabNl = WH_CHIM[iN].xyz; }
            if (cabSolid >= 0) cabPl = roL + rdL * zCab;
        }
    }
    // smoke plume lives at the chimney depth
    float3 chimTop = CAB_C + R * float3(CHIM.x, CAB_RH + 1.15, CHIM.y);
    float zSmoke = chimTop.z;
    float2 smokeXY = float2(ax * zSmoke, CAMH + b * zSmoke);
    bool smokeOn = (smokeXY.y > chimTop.y - 0.2 && smokeXY.y < chimTop.y + 12.0 && smokeXY.x > chimTop.x - 2.0 && smokeXY.x < chimTop.x + 9.0);
    float zEvent = (cabSolid >= 0) ? zCab : (smokeOn ? zSmoke : 1e9);
    if (cabSolid >= 0 && smokeOn) zEvent = min(zCab, zSmoke);

    float zG = wh_groundHit(ax, b);
    if (zG < 0.0) zG = 1e9;

    float3 acc = float3(0.0), T = float3(1.0);
    float zPrev = 0.0;
    float3 Thalo = float3(0.0); bool haloSet = false;
    int ri = 0, fi = 0; bool cabDone = false; bool opaque = false;

    for (int it = 0; it < 48; it++) {
        float zRow = ri < NROWS ? ROW_Z[ri] : 1e9;
        float zFl = fi < NFL ? FL_Z[fi] : 1e9;
        float zC = cabDone ? 1e9 : zEvent;
        float zn = min(min(zRow, zFl), min(zC, zG));
        if (zn > 1e8) break;
        wh_fog(acc, T, zPrev, zn, ax, b, len, t, fogCol);
        zPrev = zn;
        if (!haloSet && zn >= 40.0) { Thalo = T; haloSet = true; }

        if (zn == zFl) {
            // ---------------- snowflake layer
            float z = zn; float C = FL_C[fi]; int K = FL_K[fi];
            float2 w = float2(ax * z, CAMH + b * z);
            float thB = 0.5 * APER * abs(z - ZF) / (z * ZF);          // bokeh radius (rad)
            float thF = FLAKE_R / z;                                   // flake radius (rad)
            float thT = max(sqrt(thF * thF + thB * thB), 0.9 * pxA);
            float eA = clamp((thF * thF) / (thT * thT) * 1.6, 0.0, 1.0);
            float3 Pf = float3(w, z);
            float3 lightF = SNOW_A * (SKY_E * 1.25 + wh_warm(Pf, float3(0.0, 0.0, -1.0), L, 0.6) * 0.8);
            int nsub = fi < 5 ? 2 : 1;
            for (int sub = 0; sub < nsub; sub++) {
                float2 cc = w / C + float2(t * 2.0, t * float(K)) + float2(0.5 * float(sub), 0.31 * float(sub) + 7.0 * float(fi));
                float2 id = floor(cc), f = cc - id;
                float4 h = hash24(id + float(sub) * 37.0 + float(fi) * 101.0);
                if (h.w < 0.40) continue;
                float m = 1.0 + floor(h.z * 2.0);
                float2 pos = 0.5 + (h.xy - 0.5) * 0.55;
                pos.x += 0.10 * sin(TAU * (t * m + h.z * 7.0));
                pos.y += 0.03 * sin(TAU * (t * 2.0 * m + h.x * 5.0));
                float dAng = length(f - pos) * C / z;
                float sh = smoothstep(thT, thT * 0.55, dAng);
                if (thB > thF) {  // bokeh disc: flatter profile, faint bright rim
                    float rr = dAng / thT;
                    sh = (1.0 - smoothstep(0.82, 1.02, rr)) * (0.82 + 0.28 * smoothstep(0.55, 0.95, rr));
                }
                float a = sh * eA * (0.6 + 0.4 * h.z);
                if (a <= 0.0) continue;
                acc += T * a * lightF * (0.9 + 0.2 * h.y);
                T *= 1.0 - a;
            }
            fi++;
        } else if (zn == zRow) {
            // ---------------- spruce row
            float z = zn;
            float x = ax * z, y = CAMH + b * z;
            float gz = wh_rise(z);
            bool full = z > 60.0;
            float eL = wh_edgeL(z), eR = wh_edgeR(z);
            bool inClearing = !full && x > eL + 3.4 && x < eR - 3.4;
            if (y < gz + TREE_H * 1.35 + 1.0 && y > gz - 1.5 && !inClearing) {
                float cs = 3.0 + 0.012 * z;
                float ci = floor(x / cs);
                float thB = 0.5 * APER * abs(z - ZF) / (z * ZF) * z;
                float fp = z * pxA + 1.5 * thB;
                float rowSeed = 13.0 * float(ri) + 0.5;
                float best = -1e3, snow = 0.0, lit = 0.0, hgt = 0.0;
                for (int kk = -2; kk <= 2; kk++) {
                    float c = ci + float(kk);
                    float4 h = hash24(float2(c, rowSeed));
                    float xk = (c + 0.5 + (h.x - 0.5) * 0.8) * cs;
                    if (!full && xk > eL && xk < eR) continue;
                    if (h.w < 0.16) continue;
                    float H = TREE_H * (0.68 + 0.62 * pow(h.y, 1.4));
                    float gb = wh_gCoarse(float2(xk, z)) - 0.35;
                    float sn, lt;
                    float d = wh_tree(x - xk, y - gb, H, h, fp, sn, lt);
                    if (d > best) { best = d; snow = sn; lit = lt; hgt = clamp((y - gb) / H, 0.0, 1.0); }
                }
                float a = clamp(0.5 + best / fp, 0.0, 1.0);
                if (a > 0.0) {
                    float ao = 0.45 + 0.55 * smoothstep(0.0, 0.5, hgt);
                    float3 P = float3(x, y, z);
                    float3 folE = SKY_E * (0.35 + 0.65 * hgt) * ao;
                    float3 snE = SKY_E * (0.35 + 0.65 * lit) * (0.55 + 0.45 * hgt) * ao;
                    float3 warmS = wh_warm(P, normalize(float3(0.0, 0.55, -1.0)), L, 0.25);
                    float3 col = mix(FOL_A * (folE + 0.6 * warmS), SNOW_A * (snE + warmS), snow);
                    acc += T * a * col;
                    T *= 1.0 - a;
                }
            }
            ri++;
        } else if (zn == zC) {
            // ---------------- smoke, then cabin
            if (smokeOn) {
                float s = wh_smoke(smokeXY, chimTop, t);
                if (s > 0.0) {
                    float3 P = float3(smokeXY, zSmoke);
                    float3 scol = float3(0.72, 0.76, 0.84) * (SKY_E * 1.1 + wh_warm(P, float3(0.0, 0.3, -1.0), L, 0.5) * 0.4);
                    float a = 0.55 * s;
                    acc += T * a * scol;
                    T *= 1.0 - a;
                }
            }
            if (cabSolid >= 0 && zCab <= zEvent + 1e-3) {
                if (!haloSet) { Thalo = T; haloSet = true; }
                float3 col = wh_cabinShade(cabSolid, cabFace, cabPl, cabNl, R, L, zCab * pxA, t);
                acc += T * col;
                T = float3(0.0);
                opaque = true;
            }
            cabDone = true;
        } else {
            // ---------------- snow ground
            float z = zn;
            if (!haloSet && z > 20.0) { Thalo = T; haloSet = true; }
            if (z >= 159.0) { acc += T * fogCol; T = float3(0.0); opaque = true; break; }
            float3 P = float3(ax * z, CAMH + b * z, z);
            float fp = z * pxA * 2.0;
            float e = max(fp, 0.004);
            float g0 = wh_gFull(P.xz, fp);
            float gx = wh_gFull(P.xz + float2(e, 0.0), fp);
            float gzz = wh_gFull(P.xz + float2(0.0, e), fp);
            float3 n = normalize(float3(-(gx - g0) / e, 1.0, -(gzz - g0) / e));
            P.y = g0;
            // sky irradiance, forest-edge occlusion
            float eL = wh_edgeL(z), eR = wh_edgeR(z);
            float occ = 1.0 - 0.45 * smoothstep(4.0, -2.0, P.x - eL) - 0.35 * smoothstep(-6.0, 1.0, P.x - eR) * (1.0 - smoothstep(50.0, 62.0, z));
            occ = clamp(occ, 0.3, 1.0);
            float3 E = SKY_E * (0.5 + 0.5 * n.y) * occ;
            // a touch of forward-scatter sheen toward the horizon
            E += SKY_H * 0.12 * pow(1.0 - max(dot(n, -rdn), 0.0), 3.0);
            float3 warm = wh_warm(P, n, L, 0.0);
            // sparkle (static, world-anchored) — only where light is strong
            float spk = 0.0;
            float sfade = 1.0 - smoothstep(0.006, 0.03, fp);
            if (sfade > 0.0) {
                float2 sc = P.xz * 55.0;
                float2 sid = floor(sc);
                float4 hs = hash24(sid + 9.0);
                float2 sf = sc - sid - 0.5 - (hs.xy - 0.5) * 0.6;
                float ds = length(sf) / max(fp * 55.0 * 0.9, 0.05);
                spk = step(0.965, hs.w) * exp(-ds * ds * 2.0) * (0.3 + 0.7 * hs.z) * sfade;
            }
            float3 col = SNOW_A * (E + warm) + spk * (SKY_E * 1.5 + warm * 3.0);
            acc += T * col;
            T = float3(0.0);
            opaque = true;
            break;
        }
        if (max(T.x, max(T.y, T.z)) < 0.003) { opaque = true; break; }
    }

    if (!opaque) {
        // far fog + sky
        wh_fog(acc, T, zPrev, 1200.0, ax, b, len, t, fogCol);
        float el = atan(b);
        float u = clamp(el / 0.32, 0.0, 1.0);
        float3 sky = mix(SKY_H, SKY_Z, pow(u, 0.8));
        float2 cq = float2(ax / (b + 0.06), 1.0 / (b + 0.06));
        float cl = fbmLoop(cq * 0.35, t, 3, 1);
        sky *= 1.0 + 0.10 * cl * smoothstep(0.0, 0.05, el);
        sky += float3(0.05, 0.028, 0.012) * exp(-el / 0.06) * smoothstep(0.35, -0.5, ax);   // faint afterglow, left
        acc += T * sky;
    }

    // window glow halo in the mist (scattered light between camera and cabin)
    if (haloSet) {
        float3 halo = float3(0.0);
        for (int i = 0; i < 5; i++) {
            float3 Lp = L[i].pos;
            float2 sp = float2(Lp.x / Lp.z, (Lp.y - CAMH) / Lp.z);
            float r = length(float2(ax, b) - sp);
            halo += L[i].I * (0.030 * exp(-r / 0.010) + 0.016 * exp(-r / 0.035) + 0.006 * exp(-r / 0.10));
        }
        acc += Thalo * WARM * halo;
    }

    float3 col = acc * EXPO;
    col *= ws_vignette(uv, 0.28);
    col = ws_acesFitted(col);
    col += ws_grain(fragCoord, t) * 0.005 * sqrt(max(col, 0.0));
    return col;
}
