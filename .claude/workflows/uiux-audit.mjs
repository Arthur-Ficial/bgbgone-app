export const meta = {
  name: 'uiux-audit',
  description: 'Exhaustive UI/UX audit of bgbgone-app (every click, menu, control) → prioritized TDD+e2e remediation plan',
  whenToUse: 'Audit the macOS app UI/UX against Apple HIG + the Finder charter + the design SSOT, then emit a remediation plan. Re-run after fixes to burn it down.',
  phases: [
    { title: 'Boot', detail: 'build + launch the app, confirm peekaboo sees the window' },
    { title: 'Static review', detail: 'one reviewer per UI surface vs HIG + charter + SSOT' },
    { title: 'Live capture', detail: 'serial: drive every state/menu, screenshot each' },
    { title: 'Judge', detail: 'one vision-judge per screenshot' },
    { title: 'Verify', detail: 'adversarial skeptics refute each finding' },
    { title: 'Synthesize', detail: 'dedup, prioritize, write UIUX-REMEDIATION-PLAN.md' },
  ],
}

// ─── Constants ────────────────────────────────────────────────────────────────
const APP = '/Users/arthurficial/dev/bgbgone-tree/bgbgone-app'
const SHOTS = `${APP}/build/screenshots/audit`
const PLAN_OUT = `${APP}/design/review/UIUX-REMEDIATION-PLAN.md`
const SSOT = `${APP}/design/project/bgbgone.html`
const CHARTER = `${APP}/CLAUDE.md`
const TOKENS = `${APP}/Sources/Views/DesignTokens.swift`

// Authorities every reviewer/judge must weigh a surface against.
const AUTHORITIES = `Authorities for "correct", in priority order:
1. The app charter ${CHARTER} — "Finder, but for background removal": real NSWindow chrome,
   STOCK SwiftUI primitives only, system fonts (.system/.headline/...), SYSTEM accent via
   .tint(.accentColor) (NOT hardcoded blue), system materials (.regularMaterial/.thinMaterial),
   system semantic colors (.primary/.secondary/.tertiary). No fake chrome, no custom-painted
   OS elements, no placeholder art, no aspirational labels, no Stub/Mock/Fake in Sources/.
2. Apple Human Interface Guidelines (macOS) — fetch the relevant section (menus, context menus,
   toolbars, sidebars, color, typography, layout/spacing, controls, modality, accessibility,
   pointer/hit-target sizing, keyboard, VoiceOver). Cite the rule you check against.
3. The design SSOT ${SSOT} — layout/color/copy/interaction spec; drift > 3% is a release blocker.
4. Accessibility: every interactive element needs an accessibilityIdentifier (NONE exist today)
   AND an accessibility label/role; WCAG AA contrast; keyboard reachability; hit target >= HIG min.

KNOWN SEED VIOLATION (must appear in findings if you review tokens/color): ${TOKENS} hardcodes
DesignColor.accent = #007aff, but the charter mandates the SYSTEM accent (.tint(.accentColor)),
NOT a hardcoded blue. This is a genuine charter violation.`

// The finding schema, shared by static reviewers and visual judges.
const FINDING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          surface: { type: 'string', description: 'UI surface, e.g. "Context menu" or "Inspector / Config"' },
          title: { type: 'string', description: 'one-line issue title' },
          file: { type: 'string', description: 'Sources/ path (and :line if known) or screenshot path' },
          rule: { type: 'string', description: 'the specific HIG/charter/SSOT/a11y rule violated' },
          source: { type: 'string', enum: ['HIG', 'charter', 'SSOT', 'a11y', 'heuristic'] },
          severity: { type: 'string', enum: ['blocker', 'high', 'medium', 'low'] },
          evidence: { type: 'string', description: 'concrete observed fact (quoted code or what the screenshot shows)' },
          fixSketch: { type: 'string', description: 'how to fix it, in stock-SwiftUI terms' },
          testKind: { type: 'string', enum: ['source-scan', 'e2e-peekaboo', 'both'] },
        },
        required: ['surface', 'title', 'rule', 'source', 'severity', 'evidence', 'fixSketch', 'testKind'],
      },
    },
  },
  required: ['findings'],
}

const BOOT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    built: { type: 'boolean' },
    launchable: { type: 'boolean' },
    peekabooSeesWindow: { type: 'boolean' },
    notes: { type: 'string' },
  },
  required: ['built', 'launchable', 'peekabooSeesWindow', 'notes'],
}

