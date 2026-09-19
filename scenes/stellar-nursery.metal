// ============================================================================
//  Stellar Nursery — emission nebula: dust cliffs & pillars carved and lit by a
//  young blue-white cluster, HOO + gold ionised gas, deep reddened star field.
//
//  Dust is a participating medium given by a column density rho(x,y). The
//  ionising UV reaching each point is exp(-kappa * integral rho) along the
//  line to the cluster (2D optical-depth march), so ionisation fronts appear
//  exactly where the dust faces the cluster, with a physically soft falloff.
// ============================================================================

// ---------------------------------------------------------------- noise (cheap, trig-free)
inline float2 sn_g2(int2 c) {
    uint h = ws_pcg(uint(c.x) * 73856093u ^ uint(c.y) * 19349663u);
    return float2(float(h & 0xffffu), float(h >> 16)) * (2.0 / 65535.0) - 1.0;
}
inline float sn_n2(float2 p) {
    float2 i = floor(p); float2 f = p - i; int2 c = int2(i);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(sn_g2(c),              f);
    float b = dot(sn_g2(c + int2(1, 0)), f - float2(1, 0));
    float d = dot(sn_g2(c + int2(0, 1)), f - float2(0, 1));
    float e = dot(sn_g2(c + int2(1, 1)), f - float2(1, 1));
    return 1.5 * mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}
constant float2x2 SN_R = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
inline float sn_fbm(float2 p, int oct, float gain) {
    float s = 0.0, a = 1.0, n = 0.0;
    for (int i = 0; i < oct; i++) {
        s += a * sn_n2(p); n += a;
        p = SN_R * p * 2.03 + float2(1.7, 9.2);
        a *= gain;
    }
    return s / n;
}
inline float sn_billow(float2 p, int oct, float gain) {   // ~[0,1]
    float s = 0.0, a = 1.0, n = 0.0;
    for (int i = 0; i < oct; i++) {
        s += a * abs(sn_n2(p)); n += a;
        p = SN_R * p * 2.07 + float2(3.1, 8.3);
        a *= gain;
    }
    return s / n;
}
inline float sn_ridge(float2 p, int oct, float gain) {    // ~[0,1]
    float s = 0.0, a = 1.0, n = 0.0;
    for (int i = 0; i < oct; i++) {
        float r = 1.0 - abs(sn_n2(p));
        s += a * r * r; n += a;
        p = SN_R * p * 2.11 + float2(7.3, 2.9);
        a *= gain;
    }
    return s / n;
}
inline float sn_smax(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
    return mix(b, a, h) + k * h * (1.0 - h);
}

// ---------------------------------------------------------------- layout
constant float2 SN_S = float2(-0.50, 0.32);    // ionising cluster (screen coords)

// bent, lumpy pillar from base a to tip b; returns inside-ness (>0 inside)
inline float sn_pillar(float2 p, float2 a, float2 b, float r0, float r1, float seed) {
    float2 ab = b - a; float L = length(ab); float2 ax = ab / L;
    float2 pp = float2(-ax.y, ax.x);
    float2 q = p - a;
    float t = dot(q, ax) / L;
    float tc = clamp(t, 0.0, 1.0);
    // bend the axis and vary the girth along the length
    float bend = L * (0.10 * sin(tc * 2.6 + seed) + 0.05 * sn_n2(float2(tc * 3.0, seed)));
    float d = length(q - ax * (tc * L) - pp * bend);
    float r = mix(r0, r1, pow(tc, 0.75)) * (1.0 + 0.22 * sn_n2(float2(tc * 7.0, seed + 4.0)))
            + 0.35 * r1 * exp(-(tc - 0.90) * (tc - 0.90) * 70.0);
    return r - d;
}

