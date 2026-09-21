// =====================================================================
//  Golden Swell — open ocean at golden hour, camera 1.5 m above the sea.
//  Units: metres. y up, camera looks toward +z. Mean sea level y = 0.
//  Earth curvature is modelled (horizon ~4.4 km away).
// =====================================================================

constant float GS_RE    = 6371e3;
constant float GS_CAMH  = 1.5;
constant float GS_FOVY  = 34.0;       // vertical field of view (deg)
constant float GS_HOR   = 0.42;       // horizon height as fraction of frame (from bottom)
constant float GS_SUNEL = 4.8;        // sun elevation (deg)
constant float GS_SUNAZ = -6.5;       // sun azimuth (deg, negative = left of frame centre)
constant float GS_SUNI  = 22.0;       // sun irradiance scale for ws_atmosphere
constant float GS_MIE   = 0.30;        // marine aerosol strength
constant float GS_EXPO  = 0.505;
#ifndef GS_DBG
#define GS_DBG 0
#endif
#ifndef GS_NOCLOUD
#define GS_NOCLOUD 0
#endif
#ifndef GS_LIVECONST
#define GS_LIVECONST 1
#endif

// cloud deck
constant float GS_CB = 1300.0;        // cloud base (m)
constant float GS_CT = 2650.0;        // top of the modelled slab (m)
// The shape functions work in units of a ~970 m thick cloud; the slab is taller so the
// biggest billows have headroom instead of being sliced flat by the layer boundary.
constant float GS_HSC = (2650.0 - 1300.0) / 970.0;
// The deck is modelled in a "field space" that is GS_QS x larger than the world, so the
// same cloud shapes sit ~30% nearer (and ~30% lower) at the same angular size: half the
// aerial haze, twice the resolved detail per cloud.
constant float GS_QS = 1.45;
constant float GS_QI = 1.0 / 1.45;

// waves (spectral Gerstner sum)
constant int   GS_NW     = 160;       // wave components
constant float GS_LAM0   = 110.0;     // longest wavelength (m)
constant float GS_LAMMIN = 0.025;     // shortest wavelength (m)
constant float GS_STEEP  = 0.016;     // per-component steepness (a*k) in the equilibrium range
constant float GS_CHOP   = 1.6;       // Gerstner choppiness
constant float GS_WIND   = 3.40;      // wind-sea propagation angle (rad), ~toward camera
constant float GS_SWELL  = 2.80;      // swell propagation angle (rad)
constant float GS_SWELL2 = 3.95;      // secondary (crossing) swell angle (rad)

inline float3 gs_sunDir() {
    float el = GS_SUNEL * (PI / 180.0), az = GS_SUNAZ * (PI / 180.0);
    return float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
}

// ------------------------------------------------------------ atmosphere helpers
// Transmittance of sunlight reaching altitude `alt` (Rayleigh + Mie, same constants as ws_atmosphere)
inline float3 gs_sunTrans(float alt, float3 sd) {
    const float Rp = 6371e3, Ra = 6471e3;
    float3 p0 = float3(0.0, Rp + alt, 0.0);
    float L = ws_raySphere(p0, sd, Ra).y;
    const int N = 12;
    float odR = 0.0, odM = 0.0;
    float tPrev = 0.0;
    for (int i = 0; i < N; i++) {
        float u1 = float(i + 1) / float(N);
        float t1 = L * u1 * u1;
        float tm = 0.5 * (tPrev + t1);
        float h = length(p0 + sd * tm) - Rp;
        float dt = t1 - tPrev;
        odR += exp(-h / 8e3) * dt;
        odM += exp(-h / 1.2e3) * dt;
        tPrev = t1;
    }
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    float kM = 21e-6 * GS_MIE;
    return exp(-(kR * odR + kM * 1.1 * odM));
}

// In-scattered light (airlight) and transmittance along a view ray from the camera to `dist`
// (same Rayleigh + Mie model as ws_atmosphere, but for a finite segment).
inline float3 gs_airlight(float3 rd, float3 sd, float dist, thread float3& Tair) {
    const float Rp = 6371e3, Ra = 6471e3;
    const float3 kR = float3(5.5e-6, 13.0e-6, 22.4e-6);
    const float kM = 21e-6 * GS_MIE;
    const int N = 10, NL = 6;
    float3 r0 = float3(0.0, Rp + 2.0, 0.0);
    float mu = dot(rd, sd), mumu = mu * mu, g = 0.78, gg = g * g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mumu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - gg) * (mumu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));
    float3 tR = float3(0.0), tM = float3(0.0);
    float odR = 0.0, odM = 0.0;
    float tPrev = 0.0;
    for (int i = 0; i < N; i++) {
        float u1 = float(i + 1) / float(N);
        float t1 = dist * u1 * u1;
        float tm = 0.5 * (tPrev + t1), dt = t1 - tPrev;
        tPrev = t1;
        float3 pos = r0 + rd * tm;
        float h = length(pos) - Rp;
        float dR = exp(-h / 8e3) * dt, dM = exp(-h / 1.2e3) * dt;
        odR += dR; odM += dM;
        float jl = ws_raySphere(pos, sd, Ra).y;
        float jR = 0.0, jM = 0.0, jp = 0.0;
        for (int j = 0; j < NL; j++) {
            float v1 = float(j + 1) / float(NL);
            float j1 = jl * v1 * v1;
            float jm = 0.5 * (jp + j1);
            float hj = length(pos + sd * jm) - Rp;
            jR += exp(-hj / 8e3) * (j1 - jp);
            jM += exp(-hj / 1.2e3) * (j1 - jp);
            jp = j1;
        }
        float3 att = exp(-(kR * (odR + jR) + kM * 1.1 * (odM + jM)));
        tR += dR * att; tM += dM * att;
    }
    Tair = exp(-(kR * odR + kM * 1.1 * odM));
    return GS_SUNI * (pR * kR * tR + pM * kM * tM);
}

inline float3 gs_skyRad(float3 rd, float3 sd) {
    float3 d = rd;
    d.y = max(d.y, 0.0005);
    d = normalize(d);
    return ws_atmosphere(d, sd, GS_SUNI, 0.78, GS_MIE, 2.0);
}

