import SwiftUI

/// The colors of the gift and credit screens. Set it once on any ancestor:
/// `.giftTheme(GiftTheme(accent: brandMint, onAccent: brandEvergreen))`.
///
/// `onAccent` is the color of text and icons drawn on top of `accent`. Pick a
/// pair that reads clearly: a light accent needs a dark `onAccent`.
public struct GiftTheme {
    /// Primary buttons, prices and the selected gift.
    public var accent: Color
    /// Text and icons on top of `accent`.
    public var onAccent: Color
    /// The background of cards and rows.
    public var card: Color

    public init(accent: Color = .accentColor, onAccent: Color = .white, card: Color = Color.primary.opacity(0.07)) {
        self.accent = accent
        self.onAccent = onAccent
        self.card = card
    }
}

private struct GiftThemeKey: EnvironmentKey {
    static var defaultValue: GiftTheme { GiftTheme() }
}

extension EnvironmentValues {
    var giftTheme: GiftTheme {
        get { self[GiftThemeKey.self] }
        set { self[GiftThemeKey.self] = newValue }
    }
}

extension View {
    /// Colors for every gift and credit screen below this view, including the
    /// sheets they open.
    public func giftTheme(_ theme: GiftTheme) -> some View {
        environment(\.giftTheme, theme).tint(theme.accent)
    }

    /// Compact native titles leave space for the gifts, including nested sheets.
    @ViewBuilder func giftInlineNavigation() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline).toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder func giftSheet(height: CGFloat = 480) -> some View {
        #if os(iOS)
        self.presentationDetents([.height(height), .large]).presentationDragIndicator(.visible)
        #else
        self
        #endif
    }
}

/// Artwork is the focus. Only the selected tile receives a background and ring.
struct GiftTrayTile<Artwork: View>: View {
    let name: String
    let credits: Int64
    var selected = false
    @ViewBuilder var artwork: Artwork
    @Environment(\.giftTheme) private var theme

    var body: some View {
        VStack(spacing: 5) {
            artwork.frame(height: 62).frame(maxWidth: .infinity)
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
            CreditAmount(amount: credits, font: .system(size: 11, weight: .semibold))
        }
        .padding(.vertical, 9).padding(.horizontal, 4)
        .background(selected ? theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? theme.accent : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct RechargePackTile: View {
    let credits: Int64
    let price: String
    let selected: Bool
    @Environment(\.giftTheme) private var theme
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(theme.accent).font(.title3)
            Text(credits.formatted()).font(.system(size: 27, weight: .bold, design: .rounded))
            Text(price).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
        .background(selected ? theme.accent.opacity(0.12) : theme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? theme.accent : Color.primary.opacity(0.08), lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(credits) credits for \(price)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Buttons

/// The main action of a screen: a wide, filled button.
struct GiftPrimaryButtonStyle: ButtonStyle {
    @Environment(\.giftTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A small filled capsule: a price, or a short action inside a row.
struct GiftPillButtonStyle: ButtonStyle {
    @Environment(\.giftTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(theme.onAccent)
            .padding(.vertical, 9)
            .padding(.horizontal, 16)
            .frame(minWidth: 76)
            .background(theme.accent, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// A secondary action: an outlined capsule in the accent color.
struct GiftOutlineButtonStyle: ButtonStyle {
    @Environment(\.giftTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(theme.accent)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(theme.accent.opacity(configuration.isPressed ? 0.22 : 0.12), in: Capsule())
            .overlay(Capsule().stroke(theme.accent.opacity(0.45), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

// MARK: - Pieces

/// A number of credits with the credit mark: "✦ 20".
struct CreditAmount: View {
    let amount: Int64
    var font: Font = .subheadline.weight(.bold)
    @Environment(\.giftTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
            Text(amount.formatted()).monospacedDigit()
        }
        .font(font)
        .foregroundStyle(theme.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(amount == 1 ? "1 credit" : "\(amount.formatted()) credits")
    }
}

/// One credit pack: how many credits, its name, and Apple's price as the button.
/// A name that only repeats the number ("100 Credits") is left out.
struct CreditPackRow: View {
    let credits: Int64
    let name: String
    let price: String
    var isBuying = false
    let buy: () -> Void
    @Environment(\.giftTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 46, height: 46)
                .background(theme.accent.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(credits.formatted()) credits").font(.headline)
                if Self.nameAddsSomething(name, credits: credits) {
                    Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: buy) {
                if isBuying { ProgressView().tint(theme.onAccent) } else { Text(price) }
            }
            .buttonStyle(GiftPillButtonStyle())
            .accessibilityLabel("Buy \(credits.formatted()) credits for \(price)")
        }
        .padding(14)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// False when the pack's name is just its number of credits again.
    static func nameAddsSomething(_ name: String, credits: Int64) -> Bool {
        let digits = name.filter(\.isNumber)
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && digits != String(credits)
    }
}

/// One gift in a grid: its picture, name and, in the shop, its price. `count`
/// above 1 shows as a "× 3" badge on owned gifts.
struct GiftCard<Artwork: View>: View {
    let name: String
    var price: Int64?
    var count = 1
    var isSelected = false
    @ViewBuilder var artwork: Artwork
    @Environment(\.giftTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            artwork.frame(height: 84)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
            if let price { CreditAmount(amount: price, font: .footnote.weight(.bold)) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(isSelected ? theme.accent.opacity(0.16) : theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(isSelected ? theme.accent : .clear, lineWidth: 2))
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text("× \(count)")
                    .font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(theme.accent, in: Capsule())
                    .padding(8)
                    .accessibilityHidden(true)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(theme.onAccent, theme.accent)
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Who the gift goes to, or a prompt to choose someone.
struct GiftRecipientRow: View {
    let recipient: GiftRecipient?
    var canChange = false
    @Environment(\.giftTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = recipient?.avatarURL {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
                } else { placeholder }
            }
            .frame(width: 42, height: 42).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(recipient == nil ? "Send to" : "To").font(.caption).foregroundStyle(.secondary)
                Text(recipient?.name ?? "Choose a person").font(.headline).lineLimit(1)
            }
            Spacer(minLength: 8)
            if canChange {
                Text(recipient == nil ? "Choose" : "Change").font(.subheadline.weight(.semibold)).foregroundStyle(theme.accent)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "person.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.accent.opacity(0.14))
    }
}

/// A short status line inside the gift screens (a failed purchase, a retry).
struct GiftNotice: View {
    let text: String
    var isError = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.secondary)
            Text(text).font(.footnote).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
