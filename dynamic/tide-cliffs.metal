// =====================================================================
//  Tide Cliffs — dynamic (time-of-day) wallpaper
//  An invented Atlantic headland: layered sandstone cliffs on the right,
//  long swell breaking white at their foot, sea stacks offshore, grassy
//  clifftop in the foreground.  Camera faces WEST (sunsets over the sea);
//  the cliff wall faces SOUTH so it is sunlit from midday to sunset.
//
//  Local frame after the heading rotation: -z = west (view axis),
//  +x = north (screen right), -x = south.  Land lives at x > coastline.
// =====================================================================

constant float TCD = 0.017453292519943295;
constant float TC_HEAD = -1.221730476;   // -90deg + 20deg : camera faces WNW
inline float tc_f01(float v) { return 0.5 + 0.5 * v; }
inline float tc_sn(float2 p) {          // cheap ~[-1,1] pseudo-noise (3 sines)
    return 0.46 * sin(dot(p, float2(0.92, 0.39)) + 1.3)
         + 0.34 * sin(dot(p, float2(-0.41, 0.91)) * 1.37 + 0.4)
         + 0.20 * sin(dot(p, float2(0.71, -0.70)) * 2.11 - 0.7);
}
inline float tc_sp(float x, float k) { return 0.5 * (x + sqrt(x * x + k * k)) - 0.5 * k; }   // smooth max(x,0)

constant float TC_HT    = 60.0;    // clifftop plateau height above sea (m)
constant float TC_EYE   = 67.6;    // camera eye height above sea (m)
constant float TC_FOV   = 36.0;    // vertical fov (deg)
constant float TC_PITCH = -4.6;    // camera pitch (deg)
constant float TC_BATT  = 0.215;   // cliff batter: face leans seaward going down

// sea stacks: x, z, base radius, height
constant float4 TC_STK[3] = {
    float4(-38.0, -372.0, 11.5, 44.0),
    float4(-97.0, -545.0, 13.5, 35.0),
    float4(  9.0, -292.0,  7.5, 29.0)
};

struct TCRig {
    float3 sun, moon;
    float  sunEl, moonEl;
    float3 Esun, Emoon;     // direct irradiance (linear)
    float3 Lz, Lb;          // sky tint: zenith, horizon
    float3 Lamb;            // skylight irradiance on a flat, open face
    float  night, moonPow, moonIl, day;
    float  time, seed;      // seed: slow, continuous drift so each hour gets its own sky
};

inline float tc_smax(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0); return mix(b, a, h) + k * h * (1.0 - h); }
inline float tc_smin(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0); return mix(b, a, h) - k * h * (1.0 - h); }

// ------------------------------------------------------------------ sky
inline float3 tc_atmos(float3 rd, float3 sun, int steps) {
    float3 r = normalize(float3(rd.x, max(rd.y, -0.02), rd.z));
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kM = 21e-6;
    float3 r0 = float3(0.0, Rp + 120.0, 0.0);
    float2 p = ws_raySphere(r0, r, Ra);
    p.x = max(p.x, 0.0);
    float iStep = (p.y - p.x) / float(steps);
    float iT = p.x;
    float3 totR = 0.0, totM = 0.0;
    float odR = 0.0, odM = 0.0;
    float mu = dot(r, sun), mumu = mu * mu, g = 0.762, gg = g * g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float mg = 1.0 + gg - 2.0 * mu * g;
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) / (mg * sqrt(mg) * (2.0 + gg));
    for (int i = 0; i < steps; i++) {
        float3 iPos = r0 + r * (iT + iStep * 0.5);
        float iH = length(iPos) - Rp;
        float dR = exp(-iH / 8e3) * iStep, dM = exp(-iH / 1.2e3) * iStep;
        odR += dR; odM += dM;
        float2 sg = ws_raySphere(iPos, sun, Rp);
        if (sg.x <= sg.y && sg.x > 0.0) { iT += iStep; continue; }
        float jStep = ws_raySphere(iPos, sun, Ra).y / 2.0;
        float jR = 0.0, jM = 0.0;
        for (int j = 0; j < 2; j++) {
            float jH = length(iPos + sun * (jStep * (float(j) + 0.5))) - Rp;
            jR += exp(-jH / 8e3) * jStep; jM += exp(-jH / 1.2e3) * jStep;
        }
        float3 at = exp(-(kM * (odM + jM) + kR * (odR + jR)));
        totR += dR * at; totM += dM * at;
        iT += iStep;
    }
    float3 tr = exp(-(kR * odR + kM * odM));
    float su = smoothstep(-0.10, 0.30, sun.y);
    float3 ms = mix(float3(1.00, 0.58, 0.40), float3(0.60, 0.77, 1.0), smoothstep(0.00, 0.34, sun.y));
    float hzw = mix(exp(-max(r.y, 0.0) * 3.2), 1.0, smoothstep(0.02, 0.30, sun.y));
    float tw = smoothstep(0.10, -0.06, sun.y) * smoothstep(-0.24, -0.04, sun.y);
    float3 twc = float3(0.050, 0.072, 0.146) * tw * (0.35 + 0.65 * smoothstep(-0.05, 0.45, r.y));
    return 21.0 * (pR * kR * totR + pM * kM * totM) + ms * (1.0 - tr) * (0.33 * su * hzw) + twc;
}

// Hemispherical skylight irradiance, integrated analytically from the same
// Rayleigh constants (the 1-step probes used for Lz/Lb miss ~95% of the
// column, which left shaded rock lit by nothing at all).
inline float3 tc_skyIrr(float3 sun) {
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    float su = sun.y;
    float amS = 1.0 / max(su + 0.10, 0.075);
    float3 T = exp(-(kR * 8000.0 + 21e-6 * 1200.0) * amS);
    float pR = 3.0 / (16.0 * PI) * (1.0 + su * su);
    float3 L = 21.0 * pR * kR * 8000.0 * T * 2.2;
    L = mix(L, float3(ws_luma(L)), 0.34);                    // multiple scattering
    L = mix(L, float3(ws_luma(L)) * float3(1.55, 1.02, 0.74), smoothstep(0.24, -0.02, su));
    return L * PI * 1.85 * smoothstep(-0.17, 0.05, su);
}

// solar transmittance through the airmass for a given elevation
inline float3 tc_sunT(float el) {
    float e = max(el, -1.3);
    float am = 1.0 / (sin(max(e, 0.32) * TCD) + 0.15 * pow(e + 3.885, -1.253));
    return exp(-float3(0.065, 0.130, 0.230) * min(am, 24.0));
}

// ---------------------------------------------------------------- clouds
inline float tc_cloudD(float2 q, float time, float seed, int oct) {
    float2 w = float2(0.38, 0.92) * (time * 7.0) + float2(-0.71, 0.36) * seed;
    float d = tc_f01(fbm((q + w) * 0.00042, oct));
    if (oct <= 3) return d;
    float d2 = tc_f01(fbm((q * 1.9 - w * 1.7) * 0.00085, max(oct - 2, 2)));
    return d * 0.70 + d2 * 0.30;
}

inline float3 tc_clouds(float3 rd, TCRig R, float3 sky, int lod, float calm) {
    if (rd.y < 0.006 || lod > 2) return sky;
    float3 col = sky;
    float sunUp = smoothstep(-0.14, 0.06, R.sun.y);
    float3 beam = R.Esun * 0.055;
    float3 amb  = R.Lamb * 0.42 + R.Lz * 0.35 + R.Lb * 0.13;

    // ---- high cirrus
    {
        if (lod > 1) return col;
        float2 q = rd.xz * (7600.0 / max(rd.y, 0.035));
        float2 cs = float2(-2.1, 1.3) * R.seed;
        float n = gnoise((q + cs * 1.7 + float2(1.4, 3.1) * (R.time * 5.0)) * 0.00019);
        float ridge = tc_f01(fbm(float2(q.x * 0.00052 + n * (1.0 + 0.9 * tc_f01(sin(R.seed * 0.021))) + cs.x * 0.0004 + R.time * 0.055,
                                        q.y * 0.00013 + cs.y * 0.00009), 2));
        float lo = 0.585 + 0.115 * tc_f01(sin(R.seed * 0.0135 + 1.1));  // coverage varies by hour
        float c = smoothstep(lo, lo + 0.30, ridge) * smoothstep(0.02, 0.16, rd.y);
        c *= 0.46 * (1.0 - 0.72 * calm) * (1.0 - 0.45 * smoothstep(0.10, 0.45, R.sun.y));
        float fwd = pow(max(dot(rd, R.sun), 0.0), 3.0);
        float3 cc = amb * 2.3 + beam * (3.4 + 8.0 * fwd) * mix(float3(1.0), float3(1.25, 0.72, 0.52), smoothstep(0.25, -0.02, R.sun.y));
        col = mix(col, cc, clamp(c, 0.0, 1.0) * 0.8);
    }
    // ---- cumulus deck
    {
        float H = 2350.0;
        float2 q = rd.xz * (H / max(rd.y, 0.022));
        float lenq = length(q);
        float fade = smoothstep(46000.0, 15000.0, lenq);          // thin out near the horizon
        if (fade > 0.004) {
            float d = tc_cloudD(q, R.time, R.seed, lod == 0 ? 3 : 2);
            float cov = mix(0.545, 0.615, sunUp) + 0.030 * tc_f01(sin(R.seed * 0.0173 - 0.6)) - 0.015;
            float a = smoothstep(cov, cov + 0.10, d) * fade * (1.0 - 0.55 * calm);
            if (a > 0.004) {
                // one-tap light march toward the sun
                float2 qs = q + R.sun.xz * (700.0 / max(R.sun.y, 0.12));
                float ds = tc_cloudD(qs, R.time, R.seed, 2);
                float th = clamp((ds - cov) / 0.13, 0.0, 1.0);
                float lit = exp(-3.1 * th) * 0.88 + 0.12;
                float pw = pow(clamp((d - cov) / 0.13, 0.0, 1.0), 0.6);   // powder at the edges
                float fwd = pow(max(dot(rd, R.sun), 0.0), 6.0);
                float3 top = beam * (2.6 * lit + 3.8 * fwd * lit) + amb * (1.10 + 0.55 * (1.0 - pw));
                float3 bot = amb * 0.50 + beam * 0.10 * lit;
                float3 cc = mix(bot, top, 0.35 + 0.65 * lit);
                // sunset underlight
                cc = mix(cc, cc * float3(1.35, 0.78, 0.60), smoothstep(0.14, -0.05, R.sun.y) * 0.85);
                col = mix(col, cc, clamp(a, 0.0, 1.0));
            }
        }
    }
    return col;
}

