// =====================================================================
//  Lighthouse Watch — a tall lighthouse on a rugged headland, deep night.
//  Twin opposed beams turn once per 20 s loop and sweep as volumetric
//  shafts through sea mist; heavy long-period swells roll in slowly and
//  break white against the rocks. Thin crescent moon, stars, drifting cloud.
//  Units: metres. y up, mean sea level y = 0. Camera looks toward +z.
// =====================================================================

constant float DEG = 0.017453292519943295;

// camera
constant float3 LW_CAM  = float3(0.0, 5.5, 0.0);
constant float  LW_VFOV = 36.0;
constant float  LW_YAW  = 3.0;          // camera heading (deg, + = right / +x)
constant float  LW_HOR  = 0.36;         // horizon height (fraction of frame from bottom)
constant float  LW_EXPO = 1.0;

// lighthouse
constant float2 LW_LH   = float2(-52.0, 232.0);   // tower axis (xz)
constant float  LW_PAD  = 21.0;                   // ground level at the tower
constant float  LW_TWR  = 40.0;                   // masonry tower height above the pad
constant float  LW_R0   = 3.3;                    // tower radius at base
constant float  LW_R1   = 2.25;                   // tower radius at top
constant float  LW_LAMPY = LW_PAD + LW_TWR + 3.0; // lamp height (64 m)

// moon (thin crescent, upper left)
constant float  LW_MOON_AZ = -20.0;               // world azimuth (deg from +z toward +x)
constant float  LW_MOON_EL = 16.0;

// beam
constant float  LW_PHI0   = 100.0 * DEG;          // beam azimuth at t = 0
constant float  LW_BEAM_EL = 0.6 * DEG;           // beam elevation
constant float  LW_SH = 1.5 * DEG;                // core sigma, horizontal
constant float  LW_SV = 2.4 * DEG;                // core sigma, vertical
constant float  LW_SHALO = 6.5 * DEG;             // halo sigma
constant float  LW_IBEAM = 2.4e5;                 // beam radiant intensity (scene units)
constant float  LW_SIGS  = 0.028;                 // mist scattering coefficient at sea level (1/m)
constant float  LW_SIGT  = 0.0016;                // extinction (1/m) for beam/lamp transmittance

inline float3 lw_lamp() { return float3(LW_LH.x, LW_LAMPY, LW_LH.y); }
inline float3 lw_moonDir() {
    float az = LW_MOON_AZ * DEG, el = LW_MOON_EL * DEG;
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ------------------------------------------------------------ small helpers
inline float lw_sdSeg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}
inline float lw_smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}
inline float lw_sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}
inline float lw_sdCylY(float3 p, float r, float h0, float h1) {
    float2 d = float2(length(p.xz) - r, max(h0 - p.y, p.y - h1));
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}
// loop-safe drifting noise: two copies of a field drift by `drift` over their life and are
// blended with variance-preserving weights |sin|,|cos| (sum of squares = 1).
inline float lw_flow2(float2 p, float t, float2 drift, int oct) {
    float a = fract(t), b = fract(t + 0.5);
    float wa = sin(PI * a), wb = sin(PI * b);
    float na = fbm(p - drift * (a - 0.5), oct);
    float nb = fbm(p - drift * (b - 0.5) + float2(41.3, 17.9), oct);
    return wa * na + wb * nb;
}
inline float lw_flow3(float3 p, float t, float3 drift, int oct) {
    float a = fract(t), b = fract(t + 0.5);
    float wa = sin(PI * a), wb = sin(PI * b);
    float na = fbm(p - drift * (a - 0.5), oct);
    float nb = fbm(p - drift * (b - 0.5) + float3(41.3, 17.9, 7.7), oct);
    return wa * na + wb * nb;
}
inline float lw_hg(float c, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * c, 1e-4), 1.5));
}

// ------------------------------------------------------------ terrain
// coastline signed distance in the horizontal plane (m): negative on land
inline float lw_coast(float2 q) {
    float2 w = q + 14.0 * float2(gnoise(q * 0.012 + float2(3.1, 1.7)), gnoise(q * 0.012 + float2(8.3, 5.2)))
                 + 4.0 * float2(gnoise(q * 0.05 + 1.3), gnoise(q * 0.05 + 7.4));
    float d = lw_sdSeg(w, float2(-270.0, 130.0), float2(-46.0, 238.0)) - 34.0;   // headland ridge
    float dm = dot(w - float2(-160.0, 40.0), normalize(float2(1.0, 0.35)));      // mainland
    d = lw_smin(d, dm, 40.0);
    float dn = lw_sdSeg(w, float2(-75.0, 6.0), float2(-16.0, 30.0)) - 8.0;      // foreground shelf
    d = lw_smin(d, dn, 10.0);
    float ds = length(w - float2(-14.0, 254.0)) - 6.5;                           // sea stack off the point
    d = min(d, ds);
    float dk = length(w - float2(55.0, 150.0)) - 3.5;                            // skerry, right
    d = min(d, dk);
    return d;
}

