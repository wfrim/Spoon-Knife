import SwiftUI

/// Phase 0 test harness: set home, watch what the server believes, override it,
/// and log ground-truth spot checks for the gate report.
struct PresenceSpikeView: View {
    @EnvironmentObject private var store: PresenceStore
    @StateObject private var permission = LocationPermission()
    @AppStorage("tester.name") private var testerName = ""
    @State private var showingHomeSetup = false
    @State private var checkNote = ""
    @State private var checkLogged: Date?

    var body: some View {
        NavigationStack {
            List {
                statusSection
                spotCheckSection
                overrideSection
                setupSection
                historySection
            }
            .navigationTitle("Apartment Line")
            .refreshable { await store.heartbeat() }
            .sheet(isPresented: $showingHomeSetup) {
                HomeSetupView(initial: store.home) { home in
                    Task { await store.setHome(home) }
                }
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Circle()
                    .fill(color(for: store.serverState))
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: store.serverState)).font(.title2.bold())
                    if let at = store.serverUpdatedAt {
                        Text("\(store.serverSource?.rawValue.capitalized ?? "—") · \(at, style: .relative) ago")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Nothing reported yet").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            if store.pendingCount > 0 {
                Label("\(store.pendingCount) report(s) waiting to send", systemImage: "arrow.up.circle")
                    .foregroundStyle(.orange)
            }
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("What the server thinks")
        }
    }

    private var spotCheckSection: some View {
        Section {
            TextField("Where are you? (optional, e.g. café downstairs)", text: $checkNote)
            HStack {
                Button("I'm home") { logCheck(.home) }
                    .buttonStyle(.borderedProminent).tint(.green)
                Spacer()
                Button("I'm away") { logCheck(.away) }
                    .buttonStyle(.borderedProminent).tint(.gray)
            }
            if let checkLogged {
                Text("Logged \(checkLogged, style: .time)").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Spot check")
        } footer: {
            Text("Tap whenever you think of it, a few times a day, especially just after arriving or leaving and in spots near home. This is the ground truth for the Phase 0 gate.")
        }
    }

    private var overrideSection: some View {
        Section {
            HStack {
                Button("Set Home") { store.setManual(.home) }
                Spacer()
                Button("Set Away") { store.setManual(.away) }
            }
        } header: {
            Text("Manual override")
        } footer: {
            Text("Holds until the next geofence crossing.")
        }
    }

    private var setupSection: some View {
        Section("Setup") {
            Button {
                permission.request()
            } label: {
                LabeledContent("Location", value: permission.summary)
            }
            .tint(permission.isAlways ? Color.primary : Color.accentColor)

            Button {
                showingHomeSetup = true
            } label: {
                LabeledContent("Home", value: store.home.map { "\(Int($0.radius)) m circle" } ?? "Not set")
            }

            TextField("Your name (for the test report)", text: $testerName)
                .onSubmit { Task { await store.setTesterName(testerName) } }
        }
    }

    private var historySection: some View {
        Section("Sent reports") {
            if store.history.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            }
            ForEach(store.history.prefix(50)) { report in
                HStack {
                    Circle().fill(color(for: report.state)).frame(width: 8, height: 8)
                    Text(label(for: report.state))
                    Text(report.source.rawValue).foregroundStyle(.secondary)
                    Spacer()
                    Text(report.reportedAt, format: .dateTime.weekday().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: Helpers

    private func logCheck(_ actual: PresenceState) {
        let note = checkNote
        Task {
            await store.recordCheck(actual: actual, note: note)
            if store.lastError == nil {
                checkLogged = Date()
                checkNote = ""
            }
        }
    }

    /// "Near home", not "home": the geofence can't see walls (plan B3).
    private func label(for state: PresenceState) -> String {
        switch state {
        case .home: return "Near home"
        case .away: return "Away"
        case .unknown: return "Unknown"
        }
    }

    private func color(for state: PresenceState) -> Color {
        switch state {
        case .home: return .green
        case .away: return .gray
        case .unknown: return .yellow
        }
    }
}
