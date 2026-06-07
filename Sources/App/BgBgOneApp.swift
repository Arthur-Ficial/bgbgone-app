import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Bridge from the menu-bar `File ▸ Add Files…` command to the
    /// `ContentView`'s `addFiles()` (where `NSOpenPanel` lives). Posted
    /// by the `.commands` closure, observed by `ContentView`.
    static let bgbgoneAddFiles = Notification.Name("bgbgone.addFiles")
}

@main
struct BgBgOneApp: App {
    @NSApplicationDelegateAdaptor(MenuBarPruner.self) private var menuPruner
    @State private var viewModel = AppViewModel()
    @State private var updater = UpdaterService()

    var body: some Scene {
        WindowGroup("bgbgone") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 1100, idealWidth: 1180, minHeight: 720, idealHeight: 780)
                .tint(.accentColor) // charter: inherit the user's chosen Mac accent, never a hardcoded blue
        }
        .windowResizability(.contentMinSize)
        .commands { BgBgOneCommands(viewModel: viewModel, updater: updater) }
    }
}

/// All menu-bar items live here. Aggressively prunes the macOS defaults
/// so every visible item maps to a real action this app supports.
/// Wrapped in its own `Commands` type to stay under SwiftUI's 10-item
/// `.commands { }` result-builder limit.
struct BgBgOneCommands: Commands {
    @Bindable var viewModel: AppViewModel
    var updater: UpdaterService

    var body: some Commands {
        // -- App menu: "Check for Updates…" sits right under "About", where every
        // Mac app puts it. Bound to Sparkle via UpdaterService.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }

        // -- File: a single real entry. "Add Files…" with ⌘O wakes the
        // NSOpenPanel via NotificationCenter; the rest of File is killed.
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") {
                NotificationCenter.default.post(name: .bgbgoneAddFiles, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        BgBgOneStripDefaults()

        // -- Edit: Undo/Redo bound to our run history, plus selection --
        CommandGroup(replacing: .undoRedo) {
            Button(viewModel.undoManager.canUndo ? viewModel.undoManager.undoLabel : "Undo") {
                Task { await viewModel.undoLastRun() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!viewModel.undoManager.canUndo || viewModel.activeRun != nil)

            Button(viewModel.undoManager.canRedo ? viewModel.undoManager.redoLabel : "Redo") {
                Task { await viewModel.redoLastRun() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!viewModel.undoManager.canRedo || viewModel.activeRun != nil)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Select All Visible") { viewModel.selectAllVisible() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(viewModel.files.isEmpty)
            Button("Deselect All") { viewModel.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(viewModel.selectedIds.isEmpty)
        }
    }
}

/// Empty-replace bag for the macOS default menu groups this app doesn't
/// use. Stays under the 10-item result-builder limit by living in its
/// own `Commands` type. Keep stock Hide / Hide Others / Show All /
/// Quit — those are muscle memory; only kill the noise.
struct BgBgOneStripDefaults: Commands {
    var body: some Commands {
        CommandGroup(replacing: .saveItem)        {} // no Save / Save As
        CommandGroup(replacing: .importExport)    {} // no Import / Export
        CommandGroup(replacing: .printItem)       {} // no Print / Page Setup
        CommandGroup(replacing: .textEditing)     {} // no Find / Spelling
        CommandGroup(replacing: .textFormatting)  {} // no Font / Bigger / Smaller
        CommandGroup(replacing: .toolbar)         {} // no Show Tab Bar / Customize Toolbar
        CommandGroup(replacing: .sidebar)         {} // toolbar button covers this
        CommandGroup(replacing: .help)            {} // no help book bundled
        CommandGroup(replacing: .systemServices)  {} // Services submenu — never used here
    }
}

struct ContentView: View {
    @Bindable var viewModel: AppViewModel
    @State private var isDropTargeted = false
    @State private var isInspectorPresented: Bool = false
    #if DEBUG
    @State private var isDebugOpen: Bool = ProcessInfo.processInfo.arguments.contains("--debug")
    #else
    @State private var isDebugOpen: Bool = false // debug overlay is stripped from release builds
    #endif

    var body: some View {
        Group {
            switch viewModel.bootState {
            case .starting:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missingBinary(let searched):
                MissingBinaryView(searched: searched, onRetry: { /* reload via app restart */ })
            case .ready:
                mainWindow
            }
        }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if isDebugOpen {
                DebugOverlay(viewModel: viewModel, log: DebugLog.shared) {
                    isDebugOpen = false
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .background {
            Button("") { isDebugOpen.toggle() }
                .keyboardShortcut("`", modifiers: .command)
                .opacity(0)
        }
        .animation(.easeOut(duration: 0.16), value: isDebugOpen)
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .bgbgoneAddFiles)) { _ in
            addFiles()
        }
    }

    @AppStorage("bigPreviewHeight") private var bigPreviewHeight: Double = 230
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly

    @ViewBuilder private var mainWindow: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SourceSidebar(viewModel: viewModel)
        } detail: {
            VStack(spacing: 0) {
                if !viewModel.files.isEmpty {
                    BigDualPreview(viewModel: viewModel)
                        .frame(height: bigPreviewHeight)
                    PreviewSplitter(height: $bigPreviewHeight)
                }
                FileListView(
                    viewModel: viewModel,
                    onDismissSummary: { viewModel.dismissSummary() }
                )
            }
            .navigationTitle("bgbgone")
            .navigationSubtitle(viewModel.files.isEmpty ? "" : subtitle)
            .onChange(of: viewModel.files.isEmpty) { wasEmpty, isEmpty in
                // Reveal sidebar + open inspector the moment the user has
                // content. Stay collapsed on first launch so the empty state
                // shows nothing but the drop zone (KISS).
                sidebarVisibility = isEmpty ? .detailOnly : .all
                if wasEmpty && !isEmpty { isInspectorPresented = true }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !viewModel.files.isEmpty {
                    StatusBar(viewModel: viewModel)
                }
            }
            .inspector(isPresented: $isInspectorPresented) {
                InspectorPane(viewModel: viewModel)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await viewModel.handleDrop(urls: urls) }
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
                if targeted {
                    viewModel.handleDragEnter(hint: DragHint(folderCount: 0, imageCount: 1, otherCount: 0, folderName: ""))
                } else {
                    viewModel.handleDragLeave()
                }
            }
            .overlay {
                if case .drag(let hint) = viewModel.dropMachine.phase {
                    DropVeil(hint: hint)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if case .ingest(let state) = viewModel.dropMachine.phase {
                    IngestOverlay(state: state, onCancel: { viewModel.dismissSummary() })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.16), value: phaseIndex)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Files…", systemImage: "plus", action: addFiles)
                        .help("Add image files to the queue")
                        .accessibilityIdentifier("toolbar.addFiles")
                }
                // "Run all" — visible whenever there are files. Always runs
                // EVERY file with the current Inspector settings (re-runs
                // already-done files too). One button, one label, one job.
                if !viewModel.files.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(viewModel.activeRun != nil ? "Stop" : "Run all") {
                            if viewModel.activeRun != nil {
                                viewModel.stopActiveRun()
                            } else {
                                Task { await viewModel.runAllWithVisibleSettings() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .help(viewModel.activeRun != nil
                              ? "Stop the running batch"
                              : "Apply the current Inspector settings to every image and process them all")
                        .accessibilityIdentifier("toolbar.runAll")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(
                        isInspectorPresented ? "Hide Inspector" : "Show Inspector",
                        systemImage: "sidebar.right"
                    ) { isInspectorPresented.toggle() }
                    .help(isInspectorPresented ? "Hide inspector" : "Show inspector")
                    .accessibilityIdentifier("toolbar.inspectorToggle")
                }
            }
        }
    }

    private var subtitle: String {
        let n = viewModel.files.count
        if n == 0 { return "Drop a folder to begin" }
        return "\(n) image\(n == 1 ? "" : "s")"
    }


    private var phaseIndex: Int {
        switch viewModel.dropMachine.phase {
        case .idle: 0
        case .drag: 1
        case .ingest: 2
        case .summary: 3
        }
    }

    // MARK: - File pickers + drop

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        Task { await viewModel.handleDrop(urls: panel.urls) }
    }

}

/// Right-side inspector: settings only (T12 moved the dual preview to the top of the
/// middle column). Metadata strip + settings + per-item run history.
private struct InspectorPane: View {
    @Bindable var viewModel: AppViewModel

