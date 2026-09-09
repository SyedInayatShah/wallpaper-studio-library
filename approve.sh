#!/bin/zsh
# Approves a submitted wallpaper: downloads it, adds it to the library,
# regenerates the catalog, and pushes.
# Usage: ./approve.sh <file-url-from-issue> <kebab-case-name> <still|live> [creator] [date like 9/9/26]
set -e
cd "$(dirname "$0")"

URL="$1"; NAME="$2"; KIND="$3"; CREATOR="$4"; CREATED="${5:-$(date +%-m/%-d/%y)}"
if [[ -z "$URL" || -z "$NAME" || ( "$KIND" != "still" && "$KIND" != "live" ) ]]; then
    echo "Usage: ./approve.sh <file-url> <kebab-case-name> <still|live> [creator] [date]"
    exit 1
fi

EXT="${URL##*.}"
EXT="${EXT%%\?*}"
case "$KIND" in
    still) [[ "$EXT" =~ ^(jpg|jpeg|png)$ ]] || EXT="jpg"; DIR="stills" ;;
    live)  [[ "$EXT" =~ ^(mp4|mov|gif)$ ]] || EXT="mp4"; DIR="live" ;;
esac

curl -L -o "$DIR/$NAME.$EXT" "$URL"
NAME="$NAME" CREATOR="$CREATOR" CREATED="$CREATED" python3 - <<'EOF'
import json, os
meta_path = "meta.json"
meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
entry = {}
if os.environ.get("CREATOR"):
    entry["creator"] = os.environ["CREATOR"]
if os.environ.get("CREATED"):
    entry["created"] = os.environ["CREATED"]
meta[os.environ["NAME"]] = entry
json.dump(meta, open(meta_path, "w"), indent=2)
EOF
./update-catalog.py
git add -A
git commit -m "Add community wallpaper: $NAME"
git push
echo "Published: $NAME ($KIND). Live in the app after refresh."
