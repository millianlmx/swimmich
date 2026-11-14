import Foundation
import LocalAuthentication

/// The locked folder (gap G12): a door, a grid, and a **server-side** elevation.
///
/// The PIN is not a local gate. `POST /api/auth/session/unlock` is what makes
/// `GET /api/timeline/buckets?visibility=locked` answer anything, and the
/// elevation is the session's (`AuthStatusResponseDto.isElevated`) with its own
/// expiry. A local gate would therefore open nothing: it would only *look*
/// protected while the server kept refusing the reads. Face ID is consequently
/// not a second door — it authorizes the **replay** of the PIN the user chose to
/// remember, and the same unlock route is called either way.
@Observable
@MainActor
final class LockedFolderViewModel {
    /// Which door the folder shows.
    ///
    /// - `needsSetup`: the server has no PIN for this account yet.
    /// - `locked`: a PIN exists and the session is not elevated.
    /// - `unlocked`: `GET /api/auth/status` answered `isElevated`.
    enum Gate {
        case needsSetup
        case locked
        case unlocked
    }

    /// Attempts after which the door stops accepting input. The server
    /// rate-limits too; this is what keeps the UI from machine-gunning it.
    static let maxAttempts = 5

    let client: any ImmichClient
    let accountID: String

    private let pins: any LockedFolderPINStoring
    private let evaluator: @Sendable () async -> Bool
    private let biometricsProbe: @Sendable () -> Bool

    // MARK: - Door state

    var gate: Gate
    var pinEntry = ""
    var confirmationEntry = ""
    var rememberPIN = false
    var isBusy = false
    var failedAttempts = 0
    var errorMessage: String?
    /// Bumped on each PIN the server refused (4xx), including the attempt that
    /// reaches the limit; never for the exhausted-door guard (no request),
    /// setup or Face ID. The door plays an error haptic on each change (AC-807).
    private(set) var pinRefusalFeedbackTick = 0

    /// The device can evaluate `.deviceOwnerAuthentication` — decides whether
    /// the Face ID controls exist at all (the setup door's toggle).
    private(set) var biometricsAvailable = false

    /// Capability **and** a remembered PIN: what the locked door's Face ID
    /// button needs. Both are read once per `refreshGate()` — a Keychain read
    /// per `body` evaluation would be a query per frame.
    private(set) var canUnlockWithBiometrics = false

    // MARK: - Grid state

    var buckets: [TimeBucketsResponseDto] = []
    var items: [AssetReactItem] = []
    var selectedIds: Set<String> = []
    var selectionMode = false
    var isLoadingMore = false
    var bucketIndex = 0
    private(set) var loadedIds: Set<String> = []

    /// True once `GET /api/auth/status` has answered, successfully or not.
    /// `gate` cannot play this role: it is `.locked` from `init`.
    private(set) var hasCheckedAccess = false
    /// A read of the grid (the access check and the first page) is in flight.
    private(set) var isLoading = false
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    /// True once the first page was read and applied.
    private(set) var hasLoaded = false
    /// Failure of the last read of the grid, cleared by a success. Written by
    /// the reads only; `errorMessage` stays the doors' own.
    private(set) var loadErrorMessage: String?
    /// Bumped by every read, so only the last one writes its result.
    private var readGeneration = 0

    /// The query that scopes **both** bucket reads to the folder. Held here
    /// rather than borrowed from `TimelineViewModel`: the folder is not a
    /// timeline filter, and the timeline's filter menu never learns this value.
    let filterVisibility = "locked"

    init(
        client: any ImmichClient,
        pins: any LockedFolderPINStoring,
        accountID: String,
        evaluator: @Sendable @escaping () async -> Bool = AppLockViewModel.systemEvaluator,
        biometricsAvailable: @Sendable @escaping () -> Bool = LockedFolderViewModel.systemBiometricsAvailable
    ) {
        self.client = client
        self.pins = pins
        self.accountID = accountID
        self.evaluator = evaluator
        self.biometricsProbe = biometricsAvailable
        // Safest door until `GET /api/auth/status` answers: never the grid.
        self.gate = .locked
    }

