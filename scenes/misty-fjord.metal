// =====================================================================
//  Misty Fjord — Norwegian fjord at dawn under a low overcast, with a
//  warm break in the cloud far down the fjord.
//  Units: metres. y up, camera looks toward +z. Water surface at y = 0.
// =====================================================================

constant float MF_HTOP  = 1500.0;        // terrain height bound
constant float MF_CLOUD = 640.0;         // nominal cloud base
constant float2 MF_SHELF = float2(-318.0, 650.0);          // little rocky spit (hut site)
constant float3 MF_HUT   = float3(-322.0, 1.9, 654.0);      // hut origin (floor centre)
constant float  MF_HUTA  = 0.35;                            // hut yaw
constant float  MF_WFZ   = 1000.0;                          // main waterfall z

inline float mf_sq(float x) { return x * x; }
inline float mf_smax(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
    return mix(b, a, h) + k * h * (1.0 - h);
}
inline float mf_smin(float a, float b, float k) { return -mf_smax(-a, -b, k); }

// warm cloud break: down the fjord, a touch right, just above the far headlands
inline float3 mf_glowDir() { return normalize(float3(0.06, 0.06, 1.0)); }

// gradient noise with analytic derivatives (value, d/dx, d/dy), ~[-1,1]
inline float3 mf_noised(float2 p) {
    float2 i = floor(p); float2 f = p - i;
    int2 c = int2(i);
    float2 u  = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float2 ga = ws_g2(c), gb = ws_g2(c + int2(1, 0));
    float2 gc = ws_g2(c + int2(0, 1)), gd = ws_g2(c + int2(1, 1));
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0));
    float vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - float2(1, 1));
    float k1 = vb - va, k2 = vc - va, k3 = va - vb - vc + vd;
    float v = va + k1 * u.x + k2 * u.y + k3 * u.x * u.y;
    float2 g = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
             + du * float2(k1 + k3 * u.y, k2 + k3 * u.x);
    return float3(v, g) * 1.4142;
}

// ------------------------------------------------------------ fjord layout
// channel centre line meanders so that headlands overlap when seen from the water
inline float mf_cx(float z) {
    return 240.0 * sin(z * 0.00100 + 0.15) + 60.0 * sin(z * 0.0027 + 1.9) + 25.0 * sin(z * 0.0071 + 0.6);
}
inline float mf_hw(float z) {   // half width; widens toward the mouth
    return 430.0 - 60.0 * smoothstep(0.0, 7000.0, z) + 40.0 * sin(z * 0.0016 + 0.9) + 22.0 * sin(z * 0.0049 + 2.3)
         + 500.0 * smoothstep(9000.0, 14000.0, z);
}
// signed horizontal distance to the shoreline, positive on land
inline float mf_shore(float2 p) {
    float s = abs(p.x - mf_cx(p.y)) - mf_hw(p.y);
    s += 18.0 * gnoise(p * 0.004 + float2(2.1, 7.3)) + 6.0 * gnoise(p * 0.015 + float2(4.0, 1.0));
    return s;
}

// smooth large-scale landform: sheer walls rising from the water, spurs and side-valleys along them
inline float mf_macro(float2 p, float s, float side) {
    if (s < 0.0) return max(-2.0 + 1.6 * s, -380.0);                // fjord floor plunges
    float z = p.y;
    float sv = gnoise(float2(z * 0.0009 + side * 3.0, 1.3));         // spur / valley rhythm
    float L  = 240.0 + 100.0 * sv;                                   // e-fold width (steepness)
    float H  = (950.0 + 150.0 * gnoise(float2(z * 0.0006, 7.0 + side)))
             * (1.0 - 0.55 * smoothstep(6500.0, 12000.0, z));          // lower toward the mouth
    return H * (1.0 - exp(-s / L)) + 0.12 * s;
}

