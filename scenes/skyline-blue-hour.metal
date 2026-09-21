// =====================================================================
//  Skyline Blue Hour — photoreal city skyline across a bay at civil twilight
//
//  * Camera 6.5 m above calm water; a dense procedural city 1.3–3.9 km away,
//    traced exactly as a grid-DDA over per-cell building boxes (stepped
//    towers, slabs, mechanical penthouses, antenna masts with red beacons).
//  * Facades: per-building window grids (residential scatter vs office bands),
//    blackbody-coloured emitters with ceiling-light gradients, storefront glow,
//    crown lighting, floodlit towers, sky-reflecting dark glass.
//  * Exponential height haze with warm city-glow in-scatter; hazy far ridge.
//  * Water: Fresnel mirror, gentle deterministic swell + stratified stochastic
//    micro-slope taps (long-exposure light streaks); floor-smeared window LOD
//    in the mirror so the streaks integrate cleanly.
//  * Parametric blue-hour sky (ozone-blue zenith, warm sunset band), thin
//    high cirrus, quay lamps with lens halos.
// =====================================================================

constant float SB_DEG    = 0.017453292519943295;
constant float SB_C      = 34.0;      // city grid pitch (m)
constant float SB_FLOOR  = 3.55;      // floor pitch (m)
constant float SB_ZSHORE = 1300.0;    // mean shoreline distance (m)
constant float SB_ZEND   = 3900.0;    // far edge of the city (m)
constant float SB_XEXT   = 2300.0;    // half-width of the city (m)
constant float SB_HMAX   = 330.0;     // tallest possible building (m)
constant float SB_CAMY   = 6.5;
constant float SB_FOVY   = 34.0;
constant float SB_PITCH  = 2.6;       // camera pitch up (deg)
constant float SB_SUNAZ  = -16.0;     // set-sun azimuth relative to the view axis (deg, - = left)
constant int   SB_TAPS   = 4;         // stochastic mirror taps per sample
constant float SB_SLOPE  = 0.03;      // rms micro-slope of the water (per axis)
constant float SB_HAZE   = 0.00028;   // haze density at sea level (1/m)
constant float SB_HAZEK  = 1.0 / 90.0; // haze scale height (1/m)
constant float SB_LAMPDX = 21.0;      // quay lamp spacing (m)

// ------------------------------------------------------------ colour authoring
// Inverse of Hill's ACES fit: author colours as display sRGB targets (exposure 1).
inline float sb_invCurve(float r) {
    r = clamp(r, 0.0, 0.995);
    float A = 0.983729 * r - 1.0, B = 0.4329510 * r - 0.0245786, C = 0.238081 * r + 0.000090537;
    float disc = max(B * B - 4.0 * A * C, 0.0);
    return (-B - sqrt(disc)) / (2.0 * A);
}
inline float3 sb_disp(uint hex) {
    float3 o = ws_hex(hex);
    float3 r = float3(dot(float3(0.643038, 0.311187, 0.045775), o),
                      dot(float3(0.059269, 0.931436, 0.009295), o),
                      dot(float3(0.005962, 0.063929, 0.930118), o));
    float3 i = float3(sb_invCurve(r.x), sb_invCurve(r.y), sb_invCurve(r.z));
    return max(float3(dot(float3( 1.764741, -0.675778, -0.088963), i),
                      dot(float3(-0.147028,  1.160252, -0.013224), i),
                      dot(float3(-0.036337, -0.162436,  1.198773), i)), 0.0);
}

// ------------------------------------------------------------ sky
inline float2 sb_sunAzVec() { return float2(sin(SB_SUNAZ * SB_DEG), cos(SB_SUNAZ * SB_DEG)); }

