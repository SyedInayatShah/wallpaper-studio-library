#!/bin/zsh
# Approves a submitted wallpaper: downloads it, detects its real type from the
# bytes, adds it under a name no other wallpaper uses, regenerates the
# catalog, commits only what it touched, and pushes.
# Safe to re-run after a failure (e.g. a rejected push): an identical file that
# is already in the library is reused, nothing is committed twice, and the
# push is retried whenever the branch is ahead of origin.
# Usage: ./approve.sh <file-url-from-issue> <kebab-case-name> <still|live> [creator] [date like 9/9/26]
set -e
cd "$(dirname "$0")"

URL="$1"; NAME="$2"; KIND="$3"; CREATOR="$4"; CREATED="${5:-$(date +%-m/%-d/%y)}"
if [[ -z "$URL" || -z "$NAME" || ( "$KIND" != "still" && "$KIND" != "live" ) ]]; then
    echo "Usage: ./approve.sh <file-url> <kebab-case-name> <still|live> [creator] [date]"
    exit 1
fi
if [[ ! "$NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "error: name must be kebab-case (a-z, 0-9, dashes), e.g. neon-city" >&2
    exit 1
fi

# The production publisher pulls with --rebase in this same clone: never add
# or commit onto a rebase/merge that is stopped mid-way.
rebasing() { [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]; }
if rebasing || [[ -f "$(git rev-parse --git-path MERGE_HEAD)" || -n "$(git ls-files -u)" ]]; then
    echo "error: another publish is in progress in this repo — nothing was changed. Try again shortly." >&2
    exit 1
fi

TMP="$(mktemp -t wsapprove)"
trap 'rm -f "$TMP" "$TMP.jpg" "$TMP.png"' EXIT
# -f: an HTTP error must fail here, never be saved as a "wallpaper".
curl -fL --retry 2 -o "$TMP" "$URL"

# The real type comes from the bytes, not the URL (attachment URLs often have
# no extension) and not the submitter's claim.
MIME="$(file -b --mime-type "$TMP")"
case "$MIME" in
    image/jpeg)                 EXT=jpg; DIR=stills ;;
    image/png)                  EXT=png; DIR=stills ;;
    image/gif)                  EXT=gif; DIR=live ;;
    video/mp4|video/x-m4v)      EXT=mp4; DIR=live ;;
    video/quicktime)            EXT=mov; DIR=live ;;
    image/heic|image/heif|image/avif|image/webp|image/tiff|image/bmp|image/x-ms-bmp)
        # Stills the catalog can't list are converted to a high-quality JPEG.
        sips -s format jpeg -s formatOptions best "$TMP" --out "$TMP.jpg" >/dev/null
        mv "$TMP.jpg" "$TMP"
        EXT=jpg; DIR=stills ;;
    *)
        echo "error: unsupported file type '$MIME' — nothing was published" >&2
        exit 1 ;;
esac
if [[ "$DIR" == stills ]] && ffprobe -v error -select_streams v:0 -read_intervals %+#1 \
        -show_entries frame_side_data=side_data_type -of csv=p=0 "$TMP" | grep -q displaymatrix; then
    # EXIF orientation (portrait phone shots): bake it into the pixels, so the
    # file, its thumbnail and its catalog width/height are all upright.
    ffmpeg -v error -y -i "$TMP" -map_metadata -1 -q:v 1 -f image2 -c:v "$([[ $EXT == png ]] && echo png || echo mjpeg)" "$TMP.$EXT"
    mv "$TMP.$EXT" "$TMP"
fi
DETECTED=$([[ "$DIR" == live ]] && echo live || echo still)
if [[ "$DETECTED" != "$KIND" ]]; then
    echo "note: the file is really a $DETECTED ($MIME) — publishing it as $DETECTED" >&2
fi

