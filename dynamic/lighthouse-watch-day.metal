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
constant float  LW_EXPO = 1.16;

// lighthouse
constant float2 LW_LH   = float2(-52.0, 232.0);   // tower axis (xz)
constant float  LW_PAD  = 21.0;                   // ground level at the tower
constant float  LW_TWR  = 40.0;                   // masonry tower height above the pad
constant float  LW_R0   = 4.0;                    // tower radius at base
constant float  LW_R1   = 2.05;                   // tower radius at top
constant float  LW_LAMPY = LW_PAD + LW_TWR + 3.0; // lamp height (64 m)

// moon (thin crescent, upper left)
constant float  LW_MOON_AZ = -20.0;               // world azimuth (deg from +z toward +x)
constant float  LW_MOON_EL = 16.0;

// beam
constant float  LW_PHI0   = 100.0 * DEG;          // beam azimuth at t = 0
constant float  LW_BEAM_EL = 0.15 * DEG;           // beam elevation
constant float  LW_TURN   = 9.0;                   // seconds per full revolution
constant float  LW_SH = 1.25 * DEG;                // core sigma, horizontal
constant float  LW_SV = 2.25 * DEG;                // core sigma, vertical
constant float  LW_SHALO = 2.9 * DEG;             // halo sigma
// soft landward sky-glow (a town somewhere behind the camera) — the fill that
// keeps the white masonry and the wet rock from going to dead black.
constant float3 LW_FILLC = float3(0.175, 0.196, 0.268);
constant float  LW_IBEAM = 5.4e5;                 // beam radiant intensity (scene units)
constant float  LW_SIGS  = 0.028;                 // mist scattering coefficient at sea level (1/m)
constant float  LW_SIGT  = 0.0013;                // extinction (1/m) for beam/lamp transmittance

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
    return fbm(p - drift * t, oct);
}
inline float lw_flow3(float3 p, float t, float3 drift, int oct) {
    return fbm(p - drift * t, oct);
}
inline float lw_hg(float c, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * c, 1e-4), 1.5));
}

// ------------------------------------------------------------ terrain
// The terrain is evaluated at a continuous level of detail `dw` in [0,4]: tier k
// contributes with weight clamp(dw-k,0,1) and is SKIPPED outright once that weight
// reaches zero. dw falls off with distance, so a sample 400 m out costs a handful of
// noise lookups while the foreground keeps every crag. Fading (rather than switching)
// each tier means no seam appears where a tier drops out.
inline float lw_tier(float dw, int k) { return clamp(dw - float(k), 0.0, 1.0); }

// coastline signed distance in the horizontal plane (m): negative on land
inline float lw_coast(float2 q, float dw) {
    float w1 = lw_tier(dw, 1);
    float2 w = q + 14.0 * float2(gnoise(q * 0.012 + float2(3.1, 1.7)), gnoise(q * 0.012 + float2(8.3, 5.2)));
    if (w1 > 0.002) w += (4.0 * w1) * float2(gnoise(q * 0.05 + 1.3), gnoise(q * 0.05 + 7.4));
    float d = lw_sdSeg(w, float2(-270.0, 130.0), float2(-46.0, 238.0)) - 34.0;   // headland ridge
    float dm = dot(w - float2(-160.0, 40.0), normalize(float2(1.0, 0.35)));      // mainland
    dm += 30.0 * gnoise(w * 0.0062 + float2(11.4, 4.3));                         // bays and points
    if (w1 > 0.002) dm += (13.0 * w1) * gnoise(w * 0.0185 + float2(3.7, 9.2));
    d = lw_smin(d, dm, 40.0);
    float dn = lw_sdSeg(w, float2(-86.0, -6.0), float2(-34.0, 16.0)) - 9.5;     // foreground shelf
    d = lw_smin(d, dn, 10.0);
    float ds = length(w - float2(-14.0, 254.0)) - 6.5;                           // sea stack off the point
    d = min(d, ds);
    float dk = length(w - float2(55.0, 150.0)) - 3.5;                            // skerry, right
    d = min(d, dk);
    float2 nw = (w - float2(-40.0, 82.0)) * float2(1.0, 0.70);                   // near rocks, lower left
    float dfr = length(nw) - 8.0;
    float dfr2 = length((w - float2(-20.0, 63.0)) * float2(0.9, 1.30)) - 3.4;
    d = min(d, lw_smin(dfr, dfr2, 4.0));
    return d;
}

// Strict LOWER BOUND on lw_coast, with no noise lookups at all: every primitive is
// evaluated on the unwarped point and then the largest possible domain warp (~26 m),
// the mainland's noise amplitude and the smooth-min slack are subtracted. Used by the
// marcher to skip open water in long strides without paying for the real coastline.
inline float lw_coastFast(float2 q) {
    float d = lw_sdSeg(q, float2(-270.0, 130.0), float2(-46.0, 238.0)) - 34.0;
    float dm = dot(q - float2(-160.0, 40.0), normalize(float2(1.0, 0.35))) - 43.0;
    d = min(d, dm);
    d = min(d, lw_sdSeg(q, float2(-86.0, -6.0), float2(-34.0, 16.0)) - 9.5);
    d = min(d, length(q - float2(-14.0, 254.0)) - 6.5);
    d = min(d, length(q - float2(55.0, 150.0)) - 3.5);
    d = min(d, length(q - float2(-40.0, 82.0)) * 0.70 - 8.0);
    d = min(d, length(q - float2(-20.0, 63.0)) * 0.90 - 3.4);
    return d - 46.0;
}

// Conservative UPPER BOUND on lw_height, from lw_coastFast alone — no noise lookups.
// The shore cap clamps the ground to |coast distance| * capK (capK <= 3.25 on land,
// >= 0.55 offshore) plus the buttress amplitude, and the floor is -8 m. Because
// lw_coastFast under-estimates the coast distance, this over-estimates the ground,
// which is exactly what a marcher needs: it can stride until the bound is reached.
inline float lw_hub(float2 q) {
    float cf = lw_coastFast(q);
    float h = 3.6 + (cf > 0.0 ? -0.55 * cf : -3.25 * cf);
    return clamp(h, -8.0, 55.0);
}

// Ground height (m).
inline float lw_heightC(float2 q, float c, float dw) {
    float s = -c;
    if (s < -15.0) return -8.0;
    float w1 = lw_tier(dw, 1), w2 = lw_tier(dw, 2);
    float w0 = lw_tier(dw, 0);
    float top = 22.0 + 18.0 * smoothstep(-120.0, -300.0, q.x);
    if (w0 > 0.002) top += (3.0 * w0) * fbm(q * 0.012 + float2(4.0, 1.0), 2);
    float fg = smoothstep(118.0, 62.0, q.y);
    top = mix(top, 3.2, fg);
    top = mix(top, 5.4, smoothstep(11.0, 2.5, length((q - float2(-40.0, 82.0)) * float2(1.00, 0.72))));
    top = mix(top, 3.3, smoothstep(6.0, 1.5, length((q - float2(-20.0, 63.0)) * float2(0.90, 1.30))));
    top = mix(top, 14.0, smoothstep(20.0, 10.0, length(q - float2(-14.0, 254.0))));
    top = mix(top, 1.9, smoothstep(12.0, 5.0, length(q - float2(55.0, 150.0))));
    float cw = w0 > 0.002 ? mix(8.0, 15.0, 0.5 + 0.5 * gnoise(q * 0.03 + 5.0)) : 11.5;
    float u = clamp(s / cw, 0.0, 1.0);
    float iu = 1.0 - u;
    float prof = 1.0 - iu * iu * iu;
    float h = top * prof;
    // relief lives on the face, not the skyline: a cliff crest is a fairly clean edge
    float crest = 1.0 - smoothstep(0.55, 0.93, prof);
    float rockMask = (1.0 - smoothstep(0.62, 1.0, u)) * (0.40 + 0.60 * crest);
    float rBig = 0.52;
    if (w0 > 0.002) { rBig = ridged(q * 0.018 + float2(8.9, 4.2), 2); h += (rBig - 0.52) * 6.0 * rockMask * w0; }
    float r = 0.55;
    if (w1 > 0.002) {
        r = ridged(q * 0.045 + float2(1.7, 3.3), 2);
        float amp = 3.0 + 3.4 * rBig;               // some stretches sheer, some broken
        h += (r - 0.55) * amp * rockMask * w1;
    }
    // rocky apron at the waterline: boulders and shelves
    if (w2 > 0.002) {
        float ap = smoothstep(-14.0, -2.0, s) * (1.0 - smoothstep(0.0, 8.0, s)) * w2;
        if (ap > 0.001) {
            float2 wcA = worley(q * 0.22 + 0.5 * float2(gnoise(q * 0.1), gnoise(q * 0.1 + 3.0)));
            float bA = sqrt(max(0.0, 1.0 - wcA.x * wcA.x * 1.6)) * 2.2;
            h = max(h, (bA - 0.6 + 0.8 * r) * ap);
        }
    }
    // Shore cap: stops ground overhanging the waterline, and its slope carries the
    // shoreline's ruggedness. The fine component is faded out with distance — at 200 m a
    // 2 m wobble in the cap turns a cliff crest into a comb of spikes.
    float capK = 1.62 + 0.70 * gnoise(q * 0.055 + float2(6.3, 2.9));
    if (w0 > 0.002) capK += (0.55 * w0) * gnoise(q * 0.021 + float2(1.4, 7.6));
    float nearW = smoothstep(155.0, 78.0, q.y) * w2;
    if (nearW > 0.002)
        capK += (0.80 * gnoise(q * 0.17 + float2(2.7, 8.1)) + 0.30 * gnoise(q * 0.52)) * nearW;
    float cd = 0.0;
    if (w1 > 0.002) {
        float faceM = smoothstep(34.0, 3.0, s) * w1;   // the cliff face itself, not the plateau
        if (faceM > 0.004) {
            float b1 = ridged(q * 0.085 + float2(4.4, 1.2), 2) - 0.52;   // ~12 m buttresses
            cd = b1 * 5.0 * faceM;
            if (w2 > 0.002) cd += (ridged(q * 0.245 + float2(8.7, 6.5), 2) - 0.52) * 1.7 * faceM * w2;
        }
    }
    // Smooth, not hard: a hard min leaves a crease straight across every boulder,
    // which reads as a low-poly facet edge at 70 m.
    h = max(lw_smin(h, s * clamp(capK, 0.55, 3.25) + 0.35 + cd, 1.4), -8.0);
    // flatten a pad for the lighthouse and the cottage
    float dp = length((q - float2(LW_LH.x - 8.0, LW_LH.y - 3.0)) * float2(0.7, 1.0));
    float padw = smoothstep(18.0, 10.0, dp) * smoothstep(-2.0, 6.0, s);
    if (padw > 0.0) h = mix(h, LW_PAD + 0.3 * fbm(q * 0.2, 2), padw);
    return h;
}
// Conservative UPPER BOUND on lw_height that needs only the tier-0 coastline (three
// noise lookups) instead of the ~15 the full heightfield costs. Every detail term is
// replaced by its extreme: the steepest shore cap (3.25), the narrowest cliff rounding
// (cw = 8) and the largest possible relief. The marcher strides on this bound and only
// pays for the real ground once it is within a few metres of it.
inline float lw_heightUB(float2 q, float cLo) {
    float s = -cLo;
    if (s < -15.0) return -8.0;
    float top = 25.0 + 18.0 * smoothstep(-120.0, -300.0, q.x);
    top = max(top, 23.0);
    float u = clamp(s / 8.0, 0.0, 1.0);
    float iu = 1.0 - u;
    float prof = 1.0 - iu * iu * iu;
    float h = top * prof + 9.6;
    h = min(h, s * 3.25 + 7.1);
    return max(h, -8.0);
}