    @State private var advancedExpanded: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let selected = viewModel.selectedFile {
                    SelectedMeta(file: selected)
                    Divider()
                    rerunRow(for: selected)
                    Divider()
                }
                ConfigPanel(config: viewModel.inspectorConfigBinding)
                Divider()
                advancedSection
            }
        }
    }

    @ViewBuilder
    private func rerunRow(for file: ImageFile) -> some View {
        HStack {
            Button("Rerun This Image") {
                Task { await viewModel.rerun(ids: [file.id]) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.activeRun != nil)
            .help("Re-process this image with the current settings — any state, any time")

            Button {
                ExportPanels.saveSingle(file.cutoutURL(in: file.config))
            } label: {
                Label("Download Cutout", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(!file.cutoutExists)
            .help("Save the processed cutout to a location you choose")
            .accessibilityIdentifier("inspector.downloadCutout")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Everything power-users want lives behind ONE disclosure so first-time
    /// users see only Background / Format / Algorithm. Built from plain
    /// `VStack` + `GroupBox` instead of `Form` (`.grouped`) — Form's
    /// layout machinery on macOS 26 is the biggest cost in the Inspector.
    @ViewBuilder private var advancedSection: some View {
        ClickRowDisclosure(title: "Advanced", isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Save to") {
                    SaveToRow(config: viewModel.inspectorConfigBinding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Name as") {
                    NamePatternRow(config: viewModel.inspectorConfigBinding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Filters (--filter chain)") {
                    VStack(alignment: .leading, spacing: 8) {
                        MaskFiltersForm(config: viewModel.inspectorConfigBinding)
                        Divider()
                        TransformsForm(config: viewModel.inspectorConfigBinding)
                        Divider()
                        BackgroundFiltersForm(config: viewModel.inspectorConfigBinding)
                        Divider()
                        AdvancedChainEditor(config: viewModel.inspectorConfigBinding)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                RunHistoryView(
                    file: viewModel.selectedFile,
                    store: viewModel.historyStore
                )
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Save-to picker, extracted from `ConfigPanel` so the always-visible
/// inspector now shows only Background/Format/Algorithm. Re-uses stock
/// `fileImporter`.
private struct SaveToRow: View {
    @Binding var config: Config
    @State private var pickerShown = false

    var body: some View {
        HStack {
            Label(displayPath, systemImage: "folder")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") { pickerShown = true }
        }
        .fileImporter(isPresented: $pickerShown, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { config.outDirectory = url }
        }
    }

    private var displayPath: String {
        config.outDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Filename pattern field + token chips — moved out of the always-visible
/// inspector. Power-user feature; defaults are sane.
private struct NamePatternRow: View {
    @Binding var config: Config

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filename pattern", text: $config.namePattern)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            HStack(spacing: 6) {
                ForEach(["{name}", "{ext}", "{n:02}"], id: \.self) { token in
                    Button(token) { config.namePattern += token }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct InspectorEmpty: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No image selected")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Drop images on the file list to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorPickHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Pick a file in the list")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
