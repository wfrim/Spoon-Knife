import MapKit
import SwiftUI

// MARK: - Pick a style: the whole screen re-skins as you browse

struct StylePicker: View {
    @Binding var themeKey: String
    var homeName: String

    var body: some View {
        let theme = Theme.named(themeKey)
        VStack(alignment: .leading, spacing: 16) {
            // Preview: your home, drawn in the style.
            VStack(alignment: .leading, spacing: 14) {
                HomeNameBadge(name: homeName.isEmpty ? "Your home" : homeName, size: 34)
                HStack(spacing: -8) {
                    ForEach(Array(["H", "W", "R"].enumerated()), id: \.offset) { i, n in
                        Avatar(name: n, index: i, size: 44)
                    }
                }
                Text("2 home right now").font(theme.body(17, weight: .bold))
            }
            .themedCard(padding: 18)

            Picker("Style", selection: Binding(
                get: { theme.family },
                set: { family in themeKey = "\(family.rawValue)-\(Theme.schemes(for: family)[0].key)" }
            )) {
                ForEach(Theme.Family.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Colors").font(theme.body(15, weight: .bold))
                Spacer()
                Text(theme.schemeName).font(theme.body(15)).foregroundStyle(theme.muted)
            }
            HStack(spacing: 12) {
                ForEach(Theme.schemes(for: theme.family)) { scheme in
                    let key = "\(theme.family.rawValue)-\(scheme.key)"
                    Button { themeKey = key } label: {
                        HStack(spacing: 0) {
                            Color(hex: scheme.swatch.0)
                            Color(hex: scheme.swatch.1)
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                        .padding(4)
                        .overlay(Circle().stroke(key == themeKey ? theme.strong : .clear, lineWidth: 3))
                    }
                    .accessibilityLabel(scheme.name)
                    .accessibilityAddTraits(key == themeKey ? .isSelected : [])
                }
            }
        }
    }
}

struct PickStyleStep: View {
    @EnvironmentObject private var draft: OnboardingDraft
    let next: () -> Void

    var body: some View {
        OnboardingPage(
            step: "Step 2 of 6",
            title: "Pick \(draft.homeName.isEmpty ? "your home" : draft.homeName)’s style",
            subtitle: "Your whole app wears it, and so does your home when friends open it.",
            primary: "Use this style",
            note: "Any roommate can change this later.",
            action: next
        ) {
            StylePicker(themeKey: $draft.themeKey, homeName: draft.homeName)
        }
        .environment(\.theme, draft.theme)
    }
}

// MARK: - Home area: address search, use my location, radius, city

/// Apple's address autocomplete (MKLocalSearchCompleter), then MKLocalSearch to
/// turn a suggestion into a coordinate and city. No API key needed.
@MainActor
final class AddressSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" { didSet { completer.queryFragment = query } }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = .address
        completer.delegate = self
    }

    func bias(to coordinate: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
    }

    func clear() { suggestions = [] }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = Array(results.prefix(4)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }

    /// The picked suggestion's coordinate, a one-line address and its city.
    func resolve(_ completion: MKLocalSearchCompletion) async -> (CLLocationCoordinate2D, String, String?)? {
        guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first
        else { return nil }
        let line = [completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        return (item.placemark.coordinate, line, item.placemark.locality)
    }
}

struct HomeAreaStep: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var draft: OnboardingDraft
    @StateObject private var search = AddressSearch()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var locating = false
    @State private var creating = false
    @State private var error: String?
    let next: () -> Void

