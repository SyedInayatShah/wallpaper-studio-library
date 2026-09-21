// =====================================================================
//  Emerald Lake — alpine glacial lake at early morning.
//  Units: metres. y up, camera looks toward +z. Lake surface at y = 0.
// =====================================================================

constant float EL_ALT  = 1885.0;          // lake altitude ASL (sky model)
constant float EL_HTOP = 2500.0;          // conservative terrain height bound
constant float3 EL_CAM = float3(-300.0, 22.0, -335.0);   // rockpile viewpoint at the near end, toward the left shore

inline float3 el_sunDir() {
    float el = 4.5 * PI / 180.0, az = -108.0 * PI / 180.0;   // az from +z toward +x (raking light from the left)
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

inline float el_smax(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
    return mix(b, a, h) + k * h * (1.0 - h);
}
inline float el_smin(float a, float b, float k) { return -el_smax(-a, -b, k); }
inline float el_sq(float x) { return x * x; }

// gradient noise with analytic derivatives (value, d/dx, d/dy)
inline float3 el_noised(float2 p) {
    float2 i = floor(p); float2 f = p - i;
    int2 c = int2(i);
    float2 u  = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float2 ga = ws_g2(c), gb = ws_g2(c + int2(1, 0));
    float2 gc = ws_g2(c + int2(0, 1)), gd = ws_g2(c + int2(1, 1));
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0));
    float vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - float2(1, 1));
    float k4 = va - vb - vc + vd;
    float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k4;
    float2 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
             + du * (u.yx * k4 + float2(vb, vc) - va);
    return float3(v, d) * 1.4142;
}

// ------------------------------------------------------------ layout
inline float el_cx(float z) { return -60.0 + 60.0 * sin(z * 0.0009 + 0.3) + 20.0 * sin(z * 0.0031 + 2.0); }
inline float el_hw(float z) {   // lake half width
    return 440.0 - 90.0 * smoothstep(0.0, 2600.0, z) + 50.0 * sin(z * 0.0019 + 1.4) + 25.0 * sin(z * 0.0052 + 0.3);
}

// signed distance-ish to the shoreline, positive on land
inline float el_shore(float2 p) {
    float s = abs(p.x - el_cx(p.y)) - el_hw(p.y);
    s = el_smax(s, p.y - 2600.0, 350.0);
    s = el_smax(s, -320.0 - p.y, 80.0);
    s += 30.0 * gnoise(p * 0.0035 + float2(1.7, 9.2)) + 9.0 * gnoise(p * 0.013 + float2(5.1, 3.3));
    return s;
}

// smooth large-scale landform: valley floor + side walls + back massif
inline float el_macro(float2 p, float s) {
    if (s < 0.0) {
        // glacial basin: a broad shallow shelf (rock-flour fan) along the shores and the
        // near end, dropping away into the deep basin -- this is what makes the emerald band
        float shelf = 1.0 - exp(s / 190.0);
        float basin = 1.0 - exp(s / 980.0);
        float bump  = 2.2 * gnoise(p * 0.0042 + float2(6.0, 2.0)) * (1.0 - basin);
        return -(17.0 * shelf + 33.0 * basin) + bump;
    }
    float x = p.x, z = p.y;
    float xc = x - el_cx(z);
    // side walls
    float lw = smoothstep(250.0, -250.0, xc);                 // 1 on the left side
    float sl = abs(xc) - mix(548.0, 470.0, lw) - 60.0 * sin(z * 0.0013);
    float slp = max(sl, 0.0);
    // right: gentle forested hills
    float qR = slp / 540.0;
    float wallR = 392.0 * (1.0 + 0.14 * sin(z * 0.0021 + 1.0) + 0.11 * gnoise(float2(z * 0.00085, 5.5)))
                * qR * qR / (1.0 + qR * qR);
    // a nearer forested spur pushing out from the right shore, for silhouette depth
    float spur = 118.0 * exp(-el_sq((z - 760.0) / 420.0)) * smoothstep(0.0, 260.0, slp);
    wallR += spur;
    // left: forested ~30 deg lower slope, then a cliff band up to the crest
    float cn = gnoise(float2(z * 0.0016, 3.7));
    float wallL = (560.0 + 70.0 * cn) * tanh(slp * 0.62 / 560.0) + 0.06 * max(slp - 1300.0, 0.0);
    float wall = mix(wallR, wallL, lw);
    // valley floor beyond the lake: low forested moraine hills
    float beyond = smoothstep(2450.0, 3300.0, z);
    float flo = 5.0 + 0.03 * max(z - 2500.0, 0.0)
              + beyond * 75.0 * (0.55 + 0.45 * gnoise(p * 0.0022 + float2(3.0, 8.0)));
    float land = flo + wall;
    // back massif: crest recedes to the right, focal summit left of centre
    float serr = 0.5 - 0.5 * cos(x * (TAU / 1150.0) + 0.4);          // 0 at peaks, 1 at cols
    float serrN = 0.65 + 0.35 * gnoise(float2(x * 0.0007, 2.5));
    float zc = 4650.0 + 0.42 * max(x + 200.0, 0.0) + 200.0 * sin(x * 0.0011 + 1.0) + 240.0 * serr * serrN;
    float Hpk = 1060.0 + 470.0 * exp(-el_sq((x + 380.0) / 720.0)) + 210.0 * exp(-el_sq((x + 1650.0) / 600.0))
              + 170.0 * exp(-el_sq((x - 950.0) / 520.0)) - 280.0 * smoothstep(900.0, 3200.0, x)
              - 230.0 * pow(serr, 1.4) * serrN;
    float dz = clamp(abs(z - zc) / 1900.0, 0.0, 1.0);
    float massif = Hpk * pow(1.0 - dz, 1.6);
    land = el_smax(land, massif, 180.0);
    // gentle shoreline ramp
    return land * (1.0 - exp(-s / 70.0)) + 0.08 * s * exp(-s / 250.0);
}

// eroded + ridged mountain detail (IQ-style derivative damping)
inline float el_detail(float2 x, int oct, float rough) {
    float2 p = x * 0.0012;
    float a = 0.0, b = 1.0;
    float2 d = float2(0.0);
    const float2x2 m = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));
    for (int i = 0; i < oct; i++) {
        float3 n = el_noised(p);
        d += n.yz;
        float damp = 1.0 / (1.0 + 0.5 * dot(d, d));
        float v = (i < 2) ? (0.5 - abs(n.x)) : n.x;
        if (i >= 4) {                       // fractured rock on steep mountain faces
            v = mix(v, 0.42 - abs(n.x), rough);
            damp = mix(damp, 1.0, rough * 0.85);
        }
        a += b * v * damp;
        b *= (i < 2) ? 0.5 : ((i < 6) ? 0.46 : 0.40);
        p = m * p;
    }
    return a;
}

