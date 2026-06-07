import Foundation
import Testing
@testable import bgbgone_app

@Suite("CutoutExporter (download / zip)")
struct CutoutExporterTests {
    // MARK: exportNames — pure dedup logic

    @Test func exportNamesKeepsDistinctNames() {
        let urls = [
            URL(fileURLWithPath: "/a/cat_bgbgone.png"),
            URL(fileURLWithPath: "/b/dog_bgbgone.png"),
        ]
        #expect(CutoutExporter.exportNames(for: urls) == ["cat_bgbgone.png", "dog_bgbgone.png"])
    }

    @Test func exportNamesDedupesCollisionsFinderStyle() {
        let urls = [
            URL(fileURLWithPath: "/a/x.png"),
            URL(fileURLWithPath: "/b/x.png"),
            URL(fileURLWithPath: "/c/x.png"),
        ]
        #expect(CutoutExporter.exportNames(for: urls) == ["x.png", "x 2.png", "x 3.png"])
    }

    // MARK: makeZip — real archive, real unzip

    @Test func makeZipProducesArchiveContainingEveryCutout() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cutex-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let a = work.appendingPathComponent("alpha_bgbgone.png")
        let b = work.appendingPathComponent("beta_bgbgone.png")
        try Data("AAA".utf8).write(to: a)
        try Data("BBB".utf8).write(to: b)

        let zipURL = work.appendingPathComponent("out.zip")
        try CutoutExporter.makeZip(cutouts: [a, b], at: zipURL)
        #expect(fm.fileExists(atPath: zipURL.path))

        // Extract and verify both files survived with their original bytes.
        let extract = work.appendingPathComponent("extract")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, extract.path]
        try proc.run(); proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        #expect(try Data(contentsOf: extract.appendingPathComponent("alpha_bgbgone.png")) == Data("AAA".utf8))
        #expect(try Data(contentsOf: extract.appendingPathComponent("beta_bgbgone.png")) == Data("BBB".utf8))
    }

    @Test func makeZipThrowsOnEmptyInput() {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("empty.zip")
        #expect(throws: CutoutExporter.ExportError.self) {
            try CutoutExporter.makeZip(cutouts: [], at: dest)
        }
    }

    // MARK: copyAll — real copies into a folder

    @Test func copyAllCopiesEveryCutoutIntoDestination() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cutex-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let a = work.appendingPathComponent("one.png")
        let b = work.appendingPathComponent("two.png")
        try Data("1".utf8).write(to: a)
        try Data("2".utf8).write(to: b)

        let dest = work.appendingPathComponent("dest")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try CutoutExporter.copyAll(cutouts: [a, b], to: dest)
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("one.png").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("two.png").path))
    }
}