// eroded fractal detail with derivative damping: ridged spurs at low octaves, smooth rock above
inline float mf_detail(float2 x, int oct) {
    float2 p = x * 0.0011;
    float a = 0.0, b = 1.0;
    float2 d = float2(0.0);
    const float2x2 m = float2x2(float2(1.7, 1.1), float2(-1.1, 1.7));
    for (int i = 0; i < oct; i++) {
        float3 n = mf_noised(p);
        d += n.yz;
        float damp = 1.0 / (1.0 + 0.6 * dot(d, d));
        float v = (i < 3) ? (0.55 - abs(n.x)) : n.x;
        a += b * v * damp;
        b *= (i < 3) ? 0.5 : 0.47;
        p = m * p;
    }
    return a;
}

// main waterfall path on the left wall: signed z-offset from the ribbon centre (1e4 elsewhere)
inline float mf_wfOffset(float2 p, float s, float side) {
    if (side > 0.0 || s < -5.0) return 1e4;
    float ss = max(s, 0.0);
    float zc = MF_WFZ + 14.0 * sin(ss * 0.021 + 1.0) + 7.0 * sin(ss * 0.057 + 2.0) + 4.0 * gnoise(float2(ss * 0.08, 3.0));
    return p.y - zc;
}

inline float mf_heightS(float2 p, int oct, thread float &s) {
    s = mf_shore(p);
    float side = (p.x > mf_cx(p.y)) ? 1.0 : -1.0;
    float hm = mf_macro(p, s, side);
    float steep = smoothstep(15.0, 160.0, hm);
    float amp = 4.0 + 24.0 * smoothstep(0.0, 60.0, hm) + 150.0 * smoothstep(60.0, 600.0, hm);
    float h = hm + amp * mf_detail(p, oct);
    if (s > 0.0 && oct > 4) {
        // glacial scour grooves running down the fall line (x) across steep faces
        float2 q = float2(p.y * 0.045, p.x * 0.005);
        float g1 = gnoise(q + float2(1.0, 4.0));
        float g2 = gnoise(q * 2.7 + float2(5.0, 2.0));
        h += steep * (8.0 * g1 + 3.5 * g2);
        // rock benches / ledges
        float hs = (h + 6.0 * gnoise(p * 0.006 + float2(8.0, 1.0))) / 42.0;
        float fr = fract(hs);
        float bench = smoothstep(-0.2, 0.5, gnoise(p * 0.0013 + float2(3.0, 9.0)));
        h += steep * bench * 16.0 * (smoothstep(0.1, 0.9, fr) - fr);
        // waterfall groove
        float dz = mf_wfOffset(p, s, side);
        h -= 5.0 * exp(-mf_sq(dz / 11.0)) * smoothstep(0.0, 30.0, s);
    }
    // little rocky spit for the hut
    float2 dsh = (p - MF_SHELF) * float2(1.0, 0.7);
    float rs = length(dsh);
    float shelf = 1.0 - smoothstep(22.0, 58.0, rs);
    if (shelf > 0.0) {
        float sh = 1.9 + 1.2 * gnoise(p * 0.08) + 0.4 * gnoise(p * 0.3);
        h = mix(h, sh, shelf);
    }
    return h;
}
inline float mf_height(float2 p, int oct) { float s; return mf_heightS(p, oct, s); }

inline int mf_lod(float t, float pa, float bias) {
    return clamp(int(log2(380.0 / max(t * pa, 1e-3)) - bias), 3, 11);
}

// ------------------------------------------------------------ hut + jetty
inline float mf_boxSDF(float3 q, float3 b) {
    float3 d = abs(q) - b;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}
