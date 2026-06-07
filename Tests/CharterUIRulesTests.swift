import Foundation
import Testing
@testable import bgbgone_app

/// Source-level guards for charter rules surfaced by the 2026-06-07 UI/UX audit.
/// Reuses `NoFakeUITests` comment-stripping so the docs that explain these rules
/// don't trip the checks. Each test maps to a confirmed audit finding.
@Suite("Charter UI rules — audit-driven source guards")
struct CharterUIRulesTests {
    static func allCode() throws -> String {
        var s = ""
        for (_, text) in try NoFakeUITests.codeOnlySourceTexts() { s += text + "\n" }
        return s
    }

    static func code(of fileName: String) throws -> String {
        for (url, text) in try NoFakeUITests.codeOnlySourceTexts() where url.lastPathComponent == fileName {
            return text
        }
        return ""
    }

    /// Colour must be the SYSTEM accent (`.tint(.accentColor)`), never a hardcoded blue.
    /// (Audit seed finding: DesignTokens.accent = #007aff.)
    @Test func accentIsSystemNotHardcoded() throws {
        let code = try Self.allCode()
        #expect(!code.contains("DesignColor.accent"), "use Color.accentColor / .tint(.accentColor), not a DesignColor.accent token")
        #expect(!code.contains("accentPress"), "hardcoded accentPress blue must be gone")
        #expect(!code.contains("accentSoft"), "hardcoded accentSoft blue must be gone")
        #expect(!code.contains("Color(red: 0/255,   green: 122/255, blue: 255/255)"), "the #007aff literal must be gone")
        #expect(code.contains(".tint(.accentColor)"), "the app must adopt the system accent at the root")
    }

    /// The debug Tweaks overlay must be stripped from release builds.
    @Test func debugOverlayIsDebugGated() throws {
        let code = try Self.code(of: "DebugOverlay.swift")
        #expect(code.contains("#if DEBUG"), "DebugOverlay must be wrapped in #if DEBUG so it never ships in release")
    }

    /// The missing-binary screen must not tell users to install via Homebrew —
    /// the engine is bundled-only; that instruction is false. (Audit blocker.)
    @Test func missingBinaryHasNoHomebrewInstruction() throws {
        let code = try Self.code(of: "MissingBinaryView.swift")
        #expect(!code.contains("brew install"), "bundled-only app must not instruct a Homebrew install")
    }

    /// Algorithm help text must describe behaviour in plain language, not leak
    /// internal Vision request class names to end users.
    @Test func algorithmHelpTextHasNoVisionAPINames() throws {
        let code = try Self.code(of: "Config.swift")
        #expect(!code.contains("VNGenerate"), "help text must not expose VNGenerate* API names")
    }

    /// Primary interactive controls must carry accessibilityIdentifiers (audit Item 0 —
    /// none existed) so assistive tech and e2e automation can target them.
    @Test func primaryControlsHaveAccessibilityIdentifiers() throws {
        let code = try Self.allCode()
        for id in ["toolbar.addFiles", "toolbar.runAll", "toolbar.inspectorToggle",
                   "config.background", "config.format", "config.algorithm",
                   "config.colour", "empty.tryDemo", "ctx.processThisOnly"] {
            #expect(code.contains("\"\(id)\""), "missing accessibilityIdentifier \"\(id)\"")
        }
    }
}
