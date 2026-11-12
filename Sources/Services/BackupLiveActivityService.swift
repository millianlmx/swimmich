import ActivityKit
import Foundation
import ImmichSharedKit
import os

/// One frame of backup progress for the Live Activity — the engine state
/// reduced to what the widget can render. Built on the main actor by
/// `UploadViewModel` after every engine progress tick.
struct BackupActivitySnapshot: Equatable, Sendable {
    var phase: BackupActivityAttributes.Phase
    var progress: Double
    var processed: Int
    var total: Int
    var uploaded: Int
    var onServer: Int
    var waiting: Int
    var failed: Int
    var fileName: String?
    var estimatedDone: Date?
}

/// Live Activity driver seam. The real implementation talks ActivityKit;
/// tests inject a recorder. ActivityKit itself is not hermetic in unit tests.
protocol BackupLiveActivityServicing: AnyObject {
    func start(_ snapshot: BackupActivitySnapshot)
    func update(_ snapshot: BackupActivitySnapshot)
    func end(success: Bool, snapshot: BackupActivitySnapshot)
}

/// ActivityKit-backed Live Activity for backup progress (Dynamic Island +
/// Lock Screen). `snapshot.processed` is the same numerator as the in-app bar
/// (uploaded + already-on-server + failed + deferred), so the Live Activity
/// percentage tracks it exactly — and the breakdown chips tell the story.
final class LiveActivityBackupService: BackupLiveActivityServicing {
    private static let log = Logger(subsystem: "app.immich.swiftui", category: "backup-activity")
    private var current: Activity<BackupActivityAttributes>?

    /// Relevance decides which activity the Dynamic Island shows when several
    /// are live; the default 0 loses ties. A backup in flight is the most
    /// relevant thing this app has to say, so it bids the top of the range.
    private static let relevance: Double = 100

    nonisolated init() {
        // A Live Activity outlives the process that requested it (the system
        // keeps it up to 8 h); a backup run does not. Anything still alive at
        // launch is an orphan from a run the OS killed, and `Activity.request`
        // would stack a second same-app activity on top of it — the island
        // then picks between them unpredictably, which is exactly the
        // "no island during backup" symptom. Reap first, request later.
        let orphans = Activity<BackupActivityAttributes>.activities
        if !orphans.isEmpty {
            Self.log.info("reaping \(orphans.count) orphan activit(y/ies) from a killed run")
        }
        for orphan in orphans {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(_ snapshot: BackupActivitySnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.warning("Live Activities are off for this app — no Dynamic Island this run")
            return
        }
        if current != nil {
            // An activity is already in flight (e.g. the BG handler started
            // it and the foreground VM kicked another run): reuse it instead
            // of requesting a second activity. Concurrent same-app activities
            // pile up and the island renders them unreliably — one activity,
            // updated by whichever run is live, keeps the island visible.
            update(snapshot)
            return
        }
        do {
            let activity = try Activity.request(
                attributes: BackupActivityAttributes(totalCount: snapshot.total),
                content: ActivityContent(
                    state: Self.contentState(from: snapshot),
                    staleDate: nil,
                    relevanceScore: Self.relevance
                )
            )
            current = activity
            // `log stream --predicate 'category == "backup-activity"'` answers
            // "did the island ever exist, and did the system keep it?" without
            // guessing: the state stream reports stale/ended/dismissed too.
            Self.log.info("activity started id=\(activity.id, privacy: .public) total=\(snapshot.total)")
            Task {
                for await state in activity.activityStateUpdates {
                    Self.log.info("activity \(activity.id, privacy: .public) state=\(String(describing: state), privacy: .public)")
                }
            }
        } catch {
            // Swallowing this with `try?` is how a missing island stays
            // invisible for a whole debugging session.
            Self.log.error("Activity.request failed: \(PublicLogText.describe(error), privacy: .public)")
        }
    }

    func update(_ snapshot: BackupActivitySnapshot) {
        guard let current else { return }
        Task {
            await current.update(ActivityContent(
                state: Self.contentState(from: snapshot),
                staleDate: nil,
                relevanceScore: Self.relevance
            ))
        }
    }

    func end(success: Bool, snapshot: BackupActivitySnapshot) {
        guard let current else { return }
        var final = snapshot
        final.phase = snapshot.phase == .cancelled ? .cancelled : .done
        if success {
            final.progress = 1
            final.failed = 0
        }
        Task {
            // The run is over: the Live Activity disappears immediately —
            // progress has nowhere left to go and the island/panel must not
            // linger.
            await current.end(
                ActivityContent(state: Self.contentState(from: final), staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
        Self.log.info("activity ended id=\(current.id, privacy: .public) processed=\(snapshot.processed)/\(snapshot.total) success=\(success)")
        self.current = nil
    }

    private static func contentState(from snapshot: BackupActivitySnapshot) -> BackupActivityAttributes.ContentState {
        BackupActivityAttributes.ContentState(
            progress: snapshot.progress,
            processed: snapshot.processed,
            total: snapshot.total,
            uploaded: snapshot.uploaded,
            onServer: snapshot.onServer,
            waiting: snapshot.waiting,
            failed: snapshot.failed,
            phase: snapshot.phase,
            fileName: snapshot.fileName,
            estimatedDone: snapshot.estimatedDone
        )
    }
}