inline float el_glacier(float2 p) {
    float2 d = (p - float2(-330.0, 3950.0)) / float2(620.0, 300.0);
    float r = length(d) + 0.18 * gnoise(p * 0.006 + float2(2.0, 2.0));
    return 1.0 - smoothstep(0.6, 1.0, r);
}

inline float el_heightS(float2 p, int oct, thread float &s) {
    s = el_shore(p);
    float hm = el_macro(p, s);
    float amp = 3.0 + 30.0 * smoothstep(10.0, 150.0, hm) + 440.0 * smoothstep(30.0, 1250.0, hm);
    float rough = smoothstep(250.0, 800.0, hm);
    float h = hm + amp * el_detail(p, oct, rough);
    // sedimentary strata: tilted, warped terraces (cliff bands + ledges)
    float w = smoothstep(350.0, 800.0, hm) * smoothstep(-0.35, 0.25, gnoise(p * 0.0016 + float2(7.0, 3.0)));
    if (w > 0.0) {
        float hs = (h + 0.10 * p.x - 0.04 * p.y + 30.0 * gnoise(p * 0.0021 + float2(4.0, 2.0))
                    + 9.0 * gnoise(p * 0.009 + float2(1.0, 6.0))) / 30.0;
        hs += 0.45 * gnoise(float2(hs * 0.55, 0.5));   // uneven layer thickness
        float fl = floor(hs), fr = hs - fl;
        float ls = hash11(fl * 0.7310 + 0.1);          // per-layer cliff-band strength
        h += w * 0.5 * 30.0 * ls * ls * (smoothstep(0.05, 0.95, fr) - fr);
    }
    return h;
}
inline float el_height(float2 p, int oct) { float s; return el_heightS(p, oct, s); }

// octave count from ray distance and pixel angle
inline int el_lod(float t, float pa, float bias) {
    return clamp(int(log2(420.0 / max(t * pa, 1e-3)) - bias), 3, 11);
}

// ------------------------------------------------------------ forest
inline float el_forestMask(float2 p, float s, float h) {
    float n = gnoise(p * 0.0028 + float2(3.1, 7.7)) + 0.5 * gnoise(p * 0.009 + float2(1.0, 2.0));
    float tl = 330.0 + 90.0 * gnoise(p * 0.0017 + float2(8.0, 1.0)) + 45.0 * gnoise(p * 0.007 + float2(2.0, 9.0));
    tl += 205.0 * smoothstep(150.0, 700.0, p.x - el_cx(p.y));   // sheltered, forested right-shore hills
    float m = smoothstep(-0.7 + 0.35 * smoothstep(60.0, 200.0, h), -0.1, n);
    m *= smoothstep(3.0, 12.0, s) * (1.0 - smoothstep(tl - 80.0, tl + 15.0, h));
    // avalanche paths down the steep left valley wall (fall line ~ +x)
    float xc = p.x - el_cx(p.y);
    float lw = smoothstep(-300.0, -700.0, xc);
    float av = abs(gnoise(float2(p.x * 0.0011, p.y * 0.0105) + float2(4.0, 0.0)));
    float avp = (1.0 - smoothstep(0.05, 0.12, av)) * smoothstep(-0.2, 0.3, gnoise(float2(p.y * 0.002, 1.5)));
    m *= 1.0 - lw * avp * smoothstep(40.0, 120.0, h);
    m *= smoothstep(70.0, 110.0, length(p - EL_CAM.xz));       // bare moraine around the viewpoint
    return m;
}

inline float2 el_macroGrad(float2 p) {
    float e = 4.0;
    float h0 = el_macro(p, el_shore(p));
    float2 px = p + float2(e, 0.0), pz = p + float2(0.0, e);
    return float2(el_macro(px, el_shore(px)) - h0, el_macro(pz, el_shore(pz)) - h0) / e;
}

// conifer SDF near p. ground: terrain height at p, g: ground gradient
inline float el_trees(float3 p, float ground, float2 g, float dens, float grove, thread float4 &info) {
    const float C = 6.0;
    float2 cell = floor(p.xz / C);
    float dmin = 1e5;
    info = float4(0.0);
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        float2 id = cell + float2(i, j);
        float4 h = hash24(id + float2(31.0, 17.0));
        if (h.z > dens) continue;
        float2 c = (id + 0.5 + (h.xy - 0.5) * 0.92) * C;
        float base = ground + dot(g, c - p.xz);
        float stand = 0.82 + 0.38 * hash11(dot(floor(id / 6.0), float2(1.0, 37.0)) * 0.1131 + 5.3);
        float H = (11.0 + 21.0 * fract(h.w * 13.7)) * grove * stand * (1.0 - 0.45 * smoothstep(180.0, 420.0, base));
        float3 q = p - float3(c.x, base - 0.5, c.y);
        q.xz -= (float2(fract(h.w * 71.3), fract(h.w * 37.9)) - 0.5) * 0.06 * q.y;   // slight lean
        float y = q.y;
        float hn = clamp(y / H, 0.0, 1.0);
        float r = length(q.xz);
        float Rb = H * (0.11 + 0.07 * h.x);
        float prof = pow(1.0 - hn, 0.8 + 0.3 * h.y);
        // drooping branch whorls: widest at the bottom of each tier
        float wy = y * (1.05 + 0.4 * h.y) + h.z * 13.0;
        float wi = floor(wy), wf = wy - wi;
        float tierR = 0.58 + 0.42 * pow(1.0 - wf, 0.7);
        float ang = atan2(q.z, q.x);
        float irr = 0.82 + 0.10 * sin(ang * 5.0 + wi * 2.3 + h.w * 30.0) + 0.08 * sin(ang * 3.0 - wi * 1.7);
        float R = Rb * prof * tierR * irr;
        float d = (r - R) * 0.55;
        d = max(d, y - H);
        if (d < dmin) { dmin = d; info = float4(hn, r / max(Rb * prof, 0.05), h.w, wf); }
    }
    return dmin;
}