// macro inside-ness (screen units, >0 inside dust)
inline float sn_macro(float2 p) {
    float x = p.x;
    // diagonal crest: low at left, rising to a lit headland right of centre, falling away right
    float edge = -0.80 + 0.70 * smoothstep(-1.5, 0.70, x) - 0.24 * smoothstep(0.85, 1.75, x)
               + 0.13 * sn_fbm(float2(x * 1.4, 2.7), 5, 0.55)
               + 0.05 * exp(-(x + 1.05) * (x + 1.05) / 0.004) + 0.04 * exp(-(x + 0.36) * (x + 0.36) / 0.003)
               + 0.10 * exp(-(x - 0.66) * (x - 0.66) / 0.018)
               - 0.07 * exp(-(x + 0.05) * (x + 0.05) / 0.012);
    float m = edge - p.y;
    float pl = -1.0;
    pl = max(pl, sn_pillar(p, float2( 0.05, -0.50), float2(-0.14,  0.07), 0.105, 0.040, 1.0));
    pl = max(pl, sn_pillar(p, float2( 0.34, -0.32), float2( 0.22,  0.00), 0.070, 0.028, 5.0));
    pl = max(pl, sn_pillar(p, float2(-0.58, -0.74), float2(-0.67, -0.42), 0.052, 0.022, 9.0));
    pl = max(pl, sn_pillar(p, float2(-1.22, -0.86), float2(-1.26, -0.60), 0.045, 0.020, 12.0));
    m = sn_smax(m, pl, 0.07);
    return m;
}
inline float2 sn_warp(float2 p) {
    float2 q = float2(sn_fbm(p * 1.7 + float2(1.7, 4.2), 4, 0.5),
                      sn_fbm(p * 1.7 + float2(8.3, 2.8), 4, 0.5));
    float2 w = p + 0.10 * q;
    w += 0.030 * float2(sn_fbm(w * 5.5 + float2(4.4, 1.9), 3, 0.5),
                        sn_fbm(w * 5.5 + float2(2.2, 7.3), 3, 0.5));
    return w;
}

// column density of the dust. oct = detail octaves.
inline float sn_rho(float2 p, int oct) {
    float2 w = sn_warp(p);
    float m = sn_macro(w);
    // erosion: noise stretched along the flow to the cluster (fingers point at the stars)
    float2 rel = p - SN_S;
    float rad = length(rel);
    float arc = atan2(rel.y, rel.x) * rad;
    float2 fc = float2(arc * 9.0, rad * 3.0);
    m += 0.035 * sn_fbm(fc + 0.25 * w, 3, 0.5);                 // large erosion fingers only
    // lumps: billow + plain fbm (billow alone reads as cotton)
    float b = sn_billow(w * 6.0, oct, 0.50);
    m += 0.055 * (b - 0.30) + 0.035 * sn_fbm(w * 9.0 + 1.3, oct, 0.55);
    // crisp ragged edge; interior column density varies (thin veils vs opaque cores)
    float k = 0.15 * exp(3.2 * sn_fbm(w * 2.6 + 9.0, 5, 0.55));        // lognormal column
    float rho = smoothstep(0.0, 0.007, m) * (0.40 + 0.8 * b) + k * max(m, 0.0);

    if (oct > 5) rho *= exp(0.55 * sn_fbm(w * 24.0 + 2.0 * b, oct - 3, 0.6));
    return rho;
}

// ---------------------------------------------------------------- stars
inline float3 sn_starColor(float h) {
    float T = h < 0.12 ? mix(2800.0, 3700.0, h / 0.12)
            : h < 0.55 ? mix(3700.0, 5600.0, (h - 0.12) / 0.43)
            : h < 0.85 ? mix(5600.0, 7500.0, (h - 0.55) / 0.30)
            :            mix(7500.0, 12000.0, (h - 0.85) / 0.15);
    float3 c = ws_blackbody(T);
    return c / max(ws_luma(c), 1e-3);
}
inline float sn_psf(float r2, float sig) {
    float core = exp(-r2 / (2.0 * sig * sig)) / (6.2832 * sig * sig);
    const float a2 = 9.0;
    float q = 1.0 + r2 / a2;
    float halo = (1.0 / (3.1416 * a2)) / (q * q);
    const float b2 = 1600.0;
    float q2 = 1.0 + r2 / b2;
    float wide = (0.5 / (3.1416 * b2)) / (q2 * sqrt(q2));
    return 0.90 * core + 0.085 * halo + 0.015 * wide;
}
inline float sn_flux(float m) { return pow(10.0, -0.4 * (m - 12.0)); }
inline float sn_spikes(float2 d, float sig) {
    float s = 0.0;
    for (int k = 0; k < 4; k++) {
        float a = PI * 0.5 + float(k) * (PI / 3.0);
        float w = 1.0;
        if (k == 3) { a = 0.0; w = 0.35; }
        float2 dir = float2(cos(a), sin(a));
        float along = abs(dot(d, dir));
        float perp = dot(d, float2(-dir.y, dir.x));
        s += w * exp(-perp * perp / (2.0 * sig * sig * 1.3)) / pow(1.0 + along / 3.0, 2.1);
    }
    return s;
}