// relative amount of city (and therefore light-pollution glow) in a direction
inline float sb_cityDens(float3 rd) {
    float az = atan2(rd.x, rd.z);
    float d = (az + 8.0 * SB_DEG) / (30.0 * SB_DEG);
    return 0.45 + 0.55 * exp(-d * d);
}
inline float3 sb_cityGlow(float3 rd) {
    float hp = max(asin(clamp(rd.y, -1.0, 1.0)), 0.0);
    return sb_disp(0xffb070) * (0.14 * exp(-hp / 0.030) + 0.045 * exp(-hp / 0.11)) * sb_cityDens(rd);
}
// Parametric blue-hour sky radiance (linear, pre-exposure), no glow.
inline float3 sb_skyBase(float3 rd) {
    float h = asin(clamp(rd.y, -1.0, 1.0));
    float hp = max(h, 0.0);
    float2 a = normalize(rd.xz + float2(1e-5, 0.0));
    float s = 0.5 + 0.5 * dot(a, sb_sunAzVec());
    float3 zen = sb_disp(0x08132f);
    float3 mid = sb_disp(0x1a3266);
    float3 hzA = sb_disp(0x4a5f8c);   // horizon away from the sun: grey-blue
    float3 hzS = sb_disp(0x9a8fa4);   // horizon toward the sun: pale mauve
    float3 glowW = sb_disp(0xf2a35a); // warm band
    float3 base = mix(mid, zen, smoothstep(0.03, 1.2, hp));
    float3 hz = mix(hzA, hzS, s * s);
    base = mix(base, hz, exp(-hp / 0.15));
    float g = exp(-hp / 0.045) * pow(s, 6.0);
    base += glowW * g * 0.85 + sb_disp(0xb87a70) * exp(-hp / 0.10) * pow(s, 2.5) * 0.28;
    return base;
}
inline float3 sb_hazeCol(float3 rd) {
    float3 r = normalize(float3(rd.x, max(rd.y, 0.008), rd.z));
    return sb_skyBase(r) + sb_cityGlow(rd) * 1.4;
}
inline float sb_hillH(float3 rd) {
    float az = atan2(rd.x, rd.z);
    return (0.30 + 0.60 * ridged(float2(az * 6.0 + 2.0, 0.5), 4) + 0.12 * gnoise(float2(az * 22.0, 1.0))) * SB_DEG;
}
inline float3 sb_clouds(float3 rd, float3 col) {
    if (rd.y < 0.015) return col;
    float hp = asin(clamp(rd.y, -1.0, 1.0));
    float2 p = rd.xz / rd.y * 6.0 + float2(3.0, 40.0);   // km on a 6 km layer
    float n = fbm(p * float2(0.045, 0.16), 5);
    float n2 = fbm(p * float2(0.22, 0.6) + 7.0, 3);
    float d = smoothstep(0.10, 0.60, n + 0.25 * n2);
    float a = d * 0.32 * smoothstep(0.015, 0.09, rd.y) * (1.0 - 0.7 * smoothstep(0.35, 0.8, rd.y));
    float2 av = normalize(rd.xz + float2(1e-5, 0.0));
    float s = 0.5 + 0.5 * dot(av, sb_sunAzVec());
    float3 lit = mix(sb_disp(0x3a4668), sb_disp(0xc48d84), pow(s, 3.0) * exp(-hp / 0.12));
    return mix(col, lit, a);
}
// full sky for a ray that leaves the city: base + glow + clouds + far ridge
inline float3 sb_sky(float3 rd) {
    float3 col = sb_skyBase(rd);
    col = sb_clouds(rd, col);
    col += sb_cityGlow(rd);
    if (rd.y < sb_hillH(rd)) {
        float3 hill = sb_disp(0x1c2438) * 0.6;
        col = mix(hill, sb_hazeCol(rd), 0.78);
    }
    return col;
}

// ------------------------------------------------------------ city layout
struct SBBld {
    float3 mn0, mx0;     // main block
    float3 mn1, mx1;     // setback block (mx1.y < 0: none)
    float3 mn2, mx2;     // mechanical penthouse (mx2.y < 0: none)
    float2 mastXZ;
    float  mastH;        // 0: none
    float  H;
    float4 h;
    float  bay, winW, winH, office, litP, crown, flood, albedo;
    float3 crownCol, floodCol;
    int    kind;         // 0 none, 1 building, 2 quay
};

