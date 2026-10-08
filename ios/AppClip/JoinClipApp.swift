import StoreKit
import SwiftUI

/// The App Clip: tap an invite link, join the home, then get the full app
/// (which is what lets the home ring you: location + VoIP need the full app).
@main
struct JoinClipApp: App {
    @State private var code: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let code {
                    InviteJoinView(code: code, afterJoin: { home in
                        AnyView(GetFullApp(homeName: home))
                    })
                } else {
                    Text("Open an invite link to join a home.")
                        .padding()
                }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                code = InviteLink.code(from: activity.webpageURL)
            }
        }
    }
}

private struct GetFullApp: View {
    let homeName: String
    @State private var showOverlay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Get Home Phone so \(homeName) can ring you when you're home.")
            Button("Get the app") { showOverlay = true }
                .buttonStyle(.borderedProminent)
        }
        .appStoreOverlay(isPresented: $showOverlay) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
        .onAppear { showOverlay = true }
    }
}