// ---------------------------------------------------------------- moon
inline float3 tc_moon(float3 rd, TCRig R) {
    float c = dot(rd, R.moon);
    if (c < 0.9985) {
        float g = pow(max(c, 0.0), 900.0) * 0.30 + pow(max(c, 0.0), 60.0) * 0.012;
        return float3(0.55, 0.60, 0.72) * g * R.moonIl * smoothstep(-0.08, 0.10, R.moon.y);
    }
    float rad = 0.00465;                       // ~0.27 deg
    float3 glow = float3(0.55, 0.60, 0.72) * (pow(max(c, 0.0), 900.0) * 0.30 + pow(max(c, 0.0), 60.0) * 0.012)
                * R.moonIl * smoothstep(-0.08, 0.10, R.moon.y);
    float3 up = normalize(float3(0.0, 1.0, 0.0) - R.moon * R.moon.y);
    float3 rt = normalize(cross(up, R.moon));
    float3 off = rd - R.moon * c;
    float2 uv = float2(dot(off, rt), dot(off, up)) / rad;
    float rr = length(uv);
    float disk = 1.0 - smoothstep(0.985, 1.0, rr);
    // terminator for the illuminated fraction
    float3 sp = normalize(R.sun - R.moon * dot(R.sun, R.moon));
    float2 sa = normalize(float2(dot(sp, rt), dot(sp, up)) + 1e-5);
    float xs = dot(uv, sa), ys = dot(uv, float2(-sa.y, sa.x));
    float xt = (1.0 - 2.0 * clamp(R.moonIl, 0.0, 1.0)) * sqrt(max(1.0 - ys * ys, 0.0));
    float lit = smoothstep(-0.06, 0.06, xs - xt);
    float limb = 0.55 + 0.45 * sqrt(max(1.0 - rr * rr, 0.0));
    float mare = 0.80 + 0.20 * fbm(uv * 2.6, 3);
    return glow + float3(1.55, 1.52, 1.40) * disk * lit * limb * mare * smoothstep(-0.10, 0.06, R.moon.y);
}

inline float3 tc_sky(float3 rd, float3 atm, TCRig R, int lod, float calm) {
    float3 col = atm;
    if (R.night > 0.02) {
        float2 sp = float2(atan2(rd.z, rd.x) * 0.52, asin(clamp(rd.y, -1.0, 1.0)) * 0.62);
        float3 st = ws_stars(sp, 46.0, R.time * 0.035, 0.30) * R.night * 1.9;
        st *= smoothstep(-0.02, 0.10, rd.y);
        st *= 1.0 - 0.55 * clamp(R.moonPow, 0.0, 1.0);
        // faint milky way band
        float band = exp(-pow((rd.y - 0.30 - 0.22 * rd.x) / 0.30, 2.0));
        float mw = fbm(sp * 3.4, 3);
        col += st + float3(0.0090, 0.0100, 0.0155) * band * smoothstep(0.30, 0.85, mw) * R.night;
        // airglow / distant shore light hugging the horizon
        col += float3(0.0150, 0.0165, 0.0215) * R.night * exp(-max(rd.y, -0.02) / 0.055);
    }
    if (R.moonIl > 0.02 && R.moon.y > -0.05) col += tc_moon(rd, R);
    col += ws_sunDisk(rd, R.sun, 0.265, R.Esun * 3.2 * mix(1.0, 0.30, smoothstep(0.16, -0.01, R.sun.y)));
    col = tc_clouds(rd, R, col, lod, calm);
    // sun bloom near the horizon
    float sd = max(dot(rd, R.sun), 0.0);
    if (sd > 0.25) {
        float up = smoothstep(-0.08, 0.05, R.sun.y);
        float s2 = sd * sd, s4 = s2 * s2, s8 = s4 * s4;
        col += R.Esun * (0.020 * s8 * s2 + 0.006 * s2 * sd) * up;
        if (sd > 0.93) {
            float s16 = s8 * s8, s48 = s16 * s16 * s16;
            float lowS = smoothstep(0.24, -0.02, R.sun.y);
            col += R.Esun * (0.055 * s48 * s48 * s48 * s48 * s48 + 0.016 * s48) * lowS * up;
        }
    }
    return col;
}

// ------------------------------------------------------------- coastline
// Signed plan-view field: > 0 on land (at plateau level), ~metres.
inline float tc_coast(float2 P, int lod) {
    float x = -P.x;              // mirrored: land lives at screen-right
    float z = P.y;
    // near shelf: land where z > zc(x)
    float2 sc = sin(float2(0.085 * x, 0.085 * x + 1.5707963));   // sin, cos
    float sx = sc.x;
    float zc = -15.5 + 0.60 * tc_sp(x, 24.0) + 0.50 * tc_sp(-x, 22.0) + 2.4 * sx;
    float dz = 0.60 * (0.5 + 0.5 * x * rsqrt(x * x + 576.0)) - 0.50 * (0.5 - 0.5 * x * rsqrt(x * x + 484.0))
             + 0.204 * sc.y;
    float e1 = (z - zc) * rsqrt(1.0 + dz * dz);
    // promontory running west: land where x < xc(z)
    float zr = -tc_sp(-z, 40.0);
    float3 ps3 = sin(float3(0.0107 * zr, 0.0291 * zr + 1.1, 0.0631 * zr + 2.7));
    float3 pc3 = sin(float3(0.0107 * zr + 1.5707963, 0.0291 * zr + 2.6707963, 0.0631 * zr + 4.2707963));
    float xc = -100.0 + 0.10 * zr + 17.0 * ps3.x + 4.2 * ps3.y + 2.6 * ps3.z;
    float dx = 0.10 + 0.1819 * pc3.x + 0.1222 * pc3.y + 0.1641 * pc3.z;
    float e2 = (xc - x) * rsqrt(1.0 + dx * dx);
    e2 = tc_smin(e2, (z + 940.0) * 0.95, 90.0);
    float d = tc_smax(e1, e2, 12.0);
    // bays, ribs and buttresses
    float2 rb = sin(float2(dot(P, float2(0.92, 0.39)) * 0.0052 + 1.3,
                           dot(P, float2(-0.41, 0.91)) * 0.00712 + 0.4));
    d += 4.2 * (0.55 * rb.x + 0.45 * rb.y);
    return d;
}

inline float tc_topH(float2 P, float dl, int lod) {
    float4 t4 = sin(float4(dot(P, float2(0.92, 0.39)) * 0.0082 + 1.3,
                           dot(P, float2(-0.41, 0.91)) * 0.0115 + 0.4,
                           dot(P, float2(0.71, -0.70)) * 0.0210 + 2.7,
                           P.y * 0.0165 + 1.3));
    float h = TC_HT + 3.4 * (0.56 * t4.x + 0.44 * t4.y) + 1.6 * t4.z
           + 3.2 * t4.w + 1.8 * sin(P.y * 0.041 - 0.7) + 1.1 * sin(P.x * 0.03 + 2.0)
           + (lod < 2 ? 0.45 * gnoise(P * 0.030) : 0.0);
    h += 5.0 * (1.0 - exp(-max(dl, 0.0) / 110.0));       // the moor rises away from the edge
    h -= 14.0 * (1.0 - smoothstep(-900.0, -380.0, P.y));  // the headland drops toward its tip
    return h;
}

// Strata coordinate: continuous dipping bedding planes whose *thickness*
// varies ~4x.  The warp below uses incommensurate frequencies with total
// slope < 1, so it never folds (bed order is preserved) but never repeats.
inline float tc_strata(float3 p, float v) {
    float dip = 0.045 + 0.030 * sin(v * 0.0031 + 1.1);
    float sY = (p.y - dip * v) * 0.174 + 0.115 * sin(v * 0.019 + p.y * 0.0042 + 2.1);
    return sY + 0.22 * sin(sY * 0.613 + 0.7) + 0.13 * sin(sY * 1.271 - 2.1)
              + 0.070 * sin(sY * 2.907 + 1.9);
}

// Per-bed relief.  Each bed gets its own hardness (proud or recessed) and its
// own pair of contact softnesses, so no two beds share a profile and there is
// no repeating stripe pitch.
inline float tc_bedRelief(float sY) {
    float id = floor(sY), fr = sY - id;
    float h1 = hash11(id * 0.7131 + 3.17);
    float h2 = hash11(id * 1.9137 - 2.03);
    // most beds barely register; a minority are resistant and form real ledges
    float hs = smoothstep(0.54, 0.97, h1);
    float hard = (-0.16 + 0.32 * h1) + 1.45 * hs * hs;
    float a = 0.13 + 0.30 * h2;                  // lower contact: undercut but not a slot
    float b = 0.16 + 0.40 * (1.0 - h2);          // upper contact: weathered back
    float prof = smoothstep(0.0, a, fr) * smoothstep(1.0, 1.0 - b, fr);
    return (prof - 0.42) * hard;
}

