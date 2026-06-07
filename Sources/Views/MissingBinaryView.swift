import SwiftUI
import AppKit

/// Shown when `BinaryLocator` cannot find the bgbgone CLI anywhere — with the embedded
/// fallback in place this should be unreachable, but it stays as a defensive UI.
struct MissingBinaryView: View {
    let searched: [String]
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(DesignColor.fgFaint)

            Text("Where's bgbgone?")
                .font(DesignFont.displayName)
                .foregroundStyle(DesignColor.fg)

            Text("The bgbgone engine that ships inside this app is missing or unreadable. Reinstalling bgbgone-app restores the bundled engine.")
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.fgMute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)

            if !searched.isEmpty {
                DisclosureGroup("Searched paths") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(searched, id: \.self) { path in
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DesignColor.fgFaint)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(DesignColor.fgMute)
                .frame(maxWidth: 440)
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColor.bg)
    }
}
