export const meta = {
  name: 'master-wallpapers',
  description: 'Prioritised, limit-aware production of all wallpapers: 3 at a time, judge, one fix round, publish each group to Explore',
  phases: [
    { title: 'Create', detail: 'artists (Opus) read their brief from briefs.json' },
    { title: 'Judge', detail: '3-lens panel (Sonnet)' },
    { title: 'Refine', detail: 'one fix round when needed' },
    { title: 'Publish', detail: 'copy finals, catalog, git push, CDN purge' },
  ],
}
const LIB = '/Users/syedinayatshah/wallpaper-studio-library'
const B = `${LIB}/tools/bin/wsrender`
const BRIEFS = `${LIB}/work/briefs.json`
const ITEMS = args.items
const CHUNK = args.chunk || 3
const ART = { model: 'claude-opus-5', effort: 'high' }
const JUDGE = { model: 'claude-sonnet-5', effort: 'medium' }
const PUB = { model: 'claude-sonnet-5', effort: 'low' }

const RESULT = { type: 'object', properties: { slug: { type: 'string' }, kind: { type: 'string' }, scenePath: { type: 'string' }, finalPath: { type: 'string' }, reviewImages: { type: 'array', items: { type: 'string' } }, seamReport: { type: 'string' }, fileMB: { type: 'number' }, notes: { type: 'string' } }, required: ['slug', 'kind', 'scenePath', 'finalPath', 'reviewImages', 'notes'] }
const VERDICT = { type: 'object', properties: { score: { type: 'number' }, verdict: { type: 'string' }, mustFix: { type: 'array', items: { type: 'string' } }, niceToHave: { type: 'array', items: { type: 'string' } } }, required: ['score', 'verdict', 'mustFix', 'niceToHave'] }
const PUBLISHED = { type: 'object', properties: { published: { type: 'array', items: { type: 'string' } }, skipped: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } }, required: ['published', 'skipped', 'notes'] }

