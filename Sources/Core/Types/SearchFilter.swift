import Foundation

/// Value-typed state of the Search tab's Filters sheet (search-filters).
///
/// One constraint per `MetadataSearchDto` field, and exactly one writer: the
/// sheet mutates the value, `apply(to:)` projects it into the request body, and
/// `constraints` is the projection the chips bar displays. A constraint the
/// sheet cannot show is a constraint this type does not carry — which is why
/// `albumIds` and `originalPath` are absent (the official mobile client has no
/// album or path filter). The file name and description criteria are text
/// modes of the search field, not sheet fields: `SearchViewModel` writes them
/// and shows their chips (`Field.originalFileName` / `.description`).
struct SearchFilter: Equatable {
    /// 1…5, the server's scale since v3; `nil` = no rating constraint.
    var rating: Int?
    /// Detected-text criterion, projected onto `filter.ocr.matches` (the
    /// v3.2.0 replacement of the deprecated scalar `MetadataSearchDto.ocr`).
    var ocrText: String?
    var city: String?
    var state: String?
    var country: String?
    var make: String?
    var model: String?
    var lensModel: String?
    /// `AssetTypeEnum`'s two values — see `photoType` / `videoType`.
    var type: String?
    var isFavorite: Bool?
    var takenAfter: Date?
    var takenBefore: Date?
    /// Photos where **every** chosen person appears, in selection order.
    var people: [Person] = []
    /// Photos carrying **every** chosen tag (the server adds descendants).
    var tags: [Tag] = []
    /// "Not in album" display option.
    var isNotInAlbum = false
    /// "Archive" display option. Off is not "no constraint": every request
    /// then says `visibility = timeline` (`apply(to:)`), archived photos out.
    var isArchived = false

    /// A person as the filter needs them: the id for the request, the name
    /// for the chip. Unnamed people carry `""` and read "Unnamed".
    struct Person: Equatable, Hashable {
        let id: String
        let name: String
    }

    /// A tag as the filter needs it: the id for the request, the full path
    /// (`Voyages/Japon`) for the chip, so a child never reads like its parent.
    struct Tag: Equatable, Hashable {
        let id: String
        let path: String
    }

    /// The empty filter — what `clearFilters()` restores.
    static let none = SearchFilter()

    /// `AssetTypeEnum`'s values, as the published contract spells them.
    static let photoType = "IMAGE"
    static let videoType = "VIDEO"

    var isEmpty: Bool { constraints.isEmpty }
    var activeCount: Int { constraints.count }

    /// The DTO property a constraint writes. The chips bar builds its
    /// accessibility identifiers from the raw value
    /// (`searchFilterChip_<field>` / `searchFilterChipRemove_<field>`).
    enum Field: String, CaseIterable {
        case originalFileName, description, personIds, tagIds, rating, ocr
        case city, state, country, make, model, lensModel
        case type, isNotInAlbum, isFavorite, visibility, takenAfter, takenBefore
    }

    /// One active constraint, ready to display and to remove.
    struct Constraint: Identifiable, Equatable {
        let field: Field
        /// Complete localized sentence for the chip and its VoiceOver label —
        /// "Rating, 4 stars", "City, Lyon", "Taken after, 1 Jan 2024" — so the
        /// chip is one stop, never a title followed by a value.
        let label: String
        var id: String { field.rawValue }
    }

