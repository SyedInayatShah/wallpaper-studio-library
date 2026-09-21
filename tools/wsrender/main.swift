// wsrender — offline GPU renderer for Wallpaper Studio's procedural wallpapers.
// See ../README.md for the scene contract and usage.
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("wsrender: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Options

struct Options {
    var scene = ""
    var out = ""
    var width = 1920
    var height = 1200
    var sizeGiven = false
    var spp = 4
    var sppGiven = false
    var frames = 0
    var fps = 30
    var t: Float = 0
    var mode = "render"      // render | sheet | seam
    var count = 6
    var crf = 20
    var maxrateMbps = 12
    var preset = "slow"
    var tile = 256
    var jpegQuality = 0.95
    var hour: Double = 17.0
    var dateString = ""
    var lat: Double? = nil
    var lon: Double? = nil
    var timeSeconds: Float? = nil
    var moment = ""
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.contains("-h") || args.contains("--help") {
        print("""
        usage:
          wsrender SCENE.metal --out still.jpg|png [--size 3840x2400] [--spp 16] [--t 0]
          wsrender SCENE.metal --out loop.mp4 --frames 300 [--fps 30] [--size 2560x1600] [--spp 4]
                               [--crf 20] [--maxrate 12] [--preset slow]
          wsrender SCENE.metal --preview out.png [--t 0.3]        (960x600, 2 spp, quick look)
          wsrender SCENE.metal --sheet out.png [--count 6] [--size 640x400]   (loop contact sheet)
          wsrender SCENE.metal --seam [--frames 300] [--size 480x300]         (loop seam/motion report)
          wsrender SCENE.metal --daycycle out.png [--size 640x400]   (time-of-day sheet: night..sunset..dusk)
          wsrender SCENE.metal --bench [--size 1280x800] [--frames 60]   (real-time cost, GPU ms/frame)
          time of day: --hour 18.5 | --moment "golden hour" [--date 2026-06-21] [--lat 31.5 --lon 74.3] [--time SECONDS]
                       (moments: night, dawn twilight, sunrise, morning, midday, golden hour, sunset, dusk, evening night)
          common: --tile 256 (smaller if the GPU times out)
        """)
        exit(0)
    }
    func value(_ i: inout Int) -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(args[i - 1])") }
        return args[i]
    }
    func parseSize(_ s: String) -> (Int, Int) {
        let parts = s.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("bad --size \(s), use WxH") }
        return (parts[0], parts[1])
    }
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--out": o.out = value(&i)
        case "--size": (o.width, o.height) = parseSize(value(&i)); o.sizeGiven = true
        case "--spp": o.spp = max(1, Int(value(&i)) ?? 1); o.sppGiven = true
        case "--frames": o.frames = max(0, Int(value(&i)) ?? 0)
        case "--fps": o.fps = max(1, Int(value(&i)) ?? 30)
        case "--t": o.t = Float(value(&i)) ?? 0
        case "--count": o.count = max(1, Int(value(&i)) ?? 6)
        case "--crf": o.crf = Int(value(&i)) ?? 20
        case "--maxrate": o.maxrateMbps = max(1, Int(value(&i)) ?? 12)
        case "--preset": o.preset = value(&i)
        case "--tile": o.tile = max(32, Int(value(&i)) ?? 256)
        case "--quality": o.jpegQuality = Double(value(&i)) ?? 0.95
        case "--hour": o.hour = Double(value(&i)) ?? 17
        case "--date": o.dateString = value(&i)
        case "--lat": o.lat = Double(value(&i))
        case "--lon": o.lon = Double(value(&i))
        case "--time": o.timeSeconds = Float(value(&i))
        case "--moment": o.moment = value(&i)
        case "--daycycle":
            o.mode = "daycycle"; o.out = value(&i)
        case "--bench":
            o.mode = "bench"
        case "--preview":
            o.out = value(&i)
            if !o.sizeGiven { o.width = 960; o.height = 600 }
            if !o.sppGiven { o.spp = 2 }
        case "--sheet":
            o.mode = "sheet"; o.out = value(&i)
        case "--seam":
            o.mode = "seam"
        default:
            if a.hasPrefix("--") { fail("unknown option \(a)") }
            o.scene = a
        }
        i += 1
    }
    if o.scene.isEmpty { fail("no scene file given") }
    if o.mode == "sheet" {
        if !o.sizeGiven { o.width = 640; o.height = 400 }
        if !o.sppGiven { o.spp = 1 }
    }
    if o.mode == "seam" {
        if !o.sizeGiven { o.width = 480; o.height = 300 }
        o.spp = 1
        if o.frames == 0 { o.frames = 300 }
    }
    if o.mode == "daycycle" {
        if !o.sizeGiven { o.width = 640; o.height = 400 }
        if !o.sppGiven { o.spp = 2 }
    }
    if o.mode == "bench" {
        if !o.sizeGiven { o.width = 1280; o.height = 800 }
        o.spp = 1
        if o.frames == 0 { o.frames = 60 }
        o.tile = 4096
    }
    if o.mode == "render" && o.out.isEmpty { fail("--out is required") }
    return o
}

