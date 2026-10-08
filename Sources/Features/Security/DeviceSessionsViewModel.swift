import Foundation
import Observation

/// Connected devices (gap G19) — the account's sessions, and the four things
/// you can do to them: read the list, sign one other device out, sign every
/// other device out, and lock or unlock the current session.
///
/// What is the server's here, and what is this screen's — the two are easy to
/// confuse on a screen that both reads and writes:
///
/// * **The list is the server's.** `getSessions()` is the only source of
///   `sessions`, and therefore of `currentSession` / `otherSessions`.
/// * **The elevation is the server's too, but it travels on another route.**
///   No field of `SessionResponseDto` carries it (no `pinExpiresAt`, no
///   boolean), so `isElevated` is read from `GET /api/auth/status`
///   (`AuthStatusResponseDto.isElevated`) and from nowhere else. Every mutation
///   — `revoke(_:)`, `revokeAllOthers()`, `lockCurrentSession()`,
///   `unlock(pinCode:)` — ends on that probe rather than on a guess about what
///   the call must have done. A probe that fails leaves the last value the
///   server did confirm in place and raises `isElevationStale`: a request that
///   failed never becomes a state the screen asserts.
/// * **Nothing local is the truth.** `errorMessage` and `pendingRevocation` are
///   the screen's own; they never stand in for a server answer.
/// * `DELETE /api/sessions` never touches the session that calls it, and
///   `DELETE /api/sessions/{id}` does not either when the id is your own — the
///   screen therefore says "other devices" everywhere and shows no destructive
///   affordance on the current one. Nothing here promises a self-logout.
/// * Both `/auth/session/*` routes require a **session token**; an account
///   configured with an API key is answered 400. That message is surfaced as it
///   arrives instead of being swallowed, so the screen never spins on a call
///   that can only fail.
@Observable
@MainActor
final class DeviceSessionsViewModel {

    private let client: any ImmichClient

    // MARK: - State

    var sessions: [SessionResponseDto] = []
    var isLoading = false
    var errorMessage: String?
    /// The elevation the server last reported for this session. Written by
    /// `probeElevation()` alone — no action of this screen moves it on its own —
    /// and left at its last confirmed value when a probe fails.
    var isElevated = false
    /// `true` when the last probe failed, i.e. `isElevated` is a value the
    /// server confirmed earlier and not necessarily the current one. The lock
    /// control reads it so it never presents an unverified state as a fact.
    var isElevationStale = false
    /// The device whose logout a swipe asked for: the confirmation's subject.
    /// Never an implicit target, and never the current session.
    var pendingRevocation: SessionResponseDto?

    // MARK: - Projections

    /// The session this app is running in — it opens the screen and gets no
    /// destructive affordance of its own.
    var currentSession: SessionResponseDto? { sessions.first(where: \.current) }

    /// Everything else, newest activity first.
    var otherSessions: [SessionResponseDto] { sessions.filter { !$0.current } }

    init(client: any ImmichClient) {
        self.client = client
    }

    // MARK: - Actions

    /// Reads the list. The current session is pinned first, then the others by
    /// last activity descending — the row the user is most likely to act on
    /// sits closest to the top.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await client.getSessions()
            sessions = fetched.sorted { lhs, rhs in
                if lhs.current != rhs.current { return lhs.current }
                return lhs.updatedAt > rhs.updatedAt
            }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Arms the confirmation dialog for one device. The current session is
    /// refused here as well as in `revoke(_:)`: the guard is a property of the
    /// intent, not of one call site.
    func requestRevoke(_ session: SessionResponseDto) {
        guard !session.current else { return }
        pendingRevocation = session
    }

    /// Signs one other device out. Refuses the current session **before** any
    /// request — the server would ignore the call anyway, so there is no reason
    /// to spend a round trip learning that.
    func revoke(_ session: SessionResponseDto) async {
        guard !session.current else { return }
        pendingRevocation = nil
        await mutate({ try await client.deleteSession(id: session.id) }, reloadingList: true)
    }

    /// "Log out other devices": the current session survives, because the
    /// server excludes it from the bulk delete.
    func revokeAllOthers() async {
        await mutate({ try await client.deleteAllSessions() }, reloadingList: true)
    }

    /// Drops the session's elevated access. Bodyless on the wire — the route
    /// names no resource, it just clears the elevation of the caller.
    func lockCurrentSession() async {
        await mutate { try await client.lockAuthSession() }
    }

    /// Elevates the session with the account PIN. The server reads only a
    /// six-digit `pinCode` (its `pattern` is `^\d{6}$` whatever the field's
    /// description says), and a shorter entry is refused **here** so it never
    /// reaches the network — and, nothing having changed server-side, it is
    /// not worth a probe either.
    func unlock(pinCode: String) async {
        clearError()
        guard pinCode.count == 6 else {
            errorMessage = String(localized: "Enter 6 digits")
            return
        }
        await mutate { try await client.unlockAuthSession(pinCode: pinCode) }
    }