// coarse relief (shadows, AO, the conservative march tier)
// smooth part of the coarse relief (low gradient -> long march steps)
inline float tc_faceS(float3 p, float v) {
    // buttresses and gullies: the big shape of an eroded headland, not a ramp
    float d = 6.2 * tc_sn(float2(v * 0.0072, p.y * 0.0026))
            + 3.6 * tc_sn(float2(v * 0.0185, p.y * 0.0071) + 2.4)
            + 1.9 * sin(v * 0.0440 + p.y * 0.0160 - 1.1) * (0.6 + 0.4 * sin(v * 0.0271 - p.y * 0.0093));
    float gq = v * 0.0155 + 0.9 * sin(v * 0.0038 + p.y * 0.0021 + 1.4);
    float gh = hash11(floor(gq + 0.5) * 3.719 - 1.3);
    float gs = abs(sin(PI * gq));
    float gmod = 0.45 + 0.55 * sin(p.y * 0.075 + gq * 2.3 + 11.0 * gh);
    d -= (1.4 + 4.4 * gh * gh) * gs * gs * (0.45 + 0.55 * gs) * gmod * smoothstep(58.0, 10.0, p.y);
    if (p.y < 27.0) {
        float tal = smoothstep(24.0, -3.0, p.y);
        d += 6.6 * tal * (0.45 + 0.55 * tc_sn(float2(v * 0.030, p.y * 0.020)));
    }
    return d;
}

inline float tc_bedStep(float3 p, float v) {
    float bmask = 0.30 + 0.85 * tc_f01(sin(v * 0.0135 + p.y * 0.0052 + 6.3) * 0.7 + 0.42 * sin(v * 0.0061 - p.y * 0.0117));
    return 1.05 * bmask * tc_bedRelief(tc_strata(p, v));
}

// the extra detail on top of the coarse tier (max outward swing ~4.6 m)
inline float tc_faceX(float3 p, float v, float dk) {
    float tal = smoothstep(24.0, -3.0, p.y);
    // one vectorised sine bank feeds the joints, chutes and their masks
    float4 a4 = sin(float4(v * 0.0052 + p.y * 0.0016 + 1.1,
                           v * 0.0091 + p.y * 0.0035 + 4.7,
                           v * 0.0340 - p.y * 0.0310 + 1.7,
                           v * 0.0485 + p.y * 0.0640 - 4.0));
    // vertical joints: irregular spacing, per-joint depth and width
    float jv = v * 0.042 + 1.7 * a4.x;
    float jh = hash11(floor(jv + 0.5) * 2.317 + 0.41);
    float jm = smoothstep(-0.10, 0.70, a4.y);
    float js = abs(sin(PI * jv));  js = js * js * (0.45 + 0.55 * js);
    float d = -(0.16 + 0.58 * jh * jh) * jm * js;
    // runoff chutes, masked so they cluster in gullies instead of corduroy
    float ch = abs(0.78 * a4.z + 0.55 * a4.w);
    d -= 0.95 * smoothstep(-0.20, 0.72, a4.y) * smoothstep(0.46, 0.03, ch) * smoothstep(8.0, 36.0, p.y);
    float2 b2 = sin(float2(v * 0.030 + p.y * 0.021 + 3.3, v * 0.019 - p.y * 0.034 - 1.2));
    d += 1.5 * b2.x * (0.55 + 0.45 * b2.y) * smoothstep(20.0, 56.0, p.y);
    d += 1.7 * tal * tc_sn(float2(v * 0.13, p.y * 0.11));
    if (dk > 0.25) {
        d += dk * 0.55 * gnoise(float2(v * 0.17, p.y * 0.15));
        d += dk * 0.24 * tc_sn(float2(v * 0.66, p.y * 0.55));
    }
    return d;
}

// dk < 0 : conservative/coarse only (shadows, AO, reflection probes)
inline float tc_faceD(float3 p, float dk) {
    float v = p.z * 0.92 + p.x * 0.39;
    float d = tc_faceS(p, v);
    if (dk >= 0.0) d += tc_bedStep(p, v);
    if (dk > 0.004) d += tc_faceX(p, v, dk);
    return d;
}

inline float tc_stackSD(float3 p, int i, float dk) {
    float4 S = TC_STK[i];
    float2 q = p.xz - S.xy;
    float yn = clamp(p.y / S.w, -0.4, 1.4);
    float2 lean = (i == 0) ? float2(0.082, 0.057) : ((i == 1) ? float2(-0.049, -0.034) : float2(0.115, 0.080));
    q -= lean * p.y;
    float rr = length(q);
    float sd0 = float(i) * 5.31 + 1.7;
    float taper = (i == 1) ? 1.9 : 1.25;
    float rad = S.z * (1.0 - 0.44 * pow(max(yn, 0.0), taper)) * (1.0 + 0.45 * max(-yn, 0.0));
    // three different natural profiles: waisted pillar / leaning slab with an
    // overhanging brow / squat barrel -- not one mesh at three heights
    if (i == 0)      rad *= 1.0 - 0.155 * exp(-pow((yn - 0.50) / 0.22, 2.0));
    else if (i == 1) rad *= 1.0 + 0.26 * exp(-pow((yn - 0.82) / 0.15, 2.0))
                                 - 0.10 * exp(-pow((yn - 0.34) / 0.20, 2.0));
    else             rad *= 1.0 + 0.17 * exp(-pow((yn - 0.28) / 0.28, 2.0));
    rad += (1.75 + 0.40 * float(i)) * tc_sn(q * (0.105 + 0.030 * float(i)) + float2(p.y * (0.030 + 0.012 * float(i)), sd0))
         + 0.85 * tc_sn(float2(q.y, q.x) * 0.30 + float2(p.y * 0.26 + sd0, sd0 * 1.7));
    // vertical fracture planes: a broken column, not a melted one
    float fq = dot(q, float2(0.83, 0.56)) * 0.155 + 0.7 * tc_sn(q * 0.05 + sd0);
    rad -= (0.75 + 1.35 * hash11(floor(fq + 0.5) * 4.13 + sd0)) * pow(abs(sin(PI * fq)), 1.3);
    // its own bedding: level, offset and cut to a different depth per stack
    if (dk >= 0.0) rad += (1.15 + 0.35 * float(i)) * tc_bedRelief(
               tc_strata(float3(q.x, p.y + 5.3 * float(i), q.y), 21.0 * float(i) + 37.0));
    if (dk > 0.004) {
        rad += dk * 0.85 * gnoise(float2(q.x * 0.30, q.y * 0.30) + float2(p.y * 0.22, sd0));
        rad += dk * dk * 0.34 * gnoise(float2(q.x * 0.9 + sd0, p.y * 0.8));
    }
    rad -= (1.9 + 0.6 * float(i)) * exp(-pow((p.y - 1.8) / 2.8, 2.0));        // wave-cut notch
    float top = S.w + 3.0 * tc_sn(q * 0.17 + float2(11.0, sd0)) - 2.0 * float(i == 2)
              + dot(q, (i == 1) ? float2(0.26, 0.11) : float2(-0.15, 0.21));  // tilted, broken cap
    rad -= 1.6 * tc_sp(p.y - (top - 2.0), 0.7);                               // bevelled rim
    return max(rr - rad, p.y - top) * 0.72;
}

// full signed distance (negative inside rock)
// conservative cheap bound: never larger than the true distance
inline float tc_mapLo(float3 p, int sflags) {
    float dl = tc_coast(p.xz, 2);
    float d = dl + TC_BATT * (TC_HT - p.y) + tc_faceS(p, p.z * 0.92 + p.x * 0.39) + 3.9;
    float sd = max(-d * 0.80, p.y - (TC_HT + 7.6));
    if (sflags & 1) sd = min(sd, tc_stackSD(p, 0, -1.0) - 3.0);
    if (sflags & 2) sd = min(sd, tc_stackSD(p, 1, -1.0) - 3.0);
    if (sflags & 4) sd = min(sd, tc_stackSD(p, 2, -1.0) - 3.0);
    return sd;
}

inline float tc_map(float3 p, float dk, int sflags) {
    float dl = tc_coast(p.xz, 2);
    float d = dl + TC_BATT * (TC_HT - p.y) + tc_faceD(p, dk);
    float sd = tc_smax(-d * 0.62, p.y - tc_topH(p.xz, dl, 2), 1.8);
    if (sflags & 1) sd = min(sd, tc_stackSD(p, 0, dk));
    if (sflags & 2) sd = min(sd, tc_stackSD(p, 1, dk));
    if (sflags & 4) sd = min(sd, tc_stackSD(p, 2, dk));
    return sd;
}

inline float3 tc_normal(float3 p, float e, float dk, int sflags) {
    float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * tc_map(p + k.xyy * e, dk, sflags) +
                     k.yyx * tc_map(p + k.yyx * e, dk, sflags) +
                     k.yxy * tc_map(p + k.yxy * e, dk, sflags) +
                     k.xxx * tc_map(p + k.xxx * e, dk, sflags));
}

inline float tc_shadow(float3 p, float3 L, int sflags) {
    if (L.y < 0.005) return 0.0;
    float t = 1.5, res = 1.0;
    for (int i = 0; i < 3; i++) {
        float h = tc_map(p + L * t, -1.0, sflags);
        res = min(res, 8.0 * h / t);
        if (res < 0.03) break;
        t += clamp(h, 3.2, 60.0);
        if (t > 240.0) break;
    }
    return clamp(res, 0.0, 1.0);
}

inline float tc_ao(float3 p, float3 n, int sflags) {
    float a = 0.0, w = 1.0;
    for (int i = 1; i <= 2; i++) {
        float d = 1.4 * float(i) * float(i);
        a += w * clamp(tc_map(p + n * d, -1.0, sflags) / d, -1.0, 1.0);
        w *= 0.58;
    }
    return clamp(a / 1.45, 0.0, 1.0) * 0.62 + 0.38;
}