// Faint large-scale inhomogeneity of the real atmosphere: aerosol sheets and humidity
// layers mottle the gradient by a few percent and wander slightly in hue. Without this
// the zenith-to-horizon ramp reads as a vector gradient fill (and bands in PNG/EXR).
inline float3 gs_skyTex(float3 rd, float3 col) {
    float2 sq = float2(atan2(rd.x, rd.z), asin(clamp(rd.y, -1.0, 1.0)) * 1.9);
    float n1 = fbm(sq * 2.6 + float2(4.7, 1.9), 4);
    float n2 = fbm(sq * 9.5 + float2(1.3, 6.4), 3);
    float n3 = gnoise(sq * 0.85 + 3.1);
    float lumv = 0.045 * n1 + 0.018 * n2 + 0.030 * n3;
    // cooler blue bleeding into the warm band and vice versa
    float3 hue = float3(1.0 - 0.030 * n1 + 0.016 * n3, 1.0 + 0.004 * n2, 1.0 + 0.042 * n1 - 0.020 * n3);
    return col * (1.0 + lumv) * hue;
}

// ------------------------------------------------------------ clouds
inline float gs_remap(float v, float a, float b, float c, float d) {
    return c + (d - c) * clamp((v - a) / (b - a), 0.0, 1.0);
}

// 2D cloud field (0 = clear, 1 = thick) at horizontal position q (metres)
// Broken altocumulus / stratocumulus: cellular cloudlets grouped into irregular patches,
// large clear holes (thinner overhead and top-right), ragged far edge before the horizon.
inline float gs_cloudField(float2 q, int lod, thread float& FL) {
    FL = 0.0;
    // two-stage domain warp: big lazy advection, then a finer curdling warp
    float2 wa = float2(gnoise(q * (1.0 / 7000.0) + 1.3), gnoise(q * (1.0 / 7000.0) + 7.9));
    float2 wq = q + 1500.0 * wa;
    float2 wb = float2(fbm(wq * (1.0 / 2300.0) + 4.4, 3), fbm(wq * (1.0 / 2300.0) + 8.1, 3));
    wq += 620.0 * wb;

    // ---- coverage: broad patches with big clear lanes
    float cov = fbm(wq * (1.0 / 11000.0) + float2(1.3, 6.2), 3) * 0.5 + 0.5;
    cov = cov * 2.42 + 0.60;
    cov *= 0.44 + 0.56 * (fbm(wq * (1.0 / 3400.0) + float2(5.5, 1.1), 2) * 0.5 + 0.5);
    // mid-scale holes: a broken deck, not one continuous sheet
    cov *= 0.70 + 0.44 * (fbm(wq * (1.0 / 1350.0) + float2(9.1, 4.3), 2) * 0.5 + 0.5);
    float edge = q.y + 11000.0 * gnoise(q * (1.0 / 9000.0) + 2.2)
                     + 6500.0 * gnoise(q * (1.0 / 3400.0) + 5.1)
                     + 2600.0 * gnoise(q * (1.0 / 1250.0) + 8.4);
    cov *= 1.0 - 0.20 * smoothstep(16000.0, 34000.0, q.y);
    cov -= 1.75 * smoothstep(15500.0, 33000.0, edge);
    // open sky overhead: the deck only begins ~9 km out, leaving the top of the frame clear
    {   // the deck starts ~8 km out on the left and ~11 km on the right: bigger clouds
        // upper-left, quiet sky upper-right, nothing overhead to wash out the top strip
        float nearShift = 2900.0 * smoothstep(-6000.0, 3000.0, q.x);
        cov -= 1.6 * (1.0 - smoothstep(9000.0 + nearShift, 14000.0 + nearShift,
                                       q.y + 2000.0 * gnoise(q * (1.0 / 3400.0) + 6.6)));
    }
    // sparse far cloudlets low over the horizon, kept clear of the sun
    {
        float far = smoothstep(21000.0, 27000.0, q.y) * (1.0 - smoothstep(38000.0, 56000.0, q.y));
        float angq = atan2(q.x, max(q.y, 1.0));
        far *= smoothstep(0.09, 0.20, abs(angq + 0.113));
        float fc = fbm(q * (1.0 / 6000.0) + 4.1, 3) * 0.5 + 0.5;
        cov = max(cov, far * (fc * 1.05 - 0.36));
    }
    // clear lanes running away from the camera: without these the deck is one continuous
    // horizontal log across the whole frame
    {
        float lane = gnoise(float2(q.x * (1.0 / 6500.0), q.y * (1.0 / 27000.0)) + 2.9)
                   + 0.45 * gnoise(float2(q.x * (1.0 / 2400.0), q.y * (1.0 / 11000.0)) + 7.7);
        cov -= 0.36 * smoothstep(0.02, 0.70, lane);
    }
    // a scatter of small detached cloudlets for scale variety and parallax depth
    {
        float2 dq2 = wq * (1.0 / 2300.0) + 11.3;
        float w1 = clamp(1.0 - worley(dq2).x * 1.45, 0.0, 1.0);
        float m = smoothstep(0.50, 0.90, fbm(wq * (1.0 / 13000.0) + 3.7, 2) * 0.5 + 0.5);
        m *= smoothstep(10000.0, 14000.0, q.y) * (1.0 - smoothstep(24000.0, 38000.0, q.y));
        m *= 1.0 - 0.7 * smoothstep(2000.0, 9000.0, q.x);   // keep the icon zone quiet
        cov += w1 * w1 * m * 0.42;
    }
    // clear hole in the near sky (calm menu-bar strip; the near sea reflects open sky)
    cov -= 0.16 * (1.0 - smoothstep(2500.0, 8000.0, length(q - float2(-2600.0, 13000.0))));
    // calmer upper-right of the frame (desktop icons)
    cov -= 0.50 * smoothstep(1500.0, 7000.0, q.x) * (1.0 - smoothstep(15000.0, 24000.0, q.y));
    if (GS_NOCLOUD) return 0.0;
    if (cov <= 0.0) return 0.0;

    // ---- cloud streets: mild anisotropy along a slowly turning direction
    float ra = 0.55 + 0.35 * gnoise(q * (1.0 / 12000.0) + 8.8);
    float2 rdir = float2(sin(ra), cos(ra));
    float2 cq = float2(dot(wq, float2(rdir.y, -rdir.x)) * 0.62, dot(wq, rdir));

    // ---- cellular grouping: worley distance fields, but they only bias the field,
    //      the silhouette is set by the fractal term below (no round pancakes)
    float2 cw = cq * (1.0 / 780.0) + 0.85 * float2(gnoise(wq * (1.0 / 900.0)), gnoise(wq * (1.0 / 900.0) + 3.3));
    float cell1 = clamp(1.0 - worley(cw).x * 1.15, 0.0, 1.0);
    float2 cw2 = cq * (1.0 / 2100.0) + 2.7 + 0.42 * float2(gnoise(wq * (1.0 / 2600.0) + 1.1), gnoise(wq * (1.0 / 2600.0) + 6.7));
    float cell2 = clamp(1.0 - worley(cw2).x * 0.95, 0.0, 1.0);
    cell1 = cell1 * cell1 * (3.0 - 2.0 * cell1);

    // ---- fractal body: turbulent (|n|) octaves give filamented, curdled edges
    float2 dq = wq;
    if (lod == 0 && length(q) < 26000.0)
        dq += 300.0 * float2(fbm(wq * (1.0 / 700.0) + 1.7, 3), fbm(wq * (1.0 / 700.0) + 9.2, 3));
    float2 bq = dq * (1.0 / 900.0) + 3.3;
    // LOD: a pixel's rays sweep a long horizontal chord through a grazing deck, so detail
    // finer than ~1.2% of the range is pure aliasing -- fade it out instead of striping.
    float fmin = 26.0 + 0.0175 * length(q);
    float fs = 900.0;
    float s7 = 0.0, a7 = 0.5, n7 = 0.0, nLow = 0.0;
    int oct = lod == 0 ? 7 : 4;
    for (int i = 0; i < oct; i++) {
        float lw = smoothstep(0.55 * fmin, 1.6 * fmin, fs);
        float g = gnoise(bq);
        float v = (i < 2 ? g : (1.0 - 1.7 * abs(g)));
        s7 += a7 * mix(i < 2 ? 0.0 : 0.42, v, lw); n7 += a7;
        if (i == 2) nLow = s7 / n7;
        bq = WS_ROT2 * bq * 2.17 + float2(17.1, 3.7);
        a7 *= 0.56; fs *= (1.0 / 2.17);
    }
    float n = clamp((s7 / n7) * 0.62 + 0.5, 0.0, 1.0);
    nLow = clamp(nLow * 0.62 + 0.5, 0.0, 1.0);

    float grp = 0.30 * cell1 + 0.22 * cell2;
    // A wider remap window: a narrow one makes every silhouette a 2-px cliff, which the
    // near-horizontal sun then paints as a uniform bright outline. Soft, graded edges are
    // what actually reads as a lit volume.
    // a wide window: a narrow one saturates at F = 1 over large plateaus, and every
    // plateau becomes a flat-topped box with vertical walls
    FL = gs_remap(cov * (grp + 0.80 * nLow), 0.400, 0.860, 0.0, 1.0);
    float F  = gs_remap(cov * (grp + 0.80 * n),    0.400, 0.860, 0.0, 1.0);
    return F;
}