// full scene distance: mat 1 terrain, 2 tree
inline float el_map(float3 p, int oct, thread int &mat, thread float4 &tinfo) {
    float s;
    float h = el_heightS(p.xz, oct, s);
    float dy = p.y - h;
    float d = dy * 0.45;
    mat = 1;
    if (dy < 36.0 && h > -2.0 && h < 480.0 && s > 2.0) {
        float fm = el_forestMask(p.xz, s, h);
        if (fm > 0.02) {
            float2 g = el_macroGrad(p.xz);
            fm *= 1.0 - smoothstep(0.8, 1.2, length(g));
            if (fm > 0.02) {
                float4 inf;
                // stand-scale height variation: dense mature groves vs thin stunted edges
                float dt = el_trees(p, h, g, fm, 0.74 + 0.58 * fm, inf);
                if (dt < d) { d = dt; mat = 2; tinfo = inf; }
            }
        }
    }
    return d;
}

inline float el_march(float3 ro, float3 rd, float tmin, float tmax, int steps, float pa, float lodBias,
                      thread int &mat, thread float4 &tinfo) {
    float t = tmin;
    float tPrev = t, dPrev = 1e5;
    mat = 0;
    int lastM = 1; float4 lastTi = float4(0.0);
    for (int i = 0; i < steps; i++) {
        float3 p = ro + rd * t;
        if (p.y > EL_HTOP && rd.y > 0.0) { mat = 0; return tmax; }
        int m; float4 ti;
        float d = el_map(p, el_lod(t, pa, lodBias), m, ti);
        if (d < 0.0 && m == 1) {
            float tt = tPrev + (t - tPrev) * dPrev / max(dPrev - d, 1e-4);
            mat = 1; tinfo = ti;
            return tt;
        }
        if (d < 0.35 * pa * t) { mat = m; tinfo = ti; return t; }
        lastM = m; lastTi = ti;
        tPrev = t; dPrev = d;
        t += max(d, 0.02 + 0.3 * pa * t);
        if (t > tmax) { mat = 0; return tmax; }
    }
    // ran out of steps while still skimming the surface: treat as a hit
    mat = lastM; tinfo = lastTi;
    return t;
}

// ------------------------------------------------------------ gully erosion (shading only)
// Directional stripe noise aligned down the slope (after C. John's erosion noise).
inline float3 el_ero(float2 p, float2 dir) {
    float2 ip = floor(p); float2 fp = p - ip;
    float3 va = float3(0.0);
    float wt = 0.0;
    for (int j = -2; j <= 1; j++)
    for (int i = -2; i <= 1; i++) {
        float2 o = float2(i, j);
        float2 h = hash22(ip - o) * 0.5;
        float2 pp = fp + o - h;
        float w = exp(-2.0 * dot(pp, pp));
        wt += w;
        float mag = dot(pp, dir);
        va += float3(cos(mag * TAU), -sin(mag * TAU) * dir) * w;
    }
    return va / wt;
}
// g: base terrain gradient (dh/dx, dh/dz). Returns height offset (m) and gully value in .y
inline float2 el_erosionH(float2 p, float2 g, int oct) {
    float2 dir = float2(g.y, -g.x) / max(length(g), 1e-3) * 0.9;
    float3 h = float3(0.0);
    float a = 1.0, f = 1.0;
    float2 q = p / 150.0;
    for (int i = 0; i < oct; i++) {
        h += el_ero(q * f, dir + h.zy * float2(1.0, -1.0) * 0.6) * a * float3(1.0, f, f);
        a *= 0.5; f *= 2.1;
    }
    return float2(h.x, h.x);
}

inline float3 el_terrainNormal(float2 p, float t, float pa) {
    int oct = el_lod(t, pa, -1.0);
    float e = max(0.05, 0.7 * pa * t);
    float h0 = el_height(p, oct);
    float hx = el_height(p + float2(e, 0.0), oct);
    float hz = el_height(p + float2(0.0, e), oct);
    return normalize(float3(h0 - hx, e, h0 - hz));
}

// normal at an explicit metre scale e (ledge-scale snow decisions, independent of resolution)
inline float3 el_normalAt(float2 p, float e) {
    int oct = clamp(int(log2(420.0 / e)), 3, 11);
    float h0 = el_height(p, oct);
    float hx = el_height(p + float2(e, 0.0), oct);
    float hz = el_height(p + float2(0.0, e), oct);
    return normalize(float3(h0 - hx, e, h0 - hz));
}

inline float3 el_treeNormal(float3 p, float t, float pa) {
    float e = max(0.03, 0.6 * pa * t);
    const float2 k = float2(1.0, -1.0);
    int m; float4 ti;
    int oct = el_lod(t, pa, 1.0);
    return normalize(k.xyy * el_map(p + k.xyy * e, oct, m, ti) +
                     k.yyx * el_map(p + k.yyx * e, oct, m, ti) +
                     k.yxy * el_map(p + k.yxy * e, oct, m, ti) +
                     k.xxx * el_map(p + k.xxx * e, oct, m, ti));
}

inline float el_shadow(float3 p, float3 l, float tHit, float pa) {
    float res = 1.0;
    float t = 1.0 + 0.5 * pa * tHit;
    for (int i = 0; i < 72; i++) {
        float3 q = p + l * t;
        if (q.y > EL_HTOP) break;
        float h = q.y - el_height(q.xz, el_lod(tHit + t * 4.0, pa, 0.5));
        res = min(res, 12.0 * h / t);
        if (res < -0.1) break;
        t += clamp(h * 0.5, 1.0 + t * 0.01, 300.0);
    }
    return smoothstep(0.0, 1.0, res);
}

inline float el_ao(float3 p, float3 n) {
    float occ = 0.0, w = 0.0;
    for (int i = 0; i < 5; i++) {
        float hr = 3.0 * pow(3.0, float(i));
        float3 q = p + n * hr;
        float d = q.y - el_height(q.xz, 5);
        float wi = 1.0 / (1.0 + float(i) * 0.5);
        occ += clamp((hr - d * 0.8) / hr, 0.0, 1.0) * wi;
        w += wi;
    }
    return clamp(1.0 - occ / w, 0.0, 1.0);
}

// ------------------------------------------------------------ sky
inline float3 el_sunTrans(float3 sunDir) {
    const float Rp = 6371e3, Ra = 6471e3;
    float3 r0 = float3(0.0, Rp + EL_ALT, 0.0);
    float L = ws_raySphere(r0, sunDir, Ra).y;
    float st = L / 16.0, odR = 0.0, odM = 0.0;
    for (int i = 0; i < 16; i++) {
        float3 q = r0 + sunDir * (st * (float(i) + 0.5));
        float hh = length(q) - Rp;
        odR += exp(-hh / 8e3) * st;
        odM += exp(-hh / 1.2e3) * st;
    }
    return exp(-(float3(5.5e-6, 13.0e-6, 22.4e-6) * odR + 21e-6 * odM));
}