// Ground height (m). lod = ridged octaves.
inline float lw_heightC(float2 q, float c, int lod) {
    float s = -c;
    if (s < -15.0) return -8.0;
    float top = 22.0 + 3.0 * fbm(q * 0.012 + float2(4.0, 1.0), 2) + 18.0 * smoothstep(-120.0, -300.0, q.x);
    float fg = smoothstep(80.0, 50.0, q.y);
    top = mix(top, 4.0, fg);
    top = mix(top, 14.0, smoothstep(20.0, 10.0, length(q - float2(-14.0, 254.0))));
    top = mix(top, 1.9, smoothstep(12.0, 5.0, length(q - float2(55.0, 150.0))));
    float cw = mix(8.0, 15.0, 0.5 + 0.5 * gnoise(q * 0.03 + 5.0));
    float u = clamp(s / cw, 0.0, 1.0);
    float iu = 1.0 - u;
    float prof = 1.0 - iu * iu * iu;
    float h = top * prof;
    float rockMask = 1.0 - smoothstep(0.55, 1.0, u);
    float r = ridged(q * 0.07 + float2(1.7, 3.3), lod);
    h += (r - 0.55) * 4.5 * rockMask;
    // rocky apron at the waterline: boulders and shelves
    float ap = smoothstep(-14.0, -2.0, s) * (1.0 - smoothstep(0.0, 8.0, s));
    if (ap > 0.001) {
        float2 wc = worley(q * 0.22 + 0.5 * float2(gnoise(q * 0.1), gnoise(q * 0.1 + 3.0)));
        float boulder = sqrt(max(0.0, 1.0 - wc.x * wc.x * 1.6)) * 2.2;
        h = max(h, (boulder - 0.6 + 0.8 * r) * ap);
    }
    h = max(min(h, s * 0.6 + 1.0), -8.0);
    // flatten a pad for the lighthouse and the cottage
    float dp = length((q - float2(LW_LH.x - 8.0, LW_LH.y - 3.0)) * float2(0.7, 1.0));
    float padw = smoothstep(18.0, 10.0, dp) * smoothstep(-2.0, 6.0, s);
    if (padw > 0.0) h = mix(h, LW_PAD + 0.3 * fbm(q * 0.2, 2), padw);
    return h;
}
inline float lw_height(float2 q, int lod) { return lw_heightC(q, lw_coast(q), lod); }

// horizontal bounding capsules of the land (generous); returns t-range where terrain may exist
inline float2 lw_landRange(float3 ro, float3 rd) {
    float2 rng = float2(1e9, -1e9);
    float2 o = ro.xz, d = rd.xz;
    float dl = length(d);
    if (dl < 1e-4) return rng;
    float2 dn = d / dl;
    // capsules: (a, b, radius)
    for (int i = 0; i < 4; i++) {
        float2 a, b; float r;
        if (i == 0) { a = float2(-300.0, 110.0); b = float2(-40.0, 246.0); r = 62.0; }
        else if (i == 1) { a = float2(-80.0, 0.0); b = float2(-12.0, 34.0); r = 26.0; }
        else if (i == 2) { a = float2(-14.0, 254.0); b = a; r = 26.0; }
        else { a = float2(55.0, 150.0); b = a; r = 22.0; }
        // ray vs capsule in 2D: solve |o + dn*s - closest(seg)| = r approximately via circle around segment samples
        // exact: distance from ray to segment ≤ r  → compute entry/exit by sampling the segment endpoints' circles and the slab
        float2 ba = b - a;
        float bl = length(ba);
        float2 bn = bl > 1e-3 ? ba / bl : float2(1.0, 0.0);
        float2 pn = float2(-bn.y, bn.x);
        // transform ray into segment frame: u along, v across
        float ou = dot(o - a, bn), ov = dot(o - a, pn);
        float du = dot(dn, bn), dv = dot(dn, pn);
        // slab |v| <= r, u in [0, bl]  (rectangle) plus end circles — union of rectangle and two discs
        float sMin = 1e9, sMax = -1e9;
        // rectangle
        {
            float t0 = -1e9, t1 = 1e9;
            if (abs(dv) > 1e-6) { float ta = (-r - ov) / dv, tb = (r - ov) / dv; t0 = max(t0, min(ta, tb)); t1 = min(t1, max(ta, tb)); }
            else if (abs(ov) > r) { t0 = 1e9; t1 = -1e9; }
            if (abs(du) > 1e-6) { float ta = (0.0 - ou) / du, tb = (bl - ou) / du; t0 = max(t0, min(ta, tb)); t1 = min(t1, max(ta, tb)); }
            else if (ou < 0.0 || ou > bl) { t0 = 1e9; t1 = -1e9; }
            if (t0 <= t1) { sMin = min(sMin, t0); sMax = max(sMax, t1); }
        }
        // discs
        for (int e = 0; e < 2; e++) {
            float2 c = e == 0 ? a : b;
            float2 oc = o - c;
            float bq = dot(oc, dn);
            float cq = dot(oc, oc) - r * r;
            float disc = bq * bq - cq;
            if (disc > 0.0) { float sq = sqrt(disc); sMin = min(sMin, -bq - sq); sMax = max(sMax, -bq + sq); }
        }
        if (sMin <= sMax) { rng.x = min(rng.x, sMin); rng.y = max(rng.y, sMax); }
    }
    rng /= dl;
    rng.x = max(rng.x, 0.0);
    return rng;
}

// ------------------------------------------------------------ buildings (SDF)
// material ids: 1 tower, 2 iron, 3 lantern glass, 4 cottage wall, 5 roof, 7 rail
inline float2 lw_lighthouse(float3 p) {
    float3 q = p - float3(LW_LH.x, LW_PAD, LW_LH.y);
    float res = 1e5, mat = 0.0;
    // tapered tower
    {
        float y = clamp(q.y / LW_TWR, 0.0, 1.0);
        float r = mix(LW_R0, LW_R1, y);
        float d = max(length(q.xz) - r, max(-q.y - 1.5, q.y - LW_TWR)) * 0.95;
        if (d < res) { res = d; mat = 1.0; }
        float dpl = lw_sdCylY(q, LW_R0 + 0.5, -2.0, 1.2);      // plinth
        if (dpl < res) { res = dpl; mat = 1.0; }
        float band = lw_sdCylY(q, LW_R1 + 0.35, LW_TWR - 1.6, LW_TWR - 0.9);   // corbel under the gallery
        if (band < res) { res = band; mat = 1.0; }
    }
    // gallery deck + railing
    {
        float d = lw_sdCylY(q, 3.35, LW_TWR - 0.15, LW_TWR + 0.3);
        if (d < res) { res = d; mat = 2.0; }
        float3 rq = q - float3(0.0, LW_TWR + 1.25, 0.0);
        float ring = length(float2(length(rq.xz) - 3.25, rq.y)) - 0.05;
        float ring2 = length(float2(length(rq.xz) - 3.25, rq.y + 0.5)) - 0.035;
        float a = atan2(q.z, q.x);
        float sec = TAU / 30.0;
        float ai = (floor(a / sec) + 0.5) * sec;
        float2 pp = float2(cos(ai), sin(ai)) * 3.25;
        float post = max(length(q.xz - pp) - 0.04, abs(q.y - (LW_TWR + 0.78)) - 0.5);
        float rail = min(min(ring, ring2), post);
        if (rail < res) { res = rail; mat = 7.0; }
    }
    // lantern room
    {
        float yb = LW_TWR + 0.3;
        float base = lw_sdCylY(q, 2.05, yb, yb + 0.9);
        if (base < res) { res = base; mat = 2.0; }
        float glass = lw_sdCylY(q, 1.9, yb + 0.9, yb + 3.9);
        if (glass < res) { res = glass; mat = 3.0; }
        // dome
        float3 dq = q - float3(0.0, yb + 3.9, 0.0);
        float dome = max(length(dq * float3(1.0, 1.45, 1.0)) - 2.2, -dq.y);
        dome = min(dome, lw_sdCylY(q, 2.3, yb + 3.85, yb + 4.05));
        if (dome < res) { res = dome * 0.8; mat = 2.0; }
        float ball = length(q - float3(0.0, yb + 5.55, 0.0)) - 0.3;
        float rod = lw_sdCylY(q, 0.04, yb + 5.5, yb + 6.8);
        float top = min(ball, rod);
        if (top < res) { res = top; mat = 2.0; }
    }
    return float2(res, mat);
}