    /// Active constraints, in the order the sheet lists its sections.
    ///
    /// A field is listed only if `apply(to:)` would write it — the chips bar
    /// says what the request carries, no less and no more (a blank text field
    /// is not a constraint, and neither is a rating outside the server's scale).
    var constraints: [Constraint] {
        var result: [Constraint] = []
        if !people.isEmpty {
            let names = people
                .map { $0.name.isEmpty ? String(localized: "Unnamed") : $0.name }
                .formatted(.list(type: .and))
            result.append(Constraint(field: .personIds, label: String(localized: "People, \(names)")))
        }
        if !tags.isEmpty {
            let paths = tags.map(\.path).formatted(.list(type: .and))
            result.append(Constraint(field: .tagIds, label: String(localized: "Tags, \(paths)")))
        }
        if let rating, (1...5).contains(rating) {
            result.append(Constraint(field: .rating, label: String(localized: "Rating, \(rating) stars")))
        }
        if let ocrText, !ocrText.isEmpty {
            result.append(Constraint(field: .ocr, label: String(localized: "Detected text, \(ocrText)")))
        }
        if let city, !city.isEmpty {
            result.append(Constraint(field: .city, label: String(localized: "City, \(city)")))
        }
        if let state, !state.isEmpty {
            result.append(Constraint(field: .state, label: String(localized: "State, \(state)")))
        }
        if let country, !country.isEmpty {
            result.append(Constraint(field: .country, label: String(localized: "Country, \(country)")))
        }
        if let make, !make.isEmpty {
            result.append(Constraint(field: .make, label: String(localized: "Make, \(make)")))
        }
        if let model, !model.isEmpty {
            result.append(Constraint(field: .model, label: String(localized: "Model, \(model)")))
        }
        if let lensModel, !lensModel.isEmpty {
            result.append(Constraint(field: .lensModel, label: String(localized: "Lens, \(lensModel)")))
        }
        if let type, !type.isEmpty {
            let value = type == Self.photoType ? String(localized: "Photos") : String(localized: "Videos")
            result.append(Constraint(field: .type, label: String(localized: "Type, \(value)")))
        }
        if isNotInAlbum {
            result.append(Constraint(field: .isNotInAlbum, label: String(localized: "Not in album")))
        }
        if let isFavorite {
            result.append(Constraint(
                field: .isFavorite,
                label: isFavorite ? String(localized: "Favourites") : String(localized: "Not favourites")
            ))
        }
        if let takenAfter {
            result.append(Constraint(
                field: .takenAfter,
                label: String(localized: "Taken after, \(takenAfter.formatted(date: .abbreviated, time: .omitted))")
            ))
        }
        if let takenBefore {
            result.append(Constraint(
                field: .takenBefore,
                label: String(localized: "Taken before, \(takenBefore.formatted(date: .abbreviated, time: .omitted))")
            ))
        }
        if isArchived {
            result.append(Constraint(field: .visibility, label: String(localized: "Archive")))
        }
        return result
    }

    /// Drops exactly one constraint — what a chip's tap or cross does. The
    /// sheet's Done applies whatever is left; nothing else clears a field here.
    mutating func clear(_ field: Field) {
        switch field {
        case .originalFileName, .description: break // text modes of the search field (view model)
        case .personIds: people = []
        case .tagIds: tags = []
        case .rating: rating = nil
        case .ocr: ocrText = nil
        case .city: city = nil
        case .state: state = nil
        case .country: country = nil
        case .make: make = nil
        case .model: model = nil
        case .lensModel: lensModel = nil
        case .type: type = nil
        case .isNotInAlbum: isNotInAlbum = false
        case .isFavorite: isFavorite = nil
        case .visibility: isArchived = false
        case .takenAfter: takenAfter = nil
        case .takenBefore: takenBefore = nil
        }
    }

    /// Adds `person` after the ones already chosen, or removes them.
    mutating func toggle(person: PersonResponseDto) {
        if let index = people.firstIndex(where: { $0.id == person.id }) {
            people.remove(at: index)
        } else {
            people.append(Person(id: person.id, name: person.name))
        }
    }

    /// Adds `tag` (by its full path) after the ones already chosen, or removes it.
    mutating func toggle(tag: TagResponseDto) {
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags.remove(at: index)
        } else {
            tags.append(Tag(id: tag.id, path: tag.path))
        }
    }

    /// Writes every constraint that is set, and only those: the synthesized
    /// `Codable` omits an `Optional` that stays `nil` (`encodeIfPresent`), so an
    /// undone field leaves the request body instead of sending `null`.
    ///
    /// The six EXIF fields go through `ExploreField.apply(_:to:)`, the same
    /// writer the Explore drill-down uses — one place knows how `city` or
    /// `lensModel` reaches the DTO. The two dates are **not** written here: the
    /// DTO carries them as ISO-8601 strings and the formatting belongs to the
    /// ViewModel (one call site, one formatter).
    func apply(to dto: inout MetadataSearchDto) {
        // A rating outside the server's scale is ignored rather than sent as a
        // request the contract rejects (`min(1).max(5)`, `-1` removed in v3).
        if let rating, (1...5).contains(rating) { dto.rating = rating }

        let exifFields: [(SearchViewModel.ExploreField, String?)] = [
            (.city, city),
            (.state, state),
            (.country, country),
            (.make, make),
            (.model, model),
            (.lensModel, lensModel),
        ]
        for (field, value) in exifFields {
            guard let value, !value.isEmpty else { continue }
            field.apply(value, to: &dto)
        }

        if let type, !type.isEmpty { dto.type = type }
        if let isFavorite { dto.isFavorite = isFavorite }

        if !people.isEmpty { dto.personIds = people.map(\.id) }
        if !tags.isEmpty { dto.tagIds = tags.map(\.id) }
        if isNotInAlbum { dto.isNotInAlbum = true }
        // Always written, never inferred by the server: without it the flat
        // routes default to `not-locked`, archive included (decision #1).
        dto.visibility = isArchived ? .archive : .timeline

        // Detected text: the similarity filter, never the deprecated scalar.
        if let ocrText, !ocrText.isEmpty {
            dto.filter = SearchFilterDto(ocr: StringSimilarityFilterDto(matches: ocrText))
        }
    }
}