// thin high cirrus: silky strands inside soft envelopes (2D layer)
inline float el_cloudDens(float2 uv) {
    float2 q = uv * 0.00011;
    float2 wd = normalize(float2(1.0, 0.40));
    float2 r = float2(dot(q, wd), dot(q, float2(-wd.y, wd.x)));
    float2 w = float2(fbm(r * 0.9 + float2(4.0, 1.0), 3), fbm(r * 0.9 + float2(9.0, 5.0), 3));
    r += w * float2(0.5, 0.35);                                    // gentle curvature
    float env = smoothstep(0.02, 0.45, fbm(r * float2(0.7, 1.6) + float2(2.0, 7.0), 4));
    float strand = fbm(float2(r.x * 1.6, r.y * 16.0) + float2(1.0, 3.0), 5);
    float fine = fbm(float2(r.x * 4.0, r.y * 45.0) + float2(7.0, 2.0), 3);
    float d = env * smoothstep(-0.15, 0.45, strand + 0.25 * fine);
    return d;
}

struct ELLight { float3 sun; float3 sunE; float3 skyUp; float3 skyHz; float3 skyAmb; float3 skySun; float3 sunH; };

// sky irradiance / PI for a surface with normal n (includes a multiple-scattering boost)
inline float3 el_skyLight(float3 n, ELLight L) {
    return L.skyAmb * (0.55 + 0.45 * n.y) + L.skySun * 0.42 * max(dot(n, L.sunH), 0.0);
}

inline float3 el_skyBase(float3 rd, float3 sun) {
    float3 r = rd;
    r.y = max(r.y, 0.004);
    return ws_atmosphere(normalize(r), sun, 22.0, 0.76, 1.0, EL_ALT);
}

// volumetric altocumulus field hanging behind the massif (kept out of the top-right)
inline float el_cloudVol(float3 p) {
    float h01 = (p.y - 2150.0) / 380.0;
    if (h01 <= 0.0 || h01 >= 1.0) return 0.0;
    float region = smoothstep(0.30, -0.05, p.x / max(p.z, 1.0)) * smoothstep(5000.0, 7000.0, p.z);
    if (region <= 0.0) return 0.0;
    float cov = fbm(p.xz * float2(0.00030, 0.00055) + float2(3.0, 11.0), 3);
    float prof = smoothstep(0.0, 0.25, h01) * (1.0 - smoothstep(0.35, 1.0, h01));
    float n = fbm(p * float3(0.0016, 0.003, 0.0016) + float3(1.7, 0.0, 4.2), 7);
    float d = (cov + 0.45 * n - 0.02) * prof - 0.14 - 0.25 * (1.0 - prof);
    d -= 0.07 * (0.5 + 0.5 * gnoise(p * 0.012)) + 0.04 * abs(gnoise(p * 0.03 + 5.0));   // wispy eroded edges
    return clamp(d * 5.5, 0.0, 1.0) * region;
}

inline float el_hg(float mu, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(1.0 + gg - 2.0 * g * mu, 1.5));
}

inline float3 el_sky(float3 rd, ELLight L, float jit) {
    float3 col = el_skyBase(rd, L.sun);
    if (rd.y > 0.03) {
        float t0 = 2150.0 / rd.y, t1 = min(2530.0 / rd.y, t0 + 9000.0);
        const int NS = 26;
        float dt = (t1 - t0) / float(NS);
        float T = 1.0;
        float3 S = float3(0.0);
        float mu = dot(rd, L.sun);
        float ph = mix(el_hg(mu, 0.6), el_hg(mu, -0.25), 0.4) * 4.0 * PI;   // relative to isotropic
        float3 sunC = L.sunE * float3(1.0, 1.02, 1.1);
        for (int i = 0; i < NS; i++) {
            float3 p = rd * (t0 + dt * (float(i) + jit));
            float d = el_cloudVol(p);
            if (d > 0.005) {
                float sig = d * 0.0045;
                float od = 0.0;
                od += el_cloudVol(p + L.sun * 90.0) * 90.0;
                od += el_cloudVol(p + L.sun * 280.0) * 190.0;
                od += el_cloudVol(p + L.sun * 650.0) * 370.0;
                float Tl = exp(-od * 0.0036);
                float powder = 1.0 - exp(-sig * 400.0);
                float h01 = (p.y - 2150.0) / 380.0;
                float3 Lin = sunC * (ph * Tl * (0.30 + 0.70 * powder)) / PI * 0.85 + L.skyAmb * (0.30 + 0.35 * h01);
                float a = 1.0 - exp(-sig * dt);
                S += T * a * Lin;
                T *= 1.0 - a;
                if (T < 0.02) break;
            }
        }
        float fade = smoothstep(0.03, 0.08, rd.y);
        col = mix(col, col * T + S, fade);
    }
    // alpine haze layer: thickest at the horizon, thinning through the ridgeline band,
    // warmer where it looks toward the lit side of the valley
    {
        float3 h = normalize(float3(rd.x, 0.0, rd.z) + 1e-5);
        float band = exp(-max(rd.y, 0.0) / 0.072) * (0.55 + 0.45 * smoothstep(-0.02, 0.12, rd.y));
        float tex = 0.72 + 0.56 * fbm(float2(h.x * 2.6 + rd.y * 1.4, h.z * 2.1 - rd.y * 5.5) + float2(3.0, 8.0), 3);
        float warm = 0.30 + 0.70 * max(dot(h, L.sunH), 0.0);
        float3 hazeC = mix(L.skyAmb * 1.30, L.skySun * 0.46 + L.sunE * 0.0032, warm);
        col = mix(col, hazeC, clamp(0.40 * band * tex, 0.0, 0.62));
        // very slight low-frequency luminance drift so the gradient is not machine-clean
        col *= 1.0 + 0.022 * gnoise(float2(h.x * 3.1, rd.y * 9.0) + float2(5.0, 2.0));
    }
    return col;
}

