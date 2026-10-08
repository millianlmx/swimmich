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
        isBusy = true
        errorMessage = nil
        biometricsAvailable = biometricsProbe()
        canUnlockWithBiometrics = biometricsAvailable && pins.storedPIN(for: accountID) != nil
        do {
            let status = try await client.getAuthStatus()
            if status.isElevated {
                gate = .unlocked
                await loadFirstPage()
            } else if status.pinCode {
                gate = .locked
            } else {
                gate = .needsSetup
            }
        } catch let e {
            // The status route needs a session token: an account authenticated
            // with an API key is answered 400 and can never elevate, so say so
            // instead of showing a PIN field that would loop.
            errorMessage = e.userFacingMessage
            gate = pins.storedPIN(for: accountID) == nil ? .needsSetup : .locked
        }
        isBusy = false
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
        items = []
        buckets = []
        selectedIds = []
        loadedIds = []
        selectionMode = false
        bucketIndex = 0
        pinEntry = ""
        errorMessage = nil
        try? await client.lockAuthSession()
    }

    // MARK: - Grid

    /// The folder's first page: the bucket list, then its newest bucket. Both
    /// reads carry the locked filter — drop it from either and the folder shows
    /// timeline assets.
    func loadFirstPage() async {
        isLoadingMore = true
        defer { isLoadingMore = false }
        errorMessage = nil
        do {
            buckets = try await client.getTimeBuckets(
                isFavorite: nil,
                isTrashed: nil,
                personId: nil,
                withPartners: nil,
                visibility: filterVisibility,
                withStacked: true
            )
            bucketIndex = 0
            items = []
            loadedIds = []
            await loadNextBucket()
        } catch let e {
            errorMessage = e.userFacingMessage
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
        let bucket = buckets[bucketIndex]
        do {
            let columnar = try await client.getTimeBucket(
                timeBucket: bucket.timeBucket,
                personId: nil,
                withPartners: nil,
                visibility: filterVisibility,
                withStacked: true
            )
            let zipped = AssetReactItem.zip(columnar)
            for item in zipped where !loadedIds.contains(item.id) {
                items.append(item)
                loadedIds.insert(item.id)
            }
            bucketIndex += 1
        } catch let e {
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
