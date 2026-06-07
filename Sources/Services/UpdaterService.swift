import Observation
import Sparkle

/// Auto-update via Sparkle. See docs/superpowers/specs/2026-06-07-sparkle-auto-update-design.md.
///
/// Thin wrapper over `SPUStandardUpdaterController`: the updater starts automatically,
/// reads `SUFeedURL` / `SUPublicEDKey` from the bundle Info.plist, presents Sparkle's own
/// (real AppKit) update window, and on first launch asks the user whether to check
/// automatically. The only state we surface to SwiftUI is `canCheckForUpdates`, used to
/// enable/disable the "Check for Updates…" menu item.
///
/// Charter note: Sparkle is a deliberate third-party exception (Apple ships no updater for
/// Developer-ID apps). No business logic lives here — Sparkle owns the whole update flow.
@MainActor
@Observable
final class UpdaterService {
    /// True when the updater is idle and a user-initiated check is allowed.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = controller.updater.canCheckForUpdates
        // Sparkle exposes canCheckForUpdates as a KVO-compliant property. Observe it
        // (KVO, not Combine — per the repo's modern-Foundation baseline) and mirror it
        // onto the @Observable property the menu binds to.
        observation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// User-initiated check — shows Sparkle's progress / "you're up to date" / update UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