// returns distance; part: 1 walls, 2 roof, 3 jetty
inline float mf_hut(float3 p, thread int &part) {
    float3 q = p - MF_HUT;
    float c = cos(MF_HUTA), sn = sin(MF_HUTA);
    q.xz = float2(c * q.x - sn * q.z, sn * q.x + c * q.z);
    float dW = mf_boxSDF(q - float3(0.0, 1.45, 0.0), float3(2.3, 1.45, 3.4));
    float ry = q.y - 2.9;
    float dR = max(max(abs(q.z) * 0.62 + ry - 1.55, -ry - 0.12), abs(q.x) - 2.7);
    dR = max(dR, -(abs(q.z) * 0.62 + ry - 1.55 + 0.25));    // hollow underside (thin roof slab)
    // jetty: planks out over the water toward +x (channel side)
    float3 j = p - float3(MF_HUT.x + 14.0, 0.7, MF_HUT.z + 3.0);
    float dJ = mf_boxSDF(j, float3(11.0, 0.12, 1.1));
    float2 pj = float2(fract((j.x + 11.0) / 5.5) - 0.5, 0.0);
    float dP = length(float2(pj.x * 5.5, abs(j.z) - 0.9)) - 0.16;   // posts
    dP = max(dP, max(j.y - 0.6, -j.y - 1.5));
    dJ = min(dJ, dP);
    float d = dW; part = 1;
    if (dR < d) { d = dR; part = 2; }
    if (dJ < d) { d = dJ; part = 3; }
    return d;
}
inline bool mf_nearHut(float3 p) {
    float3 q = p - float3(MF_HUT.x + 8.0, 2.0, MF_HUT.z);
    return dot(q, q) < 30.0 * 30.0;
}

// ------------------------------------------------------------ marching
// mat: 0 sky, 1 terrain, 2 hut (part in hp)
inline float mf_march(float3 ro, float3 rd, float tmin, float tmax, int steps, float pa, float lodBias,
                      thread int &mat, thread int &hp) {
    float t = tmin, tPrev = t, dPrev = 1e5;
    mat = 0; hp = 0;
    for (int i = 0; i < steps; i++) {
        float3 p = ro + rd * t;
        if (p.y > MF_HTOP && rd.y > 0.0) { mat = 0; return tmax; }
        float h = mf_height(p.xz, mf_lod(t, pa, lodBias));
        float d = (p.y - h) * 0.30;
        int m = 1, part = 0;
        if (mf_nearHut(p)) {
            float dh = mf_hut(p, part);
            if (dh < d) { d = dh; m = 2; }
        }
        if (d < 0.0 && m == 1) {
            float tt = tPrev + (t - tPrev) * dPrev / max(dPrev - d, 1e-4);
            mat = 1; return tt;
        }
        if (d < 0.4 * pa * t) { mat = m; hp = part; return t; }
        tPrev = t; dPrev = d;
        t += max(d, 0.03 + 0.35 * pa * t);
        if (t > tmax) { mat = 0; return tmax; }
    }
    mat = 1;
    return t;
}

inline float3 mf_terrainNormal(float2 p, float t, float pa) {
    int oct = mf_lod(t, pa, -1.0);
    float e = max(0.05, 0.7 * pa * t);
    float h0 = mf_height(p, oct);
    float hx = mf_height(p + float2(e, 0.0), oct);
    float hz = mf_height(p + float2(0.0, e), oct);
    return normalize(float3(h0 - hx, e, h0 - hz));
}

inline float3 mf_hutNormal(float3 p) {
    const float2 k = float2(1.0, -1.0);
    const float e = 0.02;
    int pp;
    return normalize(k.xyy * mf_hut(p + k.xyy * e, pp) + k.yyx * mf_hut(p + k.yyx * e, pp) +
                     k.yxy * mf_hut(p + k.yxy * e, pp) + k.xxx * mf_hut(p + k.xxx * e, pp));
}

// soft shadow toward the cloud break (very soft: it is a big low area source)
inline float mf_shadow(float3 p, float3 l, float tHit, float pa) {
    float res = 1.0;
    float t = 2.0 + 0.5 * pa * tHit;
    for (int i = 0; i < 30; i++) {
        float3 q = p + l * t;
        if (q.y > MF_HTOP) break;
        float h = q.y - mf_height(q.xz, 4);
        res = min(res, 3.0 * h / t);
        if (res < -0.05) break;
        t += clamp(h * 0.6, 2.0 + t * 0.02, 400.0);
    }
    return smoothstep(-0.05, 1.0, res);
}