inline float sb_shoreZ(float x) {
    return SB_ZSHORE + 45.0 * sin(x * 0.0019 + 0.7) + 22.0 * sin(x * 0.0051 + 2.1) + 9.0 * sin(x * 0.013 + 0.4);
}
inline float sb_envelope(float2 p) {
    float2 d1 = (p - float2(-260.0, 1750.0)) / float2(330.0, 280.0);
    float2 d2 = (p - float2( 640.0, 2150.0)) / float2(260.0, 260.0);
    float2 d3 = (p - float2(-900.0, 2300.0)) / float2(240.0, 260.0);
    float2 d4 = (p - float2( 150.0, 2750.0)) / float2(420.0, 300.0);
    float e = exp(-dot(d1, d1)) + 0.5 * exp(-dot(d2, d2)) + 0.42 * exp(-dot(d3, d3)) + 0.3 * exp(-dot(d4, d4));
    e *= 0.8 + 0.4 * gnoise(p * 0.0025);
    return e;
}

inline SBBld sb_building(float2 cell) {
    SBBld b;
    b.kind = 0; b.H = 0.0; b.mastH = 0.0;
    b.mx1 = float3(0.0, -1.0, 0.0); b.mx2 = float3(0.0, -1.0, 0.0);
    b.mn1 = float3(0.0); b.mn2 = float3(0.0); b.mastXZ = float2(0.0);
    b.crown = 0.0; b.flood = 0.0; b.office = 0.0; b.bay = 3.2; b.winW = 0.7; b.winH = 0.6; b.litP = 0.3; b.albedo = 0.25;
    b.crownCol = float3(0.0); b.floodCol = float3(0.0);
    float2 c0 = cell * SB_C;
    float2 cc = c0 + SB_C * 0.5;
    if (abs(cc.x) > SB_XEXT || cc.y > SB_ZEND) return b;
    float sz = sb_shoreZ(cc.x);
    float s = cc.y - sz;
    if (s < -SB_C * 0.5) return b;            // water
    float4 h  = hash24(cell + float2(0.37, 0.91));
    float4 h2 = hash24(cell + float2(13.1, 5.3));
    float4 h3 = hash24(cell + float2(27.7, 1.9));
    b.h = h;
    if (s < SB_C * 0.5) {                      // quay strip along the shoreline
        b.kind = 2;
        b.mn0 = float3(c0.x, 0.0, max(c0.y, sz));
        b.mx0 = float3(c0.x + SB_C, 2.8, c0.y + SB_C);
        b.H = 2.8;
        return b;
    }
    float E = sb_envelope(cc);
    bool waterfront = s < SB_C * 2.0;
    if (h.x < 0.08 && E < 0.25) return b;      // empty lot / park
    float H = 12.0 + 26.0 * h.y * h.y + 290.0 * E * (0.35 + 0.65 * h.z);
    if (h2.x > 0.93) H += 45.0 + 40.0 * h2.y;  // outlier mid-rise
    if (waterfront) H = min(H, 10.0 + 30.0 * h.y);
    int floors = max(int(floor(H / SB_FLOOR)), 2);
    H = float(floors) * SB_FLOOR + 0.9;
    b.H = H;
    b.kind = 1;
    // footprint
    float insA = SB_C * (0.07 + 0.10 * h2.z), insB = SB_C * (0.07 + 0.10 * h2.w);
    float2 mn = c0 + float2(insA, insB), mx = c0 + SB_C - float2(insB, insA);
    float2 ctr = 0.5 * (mn + mx), hf = 0.5 * (mx - mn);
    float tall = smoothstep(80.0, 220.0, H);
    hf *= 1.0 - 0.32 * tall * h.w;             // tall towers are slimmer
    bool slab = h2.x > 0.65 && h2.x < 0.80;
    if (slab) { if (h3.x < 0.5) hf.y *= 0.5; else hf.x *= 0.5; }
    mn = ctr - hf; mx = ctr + hf;
    b.mn0 = float3(mn.x, 0.0, mn.y); b.mx0 = float3(mx.x, H, mx.y);
    // setback tower
    if (h2.x > 0.35 && h2.x < 0.65 && H > 50.0) {
        float H1 = SB_FLOOR * floor((0.5 + 0.25 * h3.y) * float(floors)) + 0.9;
        b.mx0.y = H1;
        float2 ins = hf * (0.12 + 0.18 * h3.z);
        b.mn1 = float3(mn.x + ins.x, 0.0, mn.y + ins.y);
        b.mx1 = float3(mx.x - ins.x, H, mx.y - ins.y);
    }
    // mechanical penthouse
    if (H > 35.0 && h2.y > 0.45) {
        float3 tmn = b.mx1.y > 0.0 ? b.mn1 : b.mn0;
        float3 tmx = b.mx1.y > 0.0 ? b.mx1 : b.mx0;
        float2 tc = 0.5 * (tmn.xz + tmx.xz), th = 0.5 * (tmx.xz - tmn.xz) * (0.35 + 0.25 * h3.w);
        b.mn2 = float3(tc.x - th.x, H, tc.y - th.y);
        b.mx2 = float3(tc.x + th.x, H + 3.5 + 2.5 * h3.x, tc.y + th.y);
    }
    // antenna mast
    if (H > 140.0 && h2.w > 0.45) {
        float3 tmn = b.mx1.y > 0.0 ? b.mn1 : b.mn0;
        float3 tmx = b.mx1.y > 0.0 ? b.mx1 : b.mx0;
        b.mastXZ = 0.5 * (tmn.xz + tmx.xz);
        b.mastH = 14.0 + 34.0 * h2.w;
    }
    // facade parameters
    b.office = (h3.y > 0.45 && H > 60.0) ? 1.0 : 0.0;
    b.bay  = b.office > 0.5 ? 2.6 + 1.6 * h3.z : 3.0 + 1.6 * h3.z;
    b.winW = b.office > 0.5 ? 0.86 + 0.1 * h3.w : 0.55 + 0.3 * h3.w;
    b.winH = b.office > 0.5 ? 0.62 + 0.15 * h3.x : 0.45 + 0.25 * h3.x;
    b.litP = 0.22 + 0.28 * h3.y;
    b.albedo = 0.16 + 0.22 * h2.z;
    if (H > 110.0 && h3.z > 0.80) {
        b.crown = 1.0;
        float k = h3.w;
        b.crownCol = k < 0.35 ? float3(0.9, 0.95, 1.0) : (k < 0.6 ? float3(1.0, 0.72, 0.35) : (k < 0.8 ? float3(0.35, 0.7, 1.0) : float3(1.0, 0.25, 0.2)));
    }
    if (H > 90.0 && h3.x > 0.90) {
        b.flood = 1.0;
        b.floodCol = h3.w < 0.5 ? float3(1.0, 0.8, 0.55) : float3(0.75, 0.85, 1.0);
    }
    return b;
}