# Pick a slug nothing else uses (any kind, any extension, meta.json, or a
# removal notice in removed.json — reviving a removed wallpaper's ID would tell
# its downloaders it "was removed") — approving must never overwrite a live
# wallpaper. An identical file already in the library (an earlier,
# interrupted run) is reused, but only if no different file shares its slug;
# an identical queued (pending/) copy only if nothing public claims the slug.
taken() {
    local slug="$1" f same=""
    for f in stills/"$slug".*(N) live/"$slug".*(N) dynamic/"$slug".*(N) pending/"$slug".*(N); do
        if cmp -s "$f" "$TMP"; then same="${same:-$f}"; else return 0; fi
    done
    if [[ -n "$same" && "$same" != pending/* ]]; then REUSE="$same"; return 1; fi
    SLUG="$slug" python3 -c '
import json, os, sys
slug = os.environ["SLUG"]
meta = json.load(open("meta.json")) if os.path.exists("meta.json") else {}
removed = json.load(open("removed.json")) if os.path.exists("removed.json") else []
gone = {n.get("id", "").split("-", 1)[-1] for n in removed if "-" in n.get("id", "")}
sys.exit(0 if slug in meta or slug in gone else 1)' && return 0
    if [[ -n "$same" ]]; then REUSE="$same"; fi
    return 1
}
SLUG="$NAME"; N=1; REUSE=""
while taken "$SLUG"; do
    N=$((N + 1)); SLUG="$NAME-$N"
done
if [[ -n "$REUSE" && "$REUSE" != pending/* ]]; then
    TARGET="$REUSE"
    echo "note: this file is already in the library as $TARGET — reusing it" >&2
else
    TARGET="$DIR/$SLUG.$EXT"
    if [[ "$SLUG" != "$NAME" ]]; then
        echo "note: '$NAME' is taken — publishing as '$SLUG'" >&2
    fi
    cp "$TMP" "$TARGET"
    SLUG="$SLUG" CREATOR="$CREATOR" CREATED="$CREATED" python3 - <<'EOF'
import json, os
meta_path = "meta.json"
meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
entry = {}
if os.environ.get("CREATOR"):
    entry["creator"] = os.environ["CREATOR"]
if os.environ.get("CREATED"):
    entry["created"] = os.environ["CREATED"]
meta.setdefault(os.environ["SLUG"], entry)
json.dump(meta, open(meta_path, "w"), indent=2)
EOF
fi

# The catalog we commit lists only files git knows (--tracked-only), so it
# can never point at drafts or at a production group that isn't committed
# yet. Stage the new file first so it's one of them.
git add -- "$TARGET"
# The tracked-only catalog must not stay in the shared working tree: a
# production publish committing meanwhile would ship a catalog missing its
# own new files. Put the full one back on exit, whatever happens.
trap './update-catalog.py >/dev/null 2>&1 || true' EXIT
# Stage the catalog, the thumbnails it lists and tracked-thumbnail deletions —
# never untracked thumbnails of files that aren't published.
stage_catalog() {
    ./update-catalog.py --tracked-only
    git add -- catalog.json "$@"
    python3 -c 'import json; print("\0".join(e["thumb"] for e in json.load(open("catalog.json"))), end="")' | xargs -0 git add --
    git add -u -- thumbs
}
stage_catalog meta.json
PATHS=("$TARGET" catalog.json meta.json thumbs)
if ! git diff --cached --quiet -- "${PATHS[@]}"; then
    git commit -q -m "Add community wallpaper: ${TARGET:t:r}" -- "${PATHS[@]}"
fi
if [[ "$(git rev-list --count '@{u}..HEAD')" -gt 0 ]]; then
    BEFORE="$(git rev-parse '@{u}')"
    # A conflict -X theirs can't settle must not leave the shared clone
    # mid-rebase (the production publisher commits from it too) — but only
    # a rebase this pull started is ours to abort.
    WAS_REBASING=0; rebasing && WAS_REBASING=1
    if ! git pull -q --rebase --autostash -X theirs; then
        if [[ $WAS_REBASING == 0 ]] && rebasing; then git rebase --abort 2>/dev/null; fi
        exit 1
    fi
    if [[ "$(git rev-parse '@{u}')" != "$BEFORE" ]]; then
        # Someone else pushed meanwhile — rebuild so the catalog lists both.
        stage_catalog
        git diff --cached --quiet -- catalog.json thumbs || git commit -q -m "Regenerate catalog" -- catalog.json thumbs
    fi
    git push -q
fi
for f in catalog.json removed.json; do
    curl -s -o /dev/null --max-time 10 "https://purge.jsdelivr.net/gh/SyedInayatShah/wallpaper-studio-library@main/$f" || true
done
echo "Published: $TARGET. Live in the app after refresh."