inline float mf_ao(float3 p, float3 n) {
    float occ = 0.0, w = 0.0;
    for (int i = 0; i < 5; i++) {
        float hr = 2.5 * pow(3.0, float(i));
        float3 q = p + n * hr;
        float d = q.y - mf_height(q.xz, 5);
        float wi = 1.0 / (1.0 + float(i) * 0.6);
        occ += clamp((hr - d * 0.9) / hr, 0.0, 1.0) * wi;
        w += wi;
    }
    return clamp(1.0 - occ / w, 0.0, 1.0);
}

// ------------------------------------------------------------ light + sky
struct MFLight {
    float3 amb;      // sky irradiance / PI for an upward-facing surface
    float3 glowDir;
    float3 glowCol;  // warm break radiance seen by the terrain (directional)
};

inline float3 mf_skyLight(float3 n, MFLight L) {
    return L.amb * (0.55 + 0.45 * n.y);
}

// overcast dome + textured cloud underside + warm break
inline float3 mf_sky(float3 rd, MFLight L) {
    float el = rd.y;
    float3 zen = float3(0.60, 0.66, 0.76);
    float3 hor = float3(0.40, 0.44, 0.52);
    float3 col = mix(hor, zen, smoothstep(0.0, 0.55, el));
    if (el > 0.005) {
        float2 uv = rd.xz * (MF_CLOUD / max(el, 0.02));
        float w = smoothstep(0.0, 0.14, el);
        float n = fbm(uv * 0.0009 + float2(3.0, 11.0), 4) + 0.3 * fbm(uv * 0.0035 + float2(1.0, 5.0), 3);
        col *= 1.0 + 0.30 * w * (-n);           // thicker (positive n) = darker underside
        // mammatus-ish soft lumps close to the camera
        col *= 1.0 - 0.06 * w * smoothstep(0.3, 0.7, el) * gnoise(uv * 0.006);
    }
    // warm break
    float ang = acos(clamp(dot(rd, L.glowDir), -1.0, 1.0));
    float core = exp(-mf_sq(ang / 0.075));
    float halo = exp(-mf_sq(ang / 0.30));
    float wide = exp(-mf_sq(ang / 0.75));
    float2 uvb = rd.xz * (MF_CLOUD / max(el, 0.02));
    float thin = smoothstep(-0.3, 0.5, -fbm(uvb * 0.0012 + float2(9.0, 2.0), 3));
    col += float3(1.0, 0.55, 0.28) * (3.2 * core * (0.4 + 0.6 * thin) + 0.55 * halo * (0.5 + 0.5 * thin));
    col += float3(0.9, 0.72, 0.55) * 0.18 * wide;
    // horizon haze band
    col = mix(col, float3(0.52, 0.55, 0.60) + float3(0.35, 0.22, 0.1) * wide, (1.0 - smoothstep(0.0, 0.05, el)) * 0.6);
    return col;
}

