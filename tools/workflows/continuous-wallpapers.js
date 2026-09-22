export const meta = {
  name: 'continuous-wallpapers',
  description: 'Endless cycle: invent, create, judge, refine and PUBLISH one still + one live loop + one dynamic scene per round, until stopped or limits are hit',
  phases: [
    { title: 'Ideas', detail: 'invent three original, distinct briefs (still, live, dynamic)' },
    { title: 'Create', detail: 'one artist per wallpaper' },
    { title: 'Judge', detail: '3-lens panel' },
    { title: 'Refine', detail: 'one fix round if needed' },
    { title: 'Publish', detail: 'copy finals, catalog, git push, CDN purge' },
  ],
}

const LIB = '/Users/syedinayatshah/wallpaper-studio-library'
const B = `${LIB}/tools/bin/wsrender`
const MAX_CYCLES = args.maxCycles || 60
const made = [...(args.existing || [])]
const ART = { model: 'claude-opus-5', effort: 'high' }
const JUDGE = { model: 'claude-sonnet-5', effort: 'medium' }
const PUB = { model: 'claude-sonnet-5', effort: 'low' }

const IDEAS = {
  type: 'object',
  properties: {
    briefs: {
      type: 'array', minItems: 3, maxItems: 3,
      items: {
        type: 'object',
        properties: {
          slug: { type: 'string' }, title: { type: 'string' },
          kind: { type: 'string', description: 'still | live | dynamic' },
          style: { type: 'string', description: 'photoreal | stylized' },
          frames: { type: 'number', description: 'live only: 240 (8 s), 300 (10 s), 450 (15 s) or 600 (20 s)' },
          maxrate: { type: 'number', description: 'live only: 12 for 240/300 frames, 9 for 450, 7 for 600' },
          brief: { type: 'string', description: 'a rich, specific art brief (120-220 words)' },
        },
        required: ['slug', 'title', 'kind', 'style', 'brief'],
      },
    },
  },
  required: ['briefs'],
}
const RESULT = {
  type: 'object',
  properties: {
    slug: { type: 'string' }, kind: { type: 'string' },
    scenePath: { type: 'string' }, finalPath: { type: 'string' },
    reviewImages: { type: 'array', items: { type: 'string' } },
    seamReport: { type: 'string' }, fileMB: { type: 'number' }, notes: { type: 'string' },
  },
  required: ['slug', 'kind', 'scenePath', 'finalPath', 'reviewImages', 'notes'],
}
const VERDICT = { type: 'object', properties: { score: { type: 'number' }, verdict: { type: 'string' }, mustFix: { type: 'array', items: { type: 'string' } }, niceToHave: { type: 'array', items: { type: 'string' } } }, required: ['score', 'verdict', 'mustFix', 'niceToHave'] }
const PUBLISHED = { type: 'object', properties: { published: { type: 'array', items: { type: 'string' } }, skipped: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } }, required: ['published', 'skipped', 'notes'] }

const sceneFile = s => `${LIB}/${s.kind === 'dynamic' ? 'dynamic' : 'scenes'}/${s.slug}.metal`

function specFor(s) {
  if (s.kind === 'still') return `STILL. Final: \`${B} ${sceneFile(s)} --out <final.jpg> --size 3840x2400 --spp 16\` (≤ ~5 min; --spp 8 only if necessary).`
  if (s.kind === 'dynamic') return `DYNAMIC (real-time, time-of-day) WALLPAPER — read the README's "Dynamic (time-of-day) wallpapers" section. Rendered LIVE by the app at ~24 fps, 1 spp, ~67% res + MetalFX, driven by ctx.sunDir / sunElevation / moonDir / moonIllum / dayTime, motion from ctx.time. Deliverables: \`--daycycle <sheet.png>\`, 1920x1200 --spp 1 previews at --moment "midday", "golden hour", "sunset", "dusk" and --hour 23, two --time previews (motion), and \`--bench\` MUST be ≤ 8 ms/frame. Anti-alias analytically; nothing may shimmer at 1 spp.`
  const frames = s.frames || 300, seconds = Math.round(frames / 30)
  return `LIVE LOOP, ${seconds} SECONDS (${frames} frames). Final: \`${B} ${sceneFile(s)} --out <final.mp4> --frames ${frames} --fps 30 --size 2560x1600 --spp 2 --maxrate ${s.maxrate || 12}\`. Timing test first (--frames 10 at 2560x1600, ≤ ~2.5 s/frame or optimise). Run the FINAL with run_in_background: true and poll. File ≤ 19 MB. MUST pass \`--seam\` (wrapDiff < 0.05, seam step normal, loopRange ≥ ~2, perFrameStep ≲ 4). Also --sheet and a poster (ffmpeg -y -v error -ss 3 -i <final.mp4> -frames:v 1 <poster.png>).`
}

