import SwiftUI
import IRCore

/// The handful of shapes the interface is built from.
///
/// One file rather than ad-hoc padding in each view, because the thing that
/// makes an application feel considered is not any single screen — it is that
/// the same idea looks the same everywhere. A status reads identically in the
/// source list and in the run history; a supplier is the same tile in the
/// catalogue and in the sheet that adds it.
enum Layout {
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let gutter: CGFloat = 16
}

// MARK: - Supplier tile

/// A supplier's logo, or a monogram when there is none.
///
/// The fallback is not an apology: a coloured tile with the supplier's initials
/// is recognisable at a glance and, unlike a generic grey square, tells the
/// user which row they are looking at. The colour is derived from the plugin's
/// identifier, so a given supplier is always the same colour — including
/// between machines, which a random colour would not be.
struct SupplierTile: View {
    @Environment(LogoStore.self) private var logos

    let manifest: PluginManifest?
    /// Used when no manifest is installed for a source yet.
    var fallbackName: String = ""
    var size: CGFloat = 40

    private var name: String { manifest?.name ?? fallbackName }
    private var seed: String { manifest?.id ?? fallbackName }

    private var monogram: String {
        if let manifest { return manifest.monogram }
        let letters = fallbackName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        Group {
            if let image = logos.image(for: manifest?.logoDomain) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.08)
            } else {
                ZStack {
                    LinearGradient(colors: Self.colours(for: seed),
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(monogram)
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .accessibilityLabel(name)
    }

    /// A stable pair of hues from a stable hash. `hashValue` is deliberately
    /// avoided: Swift seeds it per process, so the same supplier would change
    /// colour on every launch.
    static func colours(for seed: String) -> [Color] {
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360
        return [Color(hue: hue, saturation: 0.55, brightness: 0.78),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
                      saturation: 0.68, brightness: 0.58)]
    }
}

// MARK: - Cards

/// The container everything sits in. A hairline rather than a shadow: stacked
/// shadows on a list of twenty rows turn into grey mud.
struct CardBackground: ViewModifier {
    var padding: CGFloat = Layout.cardPadding
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Layout.cardRadius,
                                                                   style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.5)
                                              : Color(nsColor: .separatorColor).opacity(0.7),
                                  lineWidth: highlighted ? 1.5 : 0.5)
            }
    }
}

extension View {
    func card(padding: CGFloat = Layout.cardPadding, highlighted: Bool = false) -> some View {
        modifier(CardBackground(padding: padding, highlighted: highlighted))
    }
}

// MARK: - Status

/// What a source is doing, in words a person who has never read the manual can
/// act on. The tone matters more than the wording: "Ready" and "Needs you" are
/// states someone can respond to, where "idle" and "auth_required" are not.
enum SourceHealth {
    case ready, working, attention, problem, off

    var colour: Color {
        switch self {
        case .ready: return .green
        case .working: return .accentColor
        case .attention: return .orange
        case .problem: return .red
        case .off: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .working: return "arrow.triangle.2.circlepath"
        case .attention: return "exclamationmark.circle.fill"
        case .problem: return "xmark.circle.fill"
        case .off: return "pause.circle.fill"
        }
    }

    static func of(_ source: Source, isRunning: Bool) -> SourceHealth {
        if isRunning { return .working }
        if !source.isEnabled { return .off }
        if source.lastRunStatus == .needsSignIn { return .attention }
        if source.needsAttention { return .problem }
        return .ready
    }
}

/// A small coloured label. Used for status and for the catalogue's badges, so
/// that "needs attention" looks the same wherever it appears.
struct Pill: View {
    let text: String
    var colour: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.caption2)
            }
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(colour.opacity(0.13), in: Capsule())
    }
}

// MARK: - Page furniture

/// A screen's title, its one-line explanation, and its primary action.
///
/// The explanation is not decoration. Someone opening "Sources" for the first
/// time does not know what the application means by the word, and a sentence
/// costs a line where a support question costs an afternoon.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Layout.gutter)
            HStack(spacing: 8) { actions }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

/// The first thing a new user sees on an empty screen, and therefore the most
/// important text in the application: it has to say what this is for and give
/// exactly one thing to do next.
struct FirstStep: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor.gradient)
            Text(title).font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
