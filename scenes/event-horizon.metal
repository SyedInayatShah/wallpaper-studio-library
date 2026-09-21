// ============================================================================
//  Event Horizon — a Schwarzschild black hole with a thin, relativistically
//  beamed accretion disk, a lensed halo, photon ring and a lensed sky.
//
//  Units: Schwarzschild radius Rs = 1 (M = 0.5).  Null geodesics are
//  integrated in 3D with the Binet-equivalent central force
//        x'' = -1.5 h^2 x / r^5 ,   h = |x × x'|  (conserved)
//  which reproduces u'' + u = 1.5 u^2 exactly, so every bend, the lensed far
//  side of the disk, the secondary image and the photon ring fall out of the
//  integration.  Each pixel traces two neighbour rays in lock-step, giving the
//  true (lensed) pixel footprint on the disk and on the sky for filtering.
//
//  Disk: thin slab in the y = 0 plane.  Redshift for circular orbits
//        g = sqrt(1 - 1.5/r) / (1 - Ω λ),  Ω = sqrt(M / r^3),  λ = L_y / E
//  drives both colour temperature (T_obs ~ g T) and beaming (I ~ g^3).
//  Motion: differential (Keplerian) rotation, loop-safe via two advected
//  texture layers cross-faded half a cycle apart with variance-preserving
//  blending of the underlying noise (filaments morph, never double-expose).
//  Sky: point stars are drawn in image space through the lens Jacobian (stay
//  crisp, correctly magnified); a diffuse Milky Way is sampled at the escaped
//  direction so it is smeared into Einstein arcs around the shadow.
//  Camera: analytic veiling glare / halation added in HDR before tone mapping.
// ============================================================================

constant float EH_D      = 30.0;     // camera distance (Rs)
constant float EH_ELEV   = 0.085;    // camera elevation above disk plane (rad)
constant float EH_FOV    = 36.0;     // vertical fov (deg)
constant float EH_RIN    = 3.0;      // ISCO
constant float EH_ROUT   = 17.0;
constant int   EH_STEPS  = 420;
constant float2 EH_HOLE  = float2(0.0, 0.03);   // where the hole sits on screen (p units)
constant float EH_ROLL   = -0.04;
constant float EH_EXPO   = 0.9;