    /// Clears the previous failure before a new attempt, so an error never
    /// outlives the state that produced it.
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Server reads

    /// Runs one mutation, then re-reads the elevation from the server — the
    /// answer, not the action, is what `isElevated` ends up holding.
    ///
    /// `errorMessage` ends up holding the most actionable failure: the
    /// mutation's (or the list reload's) when there is one, the probe's
    /// otherwise. A failed probe never erases a mutation's failure — it raises
    /// `isElevationStale` instead — and it never touches `isElevated`, so a
    /// request that failed can never be read as "unlocked".
    private func mutate(_ mutation: () async throws -> Void, reloadingList: Bool = false) async {
        clearError()
        var failure: String?
        do {
            try await mutation()
            if reloadingList {
                await load()
                failure = errorMessage
            }
        } catch {
            failure = error.userFacingMessage
        }
        if let probeFailure = await probeElevation() {
            failure = failure ?? probeFailure
        }
        errorMessage = failure
    }

    /// `GET /api/auth/status` — the elevation's only source. Returns the failure
    /// to report when the probe itself failed, `nil` when the answer was read.
    private func probeElevation() async -> String? {
        do {
            isElevated = try await client.getAuthStatus().isElevated
            isElevationStale = false
            return nil
        } catch {
            isElevationStale = true
            return error.userFacingMessage
        }
    }

    // MARK: - Presentation

    /// `DeviceCard.svelte`'s first line: `deviceOS • deviceType (vX.Y.Z)`, with
    /// `Unknown` standing in for a field the server left empty and the version
    /// segment dropped entirely when `appVersion` is null.
    func deviceDescription(for session: SessionResponseDto) -> String {
        let os = session.deviceOS.isEmpty ? String(localized: "Unknown") : session.deviceOS
        let type = session.deviceType.isEmpty ? String(localized: "Unknown") : session.deviceType
        return "\(os) • \(type)\(versionSuffix(for: session))"
    }

    /// "Last seen 2 h ago" — relative on purpose: `updatedAt` is a last-activity
    /// stamp, and "3 days ago" is what tells two rows apart.
    func lastSeenText(for session: SessionResponseDto) -> String {
        String(localized: "Last seen \(AppDateFormat.relativeString(for: session.updatedAt))")
    }

    /// The same instant, spelled out — the absolute half of the pair
    /// `DeviceCard.svelte` shows.
    func lastSeenAbsoluteText(for session: SessionResponseDto) -> String {
        session.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// The per-OS symbol table of `DeviceCard.svelte`, in its order: the OS
    /// decides first (a Chromebook falls through to its browser), and a session
    /// with neither match is a question mark rather than a wrong icon.
    func deviceSymbol(for session: SessionResponseDto) -> String {
        let os = session.deviceOS
        let type = session.deviceType

        if os == "Android" { return "smartphone" }
        if os == "iOS" || os == "macOS" { return "apple.logo" }
        if os.contains("Safari") { return "safari" }
        if os.contains("Windows") { return "pc" }
        if os == "Linux" || os == "Ubuntu" { return "desktopcomputer" }
        if os == "Chrome OS" || type == "Chrome" || type == "Chromium" || type == "Mobile Chrome" {
            return "globe"
        }
        if os == "Google Cast" { return "airplayvideo" }
        return "questionmark.circle"
    }

    /// An expired session stays listed and revocable — it is a session the
    /// server still counts. A null `expiresAt` is not an expiry.
    func isExpired(_ session: SessionResponseDto) -> Bool {
        guard let expiresAt = session.expiresAt else { return false }
        return expiresAt < Date()
    }

    /// One VoiceOver phrase per row: what the device is, when it was last seen,
    /// and whether it is the one in your hand. Built here, so the badge is
    /// folded into the sentence instead of being read as its own element.
    func accessibilityLabel(for session: SessionResponseDto) -> String {
        var parts = [deviceDescription(for: session), lastSeenText(for: session)]
        if session.current { parts.append(String(localized: "This device")) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Confirmation copy

    /// "Log out 3 other devices?" — the count is what the bulk delete would
    /// actually remove.
    var revokeAllPrompt: String {
        String(localized: "Log out \(otherSessions.count) other devices?")
    }

    var revokeAllButtonTitle: String {
        String(localized: "Log out \(otherSessions.count) devices")
    }

    /// "Log out iPhone?" — the device named, so the single-device confirmation
    /// cannot be mistaken for the bulk one.
    func revokePrompt(for session: SessionResponseDto) -> String {
        String(localized: "Log out \(session.deviceType)?")
    }

    private func versionSuffix(for session: SessionResponseDto) -> String {
        guard let version = session.appVersion, !version.isEmpty else { return "" }
        return " (v\(version))"
    }
}
