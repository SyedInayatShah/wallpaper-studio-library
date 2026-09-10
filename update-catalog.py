#!/usr/bin/env python3
"""Rebuilds catalog.json and thumbs/ from the files in stills/ and live/.

Add wallpapers by dropping files into stills/ (jpg/png) or live/ (mp4/gif),
run this script, then commit and push. The app picks changes up automatically.
"""
import json
import os
import subprocess

ROOT = os.path.dirname(os.path.abspath(__file__))
STILL_EXT = {".jpg", ".jpeg", ".png"}
LIVE_EXT = {".mp4", ".mov", ".gif"}


def title_of(name):
    return name.replace("-", " ").replace("_", " ").title()


def dims(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in STILL_EXT:
        out = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path]).decode()
        w = h = 0
        for line in out.splitlines():
            if "pixelWidth" in line:
                w = int(line.split()[-1])
            if "pixelHeight" in line:
                h = int(line.split()[-1])
        return w, h
    out = subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=p=0", path,
    ]).decode().strip().split(",")
    return int(out[0]), int(out[1])


def make_thumb(src, dest):
    ext = os.path.splitext(src)[1].lower()
    if ext in STILL_EXT:
        subprocess.check_call(
            ["sips", "-Z", "560", "-s", "format", "jpeg", src, "--out", dest],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    else:
        subprocess.check_call([
            "ffmpeg", "-v", "error", "-y", "-ss", "1", "-i", src,
            "-frames:v", "1", "-vf", "scale=560:-1", "-q:v", "4", dest,
        ])


def load_meta():
    """meta.json maps filename-base -> {"creator": ..., "created": "9/9/26"}."""
    meta_path = os.path.join(ROOT, "meta.json")
    if os.path.exists(meta_path):
        with open(meta_path) as f:
            return json.load(f)
    return {}


META = load_meta()


def scan(folder, exts, kind):
    entries = []
    directory = os.path.join(ROOT, folder)
    for filename in sorted(os.listdir(directory)):
        base, ext = os.path.splitext(filename)
        if ext.lower() not in exts:
            continue
        path = os.path.join(directory, filename)
        w, h = dims(path)
        thumb_name = f"{base}.jpg"
        make_thumb(path, os.path.join(ROOT, "thumbs", thumb_name))
        entry = {
            "id": f"{kind}-{base}",
            "title": title_of(base),
            "kind": kind,
            "file": f"{folder}/{filename}",
            "thumb": f"thumbs/{thumb_name}",
            "width": w,
            "height": h,
        }
        info = META.get(base, {})
        if info.get("creator"):
            entry["creator"] = info["creator"]
        if info.get("created"):
            entry["created"] = info["created"]
        entries.append(entry)
    return entries


def scan_pending():
    """pending/ holds submissions awaiting review — published to pending.json,
    which the app shows only to the maintainer."""
    entries = []
    directory = os.path.join(ROOT, "pending")
    if not os.path.isdir(directory):
        return entries
    for filename in sorted(os.listdir(directory)):
        base, ext = os.path.splitext(filename)
        e = ext.lower()
        if e in STILL_EXT:
            kind = "still"
        elif e in LIVE_EXT:
            kind = "live"
        else:
            continue
        path = os.path.join(directory, filename)
        w, h = dims(path)
        thumb_name = f"pending-{base}.jpg"
        make_thumb(path, os.path.join(ROOT, "thumbs", thumb_name))
        entry = {
            "id": f"pending-{base}",
            "title": title_of(base),
            "kind": kind,
            "file": f"pending/{filename}",
            "thumb": f"thumbs/{thumb_name}",
            "width": w,
            "height": h,
        }
        info = META.get(base, {})
        if info.get("creator"):
            entry["creator"] = info["creator"]
        if info.get("created"):
            entry["created"] = info["created"]
        entries.append(entry)
    return entries


os.makedirs(os.path.join(ROOT, "thumbs"), exist_ok=True)
os.makedirs(os.path.join(ROOT, "pending"), exist_ok=True)
catalog = scan("stills", STILL_EXT, "still") + scan("live", LIVE_EXT, "live")
with open(os.path.join(ROOT, "catalog.json"), "w") as f:
    json.dump(catalog, f, indent=2)
pending = scan_pending()
with open(os.path.join(ROOT, "pending.json"), "w") as f:
    json.dump(pending, f, indent=2)
print(f"catalog.json: {len(catalog)} wallpapers · pending.json: {len(pending)} awaiting review")
