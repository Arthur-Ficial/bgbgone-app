import Foundation
import Testing
@testable import bgbgone_app

/// Regression guard for the "stale CUTOUT preview" bug (found 2026-06-07): the dual
/// preview surfaced a pre-existing output file (e.g. a flipped cutout left on disk by an
/// older bgbgone build) for a freshly-ingested file that had NOT been processed this
/// session — its row still read "Not removed" yet a cutout rendered.
///
/// Invariant (already documented on `ImageFile.cutoutExists`): a `.raw` file has no
/// cutout from this session, regardless of what happens to sit at its output path.
/// The CUTOUT pane must show only pixels a real run produced.
@MainActor
@Suite("CUTOUT preview shows only this-session output (no stale files)")
struct CutoutPreviewFreshnessTests {
    struct InstantRunner: BgBgOneRunning {
        func run(arguments: [String]) async throws -> RunResult {
            RunResult(input: URL(fileURLWithPath: "/x"), output: URL(fileURLWithPath: "/out.png"),
                      algo: "vn-mask", format: "png", width: 1, height: 1, durationMillis: 1)
        }
    }
    struct StubMetaReader: ImageMetaReading {
        func read(_ url: URL) throws -> ImageMeta { ImageMeta(width: 100, height: 100, bytes: 1234) }
    }

    static var fixtureImage: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return url.appendingPathComponent("fixtures/scan-tree/top.jpg")
    }

    @Test func freshlyIngestedRawFileDoesNotSurfaceAStaleCutout() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cutout-fresh-\(UUID().uuidString)", isDirectory: true)
        let srcDir = tmp.appendingPathComponent("src", isDirectory: true)
        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let src = srcDir.appendingPathComponent("top.jpg")
        try fm.copyItem(at: Self.fixtureImage, to: src)

        let vm = AppViewModel(
            runner: InstantRunner(),
            scanner: FolderScanner(),
            metaReader: StubMetaReader(),
            bootState: .ready(binary: URL(fileURLWithPath: "/tmp/bgbgone-stub")),
            historyStore: nil
        )
        vm.defaultConfig = Config(outDirectory: outDir)

        // Simulate a leftover cutout at the deterministic output path — exactly the
        // ~/Pictures/cutouts/*_bgbgone.png left by a previous (flip-buggy) CLI build.
        let stale = ImageFile(url: src, config: vm.defaultConfig).cutoutURL(in: vm.defaultConfig)
        try Data("stale-flipped-cutout".utf8).write(to: stale)
        #expect(fm.fileExists(atPath: stale.path))

        await vm.handleDrop(urls: [srcDir])

        let file = try #require(vm.files.first { $0.name == "top.jpg" })
        guard case .raw = file.state else {
            Issue.record("freshly-ingested file should be .raw (\"Not removed\"), got \(file.state)")
            return
        }
        #expect(
            file.cutoutExists == false,
            "a .raw file must not surface a pre-existing on-disk cutout — that renders a stale/foreign result as if it were this run's output"
        )
    }
}
