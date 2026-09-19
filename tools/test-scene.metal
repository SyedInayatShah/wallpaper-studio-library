// Smoke test: physically based sunset sky over a simple animated sea.
float3 scene(float2 fragCoord, WSCtx ctx) {
    float3 ro = float3(0.0, 2.0, 0.0);
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, float3(0.0, 2.3, -10.0), 50.0);
    float3 sun = normalize(float3(0.2, 0.06, -1.0));
    float3 col;
    if (rd.y > 0.0) {
        col = ws_atmosphere(rd, sun) + ws_sunDisk(rd, sun, 0.6, float3(40.0, 30.0, 20.0));
    } else {
        float d = -ro.y / rd.y;
        float3 p = ro + rd * d;
        float h = fbmLoop(p.xz * 0.3, ctx.t, 4, 2);
        float3 n = normalize(float3(h * 0.25, 1.0, h * 0.2));
        float3 r = reflect(rd, n);
        r.y = abs(r.y);
        float fres = 0.02 + 0.98 * pow(1.0 - max(dot(n, -rd), 0.0), 5.0);
        col = ws_atmosphere(r, sun) * fres + float3(0.005, 0.02, 0.03);
        col = mix(col, ws_atmosphere(normalize(float3(rd.x, 0.001, rd.z)), sun), 1.0 - exp(-d * 0.01));
    }
    return ws_acesFitted(col * 0.9);
}