// ------------------------------------------------------------ intersection
inline bool sb_box(float3 ro, float3 rd, float3 invRd, float3 mn, float3 mx, thread float &tN, thread float3 &nrm) {
    float3 t0 = (mn - ro) * invRd, t1 = (mx - ro) * invRd;
    float3 tmin = min(t0, t1), tmax = max(t0, t1);
    float tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    if (tn > tf || tf < 0.0) return false;
    tN = tn;
    if (tn == tmin.x) nrm = float3(rd.x > 0.0 ? -1.0 : 1.0, 0.0, 0.0);
    else if (tn == tmin.y) nrm = float3(0.0, rd.y > 0.0 ? -1.0 : 1.0, 0.0);
    else nrm = float3(0.0, 0.0, rd.z > 0.0 ? -1.0 : 1.0);
    return true;
}
// vertical cylinder (axis through (cx,cz)), y in [y0, y1]
inline bool sb_cyl(float3 ro, float3 rd, float2 c, float r, float y0, float y1, thread float &tN, thread float3 &nrm) {
    float2 oc = ro.xz - c;
    float a = dot(rd.xz, rd.xz);
    if (a < 1e-8) return false;
    float bq = dot(oc, rd.xz);
    float cq = dot(oc, oc) - r * r;
    float d = bq * bq - a * cq;
    if (d < 0.0) return false;
    float t = (-bq - sqrt(d)) / a;
    if (t < 0.0) return false;
    float y = ro.y + rd.y * t;
    if (y < y0 || y > y1) return false;
    tN = t;
    float2 n2 = normalize(oc + rd.xz * t);
    nrm = float3(n2.x, 0.0, n2.y);
    return true;
}
inline bool sb_sphere(float3 ro, float3 rd, float3 c, float r, thread float &tN) {
    float3 oc = ro - c;
    float bq = dot(oc, rd);
    float cq = dot(oc, oc) - r * r;
    float d = bq * bq - cq;
    if (d < 0.0) return false;
    float t = -bq - sqrt(d);
    if (t < 0.0) return false;
    tN = t; return true;
}