const COMMON = `You are a world-class technical artist (Inigo Quilez / Shadertoy / film-VFX calibre) creating a wallpaper for a macOS wallpaper app's public library, using ONLY procedural Metal shader scenes (no external images). Photoreal pieces must look like real photographs or high-end cinematic renders; stylized pieces must be gallery-quality original art — never a cheap "shader demo". Everything ORIGINAL (no copyrighted characters, logos, brands, or copies of specific famous artworks).
Toolkit — READ FIRST: ${LIB}/tools/README.md and ${LIB}/tools/wsrender/prelude.metal. Renderer: ${B}.
Rules: scene source at the given path; renders under ${LIB}/work/<slug>/ (create it). Do NOT modify tools/, prelude.metal, stills/, live/, other dynamic scenes, catalog/meta files, or run git. Disk is tight: delete superseded previews; keep the work folder under ~150 MB. Open every render with Read and critique it like a harsh art director; inspect 1:1 crops. The M1 GPU is shared — keep scenes efficient. Desktop composition: calm top strip and top-right, calm bottom strip, strong focal point, depth, comfortable brightness.`

const createPrompt = s => `${COMMON}

YOUR WALLPAPER: "${s.title}" — slug \`${s.slug}\` — ${s.kind.toUpperCase()} — style ${s.style.toUpperCase()}
Scene file: ${sceneFile(s)}
Art brief: ${s.brief}

${specFor(s)}

Process: read the toolkit; plan; write the scene; iterate with previews${s.kind === 'live' ? ' (+ --sheet, --seam)' : s.kind === 'dynamic' ? ' (+ --daycycle, --bench)' : ''}, opening every image; at least 6 serious iterations with brutal critiques until you honestly rate it ≥ 9/10.
Round-0 deliverables in ${LIB}/work/${s.slug}/: scene-r0.metal, ${s.kind === 'still' ? 'final-r0.jpg' : s.kind === 'live' ? 'final-r0.mp4, sheet-r0.png, poster-r0.png, --seam output' : 'day-r0.png, midday/golden/sunset/dusk/night-r0.png, motion-r0-a/b.png, --bench output'}, crop-r0-a.png, crop-r0-b.png. Return the structured result with absolute paths (finalPath = ${s.kind === 'dynamic' ? 'day-r0.png' : 'the final file'}).`

const LENSES = [
  { key: 'realism', photo: 'PHOTOREALISM & LIGHT — would a viewer believe this is a real photograph / film footage? Light, scale, materials, multi-scale detail, grading. Penalize flat vector, plastic CG, shader-demo vibes. 10 = indistinguishable from superb photography; 7 = good CG; 5 = obviously procedural.', styl: 'CRAFT & STYLE — a beautiful, polished, ORIGINAL piece that fully commits to its style? Intentionality, composition, colour, texture, richness. Penalize cheap shader-demo looks, muddy noise, generic gradients. 10 = stunning; 7 = decent; 5 = tech demo.' },
  { key: 'technical', photo: 'TECHNICAL QUALITY — banding, aliasing, noise, moiré, repetition, seams, NaN pixels, clipping, raymarch artifacts, low-detail regions at full res. Live: seam report, flicker, smoothness, ≤ 19 MB. Dynamic: bench ≤ 8 ms, no shimmer at 1 spp, smooth correct day-long transitions.' },
  { key: 'design', photo: 'WALLPAPER DESIGN & CREATIVITY — beauty, mood, composition, focal point, depth, colour harmony, brightness comfort, icon/menu-bar/Dock legibility, fulfilment of the brief; live motion interesting and natural; dynamic delightful at every hour.' },
]
function judgePrompt(s, r, lens) {
  const text = (s.style === 'stylized' && lens.styl) ? lens.styl : lens.photo
  const help = s.kind === 'dynamic' ? `DYNAMIC scene ${r.scenePath}; bench: ${r.seamReport || '(run --bench yourself)'}; you may render extra checks with ${B} (--hour 21, --moment sunrise, --time 0 vs 1).`
    : s.kind === 'live' ? `LIVE LOOP ${r.finalPath}; seam: ${r.seamReport || '(run --seam)'}; ${r.fileMB ?? '?'} MB. Check flicker via two consecutive frames (ffmpeg -ss 4 -frames:v 2).` : `STILL ${r.finalPath}.`
  return `You are an uncompromising judge reviewing a procedural wallpaper. Your lens: ${text}
Wallpaper "${s.title}" (${s.kind}, ${s.style}). Brief: ${s.brief}
${help}
Images (open with Read): ${r.reviewImages.join(', ')}. Crops under ${LIB}/work/${s.slug}/judge/. Do not edit anything. Artist notes: ${r.notes}
Score harshly on your lens only; mustFix items specific and actionable. Return the structured verdict.`
}
function refinePrompt(s, r, verdicts) {
  const critique = verdicts.map(v => `[${v.lens}] ${v.score}: ${v.verdict}\n  MUST FIX: ${v.mustFix.join(' | ') || '—'}\n  nice: ${v.niceToHave.join(' | ') || '—'}`).join('\n')
  return `${COMMON}

REFINING after a judge panel. "${s.title}" — slug \`${s.slug}\` — ${s.kind.toUpperCase()} — ${s.style}. Scene file ${sceneFile(s)} (restore from ${r.scenePath} first). Brief: ${s.brief}
Current deliverable ${r.finalPath}; images ${r.reviewImages.join(', ')}; notes: ${r.notes}
Panel critique:
${critique}

${specFor(s)}
Fix every must-fix without regressing strengths (≥ 4 preview iterations). Deliverables with suffix -r1 in ${LIB}/work/${s.slug}/ (never overwrite r0). Return the structured result.`
}