// ---------------------------------------------------------------- periodic noise
inline float2 eh_g(int2 c, uint seed) {
    uint h = ws_pcg(uint(c.x) * 73856093u ^ uint(c.y) * 19349663u ^ seed * 83492791u);
    return float2(float(h & 0xffffu), float(h >> 16)) * (2.0 / 65535.0) - 1.0;
}
// 2D gradient noise, periodic in x with integer period `per`
inline float eh_pn(float2 p, int per, uint seed) {
    float2 i = floor(p); float2 f = p - i;
    int2 c = int2(i);
    int x0 = ws_wrap(c.x, per), x1 = ws_wrap(c.x + 1, per);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(eh_g(int2(x0, c.y),     seed), f);
    float b = dot(eh_g(int2(x1, c.y),     seed), f - float2(1, 0));
    float d = dot(eh_g(int2(x0, c.y + 1), seed), f - float2(0, 1));
    float e = dot(eh_g(int2(x1, c.y + 1), seed), f - float2(1, 1));
    return 1.6 * mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

// ---------------------------------------------------------------- geodesics
inline float3 eh_acc(float3 x, float h2) {
    float r2 = dot(x, x);
    return (-1.5 * h2 / (r2 * r2 * sqrt(r2))) * x;
}
inline float3 eh_planeHit(float3 a, float3 b) {
    float dy = a.y - b.y;
    float f = abs(dy) > 1e-6 ? a.y / dy : 0.5;
    f = clamp(f, -4.0, 5.0);
    return mix(a, b, f);
}

// ---------------------------------------------------------------- disk texture
constant int   EH_NA = 10;          // angular cells at octave 0
constant float EH_NU = 16.0;        // radial cells per unit log r
inline float eh_omega(float r) { return 0.42 * pow(EH_RIN / r, 1.5); }   // turns per loop

inline float2 eh_tc(float3 hp, float rotPhase) {
    float r = length(hp.xz);
    float a = atan2(hp.z, hp.x) * (1.0 / TAU);
    float om = eh_omega(r);
    a += om * rotPhase;                         // material coordinate
    a += 0.55 * pow(EH_RIN / r, 1.5);           // frozen trailing-spiral shear
    return float2(a * float(EH_NA), log(r) * EH_NU);
}
inline float2 eh_wrapd(float2 d) { d.x -= float(EH_NA) * rint(d.x / float(EH_NA)); return d; }

// two advected layers, variance-preserving blend
struct EHC { float2 cA; float2 cB; float wA; float wB; float inv; };
inline float eh_bn(EHC c, float2 sc, float ofs, int per, uint seed) {
    float2 o = float2(0.0, ofs);
    return (c.wA * eh_pn(c.cA * sc + o, per, seed)
          + c.wB * eh_pn(c.cB * sc + o + float2(0.0, 40.0), per, seed)) * c.inv;
}
inline float eh_fw(float2 d1, float2 d2, float2 sc) {   // footprint filter weight
    float fp = max(length(d1 * sc), length(d2 * sc));
    return 1.0 - smoothstep(0.15, 0.5, fp);
}

struct EHTex { float dens; float fil; float hot; float lane; float puff; };

inline EHTex eh_tex(EHC c, float2 d1, float2 d2) {
    // low-frequency radial warp (streaks waver)
    float wa = eh_bn(c, float2(0.5, 0.12), 0.0, EH_NA / 2, 11u);
    float wb = eh_bn(c, float2(1.0, 0.35), 0.0, EH_NA, 12u) * eh_fw(d1, d2, float2(1.0, 0.35));
    float warp = 1.2 * wa + 0.4 * wb;
    c.cA.y += warp; c.cB.y += warp;

    // 1. puffs — near-isotropic gaseous clumps
    float puff = 0.0, pn = 0.0, amp = 1.0;
    float2 sc = float2(4.0, 0.30); int per = EH_NA * 4;
    for (int i = 0; i < 4; i++) {
        float w = eh_fw(d1, d2, sc);
        if (w > 0.0) puff += amp * w * eh_bn(c, sc, 13.0 * float(i) + 3.0, per, 30u + uint(i));
        pn += amp; amp *= 0.55; sc *= float2(2.0, 1.6); per *= 2;
    }
    puff /= pn;
    // 1b. large-scale density arms (2 cells around)
    float arm = eh_bn(c, float2(0.2, 0.08), 200.0, 2, 70u);

    // 2. streaks — azimuthally stretched, with ridge filaments
    float st = 0.0, sn = 0.0; amp = 1.0; sc = float2(1.0, 0.5); per = EH_NA;
    float fil = 0.0, fn = 0.0;
    for (int i = 0; i < 4; i++) {
        float w = eh_fw(d1, d2, sc);
        float nv = 0.0;
        if (w > 0.0) nv = eh_bn(c, sc, 17.3 * float(i) + 50.0, per, 40u + uint(i));
        st += amp * w * nv;
        if (i >= 1) {
            float rg = 1.0 - abs(nv); rg *= rg;
            fil += amp * mix(0.5, rg, w); fn += amp;
        }
        sn += amp; amp *= 0.5; sc *= float2(2.0, 1.5); per *= 2;
    }
    st /= sn; fil /= fn;

    // 3. dark lanes — thin absorbing threads
    float2 lsc = float2(1.5, 0.25);
    float lw = eh_fw(d1, d2, lsc);
    float ln = eh_bn(c, lsc, 90.0, EH_NA * 3 / 2, 50u);
    float ln2 = eh_bn(c, lsc * 2.0, 97.0, EH_NA * 3, 51u) * eh_fw(d1, d2, lsc * 2.0);
    float lane = smoothstep(0.70, 0.98, 1.0 - abs(ln + 0.35 * ln2)) * lw;

    // 4. broad axisymmetric rings (gentle)
    float ring;
    {
        float y = c.cA.y;
        float fy = length(float2(d1.y, d2.y));
        ring  = 0.8 * eh_pn(float2(0.37, y * 0.16), 1, 21u);
        ring += 0.2 * eh_pn(float2(0.71, y * 0.40), 1, 22u) * (1.0 - smoothstep(0.2, 0.5, fy * 0.40));
    }

    // 5. hot knots
    float2 hsc = float2(3.0, 0.6);
    float hk = eh_bn(c, hsc, 130.0, EH_NA * 3, 60u) * eh_fw(d1, d2, hsc);
    float hot = pow(max(hk - 0.2, 0.0) / 0.8, 2.2);

    float base = 0.62 * puff + 0.22 * st + 0.10 * ring + 0.35 * arm;
    float dens = smoothstep(-0.6, 0.65, base);
    dens *= 1.0 - 0.35 * lane;

    EHTex t;
    t.dens = dens;
    t.fil = fil;
    t.hot = hot;
    t.lane = lane;
    t.puff = puff;
    return t;
}

// ---------------------------------------------------------------- stars
// Point stars rendered in IMAGE space: the lens map's Jacobian (from the two
// neighbour rays) maps each star's source-space offset to a pixel offset, so
// stars stay crisp points with their lensing magnification, even near the
// Einstein ring, instead of being smeared into arcs.
inline float3 eh_stars(float3 n0, float3 j1, float3 j2, float pixA) {
    float3 col = float3(0.0);
    float ga = dot(j1, j1), gb = dot(j1, j2), gc = dot(j2, j2);
    float det = ga * gc - gb * gb;
    if (det < 1e-20) return col;
    float idet = 1.0 / det;
    float mu = min(pixA * pixA / max(length(cross(j1, j2)), 1e-12), 12.0);
    const float sp = 0.7;                  // PSF sigma in pixels
    const float sh = 2.2;                  // halo sigma (bright stars)
    float cull = 16.0 * sh * sh * (ga + gc);
    for (int L = 0; L < 3; L++) {
        float S    = (L == 0) ? 30.0 : ((L == 1) ? 90.0 : 240.0);
        float prob = (L == 0) ? 0.35 : ((L == 1) ? 0.40 : 0.45);
        float kpow = (L == 0) ? 6.0 : ((L == 1) ? 5.0 : 3.5);
        float amp  = (L == 0) ? 9.0 : ((L == 1) ? 1.6 : 0.22);
        float3 p = n0 * S;
        float3 c0 = floor(p);
        for (int k = 0; k < 27; k++) {
            float3 c = c0 + float3(float(k % 3) - 1.0, float((k / 3) % 3) - 1.0, float(k / 9) - 1.0);
            float4 h = hash44(float4(c, float(L) * 7.0 + 1.0));
            if (h.w > prob) continue;
            float3 q = c + 0.05 + 0.9 * h.xyz;
            float lq = length(q);
            if (abs(lq - S) > 0.5) continue;
            float3 dd = q / lq - n0;
            if (dot(dd, dd) > cull) continue;
            float b1 = dot(j1, dd), b2 = dot(j2, dd);
            float u = (gc * b1 - gb * b2) * idet;
            float v = (ga * b2 - gb * b1) * idet;
            float d2 = u * u + v * v;
            if (d2 > 16.0 * sh * sh) continue;
            float4 g = hash44(float4(c, float(L) * 7.0 + 3.0));
            float mag = pow(g.x, kpow);
            float temp = mix(3400.0, 12000.0, pow(g.y, 1.4));
            if (g.z < 0.22) temp = mix(2500.0, 3700.0, g.w);
            float I = amp * mag;
            float psf = exp(-d2 / (2.0 * sp * sp));
            float halo = exp(-d2 / (2.0 * sh * sh)) * 0.012 * smoothstep(0.5, 4.0, I);
            col += ws_blackbody(temp) * I * (psf + halo);
        }
    }
    return col * mu;
}

// Diffuse Milky Way + faint dust, sampled at the (lensed) escape direction.
inline float3 eh_galaxy(float3 n) {
    const float3 gN = normalize(float3(0.50, 0.86, 0.06));
    const float3 gX = normalize(cross(gN, float3(0.0, 0.0, 1.0)));
    const float3 gY = cross(gN, gX);
    float lat = asin(clamp(dot(n, gN), -1.0, 1.0));
    float lon = atan2(dot(n, gY), dot(n, gX));
    float2 q = float2(lon * 2.2, lat * 7.0);
    float cl = fbm(q + float2(3.1, 1.7), 4);
    float cl2 = fbm(q * 3.1 + float2(9.2, 4.4), 4);
    float cl3 = fbm(q * 9.0 + float2(1.2, 8.4), 3);
    float dustN = fbm(float2(lon * 3.4, lat * 11.0) + float2(7.7, 2.2), 5);
    float band = exp(-lat * lat / (2.0 * 0.13 * 0.13));
    float dust = smoothstep(-0.05, 0.38, dustN) * exp(-lat * lat / (2.0 * 0.10 * 0.10));
    float I = band * (0.5 + 0.5 * cl + 0.3 * cl2 + 0.15 * cl3) * (1.0 - 0.9 * dust);
    I += 0.2 * exp(-lat * lat / (2.0 * 0.32 * 0.32)) * (0.75 + 0.35 * cl + 0.15 * cl2);
    // bulge-ish brightening along longitude
    I *= 0.75 + 0.5 * exp(-pow(sin((lon - 0.9) * 0.5), 2.0) * 6.0);
    float3 tint = mix(float3(0.78, 0.86, 1.0), float3(1.0, 0.92, 0.78), band * 0.7);
    return max(I, 0.0) * 0.06 * tint;
}

// Analytic veiling glare / halation from the disk (screen space, HDR).
inline float3 eh_glow(float2 p) {
    float side = tanh(-p.x * 2.6);                          // +1 approaching (left)
    float dop = 1.0 + 0.7 * side;
    float ax = abs(p.x);
    float sy = 0.10 + 0.06 * ax;
    float bandG = exp(-p.y * p.y / (2.0 * sy * sy)) * exp(-ax * 0.9) * smoothstep(0.05, 0.4, ax);
    float rr = length(p);
    float haloG = exp(-pow(rr - 0.37, 2.0) / (2.0 * 0.11 * 0.11));
    float2 hc = p + float2(0.36, 0.0);
    float hal = exp(-dot(hc, hc) / (2.0 * 0.40 * 0.40));
    float wide = exp(-dot(p, p) / (2.0 * 1.0 * 1.0));
    float g = 0.05 * bandG + 0.07 * haloG + 0.025 * hal + 0.003 * wide;
    float3 tint = mix(float3(1.0, 0.52, 0.28), float3(1.0, 0.86, 0.68), 0.5 + 0.5 * side);
    return g * dop * tint;
}

// ---------------------------------------------------------------- scene
float3 scene(float2 fragCoord, WSCtx ctx) {
    float3 ro = EH_D * float3(0.0, sin(EH_ELEV), cos(EH_ELEV));
    float3 fw = normalize(-ro);
    float3 rt = normalize(cross(fw, float3(0.0, 1.0, 0.0)));
    float3 up = cross(rt, fw);
    float kf = tan(EH_FOV * (PI / 180.0) * 0.5);
    float2x2 R = ws_rot(EH_ROLL);
    float pixA = 2.0 * kf / ctx.res.y;               // angular pixel size (rad)

    float2 p0 = R * ((2.0 * fragCoord - ctx.res) / ctx.res.y - EH_HOLE);
    float2 p1 = p0 + R * float2(2.0 / ctx.res.y, 0.0);
    float2 p2 = p0 + R * float2(0.0, 2.0 / ctx.res.y);
    float3 d0 = normalize(fw + kf * (p0.x * rt + p0.y * up));
    float3 d1 = normalize(fw + kf * (p1.x * rt + p1.y * up));
    float3 d2 = normalize(fw + kf * (p2.x * rt + p2.y * up));

    float h20 = length_squared(cross(ro, d0));
    float h21 = length_squared(cross(ro, d1));
    float h22 = length_squared(cross(ro, d2));
    float lambda = -cross(ro, d0).y;                // photon L_y / E (conserved)

    float3 x0 = ro, x1 = ro, x2 = ro;
    float3 v0 = d0, v1 = d1, v2 = d2;
    float3 a0 = eh_acc(x0, h20), a1 = eh_acc(x1, h21), a2 = eh_acc(x2, h22);
    bool live1 = true, live2 = true;

    // loop-safe flow layers
    float tA = fract(ctx.t), tB = fract(ctx.t + 0.5);
    float wA = 1.0 - abs(2.0 * tA - 1.0), wB = 1.0 - wA;
    float phA = tA - 0.5, phB = tB - 0.5;
    float inv = 1.0 / sqrt(wA * wA + wB * wB);

    float3 col = float3(0.0);
    float T = 1.0;
    int state = 0;   // 0 running, 1 escaped, 2 captured, 3 opaque
    for (int i = 0; i < EH_STEPS; i++) {
        float r = length(x0);
        float dt = clamp(0.045 * r, 0.03, 2.0) / length(v0);
        float3 xp0 = x0, xp1 = x1, xp2 = x2;
        v0 += 0.5 * dt * a0; x0 += dt * v0; a0 = eh_acc(x0, h20); v0 += 0.5 * dt * a0;
        if (live1) { v1 += 0.5 * dt * a1; x1 += dt * v1; a1 = eh_acc(x1, h21); v1 += 0.5 * dt * a1; live1 = dot(x1, x1) > 1.1; }
        if (live2) { v2 += 0.5 * dt * a2; x2 += dt * v2; a2 = eh_acc(x2, h22); v2 += 0.5 * dt * a2; live2 = dot(x2, x2) > 1.1; }

        if (xp0.y * x0.y < 0.0) {
            float f = xp0.y / (xp0.y - x0.y);
            float3 hp = mix(xp0, x0, f);
            float rh = length(hp.xz);
            if (rh > EH_RIN * 0.82 && rh < EH_ROUT * 1.2) {
                float3 hp1 = eh_planeHit(xp1, x1);
                float3 hp2 = eh_planeHit(xp2, x2);
                float3 vd = normalize(x0 - xp0);
                float cosi = max(abs(vd.y), 0.015);

                EHC c;
                c.cA = eh_tc(hp, phA); c.cB = eh_tc(hp, phB);
                c.wA = wA; c.wB = wB; c.inv = inv;
                float2 e1 = eh_wrapd(eh_tc(hp1, phA) - c.cA);
                float2 e2 = eh_wrapd(eh_tc(hp2, phA) - c.cA);
                if (!live1) e1 = float2(1e3);
                if (!live2) e2 = float2(1e3);
                EHTex tx = eh_tex(c, e1 * 0.8, e2 * 0.8);

                // radial envelope: crisp-ish inner edge, wispy outer edge
                float env = smoothstep(EH_RIN * 0.86, EH_RIN * 1.08, rh)
                          * (1.0 - smoothstep(EH_ROUT * 0.42, EH_ROUT * 1.15, rh + 3.5 * tx.puff));
                float dens = tx.dens;
                float opac = mix(1.0, 0.45, smoothstep(5.0, 15.0, rh));
                float tau = env * (0.03 + 2.4 * dens * dens * (0.7 + 0.5 * tx.fil)) * opac / cosi;
                float alpha = 1.0 - exp(-tau);

                // temperature & redshift
                float xr = EH_RIN / rh;
                float F = xr * xr * xr * max(1.0 - 0.6 * sqrt(xr), 0.02);
                float Fn = F / 0.4;                     // peak at the ISCO
                float Tr = mix(2800.0, 6800.0, pow(Fn, 0.5));
                float Om = sqrt(0.5 / (rh * rh * rh));
                float g = sqrt(max(1.0 - 1.5 / rh, 0.02)) / (1.0 - Om * lambda);
                float gI = pow(g, 0.60);
                float gC = pow(g, 0.55);
                float3 bb = ws_blackbody(Tr * gC);
                float I = 2.6 * pow(Fn, 0.40) * gI * gI * gI;
                float em = (0.25 + 0.75 * pow(dens, 1.5)) * (0.85 + 0.3 * tx.fil) + 1.5 * tx.hot * dens;
                float3 S = bb * I * em;
                col += T * S * alpha;
                T *= 1.0 - alpha;
                if (T < 0.004) { state = 3; break; }
            }
        }
        float r2n = dot(x0, x0);
        if (r2n < 2.25 && dot(x0, v0) < 0.0) { state = 2; break; }
        if (r2n > 4900.0 && dot(x0, v0) > 0.0) { state = 1; break; }
    }

    if (state == 1) {
        float3 n0 = normalize(v0);
        float3 sky = eh_galaxy(n0);
        if (live1 && live2)
            sky += eh_stars(n0, normalize(v1) - n0, normalize(v2) - n0, pixA);
        col += T * sky;
    }

    col += eh_glow(p0);
    float3 c = ws_acesFitted(col * EH_EXPO);
    c = ws_saturate(c, 1.18);
    c += 0.004 * ws_grain(fragCoord, ctx.t);
    return clamp(c, 0.0, 1.0);
}
