# wsrender — procedural wallpaper renderer

All Wallpaper Studio library art is **original and procedurally generated**:
each wallpaper is a Metal "scene" shader (`scenes/<slug>.metal`) rendered
offline on the GPU by `tools/bin/wsrender` (source: `tools/wsrender/`).

## Scene contract

A scene file defines exactly one required function:

```metal
float3 scene(float2 fragCoord, WSCtx ctx);
```

- `fragCoord` — pixel coordinates, origin **bottom-left**, pixel centers at +0.5
  (Shadertoy convention). `ctx.res` is the image size.
  Aspect-correct coords: `float2 p = (2.0*fragCoord - ctx.res) / ctx.res.y;`
- Return **linear** color that is already tone-mapped into [0,1]
  (render in HDR, multiply by exposure, then `ws_acesFitted(col)`).
  The renderer supersamples (spp), converts to sRGB and dithers — do **not**
  apply gamma yourself.
- `ctx.t` — loop phase in [0,1). Stills render at t = 0 unless `--t` is passed.
- Everything from `tools/wsrender/prelude.metal` is available: hashes
  (`hash12`, `hash22`, `hash33`, `hash24`…), noise (`gnoise`, `vnoise`, `fbm`,
  `ridged`, `worley`, loop-safe `gnoiseLoop`, `fbmLoop`, `worleyLoop`,
  `gnoise3p`), color (`ws_hex`, `ws_blackbody`, `ws_acesFitted`, `ws_saturate`,
  `ws_vignette`, `ws_grain`), camera (`ws_camRay`, `ws_rot`, `ws_raySphere`),
  sky (`ws_atmosphere` — physically based Rayleigh+Mie with Earth shadow,
  `ws_sunDisk`, `ws_stars`), fog (`ws_fogAmount`).
  Helper names you define must not collide with prelude names.
- Compile errors are reported with line numbers relative to your scene file.

## CLI

```bash
B=~/wallpaper-studio-library/tools/bin/wsrender
$B scenes/x.metal --preview work/x/p1.png [--t 0.3]              # 960x600 quick look (~1s)
$B scenes/x.metal --out work/x/final.jpg --size 3840x2400 --spp 16  # FINAL still
$B scenes/x.metal --sheet work/x/sheet.png [--count 6]             # loop contact sheet (t = k/6)
$B scenes/x.metal --seam [--frames 300]                            # loop seam + motion report
$B scenes/x.metal --out work/x/test.mp4 --frames 20 --size 2560x1600 --spp 3   # timing test
$B scenes/x.metal --out work/x/final.mp4 --frames 300 --fps 30 --size 2560x1600 --spp 3   # FINAL loop
```
`--tile 128` if the GPU reports a timeout on a very heavy scene.
Video output is HEVC Main10 (10-bit, `hvc1`) — smooth gradients, plays natively on macOS.

## Final specs

| | size | quality | limits |
|---|---|---|---|
| Still | 3840×2400 | `--spp 16` JPEG q0.95 | render ≤ ~5 min on the M1 |
| Live loop | 2560×1600, 30 fps, 300 frames (10 s) | `--spp 2–4` | **≤ 19 MB** (CDN mirror limit 20 MB); frame time ≤ ~2.5 s |

Live loops **must** pass `--seam`: `wrapDiff` < 0.05 and "seam step looks like a normal frame step".
Aim for `loopRange` ≥ ~2 (motion is visible) and `perFrameStep` ≲ 4 (smooth, no flicker).

## Loop rules (live wallpapers)

Everything that moves must be **exactly periodic in `ctx.t` with period 1**:
- oscillation: `sin(TAU * (ctx.t * k + phase))` with **integer** k
- scrolling/drifting: `fract(x + ctx.t * k)` or positions `+ offset * k * ctx.t` on a
  domain that repeats with period 1 in that offset (integer k)
- evolving noise: `fbmLoop(p, ctx.t, octaves, speed)` / `gnoiseLoop` / `gnoise3p` with
  an integer period; `worleyLoop` for moving cells/caustics
- per-object random cycles: phase from a hash, cycles per loop = integer
- never use `ctx.time` or non-integer multiples of `ctx.t` for motion
- flowing-texture trick (loop-safe): blend two copies offset by half a cycle,
  `mix(A(fract(t)), B(fract(t+0.5)), abs(2*fract(t)-1))`

## Craft notes for photorealism

- Light in HDR linear space; real exposure/tonemapping (`ws_acesFitted`) — no clipped flat whites, no crushed flat blacks.
- Atmospheric perspective everywhere outdoors: blend distant geometry toward the sky/fog
  color with distance and height (`ws_fogAmount`), shift distant layers bluer/lower contrast.
- Raymarched heightfields/SDFs for terrain; proper normals, soft shadows, ambient occlusion,
  sun + sky + bounce light. Fresnel for water; roughness via noise-perturbed normals.
- Detail at every scale (macro shapes → meso → micro noise); avoid the "flat vector" look.
- Real color: sunlight warm, skylight cool; shadows tinted by sky.
- Composition for a desktop: calm top strip (menu bar) and bottom (Dock); icons sit top-right,
  so avoid harsh detail there; strong focal point, depth, and a pleasing brightness (not glaring).
- Smoothness: supersampling + renderer dithering handle banding/aliasing; add at most very subtle
  grain (`ws_grain`, amplitude ≲ 0.006). Avoid sub-pixel sparkle that flickers in video.