inline float3 lw_cottageLocal(float3 p) {
    float3 c = float3(LW_LH.x - 19.0, LW_PAD, LW_LH.y - 6.0);
    float3 q = p - c;
    float2 cs = float2(cos(0.12), sin(0.12));
    q.xz = float2(cs.x * q.x - cs.y * q.z, cs.y * q.x + cs.x * q.z);
    return q;
}
inline float2 lw_cottage(float3 p) {
    float3 q = lw_cottageLocal(p);
    float res = 1e5, mat = 0.0;
    float wall = lw_sdBox(q - float3(0.0, 1.6, 0.0), float3(6.5, 3.2, 3.6));
    if (wall < res) { res = wall; mat = 4.0; }
    float3 rq = q - float3(0.0, 4.8, 0.0);
    float roofSolid = max(abs(rq.z) * 0.78 + rq.y * 0.62 - 2.4, max(abs(rq.x) - 6.9, -rq.y));
    if (roofSolid < res) { res = roofSolid; mat = 5.0; }
    float ch = lw_sdBox(q - float3(3.8, 6.6, 0.4), float3(0.45, 1.4, 0.45));
    if (ch < res) { res = ch; mat = 4.0; }
    float an = lw_sdBox(q - float3(8.9, 1.3, 0.6), float3(2.5, 2.3, 2.7));
    if (an < res) { res = an; mat = 4.0; }
    float3 aq = q - float3(8.9, 3.6, 0.6);
    float aroof = max(abs(aq.z) * 0.7 + aq.y * 0.71 - 2.05, max(abs(aq.x) - 2.7, -aq.y));
    if (aroof < res) { res = aroof; mat = 5.0; }
    return float2(res, mat);
}

inline float2 lw_objects(float3 p) {
    float2 a;
    float3 lq = p - float3(LW_LH.x, LW_PAD + LW_TWR * 0.5, LW_LH.y);
    lq.y *= 0.16;   // squash → bounding ellipsoid around the tall tower
    float bl = length(lq);
    if (bl < 6.5) a = lw_lighthouse(p); else a = float2((bl - 5.0) * 0.9, 0.0);
    float3 cq = p - float3(LW_LH.x - 14.0, LW_PAD + 3.5, LW_LH.y - 6.0);
    float bc = length(cq);
    float2 b = bc < 18.0 ? lw_cottage(p) : float2(bc - 16.0, 0.0);
    return a.x < b.x ? a : b;
}

// ------------------------------------------------------------ scene march
// returns (t, mat) with mat 0 terrain, >0 objects; t < 0 = miss
inline float2 lw_march(float3 ro, float3 rd, float tmax, int lod) {
    float2 lr = lw_landRange(ro, rd);
    float tObj0 = 1e9, tObj1 = -1e9;
    {   // bounding sphere of the buildings
        float3 c = float3(LW_LH.x - 6.0, LW_PAD + 22.0, LW_LH.y - 3.0);
        float3 oc = ro - c;
        float b = dot(oc, rd), cc = dot(oc, oc) - 32.0 * 32.0;
        float disc = b * b - cc;
        if (disc > 0.0) { float sq = sqrt(disc); tObj0 = max(-b - sq, 0.0); tObj1 = -b + sq; }
    }
    float tStart = min(lr.x, tObj0);
    float tEnd = min(max(lr.y, tObj1), tmax);
    if (tStart > tEnd) return float2(-1.0, -1.0);
    float t = max(tStart, 0.3);
    float tPrev = t;
    float dTprev = 1e5;
    for (int i = 0; i < 110; i++) {
        float3 p = ro + rd * t;
        if (p.y > 48.0 && rd.y > 0.0 && (t > tObj1)) break;
        bool inLand = t >= lr.x && t <= lr.y;
        bool inObj = t >= tObj0 && t <= tObj1;
        float dT = 1e5, c = 1e5;
        if (inLand) {
            c = lw_coast(p.xz);
            if (c > 9.0 && p.y > 1.5) dT = max(c - 9.0, p.y - 1.5) * 0.7;      // open water: terrain is submerged
            else { float h = lw_heightC(p.xz, c, lod); dT = (p.y - h) * 0.42; }
        } else if (t < lr.x) dT = max((lr.x - t), 0.05);
        float2 o = float2(1e5, 0.0);
        if (inObj) o = lw_objects(p);
        else if (t < tObj0) o.x = max(tObj0 - t, 0.05);
        float d = min(dT, o.x);
        float eps = 0.0015 * t + 0.003;
        if (d < eps) {
            float mat = o.x < dT ? o.y : 0.0;
            if (mat == 0.0 && dTprev > 0.0 && dT < 0.0) {
                float a = tPrev, b = t;
                for (int j = 0; j < 5; j++) {
                    float m = 0.5 * (a + b);
                    float3 pm = ro + rd * m;
                    if (pm.y - lw_height(pm.xz, lod) < 0.0) b = m; else a = m;
                }
                t = 0.5 * (a + b);
            }
            return float2(t, mat);
        }
        tPrev = t; dTprev = dT;
        t += max(d, 0.02 + t * 0.002);
        if (t > tEnd) break;
    }
    return float2(-1.0, -1.0);
}

