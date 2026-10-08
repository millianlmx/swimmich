import Foundation

/// People & faces state (P3 people-faces): person list, face-thumbnail counts,
/// rename / favorite / hide / merge, and a faces drill-down grid of one
/// person's assets (via `searchMetadata(personIds:)` — the server no longer
/// exposes /people/{id}/assets).
@Observable
@MainActor
final class PeopleViewModel {
    let client: any ImmichClient

    var people: [PersonResponseDto] = []
    var hiddenCount = 0
    var total = 0
    var showingHidden = false
    var isLoading = false
    var errorMessage: String?

    /// Per-person asset counts (GET /people/{id}/statistics), keyed by person id.
    var statsByID: [String: Int] = [:]

    /// Faces drill-down state.
    var personAssets: [AssetReactItem] = []
    var assetsLoading = false
    var assetsError: String?
    var selectedPersonID: String?

    /// Test-visible: last merge payload.
    private(set) var lastMergeIds: [String]?
    private(set) var lastMergeTarget: String?

    /// Fan-out for statistics enrichment (mirrors SearchViewModel explore).
    private let statsConcurrency = 6
    private var assetsLoadedForID: String?

    init(client: any ImmichClient) {
        self.client = client
    }

    var selectedPerson: PersonResponseDto? {
        guard let id = selectedPersonID else { return nil }
        return people.first { $0.id == id }
    }

    func assetCount(for id: String) -> Int {
        statsByID[id] ?? 0
    }

    // MARK: - List

    func load(force: Bool = false) async {
        guard !(isLoading && !force) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.getPeople(page: nil, withHidden: showingHidden)
            people = page.people
            hiddenCount = page.hidden
            total = page.total
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func toggleShowHidden() async {
        showingHidden.toggle()
        await load(force: true)
    }

    /// Enriches per-person asset counts with a bounded task-group fan-out.
    func loadStatistics() async {
        var counts: [String: Int] = [:]
        var offset = 0
        while offset < people.count {
            let upper = min(offset + statsConcurrency, people.count)
            let slice = people[offset..<upper]
            offset = upper
            await withTaskGroup(of: (id: String, count: Int).self) { group in
                for person in slice {
                    group.addTask { [client] in
                        let stats = try? await client.getPersonStatistics(id: person.id)
                        return (person.id, stats?.assets ?? 0)
                    }
                }
                for await (id, count) in group {
                    counts[id] = count
                }
            }
        }
        statsByID = counts
    }

    // MARK: - Person actions (all via PUT /people/{id})

    func rename(_ person: PersonResponseDto, to name: String) async {
        await update(person.id, PersonUpdateDto(name: name))
    }

    func toggleFavorite(_ person: PersonResponseDto) async {
        await update(person.id, PersonUpdateDto(isFavorite: !(person.isFavorite ?? false)))
    }

    func toggleHidden(_ person: PersonResponseDto) async {
        await update(person.id, PersonUpdateDto(isHidden: !person.isHidden))
    }

    /// Sets a person's cover / feature photo (gap #4): PUT /people/{id}
    /// {featureFaceAssetId}. The cover is one of the person's face assets.
    func setFeatureFace(_ person: PersonResponseDto, assetId: String) async {
        await update(person.id, PersonUpdateDto(featureFaceAssetId: assetId))
    }

    /// Sets or clears a person's birthday (gap G15). `wire` is the date-only
    /// `"YYYY-MM-DD"` form: a value rides `PersonUpdateDto(birthDate:)`, so the
    /// synthesized encoder leaves the other five fields out of the body; `nil`
    /// rides `clearPersonBirthday`, whose body is the explicit `null` — the only
    /// form the server reads as an erase.
    func setBirthday(_ person: PersonResponseDto, to wire: String?) async {
        if let wire {
            await apply(person.id) { try await client.updatePerson(id: person.id, dto: PersonUpdateDto(birthDate: wire)) }
        } else {
            await apply(person.id) { try await client.clearPersonBirthday(id: person.id) }
        }
    }

    private func update(_ id: String, _ dto: PersonUpdateDto) async {
        await apply(id) { try await client.updatePerson(id: id, dto: dto) }
    }

    /// The one path both write shapes share: run `call`, replace the row with
    /// the server's answer, and surface a failure. Neither the erase nor the
    /// set may duplicate it — an erase that forgot to rewrite `people` would
    /// look applied until the next load.
    private func apply(_ id: String, _ call: () async throws -> PersonResponseDto) async {
        do {
            let updated = try await call()
            if let i = people.firstIndex(where: { $0.id == id }) { people[i] = updated }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Merges the given persons INTO `person` (POST /people/{id}/merge), then
    /// reloads the list and the drill-down assets.
    func merge(_ ids: [String], into person: PersonResponseDto) async {
        lastMergeIds = ids
        lastMergeTarget = person.id
        do {
            _ = try await client.mergePeople(ids: ids, into: person.id)
            errorMessage = nil
            await load(force: true)
            await loadAssets()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Faces drill-down

    func select(_ person: PersonResponseDto) async {
        selectedPersonID = person.id
        await loadAssets()
    }

    func loadAssets() async {
        guard let id = selectedPersonID else { return }
        if assetsLoadedForID == id { return }
        assetsLoadedForID = id
        await fetchAssets(id)
    }

    func refreshAssets() async {
        guard let id = selectedPersonID else { return }
        await fetchAssets(id)
    }

    private func fetchAssets(_ id: String) async {
        assetsLoading = true
        defer { assetsLoading = false }
        do {
            var dto = MetadataSearchDto()
            dto.personIds = [id]
            let resp = try await client.searchMetadata(dto: dto)
            personAssets = resp.assets.items.map { AssetReactItem(from: $0) }
            assetsError = nil
        } catch {
            assetsError = error.userFacingMessage
        }
    }

    func clearSelection() {
        selectedPersonID = nil
        personAssets = []
        assetsLoadedForID = nil
        assetsError = nil
    }
}