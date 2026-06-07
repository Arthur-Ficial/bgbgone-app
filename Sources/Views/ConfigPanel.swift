import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Inspector form: Background / Format / Algorithm pickers. Takes an
/// explicit `Binding<Config>` so it can edit either the selected file's
/// per-image config or the default-template config — the caller decides
/// which by passing the right binding.
struct ConfigPanel: View {
    @Binding var config: Config
    @State private var imageImporterShown = false
    @State private var colourBinding: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Background") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Background", selection: backgroundCase) {
                            Text("Transparent").tag(BackgroundCase.transparent)
                            Text("Color").tag(BackgroundCase.color)
                            Text("Image").tag(BackgroundCase.image)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("config.background")
                        Spacer(minLength: 0)
                    }

                    if case .color = config.background {
                        ColorPicker("Colour", selection: $colourBinding, supportsOpacity: false)
                            .accessibilityIdentifier("config.colour")
                            .onChange(of: colourBinding) { _, new in
                                config.background = .color(hex: new.toHex() ?? "#ffffff")
                            }
                    }
                    if case .image(let url) = config.background {
                        HStack {
                            Label(url.lastPathComponent, systemImage: "photo")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Change…") { imageImporterShown = true }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Format") {
                HStack {
                    Picker("Format", selection: $config.format) {
                        ForEach(OutputFormat.allCases, id: \.self) { format in
                            Text(format.displayLabel).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("config.format")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Algorithm") {
                HStack {
                    Picker("Algorithm", selection: $config.algorithm) {
                        ForEach(Algorithm.allCases, id: \.self) { algo in
                            Text(algo.displayLabel).tag(algo)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("config.algorithm")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fileImporter(
            isPresented: $imageImporterShown,
            allowedContentTypes: [.png, .jpeg, .heic, .tiff],
            onCompletion: handleImagePick
        )
        .onAppear(perform: syncColourFromBackground)
        .onChange(of: config.background) { _, _ in syncColourFromBackground() }
    }

    /// Bridge `BackgroundChoice` (associated values) ↔ `Picker` (needs a `Hashable` tag).
    private var backgroundCase: Binding<BackgroundCase> {
        Binding(
            get: {
                switch config.background {
                case .transparent: .transparent
                case .color: .color
                case .image: .image
                }
            },
            set: { newCase in
                switch newCase {
                case .transparent:
                    config.background = .transparent
                case .color:
                    let hex = colourBinding.toHex() ?? "#ffffff"
                    config.background = .color(hex: hex)
                case .image:
                    imageImporterShown = true
                }
            }
        )
    }

    private func handleImagePick(_ result: Result<URL, Error>) {
        if case .success(let url) = result {
            config.background = .image(url)
        }
    }

    private func syncColourFromBackground() {
        if case .color(let hex) = config.background {
            colourBinding = Color(hex: hex)
        }
    }
}

private enum BackgroundCase: Hashable { case transparent, color, image }

/// `Color` → `#rrggbb` for storage in `Config.background.color`.
private extension Color {
    func toHex() -> String? {
        let ns = NSColor(self).usingColorSpace(.sRGB)
        guard let r = ns?.redComponent, let g = ns?.greenComponent, let b = ns?.blueComponent else {
            return nil
        }
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
