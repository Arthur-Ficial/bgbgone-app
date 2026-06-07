import Foundation

/// Background choice — maps to bgbgone's `--bg` flag.
enum BackgroundChoice: Sendable, Hashable, Codable {
    case transparent
    case color(hex: String)
    case image(URL)
}

/// Output format — maps to bgbgone's `--format` flag.
enum OutputFormat: String, Sendable, Hashable, CaseIterable, Codable {
    case png, jpg, heic, tiff

    /// CLI argument value (`--format png`, etc.).
    var cliValue: String { rawValue }

    /// File extension to append to the resolved output path.
    var fileExtension: String { rawValue }

    /// Display label as rendered in the design's ConfigPanel radio chips.
    var displayLabel: String {
        switch self {
        case .png: "PNG"
        case .jpg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        }
    }
}

/// Segmentation algorithm — maps to bgbgone's `--type` flag. Values are a subset of
/// the CLI's subject-type vocabulary (see `bgbgone --help`: auto | person | product |
/// car | animal | graphic | transportation | saliency | vn-mask).
enum Algorithm: String, Sendable, Hashable, CaseIterable, Codable {
    case auto      = "auto"
    case vnMask    = "vn-mask"
    case person    = "person"
    case saliency  = "saliency"

    var cliValue: String { rawValue }

    var displayLabel: String {
        switch self {
        case .auto: "Auto"
        case .vnMask: "Vision Mask"
        case .person: "Person"
        case .saliency: "Saliency"
        }
    }

    var helpText: String {
        switch self {
        case .auto: "Let bgbgone pick the best cutout method (default)."
        case .vnMask: "General foreground/subject cutout — best all-rounder."
        case .person: "Tuned for people and portraits."
        case .saliency: "Heuristic: keeps the most visually prominent region."
        }
    }
}

/// User-configurable settings. Owned by `AppViewModel`, persisted via `UserDefaults`.
/// One `Config` applies uniformly to every queued file (per-file overrides land in v0.2).
struct Config: Sendable, Hashable {
    /// Absolute output directory (must exist and be writable).
    var outDirectory: URL

    /// Filename template — supports `{name}`, `{ext}`, `{n}`, `{n:02}`, `{n:NN}` tokens.
    /// Default matches the design: `{name}_bgbgone`.
    var namePattern: String = "{name}_bgbgone"

    var background: BackgroundChoice = .transparent
    var format: OutputFormat = .png
    var algorithm: Algorithm = .auto

    // MARK: - T14 first-class filter controls
    // Each is `Optional<T>` — `nil` means "control is off, emit no recipe". Active
    // recipes are composed into `filterChain` by the computed property below.

    var maskFeather: Double? = nil       // mask:feather=N (px)
    var maskThreshold: Double? = nil     // mask:threshold=V (0…1)
    var maskExpand: Int? = nil           // mask:expand=N (px)
    var maskContract: Int? = nil         // mask:contract=N (px)

    var fgScale: Double? = nil           // fg:scale=F
    var fgTranslateX: Int? = nil         // fg:translate=X,Y
    var fgTranslateY: Int? = nil
    var fgRotate: Double? = nil          // fg:rotate=D (degrees)
    var fgFlip: String? = nil            // fg:flip=horizontal|vertical

    var fgOutlineColor: String? = nil    // fg:outline=color=#hex:width=N
    var fgOutlineWidth: Int? = nil
    var fgShadowBlur: Double? = nil
    var fgShadowOffsetX: Int? = nil
    var fgShadowOffsetY: Int? = nil
    var fgShadowOpacity: Double? = nil
    var fgShadowColor: String? = nil
    var fgGlowColor: String? = nil
    var fgGlowRadius: Double? = nil
    var fgGlowIntensity: Double? = nil

    var bgGrayscale: Bool = false        // bg:grayscale
    var bgBlur: Double? = nil            // bg:blur=R
    var bgDesaturate: Double? = nil      // bg:desaturate=A