struct SBHit {
    float t; float3 p; float3 n; int box; SBBld b;
};

// Grid DDA through the city. Accumulates beacon halos in `glow`.
inline bool sb_trace(float3 ro, float3 rd, thread SBHit &hit, thread float3 &glow) {
    if (rd.z <= 1e-4) return false;
    float zNear = SB_ZSHORE - 130.0;
    float t0 = ro.z < zNear ? (zNear - ro.z) / rd.z : 0.0;
    float tG = rd.y < -1e-7 ? (-ro.y / rd.y) : 1e9;   // ground (water plane) time from ro
    float tLimit = tG - t0;
    if (tLimit <= 0.0) return false;
    float3 p0 = ro + rd * t0;
    float3 invRd = 1.0 / float3(abs(rd.x) < 1e-7 ? 1e-7 : rd.x, abs(rd.y) < 1e-7 ? 1e-7 : rd.y, rd.z);
    float2 cell = floor(p0.xz / SB_C);
    float2 sgn = float2(rd.x >= 0.0 ? 1.0 : -1.0, 1.0);
    float2 ard = max(abs(rd.xz), 1e-6);
    float2 tDelta = SB_C / ard;
    float2 nextB = (cell + max(sgn, 0.0)) * SB_C;
    float2 tMax = abs(nextB - p0.xz) / ard;
    float tIn = 0.0;
    for (int i = 0; i < 170; i++) {
        float tExit = min(tMax.x, tMax.y);
        float zc = (cell.y + 0.5) * SB_C;
        if (zc > SB_ZEND) return false;
        if (tIn > tLimit) return false;
        float yIn = p0.y + rd.y * tIn;
        if (rd.y >= 0.0 && yIn > SB_HMAX + 60.0) return false;
        float xc = (cell.x + 0.5) * SB_C;
        if (abs(xc) > SB_XEXT + SB_C && sgn.x * xc > 0.0) return false;
        SBBld b = sb_building(cell);
        if (b.kind != 0) {
            float yOut = p0.y + rd.y * min(tExit, tLimit);
            float topH = b.H + (b.mx2.y > 0.0 ? 8.0 : 0.0) + b.mastH;
            if (min(yIn, yOut) <= topH) {
                float best = 1e9; int bi = -1; float3 bn = float3(0.0);
                float tb; float3 n;
                if (sb_box(p0, rd, invRd, b.mn0, b.mx0, tb, n) && tb < best) { best = tb; bn = n; bi = 0; }
                if (b.mx1.y > 0.0 && sb_box(p0, rd, invRd, b.mn1, b.mx1, tb, n) && tb < best) { best = tb; bn = n; bi = 1; }
                if (b.mx2.y > 0.0 && sb_box(p0, rd, invRd, b.mn2, b.mx2, tb, n) && tb < best) { best = tb; bn = n; bi = 2; }
                if (b.mastH > 0.0) {
                    float yTop = b.H + b.mastH;
                    if (sb_cyl(p0, rd, b.mastXZ, 0.55, b.H, yTop, tb, n) && tb < best) { best = tb; bn = n; bi = 3; }
                    float3 L = float3(b.mastXZ.x, yTop + 0.6, b.mastXZ.y);
                    if (sb_sphere(p0, rd, L, 0.9, tb) && tb < best) { best = tb; bn = float3(0.0, 1.0, 0.0); bi = 4; }
                    // beacon halo (lens bloom)
                    float3 Lv = L - p0; float tc = dot(Lv, rd);
                    if (tc > 1.0) {
                        float ang = length(Lv - tc * rd) / tc;
                        float sg = 0.0011;
                        glow += float3(1.0, 0.06, 0.02) * 0.045 * sg * sg / (ang * ang + sg * sg);
                    }
                }
                if (bi >= 0 && best <= tLimit) {
                    hit.t = t0 + best; hit.p = p0 + rd * best; hit.n = bn; hit.box = bi; hit.b = b;
                    return true;
                }
            }
        }
        if (tMax.x < tMax.y) { tIn = tMax.x; tMax.x += tDelta.x; cell.x += sgn.x; }
        else                 { tIn = tMax.y; tMax.y += tDelta.y; cell.y += 1.0; }
    }
    return false;
}