// ------------------------------------------------------------ shading
// normal including gully erosion; returns gully value (neg = channel)
inline float3 el_terrainNormalE(float2 p, float t, float pa, thread float &gully) {
    int oct = el_lod(t, pa, -1.0);
    float e = max(0.05, 0.7 * pa * t);
    // base gradient for gully direction
    float E = 12.0;
    float b0 = el_height(p, 5);
    float2 g = float2(el_height(p + float2(E, 0.0), 5) - b0, el_height(p + float2(0.0, E), 5) - b0) / E;
    float slope = length(g);
    float s = el_shore(p);
    float hm = el_macro(p, s);
    float var = smoothstep(-0.5, 0.6, gnoise(p * 0.0012 + float2(5.0, 1.0)));
    float str = (6.0 + 22.0 * smoothstep(150.0, 700.0, hm)) * smoothstep(0.3, 0.9, slope) * (0.25 + 0.75 * var);
    int eo = clamp(int(log2(150.0 / max(pa * t, 0.01))), 1, 3);
    float2 e0 = el_erosionH(p, g, eo);
    float h0 = el_height(p, oct) + str * e0.x;
    float hx = el_height(p + float2(e, 0.0), oct) + str * el_erosionH(p + float2(e, 0.0), g, eo).x;
    float hz = el_height(p + float2(0.0, e), oct) + str * el_erosionH(p + float2(0.0, e), g, eo).x;
    gully = e0.y * smoothstep(0.25, 0.8, slope);
    return normalize(float3(h0 - hx, e, h0 - hz));
}

inline float3 el_shadeTerrain(float3 p, float3 rd, float t, float pa, ELLight L, thread float &shOut) {
    float gully;
    float3 n = el_terrainNormalE(p.xz, t, pa, gully);
    float2 mg = el_macroGrad(p.xz);
    float3 nm = normalize(float3(-mg.x, 1.0, -mg.y));
    float sh = el_shadow(p + n * max(0.3, pa * t), L.sun, t, pa);
    shOut = sh;
    float ao = el_ao(p, n);
    float s = el_shore(p.xz);

    float n1 = gnoise(p.xz * 0.013);
    float n2 = gnoise(p.xz * 0.11);
    float n3 = gnoise(p * 0.35);
    float hsid = (p.y + 0.10 * p.x - 0.04 * p.z + 30.0 * gnoise(p.xz * 0.0021 + float2(4.0, 2.0))
                  + 9.0 * gnoise(p.xz * 0.009 + float2(1.0, 6.0))) / 30.0;
    hsid += 0.45 * gnoise(float2(hsid * 0.55, 0.5));
    float lay = mix(hash11(floor(hsid * 2.0) * 0.5 + 0.37), 0.5 + 0.5 * gnoise(p.xz * 0.004 + float2(3.0, 1.0)), 0.45);
    float strataVis = smoothstep(300.0, 700.0, p.y) * (0.5 + 0.5 * smoothstep(-0.3, 0.3, gnoise(p.xz * 0.0015 + float2(9.0, 4.0))));
    lay = mix(0.5, lay, strataVis);
    float hue = smoothstep(-0.4, 0.5, gnoise(p.xz * 0.0009 + float2(1.0, 8.0)) + 0.3 * gnoise(p.xz * 0.004));
    float3 rock = mix(float3(0.125, 0.115, 0.105), float3(0.20, 0.182, 0.162), lay);
    rock *= mix(float3(0.92, 0.96, 1.04), float3(1.08, 0.99, 0.88), hue);     // grey limestone vs brown quartzite
    rock = mix(rock, float3(0.27, 0.245, 0.21), smoothstep(0.85, 0.98, lay) * strataVis);
    // domain-warped, multi-frequency weathering streaks (no regular vertical comb)
    float2 sw = float2(gnoise(p.xz * 0.023 + float2(3.3, 7.9)), gnoise(p.xz * 0.0075 + float2(8.1, 1.2)));
    float streak = gnoise(float2((p.x + p.z) * 0.052 + 11.0 * sw.x, p.y * 0.0042 + 46.0 * sw.y))
                 + 0.55 * gnoise(float2((p.x - 0.6 * p.z) * 0.017 + 5.0 * sw.y, p.y * 0.0013 + 3.0))
                 + 0.32 * gnoise(float2((p.x + 1.7 * p.z) * 0.135 + 2.0 * sw.x, p.y * 0.011));
    streak *= 0.62;
    float blotch = gnoise(p.xz * 0.0055 + float2(6.4, 2.8)) + 0.5 * gnoise(p.xz * 0.019 + float2(1.9, 5.5));
    rock *= (0.8 + 0.4 * (0.5 + 0.5 * n3)) * (0.88 + 0.24 * n1) * (0.85 + 0.25 * streak)
          * (0.90 + 0.16 * blotch);
    rock = mix(rock, float3(0.21, 0.205, 0.195), smoothstep(0.6, 0.85, n.y) * 0.5); // scree
    float fm = el_forestMask(p.xz, s, p.y) * (1.0 - smoothstep(0.75, 1.15, length(mg))) * smoothstep(0.55, 0.75, n.y);
    float low = (1.0 - smoothstep(250.0, 560.0, p.y + 90.0 * n1)) * smoothstep(0.62, 0.82, n.y);
    float3 meadow = mix(float3(0.070, 0.072, 0.042), float3(0.105, 0.092, 0.058), 0.5 + 0.5 * n2) * (0.8 + 0.4 * n3);
    float scree = smoothstep(0.55, 0.72, n.y) * (1.0 - smoothstep(0.78, 0.9, n.y)) * smoothstep(-0.2, 0.4, gnoise(p.xz * 0.02 + 3.0));
    rock = mix(rock, float3(0.19, 0.185, 0.175) * (0.9 + 0.2 * n2), scree * 0.7);
    rock = mix(rock, meadow, low);
    float crown = vnoise(p.xz / 3.2) * 0.6 + vnoise(p.xz / 1.4) * 0.4;
    float3 alb = mix(rock, float3(0.046, 0.075, 0.048) * (0.5 + 1.0 * crown), fm * 0.95);
    alb = mix(alb, float3(0.20, 0.19, 0.17) * (0.8 + 0.4 * n2), (1.0 - smoothstep(0.0, 3.0, s)) * step(-0.5, p.y));
    // snow: ledges and gentler slopes (decided at ~5 m scale), couloirs, scoured off micro-cliffs
    float eS = clamp(0.7 * pa * t * 1.5, 3.0, 12.0);
    float3 ns = el_normalAt(p.xz, eS);
    float snowH = smoothstep(480.0, 820.0, p.y + 110.0 * n1);
    float high = smoothstep(950.0, 1500.0, p.y);
    float thr = mix(0.84, 0.66, high) - 0.045 * gnoise(p.xz * 0.0026 + float2(2.4, 6.1));
    // wide, noise-broken transition: partial cover melting back off the rock, not a painted mask
    float sv = ns.y + 0.055 * n1 + 0.030 * n2 + 0.022 * gnoise(p.xz * 0.045 + float2(4.0, 9.0));
    float snow = smoothstep(thr - 0.135, thr + 0.115, sv) * snowH;
    float couloir = smoothstep(0.10, 0.40, -gully) * smoothstep(0.34, 0.66, ns.y) * snowH;
    snow = max(snow, couloir * 0.85);
    snow *= smoothstep(0.10, 0.40, n.y);
    // drifted snow is bright and slightly warm on the crowns, blue-shadowed where it sits
    // in hollows and on steeper, more occluded faces
    float drift = smoothstep(0.55, 0.95, ns.y) * (0.6 + 0.4 * ao);
    float3 snowCol = mix(float3(0.600, 0.660, 0.780), float3(0.855, 0.875, 0.905), drift)
                   * (0.90 + 0.10 * n2) * (0.88 + 0.18 * ao);
    alb = mix(alb, snowCol, snow);

    float dif = max(dot(n, L.sun), 0.0);
    // cavity term: where the fine normal departs from the ledge-scale one the rock is
    // broken and self-shadows the skylight -- this is what keeps the shaded faces modelled
    float cav = clamp(dot(n, ns), 0.0, 1.0);
    float meso = mix(0.66, 1.10, smoothstep(0.55, 0.985, cav));
    meso = mix(1.0, meso, smoothstep(180.0, 420.0, p.y));
    float3 col = alb * (L.sunE * dif * sh / PI);
    col += alb * el_skyLight(n, L) * ao * meso;
    col += alb * float3(0.30, 0.27, 0.22) * L.skyAmb * 0.25 * (0.5 - 0.5 * n.y) * ao;   // ground bounce
    // green light kicked back up off the lake onto the shaded shoreline slopes
    float lakeB = exp(-max(p.y, 0.0) / 88.0) * (0.25 + 0.75 * (1.0 - n.y));
    col += alb * float3(0.105, 0.345, 0.300) * 1.30 * lakeB * ao;
    return col;
}