// ----------------------------------------------------------------- water
inline float tc_depth(float2 P, float dl) {
    float s = max(-dl, 0.0);
    float d = 24.0 * (1.0 - exp(-max(s - 42.0, 0.0) / 52.0));
    for (int i = 0; i < 3; i++) {
        float2 q = P - TC_STK[i].xy;
        float r2 = dot(q, q);
        float lim = TC_STK[i].z + 75.0;
        if (r2 > lim * lim) continue;
        float r = sqrt(r2) + 9.0 * tc_sn(q * 0.045 + float2(float(i) * 4.0, 0.0));
        d = min(d, mix(2.70, 24.0, smoothstep(TC_STK[i].z * 0.95, TC_STK[i].z + 34.0, r)));
    }
    return max(d, 0.25);
}

struct TCWave { float3 n; float h; float foam; float rough2; float brk; float foamTex; };

inline TCWave tc_wave(float2 P, float fp, float time, float depth, int lod) {
    // Saturated spectrum.  Wavenumbers are incommensurate and the directional
    // spread is broad (narrow for the three swell trains, wide for the wind
    // sea), so crossing components cannot settle into an interference lattice.
    const float ka[9]  = { 0.0521, 0.0837, 0.1291, 0.2113, 0.3307, 0.5419, 0.8837, 1.4230, 2.3110 };
    const float aa[9]  = { 1.100,  0.755,  0.515,  0.470,  0.252,  0.215,  0.106,  0.078,  0.040  };
    const float wa[9]  = { 0.715,  0.906,  1.126,  1.439,  1.801,  2.306,  2.945,  3.737,  4.762  };
    const float dxs[9] = { 0.9954, 0.8290, 0.9903, 0.4147, 0.9426, 0.0087, 0.7604, 0.6626, 0.6088 };
    const float dzs[9] = { 0.0959, 0.5592,-0.1392, 0.9100,-0.3338, 1.0000,-0.6495, 0.7490,-0.7934 };
    // every component reads the two warp fields with its own gain, so their
    // relative phases wander independently across the water
    const float gA[9]  = { 0.90,   0.66,   1.15,   0.58,   0.44,   0.31,   0.23,   0.17,   0.12   };
    const float gB[9]  = { 0.42,  -0.78,   0.62,   1.22,  -0.98,   1.36,  -1.12,   0.88,  -1.42   };
    const float ph0[9] = { 0.000,  2.399,  4.712,  1.107,  5.585,  3.019,  0.628,  2.041,  5.027  };

    float shoal = clamp(pow(26.0 / max(depth, 1.2), 0.25), 1.0, 2.6);
    float wqA = 1.0 / (1.0 + pow(fp * 0.055, 2.0));
    float wqB = 1.0 / (1.0 + pow(fp * 0.30, 2.0));
    float3 a3 = sin(float3(dot(P, float2(0.96, 0.28)) * 0.0062 + 1.7,
                           dot(P, float2(-0.29, 0.96)) * 0.0091 - 2.3,
                           dot(P, float2(0.71, -0.70)) * 0.0047 + 4.1));
    float2 WA = float2(0.58 * a3.x + 0.42 * a3.z, 0.63 * a3.y - 0.37 * a3.x) * (17.0 * wqA);
    float2 sB = sin(float2(dot(P, float2(0.87, 0.49)), dot(P, float2(-0.42, 0.91))) * 0.085 + float2(2.3, 5.1));
    float2 WB = float2(sB.x * 0.78 + sB.y * 0.46, sB.x * 0.52 - sB.y * 0.81) * (2.5 * wqB);
    // swell groups and wind patches: slow, smooth modulation -- a few sines
    // read the same as fbm here and cost a fraction
    float2 gt = P + float2(0.019, 0.006) * time * 1.0;
    float3 g3 = sin(float3(dot(gt, float2(0.91, 0.41)) * 0.0034,
                           dot(gt, float2(-0.37, 0.93)) * 0.0051 + 2.1,
                           dot(gt, float2(0.62, -0.78)) * 0.0087 - 1.3));
    float grp = 0.45 + 0.95 * clamp(0.5 + 0.5 * (0.52 * g3.x + 0.31 * g3.y + 0.21 * g3.z), 0.0, 1.0);
    float2 ht = P + float2(0.05, 0.02) * time;
    float3 h3 = sin(float3(dot(ht, float2(0.88, 0.47)) * 0.0120 + 0.7,
                           dot(ht, float2(-0.51, 0.86)) * 0.0183 - 2.4,
                           dot(ht, float2(0.33, 0.94)) * 0.0291 + 1.1));
    float grp2 = clamp(0.5 + 0.5 * (0.50 * h3.x + 0.32 * h3.y + 0.22 * h3.z), 0.0, 1.0);
    float cats = 0.46 + 1.30 * grp2 * grp2;          // patchy cat's-paw chop

    float h = 0.0, hl0 = 0.0, hl1 = 0.0, hl2 = 0.0, lost = 0.0;
    float2 sl = 0.0;
    int n = 9;
    if (fp > 1.85) n = 8;
    if (fp > 3.00) n = 7;
    if (fp > 4.80) n = 6;
    if (fp > 8.00) n = 5;
    for (int i = 0; i < n; i++) {
        float2 dir = float2(dxs[i], dzs[i]);
        float amp = aa[i] * ((i < 3) ? shoal * grp : (i < 6 ? (0.55 + 0.75 * grp2) : cats));
        if (i < 3) amp = min(amp, 0.52 * depth);        // breaker height ~ 0.8 h
        float w = 1.0 / (1.0 + pow(fp * ka[i] * 0.72, 2.0));
        float2 Pi = P + WA * gA[i] + WB * gB[i];
        float ph = dot(Pi, dir) * ka[i] - wa[i] * time + ph0[i];
        float s2 = sin(ph), c2 = cos(ph);
        h += amp * w * s2;
        if (i < 3) {
            hl0 += amp * w * s2;
            hl1 += amp * w * sin(ph + wa[i] * 3.4);
            hl2 += amp * w * sin(ph + wa[i] * 7.0);
        }
        sl += dir * amp * ka[i] * w * c2;
        lost += 0.5 * pow(amp * ka[i] * (1.0 - w), 2.0);
    }
    TCWave W;
    W.h = h;
    W.n = normalize(float3(-sl.x, 1.0, -sl.y));
    W.rough2 = lost;
    // breaking where the shoaled crest gets close to the local depth
    float invd = 1.0 / max(depth, 0.55);
    float b0 = smoothstep(0.34, 0.78, (hl0 * 1.10 + 0.30) * invd);
    float b1 = smoothstep(0.34, 0.78, (hl1 * 1.10 + 0.30) * invd);
    float b2 = smoothstep(0.34, 0.78, (hl2 * 1.10 + 0.30) * invd);
    float b = clamp(max(max(b0, 0.58 * b1), 0.30 * b2) + 0.16 * smoothstep(1.8, 0.3, depth), 0.0, 1.0);
    W.brk = b;
    // whitewater: cellular froth riding the crest + streaks trailing seaward
    if (b < 0.015) { W.foam = 0.0; W.foamTex = 0.0; return W; }
    float2 fdir = float2(0.951, 0.309);
    float2 drift = fdir * time * 3.2;
    float kf = 1.0 / (1.0 + pow(fp * 0.14, 2.0));
    float f1 = tc_f01(fbm((P + drift) * 0.055, 3));
    float f2 = tc_f01(fbm((P + drift * 1.6) * 0.20, 2)
                      + 0.25 * gnoise((P + drift * 1.6) * 0.80) * (1.0 / (1.0 + pow(fp * 0.55, 2.0)))) * kf;
    float kg = 1.0 / (1.0 + pow(fp * 0.60, 2.0));
    float f3 = tc_f01(gnoise((P + drift * 2.4) * 0.85)) * kg;
    // fine froth cells, only where the pixel can still resolve them
    float kh = 1.0 / (1.0 + pow(fp * 1.5, 2.0));
    float f4 = (kh > 0.10) ? tc_f01(gnoise((P + drift * 3.3) * 2.1)) * kh : 0.0;
    float nf = 0.42 * f1 + 0.30 * (f2 + 0.5 * (1.0 - kf)) + 0.19 * (f3 + 0.5 * (1.0 - kg)) + 0.09 * (f4 + 0.5 * (1.0 - kh));
    // leading edge is hard where the crest is actively breaking; the sheet
    // behind it thins out, so alpha falls off instead of ending in a flat wall
    float th = 1.02 - 0.78 * b;
    float lead = smoothstep(th, th + 0.13 + 0.22 * (1.0 - b), nf);
    // trailing foam: streaks pulled seaward, slower to die, and translucent
    float st = tc_f01(fbm(float2(dot(P, float2(-0.309, 0.951)) * 0.055,
                                 dot(P, fdir) * 0.009 - time * 0.012), 3));
    float tr = smoothstep(0.62, 1.02, st * 0.62 + f1 * 0.38) * smoothstep(0.10, 0.44, b);
    tr *= 0.22 + 0.78 * smoothstep(0.34, 0.88, nf);
    float fw = max(lead, tr * 0.52);
    // surge clinging to the rock: tongues that run up and drain back, with a
    // ragged edge cut by the froth texture rather than a flat painted sheet
    float surge = smoothstep(1.0, 0.05, depth) * smoothstep(0.38 + 0.30 * (1.0 - b), 0.95, nf);
    fw = max(fw, surge * 0.66);
    W.foam = clamp(fw, 0.0, 1.0) * clamp(0.10 + 1.15 * nf, 0.0, 1.0);
    W.foamTex = nf;
    return W;
}

