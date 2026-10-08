import SwiftUI

/// Layout shared by every onboarding step: title and body at the top, content,
/// and the primary button pinned to the same spot at the bottom.
struct OnboardingPage<Content: View>: View {
    @Environment(\.theme) private var theme
    var step: String?
    let title: String
    var subtitle: String?
    var primary: String
    var primaryEnabled = true
    var busy = false
    var note: String?
    var secondary: (title: String, action: () -> Void)?
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ThemedScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let step {
                        Text(step).font(theme.body(14, weight: .semibold)).foregroundStyle(theme.muted)
                    }
                    ThemedTitle(text: title)
                    if let subtitle {
                        Text(subtitle).foregroundStyle(theme.muted)
                    }
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(action: action) {
                        if busy { ProgressView().tint(theme.buttonText) } else { Text(primary) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!primaryEnabled || busy)
                    Group {
                        if let secondary {
                            Button(secondary.title, action: secondary.action)
                                .font(theme.body(16, weight: .semibold))
                                .foregroundStyle(theme.text)
                        } else if let note {
                            Text(note).font(theme.body(14)).foregroundStyle(theme.muted).multilineTextAlignment(.center)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(height: 44)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .background(theme.background)
            }
        }
        .tint(theme.text)
    }
}

/// A labeled text field in the theme.
struct ThemedField: View {
    @Environment(\.theme) private var theme
    let label: String
    @Binding var text: String
    var placeholder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(theme.body(13, weight: .bold)).foregroundStyle(theme.muted)
            TextField(placeholder, text: $text)
                .font(theme.body(19, weight: .semibold))
                .foregroundStyle(Color(hex: 0x14172B))
                .padding(.horizontal, 14)
                .frame(minHeight: 54)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.isSimple ? Color(hex: 0xD5D8E1) : theme.cardBorder, lineWidth: theme.isSticker ? 2.5 : 1))
        }
    }
}