// ------------------------------------------------------------ facades
inline float3 sb_winLight(float iu, float iv, float seed, thread const SBBld &b) {
    float4 r = hash24(float2(iu * 3.0 + seed, iv * 1.7 + seed * 0.31));
    float fl = hash12(float2(iv + 0.5, seed + 3.7));
    float pOff = fl < 0.42 ? 0.90 : 0.05;
    float p = mix(b.litP, pOff, b.office);
    if (iv < 1.5) p = max(p, 0.75);
    if (r.x > p) return float3(0.0);
    float3 c;
    float cw = r.y;
    if (b.office > 0.5) c = mix(ws_blackbody(4200.0), ws_blackbody(5800.0), cw);
    else c = cw < 0.72 ? ws_blackbody(2500.0 + 1100.0 * cw / 0.72)
           : (cw < 0.92 ? ws_blackbody(4300.0) : float3(0.55, 0.75, 1.0));
    float bri = 0.45 + 1.7 * r.z * r.z + (r.w > 0.965 ? 2.5 : 0.0);
    if (iv < 1.5) { bri *= 1.5; c = mix(c, ws_blackbody(3000.0), 0.5); }
    return c * bri;
}
// rgb: emission; a: window coverage (glass)
inline float4 sb_windows(float u, float v, float faceW, thread const SBBld &b, int f, float smear, float Htop) {
    float bay = b.bay;
    float nb = floor(faceW / bay);
    if (nb < 1.0) return float4(0.0);
    float off = 0.5 * (faceW - nb * bay);
    float fu = (u - off) / bay;
    if (fu < 0.0 || fu >= nb) return float4(0.0);
    float iu = floor(fu), xu = fu - iu;
    float fv = v / SB_FLOOR;
    float iv = floor(fv), xv = fv - iv;
    float nf = floor((Htop - 0.9) / SB_FLOOR + 0.01);
    if (iv >= nf) return float4(0.0);
    float seed = floor(b.h.x * 4096.0) + float(f) * 7.13;
    float inX = step(abs(xu - 0.5), 0.5 * b.winW);
    if (inX < 0.5) return float4(0.0);
    if (smear < 0.5) {
        float y0 = 0.55 - 0.5 * b.winH, y1 = 0.55 + 0.5 * b.winH;
        if (xv < y0 || xv > y1) return float4(0.0);
        float g = (xv - y0) / b.winH;
        float3 e = sb_winLight(iu, iv, seed, b) * (0.7 + 0.6 * g);
        return float4(e, 1.0);
    }
    float3 e = float3(0.0);
    for (int k = -3; k <= 3; k++) {
        float j = iv + float(k);
        if (j < 0.0 || j >= nf) continue;
        e += sb_winLight(iu, j, seed, b);
    }
    return float4(e * (b.winH / 7.0), b.winH);
}