inline float3 el_shadeTree(float3 p, float3 rd, float t, float pa, float4 ti, ELLight L, thread float &shOut) {
    float3 n = el_treeNormal(p, t, pa);
    float sh = el_shadow(p + float3(0.0, 2.0, 0.0), L.sun, t, pa);
    shOut = sh;
    float hn = ti.x;
    float radial = clamp(ti.y, 0.0, 1.2);
    float occ = (0.5 + 0.5 * smoothstep(0.45, 1.0, radial)) * (0.6 + 0.4 * hn) * (0.75 + 0.25 * (1.0 - ti.w));
    // species / age variation: some lighter yellow-green trees, a few grey dead snags
    float v = fract(ti.z * 7.3);
    float3 alb = mix(float3(0.052, 0.088, 0.055), float3(0.085, 0.105, 0.048), smoothstep(0.5, 0.9, v));
    alb = mix(alb, float3(0.075, 0.072, 0.066), smoothstep(0.96, 0.985, v));
    alb *= 0.85 + 0.3 * fract(ti.z * 3.1);
    float dif = max(dot(n, L.sun), 0.0);
    float3 col = alb * L.sunE * dif * sh * occ / PI;
    col += alb * el_skyLight(n, L) * occ;
    // needle sheen: grazing sky reflection on the outer crown
    float fr = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), 4.0);
    col += L.skyAmb * 0.035 * fr * occ * (0.5 + 0.5 * n.y);
    // lake bounce on the shoreline conifers
    float lakeB = exp(-max(p.y, 0.0) / 78.0) * (0.3 + 0.7 * (1.0 - n.y));
    col += alb * float3(0.105, 0.345, 0.300) * 1.45 * lakeB * occ;
    // open sky seen between the ranks lifts the upper crowns a little
    col += alb * L.skyAmb * 0.55 * smoothstep(0.35, 0.95, hn) * (0.4 + 0.6 * n.y);
    return col;
}

// aerial perspective
inline float3 el_fog(float3 col, float t, float3 ro, float3 rd, ELLight L, float sh) {
    // in-scatter is weaker (and bluer) when the air near the target is in shadow
    float3 hz = el_skyBase(normalize(float3(rd.x, 0.03, rd.z)), L.sun)
              * mix(float3(0.55, 0.62, 0.75), float3(1.16, 1.09, 0.99), sh);
    float3 beta = float3(5.8e-6, 13.5e-6, 33.1e-6) * 1.3 + 8e-6;
    float hf = ws_fogAmount(t, ro, rd, 8.2e-5, 1.0 / 185.0);
    float3 ext = exp(-beta * t) * (1.0 - hf);
    return col * ext + hz * 0.85 * (1.0 - ext);
}