const avgOf = vs => (vs.length ? vs.reduce((a, v) => a + v.score, 0) / vs.length : 0)
const passes = vs => vs.length === 3 && avgOf(vs) >= 8.5 && vs.every(v => v.score >= 7.5)
async function robust(prompt, opts, tries = 4) {
  for (let i = 0; i < tries; i++) {
    const r = await agent(prompt, i === 0 ? opts : { ...opts, label: `${opts.label}~retry${i}` })
    if (r) return r
    log(`${opts.label}: attempt ${i + 1} failed`)
  }
  return null
}
async function judge(s, r, tag) {
  const vs = await parallel(LENSES.map(l => () => robust(judgePrompt(s, r, l), { ...JUDGE, label: `judge:${s.slug}:${l.key}${tag}`, phase: 'Judge', schema: VERDICT }).then(v => (v ? { ...v, lens: l.key } : null))))
  return vs.filter(Boolean)
}

const CATEGORIES = ['nature & scenery', 'weather & seasons', 'cities & architecture', 'oceans, rivers & ice', 'space & planets', 'fictional worlds (realistic)', 'cyberpunk / sci-fi fiction', 'fantasy landscapes (realistic)', 'abstract 3D art', 'surreal art', 'stylized graphic art (paper-cut, ink wash, low-poly, risograph)', 'macro & materials', 'aerial / drone views', 'deserts & canyons', 'forests & trees', 'mountains & valleys', 'night & light phenomena', 'gardens, temples & ruins']

