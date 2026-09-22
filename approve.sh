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

TMP="$(mktemp -t wsapprove)"
trap 'rm -f "$TMP" "$TMP.jpg"' EXIT
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
DETECTED=$([[ "$DIR" == live ]] && echo live || echo still)
if [[ "$DETECTED" != "$KIND" ]]; then
    echo "note: the file is really a $DETECTED ($MIME) — publishing it as $DETECTED" >&2
fi

# Pick a slug nothing else uses (any kind, any extension, or meta.json) —
# approving must never overwrite a live wallpaper. An identical file already
# in the library (an earlier, interrupted run) is reused.
taken() {
    local slug="$1" f
    for f in stills/"$slug".*(N) live/"$slug".*(N) dynamic/"$slug".*(N) pending/"$slug".*(N); do
        cmp -s "$f" "$TMP" && { REUSE="$f"; return 1; }
        return 0
    done
    SLUG="$slug" python3 -c 'import json,os,sys; m=json.load(open("meta.json")) if os.path.exists("meta.json") else {}; sys.exit(0 if os.environ["SLUG"] in m else 1)'
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

./update-catalog.py
# Stage only what this approval touched — never unrelated work in the repo.
PATHS=("$TARGET" catalog.json meta.json thumbs)
git add -A -- "${PATHS[@]}"
if ! git diff --cached --quiet -- "${PATHS[@]}"; then
    git commit -q -m "Add community wallpaper: ${TARGET:t:r}" -- "${PATHS[@]}"
fi
if [[ "$(git rev-list --count '@{u}..HEAD')" -gt 0 ]]; then
    BEFORE="$(git rev-parse '@{u}')"
    git pull -q --rebase --autostash -X theirs
    if [[ "$(git rev-parse '@{u}')" != "$BEFORE" ]]; then
        # Someone else pushed meanwhile — rebuild so the catalog lists both.
        ./update-catalog.py
        git add -A -- catalog.json thumbs
        git diff --cached --quiet -- catalog.json thumbs || git commit -q -m "Regenerate catalog" -- catalog.json thumbs
    fi
    git push -q
fi
for f in catalog.json removed.json; do
    curl -s -o /dev/null --max-time 10 "https://purge.jsdelivr.net/gh/SyedInayatShah/wallpaper-studio-library@main/$f" || true
done
echo "Published: $TARGET. Live in the app after refresh."