let opts = parseOptions()

// MARK: - Metal setup

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fail("no Metal device")
}

let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let preludeCandidates = [
    exeDir.appendingPathComponent("../wsrender/prelude.metal"),
    exeDir.appendingPathComponent("prelude.metal"),
]
guard let preludeURL = preludeCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
      let prelude = try? String(contentsOf: preludeURL, encoding: .utf8) else {
    fail("prelude.metal not found next to the binary")
}
guard let sceneSource = try? String(contentsOfFile: opts.scene, encoding: .utf8) else {
    fail("cannot read scene \(opts.scene)")
}

let footer = """

// ---- wsrender kernels ----
struct WSParams { uint2 res; uint2 origin; float t; float duration; uint sampleIndex; uint spp;
                  float4 sun; float4 moon; float4 clock; };

kernel void ws_render(device float4* accum [[buffer(0)]],
                      constant WSParams& P [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint2 pix = P.origin + gid;
    if (pix.x >= P.res.x || pix.y >= P.res.y) return;
    float2 jit = (P.spp <= 1u) ? float2(0.5)
        : fract(float2(0.5) + float(P.sampleIndex) * float2(0.7548776662, 0.5698402910));
    float2 fragCoord = float2(float(pix.x), float(P.res.y - 1u - pix.y)) + jit;
    WSCtx ctx;
    ctx.res = float2(P.res);
    ctx.t = P.t;
    ctx.duration = P.duration;
    ctx.time = P.t * P.duration;
    ctx.aspect = ctx.res.x / ctx.res.y;
    ctx.sunDir = P.sun.xyz; ctx.sunElevation = P.sun.w;
    ctx.moonDir = P.moon.xyz; ctx.moonIllum = P.moon.w;
    ctx.dayTime = P.clock.x; ctx.dayOfYear = P.clock.z; ctx.realtime = 0.0;
    if (P.clock.y > 0.0) ctx.time = P.clock.y;
    float3 c = scene(fragCoord, ctx);
    if (!all(isfinite(c))) c = float3(0.0);
    c = clamp(c, 0.0, 1.0);
    accum[pix.y * P.res.x + pix.x] += float4(c, 1.0);
}

struct WSFinal { uint2 res; float ditherAmp; uint seed; };

kernel void ws_finalize(device const float4* accum [[buffer(0)]],
                        device ushort4* outp [[buffer(1)]],
                        constant WSFinal& F [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= F.res.x || gid.y >= F.res.y) return;
    uint idx = gid.y * F.res.x + gid.x;
    float4 a = accum[idx];
    float3 c = a.w > 0.0 ? a.rgb / a.w : float3(0.0);
    float3 s = ws_lin2srgb(clamp(c, 0.0, 1.0));
    uint3 h = ws_pcg3(uint3(gid, F.seed));
    float3 tri = float3(h & 0xffffu) / 65535.0 + float3(h >> 16u) / 65535.0 - 1.0;
    s = clamp(s + tri * F.ditherAmp, 0.0, 1.0);
    outp[idx] = ushort4(ushort3(round(s * 65535.0)), ushort(65535));
}
"""

let fullSource = prelude + "\n#line 1 \"scene\"\n" + sceneSource + "\n" + footer

