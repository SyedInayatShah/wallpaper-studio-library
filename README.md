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

## Community submissions

Anyone can share a wallpaper: use **Submit Wallpaper** in the app (or
[open a submission issue](../../issues/new?template=submit-wallpaper.md) here),
attach the file, and confirm it's yours to share and appropriate.

Every submission is **reviewed by the maintainer before it appears** in the app.
To approve one, copy the attached file's URL from the issue and run:

```bash
./approve.sh <file-url> <kebab-case-name> <still|live>
```

Then close the issue. Rules: original or freely redistributable content only;
nothing NSFW, hateful, or containing personal information.
