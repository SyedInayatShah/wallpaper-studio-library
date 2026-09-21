// =====================================================================
//  Autumn Creek — forest creek at peak autumn, camera low at the water.
//  Units: metres. x right, y up, z forward (upstream, toward the sun).
//  Terrain + water are two heightfields; canopy/mist are a volume.
// =====================================================================

constant float AC_STEP  = 0.28;   // rise per cascade
constant float AC_POOLK = 0.34;   // stair frequency (pools per metre)
constant float AC_TMAX  = 42.0;

struct ACLight { float3 sun; float3 sunCol; float3 amb; float3 ambSky; };

inline float3 ac_sunDir() { return normalize(float3(-0.30, 0.65, 1.0)); }
inline float  ac_smax(float a, float b, float k) { float h = clamp(0.5 + 0.5*(a - b)/k, 0.0, 1.0); return mix(b, a, h) + k*h*(1.0 - h); }
inline float  ac_sq(float x) { return x*x; }
inline float  ac_hg(float mu, float g) { float gg = g*g; return (1.0 - gg) / (4.0*PI*pow(max(1.0 + gg - 2.0*g*mu, 1e-3), 1.5)); }

// ---------------------------------------------------------------- layout
inline float ac_cx(float z) { return 0.7*sin(z*0.21 + 0.4) + 0.35*sin(z*0.57 + 2.1); }
inline float ac_hw(float z) { return 1.7 + 0.4*sin(z*0.33 + 1.0); }
inline float ac_u(float2 p)  { return p.y*AC_POOLK + 0.05 + 0.06*sin(p.x*1.3 + p.y*0.7) + 0.03*gnoise(p*1.7); }
inline float ac_levelApprox(float z) { return AC_STEP*(z*AC_POOLK + 0.05); }

// rounded boulders from a jittered grid, smooth-max union
inline float ac_domes(float2 p, float cell, float rmin, float rmax, float hf, float seed) {
    float2 pc = p/cell; float2 i = floor(pc); float2 f = pc - i;
    float h = 0.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float2 g = float2(x, y);
        float4 r = hash24(i + g + seed);
        float2 c = g + 0.15 + 0.7*r.xy;
        float rad = mix(rmin, rmax, r.z*r.z)/cell;
        float2 d = f - c;
        float ang = r.w*TAU; float ca = cos(ang), sa = sin(ang);
        d = float2(ca*d.x - sa*d.y, sa*d.x + ca*d.y);
        d.x *= mix(0.75, 1.4, fract(r.z*7.31));
        float dd = dot(d, d)/(rad*rad);
        if (dd < 1.0) {
            float q = sqrt(dd);
            float dome = sqrt(max(1.0 - dd*q, 0.0));
            float H = rad*cell*hf*(0.55 + 0.45*fract(r.w*5.17));
            h = ac_smax(h, H*(dome - 0.15), 0.02);
        }
    }
    return h;
}

// terrain height; `smooth` = bed + banks + boulders only (what the water sheet follows)
inline float ac_terrain2(float2 p, float detail, thread float &smooth) {
    float cx = ac_cx(p.y), hw = ac_hw(p.y);
    float xr = p.x - cx, ax = abs(xr);
    float u = ac_u(p); float k = floor(u), f = u - k;
    float stair = AC_STEP*(k + smoothstep(0.78, 1.0, f));
    float chan = max(1.0 - ac_sq(ax/hw), 0.0);
    float basin = 0.30*chan*smoothstep(0.0, 0.35, f)*(1.0 - smoothstep(0.74, 0.80, f));
    float bo = max(ax - hw, 0.0);
    float bank = 0.9*smoothstep(0.0, 1.8, bo) + 0.35*bo + 0.22*gnoise(p*0.7 + 3.0)*smoothstep(0.0, 0.6, bo);
    float h = stair - basin + bank;
    float2 w = p + 0.07*float2(gnoise(p*2.6), gnoise(p*2.6 + 7.0));
    float big = ac_domes(w, 0.9, 0.22, 0.50, 0.75, 1.0);
    h += big;
    smooth = h;
    if (detail > 0.0) {
        float cob = ac_domes(w, 0.30, 0.06, 0.15, 0.8, 2.0);
        h += detail*(cob + 0.012*fbm(p*16.0, 2) + 0.004*gnoise(p*55.0));
    }
    return h;
}
inline float ac_terrain(float2 p, float detail) { float s; return ac_terrain2(p, detail, s); }

