import SwiftUI

/// Finder-style file `Table`: sortable columns, multi-select, real selection model, real
/// context menu. Drives `AppViewModel.selectedId` (single) for the inspector preview.
struct FileListView: View {
    @Bindable var viewModel: AppViewModel
    let onDismissSummary: () -> Void

    @State private var sortOrder: [KeyPathComparator<ImageFile>] = [
        KeyPathComparator(\ImageFile.name, order: .forward),
    ]

    @FocusState private var listIsFocused: Bool

    @State private var showDeleteConfirm: Bool = false
    @State private var pendingDeletionIDs: Set<ImageFile.ID> = []

    var body: some View {
        Table(sortedFiles, selection: tableSelection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 280)

            TableColumn("Status") { file in
                StatusPill(state: file.state)
            }
            .width(min: 110, max: 140)

            TableColumn("Size", value: \.bytesSortKey) { file in
                Text(sizeText(file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100, max: 130)

            TableColumn("Dimensions", value: \.pixelArea) { file in
                Text(dimsText(file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 110, max: 140)

            TableColumn("Cutout") { file in
                cutoutCell(file)
            }
            .width(min: 180, ideal: 220, max: 280)

            TableColumn("Source Folder", value: \.sourceFolderSortKey) { file in
                sourceFolderCell(file)
            }
            .width(min: 140, ideal: 180, max: 220)

            TableColumn("Modified", value: \.modifiedAt) { file in
                Text(file.modifiedAt, format: .dateTime.day().month().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: ImageFile.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click: open the image(s) in the default app. Single
            // click already selects via Table's selection binding.
            for file in viewModel.files where ids.contains(file.id) {
                NSWorkspace.shared.open(file.url)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .summary(let summary) = viewModel.dropMachine.phase {
                DropSummaryChip(summary: summary, onDismiss: onDismissSummary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .overlay {
            if viewModel.visibleFiles.isEmpty { emptyState }
        }
        .background(
            QuickLookKeyResponder(
                onSpace: handleQuickLook,
                onReturn: handleOpenInDefaultApp,
                onDelete: handleDelete
            )
        )
        .confirmationDialog(
            "Remove \(pendingDeletionIDs.count) images from queue?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove \(pendingDeletionIDs.count) from Queue", role: .destructive) {
                viewModel.removeFiles(ids: pendingDeletionIDs)
                pendingDeletionIDs = []
            }
            Button("Cancel", role: .cancel) { pendingDeletionIDs = [] }
        } message: {
            Text("They will be removed from the queue. Files on disk are not affected.")
        }
    }

    private func handleDelete() {
        let ids = viewModel.selectedIds
        guard !ids.isEmpty else { return }
        if ids.count >= 10 {
            pendingDeletionIDs = ids
            showDeleteConfirm = true
        } else {
            viewModel.removeFiles(ids: ids)
        }
    }

    private func handleQuickLook() {
        let selection = currentSelectionFiles()
        guard !selection.isEmpty else { return }
        // Each file uses its own per-image config to resolve the cutout URL.
        let urls = QuickLookURLs.urls(
            for: selection,
            cutoutURL: { $0.cutoutURL(in: $0.config) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        QuickLookController.shared.present(urls: urls)
    }

    private func handleOpenInDefaultApp() {
        let selection = currentSelectionFiles()
        for file in selection {
            NSWorkspace.shared.open(file.url)
        }
    }

    private func currentSelectionFiles() -> [ImageFile] {
        let ids = viewModel.selectedIds
        guard !ids.isEmpty else { return [] }
        return viewModel.files.filter { ids.contains($0.id) }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Drop images here")
                .font(.title2)
                .foregroundStyle(.primary)
            Button("Try Demo") {
                Task { await viewModel.startBuiltInDemo() }
            }
            .controlSize(.small)
            .padding(.top, 4)
            .accessibilityIdentifier("empty.tryDemo")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var sortedFiles: [ImageFile] {
        viewModel.visibleFiles.sorted(using: sortOrder)
    }

    private var tableSelection: Binding<Set<ImageFile.ID>> {
        Binding(
            get: { viewModel.selectedIds },
            set: { viewModel.selectedIds = $0 }
        )
    }

    private func sizeText(_ file: ImageFile) -> String {
        guard let bytes = file.bytes else { return "—" }
        return SelectedMeta.humanBytes(bytes)
    }

    private func dimsText(_ file: ImageFile) -> String {
        guard let w = file.width, let h = file.height else { return "—" }
        return "\(w) × \(h)"
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<ImageFile.ID>) -> some View {
        if ids.isEmpty {
            Button("Add files…", action: { /* handled via toolbar */ }).disabled(true)
        } else {
            let selection = viewModel.files.filter { ids.contains($0.id) }
            let actions = FileRowActions.actions(
                for: selection,
                cutoutURL: { $0.cutoutURL(in: $0.config) },
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            )

            Button(processThisOnlyLabel(count: ids.count), systemImage: "wand.and.stars") {
                viewModel.startProcessing(ids: ids)
            }
            .disabled(viewModel.activeRun != nil)
            .accessibilityIdentifier("ctx.processThisOnly")
            Divider()

            ForEach(actions) { action in
                contextMenuButton(action, selection: selection)
                if action.kind == .openCutout || action.kind == .downloadZip || action.kind == .copyCutoutPath {
                    Divider()
                }
            }
        }
    }

    private func processThisOnlyLabel(count: Int) -> String {
        count == 1 ? "Process This Only" : "Process This Only (\(count))"
    }

    @ViewBuilder
    private func contextMenuButton(
        _ action: FileRowActions.ActionItem,
        selection: [ImageFile]
    ) -> some View {
        Button(action.label, systemImage: systemImage(for: action.kind), role: role(for: action.kind)) {
            handle(action, selection: selection)
        }
        .disabled(!action.isEnabled)
        .accessibilityIdentifier("ctx.\(action.kind)")
    }

    private func systemImage(for kind: FileRowActions.Kind) -> String {
        switch kind {
        case .revealOriginal, .revealCutout: "folder"
        case .openOriginal, .openCutout: "arrow.up.right.square"
        case .saveCutout: "square.and.arrow.down"
        case .downloadZip: "doc.zipper"
        case .copyOriginalPath, .copyCutoutPath: "doc.on.clipboard"
        case .removeFromQueue: "trash"
        }
    }

    private func role(for kind: FileRowActions.Kind) -> ButtonRole? {
        kind == .removeFromQueue ? .destructive : nil
    }

    private func handle(_ action: FileRowActions.ActionItem, selection: [ImageFile]) {
        switch action.kind {
        case .revealOriginal, .revealCutout:
            NSWorkspace.shared.activateFileViewerSelecting(action.urls)
        case .openOriginal, .openCutout:
            for url in action.urls { NSWorkspace.shared.open(url) }
        case .saveCutout:
            ExportPanels.save(action.urls)
        case .downloadZip:
            ExportPanels.downloadZip(action.urls)
        case .copyOriginalPath, .copyCutoutPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                action.urls.map(\.path).joined(separator: "\n"),
                forType: .string
            )
        case .removeFromQueue:
            viewModel.removeFiles(ids: Set(selection.map(\.id)))
        }
    }

    @ViewBuilder
    private func cutoutCell(_ file: ImageFile) -> some View {
        let cutoutURL = file.cutoutURL(in: file.config)
        let exists = file.cutoutExists
        HStack(spacing: 6) {
            if exists, let thumb = ThumbnailCache.shared.thumbnail(for: cutoutURL) {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
            }
            Text(cutoutURL.lastPathComponent)
                .foregroundStyle(exists ? .primary : .tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .onTapGesture {
                    if exists { NSWorkspace.shared.open(cutoutURL) }
                }
        }
    }

    @ViewBuilder
    private func sourceFolderCell(_ file: ImageFile) -> some View {
        if let name = SourceFolder.name(for: file, byID: viewModel.batchesByID) {
            Text(name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(SourceFolder.url(for: file, byID: viewModel.batchesByID)?.path ?? name)
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }
}

/// Inline green chip shown when a drop just finished.
struct DropSummaryChip: View {
    let summary: DropSummary
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(addedLine)
                .font(.callout)
                .foregroundStyle(.primary)

            if summary.skipped > 0 {
                Text("· \(summary.skipped) skipped")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var addedLine: AttributedString {
        let n = summary.added
        let unit = n == 1 ? "image" : "images"
        var s = AttributedString("Added \(n) \(unit)")
        if !summary.folderName.isEmpty {
            let from = AttributedString(" from ")
            s.append(from)
            var name = AttributedString(summary.folderName)
            name.font = .callout.italic()
            s.append(name)
        }
        return s
    }
}

/// `KeyPathComparator` needs concrete `Comparable` properties. `Optional<Int>` doesn't
/// satisfy that on its own, so we expose stable sort keys.
private extension ImageFile {
    var bytesSortKey: Int { bytes ?? -1 }
    var pixelArea: Int { (width ?? 0) * (height ?? 0) }
    /// Sort by relativePath which carries the batch-relative prefix; loose files
    /// (empty relativePath) sort lexicographically at the top, batched files below.
    /// T1 acceptance: "loose files sink to bottom". `~` sorts after letters in ASCII.
    var sourceFolderSortKey: String { batchId == nil ? "~~~" : relativePath }
}
