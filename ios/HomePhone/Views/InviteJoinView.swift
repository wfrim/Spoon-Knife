import SwiftUI

/// "Join The Burrow": shown by the App Clip, by invite links, and by "I have
/// an invite code" in onboarding. Drawn in the home's own theme.
struct InviteJoinView: View {
    let code: String
    /// Called after joining (the app moves on to the home).
    var onJoined: (() -> Void)?
    /// Shown after joining (the App Clip offers the full app here).
    var afterJoin: (String) -> AnyView = { _ in AnyView(EmptyView()) }

    @State private var preview: InviteLink.Preview?
    @State private var loading = true
    @State private var joining = false
    @State private var joined = false
    @State private var error: String?

    var body: some View {
        let theme = Theme.named(preview?.theme)
        ThemedScreen {
            VStack(alignment: .leading, spacing: 14) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let preview {
                    Text("\(preview.invitedBy ?? "Your roommate") invited you to")
                        .foregroundStyle(theme.muted)
                    HomeNameBadge(name: preview.homeName, size: 44)
                    Text(summary(preview))
                    Spacer()
                    if joined {
                        Text("You're in! 🎉").font(theme.heading(26))
                        afterJoin(preview.homeName)
                    } else if preview.isFull {
                        Text("\(preview.homeName) is full. A home can have up to 8 people.")
                    } else {
                        Button {
                            Task { await join() }
                        } label: {
                            if joining { ProgressView() } else { Text("Join \(preview.homeName)") }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(joining)
                    }
                } else {
                    ThemedTitle(text: "This invite has expired")
                    Text("Invites last 7 days. Ask your roommate for a new one.")
                    Spacer()
                }
                if let error { Text(error).font(.footnote).foregroundStyle(theme.danger) }
            }
            .padding(24)
        }
        .environment(\.theme, theme)
        .task(id: code) { await load() }
    }

    private func summary(_ p: InviteLink.Preview) -> String {
        let people = p.roommates == 1 ? "1 person lives there" : "\(p.roommates) people live there"
        let city = p.city.map { " · \($0)" } ?? ""
        return "\(people)\(city). When you're home, calls to \(p.homeName) ring your phone."
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            preview = try await InviteLink.preview(code)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func join() async {
        joining = true
        defer { joining = false }
        do {
            _ = try await InviteLink.accept(code)
            joined = true
            error = nil
            onJoined?()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