inline float3 lw_terrainNormal(float2 q, float t, int lod) {
    float e = max(0.03, t * 0.0015);
    float hx = lw_height(q + float2(e, 0.0), lod) - lw_height(q - float2(e, 0.0), lod);
    float hz = lw_height(q + float2(0.0, e), lod) - lw_height(q - float2(0.0, e), lod);
    return normalize(float3(-hx, 2.0 * e, -hz));
}
inline float3 lw_objNormal(float3 p) {
    float e = 0.004;
    float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * lw_objects(p + k.xyy * e).x + k.yyx * lw_objects(p + k.yyx * e).x +
                     k.yxy * lw_objects(p + k.yxy * e).x + k.xxx * lw_objects(p + k.xxx * e).x);
}

// ------------------------------------------------------------ sea
constant int LW_NW = 11;
// wave i: cycles per 20 s loop n (deep-water dispersion: lambda = g T^2 / 2pi, T = 20 s / n)
inline void lw_wave(int i, thread float2& dir, thread float& k, thread float& a, thread float& n, thread float& ph) {
    const float NS[11] = {2, 3, 4, 5, 6, 8, 10, 13, 17, 3, 5};
    const float AS[11] = {0.60, 0.42, 0.28, 0.17, 0.10, 0.06, 0.035, 0.022, 0.013, 0.22, 0.09};
    const float DA[11] = {0.05, -0.08, 0.12, -0.15, 0.22, -0.26, 0.30, -0.36, 0.42, 0.62, -0.72};
    const float PH[11] = {0.3, 2.1, 4.4, 1.2, 5.3, 0.7, 3.6, 2.9, 1.7, 4.0, 0.2};
    n = NS[i];
    float lam = 624.6 / (n * n);
    k = TAU / lam;
    float ang = 3.40 + DA[i];        // propagation azimuth: toward the camera, a little left
    dir = float2(sin(ang), cos(ang));
    a = AS[i];
    ph = PH[i];
}
// Stokes-like crest sharpening: f(th) = 2*((1+cos th)/2)^1.6 - 1
inline float lw_seaH(float2 x, float t, int nmax) {
    float h = 0.0;
    for (int i = 0; i < nmax; i++) {
        float2 dir; float k, a, n, ph;
        lw_wave(i, dir, k, a, n, ph);
        float th = dot(dir, x) * k - TAU * n * t + ph;
        float c = 0.5 + 0.5 * cos(th);
        h += a * (2.0 * pow(c, 1.6) - 1.0);
    }
    return h;
}
// normal (analytic swells + wind ripples), unresolved slope variance, swell surge (for foam)
inline float3 lw_seaN(float2 x, float t, float fp, thread float& var, thread float& surge) {
    float2 g = float2(0.0);
    var = 0.0002;
    surge = 0.0;
    for (int i = 0; i < LW_NW; i++) {
        float2 dir; float k, a, n, ph;
        lw_wave(i, dir, k, a, n, ph);
        float lam = TAU / k;
        float w = smoothstep(1.5, 4.0, lam / max(fp, 1e-4));
        float th = dot(dir, x) * k - TAU * n * t + ph;
        float c = 0.5 + 0.5 * cos(th);
        float st = a * k;
        var += (1.0 - w * w) * st * st * 0.6;
        float df = -1.6 * pow(c, 0.6) * sin(th);     // d/dth of 2 c^1.6 - 1
        g += dir * (a * k * df * w);
        if (i < 3) surge += a * (2.0 * pow(c, 1.6) - 1.0);
    }
    // wind ripples (loop-safe drifting noise), two scales
    float e = 0.35;
    float wr1 = smoothstep(2.5, 0.6, fp);          // ~2 m ripples
    float wr2 = smoothstep(0.9, 0.2, fp);          // ~0.6 m ripples
    if (wr1 > 0.0) {
        float2 q = x * 0.55;
        float2 dr = float2(1.8, -3.5);
        float n0 = lw_flow2(q, t, dr, 2);
        float nx = lw_flow2(q + float2(e * 0.55, 0.0), t, dr, 2);
        float nz = lw_flow2(q + float2(0.0, e * 0.55), t, dr, 2);
        g += float2(nx - n0, nz - n0) / (e * 0.55) * 0.022 * wr1;
    }
    if (wr2 > 0.0) {
        float2 q = x * 1.7 + 11.0;
        float n0 = gnoise(q), nx = gnoise(q + float2(0.1, 0.0)), nz = gnoise(q + float2(0.0, 0.1));
        g += float2(nx - n0, nz - n0) / 0.1 * 0.03 * wr2;
    }
    var += 0.004 * (1.0 - wr1) + 0.0035 * (1.0 - wr2);
    return normalize(float3(-g.x, 1.0, -g.y));
}