// ------------------------------------------------------------ atmosphere (marched)
inline float mf_fogDensity(float3 p, thread float &warmFrac) {
    float haze = 1.5e-4 * (0.7 + 0.3 * exp(-max(p.y, 0.0) / 400.0));
    // low mist banks on the water, thicker far down the fjord
    float bank = fbm(p.xz * 0.0011 + float2(6.0, 1.0), 3) + 0.35 * gnoise(p.xz * 0.005 + float2(2.0, 8.0));
    float m = smoothstep(0.05, 0.55, bank) * smoothstep(700.0, 2600.0, p.z);
    float mist = 0.0045 * exp(-max(p.y, 0.0) / 14.0) * m;
    // cloud deck with a ragged base; wisps hanging down the walls
    float cb = MF_CLOUD + 90.0 * gnoise(p.xz * 0.0006 + float2(4.0, 3.0)) + 40.0 * gnoise(p.xz * 0.002 + float2(7.0, 1.0));
    float deck = 0.012 * smoothstep(cb - 70.0, cb + 90.0, p.y) * (0.65 + 0.35 * gnoise(p * 0.004));
    float wisp = 0.0025 * smoothstep(cb - 330.0, cb - 40.0, p.y)
               * smoothstep(0.15, 0.6, fbm(float2(p.x * 0.002 + p.y * 0.0012, p.z * 0.002) + float2(1.0, 9.0), 3));
    // spray plume at the waterfall foot
    float3 wf = p - float3(-232.0, 4.0, MF_WFZ);
    float spray = 0.03 * exp(-dot(wf * float3(0.05, 0.08, 0.05), wf * float3(0.05, 0.08, 0.05)));
    float den = haze + mist + deck + wisp + spray;
    warmFrac = (haze + mist * 0.7) / max(den, 1e-6);
    return den;
}

inline float mf_hg(float mu, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(1.0 + gg - 2.0 * g * mu, 1.5));
}

// integrate fog along [0, tEnd]; returns transmittance-composited colour
inline float3 mf_fog(float3 col, float3 ro, float3 rd, float tEnd, float jit, MFLight L, int NS) {
    float t1 = min(tEnd, 15000.0);
    float T = 1.0;
    float3 acc = float3(0.0);
    float mu = dot(rd, L.glowDir);
    float ph = mf_hg(mu, 0.55) * 4.0 * PI;
    float3 ambC = L.amb * 1.0;
    for (int i = 0; i < NS; i++) {
        float u0 = float(i) / float(NS), u1 = float(i + 1) / float(NS);
        float ta = t1 * pow(u0, 1.6), tb = t1 * pow(u1, 1.6);
        float tt = mix(ta, tb, jit);
        float dt = tb - ta;
        float3 q = ro + rd * tt;
        float wf;
        float den = mf_fogDensity(q, wf);
        float a = 1.0 - exp(-den * dt);
        // in-scatter: overcast ambient (brighter up in the deck) + warm glow reaching the far air
        float vis = smoothstep(900.0, 4500.0, q.z) * smoothstep(0.0, 1.0, 1.0 - smoothstep(400.0, 700.0, q.y));
        float3 Lin = ambC * (0.75 + 0.25 * smoothstep(0.0, 600.0, q.y)) * (0.85 + 0.15 * wf)
                   + L.glowCol * 0.22 * ph * vis * (0.35 + 0.65 * wf);
        acc += T * a * Lin;
        T *= 1.0 - a;
        if (T < 0.01) break;
    }
    return col * T + acc;
}

