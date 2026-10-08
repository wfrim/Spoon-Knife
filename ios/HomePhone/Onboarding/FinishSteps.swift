import SwiftUI

struct LocationStep: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var draft: OnboardingDraft
    @StateObject private var permission = LocationPermission()
    let next: () -> Void

    var body: some View {
        OnboardingPage(
            step: "Step 4 of 6",
            title: permission.isAlways ? "You’re all set" : "This is how your home rings you",
            subtitle: permission.isAlways
                ? "When you’re home, calls to \(draft.homeName) will ring your phone."
                : "Home Phone needs to know when you’re home, even when the app is closed. That’s the whole trick.",
            primary: permission.isAlways ? "Next: your roommates" : "Turn on location",
            secondary: notNow,
            action: { permission.isAlways ? next() : permission.request() }
        ) {
            if !permission.isAlways {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Choose **Always** when your iPhone asks", systemImage: "checkmark.circle.fill")
                    Label("Roommates only ever see “home”, never where you are", systemImage: "checkmark.circle.fill")
                    Label("You can hide even that, and still get rung", systemImage: "checkmark.circle.fill")
                }
                .font(theme.body(15))
                .themedCard()
            }
        }
        .task {
            // The home exists by now: start watching its circle.
            // (Runs again harmlessly if the user comes back to this step.)
            if let home = draft.createdHome { await PresenceStore.shared.setHome(home.location) }
        }
    }
}

private extension LocationStep {
    /// Skipping is allowed; the app keeps reminding you until location is on.
    var notNow: (title: String, action: () -> Void)? {
        permission.isAlways ? nil : (title: "Not now", action: next)
    }
}

struct RoommatesStep: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var draft: OnboardingDraft
    let next: () -> Void

    var body: some View {
        OnboardingPage(
            step: "Step 5 of 6",
            title: "How many roommates do you have?",
            subtitle: "Not counting you. Up to 8 people can share one home line.",
            primary: draft.roommates == 1 ? "Next: invite them" : draft.roommates == 2 ? "Next: invite both" : "Next: invite all \(draft.roommates)",
            action: next
        ) {
            HStack(spacing: 24) {
                Spacer()
                Button { draft.roommates = max(1, draft.roommates - 1) } label: { Image(systemName: "minus") }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel("Fewer roommates")
                Text("\(draft.roommates)").font(theme.heading(64)).monospacedDigit()
                    .accessibilityLabel("\(draft.roommates) roommates")
                Button { draft.roommates = min(7, draft.roommates + 1) } label: { Image(systemName: "plus") }
                    .buttonStyle(PillButtonStyle(selected: true))
                    .accessibilityLabel("More roommates")
                Spacer()
            }
            .padding(.vertical, 20)
            HStack(spacing: 10) {
                Avatar(name: draft.yourName.isEmpty ? "You" : draft.yourName, index: 0)
                ForEach(0..<draft.roommates, id: \.self) { _ in
                    Circle().strokeBorder(theme.muted, style: StrokeStyle(lineWidth: 2.5, dash: [5, 4]))
                        .frame(width: 48, height: 48)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct InviteStep: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var draft: OnboardingDraft
    @State private var link: (code: String, url: URL)?
    @State private var error: String?
    let done: () -> Void

    var body: some View {
        OnboardingPage(
            step: "Step 6 of 6",
            title: "Invite your roommates",
            subtitle: "Send them this link. It opens Home Phone (or an App Clip) and they join \(draft.homeName).",
            primary: "Go to \(draft.homeName)",
            note: "You can invite more people any time.",
            action: done
        ) {
            if let link {
                VStack(alignment: .leading, spacing: 10) {
                    Text("INVITE CODE").font(theme.body(12, weight: .bold)).foregroundStyle(theme.cardMuted)
                    Text(link.code).font(.system(size: 26, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    ShareLink(item: link.url, subject: Text("Join \(draft.homeName)"),
                              message: Text("Join \(draft.homeName) on Home Phone so it rings you when you’re home.")) {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PillButtonStyle(selected: true))
                }
                .themedCard()
                Text("Waiting for \(draft.roommates == 1 ? "your roommate" : "\(draft.roommates) roommates") to join.")
                    .font(theme.body(14)).foregroundStyle(theme.muted)
            } else if let error {
                Text(error).foregroundStyle(theme.danger)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task {
            guard link == nil, let home = draft.createdHome else { return }
            do { link = try await HomeService.inviteLink(home.id) } catch { self.error = error.localizedDescription }
        }
    }
}