// ------------------------------------------------------------ rock shading
inline float sd_seed(int i) { return float(i) * 5.31 + 1.7; }

inline float3 tc_rockAlbedo(float3 p, float3 n, float fp, int lod, int stk, thread float &bedAO) {
    float v = p.z * 0.92 + p.x * 0.39;
    // stacks carry their own, level bedding; the headland's beds dip along v
    float3 ps = (stk >= 0) ? float3(p.x, p.y + 5.3 * float(stk), p.z) : p;
    float sv = (stk >= 0) ? (21.0 * float(stk) + 37.0) : v;
    float sY = tc_strata(ps, sv);
    float id = floor(sY);
    float fr = sY - id;
    float sk = float(stk + 1);
    float h1 = hash11(id * 1.37 + sk * 9.13), h2 = hash11(id * 3.11 + 0.7 + sk * 4.31);
    float h3 = hash11(id * 7.31 - sk * 2.77);
    float3 c1 = ws_hex(0x86694Eu);     // buff sandstone
    float3 c2 = ws_hex(0x6B4F35u);     // ochre
    float3 c3 = ws_hex(0x655A4Bu);     // grey marl
    float3 c4 = ws_hex(0x554639u);     // dark seam
    float3 alb = mix(c1, c2, h1);
    alb = mix(alb, c3, smoothstep(0.42, 0.95, h2) * 0.60);
    // partings: thin, only under some beds, and broken along the face
    float part = smoothstep(0.88, 1.0, h3) * smoothstep(0.86, 0.99, fr)
               * smoothstep(0.28, 0.72, tc_f01(tc_sn(float2(sv * 0.045, p.y * 0.012))));
    alb = mix(alb, c4, part * 0.38);
    alb *= 1.0 - 0.14 * smoothstep(0.55, 0.98, fr) * smoothstep(0.40, 0.90, hash11(id * 2.71 - 4.4));
    // slow regional drift so the bed sequence never reads as a tiled texture
    alb *= 0.88 + 0.26 * tc_f01(tc_sn(float2(v * 0.0062, p.y * 0.0095)));
    alb = mix(alb, float3(ws_luma(alb)) * 1.02, 0.34);
    // the bed above overhangs -> a line of shade under its lower contact
    float bAO = clamp((tc_bedRelief(sY + 0.13) - tc_bedRelief(sY)) * 1.4, 0.0, 1.0);
    if (lod < 2) {
        float2 gp = float2(v * 0.55, p.y * 0.42);
        float kA = 1.0 / (1.0 + pow(fp * 1.1, 2.0));
        float kB = 1.0 / (1.0 + pow(fp * 3.0, 2.0));
        alb *= mix(1.0, 0.92 + 0.17 * gnoise(gp), kA);
        alb *= mix(1.0, 1.0 + 0.22 * gnoise(gp * 2.7 + 5.0), kB);             // grain
        alb *= 0.93 + 0.15 * tc_f01(tc_sn(float2(v * 0.055, p.y * 0.045)));
        // rain-washed streaks: clustered, not an even comb
        float sm = smoothstep(0.38, 0.86, tc_f01(tc_sn(float2(v * 0.016, p.y * 0.0042) + 3.1)));
        float st = smoothstep(0.10, 0.70, gnoise(float2(v * 0.16, p.y * 0.019)))
                 * (0.25 + 0.75 * hash11(id * 5.113 + 1.9));
        alb *= 1.0 - 0.13 * st * sm * smoothstep(0.0, 0.5, 1.0 - abs(n.y));
    }
    bedAO = bAO;
    if (stk >= 0) {
        // sea-stack weathering: bleached crown, guano streaks, darker flanks
        float hy = clamp((p.y - 4.0) / max(TC_STK[stk].w, 1.0), 0.0, 1.0);
        float strk = smoothstep(0.52, 0.96, tc_f01(tc_sn(float2(p.x, p.z) * 0.85 + sd_seed(stk))));
        alb = mix(alb, float3(0.58, 0.56, 0.50), strk * smoothstep(0.20, 0.95, hy) * 0.20);
        alb = mix(alb, ws_hex(0x4F5B3Au), smoothstep(0.55, 0.95, hy) * 0.16);
        alb *= 0.90 - 0.10 * (1.0 - hy);
    } else {
        // lichen / turf on the flatter ledges, patchy along the face
        float flat = smoothstep(0.26, 0.74, n.y);
        float3 turf = ws_hex(0x4A5730u);
        float pat = smoothstep(0.30, 0.80, tc_f01(tc_sn(float2(v * 0.026, p.y * 0.011) + 8.4)));
        alb = mix(alb, turf * (0.75 + 0.45 * gnoise(p.xz * 0.33)), flat * pat * smoothstep(10.0, 30.0, p.y) * 0.66);
        // scree and rubble collecting at the foot
        alb = mix(alb, ws_hex(0x8A7A63u) * (0.80 + 0.40 * gnoise(float2(v * 0.55, p.y * 0.55))),
                  smoothstep(16.0, 2.0, p.y) * 0.34);
    }
    return alb;
}

// ------------------------------------------------------------- foreground grass
inline float3 tc_grass(float3 p, float3 rd, float fp, TCRig R, thread float3 &nOut, thread float &aoOut) {
    float2 q = p.xz;
    float wind = R.time * 0.42;
    float2 wv = float2(0.94, 0.34);
    float2 gq2 = q - wv * wind * 1.1;                                 // slow gust fronts
    float gust = 0.58 * sin(dot(gq2, float2(0.95, 0.31)) * 0.013 + 0.9)
               + 0.42 * sin(dot(gq2, float2(-0.36, 0.93)) * 0.0207 - 1.7);
    float bend = gnoise(q * 0.13 - wv * wind * 2.0) * (0.55 + 0.45 * gust);
    float kb = 1.0 / (1.0 + pow(fp * 26.0, 2.0));                     // ~4 cm blade clumps
    float k0 = 1.0 / (1.0 + pow(fp * 9.0, 2.0));                      // ~11 cm
    float k1 = 1.0 / (1.0 + pow(fp * 2.4, 2.0));                      // ~40 cm tussocks
    float k2 = 1.0 / (1.0 + pow(fp * 0.7, 2.0));                      // ~1.5 m
    float k3 = 1.0 / (1.0 + pow(fp * 0.12, 2.0));                     // ~8 m
    float2 qb = q + bend * 0.18;
    // blade-scale structure: fine isotropic clumping plus a wind-combed lay,
    // both footprint-filtered so nothing shimmers at 1 spp
    float tb = 0.0, lay = 0.0;
    if (kb > 0.02) {
        // the blade-scale fields ride the bend only slightly: at 24 fps and
        // 1 spp a strongly advected 4 cm field boils rather than sways
        float2 qf = q + bend * 0.035;
        tb = gnoise(qf * 26.0) * kb;
        lay = gnoise(float2(dot(qf, wv) * 3.4, dot(qf, float2(-wv.y, wv.x)) * 17.0)) * kb;
    }
    float t0 = gnoise(qb * 9.0);
    float t1 = gnoise(qb * 2.4);
    float t2 = gnoise(q * 0.70);
    float t3 = 0.60 * sin(dot(q, float2(0.87, 0.49)) * 0.12 + 0.4) + 0.40 * sin(dot(q, float2(0.31, -0.95)) * 0.185 + 2.9);
    float tuft = 1.35 * (0.22 * t0 * k0 + 0.46 * t1 * k1 + 0.20 * t2 * k2 + 0.12 * t3 * k3);
    float micro = 0.62 * tb + 0.38 * lay;
    // tufts shade each other toward the sun
    float2 sd2 = normalize(R.sun.xz + float2(1e-4, 1e-4));
    float off = 0.55 + 3.2 * (1.0 - smoothstep(0.02, 0.40, R.sun.y));
    float ts = gnoise((qb + sd2 * off) * 2.4) * k1;
    float selfSh = smoothstep(-0.55, 0.35, (t1 * k1) - ts * 0.88);
    float3 n = normalize(float3(-0.17 * t2 * k2 - 0.07 * bend * k2 - 0.13 * t1 * k1 - 0.34 * micro - 0.20 * t0 * k0,
                                1.0,
                                -0.17 * t3 * k2 - 0.07 * gust - 0.13 * t0 * k1 + 0.30 * lay + 0.22 * tb));
    nOut = n;
    aoOut = tuft;
    float3 dry  = ws_hex(0x847745u);
    float3 grn  = ws_hex(0x374D20u);
    float3 moss = ws_hex(0x5A6128u);
    float m1 = clamp(0.30 + 0.38 * t3 / max(k3, 0.2) + 0.26 * t2 / max(k2, 0.2) + 0.14 * gust, 0.0, 1.0);
    float3 alb = mix(grn, dry, m1 * m1);
    alb = mix(alb, moss, clamp(0.4 + 0.6 * t1 / max(k1, 0.2), 0.0, 1.0) * 0.30);
    alb *= clamp(0.78 + 0.38 * tuft, 0.45, 1.40);
    // gaps between the blades read as small hard shadows; seed heads catch light
    alb *= clamp(1.0 + 0.52 * micro + 0.30 * tb, 0.42, 1.65);
    alb = mix(alb, ws_hex(0xA79A63u), smoothstep(0.24, 0.62, tb + 0.4 * lay) * 0.30 * kb);
    float patch = tc_f01(t2 / max(k2, 0.2) + 0.6 * gust);
    alb = mix(alb, alb * float3(1.22, 1.12, 0.82), smoothstep(0.45, 0.95, patch) * 0.55);
    alb *= 0.80 + 0.24 * selfSh;                                       // tussock shadowing
    alb *= 1.0 + 0.14 * bend * k2;
    float scar = smoothstep(0.45, 0.95, 0.55 * sin(dot(q, float2(0.81, 0.59)) * 0.075 + 2.4) + 0.45 * sin(dot(q, float2(0.27, -0.96)) * 0.113 - 0.6) + 0.5 * t1 * k1);
    alb = mix(alb, ws_hex(0x877B63u) * (0.85 + 0.35 * t0 * k0), scar * 0.26);
    float dl = tc_coast(q, 2);
    alb = mix(alb, ws_hex(0x9A8E62u), smoothstep(9.0, 0.5, dl) * 0.40);
    alb = mix(alb, float3(ws_luma(alb)) * float3(1.06, 1.00, 0.88), 0.16);
    return alb;
}