// ------------------------------------------------------------ terrain shading
inline float3 mf_shadeTerrain(float3 p, float3 rd, float t, float pa, MFLight L) {
    float3 n = mf_terrainNormal(p.xz, t, pa);
    float s = mf_shore(p.xz);
    float side = (p.x > mf_cx(p.z)) ? 1.0 : -1.0;
    float ao = mf_ao(p, n);

    // micro bump for close rock
    float bumpW = 1.0 - smoothstep(600.0, 2500.0, t);
    if (bumpW > 0.0) {
        float3 nb = mf_noised(p.xz * 0.9).yzz;
        float3 nc = mf_noised(float2(p.z, p.y) * 0.45 + 3.0).yzz;
        n = normalize(n + bumpW * (0.10 * float3(nb.x, 0.0, nb.y) + 0.08 * float3(0.0, nc.y, nc.x)));
    }

    float n1 = gnoise(p.xz * 0.012 + float2(1.0, 2.0));
    float n2 = gnoise(p.xz * 0.09 + float2(5.0, 3.0));
    float n3 = gnoise(p * 0.4);
    float lich = smoothstep(-0.2, 0.6, gnoise(p.xz * 0.03 + float2(9.0, 4.0)) + 0.5 * n3);
    float3 rock = mix(float3(0.075, 0.070, 0.066), float3(0.150, 0.140, 0.128), lich * 0.6);
    rock *= (0.82 + 0.36 * (0.5 + 0.5 * n3)) * (0.88 + 0.24 * n1);
    // dark water streaks running down the face
    float streak = gnoise(float2(p.z * 0.08, p.y * 0.006) + float2(2.0, 7.0));
    rock *= 0.82 + 0.30 * smoothstep(-0.4, 0.6, streak);
    // moss / lichen greens in moist areas, gentle slopes and lower on the wall
    float moist = smoothstep(-0.1, 0.6, gnoise(p.xz * 0.006 + float2(3.0, 5.0)) + 0.4 * n2);
    float moss = moist * smoothstep(0.15, 0.55, n.y + 0.15 * n2) * (1.0 - smoothstep(300.0, 520.0, p.y));
    rock = mix(rock, float3(0.050, 0.082, 0.032) * (0.8 + 0.4 * n2), moss * 0.85);
    // scrub / birch on ledges
    float veg = smoothstep(0.50, 0.75, n.y + 0.12 * n1) * (1.0 - smoothstep(250.0, 420.0, p.y)) * smoothstep(1.5, 8.0, s);
    float crown = vnoise(p.xz / 2.6) * 0.6 + vnoise(p.xz / 1.1) * 0.4;
    rock = mix(rock, float3(0.030, 0.052, 0.024) * (0.5 + 1.0 * crown), veg * 0.9);
    // tide-line: wet dark rock just above the water
    float wet = (1.0 - smoothstep(0.0, 2.5, p.y)) * step(-1.0, s);
    // waterfall ribbon and wet halo
    float dz = mf_wfOffset(p.xz, s, side);
    float adz = abs(dz);
    float steepF = 1.0 - smoothstep(0.55, 0.8, n.y);
    float rib = (1.0 - smoothstep(2.2, 3.4, adz + 1.2 * gnoise(float2(p.y * 0.05, p.x * 0.3))));
    rib *= smoothstep(0.0, 1.5, p.y);
    float halo = 1.0 - smoothstep(4.0, 30.0, adz);
    wet = max(wet, halo * 0.8);
    rock *= 1.0 - 0.45 * wet;
    // shelf ground + shore rocks
    float shelfW = 1.0 - smoothstep(20.0, 56.0, length((p.xz - MF_SHELF) * float2(1.0, 0.7)));
    rock = mix(rock, mix(float3(0.11, 0.105, 0.095), float3(0.06, 0.085, 0.035), smoothstep(0.2, 0.6, n2)) * (0.8 + 0.4 * n3), shelfW * 0.8);

    float3 alb = rock;
    // lighting: overcast sky + weak warm break + ground/water bounce
    float3 col = alb * mf_skyLight(n, L) * (0.35 + 0.65 * ao);
    float dg = dot(n, L.glowDir);
    if (dg > 0.0) {
        float sh = mf_shadow(p + n * max(0.5, pa * t), L.glowDir, t, pa);
        col += alb * L.glowCol * dg * sh / PI;
    }
    col += alb * L.amb * float3(0.22, 0.30, 0.30) * 0.35 * (0.5 - 0.5 * n.y) * ao;
    // wet rock sheen: reflection of the overcast sky
    float3 r = reflect(rd, n);
    float fr = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), 5.0);
    float3 skyR = mix(float3(0.40, 0.44, 0.52), float3(0.60, 0.66, 0.76), clamp(r.y, 0.0, 1.0));
    col += skyR * (0.02 + 0.5 * fr) * wet * 0.6 * ao;
    // waterfall: bright aerated water, streaky
    if (rib > 0.0) {
        float streaks = 0.7 + 0.5 * gnoise(float2(p.z * 0.9, p.y * 0.12 + p.x * 0.3));
        float3 foam = float3(0.80, 0.84, 0.88) * streaks * steepF;
        float3 fc = foam * (mf_skyLight(float3(0.3, 0.6, -0.7), L) * (0.6 + 0.4 * ao) * 1.15);
        col = mix(col, fc, rib * (0.55 + 0.45 * steepF));
    }
    return col;
}

