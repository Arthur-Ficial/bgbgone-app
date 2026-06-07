import Foundation

/// Export already-produced cutouts to a user-chosen location: save a copy, save a
/// batch into a folder, or bundle them into a single `.zip`.
///
/// No image processing happens here — these are plain file copies and an archive of
/// finished PNG/JPEG cutouts. The zip is built by spawning `/usr/bin/zip`, the same
/// `Process` mechanism the app already uses to run the bundled `bgbgone` CLI (so we
/// never re-implement compression in-process either).
enum CutoutExporter {
    enum ExportError: Error, CustomStringConvertible {
        case noFiles
        case zipFailed(code: Int32, message: String)

        var description: String {
            switch self {
            case .noFiles: "No cutouts to export."
            case let .zipFailed(code, message):
                "Creating the ZIP failed (zip exited \(code)).\(message.isEmpty ? "" : " \(message)")"
            }
        }
    }

    /// Finder-style filename dedup: on a name collision the duplicate gets a
    /// " 2", " 3"… suffix before its extension. Input order is preserved. Pure — no I/O.
    static func exportNames(for urls: [URL]) -> [String] {
        var used = Set<String>()
        var names: [String] = []
        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var candidate = url.lastPathComponent
            var n = 1
            while used.contains(candidate) {
                n += 1
                candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            }
            used.insert(candidate)
            names.append(candidate)
        }
        return names
    }

    /// Copy a single cutout to `destination`, replacing any file already there
    /// (the user picked the destination in a save panel and confirmed overwrite).
    static func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    /// Copy every cutout into `folder`, deduping both within the batch and against
    /// files already present in the destination (never clobbers existing files).
    static func copyAll(cutouts: [URL], to folder: URL) throws {
        guard !cutouts.isEmpty else { throw ExportError.noFiles }
        let fm = FileManager.default
        let names = exportNames(for: cutouts)
        for (source, name) in zip(cutouts, names) {
            var dest = folder.appendingPathComponent(name)
            let base = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            var n = 1
            while fm.fileExists(atPath: dest.path) {
                n += 1
                let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                dest = folder.appendingPathComponent(next)
            }
            try fm.copyItem(at: source, to: dest)
        }
    }

    /// Build a flat `.zip` at `destination` containing every cutout (deduped names,
    /// no directory structure). Stages deduped copies in a temp dir, then archives
    /// them with `/usr/bin/zip`.
    static func makeZip(cutouts: [URL], at destination: URL) throws {
        guard !cutouts.isEmpty else { throw ExportError.noFiles }
        let fm = FileManager.default

        let staging = fm.temporaryDirectory.appendingPathComponent("bgbgone-zip-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let names = exportNames(for: cutouts)
        for (source, name) in zip(cutouts, names) {
            try fm.copyItem(at: source, to: staging.appendingPathComponent(name))
        }

        // zip *updates* an existing archive rather than replacing it — start clean.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = staging        // -> stored paths are bare filenames
        proc.arguments = ["-q", "-X", destination.path] + names
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let message = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExportError.zipFailed(code: proc.terminationStatus, message: message)
        }
    }
}