const summaryOf = []
for (let cycle = 0; cycle < MAX_CYCLES; cycle++) {
  const cat = [CATEGORIES[(cycle * 3) % CATEGORIES.length], CATEGORIES[(cycle * 3 + 1) % CATEGORIES.length], CATEGORIES[(cycle * 3 + 2) % CATEGORIES.length]]
  phase('Ideas')
  const ideas = await robust(`You are the creative director of a macOS wallpaper app's public library of ORIGINAL procedural wallpapers. Invent THREE new wallpaper briefs for this round: exactly one STILL, one LIVE loop (choose frames 240/300/450/600 with the matching maxrate 12/12/9/7 — vary lengths across rounds), and one DYNAMIC time-of-day scene (a real-time scene driven by the actual clock: sunrise, midday, sunset, night — either a made-up-but-natural landscape or a fictional/sci-fi/cyberpunk place). Mix styles: mostly hyper-realistic (style "photoreal"), sometimes abstract/surreal/stylized art (style "stylized").
Theme suggestions for this round (bend them creatively): still → ${cat[0]}; live → ${cat[1]}; dynamic → ${cat[2]}.
Read ${LIB}/catalog.json and avoid anything similar to these existing/in-progress titles: ${made.join(', ')}.
Slugs: kebab-case, unique. Briefs: rich and specific (camera, lighting, materials, mood, what moves and how it loops, what changes across the day for dynamics), 120-220 words each, original — no copyrighted characters, brands, or copies of known artworks. Return the structured briefs.`, { ...ART, label: `ideas#${cycle + 1}`, phase: 'Ideas', schema: IDEAS }, 3)
  if (!ideas) { log('idea generation failed repeatedly — stopping (limits?)'); break }
  const briefs = ideas.briefs.filter(b => ['still', 'live', 'dynamic'].includes(b.kind) && !made.includes(b.slug))
  briefs.forEach(b => { made.push(b.slug); if (!b.style) b.style = 'photoreal' })
  log(`round ${cycle + 1}: ${briefs.map(b => b.kind + ':' + b.slug).join(', ')}`)

  const results = await pipeline(
    briefs,
    s => robust(createPrompt(s), { ...ART, label: `create:${s.slug}`, phase: 'Create', schema: RESULT }),
    async (r, s) => {
      if (!r) return null
      let cur = r, verdicts = await judge(s, cur, '')
      let best = { result: cur, verdicts, avg: avgOf(verdicts) }
      if (!passes(verdicts)) {
        const refined = await robust(refinePrompt(s, cur, verdicts), { ...ART, label: `refine:${s.slug}`, phase: 'Refine', schema: RESULT })
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
  if (!done.length) { log('nothing finished this round — stopping'); break }

  phase('Publish')
  const items = done.map(d => `- slug ${d.scene.slug} | kind ${d.scene.kind} | title "${d.scene.title}" | score ${d.best.avg.toFixed(1)} | final: ${d.best.result.finalPath} | scene snapshot: ${d.best.result.scenePath} | fileMB: ${d.best.result.fileMB ?? 'n/a'}`).join('\n')
  const pub = await robust(`You are the release engineer for the Wallpaper Studio public library at ${LIB} (a git repo; you may run git here). Publish these finished wallpapers:
${items}

Steps (bash):
1. cd ${LIB}
2. For each item — still: cp its final to stills/<slug>.jpg; live: verify the .mp4 is ≤ 19 MB (else skip it and say so), cp to live/<slug>.mp4; dynamic: cp the scene snapshot to dynamic/<slug>.metal.
3. Update meta.json (JSON object keyed by slug): set {"creator": "Wallpaper Studio", "created": "<today as M/D/YY from \`date +%-m/%-d/%y\`>"} for each published slug (python3 is fine).
4. Run ./update-catalog.py (it rebuilds catalog.json, thumbnails, and renders dynamic thumbs).
5. Before committing: "ls dynamic/" must contain ONLY .metal scenes of kind dynamic (a publisher once copied still scenes there — delete any stray that is not a dynamic item) and "git status --short" must show no scenes/, tools/ or work/ paths staged. Then, in ONE command (the maintainer app may rewrite catalog.json in between, so it must be regenerated right before staging): ./update-catalog.py && git add stills live dynamic meta.json removed.json catalog.json thumbs && (git diff --cached --quiet || git commit -m "Add wallpapers: <slugs>") && git pull --rebase --autostash && git push — stage ONLY those paths (never add everything: scenes/, tools/ and drafts must not be published); if git reports an index.lock or a rejected push, wait 30 s, "git pull --rebase", and retry (another agent may be committing maintenance changes). If ./update-catalog.py fails, run "python3 -m py_compile update-catalog.py"; if it is mid-edit by a maintainer, wait 5 min and retry (max 3 times).
6. Purge the CDN cache: for f in catalog.json removed.json; do curl -s "https://purge.jsdelivr.net/gh/SyedInayatShah/wallpaper-studio-library@main/$f" >/dev/null; done
7. Free disk: in work/<slug>/ for each published item delete preview/iteration images and judge crops, keeping only final*, scene-*.metal, sheet*, poster*, day*.
Never touch stills/dm.* or files of other wallpapers. Return the structured summary.`, { ...PUB, label: `publish#${cycle + 1}`, phase: 'Publish', schema: PUBLISHED }, 3)
  summaryOf.push({ round: cycle + 1, wallpapers: done.map(d => ({ slug: d.scene.slug, kind: d.scene.kind, title: d.scene.title, avg: Number(d.best.avg.toFixed(2)) })), published: pub ? pub.published : [], skipped: pub ? pub.skipped : done.map(d => d.scene.slug) })
  log(`round ${cycle + 1} published: ${pub ? pub.published.join(', ') : 'PUBLISH FAILED'}`)
}
return { rounds: summaryOf, allSlugs: made }
