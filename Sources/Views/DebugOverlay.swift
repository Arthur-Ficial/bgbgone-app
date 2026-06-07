import SwiftUI
import AppKit

#if DEBUG
/// `--debug` Tweaks panel — the AI-driveable affordance from the design's
/// `tweaks-panel.jsx`. Toggle with `cmd-` or with the `--debug` launch arg.
///
/// Sections:
///   • Drop-in demo — force any drop phase for visual snapshotting
///   • Demo — reset queue, mark-all-done
///   • CLI echo — exact argv the spawned bgbgone would receive for the
///     currently selected file, with one-click copy
///   • Log tail — last 100 OSLog events tagged with their category
///   • Force binary path — override the resolved bgbgone path (persists to
///     ~/Library/Application Support/bgbgone-app/settings.json)
struct DebugOverlay: View {
    @Bindable var viewModel: AppViewModel
    let log: DebugLog
    let onClose: () -> Void
    @State private var binaryPathOverride: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dropDemoSection
                    Divider().background(DesignColor.border)
                    demoActionsSection
                    Divider().background(DesignColor.border)
                    cliEchoSection
                    Divider().background(DesignColor.border)
                    logTailSection
                    Divider().background(DesignColor.border)
                    binaryOverrideSection
                }
                .padding(14)
            }
        }
        .frame(width: 320, height: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.6)))
        .shadow(color: .black.opacity(0.18), radius: 40, x: 0, y: 12)
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        HStack {
            Text("Tweaks").font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignColor.fgMute)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignColor.borderSoft).frame(height: 1) }
    }

    // MARK: - Drop-in demo

    @ViewBuilder private var dropDemoSection: some View {
        SectionLabel("Drop-in demo")
        ForEach(DemoPhase.allCases, id: \.self) { phase in
            Button {
                phase.apply(to: viewModel)
            } label: {
                HStack {
                    Text(phase.label)
                    Spacer()
                    if phase.isActive(viewModel) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(DesignColor.fg)
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(phase.isActive(viewModel) ? Color.white.opacity(0.7) : .clear)
            )
        }
    }

    // MARK: - Demo actions

    @ViewBuilder private var demoActionsSection: some View {
        SectionLabel("Demo")
        VStack(alignment: .leading, spacing: 6) {
            Button("Reset to fresh state") {
                viewModel.resetAllForDebug()
                log.clear()
            }
            .buttonStyle(MiniDebugButtonStyle())

            Button("Mark all done") {
                for idx in viewModel.files.indices {
                    viewModel.files[idx].state = .done(milliseconds: 80)
                }
            }
            .buttonStyle(MiniDebugButtonStyle())
        }
    }

    // MARK: - CLI echo

    @ViewBuilder private var cliEchoSection: some View {
        SectionLabel("CLI echo")
        let argv = previewArgv()
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(argv.isEmpty ? "(select a file to preview)" : argv)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(argv.isEmpty ? DesignColor.fgFaint : DesignColor.fg)
                    .lineLimit(1)
            }
            .frame(height: 26)
            .padding(.horizontal, 8)
            .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(argv, forType: .string)
            }
            .buttonStyle(MiniDebugButtonStyle())
            .disabled(argv.isEmpty)
        }
    }

    private func previewArgv() -> String {
        guard let selected = viewModel.files.first(where: { $0.id == viewModel.selectedId }) else { return "" }
        let cmd = BgBgOneCommand(
            input: selected.url,
            output: selected.cutoutURL(in: viewModel.config),
            background: viewModel.config.background,
            format: viewModel.config.format
        )
        return (try? cmd.arguments())?.joined(separator: " ") ?? "(invalid: would refuse to run)"
    }

    // MARK: - Log tail

    @ViewBuilder private var logTailSection: some View {
        SectionLabel("Log tail (last \(log.events.count))")
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if log.events.isEmpty {
                        Text("(no events yet — drop a folder and hit Remove background)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DesignColor.fgFaint)
                    }
                    ForEach(log.events) { event in
                        HStack(spacing: 4) {
                            Text("[\(event.category)]")
                                .foregroundStyle(Color.accentColor)
                            Text(event.message)
                                .foregroundStyle(DesignColor.fg)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .id(event.id)
                    }
                }
            }
            .frame(height: 140)
            .padding(8)
            .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            .onChange(of: log.events.count) { _, _ in
                if let last = log.events.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: - Binary override

    @ViewBuilder private var binaryOverrideSection: some View {
        SectionLabel("Force binary path")
        VStack(alignment: .leading, spacing: 6) {
            TextField("/path/to/bgbgone (blank = auto)", text: $binaryPathOverride)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            HStack(spacing: 6) {
                Button("Save (restart needed)") {
                    let trimmed = binaryPathOverride.trimmingCharacters(in: .whitespaces)
                    let url = trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
                    try? BinaryLocator.writeOverridePath(url)
                }.buttonStyle(MiniDebugButtonStyle())
                Button("Clear") {
                    binaryPathOverride = ""
                    try? BinaryLocator.writeOverridePath(nil)
                }.buttonStyle(MiniDebugButtonStyle())
            }
        }
        .onAppear {
            binaryPathOverride = BinaryLocator.readOverridePath()?.path ?? ""
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.06 * 10)
            .textCase(.uppercase)
            .foregroundStyle(DesignColor.fgMute)
            .padding(.vertical, 4)
    }
}

private struct MiniDebugButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .foregroundStyle(isEnabled ? .white : DesignColor.fgFaint)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isEnabled
                          ? (configuration.isPressed
                             ? Color(white: 0.6)
                             : Color(white: 0.22))
                          : Color(white: 0.85))
            )
    }
}