let library: MTLLibrary
do {
    let options = MTLCompileOptions()
    options.mathMode = .relaxed
    library = try device.makeLibrary(source: fullSource, options: options)
} catch {
    fail("shader compile failed:\n\(error)")
}
guard let renderFn = library.makeFunction(name: "ws_render"),
      let finalFn = library.makeFunction(name: "ws_finalize"),
      let renderPSO = try? device.makeComputePipelineState(function: renderFn),
      let finalPSO = try? device.makeComputePipelineState(function: finalFn) else {
    fail("pipeline creation failed (does the scene define `float3 scene(float2, WSCtx)`?)")
}

struct WSParams {
    var res: SIMD2<UInt32>
    var origin: SIMD2<UInt32>
    var t: Float
    var duration: Float
    var sampleIndex: UInt32
    var spp: UInt32
    var sun: SIMD4<Float> = .zero
    var moon: SIMD4<Float> = .zero
    var clock: SIMD4<Float> = .zero   // (dayTime, timeOverride, dayOfYear, 0)
}
struct WSFinal {
    var res: SIMD2<UInt32>
    var ditherAmp: Float
    var seed: UInt32
}

final class GPUErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    func set(_ m: String) { lock.lock(); if message == nil { message = m }; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return message }
}
let gpuError = GPUErrorBox()

// Time of day for this render (dynamic scenes). Defaults: today at --hour in the Mac's time zone.
let location: (lat: Double, lon: Double) = {
    let tz = Solar.timeZoneLocation()
    return (opts.lat ?? tz.lat, opts.lon ?? tz.lon)
}()
func dateFor(hour: Double) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    var day = cal.startOfDay(for: Date())
    if !opts.dateString.isEmpty {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        if let d = f.date(from: opts.dateString) { day = d } else { fail("bad --date, use YYYY-MM-DD") }
    }
    return day.addingTimeInterval(hour * 3600)
}
var sky: SkyState = {
    if !opts.moment.isEmpty {
        let moments = Solar.keyMoments(on: dateFor(hour: 12), lat: location.lat, lon: location.lon)
        guard let m = moments.first(where: { $0.0 == opts.moment }) else {
            fail("unknown --moment \(opts.moment); use one of: \(moments.map { $0.0 }.joined(separator: ", "))")
        }
        return Solar.state(at: m.1, lat: location.lat, lon: location.lon)
    }
    return Solar.state(at: dateFor(hour: opts.hour), lat: location.lat, lon: location.lon)
}()
var gpuTimeTotal: Double = 0
let gpuTimeLock = NSLock()

