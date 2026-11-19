import CoreLocation
import Foundation

/// What the poster says about the places in the photos — a pure function of
/// the map markers, so the numbers are the same however often it is drawn.
struct MapPosterStats: Equatable {

    struct CountryCount: Equatable {
        let name: String
        let photos: Int
    }

    /// The place furthest from home, and how far.
    struct Furthest: Equatable {
        let city: String?
        let country: String?
        let kilometers: Double

        /// "🇺🇸 New York": the flag stands for the country, which keeps the
        /// line short ("United States of America" did not fit). The country
        /// in words only when it has no flag or there is no city.
        var shortLabel: String? {
            let flag = country.flatMap(MapPosterStats.flag(forCountry:))
            switch (city, flag) {
            case let (city?, flag?): return "\(flag) \(city)"
            case let (city?, nil): return ReelPlan.placeLabel(city: city, country: country)
            case let (nil, flag?): return [flag, country].compactMap { $0 }.joined(separator: " ")
            case (nil, nil): return country
            }
        }
    }

    let photoCount: Int
    /// Distinct cities (with their country: two Valencias are two cities).
    let cityCount: Int
    /// The countries, most photographed first.
    let countries: [CountryCount]
    /// Where most photos were taken: the center of the busiest ~50 km square.
    let home: CLLocationCoordinate2D?
    let furthest: Furthest?

    /// Countries in the world, for the share of it seen.
    static let worldCountries = 195
    /// The side of the squares home is counted in, in degrees (~55 km).
    static let homeCell = 0.5

    var countryCount: Int { countries.count }
    var worldShare: Double { min(Double(countryCount) / Double(Self.worldCountries), 1) }

    static func == (a: MapPosterStats, b: MapPosterStats) -> Bool {
        a.photoCount == b.photoCount && a.cityCount == b.cityCount && a.countries == b.countries
            && a.home?.latitude == b.home?.latitude && a.home?.longitude == b.home?.longitude
            && a.furthest == b.furthest
    }

    static func make(_ markers: [MapPhoto]) -> MapPosterStats {
        var countries: [String: Int] = [:]
        var cities = Set<String>()
        var cells: [String: (count: Int, lat: Double, lon: Double)] = [:]
        for marker in markers {
            let country = marker.country?.trimmingCharacters(in: .whitespaces) ?? ""
            if !country.isEmpty { countries[country, default: 0] += 1 }
            if let city = marker.city?.trimmingCharacters(in: .whitespaces), !city.isEmpty {
                cities.insert("\(city)|\(country)")
            }
            let key = "\(Int((marker.latitude / homeCell).rounded(.down)))|\(Int((marker.longitude / homeCell).rounded(.down)))"
            let cell = cells[key] ?? (0, 0, 0)
            cells[key] = (cell.count + 1, cell.lat + marker.latitude, cell.lon + marker.longitude)
        }
        let busiest = cells.max { $0.value.count == $1.value.count ? $0.key > $1.key : $0.value.count < $1.value.count }?.value
        let home = busiest.map { CLLocationCoordinate2D(latitude: $0.lat / Double($0.count), longitude: $0.lon / Double($0.count)) }
        var furthest: Furthest?
        if let home {
            let farthest = markers.max { distance(home, $0.coordinate) < distance(home, $1.coordinate) }
            if let farthest {
                let city = farthest.city?.trimmingCharacters(in: .whitespaces)
                let country = farthest.country?.trimmingCharacters(in: .whitespaces)
                furthest = Furthest(
                    city: city?.isEmpty == false ? city : nil,
                    country: country?.isEmpty == false ? country : nil,
                    kilometers: distance(home, farthest.coordinate) / 1000
                )
            }
        }
        return MapPosterStats(
            photoCount: markers.count,
            cityCount: cities.count,
            countries: countries.map { CountryCount(name: $0.key, photos: $0.value) }
                .sorted { $0.photos == $1.photos ? $0.name < $1.name : $0.photos > $1.photos },
            home: home,
            furthest: furthest
        )
    }

    /// Great-circle distance in meters.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let earth = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earth * asin(min(1, sqrt(h)))
    }

    // MARK: - Flags

    /// The flag of a country the server names in English ("France", "United
    /// States of America"), nil when the name is not one Foundation knows.
    static func flag(forCountry name: String) -> String? {
        guard let code = regionCode(forCountry: name) else { return nil }
        let base: UInt32 = 0x1F1E6 - 65
        let scalars = code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(base + $0.value) }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    /// The names of the reverse geocoder that differ from Foundation's.
    private static let aliases: [String: String] = [
        "united states of america": "US",
        "united kingdom of great britain and northern ireland": "GB",
        "russian federation": "RU",
        "czechia": "CZ",
        "korea, republic of": "KR",
        "republic of korea": "KR",
        "viet nam": "VN",
        "türkiye": "TR",
        "turkey": "TR",
        "the netherlands": "NL",
    ]

    private static let englishNames: [String: String] = {
        let english = Locale(identifier: "en_US")
        var names: [String: String] = [:]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            if let name = english.localizedString(forRegionCode: region.identifier) {
                names[name.lowercased()] = region.identifier
            }
        }
        return names
    }()

    static func regionCode(forCountry name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return aliases[key] ?? englishNames[key]
    }
}
