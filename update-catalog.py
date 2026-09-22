#!/usr/bin/env python3
"""Rebuilds catalog.json and thumbs/ from the files in stills/, live/ and dynamic/.

Add wallpapers by dropping files into stills/ (jpg/png) or live/ (mp4/mov/gif),
run this script, then commit and push. The app picks changes up automatically.

pending/ is the maintainer's LOCAL review queue: it is git-ignored, and so are
pending.json and thumbs/pending-*.jpg, which this script still writes for the
app on the maintainer's Mac. Nothing in pending/ is ever public.

Files that can't be measured (corrupt, wrong extension, unsupported type) are
skipped with a warning on stderr — one bad file never blocks the rest.
Thumbnails are named <kind>-<base>.jpg; thumbs no longer referenced by
catalog.json or pending.json are deleted.
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
STILL_EXT = {".jpg", ".jpeg", ".png"}
LIVE_EXT = {".mp4", ".mov", ".gif"}
THUMBS = os.path.join(ROOT, "thumbs")


def warn(message):
    print(f"warning: {message}", file=sys.stderr)


def why(error):
    if isinstance(error, subprocess.CalledProcessError):
        return f"{os.path.basename(str(error.cmd[0] if isinstance(error.cmd, list) else error.cmd))} exited {error.returncode}"
    return str(error)


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
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        warn(f"can't measure {os.path.relpath(path, ROOT)}: {why(error)} — skipped")
        return None
    if w <= 0 or h <= 0:
        warn(f"can't measure {os.path.relpath(path, ROOT)} (not a readable image/video?) — skipped")
        return None
    return w, h


def make_thumb(src, dest):
    """Returns True on success."""
    ext = os.path.splitext(src)[1].lower()
    try:
        if ext in STILL_EXT:
            subprocess.check_call(
                ["sips", "-Z", "560", "-s", "format", "jpeg", src, "--out", dest],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        else:
            # Short clips/GIFs may not reach 1 s — fall back to the first frame.
            for seek in ("1", "0"):
                result = subprocess.call([
                    "ffmpeg", "-v", "error", "-y", "-ss", seek, "-i", src,
                    "-frames:v", "1", "-vf", "scale=560:-1", "-q:v", "4", dest,
                ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if result == 0 and os.path.exists(dest) and os.path.getsize(dest) > 0:
                    break
            else:
                raise subprocess.CalledProcessError(1, "ffmpeg")
    except (subprocess.CalledProcessError, OSError) as error:
        warn(f"can't make a thumbnail for {os.path.relpath(src, ROOT)}: {why(error)} — skipped")
        return False
    return os.path.exists(dest)


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


def scan_dynamic():
    """dynamic/*.metal — real-time time-of-day scenes; thumbnails rendered at golden hour."""
    entries = []
    directory = os.path.join(ROOT, "dynamic")
    if not os.path.isdir(directory):
        return entries
    renderer = os.path.join(ROOT, "tools", "bin", "wsrender")
    for filename in sorted(os.listdir(directory)):
        base, ext = os.path.splitext(filename)
        if ext.lower() != ".metal":
            continue
        thumb_name = f"dynamic-{base}.jpg"
        thumb_path = os.path.join(THUMBS, thumb_name)
        try:
            subprocess.check_call([
                renderer, os.path.join(directory, filename), "--out", thumb_path,
                "--size", "960x600", "--spp", "4", "--moment", "golden hour",
            ], stdout=subprocess.DEVNULL)
        except (subprocess.CalledProcessError, OSError) as error:
            if os.path.exists(thumb_path):
                warn(f"dynamic/{filename}: render failed ({why(error)}) — keeping the previous thumbnail")
            else:
                warn(f"dynamic/{filename}: render failed ({why(error)}) — skipped")
                continue
        entries.append(apply_meta({
            "id": f"dynamic-{base}",
            "title": title_of(base),
            "kind": "dynamic",
            "file": f"dynamic/{filename}",
            "thumb": f"thumbs/{thumb_name}",
            "width": 0,
            "height": 0,
        }, META.get(base, {})))
    return entries


def prune_thumbs(entries):
    """Deletes thumbnails nothing references any more (removed/renamed files,
    old un-prefixed names, rejected submissions)."""
    keep = {os.path.basename(e["thumb"]) for e in entries}
    for name in os.listdir(THUMBS):
        if name.lower().endswith(".jpg") and name not in keep:
            os.remove(os.path.join(THUMBS, name))


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