inline float3 mf_shadeHut(float3 p, float3 rd, int part, MFLight L) {
    float3 n = mf_hutNormal(p);
    float3 q = p - MF_HUT;
    float c = cos(MF_HUTA), sn = sin(MF_HUTA);
    q.xz = float2(c * q.x - sn * q.z, sn * q.x + c * q.z);
    float3 alb;
    float3 emit = float3(0.0);
    if (part == 1) {
        alb = ws_hex(0x7A2A1F) * (0.85 + 0.3 * gnoise(float2(q.y * 6.0, (q.x + q.z) * 0.4)));   // Falu red boards
        // white trim at corners and a window on the gable end facing the camera (-z) and the water side (+x)
        float trim = step(2.15, abs(q.x)) + step(3.25, abs(q.z));
        alb = mix(alb, float3(0.75, 0.74, 0.70), clamp(trim, 0.0, 1.0));
        float win = 0.0;
        if (q.z < -3.3) win = step(abs(q.x - 0.3), 0.55) * step(abs(q.y - 1.6), 0.5);
        if (q.x > 2.25) win = max(win, step(abs(q.z + 1.2), 0.55) * step(abs(q.y - 1.6), 0.45));
        emit = float3(1.0, 0.55, 0.22) * 2.6 * win;
        alb = mix(alb, float3(0.02), win);
    } else if (part == 2) {
        alb = float3(0.085, 0.10, 0.045) * (0.8 + 0.4 * gnoise(q.xz * 3.0));     // turf roof
    } else {
        alb = float3(0.16, 0.14, 0.11) * (0.8 + 0.4 * gnoise(float2(q.x * 4.0, q.z * 0.5)));
    }
    float3 col = alb * mf_skyLight(n, L) * 0.85;
    float dg = dot(n, L.glowDir);
    col += alb * L.glowCol * max(dg, 0.0) * 0.5 / PI;
    return col + emit;
}

// ------------------------------------------------------------ water
inline float3 mf_waterNormal(float2 p, float t, float grazing, float pa) {
    float wind = smoothstep(-0.1, 0.6, fbm(p * float2(0.0025, 0.0065) + float2(3.0, 1.0), 3));
    float away = smoothstep(120.0, 900.0, p.y);
    float footX = pa * t;
    float footZ = pa * t / max(grazing, 0.02);
    float2 g = float2(0.0);
    float2 q = p * float2(0.25, 1.0) / 9.0;
    float wl = 9.0;
    const float2x2 R = float2x2(float2(0.96, 0.28), float2(-0.28, 0.96));
    for (int i = 0; i < 7; i++) {
        float amp = 0.0016 + 0.011 * wind * away;
        float fz = 1.0 - smoothstep(0.5 * wl, 2.2 * wl, footZ);
        float fx = 1.0 - smoothstep(0.5 * wl, 2.2 * wl, footX * 4.0);
        float3 nd = mf_noised(q);
        g += amp * nd.yz * float2(0.25 * fx, fz) * 0.7;
        q = R * q * 2.0;
        wl *= 0.5;
    }
    return normalize(float3(-g.x, 1.0, -g.y));
}

// ------------------------------------------------------------ camera (screen-right = +x)
inline float3 mf_camRay(float2 fragCoord, float2 res, float3 ro, float3 ta, float fovYDeg) {
    float3 f = normalize(ta - ro);
    float3 r = normalize(cross(float3(0.0, 1.0, 0.0), f));
    float3 u = cross(f, r);
    float2 p = (2.0 * fragCoord - res) / res.y;
    float k = tan(fovYDeg * (PI / 180.0) * 0.5);
    return normalize(f + (p.x * r + p.y * u) * k);
}

