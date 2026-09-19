// Smoke test for time-of-day inputs: camera faces west over a calm sea.
float3 scene(float2 fragCoord, WSCtx ctx) {
    float3 sun = ws_rotY(ctx.sunDir, -PI * 0.5);   // world -> view frame (camera looks west)
    float3 moon = ws_rotY(ctx.moonDir, -PI * 0.5);
    float3 ro = float3(0.0, 2.0, 0.0);
    float3 rd = ws_camRay(fragCoord, ctx.res, ro, float3(0.0, 2.4, -10.0), 55.0);
    float3 dir = rd.y > 0.0 ? rd : reflect(rd, normalize(float3(0.03 * gnoise(rd.xz * 60.0 + ctx.time * 0.3), 1.0, 0.0)));
    float3 col = ws_atmosphere(dir, sun) + ws_sunDisk(dir, sun, 0.6, float3(40.0, 30.0, 20.0));
    float night = smoothstep(-2.0, -12.0, ctx.sunElevation);
    col += night * ws_stars(dir.xy / (dir.z - 1.2), 90.0, 0.0) * 0.02 * step(0.0, dir.y);
    col += night * ws_sunDisk(dir, moon, 0.9, float3(0.6, 0.62, 0.66) * (0.2 + ctx.moonIllum));
    col += float3(0.0005, 0.0008, 0.0015) * night;
    if (rd.y < 0.0) col *= 0.35;
    return ws_acesFitted(col * mix(0.9, 60.0, night));
}
