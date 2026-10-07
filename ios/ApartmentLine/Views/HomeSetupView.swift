import MapKit
import SwiftUI

/// Pick home: use the current location or tap the map, then size the circle.
struct HomeSetupView: View {
    let onSave: (HomeLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var center: CLLocationCoordinate2D?
    @State private var radius: Double
    @State private var position: MapCameraPosition
    @State private var locating = false

    init(initial: HomeLocation?, onSave: @escaping (HomeLocation) -> Void) {
        self.onSave = onSave
        _center = State(initialValue: initial?.coordinate)
        _radius = State(initialValue: initial?.radius ?? 100)
        if let initial {
            _position = State(initialValue: .camera(MapCamera(centerCoordinate: initial.coordinate, distance: 1200)))
        } else {
            _position = State(initialValue: .userLocation(fallback: .automatic))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $position) {
                        UserAnnotation()
                        if let center {
                            MapCircle(center: center, radius: radius)
                                .foregroundStyle(.green.opacity(0.2))
                                .stroke(.green, lineWidth: 2)
                            Marker("Home", systemImage: "house.fill", coordinate: center)
                        }
                    }
                    .onTapGesture { point in
                        if let coordinate = proxy.convert(point, from: .local) { center = coordinate }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        useCurrentLocation()
                    } label: {
                        Label(locating ? "Locating…" : "Use my current location", systemImage: "location.fill")
                    }
                    .disabled(locating)

                    Text("Or tap the map to drop the pin.").font(.footnote).foregroundStyle(.secondary)

                    VStack(alignment: .leading) {
                        Text("Radius: \(Int(radius)) m")
                        Slider(value: $radius, in: 100...1000, step: 25)
                    }
                    Text("Smaller circles fire later and less reliably; around 100 m is the practical floor. Anything inside the circle (the café downstairs) counts as home.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Set home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let center { onSave(HomeLocation(coordinate: center, radius: radius)) }
                        dismiss()
                    }
                    .disabled(center == nil)
                }
            }
        }
    }

    private func useCurrentLocation() {
        locating = true
        Task {
            defer { locating = false }
            if let location = try? await LocationPermission.currentLocation() {
                center = location.coordinate
                position = .camera(MapCamera(centerCoordinate: location.coordinate, distance: 1200))
            }
        }
    }
}