const sceneFile = s => `${LIB}/${s.kind === 'dynamic' ? 'dynamic' : 'scenes'}/${s.slug}.metal`
function specFor(s) {
  if (s.kind === 'still') return `STILL. Final: \`${B} ${sceneFile(s)} --out <final.jpg> --size 3840x2400 --spp 16\` (≤ ~5 min; --spp 8 only if necessary).`
  if (s.kind === 'dynamic') return `DYNAMIC (real-time, time-of-day) WALLPAPER — read the README's "Dynamic (time-of-day) wallpapers" section. Rendered LIVE by the app (~24 fps, 1 spp, ~67% res + MetalFX) from ctx.sunDir / sunElevation / moonDir / moonIllum / dayTime; motion from ctx.time. Deliverables: \`--daycycle <sheet.png>\`, 1920x1200 --spp 1 previews at --moment "midday", "golden hour", "sunset", "dusk" and --hour 23, two --time previews, and \`--bench\` which MUST be ≤ 8 ms/frame. Anti-alias analytically; nothing may shimmer at 1 spp.`
  const frames = s.frames || 300, seconds = Math.round(frames / 30)
  return `LIVE LOOP, ${seconds} SECONDS (${frames} frames). Final: \`${B} ${sceneFile(s)} --out <final.mp4> --frames ${frames} --fps 30 --size 2560x1600 --spp 2 --maxrate ${s.maxrate || 12}\`. Timing test first (--frames 10 at 2560x1600, ≤ ~2.5 s/frame or optimise). Run the FINAL with run_in_background: true and poll until done. File ≤ 19 MB. MUST pass \`--seam\` (wrapDiff < 0.05, seam step normal, loopRange ≥ ~2, perFrameStep ≲ 4). Also --sheet and a poster (ffmpeg -y -v error -ss 3 -i <final.mp4> -frames:v 1 <poster.png>).`
}
const COMMON = `You are a world-class technical artist (Inigo Quilez / Shadertoy / film-VFX calibre) creating a wallpaper for a macOS wallpaper app's public library using ONLY procedural Metal shader scenes. Photoreal pieces must look like real photographs or high-end cinematic renders; stylized pieces must be gallery-quality original art — never a cheap "shader demo". Everything ORIGINAL (no copyrighted characters, brands, or copies of specific artworks).
Toolkit — READ FIRST: ${LIB}/tools/README.md and ${LIB}/tools/wsrender/prelude.metal. Renderer: ${B}.
Rules: scene source at the given path; renders under ${LIB}/work/<slug>/. Do NOT modify tools/, prelude.metal, stills/, live/, other scenes, catalog/meta files, or run git. Disk is VERY tight (~4 GB free): delete superseded previews as you go; keep your work folder under ~80 MB; if "df -g /" shows < 2 GB available, delete your own previews before rendering more. Open every render with Read and critique it like a harsh art director; inspect 1:1 crops. The M1 GPU is shared — keep scenes efficient. Desktop composition: calm top strip and top-right, calm bottom strip, strong focal point, depth, comfortable brightness. Be token-efficient: think, render, look, fix — no long essays.`
const createPrompt = s => `${COMMON}

YOUR WALLPAPER: slug \`${s.slug}\` — ${s.kind.toUpperCase()} — style ${s.style.toUpperCase()}. Your TITLE and ART BRIEF are in ${BRIEFS} under the key "${s.slug}" — read that file first and follow the brief exactly (it may include the owner's feedback, which is the highest priority).
Scene file: ${sceneFile(s)}

${specFor(s)}

An earlier run may have left a draft at that scene path or under ${LIB}/work/${s.slug}/ (if final-r0.* already exists there and clearly meets the brief, validate it and return it; otherwise continue from the best draft or start fresh). Iterate with previews${s.kind === 'live' ? ' (+ --sheet, --seam)' : s.kind === 'dynamic' ? ' (+ --daycycle, --bench)' : ''}, opening every image; at least 4 serious iterations with brutal critiques until you honestly rate it ≥ 9/10.
Round-0 deliverables in ${LIB}/work/${s.slug}/: scene-r0.metal, ${s.kind === 'still' ? 'final-r0.jpg' : s.kind === 'live' ? 'final-r0.mp4, sheet-r0.png, poster-r0.png, --seam output' : 'day-r0.png, midday/golden/sunset/dusk/night-r0.png, motion-r0-a/b.png, --bench output'}, crop-r0-a.png, crop-r0-b.png. Return the structured result with absolute paths (finalPath = ${s.kind === 'dynamic' ? 'day-r0.png' : 'the final file'}; seamReport = seam/bench output).`
const LENSES = [
  { key: 'realism', photo: 'PHOTOREALISM & LIGHT — would a viewer believe this is a real photograph / film footage? Light, scale, materials, multi-scale detail, grading. Penalize flat vector, plastic CG, shader-demo vibes. 10 = indistinguishable from superb photography; 7 = good CG; 5 = obviously procedural.', styl: 'CRAFT & STYLE — a beautiful, polished, ORIGINAL piece fully committed to its style? Intentionality, composition, colour, texture, richness. Penalize cheap shader-demo looks. 10 = stunning; 7 = decent; 5 = tech demo.' },
  { key: 'technical', photo: 'TECHNICAL QUALITY — banding, aliasing, noise, moiré, repetition, seams, NaN pixels, clipping, raymarch artifacts, low-detail regions at full res. Live: seam report, flicker, smoothness, ≤ 19 MB. Dynamic: bench ≤ 8 ms, no shimmer at 1 spp, smooth correct day-long transitions.' },
  { key: 'design', photo: 'WALLPAPER DESIGN & CREATIVITY — beauty, mood, composition, focal point, depth, colour harmony, brightness comfort, icon/menu-bar/Dock legibility, fulfilment of the brief; live motion interesting and natural; dynamic delightful at every hour.' },
]
function judgePrompt(s, r, lens) {
  const text = (s.style === 'stylized' && lens.styl) ? lens.styl : lens.photo
  const help = s.kind === 'dynamic' ? `DYNAMIC scene ${r.scenePath}; bench: ${r.seamReport || '(run --bench)'}. Extra checks allowed with ${B} (--hour 21, --moment sunrise, --time 0 vs 1).`
    : s.kind === 'live' ? `LIVE LOOP ${r.finalPath}; seam: ${r.seamReport || '(run --seam)'}; ${r.fileMB ?? '?'} MB. Check flicker with two consecutive frames (ffmpeg -ss 4 -frames:v 2).` : `STILL ${r.finalPath}.`
  return `You are an uncompromising judge reviewing a procedural wallpaper. Your lens: ${text}
Wallpaper slug ${s.slug} (${s.kind}, ${s.style}); its brief is in ${BRIEFS} under "${s.slug}" (read it). ${help}
Images (open with Read): ${r.reviewImages.join(', ')}. Crops under ${LIB}/work/${s.slug}/judge/. Do not edit anything. Artist notes: ${r.notes}
Score harshly on your lens only; mustFix items specific and actionable; be concise. Return the structured verdict.`
}
function refinePrompt(s, r, verdicts) {
  const critique = verdicts.map(v => `[${v.lens}] ${v.score}: ${v.verdict}\n  MUST FIX: ${v.mustFix.join(' | ') || '—'}\n  nice: ${v.niceToHave.join(' | ') || '—'}`).join('\n')
  return `${COMMON}

REFINING after a judge panel. Slug \`${s.slug}\` — ${s.kind.toUpperCase()} — ${s.style}. Brief in ${BRIEFS} under "${s.slug}" (read it). Scene file ${sceneFile(s)} (restore from ${r.scenePath} first). Current deliverable ${r.finalPath}; images ${r.reviewImages.join(', ')}; notes: ${r.notes}
Panel critique:
${critique}

${specFor(s)}
Fix every must-fix without regressing strengths (≥ 3 preview iterations). Deliverables with suffix -r1 in ${LIB}/work/${s.slug}/ (never overwrite r0). Return the structured result.`
}
const avgOf = vs => (vs.length ? vs.reduce((a, v) => a + v.score, 0) / vs.length : 0)
const passes = vs => vs.length === 3 && avgOf(vs) >= 8.5 && vs.every(v => v.score >= 7.5)
async function robust(prompt, opts, tries = 3) {
  for (let i = 0; i < tries; i++) {
    const r = await agent(prompt, i === 0 ? opts : { ...opts, label: `${opts.label}~retry${i}` })
    if (r) return r
  }
  return null
}
const judge = async (s, r, tag) => (await parallel(LENSES.map(l => () =>
  robust(judgePrompt(s, r, l), { ...JUDGE, label: `judge:${s.slug}:${l.key}${tag}`, phase: 'Judge', schema: VERDICT }).then(v => (v ? { ...v, lens: l.key } : null))))).filter(Boolean)