const MANIFEST_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    shots: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          name: { type: 'string' },
          path: { type: 'string' },
          state: { type: 'string', description: 'what UI state/menu this captures' },
          captured: { type: 'boolean' },
        },
        required: ['name', 'path', 'state', 'captured'],
      },
    },
    notes: { type: 'string' },
  },
  required: ['shots', 'notes'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    real: { type: 'boolean', description: 'true only if the violation genuinely holds against the cited authority' },
    severityAdjusted: { type: 'string', enum: ['blocker', 'high', 'medium', 'low'] },
    reason: { type: 'string' },
  },
  required: ['real', 'severityAdjusted', 'reason'],
}

// ─── UI surface inventory (the review matrix) ──────────────────────────────────
const SURFACES = [
  { key: 'menubar', label: 'Menu bar + shortcuts', files: 'Sources/App/BgBgOneApp.swift (27-86), Sources/App/MenuBarPruner.swift', hig: 'macOS menus / keyboard shortcuts', states: '⌘O ⌘Z ⌘⇧Z ⌘A ⌘⇧A ⌘`; stripped groups; menu discoverability' },
  { key: 'toolbar', label: 'Toolbar', files: 'Sources/App/BgBgOneApp.swift (186-214)', hig: 'macOS toolbars', states: 'Add Files / Run all↔Stop toggle / Inspector toggle; placement, labels, icons' },
  { key: 'dnd', label: 'Drag & drop', files: 'Sources/App/BgBgOneApp.swift (162-183), Sources/Views/DropOverlays.swift', hig: 'drag and drop affordances', states: 'drop veil, ingest progress, summary chip; Finder-style blue inset highlight' },
  { key: 'sidebar', label: 'Sidebar', files: 'Sources/Views/SourceSidebar.swift', hig: 'macOS sidebars', states: 'All Files / Single Files / per-folder batches; .sidebar list style, badges' },
  { key: 'table', label: 'File table', files: 'Sources/Views/FileListView.swift', hig: 'tables / lists, selection', states: 'sort, multi-select, dbl-click open, Space=QuickLook, Return=open, Delete=remove' },
  { key: 'contextmenu', label: 'Context menu (right-click)', files: 'Sources/Views/FileListView.swift (184-207), Sources/Models/FileRowActions.swift', hig: 'context menus', states: '8 items incl. destructive Remove; ordering, grouping, dividers, destructive role/color, disabled states' },
  { key: 'preview', label: 'Dual preview', files: 'Sources/Views/Preview/BigDualPreview.swift, Sources/Views/Preview/PreviewSplitter.swift', hig: 'pointer gestures / zoom', states: 'pinch zoom 1-6x, pan, dbl-click reset, floating ±/⟲ controls, splitter drag cursor' },
  { key: 'inspector', label: 'Inspector / Config', files: 'Sources/App/BgBgOneApp.swift (250-324), Sources/Views/ConfigPanel.swift', hig: 'inspectors, segmented controls, color wells', states: 'Background/Format/Algorithm pickers, ColorPicker, Rerun button' },
  { key: 'settings', label: 'Settings forms', files: 'Sources/Views/Settings/MaskFiltersForm.swift, TransformsForm.swift, BackgroundFiltersForm.swift, AdvancedChainEditor.swift, ClickRowDisclosure.swift', hig: 'forms, sliders, steppers, disclosure', states: 'toggle+slider/stepper pairs, ranges, units, live validation, disclosure affordance' },
  { key: 'runhistory', label: 'Run history', files: 'Sources/Views/Inspector/RunHistoryView.swift', hig: 'lists / status', states: 'outcome rows, success/error iconography & color' },
  { key: 'statusbar', label: 'Status bar', files: 'Sources/Views/StatusBar.swift', hig: 'status footer', states: 'counts, Open Source/Output Folder buttons, monospaced path preview' },
  { key: 'modals', label: 'Modals', files: 'Sources/Views/FileListView.swift (93-105), Sources/App/BgBgOneApp.swift (.fileImporter), Sources/Views/ConfigPanel.swift (ColorPicker)', hig: 'modality, alerts, confirmation', states: 'remove-confirm at ≥10 (destructive), file pickers, color picker; button order/roles' },
  { key: 'quicklook', label: 'Quick Look', files: 'Sources/Views/QuickLookKeyResponder.swift', hig: 'Quick Look', states: 'Space → QLPreviewPanel; first-responder, panel lifecycle' },
  { key: 'empty', label: 'Empty state', files: 'Sources/Views/FileListView.swift (144-160)', hig: 'empty states / onboarding', states: 'drop hint icon + copy + Try Demo button' },
  { key: 'missing', label: 'Missing-binary state', files: 'Sources/Views/MissingBinaryView.swift', hig: 'error states', states: 'error messaging, disabled actions' },
  { key: 'debug', label: 'Debug overlay (dev)', files: 'Sources/Views/DebugOverlay.swift', hig: 'n/a (dev only)', states: 'phase forcing, demo actions, CLI echo, log tail — must not ship in user paths' },
  { key: 'tokens', label: 'Design tokens (cross-cutting)', files: 'Sources/Views/DesignTokens.swift', hig: 'color / typography', states: 'hardcoded palette vs system semantics; SEED: accent #007aff vs .accentColor' },
  { key: 'chrome', label: 'Window chrome (cross-cutting)', files: 'Sources/App/BgBgOneApp.swift (WindowGroup, .inspector, .toolbar)', hig: 'windows / title bars', states: 'real NSWindow chrome, resizability, title, no fake chrome' },
]