    /// Composed filter chain (T14). Walks the active filter fields in left-to-right
    /// order and assembles a `FilterChain`. The DSL string is then emitted via
    /// `BgBgOneCommand.filterChain`.
    var filterChain: FilterChain {
        var recipes: [FilterRecipe] = []
        if let v = maskFeather   { recipes.append(.init(layer: .mask, name: "feather",   args: [.positional(String(Int(v)))])) }
        if let v = maskThreshold { recipes.append(.init(layer: .mask, name: "threshold", args: [.positional(String(format: "%.3f", v))])) }
        if let v = maskExpand    { recipes.append(.init(layer: .mask, name: "expand",    args: [.positional(String(v))])) }
        if let v = maskContract  { recipes.append(.init(layer: .mask, name: "contract",  args: [.positional(String(v))])) }
        if let v = fgScale       { recipes.append(.init(layer: .fg,   name: "scale",     args: [.positional(String(format: "%.2f", v))])) }
        // bgbgone's `translate` takes a single `X,Y` value (comma-separated), NOT two
        // colon-joined positionals — `translate=10:20` is rejected ("value must be X,Y").
        if let dx = fgTranslateX, let dy = fgTranslateY { recipes.append(.init(layer: .fg, name: "translate", args: [.positional("\(dx),\(dy)")])) }
        if let v = fgRotate      { recipes.append(.init(layer: .fg,   name: "rotate",    args: [.positional(String(format: "%.1f", v))])) }
        if let v = fgFlip        { recipes.append(.init(layer: .fg,   name: "flip",      args: [.positional(v)])) }
        if let c = fgOutlineColor, let w = fgOutlineWidth {
            recipes.append(.init(layer: .fg, name: "outline", args: [.keyed("color", c), .keyed("width", String(w))]))
        }
        if let blur = fgShadowBlur, let x = fgShadowOffsetX, let y = fgShadowOffsetY,
           let op = fgShadowOpacity, let c = fgShadowColor {
            recipes.append(.init(layer: .fg, name: "shadow", args: [
                .keyed("blur", String(Int(blur))),
                .keyed("offset", "\(x),\(y)"),
                .keyed("opacity", String(format: "%.2f", op)),
                .keyed("color", c),
            ]))
        }
        if let c = fgGlowColor, let r = fgGlowRadius, let i = fgGlowIntensity {
            recipes.append(.init(layer: .fg, name: "glow", args: [
                .keyed("color", c),
                .keyed("radius", String(Int(r))),
                .keyed("intensity", String(format: "%.2f", i)),
            ]))
        }
        if bgGrayscale           { recipes.append(.init(layer: .bg, name: "grayscale", args: [])) }
        if let v = bgBlur        { recipes.append(.init(layer: .bg, name: "blur",      args: [.positional(String(Int(v)))])) }
        if let v = bgDesaturate  { recipes.append(.init(layer: .bg, name: "desaturate", args: [.positional(String(format: "%.2f", v))])) }
        return FilterChain(recipes: recipes)
    }

    /// T14 — free-form `--filter` text. When non-nil + non-empty, overrides the
    /// composed `filterChain`. AdvancedChainEditor binds to this for power users.
    var advancedFilterText: String? = nil

    /// The string actually emitted to bgbgone — advanced text wins over composed.
    var effectiveFilterString: String {
        if let advancedFilterText, !advancedFilterText.isEmpty { return advancedFilterText }
        return filterChain.dslString
    }

    /// 5 swatches from `design/project/app.jsx:COLOR_PRESETS`. Used by the UI; not part
    /// of the argv computation but lives here so the rest of the app reads one config.
    static let colorPresets: [String] = ["#ffffff", "#000000", "#0066cc", "#f06a3a", "#2da94f"]

    /// Default Pictures-relative folder used on first launch.
    static var defaultOutDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("cutouts", isDirectory: true)
    }
}