// ------------------------------------------------------------ water
// returns normal; ruffle in .w-ish via out param: 0 glassy .. 1 wind-ruffled
inline float el_windPatch(float2 p) {
    float2 wp = p * float2(0.0016, 0.0062);
    float wind = fbm(wp + float2(1.3, 4.1), 3) + 0.45 * fbm(wp * 2.7 + float2(7.0, 2.0), 2);
    wind = smoothstep(0.16, 0.56, wind);
    float calmShore = smoothstep(0.0, 90.0, -el_shore(p));
    return max(0.075, wind * (0.25 + 0.75 * calmShore));
}
// one swell train: its own heading, anisotropy and phase, sampled in a warped domain.
// the gradient is rotated back to world so the slopes stay coherent across trains.
inline float2 el_swell(float2 p, float2 warp, float2 sc, float ang, float2 off) {
    float c = cos(ang), sn = sin(ang);
    float2 r = float2(c * p.x - sn * p.y, sn * p.x + c * p.y) + warp;
    float2 d = el_noised(r * sc + off).yz;
    return float2(c * d.x + sn * d.y, -sn * d.x + c * d.y);
}
inline float3 el_waterNormal(float2 p, float t, float grazing, float pa, float ruffle) {
    float footX = pa * t;
    float footZ = pa * t / max(grazing, 0.01);
    float2 g = float2(0.0);
    // low-frequency domain warp: destroys the regular lattice the gradient-noise cells
    // would otherwise print across the reflection as a comb pattern
    float2 wrp = float2(gnoise(p * float2(0.0026, 0.0061) + float2(11.3, 3.4)),
                        gnoise(p * float2(0.0023, 0.0055) + float2(2.6, 17.1)));
    // long gentle swell (glassy regime): barely visible waviness
    {
        // each train washes out once the pixel footprint exceeds its wavelength
        float f0 = 1.0 - smoothstep(16.0, 62.0, footZ);
        float f1 = 1.0 - smoothstep(6.0, 22.0, footZ);
        float f2 = 1.0 - smoothstep(2.2, 8.0, footZ);
        if (f0 > 0.002) g += 0.00195 * el_swell(p, wrp * 44.0, float2(0.0084, 0.0213), -0.31, float2(3.0, 1.0)) * float2(0.78, 1.0) * f0;
        if (f1 > 0.002) g += 0.00125 * el_swell(p, wrp * 19.0, float2(0.0310, 0.0545), 0.47, float2(9.0, 4.0)) * float2(0.72, 1.0) * f1;
        if (f2 > 0.002) g += 0.00080 * el_swell(p, wrp * 7.0,  float2(0.0590, 0.1810), -0.88, float2(5.0, 8.0)) * float2(0.66, 1.0) * f2;
        // a fourth, very shallow train crossing the others at a wide angle breaks any
        // residual corrugation into irregular chop
        if (f1 > 0.002) g += 0.00075 * el_swell(p, wrp * 12.0, float2(0.0175, 0.0905), 1.24, float2(13.0, 6.0)) * float2(0.55, 1.0) * f1;
    }
    // wind ripples (matte regime) -- irrational lacunarity + rotating frame, no repeats
    float2 q = p * float2(0.25, 1.0) / 6.0;
    float wl = 6.0;
    const float2x2 R = float2x2(float2(0.873, 0.488), float2(-0.488, 0.873));
    for (int i = 0; i < 6; i++) {
        float amp = 0.010 * ruffle * (0.78 + 0.44 * fract(float(i) * 0.6180339));
        float fz = 1.0 - smoothstep(0.6 * wl, 2.4 * wl, footZ);
        float fx = 1.0 - smoothstep(0.6 * wl, 2.4 * wl, footX * 4.0);
        float3 nd = el_noised(q);
        g += amp * nd.yz * float2(0.35 * fx, fz) * 0.7;
        q = R * q * 1.873 + float2(4.7, 2.3);
        wl /= 1.873;
    }
    return normalize(float3(-g.x, 1.0, -g.y));
}

// ------------------------------------------------------------ mist
inline float3 el_mist(float3 col, float3 ro, float3 rd, float tEnd, float jit, ELLight L) {
    const float MH = 40.0;
    float t1 = min(tEnd, 3000.0);
    if (rd.y > 0.0) t1 = min(t1, max((MH - ro.y) / rd.y, 0.0));
    if (t1 <= 0.0) return col;
    const int NS = 30;
    float Tm = 1.0;
    float3 acc = float3(0.0);
    // shaded valley mist is sky-lit and cool; the far end picks up a little warm bounce
    float3 mistCol = L.skyAmb * 1.18 + L.skySun * 0.10 * max(dot(rd, L.sunH), 0.0);
    for (int i = 0; i < NS; i++) {
        // denser samples near the camera (power-law spacing), jittered
        float u0 = float(i) / float(NS), u1 = float(i + 1) / float(NS);
        float ta = t1 * pow(u0, 1.7), tb = t1 * pow(u1, 1.7);
        float tt = mix(ta, tb, jit);
        float dt = tb - ta;
        float3 q = ro + rd * tt;
        if (q.y > MH) continue;
        // low-lying banks: large soft patches, thinning toward the far end of the lake
        float bank = fbm(q.xz * float2(0.0022, 0.0055) + float2(6.0, 1.0), 3);
        float wisp = gnoise(float3(q.x * 0.012, q.y * 0.06, q.z * 0.03) + float3(2.0, 0.0, 5.0));
        float m = smoothstep(0.04, 0.64, bank + 0.3 * wisp
                  + 0.22 * gnoise(float3(q.x * 0.0055, 0.0, q.z * 0.0018) + float3(8.0, 0.0, 2.0)));
        float far = 1.0 - 0.7 * smoothstep(1200.0, 2600.0, q.z);
        float den = 0.0052 * exp(-max(q.y, 0.0) / 10.0) * m * far;
        // drifting wisps standing a little higher off the water, in patches
        float wp = smoothstep(0.25, 0.65, fbm(q.xz * float2(0.004, 0.011) + float2(2.0, 9.0), 3));
        float wisp2 = smoothstep(0.0, 0.6, gnoise(float3(q.x * 0.02, q.y * 0.09, q.z * 0.05) + float3(7.0, 1.0, 3.0)));
        den += 0.0038 * exp(-max(q.y - 4.0, 0.0) / 17.0) * wp * wisp2 * smoothstep(120.0, 450.0, q.z);
        float a = 1.0 - exp(-den * dt);
        acc += Tm * a * mistCol;
        Tm *= 1.0 - a;
    }
    return col * Tm + acc;
}

// ------------------------------------------------------------ camera (screen-right = +x)
inline float3 el_camRay(float2 fragCoord, float2 res, float3 ro, float3 ta, float fovYDeg) {
    float3 f = normalize(ta - ro);
    float3 r = normalize(cross(float3(0.0, 1.0, 0.0), f));
    float3 u = cross(f, r);
    float2 p = (2.0 * fragCoord - res) / res.y;
    float k = tan(fovYDeg * (PI / 180.0) * 0.5);
    return normalize(f + (p.x * r + p.y * u) * k);
}

// ------------------------------------------------------------ main
#ifndef EL_MAP
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 res = ctx.res;
#ifdef EL_ZOOM   // 1:1 crop of a virtual full-size frame: float4(cx, cy (0..1 from top-left), fullW, fullH)
    {
        float4 Z = EL_ZOOM;
        fragCoord = float2(Z.x * Z.z, (1.0 - Z.y) * Z.w) + (fragCoord - 0.5 * ctx.res);
        res = Z.zw;
    }
