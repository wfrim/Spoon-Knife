import SwiftUI

/// Your home: who lives here and who's home, ring the house, invite people,
/// change the style. The full five-tab app comes next; the Phase 0 test tools
/// live behind the wrench.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var calls: CallManager
    let home: Home

    @State private var roommates: [Roommate] = []
    @State private var invite: (code: String, url: URL)?
    @State private var showingStyle = false
    @State private var showingTools = false
    @State private var error: String?

    var body: some View {
        let theme = Theme.named(home.theme)
        ThemedScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Button { showingStyle = true } label: { Image(systemName: "paintpalette") }
                            .buttonStyle(PillButtonStyle())
                            .accessibilityLabel("Change style")
                        Button { showingTools = true } label: { Image(systemName: "wrench.adjustable") }
                            .buttonStyle(PillButtonStyle())
                            .accessibilityLabel("Test tools")
                    }
                    HomeNameBadge(name: home.name, size: 42)
                    Text([home.city, "@\(home.handle)"].compactMap { $0 }.joined(separator: " · "))
                        .font(theme.body(16, weight: .semibold)).foregroundStyle(theme.muted)
                    if let status = home.statusLine, !status.isEmpty {
                        Text(status)
                    }
                    roommatesCard
                    callCard
                    inviteCard
                    if let error { Text(error).font(.footnote).foregroundStyle(theme.danger) }
                }
                .padding(20)
            }
            .refreshable { await load() }
        }
        .environment(\.theme, theme)
        .task(id: home.id) { await load() }
        .sheet(isPresented: $showingStyle) {
            StyleSheet(home: home)
        }
        .sheet(isPresented: $showingTools) {
            PresenceSpikeView()
                .environmentObject(PresenceStore.shared)
                .environmentObject(calls)
        }
    }

    private var homeCount: Int { roommates.filter { $0.presence == .home }.count }

    private var roommatesCard: some View {
        let theme = Theme.named(home.theme)
        return VStack(alignment: .leading, spacing: 12) {
            Text(homeCount == 0 ? "Nobody’s home" : "\(homeCount) home right now")
                .font(theme.heading(24))
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(roommates.enumerated()), id: \.element.id) { i, r in
                    VStack(spacing: 4) {
                        Avatar(name: r.displayName.isEmpty ? "?" : r.displayName, index: i, size: 54)
                            .overlay(alignment: .topTrailing) {
                                if r.isKeyholder {
                                    Image(systemName: "key.fill").font(.system(size: 11, weight: .bold))
                                        .padding(5).background(theme.accent, in: Circle()).foregroundStyle(theme.onAccent)
                                        .offset(x: 6, y: -6).accessibilityLabel("Keyholder")
                                }
                            }
                        Text(r.displayName.isEmpty ? "Roommate" : r.displayName).font(theme.body(14, weight: .bold))
                        // Only "home" is ever shown; away and unknown look the same.
                        if r.presence == .home {
                            Text("home").font(theme.body(12, weight: .heavy))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(theme.call, in: Capsule()).foregroundStyle(theme.onCall)
                        }
                    }
                }
            }
        }
        .themedCard()
    }

    private var callCard: some View {
        let theme = Theme.named(home.theme)
        return VStack(alignment: .leading, spacing: 10) {
            Button(calls.isBusy ? "On a call…" : "Ring the house") { calls.call(home: home.id, named: home.name) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(calls.isBusy)
            Text("Rings everyone else who’s home. Friends call \(home.name) the same way.")
                .font(theme.body(14)).foregroundStyle(theme.muted)
        }
    }

    private var inviteCard: some View {
        let theme = Theme.named(home.theme)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Invite roommates").font(theme.body(17, weight: .bold))
            if let invite {
                Text(invite.code).font(.system(size: 22, weight: .bold, design: .monospaced)).textSelection(.enabled)
                ShareLink(item: invite.url, subject: Text("Join \(home.name)"),
                          message: Text("Join \(home.name) on Home Phone so it rings you when you’re home.")) {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PillButtonStyle(selected: true))
            } else {
                Button("Make an invite link") { Task { await makeInvite() } }
                    .buttonStyle(PillButtonStyle(selected: true))
            }
        }
        .themedCard()
    }

    private func load() async {
        do {
            roommates = try await HomeService.roster(home.id)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func makeInvite() async {
        do { invite = try await HomeService.inviteLink(home.id) } catch { self.error = error.localizedDescription }
    }
}

/// Change the home's style; everyone who lives here sees it.
private struct StyleSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let home: Home
    @State private var key: String

    init(home: Home) {
        self.home = home
        _key = State(initialValue: home.theme)
    }

    var body: some View {
        OnboardingPage(
            title: "\(home.name)’s style",
            subtitle: "Everyone who lives here sees the change.",
            primary: "Use this style",
            action: {
                Task { await app.setTheme(key) }
                dismiss()
            }
        ) {
            StylePicker(themeKey: $key, homeName: home.name)
        }
        .environment(\.theme, Theme.named(key))
    }
}
