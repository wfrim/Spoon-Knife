import SwiftUI

/// The page every themed screen sits on.
struct ThemedScreen<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            content
                .foregroundStyle(theme.text)
                .font(theme.body())
        }
        .animation(.easeInOut(duration: 0.3), value: theme.key)
    }
}

/// Big, full-width primary button in the theme's shape (always in the same spot: the bottom).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
        return configuration.label
            .font(theme.body(18, weight: .bold))
            .foregroundStyle(theme.buttonText)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(theme.buttonBackground, in: shape)
            .overlay { if let border = theme.buttonBorder { shape.stroke(border, lineWidth: 2.5) } }
            .background {
                if let shadow = theme.buttonShadow {
                    shape.fill(shadow).offset(y: pressed ? 1 : 4)
                }
            }
            .offset(y: pressed && theme.buttonShadow != nil ? 3 : 0)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Smaller pill for secondary actions.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        return configuration.label
            .font(theme.body(15, weight: .bold))
            .foregroundStyle(selected ? theme.onAccent : theme.cardText)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(selected ? theme.accent : theme.cardBackground, in: shape)
            .overlay(shape.stroke(theme.isSimple && !selected ? theme.cardBorder : (theme.isSimple ? .clear : theme.cardBorder),
                                  lineWidth: theme.isSticker ? 2 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A white card with the theme's border, radius and (Sticker) hard shadow.
struct ThemedCard: ViewModifier {
    @Environment(\.theme) private var theme
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(theme.cardText)
            .background(theme.cardBackground, in: shape)
            .overlay(shape.stroke(theme.cardBorder, lineWidth: theme.cardBorderWidth))
            .background { if let shadow = theme.cardShadow { shape.fill(shadow).offset(y: 4) } }
    }
}

extension View {
    func themedCard(padding: CGFloat = 16) -> some View { modifier(ThemedCard(padding: padding)) }
}

/// A screen title in the theme's heading face.
struct ThemedTitle: View {
    @Environment(\.theme) private var theme
    let text: String
    var size: CGFloat = 32

    var body: some View {
        Text(text)
            .font(theme.heading(size))
            .tracking(theme.isSimple ? -0.5 : 0)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The home's name, presented the way each style does it: an accent block
/// (Simple), a tilted sticker (Sticker), or wood-colored italic (Rotary).
struct HomeNameBadge: View {
    @Environment(\.theme) private var theme
    let name: String
    var size: CGFloat = 40

    var body: some View {
        switch theme.family {
        case .simple:
            Text(name)
                .font(theme.heading(size))
                .foregroundStyle(theme.accent)
        case .sticker:
            Text(name)
                .font(theme.heading(size))
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 4)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.cardBorder, lineWidth: 2.5))
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.cardBorder).offset(y: 5))
                .rotationEffect(.degrees(theme.tilt))
                .padding(.vertical, 6)
        case .rotary:
            Text(name)
                .font(theme.heading(size))
                .foregroundStyle(theme.strong)
        }
    }
}

/// A roommate's initial in a colored circle.
struct Avatar: View {
    @Environment(\.theme) private var theme
    let name: String
    let index: Int
    var size: CGFloat = 48

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(theme.body(size * 0.4, weight: .heavy))
            .foregroundStyle(theme.onTone)
            .frame(width: size, height: size)
            .background(theme.tone(index), in: Circle())
            .overlay(Circle().stroke(theme.isSimple ? .clear : theme.cardBorder, lineWidth: theme.isSticker ? 2.5 : 1.5))
            .rotationEffect(.degrees(theme.isSticker ? [-6, 4, -2, 5][index % 4] : 0))
            .accessibilityHidden(true)
    }
}