inline float3 sb_shade(thread const SBHit &h, float3 rd, float smear) {
    thread const SBBld &b = h.b;
    float3 p = h.p, n = h.n;
    if (h.box == 3) return float3(0.004, 0.004, 0.006);
    if (h.box == 4) return float3(1.0, 0.05, 0.02) * 9.0;
    if (n.y > 0.5) return float3(0.006, 0.006, 0.009);
    float faceSun = 0.5 + 0.5 * dot(n.xz, sb_sunAzVec());
    float3 amb = mix(sb_disp(0x182744), sb_disp(0x8a7c86), faceSun * faceSun) * 0.16;
    if (b.kind == 2) {
        float lampPat = 0.5 + 0.5 * cos(TAU * p.x / SB_LAMPDX);
        float3 col = float3(0.22) * amb;
        col += sb_disp(0xffb070) * 0.11 * lampPat * (1.0 - 0.5 * smoothstep(0.0, 2.8, p.y));
        return col;
    }
    float3 wallCol = float3(b.albedo) * mix(float3(1.0), float3(1.0, 0.9, 0.82), b.h.y);
    float3 col = wallCol * amb;
    col += wallCol * sb_disp(0xffa050) * 0.07 * exp(-p.y / 28.0);      // street-light spill from below
    if (h.box == 2) return col;                                          // mechanical penthouse: blank
    float3 mn = h.box == 0 ? b.mn0 : b.mn1, mx = h.box == 0 ? b.mx0 : b.mx1;
    float u, faceW; int f;
    if (abs(n.x) > 0.5) { u = p.z - mn.z; faceW = mx.z - mn.z; f = n.x > 0.0 ? 0 : 1; }
    else                { u = p.x - mn.x; faceW = mx.x - mn.x; f = n.z > 0.0 ? 2 : 3; }
    float Htop = mx.y;
    float4 win = sb_windows(u, p.y, faceW, b, f, smear, Htop);
    float3 glass = float3(0.0025, 0.004, 0.008) * (0.5 + faceSun);
    col = mix(col, glass, win.a) + win.rgb;
    bool topBlock = (b.mx1.y > 0.0) ? (h.box == 1) : (h.box == 0);
    if (b.crown > 0.0 && topBlock && p.y > Htop - 2.0 * SB_FLOOR - 0.9) col += b.crownCol * 0.9;
    if (b.flood > 0.0) col += wallCol * b.floodCol * 2.2 * pow(max(1.0 - p.y / b.H, 0.0), 1.6) * (1.0 - 0.7 * win.a);
    return col;
}

inline float3 sb_aerial(float3 col, float3 ro, float3 rd, float dist) {
    float f = ws_fogAmount(dist, ro, rd, SB_HAZE, SB_HAZEK);
    return mix(col, sb_hazeCol(rd), f);
}

// quay lamps: tiny cores + lens halos (they stand in front of everything)
inline float3 sb_lamps(float3 ro, float3 rd) {
    if (rd.z < 0.3) return float3(0.0);
    float tz = (SB_ZSHORE - ro.z) / rd.z;
    float xh = ro.x + rd.x * tz;
    float i0 = floor((xh + 2100.0) / SB_LAMPDX);
    float3 acc = float3(0.0);
    for (int k = -4; k <= 4; k++) {
        float i = i0 + float(k);
        if (i < 0.0 || i > 200.0) continue;
        float4 r = hash24(float2(i, 3.3));
        float x = -2100.0 + SB_LAMPDX * i + 3.0 * (r.w - 0.5);
        float3 P = float3(x, 2.8 + 5.5, sb_shoreZ(x) - 2.0);
        float3 d = P - ro; float L = length(d); d /= L;
        float c = dot(d, rd);
        float th = sqrt(max(2.0 - 2.0 * c, 0.0));
        float sig = 0.00040;
        float core = exp(-th * th / (2.0 * sig * sig));
        float sg2 = sig * 4.0;
        float wing = 0.05 * sg2 * sg2 / (th * th + sg2 * sg2);
        float3 col = r.y > 0.85 ? ws_blackbody(5000.0) : mix(ws_blackbody(2300.0), ws_blackbody(3400.0), r.x);
        float I = 2.2 + 2.0 * r.z;
        float f = ws_fogAmount(L, ro, d, SB_HAZE, SB_HAZEK);
        acc += col * I * (core + wing) * (1.0 - 0.6 * f);
    }
    return acc;
}

