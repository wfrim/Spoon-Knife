import SwiftUI

/// Onboarding until you live somewhere, then your home.
struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            switch app.phase {
            case .loading:
                ZStack {
                    Theme.house.background.ignoresSafeArea()
                    ProgressView()
                }
            case .onboarding:
                OnboardingFlow()
            case .home(let home):
                HomeView(home: home)
            case .failed(let message):
                VStack(spacing: 14) {
                    Text("Couldn’t reach Home Phone").font(.title2.bold())
                    Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try again") { Task { await app.refresh() } }.buttonStyle(.borderedProminent)
                }
                .padding(24)
            }
        }
        .task { await app.refresh() }
    }
}