    var body: some View {
        OnboardingPage(
            step: "Step 3 of 6",
            title: "Where can \(draft.homeName) ring you?",
            subtitle: "Inside this circle, calls to \(draft.homeName) ring your phone. Outside it, they don’t.",
            primary: "This is home",
            primaryEnabled: draft.coordinate != nil,
            busy: creating,
            note: "Only the city is shown. Your address never is.",
            action: create
        ) {
            searchField
            if !search.suggestions.isEmpty { suggestionList }
            map
            radius
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CITY ON YOUR HOME’S PROFILE").font(theme.body(12, weight: .bold)).foregroundStyle(theme.cardMuted)
                    TextField("City", text: $draft.city).font(theme.body(17, weight: .bold))
                }
            }
            .themedCard(padding: 12)
            if let error { Text(error).font(.footnote).foregroundStyle(theme.danger) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color(hex: 0x5B6075))
            TextField("Search your address", text: $search.query)
                .textContentType(.fullStreetAddress)
                .foregroundStyle(Color(hex: 0x14172B))
            Button { useMyLocation() } label: {
                if locating { ProgressView() } else { Image(systemName: "location.fill") }
            }
            .accessibilityLabel("Use my location")
            .foregroundStyle(Color(hex: 0x14172B))
            .frame(width: 44, height: 44)
        }
        .padding(.leading, 12)
        .frame(minHeight: 48)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(theme.isSimple ? Color(hex: 0xD5D8E1) : theme.cardBorder, lineWidth: theme.isSticker ? 2.5 : 1))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(search.suggestions, id: \.self) { s in
                Button {
                    Task { await pick(s) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.body.weight(.semibold))
                        Text(s.subtitle).font(.caption).foregroundStyle(Color(hex: 0x5B6075))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .foregroundStyle(Color(hex: 0x14172B))
                Divider()
            }
        }
        .padding(.horizontal, 12)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            if let center = draft.coordinate {
                MapCircle(center: center, radius: draft.radius)
                    .foregroundStyle(theme.accent.opacity(0.25))
                    .stroke(theme.strong, lineWidth: 2)
                Marker(draft.homeName, systemImage: "house.fill", coordinate: center)
                    .tint(theme.strong)
            }
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous).stroke(theme.cardBorder, lineWidth: theme.cardBorderWidth))
    }

    private var radius: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Home area").font(theme.body(15, weight: .bold))
                Spacer()
                Text("\(Int(draft.radius)) m\(Int(draft.radius) == 200 ? " · recommended" : "")")
                    .font(theme.body(15, weight: .bold)).foregroundStyle(theme.strong)
            }
            Slider(value: $draft.radius, in: 100...500, step: 25).tint(theme.strong)
            Text(draft.radius < 150 ? "Tight. Phones drift indoors, so you might not ring from your bedroom."
                 : draft.radius <= 250 ? "Your block. You may ring a minute before you walk in."
                 : "Big: you’ll ring while you’re still down the street.")
                .font(theme.body(13)).foregroundStyle(theme.muted)
        }
    }

    private func pick(_ s: MKLocalSearchCompletion) async {
        guard let found = await search.resolve(s) else { return }
        set(found.0, address: found.1, city: found.2)
        search.query = found.1
        search.clear()
    }

    private func useMyLocation() {
        locating = true
        Task {
            defer { locating = false }
            guard let location = try? await LocationPermission.currentLocation() else {
                error = "Couldn’t find you. Search your address instead."
                return
            }
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            let line = [placemark?.subThoroughfare, placemark?.thoroughfare].compactMap { $0 }.joined(separator: " ")
            set(location.coordinate, address: line, city: placemark?.locality)
            search.query = line
            search.clear()
        }
    }

    private func set(_ coordinate: CLLocationCoordinate2D, address: String, city: String?) {
        draft.coordinate = coordinate
        draft.address = address
        if let city { draft.city = city }
        search.bias(to: coordinate)
        camera = .camera(MapCamera(centerCoordinate: coordinate, distance: 1400))
        error = nil
    }

    private func create() {
        guard let coordinate = draft.coordinate else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                if draft.createdHome == nil {
                    let city = draft.city.trimmingCharacters(in: .whitespaces)
                    draft.createdHome = try await HomeService.create(.init(
                        name: draft.homeName.trimmingCharacters(in: .whitespaces),
                        statusLine: draft.statusLine.trimmingCharacters(in: .whitespaces),
                        theme: draft.themeKey, coordinate: coordinate, radius: Int(draft.radius),
                        city: city.isEmpty ? nil : city))
                }
                next()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