// Radiance along a ray that is not looking into the water surface
// (city / sky / lamps). `water` is set when the ray misses everything downward.
inline float3 sb_radiance(float3 ro, float3 rd, float smear, thread bool &water) {
    water = false;
    SBHit h; float3 glow = float3(0.0);
    float3 col;
    if (sb_trace(ro, rd, h, glow)) {
        col = sb_shade(h, rd, smear);
        col = sb_aerial(col, ro, rd, h.t);
    } else if (rd.y < 0.0) {
        water = true; return float3(0.0);
    } else {
        col = sb_sky(rd);
    }
    col += glow + sb_lamps(ro, rd);
    return col;
}

// ------------------------------------------------------------ water
inline float sb_swellH(float2 q) {
    return 0.045 * gnoise(q * 0.09 + 3.1) + 0.022 * gnoise(WS_ROT2 * q * 0.31 + 7.0) + 0.010 * gnoise(q * 0.9 + 11.0);
}
inline float2 sb_swellGrad(float2 q, float dist) {
    float e = 0.05;
    float hx = sb_swellH(q + float2(e, 0.0)) - sb_swellH(q - float2(e, 0.0));
    float hz = sb_swellH(q + float2(0.0, e)) - sb_swellH(q - float2(0.0, e));
    return float2(hx, hz) / (2.0 * e) / (1.0 + dist / 500.0);
}

float3 scene(float2 fragCoord, WSCtx ctx) {
    float3 ro = float3(0.0, SB_CAMY, 0.0);
    float3 ta = ro + float3(0.0, tan(SB_PITCH * SB_DEG), 1.0);
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, ta, SB_FOVY);
    float2 uv = fragCoord / ctx.res;

    bool water;
    float3 col = sb_radiance(ro, rd, 0.0, water);
    if (water) {
        float t = -ro.y / rd.y;
        float3 p = ro + rd * t;
        float2 g = sb_swellGrad(p.xz, t);
        float2 rnd = hash22(fragCoord * 7.31 + float2(0.5, 0.25));
        float3 acc = float3(0.0);
        float Fsum = 0.0;
        for (int k = 0; k < SB_TAPS; k++) {
            float u1 = (float(k) + rnd.x) / float(SB_TAPS);
            float u2 = fract(rnd.y + float(k) * 0.618034);
            float r = SB_SLOPE * sqrt(-2.0 * log(max(1.0 - u1, 1e-4)));
            float2 s = r * float2(cos(TAU * u2), sin(TAU * u2)) * float2(0.85, 1.15);
            float3 n = normalize(float3(-g.x + s.x, 1.0, -g.y + s.y));
            float3 rr = reflect(rd, n);
            if (rr.y < 0.002) { rr.y = 0.002; rr = normalize(rr); }
            float cosT = max(dot(-rd, n), 0.0);
            float F = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
            bool w;
            acc += F * sb_radiance(p, rr, 1.0, w);
            Fsum += F;
        }
        acc /= float(SB_TAPS); Fsum /= float(SB_TAPS);
        float3 body = float3(0.004, 0.008, 0.013);
        col = body * (1.0 - Fsum) + acc;
        col = sb_aerial(col, ro, rd, t);
    }
    col *= ws_vignette(uv, 0.16);
    col = ws_acesFitted(col);
    col += ws_grain(fragCoord, ctx.t) * 0.004;
    return clamp(col, 0.0, 1.0);
}