/// Renders one image at phase `t` into `out` (ushort4 sRGB, dithered).
func renderImage(t: Float, width w: Int, height h: Int, spp: Int, duration: Float,
                 accum: MTLBuffer, out: MTLBuffer, seed: UInt32, ditherAmp: Float) {
    guard let clear = queue.makeCommandBuffer(), let blit = clear.makeBlitCommandEncoder() else {
        fail("command buffer failed")
    }
    blit.fill(buffer: accum, range: 0..<(w * h * 16), value: 0)
    blit.endEncoding()
    clear.commit()

    let tile = opts.tile
    let tg = MTLSize(width: 16, height: 16, depth: 1)
    for s in 0..<spp {
        for ty in stride(from: 0, to: h, by: tile) {
            for tx in stride(from: 0, to: w, by: tile) {
                guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
                    fail("command buffer failed")
                }
                enc.setComputePipelineState(renderPSO)
                enc.setBuffer(accum, offset: 0, index: 0)
                var p = WSParams(res: SIMD2(UInt32(w), UInt32(h)), origin: SIMD2(UInt32(tx), UInt32(ty)),
                                 t: t, duration: duration, sampleIndex: UInt32(s), spp: UInt32(spp),
                                 sun: SIMD4(sky.sunDir, sky.sunElevation),
                                 moon: SIMD4(sky.moonDir, sky.moonIllumination),
                                 clock: SIMD4(sky.dayTime, opts.timeSeconds ?? (duration > 0 ? 0 : -1), sky.dayOfYear, 0))
                enc.setBytes(&p, length: MemoryLayout<WSParams>.stride, index: 1)
                enc.dispatchThreads(MTLSize(width: min(tile, w - tx), height: min(tile, h - ty), depth: 1),
                                    threadsPerThreadgroup: tg)
                enc.endEncoding()
                let where_ = "tile (\(tx),\(ty)) sample \(s)"
                cb.addCompletedHandler { buffer in
                    gpuTimeLock.lock(); gpuTimeTotal += buffer.gpuEndTime - buffer.gpuStartTime; gpuTimeLock.unlock()
                    if buffer.status == .error {
                        gpuError.set("GPU error at \(where_): \(buffer.error?.localizedDescription ?? "unknown"). The scene is too expensive per pixel — reduce march steps / octaves, or pass --tile 128.")
                    }
                }
                cb.commit()
            }
        }
    }
    guard let fin = queue.makeCommandBuffer(), let enc = fin.makeComputeCommandEncoder() else {
        fail("command buffer failed")
    }
    enc.setComputePipelineState(finalPSO)
    enc.setBuffer(accum, offset: 0, index: 0)
    enc.setBuffer(out, offset: 0, index: 1)
    var f = WSFinal(res: SIMD2(UInt32(w), UInt32(h)), ditherAmp: ditherAmp, seed: seed)
    enc.setBytes(&f, length: MemoryLayout<WSFinal>.stride, index: 2)
    enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: tg)
    enc.endEncoding()
    fin.commit()
    fin.waitUntilCompleted()
    if let message = gpuError.get() { fail(message) }
}

func makeBuffers(_ w: Int, _ h: Int) -> (MTLBuffer, MTLBuffer) {
    guard let accum = device.makeBuffer(length: w * h * 16, options: .storageModeShared),
          let out = device.makeBuffer(length: w * h * 8, options: .storageModeShared) else {
        fail("could not allocate \(w)x\(h) buffers")
    }
    return (accum, out)
}

/// 16-bit RGBA buffer -> 8-bit RGBA bytes
func to8bit(_ out: MTLBuffer, _ w: Int, _ h: Int) -> [UInt8] {
    let src = out.contents().bindMemory(to: UInt16.self, capacity: w * h * 4)
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    bytes.withUnsafeMutableBufferPointer { dst in
        for i in 0..<(w * h * 4) {
            dst[i] = UInt8((UInt32(src[i]) + 128) / 257)
        }
    }
    return bytes
}

func cgImage(from bytes: [UInt8], _ w: Int, _ h: Int) -> CGImage {
    let data = Data(bytes) as CFData
    guard let provider = CGDataProvider(data: data),
          let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        fail("could not build image")
    }
    return image
}

func writeImage(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension.lowercased()
    let type = (ext == "jpg" || ext == "jpeg") ? UTType.jpeg : UTType.png
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        fail("cannot write \(path)")
    }
    var props: [CFString: Any] = [:]
    if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = opts.jpegQuality }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(path)") }
}

func fileSizeMB(_ path: String) -> Double {
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.doubleValue ?? 0
    return size / 1_048_576
}

let start = Date()
let W = opts.width, H = opts.height

// MARK: - Modes