// water surface height given the smooth terrain under it
inline float ac_water(float2 p, float smooth) {
    float u = ac_u(p); float k = floor(u), f = u - k;
    float lvl = AC_STEP*(k + smoothstep(0.80, 0.97, f));
    float drop = min(smoothstep(0.74, 0.82, f) + (1.0 - smoothstep(0.0, 0.08, f)), 1.0);
    float cover = 1.0 - smoothstep(0.05, 0.14, smooth - lvl);
    float sheet = max(lvl, smooth + 0.02);
    float und = 0.003*gnoise(p*3.0 + 1.0);
    return mix(lvl + und, sheet, drop*cover);
}

inline float ac_detailAt(float t) { return 1.0 - smoothstep(6.0, 10.0, t); }

inline float ac_top(float2 p, float detail, thread float &terr, thread float &wat) {
    float sm; terr = ac_terrain2(p, detail, sm); wat = ac_water(p, sm); return max(terr, wat);
}

inline bool ac_march(float3 ro, float3 rd, float tmin, float tmax, int maxIt,
                     thread float &tHit, thread int &mat, thread float &terrO, thread float &watO) {
    float t = tmin, tp = tmin;
    for (int i = 0; i < maxIt; i++) {
        float3 P = ro + rd*t;
        float terr, wat;
        float h = ac_top(P.xz, ac_detailAt(t), terr, wat);
        float d = P.y - h;
        if (d < 0.0) {
            float ta = tp, tb = t;
            for (int j = 0; j < 5; j++) {
                float tm = 0.5*(ta + tb);
                float3 Pm = ro + rd*tm;
                float h2 = ac_top(Pm.xz, ac_detailAt(tm), terr, wat);
                if (Pm.y - h2 < 0.0) tb = tm; else ta = tm;
            }
            float3 Ph = ro + rd*tb;
            ac_top(Ph.xz, ac_detailAt(tb), terr, wat);
            tHit = tb; terrO = terr; watO = wat;
            mat = (wat > terr + 0.002) ? 2 : 1;
            return true;
        }
        tp = t;
        t += clamp(d*0.5, 0.003 + 0.004*t, 0.12 + 0.03*t);
        if (t > tmax) return false;
    }
    return false;
}

inline float3 ac_normalRock(float2 p, float t, float detail) {
    float e = max(0.0012, 0.0005*t);
    float hx = ac_terrain(p + float2(e, 0.0), detail) - ac_terrain(p - float2(e, 0.0), detail);
    float hz = ac_terrain(p + float2(0.0, e), detail) - ac_terrain(p - float2(0.0, e), detail);
    return normalize(float3(-hx, 2.0*e, -hz));
}
inline float3 ac_normalWater(float2 p, float t, float detail) {
    float e = max(0.0015, 0.0006*t);
    float s;
    ac_terrain2(p + float2(e, 0.0), detail, s); float a = ac_water(p + float2(e, 0.0), s);
    ac_terrain2(p - float2(e, 0.0), detail, s); float b = ac_water(p - float2(e, 0.0), s);
    ac_terrain2(p + float2(0.0, e), detail, s); float c = ac_water(p + float2(0.0, e), s);
    ac_terrain2(p - float2(0.0, e), detail, s); float d = ac_water(p - float2(0.0, e), s);
    return normalize(float3(-(a - b), 2.0*e, -(c - d)));
}

// ---------------------------------------------------------------- light helpers
// canopy gaps projected along the sun: shared by dappled light, water and god rays
inline float ac_gaps(float3 P) {
    float3 s = ac_sunDir();
    float3 r = normalize(cross(s, float3(0.0, 1.0, 0.0)));
    float3 u = cross(r, s);
    float2 q = float2(dot(P, r), dot(P, u));
    float n = fbm(q*0.55 + float2(3.1, 7.7), 4);
    float n2 = gnoise(q*2.6 + float2(1.0, 5.0));
    float g = smoothstep(0.04, 0.32, n + 0.25*n2 + 0.02);
    g *= 0.7 + 0.3*vnoise(q*9.0);
    float hgt = P.y - ac_levelApprox(P.z);
    g = mix(g, 1.0, smoothstep(8.0, 11.0, hgt));
    return 0.04 + 0.96*g;
}

inline float ac_shadow(float3 P, float3 Ldir, float det) {
    float sh = 1.0; float t = 0.02;
    for (int i = 0; i < 14; i++) {
        float3 Q = P + Ldir*t;
        float h = ac_terrain(Q.xz, det*(t < 0.5 ? 1.0 : 0.0));
        float d = Q.y - h;
        sh = min(sh, 10.0*d/t);
        if (sh < 0.0) break;
        t += max(0.02, t*0.5);
    }
    return clamp(sh, 0.0, 1.0);
}

