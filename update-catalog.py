#!/usr/bin/env python3
"""Rebuilds catalog.json and thumbs/ from the files in stills/, live/ and dynamic/.

Add wallpapers by dropping files into stills/ (jpg/png) or live/ (mp4/mov/gif),
run this script, then commit and push. The app picks changes up automatically.

pending/ is the maintainer's LOCAL review queue: it is git-ignored, and so are
pending.json and thumbs/pending-*.jpg, which this script still writes for the
app on the maintainer's Mac. Nothing in pending/ is ever public.

A dynamic scene is previewed the way macOS previews its own: the same scene
rendered at several times of day and cut together along clean diagonals, in
time order left to right. That is the PREVIEW only -- the desktop always draws
the live scene.

Files that can't be measured (corrupt, wrong extension, unsupported type) are
skipped with a warning on stderr — one bad file never blocks the rest. A missing
TOOL (sips, ffprobe, ffmpeg, tools/bin/wsrender) is different: the script exits
non-zero before writing anything, so it can never de-list a whole kind.

--tracked-only lists only files git knows (committed or staged), for the
maintainer's publishes: a commit must never ship catalog entries whose files
aren't in it (drafts, a production group that isn't committed yet). Thumbnails
of those untracked files are left alone.
Thumbnails are named <kind>-<base>.jpg; thumbs no longer referenced by
catalog.json or pending.json are deleted.
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
STILL_EXT = {".jpg", ".jpeg", ".png"}
LIVE_EXT = {".mp4", ".mov", ".gif"}
THUMBS = os.path.join(ROOT, "thumbs")
RENDERER = os.path.join(ROOT, "tools", "bin", "wsrender")
# A dynamic wallpaper is previewed the way macOS previews its own: the SAME
# scene rendered at several times of day, cut by clean parallel diagonals in
# time order, left to right. Only the preview is sliced -- the desktop always
# draws the live scene (or its unsliced poster).
DYNAMIC_THUMB = (960, 600)
# One turn of the clock: night, back round to the night after it. Six moments
# make adjacent daylight slices too alike to tell apart; five read cleanly.
#
# Which five matters as much as how many. A band only reads as its own time of
# day if it differs from its neighbour WHERE THE CUT IS, and a scene that isn't
# mostly sky (Cyber District's street canyon: dark walls left and right at
# every hour, the sky only in the middle) barely changes there between two
# moments an hour apart. Sunrise and sunset in that canyon are nearly as dark
# as night, so night|sunrise and midday|sunset used to vanish. Jumping straight
# from night to midday and then walking down through golden hour and sunset
# puts the biggest change of the day at the leftmost cut and keeps every later
# one moving in the same direction; measured on the two scenes in the catalog
# it roughly doubles the weakest seam (see DYNAMIC_MIN_SEAM).
#
# Anything changed here must be changed in the app too — Processor's
# `dynamicPreviewMoments` — or an imported scene and its Explore card show the
# same wallpaper cut at different times of day, side by side in one window.
DYNAMIC_MOMENTS = ("night", "midday", "golden hour", "sunset", "dusk")
DYNAMIC_SPP = "8"
# How far a cut leans: its horizontal travel over the full height, as a
# fraction of the width (0.24 of 960 across 600 rows is about 21 degrees).
DYNAMIC_SLANT = 0.24
# The weakest a seam may be before the preview stops reading as a day cycle,
# in the weighted-RGB distance `seam_contrast` returns (roughly a 0..255 scale).
# For reference, at the moments above: Lighthouse Watch Day's weakest seam is
# about 29 and Cyber District's about 13, while Cyber District under the old
# night/sunrise/midday/sunset/dusk pick was 7 — a cut a stranger could not see.
DYNAMIC_MIN_SEAM = 12.0
TRACKED_ONLY = "--tracked-only" in sys.argv[1:]
# Callers (launchd, the app, workflows) may not have Homebrew on PATH.
os.environ["PATH"] = os.pathsep.join(
    [os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin"])


def warn(message):
    print(f"warning: {message}", file=sys.stderr)


def why(error):
    if isinstance(error, subprocess.CalledProcessError):
        return f"{os.path.basename(str(error.cmd[0] if isinstance(error.cmd, list) else error.cmd))} exited {error.returncode}"
    return str(error)


def scratch(dest):
    """A sibling of `dest` with the same extension, for a tool to write into.

    Same directory, so `os.replace` onto `dest` is atomic; same extension,
    because sips, ffmpeg and wsrender all pick their output format from it.
    """
    base, ext = os.path.splitext(dest)
    return f"{base}.partial{ext}"


def discard(path):
    try:
        os.remove(path)
    except OSError:
        pass


def publish(tmp, dest):
    """Moves a finished thumbnail over the one catalog.json points at.

    Nothing is ever rendered or converted straight into the published path:
    every writer here can create or truncate its output and then die (no disk
    space, a SIGKILL, Ctrl-C, a fault inside sips), and writing in place turns
    that into a corrupt jpeg the app downloads and fails to decode — while the
    warning claims the previous thumbnail was kept. Written to `scratch(dest)`
    and moved here only once complete, a failure leaves `dest` byte for byte as
    it was, so `os.path.exists(dest)` is an honest test of whether a previous
    thumbnail really survived.
    """
    os.replace(tmp, dest)


def title_of(name):
    return name.replace("-", " ").replace("_", " ").title()


def dims(path):
    """(width, height), or None if the file can't be measured."""
    ext = os.path.splitext(path)[1].lower()
    try:
        if ext in STILL_EXT:
            out = subprocess.check_output(
                ["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                stderr=subprocess.DEVNULL,
            ).decode(errors="replace")
            w = h = 0
            for line in out.splitlines():
                value = line.split()[-1] if line.split() else ""
                if "pixelWidth" in line and value.isdigit():
                    w = int(value)
                if "pixelHeight" in line and value.isdigit():
                    h = int(value)
        else:
            out = subprocess.check_output([
                "ffprobe", "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=width,height", "-of", "csv=p=0", path,
            ], stderr=subprocess.DEVNULL).decode(errors="replace").strip().splitlines()
            parts = out[0].split(",") if out else []
            w, h = (int(parts[0]), int(parts[1])) if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit() else (0, 0)
    except (subprocess.CalledProcessError, ValueError) as error:
        warn(f"can't measure {os.path.relpath(path, ROOT)}: {why(error)} — skipped")
        return None
    if w <= 0 or h <= 0:
        warn(f"can't measure {os.path.relpath(path, ROOT)} (not a readable image/video?) — skipped")
        return None
    return w, h


def make_thumb(src, dest):
    """Returns True on success."""
    ext = os.path.splitext(src)[1].lower()
    tmp = scratch(dest)
    discard(tmp)
    try:
        if ext in STILL_EXT:
            subprocess.check_call(
                ["sips", "-Z", "560", "-s", "format", "jpeg", src, "--out", tmp],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        else:
            # Short clips/GIFs may not reach 1 s — fall back to the first frame.
            for seek in ("1", "0"):
                result = subprocess.call([
                    "ffmpeg", "-v", "error", "-y", "-ss", seek, "-i", src,
                    "-frames:v", "1", "-vf", "scale=560:-1", "-q:v", "4", tmp,
                ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if result == 0 and os.path.exists(tmp) and os.path.getsize(tmp) > 0:
                    break
            else:
                raise subprocess.CalledProcessError(1, "ffmpeg")
    except (subprocess.CalledProcessError, OSError) as error:
        discard(tmp)
        warn(f"can't make a thumbnail for {os.path.relpath(src, ROOT)}: {why(error)} — skipped")
        return False
    if not os.path.exists(tmp):
        return False
    publish(tmp, dest)
    return True


def load_json(path, default):
    if os.path.exists(path):
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, ValueError) as error:
            warn(f"can't read {os.path.relpath(path, ROOT)}: {why(error)} — ignoring it")
    return default


# meta.json maps filename-base -> {"creator": ..., "created": "9/9/26"}.
META = load_json(os.path.join(ROOT, "meta.json"), {})
# Local-only metadata for the review queue (pending/meta.json, git-ignored).
PENDING_META = load_json(os.path.join(ROOT, "pending", "meta.json"), {})


def apply_meta(entry, info):
    if info.get("creator"):
        entry["creator"] = info["creator"]
    if info.get("created"):
        entry["created"] = info["created"]
    return entry


def tracked_files():
    """Paths git knows under stills/, live/ and dynamic/ (index = committed or staged)."""
    out = subprocess.check_output(
        ["git", "-C", ROOT, "ls-files", "-z", "--", "stills", "live", "dynamic"])
    return {p for p in out.decode().split("\0") if p}


TRACKED = tracked_files() if TRACKED_ONLY else None


def listed(folder, filename):
    return TRACKED is None or f"{folder}/{filename}" in TRACKED


def require_tools():
    """Exit before writing anything if a tool some file needs is missing —
    a missing tool must never look like 'every file of that kind is bad'."""
    needed = set()
    for folder in ("stills", "live", "dynamic", "pending"):
        directory = os.path.join(ROOT, folder)
        if not os.path.isdir(directory):
            continue
        for filename in os.listdir(directory):
            ext = os.path.splitext(filename)[1].lower()
            if folder != "pending" and not listed(folder, filename):
                continue
            if ext in STILL_EXT:
                needed.add("sips")
            elif ext in LIVE_EXT and folder != "dynamic":
                needed.update(("ffprobe", "ffmpeg"))
            elif ext == ".metal" and folder == "dynamic":
                needed.update(("wsrender", "sips"))
    missing = sorted(t for t in needed if t != "wsrender" and shutil.which(t) is None)
    if "wsrender" in needed and not os.access(RENDERER, os.X_OK):
        missing.append(os.path.relpath(RENDERER, ROOT))
    if missing:
        print(f"error: required tool(s) not found: {', '.join(missing)} — nothing was written", file=sys.stderr)
        sys.exit(1)


def scan(folder, exts, kind):
    entries = []
    directory = os.path.join(ROOT, folder)
    if not os.path.isdir(directory):
        return entries
    for filename in sorted(os.listdir(directory)):
        if filename.startswith("."):
            continue
        base, ext = os.path.splitext(filename)
        if ext.lower() not in exts:
            warn(f"{folder}/{filename}: unsupported type — not listed")
            continue
        if not listed(folder, filename):
            continue
        path = os.path.join(directory, filename)
        size = dims(path)
        if size is None:
            continue
        thumb_name = f"{kind}-{base}.jpg"
        if not make_thumb(path, os.path.join(THUMBS, thumb_name)):
            continue
        entries.append(apply_meta({
            "id": f"{kind}-{base}",
            "title": title_of(base),
            "kind": kind,
            "file": f"{folder}/{filename}",
            "thumb": f"thumbs/{thumb_name}",
            "width": size[0],
            "height": size[1],
        }, META.get(base, {})))
    return entries


def scan_pending():
    """pending/ holds submissions awaiting review — listed in the LOCAL,
    git-ignored pending.json, which the app shows only to the maintainer."""
    entries = []
    directory = os.path.join(ROOT, "pending")
    if not os.path.isdir(directory):
        return entries
    for filename in sorted(os.listdir(directory)):
        if filename.startswith(".") or filename == "meta.json":
            continue
        base, ext = os.path.splitext(filename)
        e = ext.lower()
        if e in STILL_EXT:
            kind = "still"
        elif e in LIVE_EXT:
            kind = "live"
        else:
            warn(f"pending/{filename}: unsupported type — not listed")
            continue
        path = os.path.join(directory, filename)
        size = dims(path)
        if size is None:
            continue
        thumb_name = f"pending-{base}.jpg"
        if not make_thumb(path, os.path.join(THUMBS, thumb_name)):
            continue
        entries.append(apply_meta({
            "id": f"pending-{base}",
            "title": title_of(base),
            "kind": kind,
            "file": f"pending/{filename}",
            "thumb": f"thumbs/{thumb_name}",
            "width": size[0],
            "height": size[1],
        }, PENDING_META.get(base) or META.get(base, {})))
    return entries


class ThumbError(Exception):
    """A sliced preview could not be built (render, sips or a malformed BMP)."""


def _bmp_read(path):
    """(width, height, rows) from an uncompressed BMP: one bytearray of BGR
    triples per row, top row first. sips writes exactly this."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"BM" or len(data) < 54:
        raise ThumbError(f"{os.path.basename(path)} is not a BMP")
    pixels = struct.unpack_from("<I", data, 10)[0]
    width, signed_height, _planes, depth, packing = struct.unpack_from("<iiHHI", data, 18)
    height = abs(signed_height)
    if depth not in (24, 32) or packing != 0 or width <= 0 or height == 0:
        raise ThumbError(f"unsupported BMP: {width}x{height}, {depth} bpp, compression {packing}")
    sample = depth // 8
    stride = (width * sample + 3) // 4 * 4
    if pixels + stride * height > len(data):
        raise ThumbError(f"{os.path.basename(path)} is truncated")
    rows = []
    for y in range(height):
        # A positive height means the rows are stored bottom-up.
        source = y if signed_height < 0 else height - 1 - y
        start = pixels + source * stride
        row = data[start:start + width * sample]
        if sample == 4:
            row = b"".join(row[i:i + 3] for i in range(0, len(row), 4))
        rows.append(bytearray(row))
    return width, height, rows


def _bmp_write(path, width, rows):
    stride = (width * 3 + 3) // 4 * 4
    padding = b"\0" * (stride - width * 3)
    body = b"".join(bytes(row) + padding for row in rows)
    header = b"BM" + struct.pack("<IHHI", 54 + len(body), 0, 0, 54) + struct.pack(
        "<IiiHHIIiiII", 40, width, -len(rows), 1, 24, 0, len(body), 2835, 2835, 0, 0)
    with open(path, "wb") as f:
        f.write(header + body)


def diagonal_slices(layers, width, height, slant=DYNAMIC_SLANT):
    """One image from several of the same size: parallel diagonal cuts, the
    first layer on the left. The cuts lean by `slant` * width across the full
    height and pivot at mid-height, so every band keeps its share of the image.
    The one pixel a cut runs through is blended, which keeps the edge straight
    and clean instead of stair-stepped."""
    travel = slant * width
    span = max(height - 1, 1)
    composite = []
    for y in range(height):
        row = bytearray(layers[0][y])
        lean = travel * (0.5 - y / span)
        for index in range(1, len(layers)):
            cut = width * index / len(layers) + lean
            above = layers[index][y]
            if cut >= width - 1:
                break
            if cut <= 0:
                row[:] = above
                continue
            whole = int(cut)
            edge = whole * 3
            row[edge + 3:] = above[edge + 3:]
            covered = 1.0 - (cut - whole)
            under = 1.0 - covered
            for channel in range(3):
                at = edge + channel
                row[at] = int(row[at] * under + above[at] * covered + 0.5)
        composite.append(row)
    return composite


def seam_contrast(layers, width, height, slant=DYNAMIC_SLANT):
    """How visible each cut will be, one number per cut, left to right.

    A sliced preview only says "this scene changes through the day" if you can
    SEE the cuts, and whether you can depends on the two moments where the cut
    falls -- not on how different they look averaged over the whole frame. A
    city canyon can go from black to noon daylight in the middle of the frame
    and stay a dark wall at the edges, which is exactly where cuts 1 and 4 are.

    So each cut is measured the way it is seen: the mean colour of the layer
    that ends there against the mean colour of the layer that starts there,
    over the narrow strip of pixels the cut runs through (the same leaning line
    `diagonal_slices` draws), as a weighted RGB distance on a 0..255 scale.
    """
    travel = slant * width
    span = max(height - 1, 1)
    half = max(2, int(round(0.04 * width)))
    out = []
    for index in range(1, len(layers)):
        sums = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
        count = 0
        for y in range(height):
            cut = width * index / len(layers) + travel * (0.5 - y / span)
            lo, hi = max(0, int(cut - half)), min(width, int(cut + half))
            if hi - lo < 2:
                continue
            for side, layer in ((0, layers[index - 1]), (1, layers[index])):
                row = layer[y]
                for x in range(lo, hi):
                    at = x * 3
                    # _bmp_read hands back BGR triples.
                    sums[side][0] += row[at + 2]
                    sums[side][1] += row[at + 1]
                    sums[side][2] += row[at]
            count += hi - lo
        if not count:
            out.append(0.0)
            continue
        below = [v / count for v in sums[0]]
        above = [v / count for v in sums[1]]
        dr, dg, db = (below[i] - above[i] for i in range(3))
        out.append((2 * dr * dr + 4 * dg * dg + 3 * db * db) ** 0.5 / 3)
    return out


def render_dynamic_frame(scene, dest, moment, size=DYNAMIC_THUMB, spp=DYNAMIC_SPP):
    subprocess.check_call([
        RENDERER, scene, "--out", dest, "--size", f"{size[0]}x{size[1]}",
        "--spp", spp, "--moment", moment,
    ], stdout=subprocess.DEVNULL)


def make_dynamic_thumb(scene, dest):
    """Renders the scene at DYNAMIC_MOMENTS and writes ONE jpeg of them cut
    together diagonally, in time order. Returns the moments that went into it,
    in the order they were drawn -- catalog.json carries that list so the app
    can name the bands it can actually see instead of assuming five. Raises
    ThumbError if it can't, with `dest` untouched."""
    width, height = DYNAMIC_THUMB
    tmp = scratch(dest)
    discard(tmp)
    moments = list(DYNAMIC_MOMENTS)
    try:
        with tempfile.TemporaryDirectory() as work:
            layers = []
            for index, moment in enumerate(moments):
                frame = os.path.join(work, f"{index}.png")
                raw = os.path.join(work, f"{index}.bmp")
                render_dynamic_frame(scene, frame, moment)
                subprocess.check_call(["sips", "-s", "format", "bmp", frame, "--out", raw],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                got_width, got_height, rows = _bmp_read(raw)
                if (got_width, got_height) != (width, height):
                    raise ThumbError(f"{moment} came out {got_width}x{got_height}, not {width}x{height}")
                layers.append(rows)
            report_seams(scene, moments, layers, width, height)
            sliced = os.path.join(work, "sliced.bmp")
            _bmp_write(sliced, width, diagonal_slices(layers, width, height))
            subprocess.check_call([
                "sips", "-s", "format", "jpeg", "-s", "formatOptions", "88",
                sliced, "--out", tmp,
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, OSError, ValueError, ThumbError) as error:
        discard(tmp)
        raise ThumbError(why(error)) from error
    if not os.path.exists(tmp):
        raise ThumbError("sips wrote no jpeg")
    publish(tmp, dest)
    return moments


def report_seams(scene, moments, layers, width, height):
    """Warns about cuts a stranger would not see, at catalog time rather than
    after the thumbnail has shipped. The preview still gets written -- a faint
    seam is a scene that defeats the slicing, not a broken file -- but a scene
    whose whole day happens in the middle of the frame needs either different
    moments or a composition the light reaches all of."""
    faint = [
        (moments[i], moments[i + 1], value)
        for i, value in enumerate(seam_contrast(layers, width, height))
        if value < DYNAMIC_MIN_SEAM
    ]
    for below, above, value in faint:
        warn(f"{os.path.relpath(scene, ROOT)}: the {below}|{above} cut is nearly "
             f"invisible ({value:.0f} against {DYNAMIC_MIN_SEAM:.0f}) — those two "
             f"bands will read as one picture")


def scan_dynamic():
    """dynamic/*.metal — real-time time-of-day scenes. The thumbnail shows the
    scene's whole day: DYNAMIC_MOMENTS rendered and cut together diagonally."""
    entries = []
    directory = os.path.join(ROOT, "dynamic")
    if not os.path.isdir(directory):
        return entries
    for filename in sorted(os.listdir(directory)):
        base, ext = os.path.splitext(filename)
        if ext.lower() != ".metal" or not listed("dynamic", filename):
            continue
        scene = os.path.join(directory, filename)
        thumb_name = f"dynamic-{base}.jpg"
        thumb_path = os.path.join(THUMBS, thumb_name)
        moments = None
        try:
            moments = make_dynamic_thumb(scene, thumb_path)
        except ThumbError as error:
            # One time of day still makes a usable thumbnail; a scene that
            # can't be sliced must never drop out of the catalog.
            warn(f"dynamic/{filename}: no sliced preview ({error}) — trying one frame")
            one = scratch(thumb_path)
            discard(one)
            try:
                render_dynamic_frame(scene, one, "golden hour")
                if not os.path.getsize(one):
                    raise subprocess.CalledProcessError(1, RENDERER)
                publish(one, thumb_path)
            except (subprocess.CalledProcessError, OSError) as error:
                discard(one)
                # Honest now that nothing was written in place: if a thumbnail
                # is still here, it is the good one from last time.
                if os.path.exists(thumb_path):
                    warn(f"dynamic/{filename}: render failed ({why(error)}) — keeping the previous thumbnail")
                else:
                    warn(f"dynamic/{filename}: render failed ({why(error)}) — skipped")
                    continue
        entry = {
            "id": f"dynamic-{base}",
            "title": title_of(base),
            "kind": "dynamic",
            "file": f"dynamic/{filename}",
            "thumb": f"thumbs/{thumb_name}",
            "width": 0,
            "height": 0,
        }
        # The times of day this thumbnail is actually cut from, left to right.
        # Omitted when the slicing failed and the thumbnail is a single frame,
        # so the app labels the bands it can see rather than five it can't.
        if moments:
            entry["moments"] = moments
        entries.append(apply_meta(entry, META.get(base, {})))
    return entries


def prune_thumbs(entries):
    """Deletes thumbnails nothing references any more (removed/renamed files,
    old un-prefixed names, rejected submissions)."""
    keep = {os.path.basename(e["thumb"]) for e in entries}
    if TRACKED is not None:
        # Untracked working-tree files (drafts, a production group being
        # published right now) keep their thumbnails — they're just not listed.
        for folder, kind in (("stills", "still"), ("live", "live"), ("dynamic", "dynamic")):
            directory = os.path.join(ROOT, folder)
            if os.path.isdir(directory):
                keep.update(f"{kind}-{os.path.splitext(n)[0]}.jpg" for n in os.listdir(directory))
    for name in os.listdir(THUMBS):
        if name.lower().endswith(".jpg") and name not in keep:
            os.remove(os.path.join(THUMBS, name))


require_tools()
os.makedirs(THUMBS, exist_ok=True)
os.makedirs(os.path.join(ROOT, "pending"), exist_ok=True)
catalog = scan("stills", STILL_EXT, "still") + scan("live", LIVE_EXT, "live") + scan_dynamic()
slugs = {}
for entry in catalog:
    base = entry["id"].split("-", 1)[1]
    if base in slugs:
        warn(f"slug '{base}' is used by both {slugs[base]} and {entry['file']} — they share meta.json info; rename one")
    slugs[base] = entry["file"]
with open(os.path.join(ROOT, "catalog.json"), "w") as f:
    json.dump(catalog, f, indent=2)
pending = scan_pending()
with open(os.path.join(ROOT, "pending.json"), "w") as f:
    json.dump(pending, f, indent=2)
prune_thumbs(catalog + pending)
print(f"catalog.json: {len(catalog)} wallpapers · pending.json (local only): {len(pending)} awaiting review")