// ─── Phase 0: Boot ─────────────────────────────────────────────────────────────
phase('Boot')
const boot = await agent(
  `Build and launch the macOS app bgbgone-app so a UI audit can drive it. Run, from ${APP}:
  1. \`make vendor\` (builds the pinned bgbgone CLI submodule — needed for a launchable bundle). If the submodule is absent, run \`git submodule update --init --recursive\` first.
  2. \`make app\` (builds + bundles + ad-hoc signs build/bgbgone-app.app).
  3. Quit any stale instance: \`osascript -e 'tell application "bgbgone-app" to quit'\`; \`pkill -f bgbgone-app/Contents/MacOS/bgbgone-app\` (ignore errors).
  4. Launch with the debug overlay: \`open ${APP}/build/bgbgone-app.app --args --debug\`; sleep 3; \`osascript -e 'tell application "bgbgone-app" to activate'\`.
  5. Confirm peekaboo can see it: \`peekaboo see --app bgbgone\` (or \`peekaboo image --app bgbgone --path /tmp/bgbgone-boot.png\`).
  Report built/launchable/peekabooSeesWindow honestly with exact error text in notes if anything fails. Do NOT edit any source files.`,
  { schema: BOOT_SCHEMA, phase: 'Boot', label: 'boot:build+launch' },
)
const appReady = !!(boot && boot.launchable)
log(`Boot: built=${boot?.built} launchable=${boot?.launchable} peekaboo=${boot?.peekabooSeesWindow}. ${appReady ? 'Live capture enabled.' : 'App not launchable — static-only audit. ' + (boot?.notes || '')}`)

// ─── Phases 1 + 2: Static review (parallel) ‖ Live capture (single serial agent) ──
// Static reviewers only read files; the one capture agent owns the screen. Running them
// concurrently is safe — exactly one agent ever drives the GUI, so no screen contention.
phase('Static review')
const staticThunk = () => parallel(SURFACES.map((s) => () =>
  agent(
    `You are auditing ONE surface of the native macOS SwiftUI app bgbgone-app for UI/UX correctness.
SURFACE: ${s.label}
SOURCE FILES: ${s.files}
INTERACTIONS / STATES: ${s.states}
RELEVANT HIG AREA: ${s.hig}

${AUTHORITIES}

Read the source file(s) in full. WebFetch/WebSearch the relevant Apple HIG section and cite it. Read the matching region of ${SSOT} for this surface and compare. For EVERY left-click, right-click item, keyboard path, control, label, color, spacing, and state in this surface, decide whether it conforms. Report concrete violations only (no vague advice) — each with the exact rule, file:line evidence, severity, a stock-SwiftUI fix, and whether it should be guarded by a source-scan test, a peekaboo e2e test, or both. Be exhaustive; this surface's coverage is your sole responsibility. Do NOT edit any files.`,
    { schema: FINDING_SCHEMA, phase: 'Static review', label: `static:${s.key}` },
  )))

