import Foundation
import Observation
import SwiftUI
import os

/// Top-level UI state owner. Views observe `files`, `batches`, `selectedId`, `config`,
/// `dropPhase`, `bootState`. Views never own state — they emit intents back to this
/// type. Pure I/O happens in injected Services (`BgBgOneRunning`, `FolderScanning`,
/// `ImageMetaReading`).
@MainActor
@Observable
final class AppViewModel {
    /// Whether we've located the bgbgone binary. Drives `MissingBinaryView`.
    enum BootState: Equatable {
        case starting
        case ready(binary: URL)
        case missingBinary(searched: [String])
    }

    private(set) var bootState: BootState = .starting

    var files: [ImageFile] = []

    /// O(1) lookup used by `markProcessing` / `markFinished` so per-file
    /// completion is O(1) instead of `files.firstIndex(where:)` which makes a
    /// 100-file batch O(N²). Rebuilt only on array *reshape* (append / remove)
    /// — per-element `files[idx].state = …` mutations never shift indices, so
    /// they don't need to touch this dict.
    private var fileIndexByID: [ImageFile.ID: Int] = [:]

    private func rebuildFileIndex() {
        fileIndexByID = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.id, $0) })
    }

    /// Use `appendBatch(_:)`, `setBatch(_:at:)`, or `mutateBatch(id:_:)` for
    /// mutations so `batchesByID` stays in sync. Direct array index assignment
    /// is allowed only within `AppViewModel`.
    private(set) var batches: [Batch] = [] {
        didSet { batchesByID = Dictionary(uniqueKeysWithValues: batches.map { ($0.id, $0) }) }
    }

    /// O(1) batch lookup used by the file list (Source Folder column) and the
    /// row-action menu. Kept in sync with `batches` via the property observer.
    private(set) var batchesByID: [Batch.ID: Batch] = [:]

    /// Multi-select selection model (T9). The Table binds directly to this.
    /// `selectedId` (singular) is a thin compat shim that reads/writes the first
    /// element — preserved for views that only need one item (inspector preview).
    var selectedIds: Set<ImageFile.ID> = []
    var selectedId: ImageFile.ID? {
        get { selectedIds.first }
        set { selectedIds = newValue.map { Set([$0]) } ?? [] }
    }
    /// Template config that new drops inherit. Edits to the Inspector when
    /// no file is selected write here; new files clone this on ingest.
    var defaultConfig: Config = Config(outDirectory: Config.defaultOutDirectory)

    /// O(1) lookup of the currently-selected file via `fileIndexByID`.
    /// Replaces the `files.first(where: { $0.id == selectedId })` scan that
    /// was called from at least 4 views per body invocation.
    var selectedFile: ImageFile? {
        guard let id = selectedId,
              let idx = fileIndexByID[id],
              idx < files.count,
              files[idx].id == id else { return nil }
        return files[idx]
    }

    /// Binding the Inspector edits — reflects the currently-selected
    /// file's per-image config (or `defaultConfig` when no file is
    /// selected). Mutations route back to the right owner.
    var inspectorConfigBinding: Binding<Config> {
        Binding(
            get: {
                if let id = self.selectedId, let idx = self.fileIndexByID[id], idx < self.files.count {
                    return self.files[idx].config
                }
                return self.defaultConfig
            },
            set: { newValue in
                if let id = self.selectedId, let idx = self.fileIndexByID[id], idx < self.files.count {
                    self.files[idx].config = newValue
                } else {
                    self.defaultConfig = newValue
                }
            }
        )
    }

    /// Convenience read-only accessor used by views that don't need a
    /// binding (StatusBar samples, DebugOverlay, etc.).
    var config: Config { inspectorConfigBinding.wrappedValue }

    /// Finder-style sidebar selection. `.all` shows every file; `.batch(id)` filters.
    var sidebarSelection: SidebarItem? = .all

    /// Files filtered by the current sidebar selection.
    var visibleFiles: [ImageFile] {
        switch sidebarSelection {
        case .none, .some(.all): files
        case .some(.batch(let id)): files.filter { $0.batchId == id }
        }
    }

    let dropMachine: DropMachine

    /// `nil` when the binary couldn't be located. The UI shows `MissingBinaryView` and
    /// disables actions in that case; `processAll()` early-returns. We do not ship a
    /// stub runner — a stub is the "fake fallback" the no-fake-UI charter forbids.
    private let runner: (any BgBgOneRunning)?
    private let scanner: any FolderScanning
    private let metaReader: any ImageMetaReading
    let historyStore: RunHistoryStore?
    let undoManager = BgBgOneUndoManager()
    private var processingStartedAt: [UUID: Date] = [:]
    /// Files that are part of the in-flight batch, captured at `processSelected` entry
    /// so the post-run undo registration sees a stable id set.
    private var currentBatchIDs: Set<UUID> = []
    private var currentBatchSnapshot: ConfigSnapshot?
    /// T7 — fire-and-forget Task for the active batch. `nil` when idle; set by
    /// `startProcessing`, cleared when the task completes (success or cancelled).
    private(set) var activeRun: Task<Void, Never>?
    private let logger = Logger(subsystem: BuildInfo.osLogSubsystem, category: "app")

    // MARK: - init

    /// Production initialiser — discovers the binary via `BinaryLocator`. Views call
    /// this with no arguments.
    convenience init() {
        let locator = BinaryLocator()
        let bootState: BootState
        let runner: (any BgBgOneRunning)?
        do {
            let binary = try locator.locate()
            bootState = .ready(binary: binary)
            runner = BgBgOneRunner(binary: binary)
        } catch BinaryLocator.LocatorError.notFound(let searched) {
            bootState = .missingBinary(searched: searched)
            runner = nil
        } catch {
            bootState = .missingBinary(searched: ["unknown: \(error)"])
            runner = nil
        }
        self.init(
            runner: runner,
            scanner: FolderScanner(),
            metaReader: ImageMetaReader(),
            bootState: bootState,
            historyStore: RunHistoryStore(directory: RunHistoryStore.defaultDirectory)
        )
    }

    /// Test-friendly initialiser. Tests pass mocks for all three services so the
    /// integration test runs without spawning anything or touching disk.
    init(
        runner: (any BgBgOneRunning)?,
        scanner: any FolderScanning,
        metaReader: any ImageMetaReading,
        bootState: BootState,
        historyStore: RunHistoryStore?
    ) {
        self.runner = runner
        self.scanner = scanner
        self.metaReader = metaReader
        self.bootState = bootState
        self.historyStore = historyStore
        self.dropMachine = DropMachine()
    }

    // MARK: - Drag / drop

    func handleDragEnter(hint: DragHint) { dropMachine.handleDragEnter(hint: hint) }
    func handleDragLeave() { dropMachine.handleDragLeave() }
    func dismissSummary() { dropMachine.dismissSummary() }

    /// Try-Demo entrypoint. Copies the 3 PD/CC0 images bundled at
    /// `Contents/Resources/demo/` into a tmp directory and feeds them
    /// through the normal `handleDrop` pipeline. No network, no JSON, no
    /// attribution sheet — replaces the fragile fetch-script + manifest
    /// approach. Returns silently if the bundled demo folder isn't found
    /// (e.g. unit-test target).
    func startBuiltInDemo() async {
        guard let demoDir = Bundle.main.url(forResource: "demo", withExtension: nil) else { return }
        let images = (try? FileManager.default.contentsOfDirectory(
            at: demoDir, includingPropertiesForKeys: nil
        )) ?? []
        guard !images.isEmpty else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgbgone-demo", isDirectory: true)
        // Recreate each invocation so re-clicking Try Demo gives a fresh batch.
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for img in images {
            let dest = tmp.appendingPathComponent(img.lastPathComponent)
            try? FileManager.default.copyItem(at: img, to: dest)
        }
        await handleDrop(urls: [tmp])
    }

    /// Called when the user drops folders / files on the window.
    ///
    /// Folders are scanned recursively (one `Batch` per folder); loose images go into
    /// no batch. Each new `ImageFile` starts in `.raw` state.
    func handleDrop(urls: [URL]) async {
        // Classify the drop so we can name the ingest progress card.
        let folderURLs = urls.filter { Self.isDirectory($0) }
        let looseImageURLs = urls.filter { !Self.isDirectory($0) && Self.isImage($0) }
        let folderName = folderURLs.first?.lastPathComponent ?? "dropped"
        dropMachine.handleDrop(folderName: folderName)

        var addedImages: [ImageFile] = []

        // T13: ensure the "Single Files" virtual batch exists before loose-drop
        // ingestion so loose files get a real batchId (not nil).
        if !looseImageURLs.isEmpty, !batches.contains(where: { $0.id == Batch.singleFilesID }) {
            batches.append(
                Batch(id: Batch.singleFilesID, name: Batch.singleFilesDisplayName, rootURL: nil)
            )
        }

        // 1. Loose images go into the "Single Files" virtual batch.
        for url in looseImageURLs {
            let file = makeImageFile(at: url, batchId: Batch.singleFilesID, relativePath: "")
            addedImages.append(file)
            if let idx = batches.firstIndex(where: { $0.id == Batch.singleFilesID }) {
                batches[idx].imageCount += 1
            }
            dropMachine.applyScanEvent(.foundImage(url: url, relativePath: url.lastPathComponent))
            dropMachine.applyScanEvent(.scanned(url: url, isImage: true))
        }

        // 2. Folders, one batch per folder.
        var totalScanned = 0
        var totalSkipped = 0
        for folder in folderURLs {
            let batch = Batch(name: folder.lastPathComponent, rootURL: folder, addedAt: .now)
            batches.append(batch)
            for await event in scanner.scan(folder) {
                switch event {
                case .foundImage(let url, let relativePath):
                    let file = makeImageFile(at: url, batchId: batch.id, relativePath: relativePath)
                    addedImages.append(file)
                    if let idx = batches.firstIndex(where: { $0.id == batch.id }) {
                        batches[idx].imageCount += 1
                    }
                    dropMachine.applyScanEvent(event)
                case .scanned:
                    totalScanned += 1
                    dropMachine.applyScanEvent(event)
                case .skipped:
                    totalSkipped += 1
                    if let idx = batches.firstIndex(where: { $0.id == batch.id }) {
                        batches[idx].skippedCount += 1
                    }
                    dropMachine.applyScanEvent(event)
                case .completed(_, let scannedCount, let skippedCount):
                    totalScanned += scannedCount
                    totalSkipped += skippedCount
                    // Don't forward .completed to the drop machine yet — wait until ALL
                    // folders are done so the summary fires once.
                    break
                }
            }
        }

        files.append(contentsOf: addedImages)
        rebuildFileIndex()
        if selectedId == nil, let first = addedImages.first { selectedId = first.id }

        dropMachine.applyScanEvent(.completed(
            images: addedImages.map(\.url),
            scannedCount: totalScanned + looseImageURLs.count,
            skippedCount: totalSkipped
        ))
    }

    /// Build an `ImageFile`, reading dims/bytes synchronously. Sync is fine here —
    /// `ImageMetaReader` doesn't decode pixels and runs in well under a millisecond.
    private func makeImageFile(at url: URL, batchId: Batch.ID?, relativePath: String) -> ImageFile {
        var file = ImageFile(url: url, batchId: batchId, relativePath: relativePath, config: defaultConfig)
        if let meta = try? metaReader.read(url) {
            file.width = meta.width
            file.height = meta.height
            file.bytes = meta.bytes
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attrs[.modificationDate] as? Date {
            file.modifiedAt = modified
        }
        // A freshly-ingested file is `.raw` ("Not removed") — it has no cutout from THIS
        // session. We deliberately do NOT probe the disk here: a leftover file at the
        // deterministic output path (e.g. a flipped cutout written by an older bgbgone
        // build) must never be surfaced as if it were this run's result. `cutoutExists`
        // flips to true only when a real run completes (`markFinished`). This honors the
        // documented invariant on `ImageFile.cutoutExists` and the "no fake previews"
        // charter — every pixel in the CUTOUT pane comes from a run we actually performed.
        return file
    }

    // MARK: - Queue

    /// Number of files in the queue that still need work.
    var pendingCount: Int {
        files.lazy.filter { f in
            switch f.state {
            case .raw, .error, .queued, .processing: true
            case .done: false
            }
        }.count
    }

    /// Computed primary toolbar button label. While idle, "Remove background from N
    /// images"; during a run, "Stop — N of M done". T7 acceptance: label derived
    /// purely from state, never set imperatively.
    var primaryActionLabel: String {
        if let activeRun, !activeRun.isCancelled, !activeRunFinished {
            return "Stop — \(doneCount) of \(files.count) done"
        }
        let pending = pendingCount
        return pending == 1 ? "Remove background from 1 image" : "Remove background from \(pending) images"
    }

    private var activeRunFinished: Bool = false

    private var doneCount: Int {
        files.lazy.filter { if case .done = $0.state { return true } else { return false } }.count
    }

    /// T7 — fire-and-forget entry point for the toolbar button. Spawns a Task that
    /// drives `processSelected` and stores the handle in `activeRun` so the toolbar
    /// can switch to a "Stop" label and cancel it.
    func startProcessing(ids: Set<UUID>) {
        guard activeRun == nil else { return }
        activeRunFinished = false
        activeRun = Task { [weak self] in
            await self?.processSelected(ids: ids)
            await MainActor.run {
                self?.activeRunFinished = true
                self?.activeRun = nil
            }
        }
    }

    /// T7 — cancel the in-flight batch. In-flight items revert from `.processing`
    /// back to `.queued` (handled by `markFinished` when it sees `RunnerError.cancelled`).
    func stopActiveRun() {
        activeRun?.cancel()
    }

    /// "Run all" toolbar action — apply the currently-visible Inspector
    /// settings to EVERY file (overwriting per-image configs), then rerun.
    /// User mental model: tweak the Inspector, click Run all, every image
    /// gets those settings.
    func runAllWithVisibleSettings() async {
        let visible = inspectorConfigBinding.wrappedValue
        for idx in files.indices {
            files[idx].config = visible
        }
        await rerun(ids: Set(files.map(\.id)))
    }

    /// Rerun a single file regardless of its current state — `.done` files
    /// have their previous output trashed; `.raw`/`.error`/`.queued`/`.processing`
    /// files reset to `.queued` and re-run. The user can hit this any time.
    func rerun(ids: Set<UUID>) async {
        guard activeRun == nil, !ids.isEmpty else { return }
        if let historyStore {
            for id in ids {
                if let idx = fileIndexByID[id], case .done = files[idx].state {
                    let entries = await historyStore.entries(for: id)
                    if let outputURL = entries.last?.outputURL {
                        _ = try? TrashService.trash(outputURL)
                    }
                }
            }
        }
        for idx in files.indices where ids.contains(files[idx].id) {
            files[idx].state = .queued
            files[idx].cutoutExists = false
        }
        await processSelected(ids: ids)
    }

    /// T6 — re-run already-`.done` files with the **current** config (not the snapshot
    /// from the historical run). Trashes the previous output via `TrashService` then
    /// transitions `.done → .queued` and processes through the normal pipeline.
    /// Non-`.done` files in the selection are skipped.
    func rerunSelectedWithCurrentSettings(ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        let doneIDs = Set(files.lazy.filter { file in
            ids.contains(file.id) && (file.state.isRequeueable == false && file.state != .queued && file.state != .processing)
        }.map(\.id))
        guard !doneIDs.isEmpty else { return }

        if let historyStore {
            for id in doneIDs {
                let entries = await historyStore.entries(for: id)
                guard let outputURL = entries.last?.outputURL else { continue }
                _ = try? TrashService.trash(outputURL)
            }
        }

        for idx in files.indices where doneIDs.contains(files[idx].id) {
            files[idx].state = .queued
            files[idx].cutoutExists = false
        }
        await processSelected(ids: doneIDs)
    }

    // MARK: - Selection (T9)

    /// Select every visible file (respecting `sidebarSelection`). Cmd-A.
    func selectAllVisible() {
        selectedIds = Set(visibleFiles.map(\.id))
    }

    /// Clear selection. Cmd-Shift-A.
    func deselectAll() {
        selectedIds = []
    }

    /// Remove files from the queue and prune them from the selection. Delete /
    /// Backspace. The View layer is responsible for the confirm prompt when count ≥ 10.
    func removeFiles(ids: Set<ImageFile.ID>) {
        files.removeAll { ids.contains($0.id) }
        rebuildFileIndex()
        selectedIds.subtract(ids)
    }

    /// Debug-overlay "Reset to fresh state" entrypoint. Goes through the
    /// ViewModel so `batchesByID` stays in sync with `batches`.
    func resetAllForDebug() {
        files.removeAll()
        rebuildFileIndex()
        batches.removeAll()
        selectedIds.removeAll()
        dropMachine.dismissSummary()
    }

    /// "Remove background from N" → enqueue every `.raw` / `.error` file.
    ///
    /// No-op when the binary is missing: the UI shows `MissingBinaryView` and disables
    /// the toolbar action, so this is the explicit assertion of that invariant rather
    /// than a fallback.
    func processAll() async {
        await processSelected(ids: Set(files.map(\.id)))
    }

    /// T5 "Process This Only" — enqueue only the files in `ids` that are currently
    /// `.raw` or `.error`. Already-`.done` items are skipped (T6 re-runs them
    /// separately). Empty `ids` is a no-op.
    func processSelected(ids: Set<UUID>) async {
        await processSelected(ids: ids, configOverride: nil)
    }

    /// Internal entry-point that also supports T8 redo, which passes the historical
    /// `ConfigSnapshot` to use instead of each file's per-image config.
    private func processSelected(ids: Set<UUID>, configOverride: ConfigSnapshot?) async {
        guard let runner else { return }
        guard !ids.isEmpty else { return }

        for idx in files.indices where ids.contains(files[idx].id) && files[idx].state.isRequeueable {
            files[idx].state = .queued
            files[idx].cutoutExists = false
        }
        let queuedIDs = Set(files.lazy.filter { ids.contains($0.id) && $0.state == .queued }.map(\.id))
        currentBatchIDs = queuedIDs
        // For undo-snapshot bookkeeping: capture the first file's config
        // (or the override). Per-image divergence is intentional; the undo
        // snapshot just records "what was used most recently". Redo replays
        // via the explicit snapshot regardless.
        let representative = configOverride ?? Self.snapshot(of: files.first { ids.contains($0.id) }?.config ?? defaultConfig)
        currentBatchSnapshot = representative

        let workItems: [QueueRunner.WorkItem] = files.compactMap { file in
            guard ids.contains(file.id), file.state == .queued else { return nil }
            // Each file uses its OWN per-image config (or the historical
            // override during redo). Both shapes carry the same fields.
            let snap = configOverride ?? Self.snapshot(of: file.config)
            let output = BgBgOneCommand.resolveOutputURL(
                for: file.url,
                in: snap.outDirectory,
                pattern: snap.namePattern,
                format: snap.format
            )
            let cmd = BgBgOneCommand(
                input: file.url,
                output: output,
                background: snap.background,
                format: snap.format,
                algorithm: snap.algorithm,
                filterChain: snap.filterChain
            )
            guard let args = try? cmd.arguments() else { return nil }
            return QueueRunner.WorkItem(id: file.id, arguments: args)
        }

        let queue = QueueRunner(runner: runner)
        await queue.process(
            workItems,
            onStart: { [weak self] id in
                await self?.markProcessing(id: id)
            },
            onResult: { [weak self] id, result in
                await self?.markFinished(id: id, result: result)
            }
        )

        finalizeBatchForUndo()
    }

    private func finalizeBatchForUndo() {
        let batchIDs = currentBatchIDs
        guard !batchIDs.isEmpty, let snapshot = currentBatchSnapshot else { return }
        let successfulIDs = Set(files.lazy.filter { file in
            guard batchIDs.contains(file.id) else { return false }
            if case .done = file.state { return true }
            return false
        }.map(\.id))
        if !successfulIDs.isEmpty {
            undoManager.register(ids: successfulIDs, snapshot: snapshot)
        }
        currentBatchIDs = []
        currentBatchSnapshot = nil
    }

    /// T8 — undo last completed batch. Trashes outputs, transitions `.done → .raw`.
    func undoLastRun() async {
        guard activeRun == nil, let entry = undoManager.popUndo() else { return }
        if let historyStore {
            for id in entry.ids {
                let entries = await historyStore.entries(for: id)
                guard let outputURL = entries.last?.outputURL else { continue }
                _ = try? TrashService.trash(outputURL)
            }
        }
        for idx in files.indices where entry.ids.contains(files[idx].id) {
            files[idx].state = .raw
            files[idx].cutoutExists = false
        }
    }

    /// T8 — redo last undone batch. Re-processes with the **snapshotted** config from
    /// the original run, not the live `config`.
    func redoLastRun() async {
        guard activeRun == nil, let entry = undoManager.popRedo() else { return }
        await processSelected(ids: entry.ids, configOverride: entry.snapshot)
    }

    private func markProcessing(id: UUID) {
        guard let idx = fileIndexByID[id], idx < files.count, files[idx].id == id else { return }
        files[idx].state = .processing
        files[idx].cutoutExists = false
        processingStartedAt[id] = .now
    }

    private func markFinished(id: UUID, result: Result<RunResult, Error>) async {
        guard let idx = fileIndexByID[id], idx < files.count, files[idx].id == id else { return }
        let startedAt = processingStartedAt.removeValue(forKey: id) ?? .now
        let finishedAt = Date.now
        // Prefer the batch's active snapshot (set by `processSelected`); falls back to
        // this file's own per-image config so history records what was actually used.
        let snapshot = currentBatchSnapshot ?? Self.snapshot(of: files[idx].config)
        let entry: RunHistoryEntry
        switch result {
        case .success(let outcome):
            files[idx].state = .done(milliseconds: outcome.durationMillis)
            files[idx].cutoutExists = true
            // The file at `outcome.output` was just (re)written. Drop any
            // cached thumbnail for that URL so the preview shows the new
            // pixels instead of a stale cache hit.
            ThumbnailCache.shared.invalidate(url: outcome.output)
            entry = RunHistoryEntry(
                id: UUID(),
                startedAt: startedAt,
                finishedAt: finishedAt,
                durationMillis: outcome.durationMillis,
                outputURL: outcome.output,
                outcome: .success,
                configSnapshot: snapshot
            )
        case .failure(let err):
            if case RunnerError.cancelled = err {
                files[idx].state = .queued
                processingStartedAt.removeValue(forKey: id)
                return
            }
            files[idx].state = .error(message: "\(err)")
            logger.error("file \(id.uuidString, privacy: .public) failed: \(String(describing: err), privacy: .public)")
            entry = RunHistoryEntry(
                id: UUID(),
                startedAt: startedAt,
                finishedAt: finishedAt,
                durationMillis: Int(finishedAt.timeIntervalSince(startedAt) * 1000),
                outputURL: nil,
                outcome: .failure(code: errorCode(err), message: "\(err)"),
                configSnapshot: snapshot
            )
        }
        await recordHistory(id: id, entry: entry)
    }

    private func recordHistory(id: UUID, entry: RunHistoryEntry) async {
        guard let historyStore else { return }
        await historyStore.append(entry, for: id)
        try? await historyStore.flush()
    }

    private func errorCode(_ err: Error) -> String {
        guard let runner = err as? RunnerError else { return "BGBG_UNKNOWN" }
        switch runner {
        case .userError: return "BGBG_USER_ERROR"
        case .noSubject: return "BGBG_NORESULT_NO_SUBJECT"
        case .framework: return "BGBG_FRAMEWORK_INTERNAL_INVARIANT"
        case .cancelled: return "BGBG_CANCELLED"
        case .timeout: return "BGBG_TIMEOUT"
        case .malformedJSON: return "BGBG_MALFORMED_JSON"
        case .binaryNotExecutable: return "BGBG_BINARY_NOT_EXECUTABLE"
        }
    }

    // MARK: - Helpers

    /// Freeze a live `Config` into a `ConfigSnapshot` for history / undo.
    private static func snapshot(of config: Config) -> ConfigSnapshot {
        ConfigSnapshot(
            outDirectory: config.outDirectory,
            namePattern: config.namePattern,
            background: config.background,
            format: config.format,
            algorithm: config.algorithm,
            filterChain: config.effectiveFilterString
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isImage(_ url: URL) -> Bool {
        FolderScanner.imageExtensions.contains(url.pathExtension.lowercased())
    }
}