inline float3 sn_starLayer(float2 qpx, float cellPx, float prob, float mBright, float mFaint,
                           float sig, float seed, bool nb) {
    float3 acc = float3(0.0);
    float2 id0 = floor(qpx / cellPx);
    int R = nb ? 1 : 0;
    for (int j = -R; j <= R; j++)
    for (int i = -R; i <= R; i++) {
        float2 id = id0 + float2(i, j);
        float4 h = hash24(id + seed);
        if (h.x > prob) continue;
        float4 h2 = hash24(id + seed + 71.3);
        float2 pos = (id + 0.5 + (h.yz - 0.5) * (nb ? 0.9 : 0.62)) * cellPx;
        float2 d = qpx - pos;
        float m = max(mFaint + log10(max(h2.w, 1e-6)) / 0.33, mBright);
        float r2 = dot(d, d);
        // faint single-cell stars: Gaussian core only (wings would be clipped at the cell border)
        float psf = nb ? sn_psf(r2, sig) : exp(-r2 / (2.0 * sig * sig)) / (6.2832 * sig * sig);
        if (m < 6.5) psf += 0.0004 * sn_spikes(d, sig) * smoothstep(6.5, 5.0, m);
        acc += sn_starColor(h2.x) * sn_flux(m) * psf;
    }
    return acc;
}
// ---------------------------------------------------------------- scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
    float  pxScale = 2400.0 / ctx.res.y;
    float2 qpx = fragCoord * pxScale;
    float  sig = max(0.85, 0.5 * pxScale);
    float  rnd = hash12(fragCoord * 1.37 + 0.5);

    const float3 cHa   = float3(1.00, 0.055, 0.15);
    const float3 cO3   = float3(0.02, 0.62, 0.70);
    const float3 cGold = float3(1.00, 0.50, 0.16);
    const float3 cRefl = float3(0.50, 0.68, 1.00);

    float2 rel = p - SN_S;
    float  rS  = length(rel);
    float2 dS  = -rel / max(rS, 1e-4);        // unit direction toward the cluster

    // ------------------------------------------------ dust at this pixel
    float rho  = sn_rho(p, 9);
    // smooth heightfield (low octaves only: no rocky micro-relief) -> gentle normal
    float e = 0.006;
    float rs0 = sn_rho(p, 3);
    float rsX = sn_rho(p + float2(e, 0.0), 3);
    float rsY = sn_rho(p + float2(0.0, e), 3);
    float hC = 0.10 * (1.0 - exp(-rs0 * 1.2));
    float hX = 0.10 * (1.0 - exp(-rsX * 1.2));
    float hY = 0.10 * (1.0 - exp(-rsY * 1.2));
    float3 nrm = normalize(float3(-(hX - hC) / e, -(hY - hC) / e, 1.0));
    float3 l3 = normalize(float3(SN_S - p, 0.22 - hC));   // cluster slightly in front of the slab

    // ------------------------------------------------ UV optical depth toward the cluster
    float tauE = 0.0;
    {
        float s = 0.0015;
        float prev = 0.0;
        for (int k = 0; k < 34; k++) {
            if (s > rS) break;
            float ds = s - prev;
            float rq = sn_rho(p + dS * s, k < 10 ? 8 : 4);
            // UV sees a thinned column: in 3D it slips over thin veils, dense cores block it
            tauE += rq * (0.45 + 0.55 * smoothstep(0.45, 1.3, rq)) * ds;
            prev = s;
            s = s * 1.16 + 0.0015;
        }
    }
    float Le = exp(-tauE * 110.0);            // thin ionisation front (in-plane)
    float Lf = exp(-tauE * 9.0);              // deeper, softer "face" illumination
    float flux = 0.26 / (rS * rS + 0.10);

    // ------------------------------------------------ gas (H II bubble around the cluster)
    float2 bq = float2(sn_fbm(p * 0.9 + 3.3, 5, 0.5), sn_fbm(p * 0.9 + 7.1, 5, 0.5));
    float2 bw = p + 0.18 * bq;
    bw += 0.018 * float2(sn_fbm(bw * 11.0 + 1.3, 4, 0.5), sn_fbm(bw * 11.0 + 6.1, 4, 0.5));
    float2 bc = (bw - SN_S) * float2(0.88, 1.05);
    float rb = length(bc);
    float ab = atan2(bc.y, bc.x);
    float R0 = 0.66 + 0.16 * sn_fbm(float2(ab * 1.3, 1.7), 3, 0.5);
    float dr = rb - R0;
    float side = 0.35 + 0.65 * smoothstep(-0.3, 0.8, dot(normalize(bc), normalize(float2(0.9, -0.6))));
    float shell = exp(-dr * dr / (dr < 0.0 ? 0.030 : 0.10)) * side;    // limb-brightened wall
    float inner = smoothstep(R0 + 0.05, 0.0, rb * (1.0 + 0.35 * sn_fbm(bw * 2.0 + 31.0, 4, 0.5))); // hot cavity
    float halo  = exp(-rb * rb / 2.4);                                  // outer diffuse H-alpha
    // lognormal turbulent density: exp(sigma * fbm) -> knots, sheets, sharp lanes at all scales
    float big   = sn_fbm(bw * 1.7 + 11.0, 9, 0.60);
    float fine  = sn_fbm(bw * 7.0 + 2.0 * bq + 3.0, 7, 0.62);
    float fil   = sn_ridge(bw * 3.0 + 1.3 * bq, 6, 0.55);
    float fine2 = sn_fbm(p * 22.0 + 0.6 * bq, 6, 0.6);                   // isotropic small-scale turbulence
    float dHa   = exp(2.6 * big + 0.8 * fine + 0.45 * fine2) * (0.7 + 0.5 * pow(fil, 6.0));
    float dO3   = exp(2.8 * sn_fbm(bw * 2.4 + 23.0, 8, 0.62) + 0.7 * fine + 0.5 * fine2) * 0.7;
    float tauL  = 0.35 * exp(3.0 * sn_fbm(bw * 2.3 + 5.0, 9, 0.60));   // dark lanes (column)
    // a winding translucent dust lane crossing the upper-left glow toward the cavity
    {
        float2 lw = p + 0.06 * bq + 0.012 * float2(sn_fbm(p * 14.0 + 2.0, 4, 0.55), 0.0);
        float yc = 0.64 - 0.24 * smoothstep(-1.75, -0.70, lw.x) + 0.035 * sin(4.0 * lw.x + 1.0);
        float wd = 0.075 * (0.35 + 0.65 * smoothstep(-0.70, -1.05, lw.x));
        float dl = abs(lw.y - yc) / wd;
        float lane = exp(-dl * dl * 1.6) * smoothstep(-0.66, -0.98, lw.x);
        tauL += 1.8 * lane * exp(1.2 * sn_fbm(p * 18.0 + 8.0, 6, 0.6));
    }
    // small dark wisps / knots (lognormal: mostly clear, occasionally opaque)
    tauL += 0.18 * exp(2.6 * sn_fbm(bw * 9.0 + 0.8 * bq + 3.0, 7, 0.6));
    // occasional crisp bright sheet edges
    float sheet = pow(sn_ridge(bw * 4.5 + 0.7 * float2(fine, fine2) + 9.0, 5, 0.5), 10.0);
    float calm = smoothstep(1.02, 0.62, p.y) * (1.0 - 0.92 * smoothstep(0.25, 1.25, p.x) * smoothstep(0.0, 0.7, p.y));
    float absb = exp(-tauL);
    float lanes = tauL;
    float mott = 0.5 + 0.5 * fine;
    float mMac = sn_macro(sn_warp(p));
    float bar = exp(min(mMac, 0.0) / 0.07) * smoothstep(1.6, 0.4, rS);   // dense gas at the dust interface
    float haI = (shell * 1.0 + halo * 0.30 + bar * 1.3) * dHa * absb * calm * 0.52 * (0.85 + 1.4 * sheet);
    float glowLoc = (shell + halo * 0.4 + inner * 0.5) * calm;             // smooth local nebular light
    float o3I = inner * dO3 * exp(-tauL * 0.8) * calm * 0.45;
    float gasLit = mix(0.62, 1.0, exp(-tauE * 2.0));                    // soft neutral shadow tails
    float3 cHaB = float3(1.00, 0.10, 0.34);                             // H-alpha + H-beta (magenta)
    float3 haCol = mix(cHa, cHaB, smoothstep(0.1, 0.6, shell * mott));
    float3 back = (haCol * haI * 0.55 + cO3 * o3I * 0.65
                 + cGold * (0.04 * shell * pow(fil, 2.0) + 0.16 * bar) * dHa * absb * calm) * gasLit;
    back += cRefl * (exp(-rS * rS / 0.004) * 0.10 + exp(-rS * rS / 0.03) * 0.06) + cO3 * exp(-rS * rS / 0.08) * 0.05;

    // ------------------------------------------------ stars
    // star density varies on large scales (galactic structure / patchy foreground extinction)
    float sDen = exp(0.9 * sn_fbm(p * 1.3 + 40.0, 4, 0.5));
    float3 starsBg = sn_starLayer(qpx, 8.0, 0.22 * sDen, 13.0, 16.6, sig, 7.0, false)
                   + sn_starLayer(qpx, 14.0, 0.30 * sDen, 11.5, 15.6, sig, 1.0, false)
                   + sn_starLayer(qpx, 60.0, 0.30, 7.0, 12.5, sig, 2.0, true);
    // unresolved starlight + a few faint background galaxies
    starsBg += float3(0.0030, 0.0026, 0.0022) * sDen * sDen;
    for (int g = 0; g < 7; g++) {
        float4 hg = hash24(float2(float(g) * 7.3, 3.1));
        float2 gp = float2(mix(0.35, 1.55, hg.x), mix(-0.95, 0.85, hg.y));
        float2 dg = ws_rot(hg.z * PI) * (p - gp) * ctx.res.y * 0.5 * pxScale;   // final px
        float ax = 3.0 + 7.0 * hg.w, ay = ax * mix(0.3, 0.8, fract(hg.w * 7.1));
        float rg = length(dg / float2(ax, ay));
        starsBg += float3(1.0, 0.85, 0.70) * 0.035 * (exp(-rg * rg * 1.5) + 0.35 * exp(-rg * 1.4));
    }
    starsBg *= exp(-lanes * 1.0) * (0.55 + 0.45 * calm);
    float3 starsFg = sn_starLayer(qpx, 300.0, 0.30, 4.5, 9.0, sig, 4.0, true);

    float2 clPx = (SN_S * 2400.0 + float2(3840.0, 2400.0)) * 0.5;
    float3 cl = float3(0.0);
    for (int i = 0; i < 16; i++) {
        float4 hh = hash24(float2(float(i) * 3.1, 9.7));
        float a = hh.x * TAU, rr = pow(hh.y, 1.4) * 240.0;
        if (i == 0) rr = 0.0;
        float2 d = qpx - (clPx + float2(cos(a), sin(a)) * rr);
        float mg = (i == 0) ? -0.6 : 1.4 + 4.2 * hh.z;
        float fl = sn_flux(mg);
        float3 sc = mix(float3(0.62, 0.74, 1.0), float3(0.86, 0.90, 1.0), hh.w);
        cl += sc * fl * (sn_psf(dot(d, d), sig) + 0.0005 * sn_spikes(d, sig));
    }

    // ------------------------------------------------ dust shading
    float alpha = 1.0 - exp(-rho * 3.5);
    float3 tauC = float3(1.0, 1.4, 1.9);
    float3 trans = exp(-rho * 2.6 * tauC);
    float ndl = max(dot(nrm, l3), 0.0);
    float limb = min(1.0 / max(nrm.z, 0.1), 6.0);
    // turbulent, flow-aligned texture of the ionised skin (lognormal; streaks point at the cluster)
    float angS = atan2(rel.y, rel.x);
    float2 fc = float2(angS * rS * 55.0, rS * 16.0);
    float2 tw = p * 34.0 + 1.5 * float2(sn_fbm(p * 12.0, 3, 0.5), sn_fbm(p * 12.0 + 5.0, 3, 0.5));
    float stri = 0.5 + 0.5 * sn_fbm(tw * 2.0 + 7.0, 5, 0.6);
    float tex = exp(1.2 * sn_fbm(tw, 7, 0.60)) * 0.75;
    float Lb = exp(-tauE * 3.0);              // deep soft light in the cloud body
    // ionised skin: optically thin emission in the thin transition layer at the lit boundary
    float skinZone = 4.0 * alpha * (1.0 - alpha);
    float3 skinCol = mix(float3(1.0, 0.14, 0.17), float3(1.0, 0.52, 0.17), clamp(0.30 + 0.5 * tex * Le, 0.0, 1.0));
    float patchy = exp(1.8 * sn_fbm(p * 8.0 + 51.0, 4, 0.55)) * 0.85;    // bright and dim stretches of front
    float3 skin = skinCol * flux * Le * (skinZone * 1.7 + alpha * 0.30 * (0.6 + 0.4 * limb) * (0.5 + 0.5 * ndl))
                * (0.35 + 0.65 * tex) * patchy;
    // neutral dust body: weak reddened scattered starlight + diffuse nebular light
    float mottle = exp(1.6 * sn_fbm(tw * 0.6 + 11.0, 6, 0.6));         // high-contrast knots/veils
    float3 dustCol = float3(0.60, 0.24, 0.10) * flux * (Lf * (0.3 + 0.7 * ndl) * 0.09 + Lb * 0.025) * mottle * (0.5 + stri)
                   + float3(0.030, 0.011, 0.008) * (0.4 + 0.6 * mottle * stri) * clamp(glowLoc * 2.5, 0.08, 1.2);
    // fine dark filaments threading the dust (foreground absorption)
    float filA = pow(sn_ridge(tw * 0.35 + 4.0, 6, 0.55), 5.0)
               * smoothstep(-0.2, 0.5, sn_fbm(p * 5.0 + 17.0, 4, 0.5)) * (0.4 + 0.6 * mottle / (1.0 + mottle));
    float3 filT = exp(-filA * 2.2 * alpha * float3(1.0, 1.3, 1.6));
    // evaporating flows: ionised gas streaming off lit dust toward the cluster
    float evapD = 0.0;
    {
        float wsum = 0.0;
        for (int k = 0; k < 6; k++) {
            float s = 0.004 * exp2((float(k) + rnd) * 0.85);             // jittered: no ghost contours
            float w = exp(-s / 0.030);
            evapD += (1.0 - exp(-sn_rho(p - dS * s, 4) * 3.0)) * w;
            wsum += w;
        }
        evapD /= wsum;
    }
    float stream = exp(1.1 * sn_fbm(float2(angS * 70.0, rS * 5.0), 5, 0.6)) * 0.8;
    float3 evap = mix(float3(1.0, 0.10, 0.22), float3(1.0, 0.45, 0.25), evapD) * flux * Le * evapD * (1.0 - alpha) * stream * 1.1
                * (0.4 + 0.6 * patchy);

    float3 col = ((back + starsBg + cl) * trans + dustCol * alpha + skin) * filT + evap;
    for (int i = 0; i < 9; i++) {
        float4 hh = hash24(float2(float(i) * 5.7, 1.3));
        float2 sp = float2(mix(-1.3, 1.5, hh.x), mix(-0.95, -0.15, hh.y));
        if (sn_macro(sp) < 0.03) continue;                              // only inside the cloud
        float2 d = qpx - (sp * 1200.0 + float2(1920.0, 1200.0));
        float fl = sn_flux(3.8 + 3.0 * hh.z);
        float r2 = dot(d, d);
        float3 ycol = float3(1.0, 0.42, 0.20);
        col += ycol * fl * (sn_psf(r2, sig) + 0.0004 * sn_spikes(d, sig))
             + float3(0.9, 0.35, 0.25) * fl * 0.00018 * exp(-sqrt(r2) / (14.0 + 30.0 * hh.w));
    }
    // thin foreground emission veil (the dust sits inside the H II region, not in front of it)
    col += haCol * (halo * 0.5 + shell * 0.25) * (0.5 + 0.5 * mott) * calm * 0.035 * alpha;
    col += starsFg;

    col = ws_acesFitted(col * 1.65);
    // (no added grain: renderer dithers; grain near black is amplified by the sRGB curve)
    return max(col, 0.0);
}