// ------------------------------------------------------------ lighthouse beam
inline float3 lw_beamDir(float t, int b) {
    float phi = LW_PHI0 + TAU * t + (b == 1 ? PI : 0.0);
    return float3(sin(phi) * cos(LW_BEAM_EL), sin(LW_BEAM_EL), cos(phi) * cos(LW_BEAM_EL));
}
// angular profile of the beam for unit direction vn from the lamp
inline float lw_beamProfile(float3 vn, float3 D, float3 S, float3 U) {
    float along = dot(vn, D);
    if (along < 0.3) return 0.0;
    float ah = atan2(dot(vn, S), along), av = atan2(dot(vn, U), along);
    float core = exp(-0.5 * (ah * ah / (LW_SH * LW_SH) + av * av / (LW_SV * LW_SV)));
    float halo = 0.05 * exp(-0.5 * (ah * ah + av * av) / (LW_SHALO * LW_SHALO));
    float avd = av + 5.0 * DEG;
    float down = 0.09 * exp(-0.5 * (ah * ah / (4.0 * LW_SH * LW_SH) + avd * avd / (25.0 * DEG * DEG)));
    return core + halo + down;
}
// scattering coefficient of the misty air (relative to LW_SIGS)
inline float lw_mist(float3 p, float t) {
    float hgt = exp(-max(p.y, 0.0) / 85.0);
    float n = lw_flow3(p * float3(0.025, 0.045, 0.025), t, float3(14.0, 0.0, 5.0), 2);
    return hgt * clamp(0.7 + 1.0 * n, 0.12, 2.0);
}
// in-scattered beam light along the view ray segment [0, tEnd]; ns samples per beam
inline float3 lw_beamScatter(float3 ro, float3 rd, float tEnd, float t, float jit, int ns, float strength) {
    float3 L = lw_lamp();
    float3 sum = float3(0.0);
    float tc = dot(L - ro, rd);
    float3 pc = ro + rd * tc;
    float3 pv = pc - L;
    float d = max(length(pv), 0.05);
    float3 Ph = pv / d;                              // unit vector lamp → closest point on ray
    float th0 = atan2(0.0 - tc, d);
    float th1 = atan2(tEnd - tc, d);
    float3 N = normalize(cross(Ph, rd));             // normal of the plane (lamp, ray)
    for (int b = 0; b < 2; b++) {
        float3 D = lw_beamDir(t, b);
        float3 S = normalize(cross(D, float3(0.0, 1.0, 0.0)));
        float3 U = cross(S, D);
        float dn = dot(D, N);
        float delta = asin(clamp(abs(dn), 0.0, 1.0));   // closest angular approach of the beam axis to the ray plane
        float w = 3.2 * LW_SHALO;
        if (delta > w) continue;
        float thStar = atan2(dot(D, rd), dot(D, Ph));
        float acc = 0.0;
        for (int i = 0; i < ns; i++) {
            float u = ((float(i) + jit) / float(ns)) * 2.0 - 1.0;
            float th = thStar + w * u * abs(u);
            if (th < th0 || th > th1) continue;
            float jac = 2.0 * w * abs(u);            // dth/du
            float ts = tc + d * tan(th);
            float3 p = ro + rd * ts;
            float3 v = p - L;
            float r = length(v);
            float3 vn = v / max(r, 1e-3);
            float prof = lw_beamProfile(vn, D, S, U);
            if (prof < 1e-4) continue;
            float cosSc = dot(vn, -rd);
            float ph = 0.68 * lw_hg(cosSc, 0.62) + 0.32 * 0.0796;
            float sig = lw_mist(p, t);
            float tr = exp(-LW_SIGT * (r + ts));
            float near = r * r / (r * r + 4.0);
            // equiangular weight: (r^2 / d) per unit theta; integrand has 1/r^2 → 1/d
            acc += prof * ph * sig * tr * near * jac / d;
        }
        sum += float3(acc * (2.0 / float(ns)));
    }
    return sum * (LW_SIGS * LW_IBEAM * strength);
}

// ------------------------------------------------------------ sky
inline float3 lw_sky(float3 rd, float3 md, float moonIll) {
    float h = clamp(rd.y, -0.05, 1.0);
    float3 zen = float3(0.0040, 0.0068, 0.0170);
    float3 hor = float3(0.0165, 0.0225, 0.0380);
    float3 col = mix(hor, zen, 1.0 - exp(-max(h, 0.0) * 3.0));
    // moon aureole (Mie forward scatter in thin haze)
    float mu = dot(rd, md);
    float ang = acos(clamp(mu, -1.0, 1.0));
    col += float3(0.055, 0.058, 0.070) * moonIll * (0.9 * exp(-ang / 0.05) + 0.35 * exp(-ang / 0.22) + 0.10 * exp(-ang / 0.7));
    // sea-mist glow near the horizon
    col += hor * 0.6 * exp(-max(h, 0.0) / 0.035);
    return col;
}

inline float3 lw_moonDisc(float3 rd, float3 md) {
    float c = dot(rd, md);
    float ang = acos(clamp(c, -1.0, 1.0));
    float rad = 0.26 * DEG;
    if (ang > rad * 1.6) return float3(0.0);
    // local disc coords
    float3 S = normalize(cross(md, float3(0.0, 1.0, 0.0)));
    float3 U = cross(S, md);
    float2 uv = float2(dot(rd, S), dot(rd, U)) / rad;
    float rr = dot(uv, uv);
    float disc = 1.0 - smoothstep(0.93, 1.05, sqrt(rr));
    float3 n = float3(uv, sqrt(max(0.0, 1.0 - rr)));
    float3 sun = normalize(float3(-0.86, -0.22, -0.46));     // sun behind and left → thin crescent
    float lit = max(dot(n, sun), 0.0);
    float phase = smoothstep(0.0, 0.25, lit);
    float3 albedo = float3(0.95, 0.92, 0.86) * (0.75 + 0.25 * gnoise(uv * 5.0));
    // earthshine on the dark limb
    return albedo * (phase * 9.0 + 0.07) * disc;
}

// scattered altocumulus deck, 2D at 1500 m; returns (rgb, alpha)
inline float4 lw_clouds(float3 ro, float3 rd, float t, float3 md, float3 moonCol, float3 amb, float mu) {
    if (rd.y < 0.015) return float4(0.0);
    float tc = (1500.0 - ro.y) / rd.y;
    float2 q = ro.xz + rd.xz * tc;
    float2 drift = float2(380.0, 90.0);
    float2 wq = q + 260.0 * float2(gnoise(q * (1.0 / 3000.0) + 1.3), gnoise(q * (1.0 / 3000.0) + 7.9));
    float base = lw_flow2(wq * (1.0 / 2400.0) + float2(2.1, 0.6), t, drift * (1.0 / 2400.0), 4);
    float det = lw_flow2(wq * (1.0 / 520.0) + float2(9.1, 3.2), t, drift * (1.0 / 520.0), 3);
    // coverage bias: more cloud to the upper-left / far, less at the upper-right (icons)
    float bias = -0.06 + 0.10 * smoothstep(0.0, -6000.0, q.x) - 0.08 * smoothstep(1000.0, 5000.0, q.x) * smoothstep(0.35, 0.7, rd.y);
    float cov = base * 0.7 + det * 0.3 + bias;
    float dens = smoothstep(0.02, 0.28, cov);
    float far = smoothstep(0.02, 0.10, rd.y);
    float alpha = dens * far * 0.92;
    if (alpha < 0.002) return float4(0.0);
    // lighting: moon-lit tops (gradient toward the moon), silver lining where thin & near the moon
    float2 toMoon = normalize(md.xz + 1e-4) * 900.0;
    float covM = lw_flow2((wq + toMoon) * (1.0 / 2400.0) + float2(2.1, 0.6), t, drift * (1.0 / 2400.0), 3) * 0.7
               + lw_flow2((wq + toMoon) * (1.0 / 520.0) + float2(9.1, 3.2), t, drift * (1.0 / 520.0), 2) * 0.3 + bias;
    float grad = clamp((cov - covM) * 3.0 + 0.5, 0.0, 1.0);    // 1 = facing the moon
    float thin = 1.0 - dens;
    float fwd = lw_hg(mu, 0.55);
    float3 col = amb * (0.5 + 0.5 * thin)
               + moonCol * (0.10 + 0.35 * grad) * (0.35 + 0.65 * thin)
               + moonCol * fwd * 2.2 * thin * dens;
    return float4(col, alpha);
}

