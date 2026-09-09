# Wallpaper Studio — Public Library

The public wallpaper catalog for the **Wallpaper Studio** macOS app. The app's
Explore tab fetches `catalog.json` from this repo and shows everything listed.

## Adding wallpapers

1. Drop still images (`.jpg`/`.png`) into `stills/`, or loop videos/GIFs
   (`.mp4`/`.gif`) into `live/`. Use kebab-case filenames — they become the
   title (`neon-city.mp4` → "Neon City").
2. Run `./update-catalog.py` (regenerates thumbnails + `catalog.json`).
3. Commit and push. The app picks it up on next refresh.

Only add content you created or that is licensed for redistribution.
All seed wallpapers here are original, procedurally generated art (public domain).