const summary = []
let limitHit = false
for (let i = 0; i < ITEMS.length; i += CHUNK) {
  const chunk = ITEMS.slice(i, i + CHUNK)
  log(`group ${i / CHUNK + 1}: ${chunk.map(s => s.slug).join(', ')}`)
  const results = await pipeline(
    chunk,
    s => robust(createPrompt(s), { ...ART, label: `create:${s.slug}`, phase: 'Create', schema: RESULT }),
    async (r, s) => {
      if (!r) return null
      let verdicts = await judge(s, r, '')
      let best = { result: r, verdicts, avg: avgOf(verdicts) }
      if (verdicts.length && !passes(verdicts)) {
        const refined = await robust(refinePrompt(s, r, verdicts), { ...ART, label: `refine:${s.slug}`, phase: 'Refine', schema: RESULT })
        if (refined) {
          const v2 = await judge(s, refined, '#1')
          if (avgOf(v2) > best.avg) best = { result: refined, verdicts: v2, avg: avgOf(v2) }
        }
      }
      log(`${s.slug}: avg ${best.avg.toFixed(1)}`)
      return { scene: s, best }
    },
  )
  const done = results.filter(Boolean)
  if (!done.length) { limitHit = true; log('whole group failed — probably the usage limit; stopping here'); break }
  const items = done.map(d => `- slug ${d.scene.slug} | kind ${d.scene.kind} | score ${d.best.avg.toFixed(1)} | final: ${d.best.result.finalPath} | scene snapshot: ${d.best.result.scenePath} | fileMB: ${d.best.result.fileMB ?? 'n/a'}${d.scene.replaces ? ` | REPLACES old ${d.scene.oldKind} "${d.scene.replaces}"` : ''}`).join('\n')
  const pub = await robust(`You are the release engineer for the Wallpaper Studio public library at ${LIB} (a git repo; you may run git here). Publish these finished wallpapers:
${items}
Titles are in ${BRIEFS} under each slug.

Steps (bash):
1. cd ${LIB}
2. Per item — still: cp final to stills/<slug>.jpg; live: verify the .mp4 is ≤ 19 MB (else skip and report), cp to live/<slug>.mp4; dynamic: cp the scene snapshot to dynamic/<slug>.metal.
3. For an item that REPLACES an old wallpaper: delete the old file (stills/<old>.jpg or live/<old>.mp4, whichever exists; update-catalog.py deletes its stale thumbnail), remove <old> from meta.json, and append to removed.json (a JSON array) {"id": "<oldKind>-<old>", "title": "<Old Title Case>", "reason": "Replaced by the new hyper-realistic version — see Explore.", "removed": "<today M/D/YY>"}.
4. meta.json (object keyed by slug): set {"creator": "Wallpaper Studio", "created": "<today via \`date +%-m/%-d/%y\`>"} for each published slug (python3 is fine).
5. ./update-catalog.py
6. Before committing: "ls dynamic/" must contain ONLY .metal scenes of kind dynamic (a publisher once copied still scenes there — delete any stray that is not a dynamic item) and "git status --short" must show no scenes/, tools/ or work/ paths staged. Then, in ONE command (the maintainer app may rewrite catalog.json in between, so it must be regenerated right before staging): ./update-catalog.py && git add stills live dynamic meta.json removed.json catalog.json thumbs && (git diff --cached --quiet || git commit -m "Add wallpapers: <slugs>") && git pull --rebase --autostash && git push — stage ONLY those paths (never add everything: scenes/, tools/ and drafts must not be published); if git reports an index.lock or a rejected push, wait 30 s, "git pull --rebase", and retry (another agent may be committing maintenance changes). If ./update-catalog.py fails, run "python3 -m py_compile update-catalog.py"; if it is mid-edit by a maintainer, wait 5 min and retry (max 3 times).
7. Purge CDN: for f in catalog.json removed.json; do curl -s "https://purge.jsdelivr.net/gh/SyedInayatShah/wallpaper-studio-library@main/$f" >/dev/null; done
8. Free disk: in work/<slug>/ of each published item delete preview/iteration images and judge crops, keeping final*, scene-*.metal, sheet*, poster*, day*.
Never touch stills/dm.* or other wallpapers' files. Be concise. Return the structured summary.`, { ...PUB, label: `publish:group${i / CHUNK + 1}`, phase: 'Publish', schema: PUBLISHED })
  summary.push({ group: i / CHUNK + 1, wallpapers: done.map(d => ({ slug: d.scene.slug, kind: d.scene.kind, avg: Number(d.best.avg.toFixed(2)), final: d.best.result.finalPath })), published: pub ? pub.published : [], skipped: pub ? pub.skipped : done.map(d => d.scene.slug), failed: chunk.filter(s => !done.some(d => d.scene.slug === s.slug)).map(s => s.slug) })
  log(`group ${i / CHUNK + 1} published: ${pub ? pub.published.join(', ') : 'PUBLISH FAILED'}`)
}
let endless = null
if (!limitHit && args.continueForever) {
  log('all planned wallpapers done — starting the endless still → live → dynamic loop (standing order)')
  const existing = [...(args.existing || []), ...ITEMS.map(s => s.slug)]
  try { endless = await workflow({ scriptPath: `${LIB}/tools/workflows/continuous-wallpapers.js` }, { existing, maxCycles: args.maxCycles || 60 }) }
  catch (e) { log(`endless loop failed to start: ${e}`) }
}
return { limitHit, groups: summary, endless }