// Billow noise: sum of |gradient noise| -- puffy, cauliflower lobes. Worley cells were
// the wrong primitive for cloud tops: each cell is literally a cone with straight ridge
// lines, which builds faceted, polygonal mesas.
inline float gs_billow(float2 p, int oct) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < oct; i++) {
        float g = gnoise(p);
        // smooth |n|: a raw absolute value leaves a crease, and its maxima are cones
        s += a * (1.0 - sqrt(g * g + 0.045));
        n += a;
        p = WS_ROT2 * p * 2.11 + float2(9.3, 4.7);
        a *= 0.52;
    }
    return s / n;
}

// p = (x, altitude, z) in metres. lod 0 = full detail, 1 = cheap.
// Returns density; topOut = normalised height of the local cloud top (for ambient occlusion)
inline float gs_cloudDensT(float3 p, int lod, thread float& topOut, thread float& Fout) {
    topOut = 0.0; Fout = 0.0;
    float h = (p.y - GS_CB) / (GS_CT - GS_CB);
    if (h <= 0.0 || h >= 1.0) return 0.0;
    h *= GS_HSC;
    float rng = length(p.xz);
    float FL;
    float F = gs_cloudField(p.xz * GS_QS, lod, FL);
    Fout = F;
    if (F <= 0.0) return 0.0;
    // --- boundary relief. The old version faded ALL of it out beyond ~16 km, which left the
    // far two thirds of the deck as flat-topped extruded mesas. Instead each octave gets its
    // own range limit, so coarse lobes (hundreds of metres, tens of pixels even at 25 km)
    // survive everywhere and only the fine mottling drops out.
    // The camera is 1.5 m up and the deck is 1.3 km up: almost everything we see is the
    // UNDERSIDE. Built from billow (|n|) octaves down to ~50 m so it reads as lumpy
    // pouches -- smooth gradient-noise octaves give sand dunes with contour terraces.
    float f0 = 1.0;                                             // 1.2 km lobes: always
    float f1 = 1.0 - smoothstep(20000.0, 40000.0, rng);         // 430 m lobes
    float f2 = lod == 0 ? 1.0 - smoothstep(11000.0, 26000.0, rng) : 0.0;  // 150 m
    float f3 = lod == 0 ? 1.0 - smoothstep(5500.0, 14000.0, rng) : 0.0;   // 55 m
    float2 wp = p.xz + 300.0 * float2(gnoise(p.xz * (1.0 / 850.0) + 5.5),
                                      gnoise(p.xz * (1.0 / 850.0) + 2.1));
    float lobeA = gs_billow(wp * (1.0 / 1500.0) + 2.3, lod == 0 ? 3 : 2);
    float lobeB = gs_billow(wp * (1.0 / 430.0)  + 7.1, 2);
    float und = 0.098 * (gs_billow(p.xz * (1.0 / 3600.0) + 1.7, 2) - 0.74)
              + f0 * 0.125 * (lobeA - 0.74)
              + f1 * 0.080 * (lobeB - 0.74)
              + f2 * 0.052 * (gs_billow(p.xz * (1.0 / 150.0) + 3.3, 2) - 0.74)
              + f3 * 0.030 * (gs_billow(p.xz * (1.0 / 55.0)  + 6.2, 1) - 0.74);
    float gA = gnoise(p.xz * (1.0 / 1500.0) + 3.1);
    float gB = gnoise(p.xz * (1.0 / 520.0)  + 8.3);
    float gC = gnoise(p.xz * (1.0 / 128.0)  + 9.0);
    float baseUnd = und - 0.030 * gA - f1 * 0.024 * gB - f2 * 0.018 * gC;
    float bot = clamp(0.235 + baseUnd + 0.05 * (1.0 - FL), 0.02, 0.40);
    float fv = mix(FL, F, 0.55);
    // large-scale height variation: some groups tower, others stay flat pancakes
    float tow = 0.62 + 0.70 * (fbm(p.xz * (1.0 / 3600.0) + 1.9, 2) * 0.5 + 0.5);
    float top = bot + 0.07 + 0.25 * fv * (0.72 + 0.62 * fv) * tow;
    top += fv * (f0 * (0.230 * (lobeA - 0.48) + 0.055 * gA)
               + f1 * (0.125 * (lobeB - 0.48) + 0.030 * gB)
               + f2 * 0.030 * gC);
    topOut = top / GS_HSC;
    // wide, soft vertical ramps: a hard base plane draws a bright iso-line at grazing angles
    float prof = smoothstep(bot, bot + 0.115, h) * (1.0 - smoothstep(top - 0.24, top, h));
    if (prof <= 0.0) return 0.0;
    // isotropic scales only: a squashed vertical scale smears into wood-grain stripes
    // when the deck is seen edge-on.
    float3 pd = p * (1.0 / 380.0);
    pd += 0.42 * float3(gnoise(p * (1.0 / 900.0) + 4.1),
                        gnoise(p * (1.0 / 900.0) + 8.3),
                        gnoise(p * (1.0 / 900.0) + 1.6));
    float det = fbm(pd, lod == 0 ? 4 : 2);
    float er = clamp(0.5 - 1.55 * det, 0.0, 1.0);
    if (lod == 0) {
        // fine mottling fades out with range (it would alias into bright hairlines)
        float dfade = 1.0 - smoothstep(12000.0, 30000.0, rng);
        float det2 = (0.60 * gnoise(p * (1.0 / 150.0) + 7.7)
                    + 0.40 * gnoise(p * (1.0 / 74.0) + 2.4)) * dfade;
        er = clamp(er + dfade * (0.22 - 0.44 * det2), 0.0, 1.0);
    }
    // Erode the COVERAGE with 3D noise, not the finished density: that makes the
    // silhouette itself three-dimensional. Eroding density only shifts an extruded 2D
    // outline slightly, which is why the deck kept reading as vertical walls and
    // topographic terraces.
    float Fe = clamp(F * 1.40 - 0.95 * er * er, 0.0, 1.0);
    if (Fe <= 0.0) return 0.0;
    float d = sqrt(Fe) * prof;
    // A gentle gain on the final ramp: a steep one turns every silhouette into a 2-px
    // cliff, which a near-horizontal sun then paints as a uniform cel-shading outline.
    d = clamp(d * 1.50 - 0.13, 0.0, 1.9);
    return d;
}
inline float gs_cloudDens(float3 p, int lod) { float t, f; return gs_cloudDensT(p, lod, t, f); }

