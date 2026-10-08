import CoreLocation
import SwiftUI

/// What onboarding has collected so far.
@MainActor
final class OnboardingDraft: ObservableObject {
    @Published var yourName = ""
    @Published var homeName = ""
    @Published var statusLine = ""
    @Published var themeKey = Theme.defaultKey
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var address = ""
    @Published var city = ""
    @Published var radius: Double = 200
    @Published var roommates = 2
    @Published var createdHome: Home?

    var theme: Theme { Theme.named(themeKey) }
}

enum OnboardingStep: Hashable {
    case aboutYou, choosePath, joinCode, nameHome, pickStyle, homeArea, location, roommates, invite
}

/// Welcome → About you → Create or join → (create) Name → Style → Home area →
/// Location → Roommates → Invite → your home. Everything after the style step
/// wears the style you picked.
struct OnboardingFlow: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var draft = OnboardingDraft()
    @State private var path: [OnboardingStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStep { path.append(.aboutYou) } haveInvite: { path.append(.joinCode) }
                .navigationDestination(for: OnboardingStep.self) { step in
                    destination(step)
                }
        }
        .environmentObject(draft)
    }

    @ViewBuilder
    private func destination(_ step: OnboardingStep) -> some View {
        switch step {
        case .aboutYou:
            AboutYouStep { path.append(.choosePath) }
        case .choosePath:
            ChoosePathStep(create: { path.append(.nameHome) }, join: { path.append(.joinCode) })
        case .joinCode:
            JoinCodeStep { Task { await app.refresh() } }
        case .nameHome:
            NameHomeStep { path.append(.pickStyle) }
        case .pickStyle:
            PickStyleStep { path.append(.homeArea) }
        case .homeArea:
            HomeAreaStep { path.append(.location) }.environment(\.theme, draft.theme)
        case .location:
            LocationStep { path.append(.roommates) }.environment(\.theme, draft.theme)
        case .roommates:
            RoommatesStep { path.append(.invite) }.environment(\.theme, draft.theme)
        case .invite:
            InviteStep { Task { await app.refresh() } }.environment(\.theme, draft.theme)
        }
    }
}