inline float ac_ao(float3 P, float det) {
    float occ = 0.0;
    float rad = 0.05;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            float a = float(j)*1.5708 + float(i)*0.39;
            float2 q = P.xz + float2(cos(a), sin(a))*rad;
            float h = ac_terrain(q, det*(i < 2 ? 1.0 : 0.0));
            occ += clamp((h - P.y)/rad - 0.15, 0.0, 1.0)*0.25;
        }
        rad *= 2.6;
    }
    return clamp(1.0 - occ*0.35, 0.0, 1.0);
}

inline float3 ac_envCheap(float3 P, float3 R, ACLight L) {
    float mu = dot(R, L.sun);
    float up = clamp(R.y, 0.0, 1.0);
    float3 e = L.amb*(0.9 + 1.4*up) + L.ambSky*up*0.6;
    float g = ac_gaps(P + R*2.5);
    e += L.sunCol*0.12*g*ac_hg(mu, 0.75)*smoothstep(-0.1, 0.2, R.y);
    return e;
}

// ---------------------------------------------------------------- leaves
inline float ac_leafSDF(float2 q, float kind, thread float &vein) {
    float r = length(q); float a = atan2(q.y, q.x);
    float R;
    if (kind < 0.45) {   // maple-like: 5 lobes, stem notch
        float lobe = pow(abs(cos(2.5*a)), 0.6);
        R = 0.58 + 0.42*lobe;
        R *= 1.0 - 0.18*smoothstep(0.75, 1.0, abs(a)/PI);
        vein = smoothstep(0.1, 0.0, abs(sin(2.5*a))*r)*(1.0 - smoothstep(0.3, 1.0, r/R));
        return r - R;
    } else {             // ovate, pointed tip
        float2 e = float2(q.x - 0.08, q.y*1.8);
        float re = length(e); float ae = atan2(e.y, e.x);
        float Re = 0.92*(1.0 + 0.12*cos(ae))*(1.0 - 0.10*pow(abs(sin(ae)), 3.0));
        float mid = smoothstep(0.06, 0.0, abs(e.y))*(1.0 - smoothstep(0.2, 1.0, re/Re));
        float lat = smoothstep(0.12, 0.0, abs(fract(e.x*3.0 + abs(e.y)*1.2) - 0.5))*0.5*(1.0 - smoothstep(0.6, 1.0, re/Re));
        vein = max(mid, lat);
        return (re - Re)*0.7;
    }
}

struct ACLeaf { float cover; float3 col; float3 nrm; float ring; };

inline ACLeaf ac_leafField(float2 p, float cell, float density, float seed, float3 n, float aa) {
    ACLeaf o; o.cover = 0.0; o.col = float3(0.0); o.nrm = n; o.ring = 0.0;
    float2 pc = p/cell; float2 i = floor(pc); float2 f = pc - i;
    float best = -1.0;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        float2 g = float2(x, y);
        float4 h = hash24(i + g + seed);
        if (h.x > density) continue;
        float4 h2 = hash24(i + g + seed + 37.1);
        float2 c = g + 0.15 + 0.7*h.yz;
        float2 d = (f - c)*cell;
        float size = mix(0.035, 0.062, h.w);
        float ang = h2.x*TAU; float ca = cos(ang), sa = sin(ang);
        float2 q = float2(ca*d.x - sa*d.y, sa*d.x + ca*d.y)/size;
        if (dot(q, q) > 2.4) continue;
        float vein; float sd = ac_leafSDF(q, h2.y, vein);
        float a = aa/size;
        float m = 1.0 - smoothstep(-a, a, sd);
        if (sd > 0.0) o.ring = max(o.ring, smoothstep(0.35, 0.0, sd));
        if (m > 0.02 && h2.z > best) {
            best = h2.z; o.cover = m;
            float3 red = float3(0.42, 0.045, 0.02), orange = float3(0.70, 0.22, 0.03);
            float3 yellow = float3(0.78, 0.55, 0.07), brown = float3(0.26, 0.12, 0.05);
            float sel = h2.w;
            float3 col;
            if (h2.y < 0.45) col = sel < 0.5 ? red : (sel < 0.85 ? orange : yellow);
            else col = sel < 0.55 ? yellow : (sel < 0.8 ? orange : brown);
            float rr = clamp(1.0 + sd, 0.0, 1.0);
            col = mix(col, brown, 0.35*smoothstep(0.55, 1.0, rr)*h.w);
            col *= 0.85 + 0.3*gnoise(q*2.5 + h2.z*10.0);
            col *= 1.0 - 0.4*vein;
            o.col = col;
            float2 rad = normalize(q + float2(1e-4, 0.0));
            float2 rw = float2(ca*rad.x + sa*rad.y, -sa*rad.x + ca*rad.y);
            o.nrm = normalize(n + float3(-rw.x, 0.0, -rw.y)*0.45*smoothstep(0.5, 1.0, rr));
        }
    }
    return o;
}

