import SwiftUI

// MARK: - Before you have a home (house "Pop" style)

struct WelcomeStep: View {
    let next: () -> Void
    let haveInvite: () -> Void

    var body: some View {
        ZStack {
            Color(hex: 0x3B5BFD).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "house.and.flag.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color(hex: 0x14172B))
                    .frame(width: 76, height: 76)
                    .background(Color(hex: 0xFFD43B), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .rotationEffect(.degrees(-6))
                    .padding(.top, 40)
                Text("One line for you and your roommates.")
                    .font(.system(size: 46, weight: .heavy))
                    .tracking(-1)
                Text("Friends call your home by name. It rings whoever’s there.")
                    .font(.system(size: 19))
                    .foregroundStyle(Color(hex: 0xE3E8FF))
                Spacer()
                Button("Get started", action: next)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(hex: 0x14172B))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color(hex: 0xFFD43B), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Button("I have an invite code", action: haveInvite)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct AboutYouStep: View {
    @EnvironmentObject private var draft: OnboardingDraft
    @State private var saving = false
    @State private var error: String?
    let next: () -> Void

    var body: some View {
        OnboardingPage(
            title: "What should your roommates call you?",
            subtitle: "It’s what people see when you call.",
            primary: "Next",
            primaryEnabled: !draft.yourName.trimmingCharacters(in: .whitespaces).isEmpty,
            busy: saving,
            action: save
        ) {
            ThemedField(label: "Your first name", text: $draft.yourName, placeholder: "Maya")
                .textContentType(.givenName)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await HomeService.setDisplayName(draft.yourName.trimmingCharacters(in: .whitespaces))
                next()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ChoosePathStep: View {
    @Environment(\.theme) private var theme
    let create: () -> Void
    let join: () -> Void

    var body: some View {
        OnboardingPage(
            title: "Got a home line yet?",
            subtitle: "Each home has one line that rings whoever’s there.",
            primary: "Create a home",
            secondary: (title: "I have an invite code", action: join),
            action: create
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Label("You’re the first one here", systemImage: "sparkles").font(theme.body(17, weight: .bold))
                Text("Name your place, pick its style, then invite your roommates.").foregroundStyle(theme.cardMuted)
            }
            .themedCard()
            VStack(alignment: .leading, spacing: 8) {
                Label("A roommate already set it up", systemImage: "key.fill").font(theme.body(17, weight: .bold))
                Text("Use the code or link they sent you.").foregroundStyle(theme.cardMuted)
            }
            .themedCard()
        }
    }
}

struct JoinCodeStep: View {
    @State private var code = ""
    @State private var showing: PendingInvite?
    let joined: () -> Void

    var body: some View {
        OnboardingPage(
            title: "Join your home",
            subtitle: "Paste the invite link or type the code your roommate sent.",
            primary: "Continue",
            primaryEnabled: InviteCodeInput.code(from: code) != nil,
            action: { if let c = InviteCodeInput.code(from: code) { showing = PendingInvite(id: c) } }
        ) {
            ThemedField(label: "Invite code or link", text: $code, placeholder: "homephone.app/j/…")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .sheet(item: $showing) { invite in
            InviteJoinView(code: invite.id, onJoined: joined)
        }
    }
}

enum InviteCodeInput {
    /// Accepts a bare code or a full invite link.
    static func code(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let code = InviteLink.code(from: url) { return code }
        let candidate = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return candidate.range(of: "^[A-Za-z0-9]{6,32}$", options: .regularExpression) != nil ? candidate : nil
    }
}

struct NameHomeStep: View {
    @EnvironmentObject private var draft: OnboardingDraft
    let next: () -> Void

    var body: some View {
        OnboardingPage(
            step: "Step 1 of 6",
            title: "Give your place a name",
            subtitle: "Friends search for it, and it’s what shows up when your home is called.",
            primary: "Next: pick a style",
            primaryEnabled: draft.homeName.trimmingCharacters(in: .whitespaces).count >= 2,
            action: next
        ) {
            ThemedField(label: "Home name", text: $draft.homeName, placeholder: "The Burrow")
            if !draft.homeName.isEmpty {
                Text("@\(HomeService.handle(for: draft.homeName))").font(.subheadline).foregroundStyle(.secondary)
            }
            ThemedField(label: "Status line (optional)", text: $draft.statusLine, placeholder: "Plants watered. Door’s always open.")
        }
    }
}
