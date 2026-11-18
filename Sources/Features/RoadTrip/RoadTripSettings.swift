import Foundation
import SwiftUI
import UIKit

/// What the person chose for an album's road trip: the film's length, its
/// collages, how many photos a stop shows, the car's paint, and the photos
/// they pinned into or left out of the film. Kept per album; the defaults are
/// the automatic film.
struct RoadTripSettings: Codable, Equatable, Sendable {

    enum Length: String, Codable, CaseIterable, Sendable {
        case short
        case standard
        case long

        /// The soft length the film's photo budget aims at.
        var targetDuration: TimeInterval {
            switch self {
            case .short: return 30
            case .standard: return RoadTripTimelineBuilder.targetDuration
            case .long: return 60
            }
        }
    }

    enum CarColor: String, Codable, CaseIterable, Sendable {
        case white
        case red
        case black

        /// The body paint of the 3D car.
        var paint: UIColor {
            switch self {
            case .white: return UIColor(white: 0.9, alpha: 1)
            case .red: return UIColor(red: 0.62, green: 0.04, blue: 0.06, alpha: 1)
            case .black: return UIColor(white: 0.07, alpha: 1)
            }
        }
    }

    /// The most photos a stop can be set to show.
    static let maxPhotosPerStop = RoadTripTimelineBuilder.maxCollageTiles

    var length: Length = .standard
    var collages: RoadTripTimelineBuilder.CollageMode = .auto
    /// 1…`maxPhotosPerStop`, collage tiles included.
    var photosPerStop: Int = RoadTripSettings.maxPhotosPerStop
    var carColor: CarColor = .white
    /// Asset ids that must be in the film.
    var pinned: Set<String> = []
    /// Asset ids left out of the film.
    var excluded: Set<String> = []

    /// What the timeline builder reads.
    var builderOptions: RoadTripTimelineBuilder.Options {
        RoadTripTimelineBuilder.Options(
            targetDuration: length.targetDuration,
            collages: collages,
            maxPhotosPerStop: min(max(photosPerStop, 1), Self.maxPhotosPerStop),
            pinned: pinned
        )
    }

    /// A photo's place in the film, as the person set it: chosen by the film
    /// (`auto`), always in (`pinned`) or left out (`excluded`).
    enum PhotoChoice: Equatable, Sendable {
        case auto
        case pinned
        case excluded
    }

    func choice(for assetID: String) -> PhotoChoice {
        if pinned.contains(assetID) { return .pinned }
        if excluded.contains(assetID) { return .excluded }
        return .auto
    }

    /// Tapping a photo cycles it: auto → pinned → excluded → auto.
    mutating func cycleChoice(for assetID: String) {
        switch choice(for: assetID) {
        case .auto:
            pinned.insert(assetID)
        case .pinned:
            pinned.remove(assetID)
            excluded.insert(assetID)
        case .excluded:
            excluded.remove(assetID)
        }
    }

    init() {}

    // Tolerant decoding: a field added later reads its default from older data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        length = (try? container.decode(Length.self, forKey: .length)) ?? .standard
        collages = (try? container.decode(RoadTripTimelineBuilder.CollageMode.self, forKey: .collages)) ?? .auto
        photosPerStop = (try? container.decode(Int.self, forKey: .photosPerStop)) ?? Self.maxPhotosPerStop
        carColor = (try? container.decode(CarColor.self, forKey: .carColor)) ?? .white
        pinned = (try? container.decode(Set<String>.self, forKey: .pinned)) ?? []
        excluded = (try? container.decode(Set<String>.self, forKey: .excluded)) ?? []
    }
}

/// Reads and writes `RoadTripSettings` per album in `UserDefaults`.
struct RoadTripSettingsStore: Sendable {
    let albumId: String
    nonisolated(unsafe) let defaults: UserDefaults

    init(albumId: String, defaults: UserDefaults = .standard) {
        self.albumId = albumId
        self.defaults = defaults
    }

    private var key: String { "roadTrip.settings.\(albumId)" }

