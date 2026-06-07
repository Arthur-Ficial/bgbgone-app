import Foundation

/// Pure-logic builder for the right-click context menu on file rows (T2). Returns a
/// declarative list of `ActionItem`s that the view layer dispatches by `kind` (the
/// SwiftUI side wires `NSWorkspace`, `NSPasteboard`, and queue removal).
///
/// Disable state is backed by a `fileExists` closure (production: `FileManager.default
/// .fileExists`) so the menu reflects real disk truth rather than processing state alone.
enum FileRowActions {
    enum Kind: Sendable, Hashable {
        case revealOriginal
        case revealCutout
        case openOriginal
        case openCutout
        case saveCutout
        case downloadZip
        case copyOriginalPath
        case copyCutoutPath
        case removeFromQueue
    }

    struct ActionItem: Sendable, Hashable, Identifiable {
        let kind: Kind
        let label: String
        let isEnabled: Bool
        let urls: [URL]
        var id: Kind { kind }
    }

    static func actions(
        for selection: [ImageFile],
        cutoutURL: (ImageFile) -> URL?,
        fileExists: (URL) -> Bool
    ) -> [ActionItem] {
        let originals = selection.map(\.url)
        let cutouts = selection.compactMap(cutoutURL)
        let originalsAllExist = !originals.isEmpty && originals.allSatisfy(fileExists)
        let cutoutsAllExist = !cutouts.isEmpty && cutouts.count == selection.count && cutouts.allSatisfy(fileExists)
        let n = selection.count

        return [
            ActionItem(
                kind: .revealOriginal,
                label: pluralize("Reveal", noun: "Original", suffix: "in Finder", count: n),
                isEnabled: originalsAllExist,
                urls: originals
            ),
            ActionItem(
                kind: .revealCutout,
                label: pluralize("Reveal", noun: "Cutout", suffix: "in Finder", count: n),
                isEnabled: cutoutsAllExist,
                urls: cutouts
            ),
            ActionItem(
                kind: .openOriginal,
                label: pluralize("Open", noun: "Original", suffix: nil, count: n),
                isEnabled: originalsAllExist,
                urls: originals
            ),
            ActionItem(
                kind: .openCutout,
                label: pluralize("Open", noun: "Cutout", suffix: nil, count: n),
                isEnabled: cutoutsAllExist,
                urls: cutouts
            ),
            ActionItem(
                kind: .saveCutout,
                label: n == 1 ? "Save Cutout As…" : "Save \(n) Cutouts…",
                isEnabled: cutoutsAllExist,
                urls: cutouts
            ),
            ActionItem(
                kind: .downloadZip,
                label: n == 1 ? "Download as ZIP…" : "Download \(n) Cutouts as ZIP…",
                isEnabled: cutoutsAllExist,
                urls: cutouts
            ),
            ActionItem(
                kind: .copyOriginalPath,
                label: n == 1 ? "Copy Original Path" : "Copy \(n) Original Paths",
                isEnabled: !selection.isEmpty,
                urls: originals
            ),
            ActionItem(
                kind: .copyCutoutPath,
                label: n == 1 ? "Copy Cutout Path" : "Copy \(n) Cutout Paths",
                isEnabled: cutoutsAllExist,
                urls: cutouts
            ),
            ActionItem(
                kind: .removeFromQueue,
                label: n == 1 ? "Remove from Queue" : "Remove \(n) from Queue",
                isEnabled: !selection.isEmpty,
                urls: originals
            ),
        ]
    }

    private static func pluralize(_ verb: String, noun: String, suffix: String?, count: Int) -> String {
        let core: String
        if count == 1 {
            core = "\(verb) \(noun)"
        } else {
            core = "\(verb) \(count) \(noun)s"
        }
        if let suffix { return "\(core) \(suffix)" }
        return core
    }
}