// ------------------------------------------------------------ main
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 res = ctx.res;
#ifdef MF_ZOOM   // 1:1 crop of a virtual full-size frame: float4(cx, cy (0..1 from top-left), fullW, fullH)
    {
        float4 Z = MF_ZOOM;
        fragCoord = float2(Z.x * Z.z, (1.0 - Z.y) * Z.w) + (fragCoord - 0.5 * ctx.res);
        res = Z.zw;
    }
#endif
    float3 ro = float3(mf_cx(0.0) - 170.0, 6.0, 0.0);
    float yaw = -6.0 * PI / 180.0, pitch = 2.0 * PI / 180.0;
    float3 ta = ro + float3(sin(yaw), tan(pitch), cos(yaw)) * 1000.0;
    const float fov = 40.0;
    float3 rd = mf_camRay(fragCoord, res, ro, ta, fov);
    float pa = 2.0 * tan(fov * PI / 360.0) / res.y;

    MFLight L;
    L.amb = float3(0.38, 0.42, 0.49);
    L.glowDir = mf_glowDir();
    L.glowCol = float3(1.0, 0.60, 0.32) * 2.2;

    float jit = hash12(fragCoord + 1.3);
    float tWater = rd.y < 0.0 ? -ro.y / rd.y : 1e9;
    int mat, hp;
    float tmax = min(tWater, 16000.0);
    float t = mf_march(ro, rd, 1.0, tmax, 300, pa, 0.0, mat, hp);

    float3 col;
    float tTot = t;
    if (mat == 1) {
        col = mf_shadeTerrain(ro + rd * t, rd, t, pa, L);
    } else if (mat == 2) {
        col = mf_shadeHut(ro + rd * t, rd, hp, L);
    } else if (tWater < 1e8) {
        tTot = tWater;
        float3 P = ro + rd * tWater;
        float3 n = mf_waterNormal(P.xz, tWater, -rd.y, pa);
        float3 r = reflect(rd, n);
        r.y = max(r.y, 0.001);
        int rm, rhp;
        float rpa = pa * 1.5;
        float rt = mf_march(P, r, 0.5, 15000.0, 170, rpa, 0.7, rm, rhp);
        float3 rc;
        if (rm == 1) rc = mf_shadeTerrain(P + r * rt, r, rt + tWater, rpa, L);
        else if (rm == 2) rc = mf_shadeHut(P + r * rt, r, rhp, L);
        else rc = mf_sky(r, L);
        rc = mf_fog(rc, P, r, (rm == 0) ? 15000.0 : rt, jit, L, 22);

        float cosi = max(dot(-rd, n), 0.0);
        float F = 0.02 + 0.98 * pow(1.0 - cosi, 5.0);
        // deep green fjord water; a little bottom visibility in the shallows by the spit
        float depth = max(-mf_height(P.xz, 5), 0.0);
        float3 tr = refract(rd, n, 1.0 / 1.333);
        float path = depth / max(-tr.y, 0.15);
        float3 sigma = float3(0.35, 0.09, 0.12);
        float3 T = exp(-sigma * (path + depth));
        float3 body = L.amb * float3(0.020, 0.060, 0.052) * (1.0 - T) + float3(0.16, 0.15, 0.11) * L.amb * T;
        col = body * (1.0 - F) + rc * F;
    } else {
        col = mf_sky(rd, L);
        tTot = 1e5;
    }

    col = mf_fog(col, ro, rd, tTot, jit, L, 40);

    float3 c = col * 1.35;
    c = ws_acesFitted(c);
    c += ws_grain(fragCoord, ctx.t) * 0.003;
    return c;
}