    /// Production probe: Face ID / Touch ID with passcode fallback.
    static let systemBiometricsAvailable: @Sendable () -> Bool = {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    var canLoadMore: Bool { bucketIndex < buckets.count }

    /// "12" for the unlocked banner — formatting belongs to the ViewModel.
    var itemCountText: String { String(items.count) }

    var attemptsExhausted: Bool { failedAttempts >= Self.maxAttempts }

    // MARK: - Gate

    /// Reads the session's elevation **from the server** and picks the door.
    ///
    /// Never inferred from the grid's content: an unelevated
    /// `visibility=locked` read answers an empty list rather than a 403, so an
    /// empty answer is indistinguishable from an empty folder.
    func refreshGate() async {
        readGeneration += 1
        let generation = readGeneration
        isLoading = true
        isBusy = true
        errorMessage = nil
        defer {
            if generation == readGeneration {
                isLoading = false
                isBusy = false
            }
        }
        biometricsAvailable = biometricsProbe()
        canUnlockWithBiometrics = biometricsAvailable && pins.storedPIN(for: accountID) != nil
        do {
            let status = try await client.getAuthStatus()
            hasCheckedAccess = true
            guard generation == readGeneration else { return }
            if status.isElevated {
                gate = .unlocked
                await readFirstPage(generation: generation)
            } else {
                // An elevation that expired (or never was) closes the folder:
                // nothing locked stays in memory behind the door.
                resetGrid()
                gate = status.pinCode ? .locked : .needsSetup
            }
        } catch let e {
            // A cancellation changes nothing.
            guard generation == readGeneration, let message = e.userFacingMessage else { return }
            hasCheckedAccess = true
            if gate == .unlocked {
                // The grid is on screen: it stays, the failure becomes its banner.
                loadErrorMessage = message
            } else {
                // The status route needs a session token: an account authenticated
                // with an API key is answered 400 and can never elevate, so say so
                // instead of showing a PIN field that would loop.
                errorMessage = message
                gate = pins.storedPIN(for: accountID) == nil ? .needsSetup : .locked
            }
        }
    }

    /// Pull-to-refresh: `refreshGate()` flagged so the grid and its photos stay
    /// in place while the access and the first page are read again.
    func refresh() async {
        isRefreshing = true
        await refreshGate()
        isRefreshing = false
    }

    /// What the grid renders.
    var gridState: ListRenderState {
        .resolve(
            isEmpty: items.isEmpty,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: loadErrorMessage
        )
    }

    /// Empties the grid and forgets that it was ever read.
    private func resetGrid() {
        items = []
        buckets = []
        selectedIds = []
        loadedIds = []
        selectionMode = false
        bucketIndex = 0
        hasLoaded = false
        loadErrorMessage = nil
    }

    /// First-time PIN creation. Both guards are local and cost no round trip:
    /// exactly 6 digits, and a confirmation that matches. The PIN is then
    /// created **and** used to elevate — the folder only opens once the server
    /// accepted the elevation, so a created-but-not-elevated state cannot show
    /// an empty grid as if it were the folder.
    func setupPIN() async {
        guard pinEntry.count == 6, pinEntry == confirmationEntry else {
            errorMessage = pinEntry.count == 6
                ? String(localized: "PINs don't match")
                : String(localized: "Enter 6 digits")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await client.setupPinCode(pinEntry)
            try await client.unlockAuthSession(pinCode: pinEntry)
            if rememberPIN { pins.storePIN(pinEntry, for: accountID) }
            failedAttempts = 0
            pinEntry = ""
            confirmationEntry = ""
            gate = .unlocked
            canUnlockWithBiometrics = biometricsAvailable && pins.storedPIN(for: accountID) != nil
            await loadFirstPage()
        } catch let e {
            errorMessage = e.userFacingMessage
        }
    }

    /// The locked door: one PIN against `POST /api/auth/session/unlock`. On a
    /// refusal nothing opens — the attempts counter moves, the field is cleared
    /// and the gate stays `.locked`.
    func submitPIN() async {
        guard !attemptsExhausted else {
            errorMessage = String(localized: "Too many attempts")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await client.unlockAuthSession(pinCode: pinEntry)
            failedAttempts = 0
            pinEntry = ""
            gate = .unlocked
            await loadFirstPage()
        } catch {
            // The server's own wording is not shown here on purpose: a refused
            // PIN is the only failure this route has for a signed-in session,
            // and "Wrong PIN" is what the user can act on.
            failedAttempts += 1
            if APIError.from(error).isServerRefusal { pinRefusalFeedbackTick &+= 1 }
            pinEntry = ""
            errorMessage = failedAttempts >= Self.maxAttempts
                ? String(localized: "Too many attempts")
                : String(localized: "Wrong PIN")
        }
    }

    /// Face ID replays the remembered PIN — it never opens the folder by
    /// itself. No PIN remembered (or an evaluator that answered no) means no
    /// server call at all.
    func unlockWithBiometrics() async {
        guard !attemptsExhausted else {
            errorMessage = String(localized: "Too many attempts")
            return
        }
        guard !isBusy else { return }
        guard let remembered = pins.storedPIN(for: accountID) else {
            errorMessage = String(localized: "Enter 6 digits")
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        guard await evaluator() else { return }
        do {
            try await client.unlockAuthSession(pinCode: remembered)
            failedAttempts = 0
            pinEntry = ""
            gate = .unlocked
            await loadFirstPage()
        } catch let e {
            // A remembered PIN the server refuses is stale (changed on another
            // device): drop it, or the button would loop on the same code.
            pins.clearPIN(for: accountID)
            canUnlockWithBiometrics = false
            errorMessage = e.userFacingMessage
        }
    }

    /// Closes the folder: the server drops the session's elevation and the grid
    /// is emptied **locally first**, so nothing locked stays on screen between
    /// the tap and the next status read.
    func relock() async {
        gate = .locked
        // A read still in flight must not write locked photos back.
        readGeneration += 1
        isLoading = false
        // The superseded read's `defer` no longer clears the door's busy flag.
        isBusy = false
        resetGrid()
        pinEntry = ""
        errorMessage = nil
        try? await client.lockAuthSession()
    }

    /// Backgrounding closes an OPEN folder only (the scene-phase rule, driven by
    /// `AuthenticatedRoot`). A folder that is still `.locked` or has no PIN yet
    /// keeps its gate and costs no request: `relock()` would flip `.needsSetup`
    /// to `.locked` and call the server for nothing.
    func relockIfUnlocked() async {
        guard gate == .unlocked else { return }
        await relock()
    }

    // MARK: - Grid

    /// The folder's first page: the bucket list, then its newest bucket. Both
    /// reads carry the locked filter — drop it from either and the folder shows
    /// timeline assets.
    func loadFirstPage() async {
        readGeneration += 1
        let generation = readGeneration
        isLoading = true
        defer { if generation == readGeneration { isLoading = false } }
        await readFirstPage(generation: generation)
    }

    /// Reads the bucket list and its newest bucket into locals, then writes
    /// the grid at once: the photos on screen stay until the answer, and a
    /// failure or a newer read leaves them alone.
    private func readFirstPage(generation: Int) async {
        do {
            let fetched = try await client.getTimeBuckets(
                isFavorite: nil,
                isTrashed: nil,
                personId: nil,
                withPartners: nil,
                visibility: filterVisibility,
                withStacked: true
            )
            guard generation == readGeneration else { return }
            var firstItems: [AssetReactItem] = []
            var firstIds: Set<String> = []
            if let first = fetched.first {
                let columnar = try await client.getTimeBucket(
                    timeBucket: first.timeBucket,
                    personId: nil,
                    withPartners: nil,
                    visibility: filterVisibility,
                    withStacked: true
                )
                guard generation == readGeneration else { return }
                for item in AssetReactItem.zip(columnar) where !firstIds.contains(item.id) {
                    firstItems.append(item)
                    firstIds.insert(item.id)
                }
            }
            buckets = fetched
            bucketIndex = fetched.isEmpty ? 0 : 1
            items = firstItems
            loadedIds = firstIds
            selectedIds.formIntersection(firstIds)
            hasLoaded = true
            loadErrorMessage = nil
        } catch let e {
            guard generation == readGeneration, let message = e.userFacingMessage else { return }
            loadErrorMessage = message
        }
    }

    func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadNextBucket()
    }

    private func loadNextBucket() async {
        guard bucketIndex < buckets.count else { return }
        let generation = readGeneration
        let bucket = buckets[bucketIndex]
        do {
            let columnar = try await client.getTimeBucket(
                timeBucket: bucket.timeBucket,
                personId: nil,
                withPartners: nil,
                visibility: filterVisibility,
                withStacked: true
            )
            // A first-page read that landed meanwhile replaced the grid.
            guard generation == readGeneration else { return }
            let zipped = AssetReactItem.zip(columnar)
            for item in zipped where !loadedIds.contains(item.id) {
                items.append(item)
                loadedIds.insert(item.id)
            }
            bucketIndex += 1
        } catch let e {
            guard generation == readGeneration else { return }
            errorMessage = e.userFacingMessage
        }
    }

    func enterSelectionMode() { selectionMode = true }

    func exitSelectionMode() {
        selectionMode = false
        selectedIds.removeAll()
    }

    func toggleSelection(id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// Sends the selection back to the timeline (`visibility: timeline`) and
    /// drops it from the grid — same try-then-mutate discipline as the
    /// timeline's archive action: on a throw nothing is removed locally.
    func restoreSelectionToTimeline() async {
        guard !selectedIds.isEmpty, !isBusy else { return }
        let ids = Array(selectedIds)
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await client.bulkUpdateAssets(dto: AssetBulkUpdateDto(ids: ids, visibility: .timeline))
            items.removeAll { selectedIds.contains($0.id) }
            loadedIds.subtract(selectedIds)
            selectedIds.removeAll()
            selectionMode = false
        } catch let e {
            errorMessage = e.userFacingMessage
        }
    }
}