switch opts.mode {
case "sheet":
    // Contact sheet of `count` frames across the loop, 3 columns.
    let (accum, out) = makeBuffers(W, H)
    let cols = min(3, opts.count)
    let rows = (opts.count + cols - 1) / cols
    let gap = 6
    let sheetW = cols * W + (cols - 1) * gap, sheetH = rows * H + (rows - 1) * gap
    var sheet = [UInt8](repeating: 0, count: sheetW * sheetH * 4)
    for k in 0..<opts.count {
        let t = Float(k) / Float(opts.count)
        renderImage(t: t, width: W, height: H, spp: opts.spp, duration: 10,
                    accum: accum, out: out, seed: UInt32(k), ditherAmp: 1.0 / 255.0)
        let frame = to8bit(out, W, H)
        let ox = (k % cols) * (W + gap), oy = (k / cols) * (H + gap)
        for y in 0..<H {
            let srcStart = y * W * 4
            let dstStart = ((oy + y) * sheetW + ox) * 4
            sheet.replaceSubrange(dstStart..<(dstStart + W * 4), with: frame[srcStart..<(srcStart + W * 4)])
        }
    }
    writeImage(cgImage(from: sheet, sheetW, sheetH), to: opts.out)
    print("sheet: \(opts.out)  (\(opts.count) frames at t = k/\(opts.count), left-to-right, top-to-bottom)  \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

case "daycycle":
    // Sheet of the key moments of the day (night, dawn, sunrise, morning, midday,
    // golden hour, sunset, dusk, night) for time-of-day scenes.
    let (accum, out) = makeBuffers(W, H)
    let moments = Solar.keyMoments(on: dateFor(hour: 12), lat: location.lat, lon: location.lon)
    let cols = 3
    let rows = (moments.count + cols - 1) / cols
    let gap = 6
    let sheetW = cols * W + (cols - 1) * gap, sheetH = rows * H + (rows - 1) * gap
    var sheet = [UInt8](repeating: 0, count: sheetW * sheetH * 4)
    let tf = DateFormatter(); tf.dateFormat = "HH:mm"; tf.timeZone = .current
    var legend: [String] = []
    for (k, moment) in moments.enumerated() {
        sky = Solar.state(at: moment.1, lat: location.lat, lon: location.lon)
        legend.append("\(k + 1). \(moment.0) \(tf.string(from: moment.1)) (sun \(String(format: "%.1f", sky.sunElevation))°)")
        renderImage(t: 0, width: W, height: H, spp: opts.spp, duration: 0,
                    accum: accum, out: out, seed: UInt32(k), ditherAmp: 1.0 / 255.0)
        let frame = to8bit(out, W, H)
        let ox = (k % cols) * (W + gap), oy = (k / cols) * (H + gap)
        for y in 0..<H {
            let srcStart = y * W * 4
            let dstStart = ((oy + y) * sheetW + ox) * 4
            sheet.replaceSubrange(dstStart..<(dstStart + W * 4), with: frame[srcStart..<(srcStart + W * 4)])
        }
    }
    writeImage(cgImage(from: sheet, sheetW, sheetH), to: opts.out)
    print("daycycle: \(opts.out)  location \(String(format: "%.2f, %.2f", location.lat, location.lon))\n" + legend.joined(separator: "\n"))

case "bench":
    // Real-time cost: one dispatch per frame at the given size, 1 spp, time advancing at 30 fps.
    let (accum, out) = makeBuffers(W, H)
    renderImage(t: 0, width: W, height: H, spp: 1, duration: 0, accum: accum, out: out, seed: 0, ditherAmp: 0) // warm-up
    gpuTimeTotal = 0
    for f in 0..<opts.frames {
        var o2 = opts; o2.timeSeconds = Float(f) / 30
        _ = o2
        renderImage(t: Float(f) / Float(opts.frames), width: W, height: H, spp: 1, duration: Float(opts.frames) / 30,
                    accum: accum, out: out, seed: 0, ditherAmp: 0)
    }
    let ms = gpuTimeTotal / Double(opts.frames) * 1000
    let verdict = ms <= 8 ? "OK for live rendering" : (ms <= 14 ? "heavy — aim for ≤ 8 ms" : "TOO SLOW for live rendering")
    print(String(format: "bench: %dx%d  %.2f ms/frame GPU  (%@)  (other GPU work inflates this)", W, H, ms, verdict))

case "seam":
    // Loop quality metrics in 8-bit units (mean absolute difference per channel).
    let (accum, out) = makeBuffers(W, H)
    let F = Float(opts.frames)
    func frame(_ t: Float) -> [UInt8] {
        renderImage(t: t, width: W, height: H, spp: 1, duration: 10, accum: accum, out: out, seed: 0, ditherAmp: 0)
        return to8bit(out, W, H)
    }
    func mad(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0
        for i in 0..<a.count where i % 4 != 3 { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count / 4 * 3)
    }
    let f0 = frame(0), f1 = frame(1 / F), fLast = frame((F - 1) / F), fWrap = frame(1.0)
    let fHalf = frame(0.5), fQuarter = frame(0.25)
    let step = mad(f0, f1)
    let seam = mad(fLast, f0)
    let wrap = mad(fWrap, f0)
    let range = max(mad(fHalf, f0), mad(fQuarter, f0))
    var verdict: [String] = []
    verdict.append(wrap < 0.05 ? "seamless (t=1 matches t=0)" : "NOT SEAMLESS: t=1 differs from t=0 — something is not periodic in ctx.t")
    verdict.append(seam <= step * 2.0 + 0.3 ? "seam step looks like a normal frame step" : "VISIBLE JUMP at the loop seam")
    if range < 1.0 { verdict.append("WARNING: almost nothing moves across the loop") }
    if step > 6.0 { verdict.append("WARNING: large per-frame change — may look jittery/flickery") }
    print("""
    {"frames": \(opts.frames), "perFrameStep": \(String(format: "%.3f", step)), "seamStep": \(String(format: "%.3f", seam)), "wrapDiff": \(String(format: "%.4f", wrap)), "loopRange": \(String(format: "%.2f", range))}
    verdict: \(verdict.joined(separator: "; "))
    """)

default:
    let (accum, out) = makeBuffers(W, H)
    let ext = URL(fileURLWithPath: opts.out).pathExtension.lowercased()
    if ext == "mp4" || ext == "mov" {
        guard opts.frames > 0 else { fail("video output needs --frames N") }
        let duration = Float(opts.frames) / Float(opts.fps)
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.fileExists(atPath: $0) }
        guard let ffmpeg else { fail("ffmpeg not found") }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: opts.out).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let maxK = opts.maxrateMbps * 1000
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-y", "-v", "error",
            "-f", "rawvideo", "-pix_fmt", "rgba64le", "-s", "\(W)x\(H)", "-r", "\(opts.fps)", "-i", "-",
            "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p10le",
            "-c:v", "libx265", "-preset", opts.preset, "-crf", "\(opts.crf)",
            "-x265-params", "log-level=error:vbv-maxrate=\(maxK):vbv-bufsize=\(maxK * 2):aq-mode=3",
            "-tag:v", "hvc1",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-an", "-movflags", "+faststart", opts.out,
        ]
        let pipe = Pipe()
        proc.standardInput = pipe
        do { try proc.run() } catch { fail("could not start ffmpeg: \(error)") }
        let bytesPerFrame = W * H * 8
        for f in 0..<opts.frames {
            let t = Float(f) / Float(opts.frames)
            renderImage(t: t, width: W, height: H, spp: opts.spp, duration: duration,
                        accum: accum, out: out, seed: UInt32(f), ditherAmp: 0.5 / 1023.0)
            pipe.fileHandleForWriting.write(Data(bytesNoCopy: out.contents(), count: bytesPerFrame, deallocator: .none))
            if f % 30 == 0 || f == opts.frames - 1 {
                let el = Date().timeIntervalSince(start)
                let per = el / Double(f + 1)
                print(String(format: "frame %d/%d  %.2fs/frame  eta %.0fs", f + 1, opts.frames, per, per * Double(opts.frames - f - 1)))
            }
        }
        try? pipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { fail("ffmpeg failed (status \(proc.terminationStatus))") }
        let mb = fileSizeMB(opts.out)
        print(String(format: "video: %@  %dx%d  %d frames @ %dfps (%.1fs loop)  %.1f MB  total %.0fs",
                     opts.out, W, H, opts.frames, opts.fps, duration, mb, Date().timeIntervalSince(start)))
        if mb > 19.0 { print("WARNING: file > 19 MB — the CDN mirror rejects files over 20 MB. Lower --maxrate or --crf quality.") }
    } else {
        renderImage(t: opts.t, width: W, height: H, spp: opts.spp, duration: 0,
                    accum: accum, out: out, seed: 7, ditherAmp: 1.0 / 255.0)
        writeImage(cgImage(from: to8bit(out, W, H), W, H), to: opts.out)
        print(String(format: "image: %@  %dx%d  %d spp  %.1f MB  %.1fs",
                     opts.out, W, H, opts.spp, fileSizeMB(opts.out), Date().timeIntervalSince(start)))
    }
}