phase('Live capture')
const captureThunk = () => {
  if (!appReady) return Promise.resolve({ shots: [], notes: 'app not launchable; capture skipped' })
  return agent(
    `You drive the RUNNING bgbgone-app (already built & launched with --debug) and capture a screenshot of every UI state and menu. You are the ONLY agent touching the screen — work serially and deliberately. Tools: peekaboo (see/click/right-click/type/hotkey/menu) and screencapture.

Setup: \`mkdir -p ${SHOTS}\`. For each state below, drive the app into it, then capture with \`peekaboo image --app bgbgone --path ${SHOTS}/<name>.png\` (fallback \`screencapture -x\`). Use \`peekaboo see --app bgbgone --annotate\` to discover element IDs before clicking.

Capture at least these states (skip gracefully + note any you cannot reach):
- 01-empty: first launch empty state (drop hint + Try Demo)
- 02-demo-populated: click "Try Demo", wait for the 3 images to ingest
- 03..08 debug phases: open ⌘\` debug overlay, click each Drop-in demo phase button (idle, drag one folder, drag many images, drag mixed, drag blocked, ingesting, post-drop summary), capturing each
- 09-inspector-open: ensure inspector is shown
- 10..12 config-picks: cycle Background = Transparent/Color/Image (capture ColorPicker open), Format, Algorithm segmented picks
- 13..16 advanced-forms: expand Advanced, then each disclosure — Mask refinement, Foreground transforms, Background filters, Advanced chain editor; capture a slider at min and at max where visible
- 17-contextmenu: right-click a file row to reveal the context menu (8 items); capture the open menu. If items vary by state, capture the menu with a processed file too (mark-all-done via debug) to show Reveal/Open/Copy Cutout enabled.
- 18-remove-confirm: select rows and press Delete (if ≥10 a confirmation appears) — capture it
- 19-quicklook: select a row, press Space for Quick Look — capture
- 20-statusbar / 21-runhistory: capture the status bar and a populated run-history section
- 22-window-chrome: capture the whole window to judge title bar / toolbar / traffic lights realness

Return the manifest of every shot (name, absolute path, state, captured true/false). Do NOT edit any source files. When done, quit the app: \`osascript -e 'tell application "bgbgone-app" to quit'\`.`,
    { schema: MANIFEST_SCHEMA, phase: 'Live capture', label: 'capture:all-states' },
  )
}

const [staticResults, manifest] = await parallel([staticThunk, captureThunk])
const staticFindings = (staticResults || []).filter(Boolean).flatMap((r) => r.findings || [])
const shots = (manifest && manifest.shots || []).filter((s) => s.captured)
log(`Static review: ${staticFindings.length} candidate findings across ${SURFACES.length} surfaces. Captured ${shots.length} screenshots.`)

// ─── Phase 3: Judge each screenshot (parallel) ─────────────────────────────────
phase('Judge')
const visualResults = await parallel(shots.map((shot) => () =>
  agent(
    `Visually judge ONE screenshot of bgbgone-app against the authorities below. Read the image at ${shot.path} (state: "${shot.state}").

${AUTHORITIES}

Read the matching region of ${SSOT} for this state and compare layout/color/copy/spacing (drift > 3% is a blocker). Judge: alignment & spacing (consistent with DesignRadius 14/8/5?), contrast (WCAG AA), hit-target sizes (>= HIG minimum), focus/selection affordance, destructive-action coloring, menu ordering & grouping, label clarity & truthfulness, and the "Finder eyeball test" — does this look like a stock Apple app or something crafted/fake? Report concrete visual violations only, each with the rule, the screenshot path as evidence (describe exactly what's wrong and where), severity, a stock-SwiftUI fix, and testKind. Do NOT edit files.`,
    { schema: FINDING_SCHEMA, phase: 'Judge', label: `judge:${shot.name}` },
  )))
const visualFindings = (visualResults || []).filter(Boolean).flatMap((r) => r.findings || [])
log(`Judge: ${visualFindings.length} candidate visual findings from ${shots.length} screenshots.`)