inline float gs_hg(float c, float g) {
    float gg = g * g;
    return (1.0 - gg) / (4.0 * PI * pow(1.0 + gg - 2.0 * g * c, 1.5));
}

// Volumetric cloud deck. Coarse steps through empty space, fine steps inside cloud.
// returns (rgb scattered radiance, transmittance); dist = mean scattering distance
inline float4 gs_clouds(float3 rd, float3 sd, float3 sunCol, float3 ambTop, float3 ambBot,
                        int steps, int lsteps, int lod, float jitter, thread float& dist) {
    float3 ro = float3(0.0, GS_RE + GS_CAMH, 0.0);
    dist = 0.0;
    if (rd.y < 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    float t0 = ws_raySphere(ro, rd, GS_RE + GS_CB).y;
    float t1 = ws_raySphere(ro, rd, GS_RE + GS_CT).y;
    t1 = min(t1, t0 + 9000.0);
    if (t0 > 90000.0) return float4(0.0, 0.0, 0.0, 1.0);
    float dtc = (t1 - t0) / float(steps);
    // empty-space step. It must be smaller than the cloud features it is hunting for:
    // a 340 m coarse step through a broken deck skips whole cloudlets depending on the
    // ray's random start phase, which is what stippled every silhouette.
    if (lod == 0) dtc = min(dtc, clamp(t0 * 0.0048, 50.0, 115.0));
    // fine step: kept short on purpose. The stochastic start phase makes the integrator
    // noisy wherever the integrand swings inside one step, which at a backlit fringe is
    // orders of magnitude -- that was the sand-grain speckle on every cloud edge.
    float dtf = lod == 0 ? clamp(t0 * 0.0011, 7.0, 28.0) : max(dtc * 0.40, 34.0);
    dtf = min(dtf, dtc);
    int maxIt = lod == 0 ? 420 : steps + 14;
    float mu = dot(rd, sd);
    float T = 1.0;
    float3 L = float3(0.0);
    float wsum = 0.0, dsum = 0.0;
    const float sigma = 0.040;                       // extinction per metre at density 1
    // (0.04/m -> mean free path 25 m, a realistic stratocumulus. The draft used 0.155,
    //  a 6 m mfp: every edge was a binary bright/black step two pixels wide.)
    float phs[3];
    for (int o = 0; o < 3; o++) {
        float g = 0.72 * pow(0.52, float(o));
        phs[o] = mix(gs_hg(mu, g), gs_hg(mu, -0.24 * pow(0.5, float(o))), 0.26);
    }
    float t = t0 + dtc * jitter;
    float tScan = t0;          // furthest point already scanned at fine resolution
    bool fine = false;
    int empty = 0;
    for (int i = 0; i < maxIt; i++) {
        if (t > t1 || T < 0.01) break;
        float3 P = ro + rd * t;
        float alt = length(P) - GS_RE;
        float3 pc = float3(P.x, alt, P.z);
        float ctop, cF;
        float d = gs_cloudDensT(pc, fine ? lod : 1, ctop, cF);
        if (!fine && d > 0.0) {                   // entered a cloud: back up and refine
            fine = true; empty = 0;
            // never back up into a stretch the fine march already integrated: the old
            // code re-entered up to a whole coarse step behind itself every time the
            // fine/coarse hysteresis flipped, double-counting extinction by a
            // jitter-dependent amount -- which is what stippled the whole deck
            t = max(tScan, t - dtc) + dtf * jitter;
            continue;
        }
        // Adaptive: hold the optical depth per step near 0.3 whatever the density.
        // A fixed step is either too coarse in the dense cores (each step then swallows a
        // large fraction of the ray, and the jittered start phase turns that into speckle)
        // or wastes the whole iteration budget crossing the thin fringes.
        // where the 2D coverage column is empty there is no cloud at ANY altitude, so
        // the empty-space step can be much longer -- this is most of the sky
        float dt = fine ? min(min(dtf, dtc), 0.30 / max(sigma * d, 0.0005))
                        : (cF <= 0.0 ? dtc * 2.6 : dtc);
        if (d > 0.003) {
            empty = 0;
            float tauL = 0.0;
            // The sun is ~5 deg up, so light travels kilometres THROUGH the deck before
            // reaching a sample. The march is also CONE-SPREAD: each step is offset
            // laterally on a golden-angle spiral by roughly the transport mean free path
            // (mfp/(1-g) ~ 150 m), which is where a real cloud's soft silver lining comes
            // from. A pencil-thin march gives the cel-shaded outline instead.
            float ls = lod == 0 ? 55.0 : 130.0;
            float3 sT = normalize(cross(sd, float3(0.0, 1.0, 0.0)));
            float3 sB = cross(sd, sT);
            float3 lp = pc;
            float trav = 0.0;
            for (int j = 0; j < lsteps; j++) {
                lp += sd * ls; trav += ls;
                float ja = 2.39996 * float(j) + 0.7;
                float rr = min(12.0 + 0.055 * trav, 120.0);
                // squashed vertically: the deck is only ~1 km thick, and a tall offset
                // walks the light sample out of the cloud and fakes a sunlit core
                float3 lq = lp + (sT * cos(ja) + sB * (0.28 * sin(ja))) * rr;
                tauL += gs_cloudDens(lq, 1) * ls;
                ls *= 1.60;
            }
            // Beyond ~2 km the shadow ray is carried by the SMOOTH 2D coverage field.
            // A point sample of the 3D density 5 km away is effectively a coin flip whose
            // weight is kilometres of optical depth, and the ray-start jitter turned that
            // coin flip into per-pixel speckle over the whole deck.
            {
                float fl;
                float3 la = pc + sd * 3400.0, lb = pc + sd * 7600.0;
                float Fa = la.y < GS_CT ? gs_cloudField(la.xz * GS_QS, 1, fl) : 0.0;
                float Fb = lb.y < GS_CT ? gs_cloudField(lb.xz * GS_QS, 1, fl) : 0.0;
                tauL += 0.33 * (Fa * 3000.0 + Fb * 4200.0);
            }
            tauL *= sigma;
            float hfr = clamp((alt - GS_CB) / (GS_CT - GS_CB), 0.0, 1.0);
            float3 sunS = float3(0.0);
            float a = 1.0, b = 1.0;
            for (int o = 0; o < 3; o++) {
                sunS += a * exp(-tauL * b) * phs[o];
                a *= 0.26; b *= 0.155;
            }
            // deep cores keep a faint, structured warm glow (lateral multiple scattering)
            sunS += 0.013 * exp(-tauL * 0.016) * phs[2];
            sunS *= 0.98;
            // sky light from above is occluded by the cloud mass overhead; bases see the sea + horizon
            float tauUp = sigma * d * max(ctop - hfr, 0.0) * (GS_CT - GS_CB) * 0.8;
            float tauDn = sigma * d * hfr * (GS_CT - GS_CB) * 0.8;
            float3 amb = ambTop * (exp(-tauUp) * 0.6 + 0.4 * exp(-tauUp * 0.25)) * 0.8
                       + ambBot * (exp(-tauDn) * 0.6 + 0.4 * exp(-tauDn * 0.25));
            float3 S = sunCol * sunS + amb;
            if (GS_DBG == 9) S = sunCol * sunS;
            if (GS_DBG == 10) S = amb;
            float se = d * sigma;
            float Ts = exp(-se * dt);
            L += T * S * (1.0 - Ts);                 // energy-conserving (albedo 1)
            wsum += T * (1.0 - Ts); dsum += T * (1.0 - Ts) * t;
            T *= Ts;
        } else if (fine) {
            empty++;
            if (empty > 7) fine = false;
        }
        t += dt;
        if (fine) tScan = max(tScan, t);
    }
    dist = wsum > 0.0 ? dsum / wsum : t0;
    return float4(L, T);
}

// ------------------------------------------------------------ ocean
// Spectral sea: GS_NW Gerstner components, stratified in log-wavenumber (long -> short),
// Phillips-like equilibrium range (constant steepness per component), directional spreading
// that widens for short waves, a gentle swell, and wind-roughness patches for short waves.
inline void gs_wave(int i, thread float2& dir, thread float& k, thread float& a, thread float& ph) {
    float fi = float(i);
    float4 h = hash44(float4(fi, 17.0, 3.0, 11.0));
    float u = (fi + h.x) / float(GS_NW);
    k = (TAU / GS_LAM0) * exp(u * log(GS_LAM0 / GS_LAMMIN));
    float lam = TAU / k;
    // directional spreading (approx. gaussian via sum of two uniforms)
    float g = (h.y + h.w - 1.0);
    bool swell = (lam > 45.0) && (h.z < 0.6);
    bool swell2 = (lam > 40.0) && !swell && (h.z < 0.85);
    // directional spreading: ~±20° typical at the peak, nearly isotropic for the short waves
    float spread = mix(0.95, 1.45, smoothstep(40.0, 1.0, lam));
    float ang = swell ? GS_SWELL + 0.42 * g : swell2 ? GS_SWELL2 + 0.52 * g : GS_WIND + spread * g * 1.4;
    dir = float2(sin(ang), cos(ang));
    // steepness: JONSWAP-like peak ~ 28 m, equilibrium range below, slightly calmer 0.3-5 m band,
    // stronger capillary tail
    float lg = log(lam / 28.0);
    float peak = 1.0 + 0.8 * exp(-lg * lg / 0.16) + 0.42 * exp(-lg * lg / 1.9);
    float steep = GS_STEEP * smoothstep(GS_LAM0 * 1.05, 28.0, lam) * peak
                * (1.0 - 0.2 * smoothstep(8.0, 4.0, lam) * smoothstep(0.15, 0.4, lam))
                * (1.0 + 0.25 * smoothstep(1.5, 0.2, lam));
    if (swell) steep = 0.0155;
    if (swell2) steep = 0.0105;
    a = steep / k;
    ph = fract(h.z * 7.13 + h.x * 3.1) * TAU;
}

inline float gs_roughPatch(float2 x) {
    float big = fbm(x * (1.0 / 160.0) + float2(7.0, 2.0), 3);
    float sml = fbm(x * (1.0 / 28.0) + float2(3.0, 9.0), 3);
    float v = clamp(0.55 + 0.75 * big + 0.35 * sml, 0.0, 1.0);
    return 0.04 + 1.6 * v * v;
}
inline float gs_fw(float lam, float fp) { return smoothstep(1.2, 2.5, lam / max(fp, 1e-4)); }

// Horizontal Gerstner displacement at undisplaced position x0 (waves longer than lamMin)
inline float2 gs_disp(float2 x0, float fp, float lamMin) {
    float2 D = float2(0.0);
    for (int i = 0; i < GS_NW; i++) {
        float2 dir; float k, a, ph;
        gs_wave(i, dir, k, a, ph);
        float lam = TAU / k;
        if (lam < lamMin) break;
        float w = gs_fw(lam, fp);
        if (w <= 0.0) break;
        float th = dot(dir, x0) * k + ph;
        D += dir * (GS_CHOP * a * w * sin(th));
    }
    return D;
}

// Height of the sea at world xz (fixed-point Gerstner inversion)
inline float gs_seaH(float2 x, float fp, float lamMin, int iters) {
    float2 x0 = x;
    for (int it = 0; it < iters; it++) x0 = x + gs_disp(x0, fp, lamMin);
    float h = 0.0;
    for (int i = 0; i < GS_NW; i++) {
        float2 dir; float k, a, ph;
        gs_wave(i, dir, k, a, ph);
        float lam = TAU / k;
        if (lam < lamMin) break;
        float w = gs_fw(lam, fp);
        if (w <= 0.0) break;
        h += a * w * cos(dot(dir, x0) * k + ph);
    }
    return h;
}

struct GSSurf { float3 n; float var; float h; float hw; float jac; float rough; };

inline GSSurf gs_seaSurf(float2 x, float fp) {
    GSSurf s;
    float2 x0 = x;
    for (int it = 0; it < 3; it++) x0 = x + gs_disp(x0, fp, 1.0);
    float rp = gs_roughPatch(x);
    fp = max(fp, 0.02);
    float3 nrm = float3(0.0, 1.0, 0.0);
    float h = 0.0, hw = 0.0, var = 0.0;
    float jxx = 1.0, jzz = 1.0, jxz = 0.0;
    for (int i = 0; i < GS_NW; i++) {
        float2 dir; float k, a, ph;
        gs_wave(i, dir, k, a, ph);
        float lam = TAU / k;
        float amp = a * (lam < 5.0 ? mix(1.0, rp, smoothstep(5.0, 1.2, lam)) : 1.0);
        float w = gs_fw(lam, fp);
        float st = amp * k;
        var += (1.0 - w * w) * st * st * 0.5;
        if (w <= 0.0) continue;
        amp *= w;
        float th = dot(dir, x0) * k + ph;
        float S = sin(th), C = cos(th);
        float wa = k * amp;
        float q = GS_CHOP;
        h += amp * C;
        if (lam < 40.0) hw += amp * C;
        nrm.x += dir.x * wa * S;
        nrm.z += dir.y * wa * S;
        nrm.y -= q * wa * C;
        jxx -= q * wa * dir.x * dir.x * C;
        jzz -= q * wa * dir.y * dir.y * C;
        jxz -= q * wa * dir.x * dir.y * C;
    }
    var += 0.0035 * rp;             // capillary micro-roughness (never resolved)
    s.n = normalize(float3(nrm.x, max(nrm.y, 0.05), nrm.z));
    s.var = var;
    s.h = h;
    s.hw = hw;
    s.jac = jxx * jzz - jxz * jxz;
    s.rough = rp;
    return s;
}

// ------------------------------------------------------------ shading helpers
inline float gs_ggx(float nh, float a2) {
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}
inline float gs_fresnel(float c) {
    float m = clamp(1.0 - c, 0.0, 1.0);
    float m2 = m * m;
    return 0.02 + 0.98 * m2 * m2 * m;
}

// ------------------------------------------------------------ scene
float3 scene(float2 fragCoord, WSCtx ctx) {
#ifdef GS_CROP
    // 1:1 window of the 3840x2400 frame; GS_CROP = top-left corner (x, y from top)
    fragCoord = fragCoord + float2(GS_CROP.x, 2400.0 - GS_CROP.y - ctx.res.y);
    ctx.res = float2(3840.0, 2400.0);
#endif
    float3 sd = gs_sunDir();
    float2 p = (2.0 * fragCoord - ctx.res) / ctx.res.y;
    if (GS_DBG == 8) {   // top-down map of the cloud field, 50 km wide, camera at bottom centre
        float2 q = float2(p.x, p.y + 1.0) * 25000.0 * float2(1.0, 0.8);
        float FLd; float F = gs_cloudField(q, 0, FLd);
        float3 c = float3(F);
        // frame wedge
        float ang = atan2(q.x, q.y);
        if (abs(ang) < 0.47 && abs(abs(ang) - 0.47) < 0.004) c = float3(1, 0, 0);
        return c;
    }
    if (GS_DBG == 6 || GS_DBG == 7) {   // top-down view of the sea
        float2 xz = float2(p.x, p.y) * 30.0 + float2(0.0, 80.0);
        float fpd = 60.0 / ctx.res.y;
        GSSurf s = gs_seaSurf(xz, fpd);
        float3 n = s.n;
        float h0 = s.h;
        if (GS_DBG == 7) return float3(clamp(h0 * 0.8 + 0.5, 0.0, 1.0), clamp(h0 * 0.8 + 0.5, 0.0, 1.0), clamp(h0 * 0.8 + 0.5, 0.0, 1.0) + smoothstep(0.4, 0.0, s.jac));
        float3 L = normalize(float3(0.4, 0.8, 0.3));
        float dif = max(dot(n, L), 0.0);
        return clamp(float3(0.15, 0.3, 0.45) * (0.2 + dif) * 0.8, 0.0, 1.0);
    }
    float kf = tan(GS_FOVY * (PI / 180.0) * 0.5);
    float dip = sqrt(2.0 * GS_CAMH / GS_RE);
    float pitch = atan((1.0 - 2.0 * GS_HOR) * kf) - dip;
    float3 f = float3(0.0, sin(pitch), cos(pitch));
    float3 r = float3(1.0, 0.0, 0.0);
    float3 u = cross(f, r);
    float3 rd = normalize(f + (p.x * r + p.y * u) * kf);
    float3 ro = float3(0.0, GS_CAMH, 0.0);
    float pixAng = 2.0 * kf / ctx.res.y;
    uint2 jb = as_type<uint2>(fragCoord);
    float jit = float(ws_pcg(jb.x ^ ws_pcg(jb.y + 0x9e3779b9u))) * WS_INV_U32;

    // light
#if GS_LIVECONST
    float3 sunE0 = GS_SUNI * gs_sunTrans(2.0, sd);                       // direct irradiance at sea level
    float3 sunEc = GS_SUNI * gs_sunTrans(0.5 * (GS_CB + GS_CT), sd);     // at the cloud deck
#else
    // image constants measured with GS_DBG 12 (sun 4.8 deg, Mie 0.6) — re-measure if lighting changes
    const float3 sunE0 = float3(11.612, 6.236, 2.859);
    const float3 sunEc = float3(14.551, 8.799, 4.682);
#endif
    float3 sdH = normalize(float3(sd.x, 0.0, sd.z));
    // sky-dome ambient for clouds: from above (blue) and from below (horizon glow + dark sea)
#if GS_LIVECONST
    float3 skyUp = 0.5 * (gs_skyRad(normalize(float3(0.0, 0.8, -0.6)), sd) + gs_skyRad(normalize(sdH + float3(0.0, 1.2, 0.0)), sd));
    float3 skyHz = 0.5 * (gs_skyRad(normalize(sdH + float3(0.0, 0.05, 0.0)), sd) + gs_skyRad(normalize(float3(-sdH.x, 0.05, -sdH.z)), sd));
    float3 skyZen = gs_skyRad(float3(0.0, 1.0, 0.0), sd);
#else
    const float3 skyUp  = float3(0.08253, 0.13814, 0.16418);
    const float3 skyHz  = float3(4.28953, 2.25371, 0.94524);
    const float3 skyZen = float3(0.04568, 0.07916, 0.09646);
#endif
    float3 ambTop = mix(skyUp, skyZen, 0.45) * 1.55;
    float muV = max(dot(rd, sd), 0.0);
    // cloud bases see the dark sea (reflecting the blue upper sky) plus the horizon glow,
    // which forward-scatters toward the viewer mostly in the sun's direction
    // bases see the dark blue sea plus the horizon glow; the glow only reaches them
    // near the sun's azimuth, so the far side of the band stays blue-grey
    float3 ambBot = skyZen * float3(1.55, 1.85, 2.20) + skyHz * 0.0135 * (0.20 + 7.5 * pow(muV, 6.0));

    float3 col;
    if (GS_DBG == 12) {   // constant light values encoded as swatches (decoded by readvals.py)
        int ix = int(fragCoord.x / ctx.res.x * 6.0);
        float2 uv = fragCoord / ctx.res;
        float sdist3;
        float4 sc = gs_clouds(sd, sd, sunEc, ambTop, ambBot, 8, 1, 1, 0.5, sdist3);
        float3 v = ix == 0 ? sunE0 : ix == 1 ? sunEc : ix == 2 ? skyUp : ix == 3 ? skyHz : ix == 4 ? skyZen : float3(sc.a);
        float sc2 = ix == 0 || ix == 1 || ix == 3 ? 32.0 : ix == 5 ? 1.0 : 2.0;
        return v / (uv.y > 0.5 ? sc2 : sc2 * 0.125);
    }
    if (GS_DBG == 11) {
        float2 uv = fragCoord / ctx.res;
        float sdist3;
        float4 sc = gs_clouds(sd, sd, sunEc, ambTop, ambBot, 8, 1, 1, 0.5, sdist3);
        float3 c = uv.x < 0.2 ? skyZen : uv.x < 0.4 ? ambTop : uv.x < 0.6 ? ambBot : uv.x < 0.8 ? sunE0 * 0.05 : float3(sc.a);
        return ws_acesFitted(c * (uv.y > 0.5 ? GS_EXPO : GS_EXPO * 4.0));
    }

    // ---------------------------------------------------- ocean intersection
    bool hitSea = false;
    float tHit = 0.0;
    const float HMAX = 2.6, HMIN = -2.6;
    if (rd.y < 0.0) {
        float t = max(0.0, (GS_CAMH - HMAX) / -rd.y);
        float tPrev = t;
        for (int i = 0; i < 180; i++) {
            float3 pp = ro + rd * t;
            float fp = t * pixAng / sqrt(max(-rd.y, 0.002));
            float curv = (t * t) / (2.0 * GS_RE);
            float d = pp.y + curv - gs_seaH(pp.xz, fp * 1.5, 2.0, 1);
            if (d < 0.0) {
                float a = tPrev, b = t;
                for (int j = 0; j < 7; j++) {
                    float m = 0.5 * (a + b);
                    float3 pm = ro + rd * m;
                    float fpm = m * pixAng / sqrt(max(-rd.y, 0.002));
                    float dm = pm.y + m * m / (2.0 * GS_RE) - gs_seaH(pm.xz, fpm * 1.5, 2.0, 2);
                    if (dm < 0.0) b = m; else a = m;
                }
                tHit = 0.5 * (a + b);
                hitSea = true;
                break;
            }
            tPrev = t;
            float step = d / (-rd.y + 0.3);
            float minStep = 0.02 + t * 0.002 + t * t * pixAng * 0.3;
            t += max(step, minStep);
            if (t > 7000.0 || pp.y + curv < HMIN) break;
        }
    }

    if (hitSea) {
        float3 P = ro + rd * tHit;
        float fp = tHit * pixAng / sqrt(max(-rd.y, 0.002));
        GSSurf s = gs_seaSurf(P.xz, fp);
        float var = s.var;
        float h0 = s.h;
        float3 n = s.n;
        float3 v = -rd;
        // at grazing angles the visible facets tilt toward the viewer
        float sig = sqrt(var);
        float3 toCam = normalize(float3(v.x, 0.0, v.z));
        float3 ne = normalize(n + toCam * sig * 0.55 * (1.0 - smoothstep(0.0, 0.3, dot(n, v))));
        float nv = max(dot(ne, v), 1e-3);
        float3 R = reflect(rd, ne);
        // sub-pixel roughness: scatter the mirror ray over the unresolved slope lobe.
        // Without this the long resolved swell paints continuous "brushed metal" streaks.
        {
            uint2 rb = as_type<uint2>(fragCoord + 13.37);
            uint h1 = ws_pcg(rb.x ^ ws_pcg(rb.y + 0x85ebca6bu));
            float u1 = float(h1) * WS_INV_U32;
            float u2 = float(ws_pcg(h1 + 0xc2b2ae35u)) * WS_INV_U32;
            float gr = min(sqrt(-2.0 * log(max(u1, 1e-4))), 2.4);
            float3 Tb = normalize(cross(R, float3(0.0, 1.0, 0.0)) + 1e-4);
            float3 Bb = cross(R, Tb);
            // a floor here matters: where the swell is smooth the mirror reflection
            // paints continuous brushed-metal combing, which is the off-sun artifact
            float spr = min(sig, 0.16) * 1.35 + 0.018 + 0.030 * smoothstep(200.0, 1200.0, tHit);
            R += (Tb * (gr * cos(TAU * u2)) + Bb * (gr * sin(TAU * u2))) * spr;
            R.y = max(R.y, 0.004);
        }
        if (R.y < 0.0) R.y = -R.y * 0.55;
        R = normalize(R);
        float F = gs_fresnel(nv);
        float3 skyR = gs_skyRad(R, sd);
        float cd;
        float4 cl = gs_clouds(R, sd, sunEc, ambTop, ambBot, 22, 4, 1, jit, cd);
        float hzR = 1.0 - exp(-cd / 34000.0);
        float3 reflCol = mix(cl.rgb + cl.a * skyR, skyR, hzR);
        // Sun specular (GGX with unresolved slope variance). The roughness floor is tied
        // to the pixel footprint: without it the foreground glints are far narrower than a
        // pixel and the regular Gerstner lattice beats into a diagonal moire grid.
        float fpm = fp * 1.5;                                   // metres of sea per pixel
        float a2min = 0.0026 + 0.055 * fpm / (fpm + 0.10);
        float a2 = clamp(var + a2min * a2min * 3.0 + 0.0022, 0.0030, 0.5);
        float3 hv = normalize(sd + v);
        float nl = max(dot(n, sd), 0.0);
        float nh = max(dot(n, hv), 0.0);
        float nvs = max(dot(n, v), 1e-3);
        float D = gs_ggx(nh, a2);
        float Fs = gs_fresnel(max(dot(hv, v), 0.0));
        float k2 = a2 * 0.5;
        float G = (nl / (nl * (1.0 - k2) + k2)) * (nvs / (nvs * (1.0 - k2) + k2));
        float3 spec = sunE0 * D * Fs * G / (4.0 * nvs + 1e-3);
        // water body (upwelling light) + light transmitted through backlit crests
        float3 Ed = sunE0 * sd.y + skyZen * 3.0 + skyHz * 0.35;
        // upwelling light from the water body. It is the only cool element competing
        // with a sky that is amber from horizon to zenith angle, and it is what keeps
        // the off-sun sea marine blue-grey instead of mauve.
        float3 deep = float3(0.0022, 0.0116, 0.0208) * Ed * 5.4;
        float3 rdH = normalize(float3(rd.x, 0.0, rd.z));
        float back = pow(clamp(dot(rdH, sdH), 0.0, 1.0), 2.0);
        float crest = smoothstep(0.16, 0.40, s.hw) * smoothstep(0.55, 0.14, s.jac);
        float face = smoothstep(0.10, 0.42, dot(n, -sdH));                // face tilted toward the camera, away from the sun
        float3 trans = float3(0.20, 0.62, 0.58);                          // water absorption on the sun's path
        float3 sss = trans * sunE0 * 0.050 * back * crest * face * smoothstep(240.0, 12.0, tHit);
        float3 body = (deep + sss) * (1.0 - F);
        col = reflCol * F + spec + body;
        // foam: compressed Gerstner crests + faint wind-aligned streaks
        {
            float2 wdir = float2(sin(GS_WIND), cos(GS_WIND));
            float2 fq = float2(dot(P.xz, wdir), dot(P.xz, float2(-wdir.y, wdir.x)));
            float streak = fbm(float2(fq.x * 0.17, fq.y * 1.7) + float2(3.1, 8.4), 5) * 0.5 + 0.5;
            float speck = fbm(P.xz * 5.5 + 11.0, 3) * 0.5 + 0.5;
            float bub = fbm(P.xz * 26.0 + 4.7, 3) * 0.5 + 0.5;       // bubble texture
            // the Jacobian term used to paint smooth blobs that read as brown stains;
            // keep it faint and break it with bubble texture
            float cap = smoothstep(0.52, 0.12, s.jac) * (0.20 + 1.15 * speck) * (0.35 + 0.95 * bub);
            float lace = smoothstep(0.58, 0.82, streak) * smoothstep(0.40, 0.76, speck)
                       * smoothstep(0.03, 0.18, s.hw) * (0.45 + 0.75 * bub);
            float foam = clamp(cap + lace, 0.0, 1.0) * smoothstep(1500.0, 220.0, tHit);
            foam *= 0.44;
            // foam is a white lambertian scatterer seeing the WHOLE sky, not a sliver of
            // it: underlit, it renders as a brown stain instead of sunlit sea-foam
            float3 foamE = sunE0 * clamp(dot(n, sd) * 0.8 + 0.26, 0.0, 1.0) + skyZen * 4.2 + skyHz * 1.05;
            float3 foamCol = foamE * (0.85 / PI);
            col = mix(col, foamCol, foam);
        }
        if (GS_DBG == 1) return n * 0.5 + 0.5;
        if (GS_DBG == 2) return ws_acesFitted(spec * GS_EXPO);
        if (GS_DBG == 3) return ws_acesFitted(reflCol * F * GS_EXPO);
        if (GS_DBG == 4) return float3(sig * 3.0, F, 0.0);
        // aerial perspective over the sea
        float3 hazeCol = gs_skyRad(normalize(float3(rd.x, 0.002, rd.z)), sd);
        float haze = 1.0 - exp(-tHit / 24000.0);
        col = mix(col, hazeCol, haze);
    } else {
        // ---------------------------------------------------- sky
        float3 sky = gs_skyTex(rd, gs_skyRad(rd, sd));
        float3 sun = ws_sunDisk(rd, sd, 0.30, sunE0 * 2.2e3);
        float cd;
        float4 cl = gs_clouds(rd, sd, sunEc, ambTop, ambBot, 32, 7, 0, jit, cd);
        // Aerial perspective as a blend toward the sky radiance in the same direction.
        // (The previous explicit airlight integral over-counted against ws_atmosphere and
        //  clamped to the sky, so every cloud was washed to within a few percent of the
        //  background -- no lighting story survived.)
        float hz = 1.0 - exp(-cd / 27000.0);
        col = mix(cl.rgb + cl.a * sky, sky, hz) + cl.a * sun;
        if (GS_DBG == 3) col = sky;
    }

    // Camera/atmosphere point spread around the sun. Evaluated per channel with slightly
    // different widths: the blown core fringes white -> gold -> amber over ~100 px instead
    // of ending at a hard circle, which is the classic CG tell.
    {
        float ang = acos(clamp(dot(rd, sd), -1.0, 1.0));
        float3 w = float3(1.34, 1.0, 0.80);
        float3 glare = float3(0.0);
        glare += 0.62 * exp(-ang / (0.0085 * w));
        glare += 0.46 * exp(-ang / (0.021  * w));
        glare += 0.15 * exp(-ang / (0.055  * w));
        glare += 0.045 * exp(-ang / (0.15   * w));
        glare += 0.012 * exp(-ang / (0.55   * w));
        col += sunE0 * glare;
    }
    col *= GS_EXPO;
    col = ws_acesFitted(col);
    // gentle photographic grade: a touch of saturation, cool shadows, warm highlights
    col = max(ws_saturate(col, 1.12), 0.0);
    float lum = ws_luma(col);
    col += float3(-0.010, 0.000, 0.018) * (1.0 - smoothstep(0.0, 0.35, lum)) * smoothstep(0.0, 0.05, lum);
    col *= mix(float3(1.0), float3(1.02, 1.0, 0.97), smoothstep(0.3, 0.9, lum));
    col = mix(col, col * col * (3.0 - 2.0 * col), 0.17);            // gentle film contrast
    col *= 1.0 - 0.075 * pow(length((fragCoord / ctx.res - 0.5) * float2(1.05, 1.5)), 2.6);
    col += (ws_grain(fragCoord, 0.0) - 0.5) * 0.004;
    return clamp(col, 0.0, 1.0);
}