inline float lw_height(float2 q, float dw) { return lw_heightC(q, lw_coast(q, dw), dw); }
// detail weight for a sample at range t
inline float lw_dw(float t) { return clamp(3.0 - (t - 95.0) * (3.0 / 430.0), 0.0, 3.0); }

// horizontal bounding capsules of the land (generous); returns t-range where terrain may exist
inline float2 lw_landRange(float3 ro, float3 rd) {
    float2 rng = float2(1e9, -1e9);
    float2 o = ro.xz, d = rd.xz;
    float dl = length(d);
    if (dl < 1e-4) return rng;
    float2 dn = d / dl;
    // capsules: (a, b, radius)
    for (int i = 0; i < 5; i++) {
        float2 a, b; float r;
        if (i == 0) { a = float2(-300.0, 110.0); b = float2(-40.0, 246.0); r = 62.0; }
        else if (i == 1) { a = float2(-80.0, 0.0); b = float2(-12.0, 34.0); r = 26.0; }
        else if (i == 2) { a = float2(-14.0, 254.0); b = a; r = 26.0; }
        else if (i == 3) { a = float2(55.0, 150.0); b = a; r = 22.0; }
        else { a = float2(-40.0, 82.0); b = float2(-20.0, 63.0); r = 26.0; }
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
        float dpl = lw_sdCylY(q, LW_R0 + 0.55, -2.0, 1.4);      // plinth
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
    // Terrain lives entirely in the slab -8 m .. 56 m: clip the search to where the ray
    // is actually inside it (the buildings keep their own t-window).
    {
        float yTop = 56.0, yBot = -8.5;
        if (abs(rd.y) > 1e-5) {
            float ta = (yTop - ro.y) / rd.y, tb = (yBot - ro.y) / rd.y;
            float s0 = min(ta, tb), s1 = max(ta, tb);
            lr.x = max(lr.x, s0); lr.y = min(lr.y, s1);
        } else if (ro.y > yTop || ro.y < yBot) { lr = float2(1e9, -1e9); }
        tStart = min(lr.x, tObj0);
        tEnd = min(max(lr.y, tObj1), tmax);
        if (tStart > tEnd) return float2(-1.0, -1.0);
    }
    float t = max(tStart, 0.3);
    float tPrev = t;
    float dTprev = 1e5;
    for (int i = 0; i < 64; i++) {
        float dwS = lw_dw(t);
        float3 p = ro + rd * t;
        if (p.y > 46.0 && rd.y > 0.0 && (t > tObj1)) break;
        bool inLand = t >= lr.x && t <= lr.y;
        bool inObj = t >= tObj0 && t <= tObj1;
        float dT = 1e5, c = 1e5;
        bool empty = false; float advance = 0.0;
        if (inLand) {
            c = lw_coast(p.xz, dwS);
            if (c > 14.0) { empty = true; advance = max((c - 14.0) * 0.8, 0.4 + t * 0.006); }
            else { float h = lw_heightC(p.xz, c, dwS); dT = (p.y - h) * 0.55; }
        }
        float2 o = float2(1e5, 0.0);
        if (inObj) o = lw_objects(p);
        // Well clear of any ground: advance without running the surface test, so the
        // marcher can never mistake this bookkeeping distance for a hit.
        if (empty && o.x > 1e4) {
            tPrev = t; dTprev = 1e5;
            t += advance;
            if (t > tEnd) break;
            continue;
        }
        // Outside every bounding volume: jump straight to the next one. (Clamping the
        // distance here instead would let the surface-hit test fire on the bounding
        // volume itself and draw a hairline along it.)
        if (!inLand && !inObj) {
            float tNext = 1e9;
            if (t < lr.x) tNext = min(tNext, lr.x);
            if (t < tObj0) tNext = min(tNext, tObj0);
            if (tNext > 1e8) break;
            t = tNext + 1e-3;
            tPrev = t; dTprev = 1e5;
            continue;
        }
        float d = min(dT, o.x);
        // objects carry hard silhouettes (roof ridge, eaves, railing) and need a much
        // tighter hit test than the terrain heightfield, or they stair-step against the sky
        float eps = (o.x < dT) ? (0.00035 * t + 0.0015) : (0.0015 * t + 0.003);
        if (d < eps) {
            float mat = o.x < dT ? o.y : 0.0;
            if (mat == 0.0 && dTprev > 0.0 && dT < 0.0) {
                float a = tPrev, b = t;
                for (int j = 0; j < 5; j++) {
                    float m = 0.5 * (a + b);
                    float3 pm = ro + rd * m;
                    if (pm.y - lw_height(pm.xz, lw_dw(m)) < 0.0) b = m; else a = m;
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
    float dw = lw_dw(t);
    float hx = lw_height(q + float2(e, 0.0), dw) - lw_height(q - float2(e, 0.0), dw);
    float hz = lw_height(q + float2(0.0, e), dw) - lw_height(q - float2(0.0, e), dw);
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
    const float AS[11] = {1.10, 0.78, 0.48, 0.28, 0.165, 0.092, 0.050, 0.029, 0.017, 0.40, 0.155};
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
        h += a * (2.0 * c * sqrt(c) - 1.0);
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
        float df = -1.5 * sqrt(c) * sin(th);         // d/dth of 2 c^1.5 - 1
        g += dir * (a * k * df * w);
        if (i < 3) surge += a * (2.0 * c * sqrt(c) - 1.0);
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
    var += 0.0105 * (1.0 - wr1) + 0.0082 * (1.0 - wr2) + 0.0016;
    return normalize(float3(-g.x, 1.0, -g.y));
}

// ------------------------------------------------------------ lighthouse beam
inline float3 lw_beamDir(float t, int b) {
    float phi = LW_PHI0 + TAU * t * (20.0 / LW_TURN) + (b == 1 ? PI : 0.0);
    return float3(sin(phi) * cos(LW_BEAM_EL), sin(LW_BEAM_EL), cos(phi) * cos(LW_BEAM_EL));
}
// angular profile of the beam for unit direction vn from the lamp
inline float lw_beamProfile(float3 vn, float3 D, float3 S, float3 U) {
    float along = dot(vn, D);
    if (along < 0.3) return 0.0;
    float ah = atan2(dot(vn, S), along), av = atan2(dot(vn, U), along);
    float core = exp(-0.5 * (ah * ah / (LW_SH * LW_SH) + av * av / (LW_SV * LW_SV)));
    float spine = 0.55 * exp(-0.5 * (ah * ah / (0.34 * LW_SH * LW_SH) + av * av / (0.5 * LW_SV * LW_SV)));
    float halo = 0.016 * exp(-0.5 * (ah * ah + av * av) / (LW_SHALO * LW_SHALO));
    float avd = av + 5.0 * DEG;
    float down = 0.055 * exp(-0.5 * (ah * ah / (3.0 * LW_SH * LW_SH) + avd * avd / (34.0 * DEG * DEG)));
    return core + spine + halo + down;
}
// scattering coefficient of the misty air (relative to LW_SIGS)
inline float lw_mist(float3 p, float t) {
    float hgt = exp(-max(p.y, 0.0) / 72.0);
    float n = lw_flow3(p * float3(0.022, 0.040, 0.022), t, float3(16.0, 1.0, 6.0), 3);
    float f = lw_flow3(p * float3(0.075, 0.110, 0.075) + 31.0, t, float3(9.0, 1.5, 3.0), 2);
    float d = 0.44 + 1.95 * n + 1.00 * f;
    // drifting low banks that sit on the sea and thin out with height
    d += 0.9 * exp(-max(p.y, 0.0) / 22.0) * smoothstep(-0.15, 0.45, lw_flow3(p * float3(0.010, 0.05, 0.010) + 7.0, t, float3(22.0, 0.0, 8.0), 2));
    return hgt * clamp(d, 0.10, 2.8);
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
        float w = 4.4 * LW_SHALO;
        if (delta > w * 1.25) continue;
        float edge = 1.0 - smoothstep(w * 0.85, w * 1.25, delta);   // soft, so no hard screen-space seam
        float thStar = atan2(dot(D, rd), dot(D, Ph));
        // sample th over [thStar-w, thStar+w] warped as th = thStar + w*u|u| (u in [-1,1]),
        // with the interval CLAMPED to the visible span [th0, th1] — no per-sample rejection,
        // so nothing pops in and out between neighbouring pixels.
        float x0 = th0 - thStar, x1 = th1 - thStar;
        float ua = clamp(sign(x0) * sqrt(min(abs(x0) / w, 1.0)), -1.0, 1.0);
        float ub = clamp(sign(x1) * sqrt(min(abs(x1) / w, 1.0)), -1.0, 1.0);
        if (ub - ua < 1e-5) continue;
        float acc = 0.0;
        for (int i = 0; i < ns; i++) {
            // only a fraction of the per-pixel jitter: full decorrelation between
            // neighbouring pixels turned the smooth shaft into visible sensor-like speckle
            float jj = fract(jit * 0.26 + float(i) * 0.6180339887);
            float u = mix(ua, ub, (float(i) + jj) / float(ns));
            float th = thStar + w * u * abs(u);
            float jac = 2.0 * w * abs(u);            // dth/du
            float ts = tc + d * tan(th);
            float3 p = ro + rd * ts;
            float3 v = p - L;
            float r = length(v);
            float3 vn = v / max(r, 1e-3);
            float prof = lw_beamProfile(vn, D, S, U);
            if (prof < 1e-4) continue;
            // Striation. A real lens throws an uneven fan — panel joints, dust on the glass,
            // drifting density in the air — so the shaft is streaked, not airbrushed.
            {
                float al = dot(vn, D);
                float ah2 = atan2(dot(vn, S), al), av2 = atan2(dot(vn, U), al);
                float2 ag = float2(ah2, av2) * (1.0 / DEG);
                float n1 = lw_flow2(ag * 0.62 + float2(0.0, 5.0), t, float2(1.6, 0.4), 2);
                float n2 = lw_flow2(ag * 2.30 + float2(9.0, 1.0), t, float2(3.1, 0.8), 2);
                prof *= clamp(0.72 + 0.62 * n1 + 0.30 * n2, 0.16, 1.95);
            }
            float cosSc = dot(vn, -rd);
            float ph = 0.68 * lw_hg(cosSc, 0.62) + 0.32 * 0.0796;
            float sig = lw_mist(p, t);
            float tr = exp(-LW_SIGT * (r + ts));
            float near = r * r / (r * r + 4.0);
            // equiangular weight: (r^2 / d) per unit theta; integrand has 1/r^2 → 1/d
            acc += prof * ph * sig * tr * near * jac / (d * 0.50 + 40.0);
        }
        sum += float3(acc * ((ub - ua) / float(ns)) * edge);
    }
    return sum * (LW_SIGS * LW_IBEAM * strength);
}

// ------------------------------------------------------------ night sky
// Star field in (azimuth, altitude). Cells are sized so a star core lands at ~1.3 px
// at 2560x1600 / 36 deg vFOV — big enough not to scintillate in video, small enough
// to read as a point. Magnitude distribution is heavy-tailed so a few stars dominate.
inline float3 lw_stars(float2 sp, float t, float dense) {
    float3 col = float3(0.0);
    for (int L = 0; L < 3; L++) {
        float sc = 96.0 * (1.0 + 0.77 * float(L));
        float2 q = sp * sc + float2(31.7, 11.3) * float(L);
        float2 id = floor(q);
        float2 f = q - id - 0.5;
        float4 h = hash24(id + float2(7.0, 13.0) * float(L));
        float cut = mix(0.955, 0.760, dense);          // Milky Way is far denser
        if (h.x < cut) continue;
        float2 pos = (h.yz - 0.5) * 0.66;
        float d2 = dot(f - pos, f - pos);
        float mag = pow(h.w, 4.5);                      // few bright, many faint
        float sig = 0.048 + 0.030 * mag;
        float core = exp(-d2 / (sig * sig));
        // slow, shallow scintillation (integer cycles per loop -> loop safe)
        float tw = 0.86 + 0.14 * sin(TAU * (t * (1.0 + floor(h.y * 3.0)) + h.z));
        float3 tint = mix(float3(1.00, 0.80, 0.62), float3(0.70, 0.80, 1.00), smoothstep(0.15, 0.85, h.z));
        col += tint * core * (0.013 + 0.62 * mag) * tw;
    }
    return col;
}
// Faint Milky Way: a broad band of unresolved starlight split by a dark dust rift.
inline float lw_milkyBand(float3 rd) {
    float3 N = normalize(float3(0.246, 0.937, -0.254));
    float bd = dot(rd, N);
    float band = exp(-bd * bd / (2.0 * 0.115 * 0.115));
    // rift: a darker lane offset from the band axis
    float rift = 1.0 - 0.62 * exp(-(bd - 0.055) * (bd - 0.055) / (2.0 * 0.030 * 0.030));
    return band * rift;
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


// =====================================================================
//  TIME OF DAY
// =====================================================================
// World frame is x = east, y = up, z = south. The camera looks toward +z,
// so rotating world vectors by +90 deg about y makes the camera face WEST:
// the sun rises behind the viewer, crosses to the right, and sets out to
// sea straight ahead — the whole point of a west-facing headland.
constant float LW_HEAD = 1.5707963267948966;

// Zenith optical depth of a clear maritime atmosphere, per channel.
constant float3 LW_TR = float3(0.0420, 0.1010, 0.2560);   // Rayleigh
constant float3 LW_TM = float3(0.0215, 0.0250, 0.0300);   // aerosol
constant float  LW_E0 = 16.0;                             // solar scale

// Kasten-Young airmass toward the sun, and the optical depth it implies.
inline float3 lw_sunTau(float el) {
    float e = max(el, -6.0);
    float am = 1.0 / (max(sin(e * DEG), 0.0) + 0.15 * pow(max(e + 3.885, 0.05), -1.253));
    return (LW_TR + LW_TM) * min(am, 40.0);
}
// Direct sunlight colour, normalised so a zenith sun is (near) white.
inline float3 lw_sunColor(float el) {
    return exp(-lw_sunTau(el)) / exp(-(LW_TR + LW_TM));
}
inline float3 lw_sunIrr(float el) {
    return lw_sunColor(el) * (5.4 * smoothstep(-1.5, 1.8, el));
}
// Hemispherical skylight irradiance (the blue fill that colours every shadow).
inline float3 lw_skyIrr(float el) {
    float d = smoothstep(-13.0, 9.0, el);
    float low = smoothstep(16.0, -3.0, el);
    float3 c = mix(float3(0.335, 0.500, 0.900), float3(0.620, 0.430, 0.400), low * 0.70);
    float amp = 0.030 + 0.86 * pow(d, 1.55);
    return c * amp;
}

// Analytic single-scattering sky. Rayleigh + Mie along a view ray whose airmass is
// a smooth rational fit, attenuated by the sun's own slant path, plus a
// multiple-scatter floor so the horizon stays luminous instead of going black.
// ~40x cheaper than marching the atmosphere, and it gives the same sunset colours
// because the reddening comes from the same optical depths.
inline float3 lw_skyAnalytic(float3 rd, float3 sd, float el, float3 sunT) {
    float y = max(rd.y, -0.045);
    // Light scattered toward the zenith is scattered high up, where the sun's own slant
    // path is far shorter — so the top of the dome stays blue while the horizon reddens.
    // Without this the whole sky turns one flat olive wash at low sun.
    // Only while the sun is actually up: after sunset the high-altitude path must go
    // dark with everything else, or twilight turns into a milk-white dome.
    // Light scattered toward the zenith left the sun's beam high in the atmosphere,
    // where its slant path is far shorter, so it is barely reddened even at sunrise.
    // Fading the lift out *with* the sun (the old 22 * smoothstep(-3,5)) reddened the
    // zenith exactly when it should not be, and the blue vault turned olive.
    float zLift = 24.0 * smoothstep(-6.0, 1.0, el);
    float3 zT = exp(-lw_sunTau(el + zLift));
    // Take the HUE of the un-reddened high beam but not its full strength: as the sun
    // sets the zenith has to darken with everything else, or the vault goes pale grey.
    float lz = max(dot(zT, float3(0.3333)), 1e-4);
    float ls = max(dot(sunT, float3(0.3333)), 1e-4);
    zT *= pow(ls / lz, 0.55);
    sunT = mix(sunT, zT, smoothstep(0.010, 0.30, rd.y) * step(0.5, zLift));
    float Mv = 1.09 / (max(y, 0.0) + 0.105);
    float mu = clamp(dot(rd, sd), -1.0, 1.0);
    float pR = 0.0597 * (1.0 + mu * mu);
    const float g = 0.76, gg = 0.5776;
    float pM = 0.0796 * (1.0 - gg) / pow(max(1.0 + gg - 2.0 * g * mu, 2.0e-3), 1.5);
    float3 tauV = (LW_TR + LW_TM) * Mv;
    float3 atten = (1.0 - exp(-tauV)) / max(tauV, 1.0e-4);
    float3 sc = (LW_TR * pR + LW_TM * min(pM, 26.0)) * Mv;
    float3 L = LW_E0 * sunT * sc * atten;
    // multiple scattering: desaturated, strongest where the air is thickest
    // multiple scattering: a modest, horizon-weighted pedestal. Kept small — too much
    // of it is exactly what turns a clear sky into flat white paper.
    float hz = pow(clamp(Mv / 12.1, 0.0, 1.0), 0.85);
    float3 ms = LW_E0 * sunT * (LW_TR * 0.55 + LW_TM * 0.85) * Mv * atten
              * (0.022 + 0.022 * hz) * (0.30 + 0.70 * max(sd.y, 0.0));
    // The optical-depth fit clamps the sun at -6 deg, so without this the forward-scatter
    // glow toward a sunken sun never dies and deep twilight renders as a white dome.
    float below = smoothstep(-4.5, -0.8, el);
    return max(L + ms, 0.0) * below;
}

// Twilight sky. Below the horizon the single-scattering fit above is simply not
// valid — its airmass is clamped, so it paints one flat olive dome. Real civil /
// nautical twilight is a deep blue vault with a warm band that hugs the western
// horizon, shrinks in height and slides orange -> rose -> violet as the sun sinks,
// while the whole dome decays roughly exponentially toward the night floor.
inline float3 lw_skyTwilight(float3 rd, float3 sd, float el) {
    float d = max(-el, 0.0);                       // degrees of sun depression
    float lum = exp(-d * d / 95.0) * exp(-d / 7.0);// smooth decay to the night floor
    float y = max(rd.y, -0.035);
    float3 sh = normalize(float3(sd.x, 0.0, sd.z) + 1e-5);
    float3 vh = normalize(float3(rd.x, 1e-4, rd.z));
    float az = clamp(0.5 + 0.5 * dot(vh, sh), 0.0, 1.0);   // 1 toward the sunken sun
    // the bright segment hugs the horizon and collapses as the sun sinks
    float bandH = 0.030 + 0.155 * exp(-d / 3.0);
    float band  = exp(-max(y, 0.0) / bandH);
    float wide  = exp(-max(y, 0.0) / (bandH * 3.4));
    float glow  = band * pow(az, 1.9 + 0.55 * d);
    // colours: ember orange right at the sun, rose above it, violet off-axis,
    // deep navy at the zenith.
    float3 cEmber = float3(1.00, 0.40, 0.115);
    float3 cRose  = float3(0.62, 0.30, 0.34);
    float3 cViol  = float3(0.155, 0.135, 0.285);
    float3 cZen   = float3(0.030, 0.062, 0.175);
    float3 col = mix(cZen, cViol, wide * (0.55 + 0.35 * az));
    col = mix(col, cRose, clamp(band * (0.35 + 0.65 * az), 0.0, 1.0) * 0.62 * exp(-d / 5.5));
    col += cEmber * glow * (1.35 * exp(-d / 3.6));
    // the anti-solar side keeps a faint cool counter-glow (the Belt of Venus edge)
    col += float3(0.075, 0.085, 0.130) * wide * (1.0 - az) * 0.35 * exp(-d / 4.0);
    return max(col, 0.0) * lum * 0.76;
}

// Daylight atmosphere and twilight, cross-faded across the horizon crossing.
inline float3 lw_skyBase(float3 rd, float3 sd, float el, float3 sunT) {
    float tw = smoothstep(-0.4, -4.2, el);
    float3 c = float3(0.0);
    if (tw < 0.997) c += lw_skyAnalytic(rd, sd, el, sunT) * (1.0 - tw);
    if (tw > 0.003) c += lw_skyTwilight(rd, sd, el) * tw;
    return c;
}

// Night-sky gradient (the original deep-night look), used under the atmosphere.
inline float3 lw_skyNight(float3 rd, float3 md, float moonIll) {
    float h = clamp(rd.y, -0.05, 1.0);
    float3 zen = float3(0.0040, 0.0068, 0.0170);
    float3 hor = float3(0.0210, 0.0282, 0.0470);
    float3 col = mix(hor, zen, 1.0 - exp(-max(h, 0.0) * 3.0));
    float mu = dot(rd, md);
    float ang = acos(clamp(mu, -1.0, 1.0));
    col += float3(0.055, 0.058, 0.070) * moonIll * (0.9 * exp(-ang / 0.05) + 0.35 * exp(-ang / 0.22) + 0.10 * exp(-ang / 0.7));
    col += hor * 0.85 * exp(-max(h, 0.0) / 0.045);
    return col;
}

// Full sky radiance in a direction: physically based atmosphere for day and
// twilight, the night gradient faded in underneath.
inline float3 lw_skyDyn(float3 rd, float3 sd, float el, float3 sunT, float3 md, float moonIll, float nightK) {
    float3 col = lw_skyBase(rd, sd, el, sunT);
    if (nightK > 0.003) col += lw_skyNight(rd, md, moonIll) * nightK;
    return col;
}

// Cheap aerial-perspective / fog colour — no second atmosphere evaluation.
inline float3 lw_hazeCol(float3 rd, float3 sd, float el, float3 sunT, float nightK) {
    float3 h = normalize(float3(rd.x, 0.045, rd.z));
    return lw_skyBase(h, sd, el, sunT) * 0.92 + float3(0.0165, 0.0205, 0.0340) * nightK;
}

// ---------------------------------------------------------------- shadows
// Soft shadow toward a light: the tower as an analytic tapered cylinder plus a
// coarse march of the heightfield (this is what throws the headland's long
// golden-hour shadow across the water).
inline float lw_shadow(float3 P, float3 L, int steps, float far) {
    if (L.y < 0.015) return 0.0;
    float sh = 1.0;
    {   // tower
        float2 d = P.xz - LW_LH;
        float2 lx = L.xz;
        float ll = dot(lx, lx);
        if (ll > 1e-6) {
            float s = -dot(d, lx) / ll;
            if (s > 0.0 && s < 1200.0) {
                float r = length(d + lx * s);
                float y = P.y + L.y * s;
                float u = clamp((y - LW_PAD) / LW_TWR, 0.0, 1.0);
                float rr = mix(LW_R0, LW_R1, u);
                float inY = smoothstep(LW_PAD - 2.0, LW_PAD + 1.0, y) * smoothstep(LW_PAD + LW_TWR + 5.0, LW_PAD + LW_TWR + 1.0, y);
                sh *= mix(1.0, smoothstep(rr * 0.80, rr * 2.1, r), inY);
            }
        }
    }
    float2 lr = lw_landRange(P, L);
    if (lr.x < lr.y) {
        float t0 = max(lr.x, 1.5), t1 = min(lr.y, far);
        if (t1 > t0) {
            float occ = 0.0;
            for (int i = 0; i < steps; i++) {
                float tt = mix(t0, t1, (float(i) + 0.5) / float(steps));
                float3 pp = P + L * tt;
                if (pp.y > 62.0) break;
                float h = lw_height(pp.xz, 1.0);
                occ = max(occ, smoothstep(-3.0, 2.0, h - pp.y));
            }
            sh *= 1.0 - occ * 0.985;
        }
    }
    return sh;
}

// ---------------------------------------------------------------- clouds
// Two sheets in perspective: broken stratocumulus at 1.4 km, high veil at 5.2 km.
// Lit by the sun (silver margins, forward scatter through thin edges) and by the sky.
inline float4 lw_clouds(float3 ro, float3 rd, float t, float3 sd, float3 sunC, float3 amb, float mu) {
    if (rd.y < 0.010) return float4(0.0);
    float3 col = float3(0.0);
    float alpha = 0.0;
    for (int L = 0; L < 2; L++) {
        float H      = (L == 0) ? 5200.0 : 1420.0;
        float baseS  = (L == 0) ? 1.0 / 7200.0 : 1.0 / 2600.0;
        float2 drift = (L == 0) ? float2(760.0, 175.0) : float2(330.0, 76.0);
        float tc = (H - ro.y) / max(rd.y, 1e-4);
        if (tc > 120000.0) continue;
        float2 q = ro.xz + rd.xz * tc;
        float2 wq = q + 430.0 * float2(gnoise(q * (baseS * 1.1) + float2(3.1, 1.7)),
                                       gnoise(q * (baseS * 1.1) + float2(8.3, 5.2)));
        float lodf = smoothstep(34000.0, 9000.0, tc);
        float lodg = smoothstep(72000.0, 20000.0, tc);
        float lodh = smoothstep(11000.0, 3400.0, tc);
        float bias = (L == 0 ? -0.225 : -0.205)
                   + 0.100 * smoothstep(2000.0, -14000.0, q.x)
                   - 0.075 * (1.0 - smoothstep(0.012, 0.075, rd.y))
                   - 0.105 * smoothstep(0.26, 0.70, rd.y) * smoothstep(-2000.0, 9000.0, q.x);
        float lo = (L == 0) ? -0.02 : 0.005, hi = (L == 0) ? 0.34 : 0.275;
        if (lodg > 0.002) {
            float sw = baseS * 4.2;
            wq += (34.0 * lodg) * float2(gnoise(q * sw + float2(17.3, 4.1)),
                                         gnoise(q * sw + float2(1.9, 23.7)));
        }
        float base = lw_flow2(wq * baseS + float2(2.1, 0.6), t, drift * baseS, 4);
        if (base * 1.38 + bias < lo - 0.40) continue;
        float med  = lodg > 0.002 ? lw_flow2(wq * (baseS * 3.4) + float2(9.1, 3.2), t, drift * (baseS * 3.4), 2) : 0.0;
        float bil  = 1.0 - abs(med);
        float det  = lodf > 0.002 ? lw_flow2(wq * (baseS * 12.0) + float2(4.7, 8.8), t, drift * (baseS * 12.0), 2) : 0.0;
        float det2 = lodh > 0.002 ? lw_flow2(wq * (baseS * 34.0) + float2(6.2, 1.4), t, drift * (baseS * 34.0), 2) : 0.0;
        float cov = base * 1.38 + bias + 0.26 * (bil - 0.5) * lodg
                  + 0.165 * det * lodf + 0.085 * det2 * lodh;
        float dens = smoothstep(lo, hi, cov);
        if (lodf > 0.002 && dens > 0.015 && dens < 0.99) {
            float er = lw_flow2(wq * (baseS * 19.0) + float2(12.9, 7.3), t, drift * (baseS * 19.0), 2);
            float rg = 1.0 - abs(er);
            dens = clamp(dens - rg * rg * 0.84 * (1.0 - dens) * lodf, 0.0, 1.0);
        }
        float fade = smoothstep(0.010, 0.050, rd.y);
        float a = (1.0 - exp(-2.3 * dens * dens)) * fade * (L == 0 ? 0.34 : 0.90);
        if (a < 0.0025) continue;
        // sun-facing gradient: sample the coverage field a few km toward the sun,
        // so margins that thin out in that direction get the silver lining
        float2 toSun = normalize(sd.xz + 1e-4) * (L == 0 ? 2600.0 : 950.0);
        float covS = lw_flow2((wq + toSun) * baseS + float2(2.1, 0.6), t, drift * baseS, 3) * 1.42 + bias;
        float grad = clamp((cov - covS) * 2.6 + 0.5, 0.0, 1.0);
        float thin = 1.0 - dens;
        float fwd = lw_hg(mu, 0.60);
        // A flat coverage slab has no vertical form, so the form has to come from the
        // viewing geometry: overhead we are looking down onto sunlit crowns, and near
        // the horizon we are looking into shaded bases. Density then reads as *crown*
        // under a high sun (thick core = tall puff = lit top) instead of as shadow,
        // which is what made the midday sky a field of flat grey cut-outs.
        float high  = smoothstep(-0.02, 0.35, sd.y);
        float crown = smoothstep(0.02, 0.40, rd.y);
        float core  = smoothstep(0.08, 0.72, dens);
        float litF  = mix(grad, mix(grad, core, 0.78), high);
        litF = mix(litF * 0.42, litF, crown);              // bases stay in their own shadow
        float shade = mix(0.58, 1.06, crown);
        // the flank turned away from the sun keeps its own shadow, or every puff
        // flattens into one white paper cut-out
        float selfSh = mix(1.0, 0.66, core * (1.0 - grad));
        // Where the coverage field saturates, a near cloud has no internal variation
        // left and renders as one clipped white slab. Let the detail octaves keep
        // modelling the surface after the density has pinned at 1.
        float bump = 0.5 + 0.5 * (0.62 * det + 0.38 * det2);
        selfSh *= mix(1.0, 0.70 + 0.58 * bump, lodf * core);
        float3 c = amb * (0.46 + 0.54 * thin) * shade * selfSh
                 + sunC * (0.030 + 0.345 * litF * high + 0.175 * grad) * shade * mix(0.75, 1.0, selfSh)
                 + sunC * fwd * 0.62 * thin * (0.25 + 0.75 * dens);
        // Aerial perspective on the cloud deck itself: 40 km of haze sits between the
        // eye and the far edge of the field, so distant cloud must lose contrast and
        // take the horizon's colour. Without this the deck stays equally white to the
        // vanishing point and the sky reads as a flat painted backdrop.
        float apc = 1.0 - exp(-tc * (1.0 / 46000.0));
        c = mix(c, amb * 1.55, apc * 0.72);
        a *= 1.0 - 0.18 * apc;
        col = col * (1.0 - a) + c * a;
        alpha = alpha * (1.0 - a) + a;
    }
    return float4(col / max(alpha, 1e-4), alpha);
}

// ===================================================================== main
// ------------------------------------------------------------ passing boat
// A single small craft crosses the bay every 9-35 minutes of REAL time, takes a
// minute or two to do it, and alternates between a near route across the water in
// front of the headland and a far route that comes out from behind it. The schedule
// is a pure function of the wall clock (day-of-year + local time), so it never
// depends on when the app was launched, and it is irregular because each slot's
// start offset and duration come from a hash.
struct lw_boat_t {
    float3 P;        // hull centre at the waterline (m)
    float2 fwd;      // heading (unit, xz)
    float  on;       // 0 = no boat, 1 = crossing (fades in/out at the frame edges)
    float  len;      // hull length (m)
    float  nav;      // navigation-light colour selector
    float  roll;     // heel from the swell (rad, screen-space tilt)
};

inline lw_boat_t lw_boatState(float dayTime, float doy, float t) {
    lw_boat_t B;
    B.on = 0.0; B.P = float3(0.0, 0.0, 400.0); B.fwd = float2(1.0, 0.0);
    B.len = 9.0; B.nav = 0.0; B.roll = 0.0;
    float mins = dayTime * 60.0;
    const float slot = 22.0;                      // one sailing per 22 min slot, jittered
    // A sailing starts at most 13 min into its slot and lasts at most 4.4 min, so it
    // always finishes inside the same slot: one hash, no neighbour check.
    float kk = floor(mins / slot);
    {
        float3 h = hash33(float3(kk * 0.731, doy * 1.117, 13.77));
        float start = kk * slot + h.x * 13.0;     // => 9..35 min between sailings
        float dur   = 150.0 + h.y * 115.0;        // 2.5..4.4 min end to end
                                                  // (~1-2 min of it inside the frame)
        float tb    = (mins - start) * 60.0;
        if (tb < 0.0 || tb > dur) return B;
        float u = tb / dur;
        // mostly alternating routes, with an occasional repeat so it never feels metronomic
        bool far = fmod(abs(kk) + (h.z > 0.76 ? 1.0 : 0.0), 2.0) >= 1.0;
        float2 a, b;
        if (far) { a = float2( 430.0, 372.0); b = float2(-250.0, 418.0); B.len = 13.0; }
        else     { a = float2( 205.0, 128.0); b = float2( -55.0, 214.0); B.len =  9.5; }
        float2 xz = mix(a, b, u);
        B.fwd = normalize(b - a);
        B.P = float3(xz.x, 0.0, xz.y);
        // ease in/out at the very ends so nothing pops at frame edge
        B.on = smoothstep(0.0, 0.05, u) * smoothstep(1.0, 0.95, u);
        B.nav = h.z;
    }
    if (B.on > 0.0) {
        // Ride the swell. The lift is the real surface (one height lookup); the heel is
        // an oscillator at the swell periods rather than a second and third lookup of the
        // wave field, which would cost several ms across the whole frame for a few pixels.
        B.P.y = lw_seaH(B.P.xz, t, 3);
        B.roll = 0.085 * sin(TAU * (t * 1.0 + B.nav))
               + 0.045 * sin(TAU * (t * 1.73 + B.nav * 2.1 + 0.37));
    }
    return B;
}

// Broad Kelvin wake + a turbulent centre trail, returned as extra foam coverage.
inline float lw_wake(float2 q, lw_boat_t B, float t, float fp) {
    if (B.on <= 0.0) return 0.0;
    float2 rel = q - B.P.xz;
    float2 pr = float2(-B.fwd.y, B.fwd.x);
    float along = -dot(rel, B.fwd);
    if (along < -B.len * 0.6 || along > 140.0) return 0.0;
    float lat = dot(rel, pr);
    float a = max(along, 0.0);
    float fade = exp(-a / 62.0) * B.on;
    // the two arms of the Kelvin V
    float arm = abs(abs(lat) - 0.355 * a);
    float w = 1.25 * exp(-arm / (0.95 + 0.085 * a)) * fade;
    // churned water straight astern
    w += 1.45 * exp(-abs(lat) / (1.15 + 0.060 * a)) * exp(-a / 30.0) * B.on;
    w += 1.30 * exp(-abs(lat) / (B.len * 0.22)) * exp(-abs(along + B.len * 0.42) / (B.len * 0.28)) * B.on;  // bow wave
    // break the ribbons up so they read as foam, not decals
    float n = lw_flow2(q * 0.55, t, float2(3.0, -4.0), 3);
    w *= 0.45 + 1.15 * n;
    w *= smoothstep(9.0, 0.8, fp);                 // dissolve below the pixel footprint
    return clamp(w, 0.0, 1.0);
}

float3 scene(float2 fragCoord, WSCtx ctx) {
    // Motion is continuous seconds. The wave model and the flow-noise fields were
    // written against a 20 s period, so feed them time/20.
    float t = ctx.time * (1.0 / 20.0);
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;

    // camera (unchanged)
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

    // ---------------------------------------------- time of day
    float el = ctx.sunElevation;
    float3 sd = normalize(ws_rotY(ctx.sunDir, LW_HEAD));
    float3 md = normalize(ws_rotY(ctx.moonDir, LW_HEAD));
    float moonIll = ctx.moonIllum;
    float nightK = 1.0 - smoothstep(-13.0, -2.0, el);
    // The keeper lights the lantern around sunset: the lantern room and its
    // near-field spill come up first, and the beam only becomes *visible* in the
    // air as the sky darkens behind it — never a hard on/off switch.
    float lampOn = 1.0 - smoothstep(-1.2, 4.2, el);       // dusk-to-dawn keeper's lamp
    float beamOn = lampOn * mix(0.10, 1.0, 1.0 - smoothstep(-11.0, -0.5, el));
    float winOn  = 1.0 - smoothstep(-3.0, 6.0, el);
    float3 sunT = exp(-lw_sunTau(el));
    float3 sunIrr = lw_sunIrr(el);
    float3 skyIrr = lw_skyIrr(el);
    float3 moonIrr = float3(0.80, 0.86, 1.00) * (0.105 * moonIll * nightK
                    * smoothstep(-0.06, 0.12, md.y));
    float3 lampCol = float3(1.0, 0.86, 0.62);
    float3 winCol  = float3(1.0, 0.50, 0.17);
    float3 fillC   = LW_FILLC * nightK;                    // landward town glow, night only
    float3 lamp = lw_lamp();
    lw_boat_t boat = lw_boatState(ctx.dayTime, float(ctx.dayOfYear), t);

    // ---------------------------------------------- sea intersection window
    float tSea0 = 1e9, tSea1 = 1e9;
    if (rd.y < -1e-4) { tSea0 = max((ro.y - 3.7) / -rd.y, 0.0); tSea1 = (ro.y + 3.7) / -rd.y; }

    float2 hit = lw_march(ro, rd, min(tSea1 + 12.0, 1400.0), 3);
    float tSea = -1.0;
    if (rd.y < -1e-4 && (hit.x < 0.0 || hit.x > tSea0)) {
        float tmax = min(min(tSea1, 2600.0), hit.x > 0.0 ? hit.x : 1e9);
        // The swell is a small displacement of a known plane, so start at the plane
        // crossing and take a few damped Newton steps instead of scanning the ray.
        float ts = clamp(ro.y / -rd.y, tSea0, tmax);
        for (int i = 0; i < 4; i++) {
            float3 pp = ro + rd * ts;
            float fs = pp.y - lw_seaH(pp.xz, t, 6);
            ts = clamp(ts + fs / (-rd.y + 0.55), tSea0, tmax);
        }
        tSea = ts;
        if (hit.x > 0.0) {
            float3 hp = ro + rd * hit.x;
            if (hp.y < lw_seaH(hp.xz, t, 5) + 0.05) tSea = min(tSea, hit.x);
        }
    }

    float3 col;
    float tScene = 1e4;
    bool isSea = tSea > 0.0 && (hit.x < 0.0 || tSea < hit.x);
    float3 beamsD[2], beamsS[2], beamsU[2];
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
        // Unresolved chop blurs the reflection: lift the sample out of the single
        // brightest strip of horizon sky, or distant water renders as a white glare band.
        R.y = abs(R.y) + 0.002 + 0.055 * smoothstep(0.05, 1.6, fp);
        float F = 0.02 + 0.98 * pow(1.0 - nv, 5.0);
        float3 refl = lw_skyDyn(R, sd, el, sunT, md, moonIll * 0.6, nightK);
        // dark headland reflected in the water
        {
            float2 lr = lw_landRange(P, R);
            float gate = 1.0 - smoothstep(680.0, 1150.0, lr.x);
            if (lr.x < lr.y && gate > 0.002) {
                float sh = 0.0;
                // 6 samples, not 10: the reflected headland is a soft dark smear on
                // chopped water, and the extra four full heightfield evaluations per
                // sea pixel cost more than they show.
                for (int i = 0; i < 6; i++) {
                    float tt = mix(lr.x, min(lr.y, 1150.0), (float(i) + 0.5) / 6.0);
                    float3 pp = P + R * tt;
                    if (pp.y < 50.0) {
                        float h = lw_height(pp.xz, 1.0);
                        sh = max(sh, smoothstep(-1.6, 1.6, h - pp.y));
                    }
                }
                float3 landRefl = float3(0.055, 0.055, 0.050) * (skyIrr * 0.5 + sunIrr * 0.05)
                                + float3(0.0025, 0.0036, 0.0060) * nightK;
                refl = mix(refl, landRefl, sh * 0.95 * gate);
            }
        }
        // water body: green-blue subsurface scattering, brighter where the swell is
        // thin and backlit, plus the deep blue that survives to the eye
        float3 tint = float3(0.042, 0.128, 0.132);   // cold Atlantic green, not a lagoon
        float3 deep = float3(0.008, 0.030, 0.058);
        float backlit = clamp(0.35 + 1.4 * max(surge, 0.0) * max(dot(normalize(float3(sd.x, 0.0, sd.z)), normalize(float3(rd.x, 0.0, rd.z))), 0.0), 0.0, 1.6);
        float dayW = smoothstep(-2.0, 9.0, el);
        float3 body = (tint * ((0.060 + 0.115 * dayW) * backlit) + deep * 0.42) * (sunIrr * max(sd.y, 0.0) + skyIrr * 0.85)
                    + fillC * 0.012 + float3(0.0035, 0.0085, 0.0125) * nightK;
        float3 c0 = refl * F + body * (1.0 - F);
        // crests tilted toward the bright horizon catch a thread of light
        {
            float2 gz = float2(n.x, n.z);
            float tilt = clamp(-dot(normalize(gz + 1e-5), normalize(float2(rd.x, rd.z))) * length(gz) * 9.0, 0.0, 1.0);
            float horiz = exp(-max(R.y, 0.0) / 0.10);
            c0 += (skyIrr * 0.055 + float3(0.0165, 0.0225, 0.0380) * nightK) * tilt * horiz * 1.4 * F;
        }
        // unresolved slope variance -> microfacet roughness (keeps highlights from
        // collapsing into contour lines at range)
        // Wind patches: real open water is never one uniform satin sheet — gusts leave
        // roughened, darker cat's-paw fields hundreds of metres across between glassier
        // lanes. This is what gives the middle distance its tonal life.
        float windP;
        {
            float2 wq = float2(P.x * 0.0052 + P.z * 0.0020, P.z * 0.0013);
            windP = 0.5 + 0.5 * lw_flow2(wq, t, float2(2.4, -1.3) * 0.0040, 3);
            windP = mix(windP, 0.5 + 0.5 * lw_flow2(wq * 3.1 + 19.0, t, float2(2.4, -1.3) * 0.0124, 2), 0.42);
            windP = mix(windP, 0.5 + 0.5 * lw_flow2(wq * 11.0 + 5.0, t, float2(2.4, -1.3) * 0.044, 2), 0.24);
            windP = clamp(windP * 1.35 - 0.16, 0.0, 1.0);
        }
        float a2 = clamp((var * 3.6 + 0.030 * smoothstep(0.10, 2.4, fp) + 0.004)
                         * (0.68 + 0.85 * windP), 0.012, 0.50);
        // Roughened lanes show more of the dark water body and less mirror sky; this is
        // the tonal relief that stops the middle distance reading as a satin sheet.
        c0 = mix(c0, c0 * (1.0 - 0.40 * F) + body * 0.26 * F, windP);
        // sun glitter path
        if (sunIrr.g > 0.001 && sd.y > 0.0) {
            float am = clamp(a2 * 1.25, 0.014, 0.50);
            float3 hv = normalize(sd + v);
            float nh = max(dot(n, hv), 0.0);
            float nl = max(dot(n, sd), 0.0);
            float dd = nh * nh * (am - 1.0) + 1.0;
            float D = am / (PI * dd * dd);
            // Smith height-correlated visibility. Without it the 1/(n.v) of the microfacet
            // BRDF runs away at grazing angles and paints a white bar across the horizon.
            float Vis = 0.5 / max(nl * sqrt(nv * nv * (1.0 - am) + am)
                                + nv * sqrt(nl * nl * (1.0 - am) + am), 1.0e-4);
            float ssh = 1.0;
            if (el < 14.0) ssh = lw_shadow(P + float3(0.0, 0.6, 0.0), sd, 6, 700.0);
            c0 += sunIrr * D * Vis * F * nl * ssh;
        }
        // lamp glitter (night only)
        if (lampOn > 0.003) {
            float3 Lv = lamp - P; float Ld = length(Lv); float3 Ln = Lv / Ld;
            float3 hv = normalize(Ln + v);
            float nh = max(dot(n, hv), 0.0);
            float dd = nh * nh * (a2 - 1.0) + 1.0;
            float D = a2 / (PI * dd * dd);
            float face = 0.0;
            for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
            float I = (1500.0 + LW_IBEAM * 0.55 * face) * lampOn;
            float tr = exp(-LW_SIGT * Ld);
            float irr = I / (Ld * Ld) * max(dot(n, Ln), 0.0) * tr;
            c0 += lampCol * irr * D * F * 0.25 / max(nv, 0.05) * 0.5;
            c0 += lampCol * irr * 0.024 * (0.25 + 0.75 * F);
        }
        if (nightK > 0.003) {   // moon glitter
            float am = clamp(a2 * 1.45, 0.016, 0.50);
            float3 hv = normalize(md + v);
            float nh = max(dot(n, hv), 0.0);
            float dd = nh * nh * (am - 1.0) + 1.0;
            float D = am / (PI * dd * dd);
            c0 += moonIrr * 13.0 * D * F * 0.25 * max(dot(n, md), 0.0) / max(nv, 0.05) * 0.5;
        }
        // foam where the swell meets rock
        float cst = lw_coast(P.xz, 3.0);
        float foam = 0.0;
        if (cst < 22.0) {
            float run = clamp(surge * 0.9, -1.0, 1.2);
            const float2 fdr = float2(2.6, -5.0);
            float2 fq = P.xz;
            float w0 = lw_flow2(fq * 0.24, t, fdr * 0.24, 3);
            float w1 = lw_flow2(fq * 0.24 + 37.0, t, fdr * 0.24, 3);
            fq += (float2(w0, w1) - 0.5) * 11.0;
            float f2 = lw_flow2(fq * 0.85, t, fdr * 0.85, 4);
            float f3 = lw_flow2(fq * 3.10 + 17.0, t, fdr * 3.10, 3);
            float f4 = lw_flow2(fq * 9.60 + 5.0, t, fdr * 9.60, 2);
            float lace = f2 * 0.52 + f3 * 0.31 + f4 * 0.17;
            float edge = 3.2 + 3.8 * run;
            float band = smoothstep(edge + 12.5, edge - 3.0, cst) * smoothstep(-9.5, -1.0, cst);
            float thr = 0.355 - 0.63 * band;
            float soft = 0.085 + 0.150 * (1.0 - band);
            foam = smoothstep(thr, thr + soft, lace);
            foam *= 0.26 + 0.74 * band;
            float veil = smoothstep(21.0, 4.0, cst) * smoothstep(0.05, 0.28, lace) * (0.24 + 0.30 * run);
            foam = max(foam, clamp(veil, 0.0, 0.40));
            foam *= smoothstep(13.0, 1.2, fp);
        }
        if (boat.on > 0.0) foam = max(foam, lw_wake(P.xz, boat, t, fp));
        if (foam > 0.0) {
            float3 nf = normalize(mix(float3(0.0, 1.0, 0.0), n, 0.55));
            float fsh = (sd.y > 0.0 && el < 14.0) ? lw_shadow(P + float3(0.0, 0.8, 0.0), sd, 6, 620.0) : 1.0;
            float3 lit = skyIrr * (0.55 + 0.45 * nf.y)
                       + sunIrr * max(dot(nf, sd), 0.0) * fsh
                       + moonIrr * max(dot(nf, md), 0.0) * 1.2
                       + fillC * 0.85;
            if (lampOn > 0.003) {
                float3 Lv = lamp - P; float Ld2 = dot(Lv, Lv); float3 Ln = Lv * rsqrt(Ld2);
                float face = 0.0;
                for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
                lit += lampCol * (2400.0 + LW_IBEAM * 0.55 * face) * lampOn / Ld2 * max(dot(nf, Ln), 0.0) * exp(-LW_SIGT * sqrt(Ld2));
            }
            // aerated water: a dense cloud of bubbles, high albedo, strongly scattering
            float3 fc = float3(0.90, 0.93, 0.95) * lit * (1.05 / PI);
            c0 = mix(c0, fc, foam * 0.90);
        }
        // beam reflected in the water
        if (lampOn > 0.003) {
            float3 nB = normalize(mix(float3(0.0, 1.0, 0.0), n, 0.34));
            float3 RB = reflect(rd, nB); RB.y = abs(RB.y) + 0.002;
            float3 bref = lw_beamScatter(P + float3(0.0, 0.05, 0.0), RB, 1500.0, t, jit, 8, beamOn);
            c0 += bref * lampCol * F * (1.0 - foam);
        }
        c0 *= 1.0 - 0.22 * smoothstep(170.0, 45.0, tSea) * nightK;
        col = c0;
    } else if (hit.x > 0.0) {
        tScene = hit.x;
        float3 P = ro + rd * hit.x;
        float3 n;
        float3 alb;
        float3 emit = float3(0.0);
        float rough = 0.6;
        float spec = 0.03;
        float ao = 1.0;
        if (hit.y == 0.0) {
            n = lw_terrainNormal(P.xz, hit.x, 3);
            {   // Fine rock relief. This has to be a 3D field: an xz-projected bump has
                // no variation along y at all, so on a near-vertical sea cliff it smears
                // into long silky vertical ribbons — the single biggest "CG" tell on the
                // whole headland. Perturb along the true surface gradient instead.
                float e = max(0.05, hit.x * 0.0013);
                float3 q = P * 1.45;
                float b0 = fbm(q, 2);
                float3 gb = float3(fbm(q + float3(e, 0.0, 0.0) * 1.45, 2),
                                   fbm(q + float3(0.0, e, 0.0) * 1.45, 2),
                                   fbm(q + float3(0.0, 0.0, e) * 1.45, 2)) - b0;
                gb /= (e * 1.45);
                gb -= n * dot(gb, n);                       // tangential component only
                gb = clamp(gb, -2.5, 2.5);
                n = normalize(n - gb * 0.20 * smoothstep(250.0, 45.0, hit.x));
                // a second, much finer grain for the nearest boulders
                float dn2 = smoothstep(120.0, 28.0, hit.x);
                if (dn2 > 0.01) {
                    float3 q2 = P * 6.4;
                    float c0 = fbm(q2, 2);
                    float3 g2 = float3(fbm(q2 + float3(0.10, 0.0, 0.0), 2),
                                       fbm(q2 + float3(0.0, 0.10, 0.0), 2),
                                       fbm(q2 + float3(0.0, 0.0, 0.10), 2)) - c0;
                    g2 /= 0.10;
                    g2 -= n * dot(g2, n);
                    g2 = clamp(g2, -2.5, 2.5);
                    n = normalize(n - g2 * 0.040 * dn2);
                }
            }
            float slope = 1.0 - n.y;
            float dFine = smoothstep(240.0, 85.0, hit.x);
            float dMid  = smoothstep(760.0, 150.0, hit.x);   // decimetre features stay visible at 230 m
            float bslope = smoothstep(0.022, 0.21, slope);
            float outcrop = smoothstep(0.30, 0.72, 0.5 + 0.5 * gnoise(P.xz * 0.028 + 9.1));
            float bexp = bslope * (0.55 + 0.45 * outcrop);
            float dip = 0.048 * P.x + 0.026 * P.z;
            float bp = (P.y + dip) * 0.68 + 1.55 * gnoise(P.xz * 0.030) + 0.42 * gnoise(P.xz * 0.145)
                     + 0.20 * gnoise(P.xz * 0.62) + 0.085 * gnoise(P.xz * 2.4);
            float bi = floor(bp);
            float bu = bp - bi;
            float3 bh = hash33(float3(bi, 3.7, 1.3));
            bu = pow(bu, 0.50 + 1.25 * bh.x);
            float bedTone = 0.56 + 0.20 * bh.y;
            // Analytic AA: a bedding plane thinner than a pixel must be widened and faded,
            // or it draws a hairline straight across the cliff like a scanline.
            float pwB = clamp(0.68 * hit.x * pixA * 2.2, 0.010, 0.44);
            float pFade = 1.0 - smoothstep(0.10, 0.40, pwB);
            float parting = (smoothstep(0.085 + pwB, 0.0, bu) + smoothstep(0.925 - pwB, 1.0, bu)) * pFade;
            float strata = clamp(bedTone * (1.0 - 0.40 * parting), 0.0, 1.0);
            float jp = (P.x * 0.285 - P.z * 0.165) + 1.15 * gnoise(P.xz * 0.075) + 0.06 * P.y;
            float joint = smoothstep(0.085, 0.012, abs(jp - floor(jp) - 0.5)) * (0.45 + 0.55 * bh.z);
            // wet dark headland stone: albedo 0.07-0.26, never chalk
            float3 rock = mix(float3(0.044, 0.043, 0.043), float3(0.150, 0.139, 0.124), strata * strata);
            rock *= mix(1.0, 0.54, joint * bexp);
            // Vertical fluting: rain and spray run DOWN a sea cliff, so its dominant
            // texture is a set of near-vertical gullies and stains, not the horizontal
            // bedding. Without this the strata read as contour lines on a CG blob.
            {
                float2 fq = float2(P.x * 0.62 - P.z * 0.38, P.y * 0.055);
                float fl = fbm(fq, 3);
                float fl2 = fbm(fq * 3.3 + 11.0, 2);
                float flute = 0.70 + 0.44 * fl + 0.16 * fl2;
                float fluteK = bexp * dMid * smoothstep(3.0, 11.0, P.y);
                rock *= mix(1.0, clamp(flute, 0.42, 1.30), fluteK);
                // the gullies are grooves: tip the normal sideways and darken their floors
                float fgx = fbm(fq + float2(0.05, 0.0), 3) - fl;
                n = normalize(n + float3(0.62, 0.0, -0.38) * fgx * 3.4 * fluteK);
                ao *= 1.0 - 0.34 * smoothstep(0.66, 0.10, flute) * fluteK;
            }
            rock *= 0.82 + 0.34 * fbm(float3(P.x, P.y * 0.62, P.z) * 0.17, 3);
            rock *= mix(1.0, 0.84 + 0.32 * fbm(float3(P.x, P.y * 0.8, P.z) * 0.9, 3), dFine);
            // grain: fine mineral speckle, carried as albedo rather than as more normal
            // tilt, so it never flips a facet in or out of the sun
            rock *= mix(1.0, 0.80 + 0.40 * fbm(P * 3.2, 2), dFine * 0.9);
            rock = mix(float3(0.092, 0.087, 0.081) * (0.84 + 0.32 * fbm(P.xz * 0.30, 3)), rock, bexp);
            {   // parting planes are ledges that catch grazing light
                float ledge = smoothstep(0.38, 0.95, parting) * bexp;
                n = normalize(n + float3(0.0, 1.0, 0.0) * ledge * 0.42
                                + float3(n.x, 0.0, n.z) * (joint * bexp * -0.30));
                ao *= 1.0 - 0.30 * joint * bexp - 0.14 * bslope;
                // a cliff face is also shut in by its own neighbours, not just by its
                // own orientation: deepen the gullies and keep the crest open
                ao *= 1.0 - 0.30 * smoothstep(0.10, 0.62, slope) * smoothstep(2.0, 12.0, P.y);
            }
            // clifftop maritime turf: wind-burnt olive, yellower on the exposed crown
            float3 grass = mix(float3(0.086, 0.132, 0.050), float3(0.168, 0.158, 0.072),
                               smoothstep(0.26, 0.76, 0.5 + 0.5 * gnoise(P.xz * 0.055 + 2.3)));
            grass *= max(0.42, 0.82 + 0.46 * fbm(P.xz * 0.115 + 1.7, 3));
            grass *= mix(1.0, 0.78 + 0.44 * fbm(P.xz * 0.55, 3), dFine);
            float g = smoothstep(0.44, 0.12, slope) * smoothstep(14.0, 21.0, P.y) * (0.40 + 0.60 * smoothstep(0.25, 0.70, 0.5 + 0.5 * gnoise(P.xz * 0.22)));
            alb = mix(rock, grass, g);
            float wet = smoothstep(3.4, 0.4, P.y);
            float mott = mix(1.0, 0.72 + 0.56 * fbm(float3(P.x, P.y * 0.75, P.z) * 1.9, 3), dFine);
            alb *= mott;
            // A faint dried-salt / lichen line just above the splash zone — subtle, and
            // broken up at two scales so it never reads as blotches of white paint.
            float splash = smoothstep(0.6, 2.2, P.y) * smoothstep(5.2, 3.0, P.y)
                         * smoothstep(0.40, 0.86, 0.5 + 0.5 * gnoise(P.xz * 1.1))
                         * (0.45 + 0.55 * fbm(P.xz * 4.5 + 3.0, 3));
            alb = mix(alb, float3(0.155, 0.150, 0.140), clamp(splash, 0.0, 1.0) * 0.30);
            alb *= mix(1.0, 0.34, wet);
            rough = mix(0.86, 0.34, wet);
            spec = mix(0.018, 0.055, wet);
        } else {
            n = lw_objNormal(P);
            int m = int(hit.y + 0.5);
            alb = m == 1 ? float3(0.80, 0.78, 0.74) : (m == 2 || m == 7) ? float3(0.05, 0.05, 0.055) : m == 3 ? float3(0.02) : m == 4 ? float3(0.70, 0.66, 0.60) : float3(0.14, 0.07, 0.05);
            if (m == 1) {
                float3 q = P - float3(LW_LH.x, LW_PAD, LW_LH.y);
                float ang = atan2(q.z, q.x);
                float tex = 0.88 + 0.12 * gnoise(float2(ang * 6.0, q.y * 0.8));
                float cy = q.y * 1.35;
                float ci = floor(cy);
                float3 ch = hash33(float3(ci, 4.1, 2.6));
                float course = 0.955 + 0.045 * smoothstep(0.05, 0.16, abs(cy - ci - 0.5));
                course *= 0.93 + 0.14 * ch.x;
                float weather = 0.82 + 0.18 * fbm(float2(ang * 3.0, q.y * 0.35) * 1.6, 3);
                alb *= tex * course * weather;
                spec = 0.028 + 0.030 * ch.y;
                alb *= mix(0.62, 1.0, smoothstep(0.0, 9.0, q.y));
                float band = smoothstep(2.1, 1.6, abs(q.y - (LW_TWR - 6.2)));
                alb = mix(alb, float3(0.40, 0.085, 0.065), band * 0.92);
                rough = 0.62;
                float3 toCam = normalize(float3(-LW_LH.x, 0.0, -LW_LH.y));
                float facing = dot(normalize(float3(q.x, 0.0, q.z)), toCam);
                float pwT = max(hit.x * pixA, 0.012);
                for (int wI = 0; wI < 3; wI++) {
                    float wy = 9.0 + 10.5 * float(wI);
                    float lat = length(float2(dot(float2(q.x, q.z), float2(-toCam.z, toCam.x)), 0.0));
                    float win = smoothstep(0.55 + pwT, 0.55 - pwT, abs(q.y - wy))
                              * smoothstep(0.30 + pwT, 0.30 - pwT, lat)
                              * smoothstep(0.45, 0.58, facing);
                    emit += winCol * 0.95 * win * winOn;
                    alb = mix(alb, float3(0.06, 0.05, 0.045), win);   // dark glazing by day
                }
            }
            if (m == 3) {
                // lantern glass: the lens is dark glass by day and only lights at dusk
                float3 q = P - float3(LW_LH.x, LW_PAD + LW_TWR + 1.2, LW_LH.y);
                float ang = atan2(q.z, q.x);
                float pwL = max(hit.x * pixA, 0.010) * 1.2;
                float mull = smoothstep(0.44 + 0.06, 0.44 - 0.06, abs(fract(ang / TAU * 12.0) - 0.5))
                           * smoothstep(1.35 + pwL, 1.35 - pwL, abs(q.y - 1.6))
                           * smoothstep(0.08 - pwL, 0.08 + pwL, abs(q.y - 1.6));
                float3 toCam = normalize(ro - P);
                float face = 0.0;
                for (int b = 0; b < 2; b++) face += lw_beamProfile(toCam, beamsD[b], beamsS[b], beamsU[b]);
                emit = lampCol * (2.2 + 45.0 * face) * mull * lampOn;
                alb = float3(0.018);
                rough = 0.10;
                spec = 0.18;      // sun glints off the lens panels
            }
            if (m == 4) {
                float3 q = lw_cottageLocal(P);
                float pwC = max(hit.x * pixA, 0.010);
                float wx = fract((q.x + 6.5) / 3.25) - 0.5;
                float win = smoothstep(0.19 + pwC / 3.25, 0.19 - pwC / 3.25, abs(wx))
                          * smoothstep(0.6 + pwC, 0.6 - pwC, abs(q.y - 1.8))
                          * smoothstep(-3.5 + pwC, -3.5 - pwC, q.z)
                          * smoothstep(6.0 + pwC, 6.0 - pwC, abs(q.x));
                float wa = smoothstep(0.55 + pwC, 0.55 - pwC, abs(q.x - 8.9))
                         * smoothstep(0.5 + pwC, 0.5 - pwC, abs(q.y - 1.6))
                         * smoothstep(-2.6 + pwC, -2.6 - pwC, q.z);
                float wglow = smoothstep(2.10, 0.28, abs(wx) * 3.25) * smoothstep(2.3, 0.45, abs(q.y - 1.8))
                            * step(q.z, -3.4) * smoothstep(6.6, 5.6, abs(q.x));
                emit = winCol * (1.7 * max(win, wa) + 0.34 * wglow) * winOn;
                alb = mix(alb * (0.92 + 0.08 * gnoise(q.xy * 2.0)), float3(0.055, 0.05, 0.048), max(win, wa));
            }
            if (m == 5) { rough = 0.5; alb *= 0.8 + 0.2 * gnoise(P.xz * 1.5); }
        }

        // ---------------- lighting
        float ssh = 0.0;
        if (sd.y > 0.005) ssh = lw_shadow(P + n * 0.55, sd, 9, 900.0);
        float3 sunL = sunIrr * max(dot(n, sd), 0.0) * ssh;
        // A vertical cliff face sees roughly half the sky; the old 0.42 pedestal lit it
        // almost as brightly as the plateau, which is what flattened the headland into
        // one pale grey shape with no read of its own form.
        float3 ambL = skyIrr * (0.14 + 0.86 * clamp(0.5 + 0.5 * n.y, 0.0, 1.0)) * ao;
        float3 mo = moonIrr * max(dot(n, md), 0.0);
        const float3 fillD = normalize(float3(0.20, 0.40, -0.89));
        float3 fill = fillC * (0.10 + 0.90 * max(dot(n, fillD) * 0.85 + 0.15, 0.0));
        // bounce: cool light up off the sea onto the cliff faces, warm off the sunlit turf
        float3 bnc = float3(0.30, 0.46, 0.52) * (sunIrr * 0.030 + skyIrr * 0.060) * clamp(0.25 - n.y, 0.0, 1.0) * 2.4
                   + float3(0.36, 0.34, 0.24) * sunIrr * 0.022 * clamp(n.y, 0.0, 1.0) * max(sd.y, 0.0);
        // lamp spill (night only)
        float3 lampL = float3(0.0), winL = float3(0.0);
        float3 Lv = lamp - P;
        float Ld2 = dot(Lv, Lv);
        float Ld = sqrt(Ld2);
        float3 Ln = Lv / Ld;
        float nl = max(dot(n, Ln), 0.0);
        float face = 0.0;
        if (lampOn > 0.003) {
            for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
            float spill = 1400.0 / (Ld2 + 2.0);
            lampL = lampCol * (spill + LW_IBEAM * 0.12 * face / Ld2) * lampOn * nl * exp(-LW_SIGT * Ld);
            float3 gp = lamp - float3(0.0, 2.6, 0.0);
            float3 Gv = gp - P; float Gd2 = dot(Gv, Gv); float3 Gn = Gv * rsqrt(Gd2);
            float aim = smoothstep(-0.25, 0.85, -Gn.y);
            lampL += lampCol * 520.0 * lampOn * aim / (Gd2 + 9.0) * (0.30 + 0.70 * max(dot(n, Gn), 0.0)) * ((hit.y == 2.0 || hit.y == 7.0) ? 0.45 : 1.0);
        }
        if (winOn > 0.003) {
            float3 wpos = float3(LW_LH.x - 19.0, LW_PAD + 1.8, LW_LH.y - 6.0) + float3(0.0, 0.0, -4.0);
            float3 Wv = wpos - P; float Wd2 = dot(Wv, Wv);
            winL = winCol * 6.0 * winOn / (Wd2 + 1.0) * max(dot(n, Wv * rsqrt(Wd2)), 0.0);
        }
        float3 diff = alb * (ambL + sunL + mo + fill + bnc + lampL + winL) / PI;
        // specular
        float3 v = -rd;
        float3 hS = normalize(sd + v), hM = normalize(md + v), hL = normalize(Ln + v);
        float shin = 2.0 / (rough * rough) - 2.0;
        float norm = (shin + 8.0) / (8.0 * PI);
        float fr = spec + (1.0 - spec) * pow(1.0 - max(dot(n, v), 0.0), 5.0);
        float3 specC = fr * (sunIrr * max(dot(n, sd), 0.0) * ssh * pow(max(dot(n, hS), 0.0), shin) * norm
                           + moonIrr * max(dot(n, md), 0.0) * pow(max(dot(n, hM), 0.0), shin) * norm);
        if (lampOn > 0.003) {
            float spill = 1400.0 / (Ld2 + 2.0);
            specC += fr * lampCol * (spill + LW_IBEAM * 0.12 * face / Ld2) * lampOn * nl
                   * pow(max(dot(n, hL), 0.0), shin) * norm * exp(-LW_SIGT * Ld);
        }
        // silhouette rim: cold at night, sky-coloured by day
        float rim = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 3.5);
        float3 rimC = mix(skyIrr * 0.20, float3(0.42, 0.50, 0.66) * smoothstep(-0.1, 0.5, dot(n, md)), nightK);
        float rimK = (hit.y == 1.0) ? 0.115 : (0.058 + 0.075 * smoothstep(260.0, 60.0, hit.x));
        col = diff + specC + emit + rimC * rim * rimK * (0.35 + 0.65 * alb.g);
    } else {
        // ---------------- sky
        float3 sky = lw_skyDyn(rd, sd, el, sunT, md, moonIll, nightK);
        {
            float3 sc = lw_sunColor(el);
            float ints = mix(190.0, 900.0, smoothstep(0.0, 13.0, el));
            sky += ws_sunDisk(rd, sd, 0.265 + 0.30 * smoothstep(10.0, 0.0, el),
                              sc * ints * smoothstep(-1.2, 0.6, el));
            // the aureole a low sun burns into hazy air
            float sa = acos(clamp(dot(rd, sd), -1.0, 1.0));
            // The aureole never really goes away — even a high sun sits in a small
            // bright halo of forward-scattered aerosol, and low sun burns a much
            // wider one. Without the wide skirt the disc reads as a pasted dot.
            sky += sc * (2.6 * exp(-sa / 0.035) + 0.75 * exp(-sa / 0.13) + 0.085 * exp(-sa / 0.38))
                 * smoothstep(-1.0, 3.0, el) * (0.22 + 0.78 * smoothstep(16.0, 1.0, el));
        }
        if (nightK > 0.003) {
            float2 sp = float2(atan2(rd.x, rd.z), asin(clamp(rd.y, -1.0, 1.0)));
            float mw = lw_milkyBand(rd);
            float tex = 0.55 + 0.50 * fbm(sp * 7.5 + float2(3.3, 1.9), 4);
            sky += float3(0.0300, 0.0318, 0.0400) * mw * tex * smoothstep(0.02, 0.30, rd.y) * nightK;
            float3 stars = lw_stars(sp, t, mw);
            float aur = 1.0 - 0.75 * exp(-acos(clamp(dot(rd, md), -1.0, 1.0)) / 0.20);
            float starMask = smoothstep(0.012, 0.135, rd.y) * aur * nightK;
            sky += stars * starMask + lw_moonDisc(rd, md) * smoothstep(-0.02, 0.06, md.y) * nightK;
        }
        float mu = dot(rd, sd);
        float4 cl = lw_clouds(ro, rd, t, sd, sunIrr, skyIrr * 0.55 + float3(0.015, 0.021, 0.039) * nightK, mu);
        col = mix(sky, cl.rgb, cl.a);
        tScene = 3000.0;
    }

    // ---------------- aerial perspective
    {
        // Clear maritime air: ~12 km meteorological visibility by day, a little
        // thicker at night. The headland is only ~230 m out, so it must stay almost
        // untouched — aerial perspective belongs to the horizon, not the foreground.
        float dens = mix(0.00068, 0.00022, smoothstep(-6.0, 10.0, el));
        float fogA = ws_fogAmount(min(tScene, 6000.0), ro, rd, dens, 0.010);
        float3 fogC = lw_hazeCol(rd, sd, el, sunT, nightK);
        col = mix(col, fogC, fogA * (isSea || hit.x > 0.0 ? 1.0 : 0.30));
    }


    // ---------------- passing boat (a sprite composited at its own depth)
    if (boat.on > 0.003) {
        float3 bd = boat.P + float3(0.0, 0.05, 0.0) - ro;
        float dist = length(bd);
        float3 nd = bd / dist;
        float fwdd = dot(rd, nd);
        if (fwdd > 0.25 && dist < tScene + 5.0) {
            float3 rgt = normalize(cross(nd, float3(0.0, 1.0, 0.0)));
            float3 upv = cross(rgt, nd);
            float3 vv = rd * (dist / fwdd) - bd;
            float sx0 = dot(vv, rgt), sy0 = dot(vv, upv);
            float cr = cos(boat.roll), sr = sin(boat.roll);
            float sx = sx0 * cr + sy0 * sr, sy = -sx0 * sr + sy0 * cr;
            float3 fw3 = float3(boat.fwd.x, 0.0, boat.fwd.y);
            float side = length(cross(fw3, nd));          // 1 broadside, 0 end-on
            float L = boat.len * max(side, 0.20);
            float dirs = (dot(fw3, rgt) < 0.0) ? -1.0 : 1.0;
            float x = sx * dirs;
            float hl = L * 0.5;
            float px = dist * pixA;                       // pixel footprint in metres, at the boat
            float aa = max(px * 0.70, 1.0e-4);
            float xn = clamp(x / max(hl, 1.0e-3), -1.35, 1.35);
            float x4 = xn * xn * xn * xn;
            // A working boat sits almost entirely ABOVE the water: ~0.75 m of freeboard,
            // sheer rising to the stem. Drawing the submerged hull is what makes a sprite
            // read as a black bowl, so the silhouette stops a few cm under the surface.
            float top = 0.70 + 0.62 * x4;
            float bot = -0.16 - 0.10 * (1.0 - x4);
            float inX = smoothstep(hl + aa, hl - aa, abs(x));
            float hull = inX * smoothstep(top + aa, top - aa, sy) * smoothstep(bot - aa, bot + aa, sy);
            float cw = 1.25 * max(side, 0.30);
            float cab = smoothstep(cw + aa, cw - aa, abs(x + hl * 0.20))
                      * smoothstep(2.15 + aa, 2.15 - aa, sy) * smoothstep(0.62 - aa, 0.62 + aa, sy);
            float roof = cab * smoothstep(1.86 - aa, 1.86 + aa, sy);
            float mast = smoothstep(0.085 + aa, 0.085 - aa, abs(x - hl * 0.12))
                       * smoothstep(4.05 + aa, 4.05 - aa, sy) * smoothstep(1.90 - aa, 1.90 + aa, sy);
            float cov = clamp(max(max(hull, cab), mast * 0.85), 0.0, 1.0);
            // masthead navigation light: one tiny point, all that is visible at night
            float2 np = float2(x - hl * 0.12, sy - 4.15) / max(px * 1.5, 0.20);
            float nr2 = dot(np, np);
            float navG = exp(-nr2) * winOn;
            float navH = (0.30 * exp(-nr2 * 0.12) + 0.10 * exp(-nr2 * 0.02)) * winOn;
            cov = max(cov, max(navG * 0.92, navH * 0.55)) * boat.on;
            if (cov > 0.002) {
                // dark hull, pale sheer strake along the gunwale, a green boot-top at the
                // waterline, off-white wheelhouse with a darker roof
                float gun = smoothstep(top - 0.30, top - 0.12, sy);
                float boot = smoothstep(0.30, 0.12, sy) * smoothstep(-0.20, -0.02, sy);
                float3 albH = mix(float3(0.038, 0.049, 0.056), float3(0.395, 0.400, 0.382), gun);
                albH = mix(albH, float3(0.085, 0.130, 0.075), boot * 0.8);
                float3 albC = mix(float3(0.66, 0.665, 0.645), float3(0.195, 0.115, 0.095), roof);
                float3 alb = mix(albH, albC, clamp(cab, 0.0, 1.0));
                float3 nrm = normalize(rgt * (-dirs * 0.60) + upv * 0.34 - nd * 0.72);
                float3 lit = skyIrr * 1.08 + fillC * 0.95 + moonIrr * 0.9
                           + sunIrr * (0.12 + 0.66 * max(dot(nrm, sd), 0.0));
                if (lampOn > 0.003) {
                    float3 Lv = lamp - boat.P; float Ld2 = dot(Lv, Lv); float3 Ln = Lv * rsqrt(Ld2);
                    float face = 0.0;
                    for (int b = 0; b < 2; b++) face += lw_beamProfile(-Ln, beamsD[b], beamsS[b], beamsU[b]);
                    lit += lampCol * (LW_IBEAM * 0.55 * face + 900.0) * lampOn
                         * exp(-LW_SIGT * sqrt(Ld2)) / Ld2 * (0.35 + 0.65 * max(dot(nrm, Ln), 0.0));
                }
                float3 bc = alb * lit * (1.0 / PI);
                float3 navc = (boat.nav > 0.5) ? float3(1.00, 0.26, 0.13) : float3(0.62, 1.00, 0.55);
                bc += navc * (0.62 * navG + 0.085 * navH);
                float bdens = mix(0.00068, 0.00022, smoothstep(-6.0, 10.0, el));
                float bfog = ws_fogAmount(dist, ro, rd, bdens, 0.010);
                bc = mix(bc, lw_hazeCol(rd, sd, el, sunT, nightK), bfog);
                col = mix(col, bc, cov);
            }
        }
    }

    // ---------------- lighthouse beam (night only)
    if (lampOn > 0.003) {
        float3 beam = lw_beamScatter(ro, rd, min(tScene, 2500.0), t, jit, 15, beamOn);
        col += beam * lampCol;
        float3 lv = normalize(lamp - ro);
        float ang = acos(clamp(dot(rd, lv), -1.0, 1.0));
        float fl = 0.0;
        for (int b = 0; b < 2; b++) fl += lw_beamProfile(-lv, beamsD[b], beamsS[b], beamsU[b]);
        float occl = (hit.x > 0.0 && hit.x < length(lamp - ro) - 4.0) ? 0.35 : 1.0;
        float3 kc = float3(1.045, 1.000, 0.952);
        float3 glow = float3(0.0);
        for (int c = 0; c < 3; c++) {
            float a = ang / kc[c];
            glow[c] = 0.9 * exp(-a / 0.0025) + 0.16 * exp(-a / 0.012) + 0.05 * exp(-a / 0.06) + 0.012 * exp(-a / 0.25);
        }
        glow *= lampCol * (0.05 + 1.0 * fl) * mix(lampOn, beamOn, 0.65);
        float3 gh = normalize(f * 2.0 - lv);
        float ga = acos(clamp(dot(rd, gh), -1.0, 1.0));
        glow += lampCol * float3(0.85, 0.95, 1.05) * fl * 0.010 * exp(-ga / 0.030) * beamOn;
        col += glow * occl;
    }

    // ---------------- exposure (the eye/camera adapting through the day)
    float expo = mix(LW_EXPO, 1.10, smoothstep(-11.0, 10.0, el));
    col *= expo;
    {
        float2 uv = fragCoord / ctx.res;
        col *= ws_vignette(uv, 0.13);
        col *= 1.0 - 0.40 * smoothstep(0.30, 0.0, uv.y) * nightK - 0.12 * smoothstep(0.26, 0.0, uv.y) * (1.0 - nightK);
    }
    {   // sensor grain, heaviest in the shadows, almost gone in daylight
        float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
        float amp = (0.0088 * nightK + 0.0022) * (1.0 - 0.68 * smoothstep(0.015, 0.30, lum));
        float g = ws_grain(fragCoord, t);
        float gc = ws_grain(fragCoord + float2(311.0, 97.0), t);
        col += (g + float3(0.30, -0.12, 0.34) * gc * 0.5) * amp;
    }
    return ws_acesFitted(max(col, 0.0));
}
