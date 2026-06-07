import AppKit
import UniformTypeIdentifiers

/// Stock AppKit save/open panels that drive `CutoutExporter`. Kept in one place so
/// both the file-list context menu and the inspector "Download" button present the
/// same native chrome (`NSSavePanel` / `NSOpenPanel` / `NSAlert`) — never a custom modal.
@MainActor
enum ExportPanels {
    /// Save one cutout to a location the user picks.
    static func saveSingle(_ cutout: URL) {
        let panel = NSSavePanel()
        panel.title = "Download Cutout"
        panel.prompt = "Download"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = cutout.lastPathComponent
        if let type = UTType(filenameExtension: cutout.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        run { try CutoutExporter.copy(cutout, to: dest) }
    }

    /// One cutout → a save panel; many → a "choose a folder" open panel.
    static func save(_ cutouts: [URL]) {
        guard let first = cutouts.first else { return }
        if cutouts.count == 1 { saveSingle(first); return }

        let panel = NSOpenPanel()
        panel.title = "Download \(cutouts.count) Cutouts"
        panel.message = "Choose a folder to save \(cutouts.count) cutouts into."
        panel.prompt = "Download Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run { try CutoutExporter.copyAll(cutouts: cutouts, to: folder) }
    }

    /// Bundle the given cutouts into a single `.zip` the user names and places.
    static func downloadZip(_ cutouts: [URL]) {
        guard let first = cutouts.first else { return }
        let panel = NSSavePanel()
        panel.title = "Download as ZIP"
        panel.prompt = "Download"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = cutouts.count == 1
            ? first.deletingPathExtension().lastPathComponent + ".zip"
            : "cutouts.zip"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        run { try CutoutExporter.makeZip(cutouts: cutouts, at: dest) }
    }

    private static func run(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t download"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }
}