    func load() -> RoadTripSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(RoadTripSettings.self, from: data) else { return RoadTripSettings() }
        return settings
    }

    func save(_ settings: RoadTripSettings) {
        if settings == RoadTripSettings() {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Sheet

/// The film's settings, from the player's ⚙️ button: length, collages,
/// photos per stop, the car's paint — and, stop by stop, the photos to keep
/// in or leave out. Applying rebuilds the film, which starts over.
struct RoadTripSettingsSheet: View {
    /// Every stop with all its photos, in film order.
    let stops: [RoadTripCluster]
    let placeName: (RoadTripCluster) -> String
    /// The photos the film shows now (marked in the grid).
    let inFilm: Set<String>
    let thumbnailURL: (AssetReactItem) -> URL
    let token: String?
    let onApply: (RoadTripSettings) -> Void

    @State private var draft: RoadTripSettings
    @Environment(\.dismiss) private var dismiss

    init(
        settings: RoadTripSettings,
        stops: [RoadTripCluster],
        placeName: @escaping (RoadTripCluster) -> String,
        inFilm: Set<String>,
        thumbnailURL: @escaping (AssetReactItem) -> URL,
        token: String?,
        onApply: @escaping (RoadTripSettings) -> Void
    ) {
        _draft = State(initialValue: settings)
        self.stops = stops
        self.placeName = placeName
        self.inFilm = inFilm
        self.thumbnailURL = thumbnailURL
        self.token = token
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Film") {
                    Picker("Length", selection: $draft.length) {
                        Text("Short · 30 s").tag(RoadTripSettings.Length.short)
                        Text("Standard · 40 s").tag(RoadTripSettings.Length.standard)
                        Text("Long · 60 s").tag(RoadTripSettings.Length.long)
                    }
                    .accessibilityIdentifier("roadTripSettingsLength")
                    Picker("Collages", selection: $draft.collages) {
                        Text("Off").tag(RoadTripTimelineBuilder.CollageMode.off)
                        Text("Automatic").tag(RoadTripTimelineBuilder.CollageMode.auto)
                        Text("As many as possible").tag(RoadTripTimelineBuilder.CollageMode.max)
                    }
                    .accessibilityIdentifier("roadTripSettingsCollages")
                    Stepper(value: $draft.photosPerStop, in: 1...RoadTripSettings.maxPhotosPerStop) {
                        LabeledContent("Photos per stop", value: draft.photosPerStop.formatted())
                    }
                    .accessibilityIdentifier("roadTripSettingsPhotosPerStop")
                    Picker("Car", selection: $draft.carColor) {
                        Text("White").tag(RoadTripSettings.CarColor.white)
                        Text("Red").tag(RoadTripSettings.CarColor.red)
                        Text("Black").tag(RoadTripSettings.CarColor.black)
                    }
                    .accessibilityIdentifier("roadTripSettingsCar")
                }

                Section {
                    ForEach(stops) { stop in
                        stopRow(stop)
                    }
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Tap a photo to always show it (star), tap again to leave it out, a third time to let the film choose. A checkmark marks the photos in the film now.")
                }

                Section {
                    Button("Reset to automatic", role: .destructive) {
                        draft = RoadTripSettings()
                    }
                    .disabled(draft == RoadTripSettings())
                }
            }
            .navigationTitle("Road trip settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                    .accessibilityIdentifier("roadTripSettingsApply")
                }
            }
        }
    }

    private func stopRow(_ stop: RoadTripCluster) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(placeName(stop))
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(stop.assets) { asset in
                        photoTile(asset)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func photoTile(_ asset: AssetReactItem) -> some View {
        let choice = draft.choice(for: asset.id)
        let shown = inFilm.contains(asset.id)
        return Button {
            draft.cycleChoice(for: asset.id)
        } label: {
            AuthenticatedAsyncImage(url: thumbnailURL(asset), token: token, contentMode: .fill)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(choice == .excluded ? 0.35 : 1)
                .overlay(alignment: .topTrailing) {
                    switch choice {
                    case .pinned:
                        badge("star.fill", color: .yellow)
                    case .excluded:
                        badge("eye.slash.fill", color: .red)
                    case .auto:
                        if shown {
                            badge("checkmark.circle.fill", color: .green)
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(choice == .pinned ? Color.yellow : Color.clear, lineWidth: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            choice == .pinned ? "Photo, always shown"
                : choice == .excluded ? "Photo, left out"
                : shown ? "Photo, in the film" : "Photo, chosen by the film"
        )
        .accessibilityIdentifier("roadTripSettingsPhoto_\(asset.id)")
    }

    private func badge(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(3)
            .background(Circle().fill(.black.opacity(0.6)))
            .padding(4)
    }
}