// ------------------------------------------------------------ main
float3 scene(float2 fragCoord, WSCtx ctx) {
    float t = ctx.t;
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;

    // camera
    float kf = tan(LW_VFOV * 0.5 * DEG);
    float pitch = atan((1.0 - 2.0 * LW_HOR) * kf);
    float yaw = LW_YAW * DEG;
    float3 f = float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch));
    float3 r = normalize(float3(cos(yaw), 0.0, -sin(yaw)));
    float3 u = cross(r, f);
    if (u.y < 0.0) u = -u;
    float3 rd = normalize(f + (p.x * r + p.y * u) * kf);
    float3 ro = LW_CAM;
    float pixA = 2.0 * kf / ctx.res.y;
    float jit = hash12(fragCoord * 1.37 + 0.123);

    float3 lamp = lw_lamp();
    float3 md = lw_moonDir();
    const float moonIll = 0.3;                               // crescent
    float3 moonCol = float3(0.80, 0.86, 1.0) * 0.11;          // moonlight irradiance
    float3 skyAmb = float3(0.010, 0.014, 0.026);              // mean sky radiance (upper hemisphere)
    float3 lampCol = float3(1.0, 0.86, 0.62);
    float3 winCol = float3(1.0, 0.62, 0.30);
    float3 sunV = float3(0.0);

    // ------------------------------------------------ sea intersection window
    float tSea0 = 1e9, tSea1 = 1e9;
    if (rd.y < -1e-4) { tSea0 = max((ro.y - 1.8) / -rd.y, 0.0); tSea1 = (ro.y + 1.8) / -rd.y; }

    // ------------------------------------------------ geometry
    float2 hit = lw_march(ro, rd, min(tSea1, 1400.0), 3);
    float tSea = -1.0;
    if (rd.y < -1e-4 && (hit.x < 0.0 || hit.x > tSea0)) {
        float t0 = tSea0, t1 = min(tSea1, hit.x > 0.0 ? hit.x : 1e9);
        float tp = t0;
        int N = 10;
        for (int i = 1; i <= N; i++) {
            float tt = mix(t0, t1, float(i) / float(N));
            float3 pp = ro + rd * tt;
            float dd = pp.y - lw_seaH(pp.xz, t, 6);
            if (dd < 0.0) {
                float a = tp, b = tt;
                for (int j = 0; j < 5; j++) {
                    float m = 0.5 * (a + b);
                    float3 pm = ro + rd * m;
                    if (pm.y - lw_seaH(pm.xz, t, 6) < 0.0) b = m; else a = m;
                }
                tSea = 0.5 * (a + b);
                break;
            }
            tp = tt;
        }
        if (tSea < 0.0 && hit.x < 0.0) tSea = tSea1;
    }

    float3 col;
    float tScene = 1e4;
    bool isSea = tSea > 0.0 && (hit.x < 0.0 || tSea < hit.x);
    float3 beamsD[2];
    float3 beamsS[2], beamsU[2];
    for (int b = 0; b < 2; b++) {
        beamsD[b] = lw_beamDir(t, b);
        beamsS[b] = normalize(cross(beamsD[b], float3(0.0, 1.0, 0.0)));
        beamsU[b] = cross(beamsS[b], beamsD[b]);
    }

    if (isSea) {
        tScene = tSea;
        float3 P = ro + rd * tSea;
        float fp = tSea * pixA / max(-rd.y, 0.03);
        fp = sqrt(fp * tSea * pixA);
        float var, surge;
        float3 n = lw_seaN(P.xz, t, fp, var, surge);
        float3 v = -rd;
        float nv = max(dot(n, v), 1e-3);
        float3 R = reflect(rd, n);
        R.y = abs(R.y) + 0.002;
        float F = 0.02 + 0.98 * pow(1.0 - nv, 5.0);
        // reflected sky (no stars — the surface scatters them away)
        float3 refl = lw_sky(R, md, moonIll * 0.6);
        // dark headland reflection: cheap silhouette test along R
        {
            float2 lr = lw_landRange(P, R);
            if (lr.x < lr.y && lr.x < 600.0) {
                float sh = 0.0;
                for (int i = 0; i < 6; i++) {
                    float tt = mix(lr.x, min(lr.y, 600.0), (float(i) + 0.5) / 6.0);
                    float3 pp = P + R * tt;
                    if (pp.y < 45.0) { float h = lw_height(pp.xz, 1); if (pp.y < h) { sh = 1.0; break; } }
                }
                refl = mix(refl, float3(0.002, 0.003, 0.005), sh);
            }
        }
        float3 body = float3(0.0035, 0.0085, 0.0125);
        float3 c0 = refl * F + body * (1.0 - F);
        // glitter from the lamp, the windows and the moon (GGX with unresolved roughness)
        float a2 = clamp(var * 2.6, 0.0015, 0.35);
        {
            float3 Lv = lamp - P; float Ld = length(Lv); float3 Ln = Lv / Ld;
            float3 hv = normalize(Ln + v);
            float nh = max(dot(n, hv), 0.0);
            float dd = nh * nh * (a2 - 1.0) + 1.0;
            float D = a2 / (PI * dd * dd);
            // lantern always glows; much brighter when a beam faces this point
            float face = 0.0;
            for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
            float I = 900.0 + LW_IBEAM * 0.06 * face;
            float tr = exp(-LW_SIGT * Ld);
            c0 += lampCol * I / (Ld * Ld) * D * F * tr * 0.25 * max(dot(n, Ln), 0.0) / max(nv, 0.05) * 0.5;
        }
        {   // moon glitter
            float3 hv = normalize(md + v);
            float nh = max(dot(n, hv), 0.0);
            float dd = nh * nh * (a2 - 1.0) + 1.0;
            float D = a2 / (PI * dd * dd);
            c0 += moonCol * 22.0 * moonIll * D * F * 0.25 * max(dot(n, md), 0.0) / max(nv, 0.05) * 0.5;
        }
        // foam where the swell meets rock
        float cst = lw_coast(P.xz);
        float foam = 0.0;
        if (cst < 12.0) {
            float ft = lw_flow2(P.xz * 0.30, t, float2(1.5, -3.0), 3);
            float m = smoothstep(11.0, 0.5, cst) * (0.5 + 0.5 * clamp(surge * 1.2, -1.0, 1.0));
            foam = smoothstep(0.25, 0.7, m + 0.4 * ft) * smoothstep(3.0, 0.6, fp);
        }
        if (foam > 0.0) {
            float3 nf = n;
            float3 amb = skyAmb * PI * (0.6 + 0.4 * nf.y);
            float3 mo = moonCol * max(dot(nf, md), 0.0);
            float3 Lv = lamp - P; float Ld2 = dot(Lv, Lv); float3 Ln = Lv * rsqrt(Ld2);
            float face = 0.0;
            for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
            float3 bl = lampCol * (1200.0 + LW_IBEAM * 0.12 * face) / Ld2 * max(dot(nf, Ln), 0.0) * exp(-LW_SIGT * sqrt(Ld2));
            float3 fc = float3(0.75, 0.78, 0.8) * (amb + mo + bl) / PI;
            c0 = mix(c0, fc, foam * 0.85);
        }
        // beam reflected in the water
        float3 bref = lw_beamScatter(P + float3(0.0, 0.05, 0.0), R, 1500.0, t, jit, 10, 1.0);
        c0 += bref * lampCol * F * (1.0 - foam);
        col = c0;
    } else if (hit.x > 0.0) {
        tScene = hit.x;
        float3 P = ro + rd * hit.x;
        float3 n;
        float3 alb;
        float3 emit = float3(0.0);
        float rough = 0.6;
        float spec = 0.03;
        if (hit.y == 0.0) {
            n = lw_terrainNormal(P.xz, hit.x, 3);
            // fine rock bump
            {
                float e = max(0.06, hit.x * 0.0015);
                float2 q = P.xz * 0.6;
                float b0 = fbm(q, 2), bx = fbm(q + float2(e * 0.6, 0.0), 2), bz = fbm(q + float2(0.0, e * 0.6), 2);
                float3 bn = normalize(float3(-(bx - b0), e * 0.6 * 1.2, -(bz - b0)));
                n = normalize(n + (bn - float3(0.0, 1.0, 0.0)) * 0.8 * smoothstep(400.0, 40.0, hit.x));
            }
            float slope = 1.0 - n.y;
            float strata = 0.5 + 0.5 * sin(P.y * 1.7 + 1.5 * gnoise(P.xz * 0.15));
            float3 rock = mix(float3(0.30, 0.28, 0.26), float3(0.42, 0.40, 0.37), strata);
            float3 grass = float3(0.16, 0.20, 0.10);
            float g = smoothstep(0.30, 0.12, slope) * smoothstep(5.0, 9.0, P.y) * (0.6 + 0.4 * gnoise(P.xz * 0.3));
            alb = mix(rock, grass, g);
            float wet = smoothstep(2.5, 0.6, P.y);
            alb *= mix(1.0, 0.45, wet);
            rough = mix(0.6, 0.18, wet);
            spec = mix(0.03, 0.06, wet);
        } else {
            n = lw_objNormal(P);
            int m = int(hit.y + 0.5);
            alb = m == 1 ? float3(0.80, 0.78, 0.74) : (m == 2 || m == 7) ? float3(0.05, 0.05, 0.055) : m == 3 ? float3(0.02) : m == 4 ? float3(0.70, 0.66, 0.60) : float3(0.14, 0.07, 0.05);
            if (m == 1) {
                // masonry: subtle stone texture + red band near the top
                float3 q = P - float3(LW_LH.x, LW_PAD, LW_LH.y);
                float ang = atan2(q.z, q.x);
                float tex = 0.9 + 0.1 * gnoise(float2(ang * 6.0, q.y * 0.8));
                alb *= tex;
                float band = step(abs(q.y - (LW_TWR - 5.5)) - 1.8, 0.0);
                alb = mix(alb, float3(0.55, 0.12, 0.09), band);
                rough = 0.55;
                // small slit windows on the seaward/camera face
                float3 toCam = normalize(float3(-LW_LH.x, 0.0, -LW_LH.y));
                float facing = dot(normalize(float3(q.x, 0.0, q.z)), toCam);
                for (int wI = 0; wI < 3; wI++) {
                    float wy = 9.0 + 10.5 * float(wI);
                    float lat = length(float2(dot(float2(q.x, q.z), float2(-toCam.z, toCam.x)), 0.0));
                    float win = step(abs(q.y - wy), 0.55) * step(lat, 0.32) * step(0.5, facing);
                    emit += winCol * 1.6 * win;
                }
            }
            if (m == 3) {
                // lantern glass: bright with the lens, mullions dark
                float3 q = P - float3(LW_LH.x, LW_PAD + LW_TWR + 1.2, LW_LH.y);
                float ang = atan2(q.z, q.x);
                float mull = step(abs(fract(ang / TAU * 12.0) - 0.5), 0.44) * step(abs(q.y - 1.6) - 1.35, 0.0) * step(0.08, abs(q.y - 1.6));
                float3 toCam = normalize(ro - P);
                float face = 0.0;
                for (int b = 0; b < 2; b++) face += lw_beamProfile(toCam, beamsD[b], beamsS[b], beamsU[b]);
                emit = lampCol * (2.2 + 45.0 * face) * mull;
                alb = float3(0.02);
                rough = 0.2;
            }
            if (m == 4) {
                float3 q = lw_cottageLocal(P);
                // windows on the long front (-z) face and the annex
                float wx = fract((q.x + 6.5) / 3.25) - 0.5;
                float win = step(abs(wx), 0.19) * step(abs(q.y - 1.8), 0.6) * step(q.z, -3.5) * step(abs(q.x), 6.0);
                float wa = step(abs(q.x - 8.9), 0.55) * step(abs(q.y - 1.6), 0.5) * step(q.z, -2.6) * step(q.z, -2.0);
                emit = winCol * 3.2 * max(win, wa);
                alb *= 0.92 + 0.08 * gnoise(q.xy * 2.0);
            }
            if (m == 5) { rough = 0.5; alb *= 0.8 + 0.2 * gnoise(P.xz * 1.5); }
        }
        // lighting: sky ambient + moon + lamp spill + beams + window spill
        float3 amb = skyAmb * PI * (0.55 + 0.45 * n.y);
        float3 mo = moonCol * max(dot(n, md), 0.0);
        float3 Lv = lamp - P;
        float Ld2 = dot(Lv, Lv);
        float Ld = sqrt(Ld2);
        float3 Ln = Lv / Ld;
        float nl = max(dot(n, Ln), 0.0);
        float face = 0.0;
        for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
        // lantern spill: strong just below the lantern (gallery, tower top), 1/r^2 beyond
        float spill = 1400.0 / (Ld2 + 2.0);
        float3 lampL = lampCol * (spill + LW_IBEAM * 0.12 * face / Ld2) * nl * exp(-LW_SIGT * Ld);
        // cottage window spill onto the ground
        float3 wpos = float3(LW_LH.x - 19.0, LW_PAD + 1.8, LW_LH.y - 6.0) + float3(0.0, 0.0, -4.0);
        float3 Wv = wpos - P; float Wd2 = dot(Wv, Wv);
        float3 winL = winCol * 6.0 / (Wd2 + 1.0) * max(dot(n, Wv * rsqrt(Wd2)), 0.0);
        float3 diff = alb * (amb + mo + lampL + winL) / PI;
        // specular (wet rock, masonry): Blinn-Phong-ish with the lamp and the moon
        float3 v = -rd;
        float3 hL = normalize(Ln + v), hM = normalize(md + v);
        float shin = 2.0 / (rough * rough) - 2.0;
        float sL = pow(max(dot(n, hL), 0.0), shin) * (shin + 8.0) / (8.0 * PI);
        float sM = pow(max(dot(n, hM), 0.0), shin) * (shin + 8.0) / (8.0 * PI);
        float fr = spec + (1.0 - spec) * pow(1.0 - max(dot(n, v), 0.0), 5.0);
        float3 specC = fr * (lampCol * (spill + LW_IBEAM * 0.12 * face / Ld2) * nl * sL * exp(-LW_SIGT * Ld) + moonCol * max(dot(n, md), 0.0) * sM);
        col = diff + specC + emit;
    } else {
        // sky
        float3 sky = lw_sky(rd, md, moonIll);
        float2 sp = float2(atan2(rd.x, rd.z), asin(clamp(rd.y, -1.0, 1.0))) * 5.0;
        float3 stars = ws_stars(sp, 22.0, t, 0.18) * 0.028;
        // faint Milky Way band
        {
            float3 Nmw = normalize(float3(0.15, 0.62, -0.77));
            float bd = dot(rd, Nmw);
            float band = exp(-bd * bd / (2.0 * 0.11 * 0.11));
            float tex = 0.5 + 0.5 * fbm(rd.xy * 9.0 + rd.z * 4.0, 3);
            sky += float3(0.010, 0.012, 0.016) * band * tex * smoothstep(0.0, 0.25, rd.y);
        }
        float starMask = smoothstep(-0.01, 0.12, rd.y);
        float mu = dot(rd, md);
        float4 cl = lw_clouds(ro, rd, t, md, moonCol * 9.0, skyAmb * 1.5, mu);
        float3 moon = lw_moonDisc(rd, md);
        col = sky + (stars * starMask + moon) * (1.0 - cl.a);
        col = mix(col, cl.rgb, cl.a);
        tScene = 3000.0;
    }

    // aerial perspective / mist (night: faint blue haze)
    {
        float fogA = ws_fogAmount(min(tScene, 3000.0), ro, rd, 0.0011, 0.018);
        float3 fogC = lw_sky(normalize(float3(rd.x, 0.03, rd.z)), md, moonIll) * 0.9;
        col = mix(col, fogC, fogA * (isSea || hit.x > 0.0 ? 1.0 : 0.35));
    }

    // lighthouse beams (volumetric)
    float3 beam = lw_beamScatter(ro, rd, min(tScene, 2500.0), t, jit, 16, 1.0);
    col += beam * lampCol;

    // lantern glow / flare
    {
        float3 lv = normalize(lamp - ro);
        float ang = acos(clamp(dot(rd, lv), -1.0, 1.0));
        float fl = 0.0;
        for (int b = 0; b < 2; b++) fl += lw_beamProfile(-lv, beamsD[b], beamsS[b], beamsU[b]);
        float occl = (hit.x > 0.0 && hit.x < length(lamp - ro) - 4.0) ? 0.35 : 1.0;   // partially hidden behind terrain
        float3 glow = lampCol * (0.05 + 1.0 * fl) * (0.9 * exp(-ang / 0.0025) + 0.16 * exp(-ang / 0.012) + 0.05 * exp(-ang / 0.06) + 0.012 * exp(-ang / 0.25));
        col += glow * occl;
    }

    col *= LW_EXPO;
    col *= ws_vignette(fragCoord / ctx.res, 0.18);
    col += ws_grain(fragCoord, t) * 0.004;
    return ws_acesFitted(max(col, 0.0));
}