// ---------------------------------------------------------------- rock material + shading
inline float3 ac_rockAlbedo(float2 q, float3 n, float above, float bo, float t,
                            thread float3 &nOut, thread float &moss, thread float &wetOut, thread float &ring) {
    float grain = fbm(q*7.0 + 2.0, 3);
    float3 rock = mix(float3(0.30, 0.28, 0.25), float3(0.16, 0.155, 0.15), 0.5 + 0.5*grain);
    rock *= 0.85 + 0.3*vnoise(q*45.0);
    rock *= mix(float3(1.0), float3(1.2, 0.98, 0.78), smoothstep(0.2, 0.7, gnoise(q*0.7 + 5.0)));
    float wet = 1.0 - smoothstep(0.03, 0.22, above);
    float mossN = fbm(q*2.1 + 11.0, 3) + 0.4*fbm(q*8.0 + 3.0, 2);
    moss = smoothstep(0.0, 0.3, mossN + 0.1*smoothstep(0.0, 1.0, bo))*smoothstep(0.35, 0.75, n.y)
         * smoothstep(0.0, 0.10, above)*(1.0 - 0.5*smoothstep(0.6, 1.6, above));
    float3 mossC = mix(float3(0.09, 0.19, 0.03), float3(0.30, 0.38, 0.06), vnoise(q*70.0));
    float3 alb = mix(rock, mossC, moss);
    alb *= mix(1.0, 0.45, wet*(1.0 - moss));
    float litter = smoothstep(0.2, 0.9, bo);
    if (litter > 0.0) {
        float3 lit = float3(0.20, 0.10, 0.04)*(0.7 + 0.5*vnoise(q*30.0));
        alb = mix(alb, lit, litter*0.7*(1.0 - moss));
    }
    float dens = mix(0.22, 0.95, litter)*smoothstep(0.3, 0.6, n.y);
    float aa = max(0.0006, 0.00035*t);
    ACLeaf lf = ac_leafField(q, 0.10, dens, 1.0, n, aa);
    alb = mix(alb, lf.col, lf.cover);
    nOut = normalize(mix(n, lf.nrm, lf.cover));
    ring = lf.ring*(1.0 - lf.cover);
    wetOut = wet*(1.0 - 0.4*lf.cover);
    return alb;
}

inline float3 ac_shadeRock(float3 P, float3 n, float3 rd, float t, float terr, float wat, ACLight L, bool full) {
    float2 q = P.xz;
    float cx = ac_cx(P.z), hw = ac_hw(P.z); float bo = max(abs(P.x - cx) - hw, 0.0);
    float above = P.y - wat;
    float3 n2; float moss, wet, ring;
    float3 alb = ac_rockAlbedo(q, n, above, bo, t, n2, moss, wet, ring);
    float det = ac_detailAt(t);
    float g = ac_gaps(P);
    float sh = full ? ac_shadow(P + n*0.01, L.sun, det) : 0.8;
    float ao = full ? ac_ao(P, det) : 0.7;
    ao *= 1.0 - 0.5*ring;
    float ndl = max(dot(n2, L.sun), 0.0);
    float3 sunL = L.sunCol*g*sh;
    float3 amb = (L.amb*(0.55 + 0.45*n2.y) + L.ambSky*max(n2.y, 0.0))*ao;
    float3 col = alb*(sunL*ndl + amb);
    // moss glows when backlit
    col += mossC_glow(0.0);
    float3 h = normalize(L.sun - rd);
    float ndh = max(dot(n2, h), 0.0);
    float rough = mix(mix(0.55, 0.16, wet), 0.75, moss);
    float a2 = rough*rough; a2 *= a2;
    float D = a2/(PI*ac_sq(ndh*ndh*(a2 - 1.0) + 1.0));
    float F0 = 0.03;
    float vdh = max(dot(-rd, h), 0.0);
    float F = F0 + (1.0 - F0)*pow(1.0 - vdh, 5.0);
    col += sunL*D*F*ndl*0.25;
    float ndv = max(dot(n2, -rd), 0.0);
    float Fe = F0 + (1.0 - F0)*pow(1.0 - ndv, 5.0);
    float3 R = reflect(rd, n2);
    col += ac_envCheap(P, R, L)*Fe*(1.0 - rough)*ao;
    return col;
}
