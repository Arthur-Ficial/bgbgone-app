# bgbgone-app — project instructions

> **`bgbgone-app` is to `bgbgone` what `apfel-chat` is to `apfel`.** All scaffolding, scripts, and conventions from [apfel-chat](https://github.com/Arthur-Ficial/apfel-chat) apply here unless explicitly overridden.

## Ownership & autonomy

**This is Arthur Ficial's project.** Arthur (the operating agent) makes every decision on this codebase autonomously — engineering, rollout, releases, version bumps, and deployment — no per-change approval required. Same standing grant as the [bgbgone CLI](https://github.com/Arthur-Ficial/bgbgone) repo. (External *communications* still follow the global rule.)

## Golden Goal

> Drop a folder. Watch it process. End up with a folder of clean cutouts. Never touch a terminal.

## UI feel golden goal — "Finder, but for background removal"

> The user opens bgbgone-app and instinctively thinks: *"this is a standard Apple app, like Finder."*

This is the **UI/UX north star**, equal in weight to the functional Golden Goal above. Concretely it means:

- **Window:** the real `NSWindow` title bar with real traffic lights, real title text (`bgbgone`), real `.toolbar` items on the right — exactly like Finder's window chrome. No floating panels-in-panels, no fake darkening, no custom shadow.
- **Sidebar / source list:** if we ever add a sidebar (folder/batch navigation), it uses `NavigationSplitView` with `List` styled as `.sidebar` — the same component Finder uses.
- **List / table:** the file list uses real `Table` (column headers, sortable, multi-select with cmd-click / shift-click, right-click context menu, Return-to-open, Space-to-quicklook) — exactly Finder's behaviour. Not a hand-rolled `LazyVStack`.
- **Toolbar items:** stock `Button` / `Menu` inside `ToolbarItemGroup`. The "Remove background from N" primary action lives where Finder's "Share" / "Action" buttons live (top-right).
- **Status bar:** if present, a single line of secondary-style text at the bottom of the window, like Finder's status footer ("10 items, 250 MB available").
- **Drop affordance:** the same blue rounded-rect inset highlight Finder uses when you drag a file over a folder.
- **Sheets / dialogs:** native `.sheet`, `.alert`, `.fileImporter` — never a custom modal.
- **Quick Look integration:** Space-bar previews any selected image via `QLPreviewPanel` (free with `NSWorkspace` / `QuickLookUI`).
- **Typography:** system fonts (`.system`, `.headline`, `.subheadline`, `.callout`, `.footnote`) at system sizes; never a hand-rolled tracking/weight stack pretending to be SF Pro.
- **Colour:** system accent colour (`.tint(.accentColor)` from the asset catalogue, defaulting to the user's chosen Mac accent — NOT a hardcoded blue). System materials (`.regularMaterial`, `.thinMaterial`) for sidebars / toolbars. System semantic colours (`.primary`, `.secondary`, `.tertiary`) for text.

**Acceptance test (the "Finder eyeball test"):** screenshot the app side-by-side with Finder open. A reasonable observer should describe them as members of the same family. If anything in our window looks *crafted* rather than *stock*, it's wrong.

This rule is non-negotiable. It is the simplest expression of the "no fake UI" charter below: **don't build a brand, inherit Apple's.**

## NO BUSINESS LOGIC · NO FALLBACKS · NO HALF-FEATURES

This is the hardest rule in the repo. **Every pixel-level operation belongs to the spawned `bgbgone` CLI binary.** The Swift code here is allowed to:

- Read **only** image metadata via `ImageIO` (`width × height × bytes` for the file list).
- Resolve `bgbgone` binary path via `BinaryLocator` (**bundled-only**: the version-locked binary embedded from the pinned `vendor/bgbgone` submodule, plus an opt-in `settings.json` override as the dev/test escape hatch — **no PATH/Homebrew/`/usr/local` scavenging**, so a stale system bgbgone can never shadow the tested one).
- Compose `[String]` argv from `Config + ImageFile` via `BgBgOneCommand` (`--format`/`--type`, never the dropped `--to`/`--algo`).
- Spawn `Process`, read stdout JSON, read exit code, surface to ViewModel.
- Walk folders with `FileManager` / `NSDirectoryEnumerator`.
- Render SwiftUI views from state.

It is **not** allowed to:

- `import Vision`, `import CoreImage`, `import CoreML`, `import Metal`, `import Accelerate`, or any other framework that could do image segmentation, matting, or compositing in-process. **A test (`NoVisionImportTest`) scans `Sources/` and fails if any of these appear.**
- Re-implement matting, alpha blending, format conversion, or background compositing.
- Fall back to a "simpler algorithm" if `bgbgone` is missing. If the binary cannot be found (which should be impossible thanks to the bundled, version-asserted helper), the app shows `MissingBinaryView` and disables actions — it never silently runs some other `bgbgone` off the machine.
- Parse `bgbgone`'s human-readable stderr text. Use `--json` / `--ndjson` only.

If a feature needs new image-processing capability, **add it to `bgbgone` first**, then surface the new flag in the GUI's `Config + BgBgOneCommand`. Never the other way around.

## NO FAKE UI · NO FAKE DATA · NO FAKE CHROME · NO MOCKS IN SHIPPING CODE

**Everything in the shipping app must be real. No mock data. No fallback shit. No fake data. No fake design. No fake chrome. No placeholder art. No aspirational labels. No `Stub*`/`Mock*`/`Fake*` types in `Sources/`. No app-in-an-app.**

**This is the second hardest rule and it is non-negotiable.** This is a standard macOS Swift/SwiftUI app — Cocoa is the chrome, Apple is the renderer, the user's pixels are the truth. Everything visible to the user must be **real**.

### TDD + e2e are required AND insufficient

Keep the TDD discipline. Keep the e2e tests. They prove the **logic** works. They do **not** prove the UI is real — a green test suite happily passes while the app ships fake traffic lights, placeholder silhouettes, and `"on-device · Vision"` labels in a Vision-forbidden codebase (this literally happened on 2026-05-23). Logic correctness ≠ UI honesty. Both gates must be green: tests for logic, AI-driven screenshot verification (below) for UI realness.

### Standard SwiftUI primitives only — no custom-painted OS chrome

The UI is built from **stock SwiftUI / AppKit elements**, period: `WindowGroup`, `NavigationStack`, `Toolbar`, `Button`, `List`, `Table`, `Form`, `TextField`, `Picker`, `ProgressView`, `Image`, `AsyncImage`, `Menu`, `Sheet`, `Alert`, `FileImporter`, `.onDrop`, the real `NSWindow` title bar via `WindowGroup` modifiers. That's the palette. **Custom views are for composing app-specific content, never for repainting OS chrome.**

Specifically forbidden:
- Custom title bars, custom traffic lights, custom window frames — **use the real `NSWindow` chrome.** Need a transparent/unified look? `.windowStyle(.hiddenTitleBar)` + real toolbar, not hand-painted circles.
- Custom button shapes that imitate `.borderedProminent`/`.bordered` — use the real button styles. Reach for `ButtonStyle` only when stock styles genuinely don't cover the need, and even then compose on top of `Button`, not by drawing rectangles around `Text`.
- Hand-rolled scrollbars, hand-rolled focus rings, hand-rolled list separators, hand-rolled context menus. SwiftUI ships all of these.

If a stock SwiftUI element does the job, **use it**. "We needed pixel-perfect match with the HTML design" is not a license to repaint Cocoa — adjust the design to live within real SwiftUI, or use the SwiftUI customisation hooks (`.controlSize`, `.tint`, `.buttonStyle(.borderedProminent)`, etc.) on the real components.

It is **forbidden** to:

- **Draw a fake macOS title bar.** No SwiftUI `Circle().fill(.red/.yellow/.green)` "traffic lights". No custom 44px "title bar" view. **Use the real `NSWindow` chrome.** If a custom title is needed, use `WindowGroup` + `.windowToolbar` / `.toolbar` / `NSWindow.titlebarAppearsTransparent` on the real window — never a SwiftUI view pretending to be one. *"App-in-an-app"* (a fake window painted inside the real window) is an automatic release blocker.
- **Render placeholder silhouettes / "blobs" / mock shapes** in place of the user's actual image. If we have a file URL, we **decode it** (via `NSImage(contentsOf:)` / `AsyncImage` / `ImageIO` thumbnail) and show **those pixels**. No "we can't decode so here's a grey ellipse." If decoding fails, show the system file icon and the error — never invented art.
- **Hardcode labels that lie about what the app is doing.** No `"on-device · Vision"` text when the app is forbidden from importing Vision. No `"AI-powered"` if there's no AI in the loop. Every status string must be derived from real state, not aspiration.
- **Bake in sample/demo files** (`bronze-tables-OK.png`, etc.) anywhere the user might mistake them for their own work. The first-launch state is **empty** — the drop zone, nothing else.
- **Ship `Stub*` / `Mock*` / `Fake*` types in `Sources/`.** Mocks live in `Tests/` only. If `BinaryLocator` returns `nil`, the app shows `MissingBinaryView` and disables actions — it does **not** install a `StubMissingRunner` that pretends to work.
- **Show fake timestamps, fake progress, fake counts, fake previews.** Every number on screen comes from real state. "22 min. ago" must reflect the actual mtime; "0 of 1 done" must reflect the actual queue.
- **Add fallbacks that mask failure.** If `bgbgone` fails, surface the real stderr. Don't silently substitute a placeholder result. Fail loud.

**Mental model:** if a junior engineer screenshotted the app and a senior asked "is that real?" — the answer must be **yes, every pixel**. The screenshot on 2026-05-23 that triggered this rule showed: fake traffic lights inside the real window, two grey ellipses standing in for the user's actual PNG, and a `"on-device · Vision"` label in a codebase forbidden from importing Vision. **Never again.**

This is enforced positively by the **"Finder, but for background removal"** north star at the top of the file — every pixel is real because every pixel comes from a stock Apple component.

## AI-driven verification — every UI change, every time

This app is **AI-built and AI-tested end-to-end**. The user does not babysit. Before claiming any UI change works:

1. Build and launch the real app bundle (`make app && make run`).
2. Take a screenshot of the running window (`tinyscreenshot app "bgbgone" -c grey` or `peekaboo image --app bgbgone --path /tmp/bgbgone-<state>.png`).
3. **Read the screenshot back** with the Read tool and visually verify against `design/project/bgbgone.html` for that state.
4. Drive the app through the actual user flow — empty state → drop folder → ingest → process → done — capturing a screenshot at **each** state and reading it back. Compare against the design HTML state-by-state.
5. Only after every state passes visual inspection can the change be called done.

"Tests pass" and "the build is clean" do **not** mean the UI works. The truth is on the screen. Always look.

## Ownership & autonomy

Arthur is authorised to commit, tag, push, cut releases, and update the Homebrew cask formula directly — provided the quality bar below is green.

Quality bar (all green before pushing to `main` or tagging a release):

- `make test` passes (every unit and integration test).
- `make app` produces a launchable bundle that opens to the empty state without errors.
- `make release` runs the full gate: bump, build, test, dist, notarize, gh release create, render cask, push to `Arthur-Ficial/homebrew-tap`.
- Every UI state in `design/project/bgbgone.html` has a matching Swift screen, **AI-screenshotted on the real running app and visually verified per "AI-driven verification" above**. A passing test suite is not enough.
- No `import Vision|CoreImage|Metal|Accelerate|CoreML` anywhere under `Sources/`.
- No fake chrome, no placeholder art, no `Stub*`/`Mock*`/`Fake*` types, no aspirational labels (see "NO FAKE UI" above). Grep gate: `grep -rE "Stub|Mock|Fake|placeholder|silhouette" Sources/` should return nothing in shipping code.

External communication (emails, PRs to other projects, posts) still needs Franz's explicit approval — only the local repo work is autonomous.

## Tech baseline — modern only

Target the bleeding edge of what the user's machine runs today (macOS 26, Apple Silicon, Swift 6.3 toolchain). Concretely:

- **Swift 6.3+**, complete strict concurrency. Don't add `@preconcurrency` to silence warnings unless the suppressed warning is actually impossible to fix.
- **`@Observable`** (Observation framework) for ViewModels — never the legacy `ObservableObject` / `@Published` pair.
- **`async`/`await` + `AsyncStream`** for all I/O. Do not use Combine, completion handlers, or NotificationCenter for new code.
- **Swift Testing only**, no XCTest. (`swift-testing` ≥ 0.99; once Swift 6.4 lands and ships Testing in-toolchain, drop the explicit package dep.)
- **SwiftUI** on macOS 26 APIs — `NavigationStack` (never `NavigationView`), `.scrollContentBackground`, `WindowGroup` + `.windowResizability(.contentSize)`, `.onDrop(of:isTargeted:perform:)`, etc.
- **Foundation modern types** — `URL` everywhere (no `String` paths), `Duration`, `Date.now`, `ContinuousClock`.
- **No third-party deps for problems Foundation/SwiftUI solve.** No SnapKit, no Alamofire, no third-party JSON. Resist hard.
- **Strict concurrency Sendable** — Models are `Sendable` value types where possible.

If a "modern" choice forces a hack (e.g. a SwiftUI API has a known bug on macOS 26 you actually hit), document the workaround in a comment with the rdar/forum link and revisit when the platform fixes it.

## Architecture (apfel-chat pattern)

```
Sources/
├── App/        @main, BinaryLocator, BuildInfo
├── Models/     ImageFile, Batch, ProcessingState, DropPhase, DragHint, Config, BgBgOneCommand
├── Protocols/  BgBgOneRunning, FolderScanning, ImageMetaReading
├── Services/   BgBgOneRunner (Process), FolderScanner, ImageMetaReader (ImageIO)
├── ViewModels/ AppViewModel (state), DropMachine (pure FSM), QueueRunner (bounded concurrency)
└── Views/      WindowChrome, DualPreview, SelectedMeta, ConfigPanel, FileListView,
                StatusBar, DropVeil, IngestOverlay, DropSummary, MissingBinaryView
Tests/          Mirrors Sources/. swift-testing only. TDD: test before impl.
```

Every Service has a Protocol so it can be mocked in tests. Views render state and emit intents; ViewModels own state machines; Services do I/O.

## Build & test

```bash
make test               # swift test
make build              # swift build -c release
make app                # build + bundle + sign (ad-hoc by default)
make run                # open the bundle
make dist               # zip + sha256
make release            # full release pipeline (Arthur only)
```

`.version` is the single source of truth for the version number. Build scripts inject it into `Info.plist` via PlistBuddy at bundle time. Same pattern as `bgbgone` and `apfel-chat`.

### The `bgbgone` CLI is a pinned, bundled dependency

`bgbgone` is vendored as a git submodule at `vendor/bgbgone`, pinned to a release tag
commit (currently **v1.2.23** — see `BGBGONE_VERSION` in `scripts/build-app.sh`). It
stays its own standalone repo; we depend on its **binary**, never link its code (that
would break the no-business-logic rule). `make app` builds the submodule
(`make -C vendor/bgbgone build` → `.build/release/bgbgone`), embeds it at
`Contents/Helpers/bgbgone`, and **asserts the embedded `--version` equals
`BGBGONE_VERSION`** — a stale system bgbgone can never end up bundled. `release.sh`
re-verifies this against `vendor/bgbgone/.version` on the packaged app.

The GUI's argv + JSON contract is version-coupled to this CLI, so resolution is
**bundled-only** (`BinaryLocator`): the embedded binary, plus an opt-in `settings.json`
override (the dev escape hatch — point it at `vendor/bgbgone/.build/release/bgbgone`
when running via `swift run`, which has no `Contents/Helpers`). No PATH scavenging.
When bumping the pin: move the submodule to the new tag, update `BGBGONE_VERSION`, and
confirm `RealBinaryE2ETests` + the `BgBgOneCommand` argv contract still hold (the CLI's
`--format`/`--type` flags and `{ok,schema,result}` JSON envelope are what the app
expects). After a fresh clone: `git submodule update --init --recursive` (or `make vendor`).

## Design reference (this is the spec)

`design/project/bgbgone.html` (open in a browser) is **the spec** for layout, color, copy, and interaction. The Tweaks panel cycles through every drop phase. Any Swift screen must match its HTML counterpart pixel-for-pixel — drift > 3% is a release blocker.

`design/chats/chat1.md` and `chat2.md` capture the design intent in the user's own words. Read them when in doubt about *why* the UI is shaped this way.

## Key files

| Area | Files |
|------|-------|
| Entry point | `Sources/App/BgBgOneApp.swift` |
| Binary discovery | `Sources/App/BinaryLocator.swift` (bundled-only) |
| CLI argv composer | `Sources/Models/BgBgOneCommand.swift` (`--format`/`--type`) |
| CLI JSON result | `Sources/Models/RunResult.swift` (`{ok,schema,result}` envelope) |
| Process spawn | `Sources/Services/BgBgOneRunner.swift` |
| Drop FSM | `Sources/ViewModels/DropMachine.swift` |
| Queue executor | `Sources/ViewModels/QueueRunner.swift` |
| Bundled CLI dependency | `vendor/bgbgone` (submodule), embedded by `scripts/build-app.sh` |
| Real-binary e2e | `Tests/RealBinaryE2ETests.swift` |
| Design spec | `design/project/bgbgone.html` |
| Version | `.version` |
| Bundle metadata | `Info.plist` |
| Entitlements | `bgbgone-app.entitlements` |
| Tests | `Tests/` |
