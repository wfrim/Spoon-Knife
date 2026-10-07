import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// "Join The Burrow": shown by the App Clip and by the app when an invite link
/// opens it. Drawn in the home's own theme.
struct InviteJoinView: View {
    let code: String
    /// Shown after joining (the App Clip offers the full app here).
    var afterJoin: (String) -> AnyView = { _ in AnyView(EmptyView()) }

    @State private var preview: InviteLink.Preview?
    @State private var loading = true
    @State private var joined = false
    @State private var error: String?

    var body: some View {
        let theme = InviteTheme.named(preview?.theme ?? "simple-cobalt")
        let design: Font.Design = theme.rounded ? .rounded : theme.serif ? .serif : .default
        ZStack {
            Color(hex: theme.background).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let preview {
                    Text("\(preview.invitedBy ?? "Your roommate") invited you to")
                        .font(.system(.title3, design: design)).opacity(0.8)
                    Text(preview.homeName)
                        .font(.system(size: 44, weight: .heavy, design: design))
                        .italic(theme.serif)
                    Text(summary(preview))
                        .font(.system(.body, design: design))
                    Spacer()
                    if joined {
                        Text("You're in! 🎉").font(.system(.title2, design: design).bold())
                        afterJoin(preview.homeName)
                    } else if preview.isFull {
                        Text("\(preview.homeName) is full. A home can have up to 8 people.")
                    } else {
                        Button {
                            Task { await join() }
                        } label: {
                            Text("Join \(preview.homeName)")
                                .font(.system(.title3, design: design).bold())
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(Color(hex: theme.accent), in: RoundedRectangle(cornerRadius: theme.rounded ? 28 : 16))
                                .foregroundStyle(Color(hex: theme.onAccent))
                        }
                    }
                } else {
                    Text("This invite has expired").font(.title.bold())
                    Text("Invites last 7 days. Ask your roommate for a new one.")
                    Spacer()
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .foregroundStyle(Color(hex: theme.ink))
            .padding(24)
        }
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
        do {
            _ = try await InviteLink.accept(code)
            joined = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