#endif
    float3 ro = EL_CAM;
    float pitch = 4.4 * PI / 180.0;
    float3 ta = ro + float3(0.02, tan(pitch), 1.0) * 1000.0;
    const float fov = 44.0;
    float3 rd = el_camRay(fragCoord, res, ro, ta, fov);
    float pa = 2.0 * tan(fov * PI / 360.0) / res.y;   // pixel angle (rad)

    ELLight L;
    L.sun = el_sunDir();
    L.sunE = 22.0 * el_sunTrans(L.sun);
    L.skyUp = ws_atmosphere(float3(0.0, 1.0, 0.0), L.sun, 22.0, 0.76, 1.0, EL_ALT);
    L.skyHz = ws_atmosphere(normalize(float3(-0.3, 0.12, 1.0)), L.sun, 22.0, 0.76, 1.0, EL_ALT);
    L.sunH = normalize(float3(L.sun.x, 0.35, L.sun.z));
    L.skySun = ws_atmosphere(L.sunH, L.sun, 22.0, 0.76, 1.0, EL_ALT);
    // cosine-weighted hemisphere average of ws_atmosphere for this sun (measured offline,
    // 64-sample quadrature) x2.2 for multiple scattering + terrain bounce
    L.skyAmb = float3(0.082, 0.135, 0.155) * 2.2;

    float tWater = rd.y < 0.0 ? -ro.y / rd.y : 1e9;
    int mat; float4 ti;
    float tmax = min(tWater, 16000.0);
    float t = el_march(ro, rd, 1.0, tmax, 300, pa, 0.0, mat, ti);

    float3 col;
    float tTot = t;
    float shh = 0.0;
    if (mat == 1) {
        col = el_shadeTerrain(ro + rd * t, rd, t, pa, L, shh);
        col = el_fog(col, t, ro, rd, L, shh);
    } else if (mat == 2) {
        col = el_shadeTree(ro + rd * t, rd, t, pa, ti, L, shh);
        col = el_fog(col, t, ro, rd, L, shh);
    } else if (tWater < 1e8) {
        tTot = tWater;
        float3 P = ro + rd * tWater;
        float ruffle = el_windPatch(P.xz);
        float3 n = el_waterNormal(P.xz, tWater, -rd.y, pa, ruffle);
        float3 r = reflect(rd, n);
        r.y = max(r.y, 0.001);
        int rm; float4 rti;
        float rpa = pa * 1.5;
        float rt = el_march(P, r, 0.5, 14000.0, 150, rpa, 0.5, rm, rti);
        float3 rc;
        if (rm == 1) { rc = el_shadeTerrain(P + r * rt, r, rt + tWater, rpa, L, shh); rc = el_fog(rc, rt + tWater, P, r, L, shh); }
        else if (rm == 2) { rc = el_shadeTree(P + r * rt, r, rt + tWater, rpa, rti, L, shh); rc = el_fog(rc, rt + tWater, P, r, L, shh); }
        else { rc = el_sky(r, L, hash12(fragCoord + 7.1)); }
        // ruffled patches integrate many micro-facets: reflection goes matte toward the mid sky
        if (ruffle > 0.01) {
            float3 rm3 = reflect(rd, normalize(float3(0.0, 1.0, -0.12)));
            rm3.y = max(rm3.y, 0.05);
            float3 matte = el_skyBase(normalize(rm3), L.sun) * 0.9;
            rc = mix(rc, matte, 0.6 * ruffle);
        }
#ifdef EL_DBGREF
        return float3(rm == 1 ? 1.0 : 0.0, rm == 2 ? 1.0 : 0.0, rm == 0 ? 1.0 : 0.0) * (0.3 + 0.7 * shh) + float3(0.0, 0.0, 0.0) * rt;
#endif

        float cosi = max(dot(-rd, n), 0.0);
        float F = 0.02 + 0.98 * pow(1.0 - cosi, 5.0);

        // glacial water body: rock-flour scattering + visible shallow bottom
        float depth = max(-el_height(P.xz, 6), 0.0);
        float3 tr = refract(rd, n, 1.0 / 1.333);
        float path = depth / max(-tr.y, 0.15);
        float3 sigma = float3(0.42, 0.052, 0.105);
        float3 T = exp(-sigma * (path + depth));
        // downwelling light inside the water integrates the whole sky plus the warm sun,
        // so it is far less blue than the shaded-slope ambient
        float lum = dot(L.skyAmb, float3(0.28, 0.52, 0.20));
        float3 skyIrr = mix(L.skyAmb, float3(lum), 0.62) * 1.25 + L.sunE * 0.010 * max(L.sun.y, 0.0);
        // suspended rock flour: emerald in the shallows, teal where the basin drops away,
        // with slow plumes of turbidity drifting out from the inflow
        float turb = fbm(P.xz * float2(0.0013, 0.00075) + float2(4.0, 7.0), 3);
        turb = 0.94 + 0.18 * smoothstep(-0.30, 0.40, turb * 1.4);
        float dp = smoothstep(1.6, 19.0, depth * (2.02 - turb));
        // shallow rock flour is strongly green-dominant; the deep basin drifts to teal
        float3 scat = skyIrr * mix(float3(0.120, 0.720, 0.268), float3(0.050, 0.330, 0.330), dp) * (1.26 * turb);
        // silty bottom with stones
        float2 bp = P.xz + tr.xz * path;
        bp += 1.6 * float2(gnoise(bp * 0.27 + float2(2.0, 5.0)), gnoise(bp * 0.31 + float2(8.0, 1.0)));
        float2 wv = worley(bp * 0.8);
        float2 wv2 = worley(bp * 2.3 + float2(4.0, 9.0));
        float stone = smoothstep(0.08, 0.35, wv.y - wv.x) * smoothstep(-0.3, 0.4, gnoise(bp * 0.15))
                    + 0.5 * smoothstep(0.06, 0.30, wv2.y - wv2.x) * smoothstep(-0.2, 0.5, gnoise(bp * 0.42 + 3.0));
        float3 bottomAlb = float3(0.52, 0.485, 0.375) * (0.72 + 0.28 * gnoise(bp * 0.9)) * (0.85 + 0.35 * stone);
        float3 body = scat * (1.0 - T) + bottomAlb * skyIrr * T;
        // the water column is lifted independently of the rock so the shallows can read
        // luminous without pushing the sunlit peaks toward clipping
        body *= 0.955;
        col = body * (1.0 - F) + rc * F;
    } else {
        col = el_sky(rd, L, hash12(fragCoord + 3.7));
        tTot = 1e5;
    }

    col = el_mist(col, ro, rd, tTot, hash12(fragCoord), L);

    float3 c = col * (1.585 * ws_vignette(fragCoord / res, 0.26));
    c = ws_acesFitted(c);
    c += ws_grain(fragCoord, ctx.t) * 0.003;
    return c;
}
#endif