/// Force-a-phase enum. Used to drive the demo radio in the overlay.
enum DemoPhase: String, CaseIterable {
    case idle = "Idle (default)"
    case empty = "Empty — first run"
    case dragFolder = "Drag: one folder"
    case dragFiles = "Drag: many images"
    case dragMixed = "Drag: folder + extras"
    case dragBlocked = "Drag: nothing usable"
    case ingest = "Ingesting folder"
    case summary = "Post-drop summary"

    var label: String { rawValue }

    @MainActor
    func isActive(_ vm: AppViewModel) -> Bool {
        switch (self, vm.dropMachine.phase) {
        case (.idle, .idle): vm.files.isEmpty == false
        case (.empty, .idle): vm.files.isEmpty
        case (.dragFolder, .drag(let h)): h.folderCount == 1 && h.imageCount == 0
        case (.dragFiles, .drag(let h)): h.folderCount == 0 && h.imageCount > 1
        case (.dragMixed, .drag(let h)): h.folderCount == 1 && h.imageCount > 0
        case (.dragBlocked, .drag(let h)): h.otherCount > 0 && h.imageCount == 0 && h.folderCount == 0
        case (.ingest, .ingest): true
        case (.summary, .summary): true
        default: false
        }
    }

    @MainActor
    func apply(to vm: AppViewModel) {
        switch self {
        case .idle:
            vm.dismissSummary()
            if case .drag = vm.dropMachine.phase { vm.handleDragLeave() }
        case .empty:
            vm.resetAllForDebug()
        case .dragFolder:
            vm.handleDragEnter(hint: DragHint(folderCount: 1, imageCount: 0, otherCount: 0, folderName: "client-headshots"))
        case .dragFiles:
            vm.handleDragEnter(hint: DragHint(folderCount: 0, imageCount: 12, otherCount: 0, folderName: ""))
        case .dragMixed:
            vm.handleDragEnter(hint: DragHint(folderCount: 1, imageCount: 4, otherCount: 2, folderName: "campaign-assets"))
        case .dragBlocked:
            vm.handleDragEnter(hint: DragHint(folderCount: 0, imageCount: 0, otherCount: 3, folderName: ""))
        case .ingest:
            vm.dropMachine.handleDrop(folderName: "client-headshots")
            // Synthesize a partial ingest state so the overlay actually has something to show.
            vm.dropMachine.applyScanEvent(.scanned(url: URL(fileURLWithPath: "/tmp/a.jpg"), isImage: true))
            vm.dropMachine.applyScanEvent(.foundImage(url: URL(fileURLWithPath: "/tmp/a.jpg"), relativePath: "client-headshots/anna_v3.heic"))
            vm.dropMachine.applyScanEvent(.foundImage(url: URL(fileURLWithPath: "/tmp/b.jpg"), relativePath: "client-headshots/raw/lukas_03.jpg"))
        case .summary:
            vm.dropMachine.handleDrop(folderName: "client-headshots")
            vm.dropMachine.applyScanEvent(.completed(images: [], scannedCount: 47, skippedCount: 3))
        }
    }
}
#endif