// ------------------------------------------------------ distant headland
inline float tc_farProfile(float az) {
    float a = (az - 0.055) / 0.150;
    float h = 128.0 * exp(-a * a);
    float b = (az - 0.175) / 0.085;
    h += 78.0 * exp(-b * b);
    float c = (az + 0.115) / 0.10;
    h += 52.0 * exp(-c * c);
    h *= 0.88 + 0.24 * gnoise(float2(az * 42.0, 3.0));
    return h;
}

// ---------------------------------------------------------------- scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 uv = fragCoord / ctx.res;
    float time = ctx.time;

    TCRig R;
    R.time = time;
    // a slow continuous seed: the cloud field is a different one each hour/day
    R.seed = ctx.dayOfYear * 137.0 + ctx.dayTime * 41.0;
    R.sun  = normalize(ws_rotY(ctx.sunDir,  TC_HEAD));
    R.moon = normalize(ws_rotY(ctx.moonDir, TC_HEAD));
    R.sunEl = ctx.sunElevation;
    R.moonEl = asin(clamp(R.moon.y, -1.0, 1.0)) / TCD;
    R.night = smoothstep(0.5, -11.0, R.sunEl);
    R.day = smoothstep(-2.0, 6.0, R.sunEl);
    R.Esun = 15.5 * tc_sunT(R.sunEl) * smoothstep(-1.2, 0.9, R.sunEl);
    R.moonIl = clamp(ctx.moonIllum, 0.0, 1.0);
    R.moonPow = pow(R.moonIl, 1.4) * smoothstep(-1.5, 7.0, R.moonEl) * R.night;
    R.Emoon = float3(0.135, 0.163, 0.232) * R.moonPow;
    float3 zen = tc_atmos(float3(0.0, 1.0, 0.0), R.sun, 1) * 1.06;
    float3 bk  = tc_atmos(normalize(float3(0.0, 0.16, 1.0)), R.sun, 1) * 1.06;
    float3 nAmb = float3(0.0110, 0.0145, 0.0250) * R.night + float3(0.0125, 0.0163, 0.0255) * R.moonPow;
    R.Lz = (zen * 1.00 + nAmb) * 2.9;
    float bov = smoothstep(4.0, -3.0, R.sunEl) * smoothstep(-8.0, -2.0, R.sunEl);
    R.Lb = (bk * 0.95 * mix(float3(1.0), float3(2.4, 1.36, 1.26), bov) + nAmb) * 2.9;
    R.Lamb = tc_skyIrr(R.sun) + (float3(0.0060, 0.0080, 0.0145) * R.night
                                 + float3(0.0105, 0.0135, 0.0215) * R.moonPow);

    // camera
    float3 ro = float3(0.0, TC_EYE, 0.0);
    float2 pp = (2.0 * fragCoord - ctx.res) / ctx.res.y;
    float th = tan(0.5 * TC_FOV * TCD);
    float3 rd = normalize(float3(pp.x * th, pp.y * th, -1.0));
    float cp = cos(TC_PITCH * TCD), sp = sin(TC_PITCH * TCD);
    rd = normalize(float3(rd.x, rd.y * cp - rd.z * sp, rd.y * sp + rd.z * cp));
    float pixAng = (TC_FOV * TCD) / ctx.res.y;

    // desktop hygiene: quiet the menu-bar strip and the icon column
    float calm = 1.0 - 0.34 * smoothstep(0.50, 1.02, uv.y) - 0.26 * smoothstep(0.42, 1.05, uv.x) * smoothstep(0.45, 1.05, uv.y);
    calm = clamp(calm, 0.0, 1.0);
    calm = 1.0 - calm;                      // 0 = normal, 1 = calm

    float3 atmV = tc_atmos(rd, R.sun, 3);
    // 3-step integration over-reddens the horizon when the sun is high; correct it
    float hzc = smoothstep(0.17, 0.0, abs(rd.y)) * smoothstep(9.0, 26.0, R.sunEl);
    atmV = mix(atmV, mix(atmV, float3(ws_luma(atmV)) * float3(0.93, 1.0, 1.10), 0.55), hzc);
    float3 haze = atmV + nAmb * 0.8;

    // ---- analytic hits
    float tSea = (rd.y < -1e-5) ? (TC_EYE / -rd.y) : 1e9;
    float tPl  = (rd.y < -1e-5) ? ((TC_EYE - TC_HT) / -rd.y) : 1e9;
    float tMax = min(tSea, 1500.0);

    // stack bounding tests (2D cylinders)
    int sflags = 0;
    float tS0 = 1e9, tS1 = -1e9;
    for (int i = 0; i < 3; i++) {
        float2 c = TC_STK[i].xy - ro.xz;
        float2 d2 = rd.xz;
        float ll = dot(d2, d2);
        float tc = dot(c, d2) / max(ll, 1e-6);
        float2 cp2 = d2 * tc - c;
        float rb = TC_STK[i].z * 1.35 + 4.0;
        float dd = rb * rb - dot(cp2, cp2);
        if (dd > 0.0 && tc > 0.0 && rd.y < -1e-5) {
            float hw = sqrt(dd / max(ll, 1e-6));
            // also clip to the slab of heights the stack occupies
            float ta = (TC_EYE - (TC_STK[i].w + 4.0)) / (-rd.y);
            float tb = (TC_EYE + 3.0) / (-rd.y);
            float e0 = max(max(tc - hw, 1.0), ta), e1s = min(tc + hw, tb);
            if (e1s > e0) {
                sflags |= (1 << i);
                tS0 = min(tS0, e0);
                tS1 = max(tS1, e1s);
            }
        }
    }

    bool plateauHit = false;
    float tHit = 1e9;
    float3 nrm = float3(0.0, 1.0, 0.0);
    bool rockHit = false;

    float dlPl = -1.0;
    float topCov = 0.0;                 // sub-pixel coverage of the clifftop
    if (tPl < tMax) {
        for (int i = 0; i < 2; i++) {
            float2 Q = ro.xz + rd.xz * tPl;
            dlPl = tc_coast(Q, 2);
            float tn = (TC_EYE - tc_topH(Q, dlPl, 2)) / max(-rd.y, 1e-5);
            tPl = clamp(mix(tPl, tn, 0.92), 1.0, 6000.0);
        }
        dlPl = tc_coast(ro.xz + rd.xz * tPl, 2);
        if (tPl < tMax) {
            // coverage across the cliff edge in plan view (one pixel wide)
            float wC = clamp(0.62 * tPl * pixAng / max(-rd.y, 0.10), 0.04, 7.0);
            topCov = smoothstep(0.5 - wC, 0.5 + wC, dlPl);
            // coverage across the *skyline*: the ray grazes the moor, so sample
            // the height field a pixel either side and take the closest approach
            if (-rd.y < 0.028 && topCov > 0.0) {
                float dtp = min(tPl * pixAng / max(-rd.y, 0.0012), 0.55 * tPl);
                float Fm = 1e9;
                for (int k = -1; k <= 1; k += 2) {
                    float tk = tPl + float(k) * dtp * 0.58;
                    float2 Qk = ro.xz + rd.xz * tk;
                    Fm = min(Fm, (TC_EYE + rd.y * tk) - tc_topH(Qk, tc_coast(Qk, 2), 2));
                }
                float hpx = max(tPl * pixAng, 0.02);
                topCov *= smoothstep(0.55 * hpx, -0.55 * hpx, Fm);
            }
        }
        if (topCov > 0.004) { tHit = tPl; }
        if (topCov > 0.992) { plateauHit = true; tMax = tPl; }
    }

    // march the cliff face / stacks
    // Plan-view culling: beyond our own nose (~22 m) the coastline never comes
    // west of x = +19, so a ray only meets land after t = 19/rd.x.
    float tStart = 1e9;
    if (!plateauHit && rd.y < -1e-4) {
        tStart = max((TC_EYE - (TC_HT - 2.0)) / (-rd.y), 2.0);
        if (rd.x < 0.02) tMax = min(tMax, 46.0);
        else tStart = max(tStart, 80.0 / rd.x);
        if (sflags != 0) { tStart = min(tStart, max(tS0, 2.0)); tMax = max(tMax, min(tS1, tSea)); }
    }
    if (tStart < tMax) {
        float t = tStart;
        for (int i = 0; i < 24; i++) {
            float3 P = ro + rd * t;
            if (P.y < -3.0 || t > tMax) break;
            float v = P.z * 0.92 + P.x * 0.39;
            float dl = tc_coast(P.xz, 2);
            float dC = dl + TC_BATT * (TC_HT - P.y) + tc_faceS(P, v);
            bool far = (t > 430.0);
            float sd = max(-(dC + (far ? 1.20 : (P.y > 27.0 ? 2.9 : 3.9))) * 0.80, P.y - (TC_HT + 7.6));
            if (sflags & 1) sd = min(sd, tc_stackSD(P, 0, -1.0) - 3.0);
            if (sflags & 2) sd = min(sd, tc_stackSD(P, 1, -1.0) - 3.0);
            if (sflags & 4) sd = min(sd, tc_stackSD(P, 2, -1.0) - 3.0);
            if (sd > max(2.8, 0.0080 * t)) { t += sd * 0.97; continue; }
            float dk = smoothstep(355.0, 155.0, t);
            float d = dC + tc_bedStep(P, v) + (dk > 0.004 ? tc_faceX(P, v, dk) : 0.0);
            sd = tc_smax(-d * 0.62, P.y - tc_topH(P.xz, dl, 2), 1.8);
            if (sflags & 1) sd = min(sd, tc_stackSD(P, 0, dk));
            if (sflags & 2) sd = min(sd, tc_stackSD(P, 1, dk));
            if (sflags & 4) sd = min(sd, tc_stackSD(P, 2, dk));
            if (sd < 0.0030 * t) { rockHit = true; break; }
            t += max(sd * 0.90, 0.0080 * t);
        }
        if (rockHit) { tHit = t; plateauHit = false; }
    }

    float3 col;
    float dist = 1e9;
    float3 colTop = 0.0;

    if (topCov > 0.004) {
        // ---------------- foreground / clifftop grass
        float3 P = ro + rd * tPl;
        dist = tPl;
        float fp = max(tPl * pixAng / max(-rd.y, 0.004), tPl * pixAng);
        float3 n;
        float tuftAO = 0.0;
        float3 alb = tc_grass(P, rd, fp, R, n, tuftAO);
        float sh = smoothstep(-0.02, 0.10, R.sun.y);
        float ndl = max(dot(n, R.sun), 0.0);
        float3 dif = R.Esun * ndl * sh;
        // translucency: grass glows when back-lit by a low sun
        float bl = pow(max(dot(rd, R.sun), 0.0), 3.5) * smoothstep(0.26, 0.02, R.sun.y);
        dif += R.Esun * bl * 0.13 * sh * (0.4 + 0.6 * smoothstep(-0.5, 0.8, tuftAO));
        float3 amb = (R.Lamb * (0.20 + 0.16 * n.y) + R.Lz * 0.30 + R.Lb * 0.24) * (0.74 + 0.26 * smoothstep(-0.5, 0.6, tuftAO));
        col = alb * (dif * 0.33 + amb * 1.05) + R.Emoon * alb * max(dot(n, R.moon), 0.0) * 0.5;
        // sheen off the bent blades
        float3 hv = normalize(R.sun - rd);
        col += R.Esun * sh * 0.035 * pow(max(dot(n, hv), 0.0), 14.0) * smoothstep(0.35, 0.02, R.sun.y);
        col = mix(col, haze, ws_fogAmount(tPl, ro, rd, 1.0 / 26000.0, 1.0 / 900.0));
        colTop = col;
    }
    if (plateauHit) {
        col = colTop;
    } else if (rockHit) {
        // ---------------- cliff / sea stacks
        float3 P = ro + rd * tHit;
        dist = tHit;
        float dkH = smoothstep(355.0, 155.0, tHit);
        int lod = (tHit > 900.0) ? 2 : (tHit > 260.0 ? 1 : 0);
        float fp = tHit * pixAng;
        float3 n = tc_normal(P, clamp(0.85 * fp, 0.18, 3.0), dkH, sflags);
        float fpG = min(fp / clamp(dot(n, -rd), 0.10, 1.0), 14.0);
        // the footprint is anisotropic at this grazing angle: texture along the
        // face smears, but relief across it is still resolved
        float fpB = min(fp / clamp(dot(n, -rd), 0.40, 1.0), 3.5);
        float dlR = tc_coast(P.xz, 2);
        // which primitive did we hit?  (stacks live well offshore)
        int stk = -1;
        if (dlR < -20.0) {
            float bd = 1e9;
            for (int i = 0; i < 3; i++) {
                float2 dq = P.xz - TC_STK[i].xy;
                float dd = dot(dq, dq);
                float lim = TC_STK[i].z + 18.0;
                if (dd < bd && dd < lim * lim) { bd = dd; stk = i; }
            }
        }
        // micro relief: filtered high-frequency bump, keeps the rock from looking poured
        float mk = 1.0 / (1.0 + pow(fpB * 2.2, 2.0));
        if (mk > 0.03) {
            float vv = P.z * 0.92 + P.x * 0.39;
            float2 um = (stk >= 0) ? float2(P.x + P.z * 0.6, P.y * 1.9) * 1.25
                                   : float2(vv, P.y * 1.35) * 0.80;
            float n0 = vnoise(um), n1 = vnoise(um + float2(0.42, 0.0)), n2 = vnoise(um + float2(0.0, 0.42));
            float3 T = normalize(cross(n, float3(0.0, 1.0, 0.0)) + float3(1e-4, 0.0, 0.0));
            float3 B = cross(n, T);
            n = normalize(n - (T * (n1 - n0) + B * (n2 - n0)) * (1.30 * mk));
        }
        float bedAO = 0.0;
        float3 alb = tc_rockAlbedo(P, n, fpG, lod, stk, bedAO);
        float gm = smoothstep(0.42, 0.86, n.y) * smoothstep(-3.0, 7.0, dlR) * smoothstep(TC_HT - 20.0, TC_HT - 4.0, P.y);
        if (gm > 0.004) {
            float3 gn; float gao;
            float3 ga = tc_grass(P, rd, fp, R, gn, gao);
            alb = mix(alb, ga, gm);
            n = normalize(mix(n, normalize(n + gn * 0.7), gm));
        }
        float ao = tc_ao(P, n, sflags) * (1.0 - 0.20 * bedAO);
        float sh = tc_shadow(P + n * 0.5, R.sun, sflags);
        float ndl = max(dot(n, R.sun), 0.0);
        // wetness: tide band + wave run-up
        float dl = dlR;
        float dep = tc_depth(P.xz, dl);
        TCWave W;
        W.h = 0.0; W.foam = 0.0; W.brk = 0.0; W.foamTex = 0.0; W.rough2 = 0.0; W.n = float3(0.0, 1.0, 0.0);
        if (P.y < 22.0) W = tc_wave(P.xz, fp, time, dep, lod);
        float runup = W.h + 1.6 + 3.4 * W.brk;
        float wet = smoothstep(5.0, -1.2, P.y - runup);
        float wash = smoothstep(2.6, -0.8, P.y - runup - 0.6) * clamp(W.brk * 1.2, 0.0, 1.0);
        alb *= mix(1.0, 0.26, wet * 0.95);
        float3 dif = R.Esun * ndl * sh;
        float3 amb = R.Lamb * (0.28 + 0.36 * clamp(n.y * 0.5 + 0.5, 0.0, 1.0)) + R.Lz * 0.30 + R.Lb * 0.34;
        // bounce from the water below
        float3 bounce = mix(ws_hex(0x18404Au), ws_hex(0x2E5A60u), 0.5) * (R.Esun * 0.055 + R.Lamb * 0.55) * clamp(-n.y * 0.7 + 0.40, 0.0, 1.0);
        col = alb * (dif * 0.42 * (1.0 - 0.22 * bedAO) + amb * ao + bounce * ao);
        // wet specular
        float3 hv = normalize(R.sun - rd);
        float rgh = mix(0.62, 0.16, wet);
        float a2 = rgh * rgh * rgh * rgh;
        float ndh = max(dot(n, hv), 0.0);
        float D = a2 / (PI * pow(ndh * ndh * (a2 - 1.0) + 1.0, 2.0));
        float F = 0.03 + 0.20 * pow(1.0 - max(dot(n, -rd), 0.0), 5.0);
        col += R.Esun * min(D, 16.0) * F * ndl * sh * (0.15 + 0.42 * wet);
        col += R.Lz * wet * 0.09 * pow(1.0 - max(dot(n, -rd), 0.0), 4.0);
        // foam washing up the rock
        float3 foamC = (R.Esun * 0.165 * sh + R.Lamb * 0.20 + R.Lz * 0.36 + R.Lb * 0.14);
        float wtex = 0.30 + 0.95 * W.foamTex;
        col = mix(col, foamC * wtex, clamp(wash, 0.0, 1.0) * 0.34 * clamp(wtex, 0.0, 1.0));
        // spray veil hanging against the foot of the rock
        float veil = smoothstep(7.0, -1.5, P.y - runup) * clamp(W.brk, 0.0, 1.0)
                   * (0.25 + 0.75 * tc_f01(tc_sn(P.xz * 0.06 + float2(0.5, 0.2) * time)));
        col = mix(col, foamC * 0.80, clamp(veil, 0.0, 1.0) * 0.15);
        col += R.Emoon * alb * max(dot(n, R.moon), 0.0) * 0.55;
        col = mix(col, haze * float3(0.98, 1.00, 1.06), ws_fogAmount(tHit, ro, rd, 1.0 / 6200.0, 1.0 / 700.0));
    } else if (tSea < 1e8) {
        // ---------------- ocean
        float3 P = ro + rd * tSea;
        dist = tSea;
        float fp = tSea * pixAng / max(-rd.y, 0.0025);
        float dl = tc_coast(P.xz, 2);
        float dep = tc_depth(P.xz, dl);
        int lod = (tSea > 900.0) ? 2 : (tSea > 300.0 ? 1 : 0);
        TCWave W = tc_wave(P.xz, fp, time, dep, lod);
        float3 n = W.n;
        float3 Rv = reflect(rd, n);
        Rv.y = max(Rv.y, 0.0022);
        Rv = normalize(Rv);
        float3 atmR = tc_atmos(Rv, R.sun, 2) * 1.02;
        float hzr = smoothstep(0.20, 0.0, abs(Rv.y)) * smoothstep(6.0, 24.0, R.sunEl);
        atmR = mix(atmR, mix(atmR, float3(ws_luma(atmR)) * float3(0.93, 1.0, 1.10), 0.70), hzr);
        float calmW = calm * (0.35 + 0.65 * smoothstep(-0.05, 0.40, uv.y));
        float3 refl = tc_sky(Rv, atmR, R, (W.rough2 > 0.0035) ? 3 : 2, calmW);
        // rough water blurs its reflection toward the average sky
        float rblur = clamp(sqrt(W.rough2) * 4.6 + 0.10, 0.0, 0.88);
        refl = mix(refl, (R.Lz * 0.26 + R.Lb * 0.42) + nAmb * (1.0 - 0.55 * R.night), rblur * 0.58);
        // the cliff reflects into the water at its foot
        if (dl > -115.0 && tSea < 1350.0) {
            float tr = 2.0, occ = 0.0, mn = 1.0;
            for (int i = 0; i < 4; i++) {
                float sdv = tc_mapLo(P + Rv * tr, sflags);
                mn = min(mn, sdv / (2.0 + 0.10 * tr));
                if (sdv < 0.3) { occ = 1.0; break; }
                tr += max(sdv * 0.95, 6.0);
                if (tr > 200.0) break;
            }
            occ = max(occ, 1.0 - clamp(mn, 0.0, 1.0));
            if (occ > 0.01) {
                float3 rockR = ws_hex(0x6A5A46u) * (R.Lz * 0.20 + R.Esun * 0.06) + R.Lz * 0.04;
                refl = mix(refl, rockR, 0.80 * occ);
            }
        }
        float cosI = clamp(dot(-rd, n), 0.0, 1.0);
        float F = 0.02 + 0.98 * pow(1.0 - cosI, 5.0);
        F *= 1.0 / (1.0 + 1.9 * sqrt(W.rough2));          // Smith-ish masking on rough water
        // body: deep green-blue, turquoise where shallow
        float3 deep = ws_hex(0x123F51u);
        float3 shal = ws_hex(0x2A7E78u);
        float shalF = smoothstep(18.0, 1.5, dep) * 0.85 * (0.06 + 0.94 * smoothstep(-7.0, 3.0, R.sunEl));
        float3 wc = mix(deep, shal, shalF);
        float3 body = wc * (R.Lz * 1.02 + R.Lb * 0.40) + wc * R.Esun * (0.055 + 0.14 * shalF) * max(R.sun.y, 0.0);
        body *= 1.0 - 0.62 * R.night;
        col = mix(body, refl, F);
        // specular glitter (roughness grows with the filtered ripples)
        float rgh = sqrt(clamp(0.0042 + W.rough2 * 2.6, 0.0, 0.5));
        float a2 = rgh * rgh * rgh * rgh;
        float3 hv = normalize(R.sun - rd);
        float ndh = max(dot(n, hv), 0.0);
        float D = a2 / (PI * pow(ndh * ndh * (a2 - 1.0) + 1.0, 2.0));
        col += R.Esun * D * F * max(dot(n, R.sun), 0.0) * 0.30;
        float3 hm = normalize(R.moon - rd);
        float ndhm = max(dot(n, hm), 0.0);
        float Dm = a2 / (PI * pow(ndhm * ndhm * (a2 - 1.0) + 1.0, 2.0));
        col += R.Emoon * Dm * F * 2.6 * max(dot(n, R.moon), 0.0);
        // whitewater
        float3 foamC = (R.Esun * 0.155 * max(R.sun.y, 0.0) + R.Esun * 0.042 + R.Lamb * 0.20 + R.Lz * 0.34 + R.Lb * 0.14);
        float fw = clamp(W.foam, 0.0, 1.0);
        // aerated foam is lit unevenly: bright crest, shaded pits, and the
        // thin trailing sheet still shows the water colour through it
        float3 fc = foamC * (0.34 + 1.35 * (W.foamTex - 0.30));
        fc = mix(fc, fc * float3(0.86, 0.95, 1.04), 0.35);
        fc = mix(mix(col, fc, 0.55), fc, smoothstep(0.30, 0.80, fw));
        col = mix(col, fc, fw * 0.90);
        // bioluminescence in the breaking foam
        col += float3(0.05, 0.34, 0.26) * fw * W.brk * R.night * 0.055;
        col = mix(col, haze, ws_fogAmount(tSea, ro, rd, 1.0 / 14000.0, 1.0 / 260.0));
        col = mix(col, haze * float3(1.00, 1.00, 1.02), smoothstep(2600.0, 11000.0, tSea) * 0.72);
    } else {
        col = tc_sky(rd, atmV, R, 0, calm);
        dist = 1e9;
    }

    if (topCov > 0.004 && !plateauHit) {
        col = mix(col, colTop, topCov);
        dist = mix(dist, tPl, topCov);
    }

    // ---------------- distant headland + harbour light
    if (dist > 8600.0) {
        float az = atan2(rd.x, -rd.z);
        if (az > -0.26 && az < 0.34) {
            float hp = tc_farProfile(az);
            float el = (hp - TC_EYE) / 9000.0;
            // haze eats the ridge line: a soft, low-contrast silhouette
            float px = pixAng * 2.6 + 0.00055;
            float m = smoothstep(el + px, el - px, rd.y) * 0.92;
            if (m > 0.002) {
                float shade = 0.55 + 0.45 * smoothstep(el, -0.004, rd.y);
                float3 lc = mix(haze * 1.02, ws_hex(0x2C3A3Eu) * (R.Lz * 0.5 + R.Esun * 0.05), 0.135 * shade);
                col = mix(col, lc, m);
            }
        }
        // blinking harbour light on the far headland
        float blink = smoothstep(0.02, 0.06, 0.24 - fract(time / 4.6));
        float lit = blink * smoothstep(2.0, -6.0, R.sunEl);
        if (lit > 0.002) {
            float3 ld = normalize(float3(sin(0.155), (34.0 - TC_EYE) / 9000.0, -cos(0.155)));
            float ang = acos(clamp(dot(rd, ld), -1.0, 1.0)) / (pixAng * 1.9);
            col += float3(1.0, 0.72, 0.36) * lit * (exp(-ang * ang) * 1.6 + 0.10 * exp(-ang * 0.35));
        }
    }

    // ---------------- gulls: tiny distant specks wheeling over the water
    if (dist > 2000.0 && rd.y > -0.010 && rd.y < 0.055 && R.sunEl > -4.0) {
        float gw = pixAng * 0.85;
        for (int g = 0; g < 3; g++) {
            float ph = R.time * (0.055 + 0.021 * float(g)) + float(g) * 2.1;
            float az = -0.30 + 0.26 * float(g) + 0.085 * sin(ph);
            float el = 0.004 + 0.0065 * float(g) + 0.0060 * sin(ph * 1.7 + 1.0);
            float3 gd = float3(sin(az), el, -cos(az));
            float3 dv = rd - gd * (1.0 / length(gd));
            float r2 = dot(dv, dv) / (gw * gw);
            if (r2 < 9.0) col = mix(col, mix(col * 0.70, haze, 0.45), exp(-r2) * 0.55);
        }
    }

    // ---------------- spray hanging over the break line
    {
        float y0 = 16.0, t0 = (TC_EYE - y0) / max(-rd.y, 1e-4), t1 = TC_EYE / max(-rd.y, 1e-4);
        t0 = max(t0, 1.0); t1 = min(t1, min(dist, 1600.0));
        float2 Pm = (ro + rd * (0.5 * (t0 + t1))).xz;
        float nearM = exp(-pow((tc_coast(Pm, 2) + 14.0) / 34.0, 2.0));
        if (t1 > t0 + 1.0 && nearM > 0.012) {
            float acc = 0.0;
            for (int i = 0; i < 2; i++) {
                float tt = mix(t0, t1, (float(i) + 0.5) / 2.0);
                float3 P = ro + rd * tt;
                float dl = tc_coast(P.xz, 2);
                float near = exp(-pow((dl + 14.0) / 26.0, 2.0));
                if (near < 0.02) continue;
                float dep = tc_depth(P.xz, dl);
                float sh2 = clamp(pow(26.0 / max(dep, 1.2), 0.25), 1.0, 2.6);
                float hs = 1.28 * sh2 * sin(dot(P.xz, float2(0.951, 0.309)) * 0.0532 - 0.723 * time)
                         + 0.88 * sh2 * sin(dot(P.xz, float2(0.883, 0.469)) * 0.0849 - 0.913 * time + 1.7);
                float bk = smoothstep(0.34, 0.85, (hs * 1.10 + 0.30) / max(dep, 0.55));
                float plume = bk * near * exp(-max(P.y, 0.0) / 7.5);
                plume *= 0.45 + 1.0 * tc_f01(tc_sn(P.xz * 0.05 + float2(0.6, 0.2) * time));
                acc += plume;
            }
            acc = clamp(acc * (t1 - t0) / 350.0, 0.0, 0.78);
            if (acc > 0.002) {
                float3 sc = R.Lz * 0.46 + R.Lb * 0.19 + R.Esun * (0.10 + 0.55 * pow(max(dot(rd, R.sun), 0.0), 8.0));
                col = mix(col, sc, acc);
            }
        }
    }

    // ---------------- grade
    float3 c = col * 0.72;
    c *= 1.0 + 2.1 * R.night * (1.0 - 0.30 * clamp(R.moonPow, 0.0, 1.0))
             + 1.05 * smoothstep(2.0, -7.0, R.sunEl) * (1.0 - R.night);                        // lift the twilight a little
    c *= ws_vignette(uv, 0.30);
    c = ws_acesFitted(c);
    c = ws_saturate(c, 1.045);
    c += (ws_grain(fragCoord, ctx.t) - 0.5) * 0.005;
    return clamp(c, 0.0, 1.0);
}
