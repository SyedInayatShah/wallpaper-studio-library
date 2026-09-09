#!/bin/zsh
# Approves a submitted wallpaper: downloads it, adds it to the library,
# regenerates the catalog, and pushes.
# Usage: ./approve.sh <file-url-from-issue> <kebab-case-name> <still|live>
set -e
cd "$(dirname "$0")"

URL="$1"; NAME="$2"; KIND="$3"
if [[ -z "$URL" || -z "$NAME" || ( "$KIND" != "still" && "$KIND" != "live" ) ]]; then
    echo "Usage: ./approve.sh <file-url> <kebab-case-name> <still|live>"
    exit 1
fi

EXT="${URL##*.}"
EXT="${EXT%%\?*}"
case "$KIND" in
    still) [[ "$EXT" =~ ^(jpg|jpeg|png)$ ]] || EXT="jpg"; DIR="stills" ;;
    live)  [[ "$EXT" =~ ^(mp4|mov|gif)$ ]] || EXT="mp4"; DIR="live" ;;
esac

curl -L -o "$DIR/$NAME.$EXT" "$URL"
./update-catalog.py
git add -A
git commit -m "Add community wallpaper: $NAME"
git push
echo "Published: $NAME ($KIND). Live in the app after refresh."