// ─── Phase 4: Adversarial verification (parallel, 3 skeptics each) ──────────────
phase('Verify')
const candidates = [...staticFindings, ...visualFindings]
const verified = await parallel(candidates.map((f, idx) => () =>
  parallel([0, 1, 2].map((vote) => () =>
    agent(
      `Adversarially verify a claimed UI/UX violation in bgbgone-app. Try to REFUTE it. Default real=false if you are not certain after checking the actual evidence.
CLAIM #${idx} (skeptic ${vote}): surface="${f.surface}" title="${f.title}" rule="${f.rule}" source=${f.source} severity=${f.severity}
EVIDENCE GIVEN: ${f.evidence}
FILE/SHOT: ${f.file || '(see evidence)'}

Open the cited file (Read) or screenshot and check the claim against the real artifact and the cited authority (charter ${CHARTER} / HIG / SSOT ${SSOT}). A claim is real ONLY if the violation genuinely holds — not if it's a stylistic preference, already handled elsewhere, or a misread of stock SwiftUI behavior. Set real, an adjusted severity, and a one-line reason.`,
      { schema: VERDICT_SCHEMA, phase: 'Verify', label: `verify:${idx}.${vote}` },
    )))
    .then((votes) => {
      const v = (votes || []).filter(Boolean)
      const realCount = v.filter((x) => x.real).length
      // Promote the majority severity adjustment (fallback to original).
      const sevs = v.filter((x) => x.real).map((x) => x.severityAdjusted)
      return { ...f, real: realCount >= 2, votes: v.length, realCount, severity: sevs[0] || f.severity, verifyReason: (v[0] && v[0].reason) || '' }
    })))
const confirmed = (verified || []).filter(Boolean).filter((f) => f.real)
const rejected = (verified || []).filter(Boolean).filter((f) => !f.real)
log(`Verify: ${confirmed.length} confirmed, ${rejected.length} rejected (logged, not dropped).`)

// ─── Phase 5: Synthesize → write the remediation plan ──────────────────────────
phase('Synthesize')
const synthInput = JSON.stringify({ confirmed, rejected: rejected.map((r) => ({ title: r.title, surface: r.surface, reason: r.verifyReason })), shots, bootNotes: boot?.notes || '' })
const synth = await agent(
  `You are writing the definitive UI/UX remediation plan for the native macOS SwiftUI app bgbgone-app. You are given the CONFIRMED findings (each survived 3 adversarial skeptics) plus rejected ones (for the appendix) and the screenshot manifest.

DATA (JSON): ${synthInput}

Write a thorough markdown plan to ${PLAN_OUT} (create the directory if needed; this file is the only thing you write — do NOT touch Sources/). Structure:

# bgbgone-app — UI/UX Remediation Plan
- Intro: what was audited (every surface/click/menu/control), authorities used (charter ${CHARTER}, Apple HIG, SSOT ${SSOT}), method (static per-surface review + live screenshot judging + 3-skeptic adversarial verification), and the headline counts.
- ## How to fix in a TDD + e2e way: explain that static/charter rules get a Swift Testing case extending Tests/NoFakeUITests.swift that scans Sources/ (red now → green after fix); behavioral/HIG rules get a peekaboo e2e check in the screenshot-tour.sh family that targets controls BY accessibilityIdentifier; accessibility gets both.
- ## Item 0 (FOUNDATION) — Add accessibilityIdentifiers to every interactive surface. There are NONE today. List the exact identifiers to add per surface (table, each context-menu item, toolbar buttons, pickers, sliders, modals, Try Demo, status-bar buttons). Provide a paste-ready failing Swift source-scan test asserting that every Button/Picker/contextMenu/Toggle/Slider in Sources/Views declares .accessibilityIdentifier. This is the prerequisite for reliable e2e.
- ## Prioritized findings: group by module/surface; within each, order by (severity × user-frequency) ÷ effort. For EACH confirmed finding give: id, surface, severity, the rule violated (with HIG/charter/SSOT citation), evidence (file:line or screenshot path), fix (in stock-SwiftUI terms), a PASTE-READY failing Swift test (source-scan style for static rules — model it on NoFakeUITests.swift's codeOnlySourceTexts() helper) OR a peekaboo e2e recipe (launch --debug, drive to state, target by accessibilityIdentifier, assert), and an estimated effort (S/M/L).
- Ensure the hardcoded-accent SEED finding (DesignTokens.accent #007aff vs .tint(.accentColor)) appears with a source-scan test that fails on raw Color(red:...) used as accent. Ensure the context menu and each settings form have entries.
- ## Appendix: rejected candidates (title + why refuted) so nothing is silently dropped, and the screenshot manifest.

Be concrete and exhaustive — paste-ready code, exact identifiers, real file paths. Return a 5-line executive summary (counts by severity, the top 5 must-fix items, and the path you wrote).`,
  { phase: 'Synthesize', label: 'synthesize:plan' },
)

log('Synthesize: plan written to ' + PLAN_OUT)
return {
  built: boot?.built, launchable: appReady, screenshots: shots.length,
  candidates: candidates.length, confirmed: confirmed.length, rejected: rejected.length,
  plan: PLAN_OUT, summary: synth,
}
