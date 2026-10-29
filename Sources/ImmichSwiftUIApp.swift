import BackgroundTasks
import SwiftUI
import WidgetKit

@main
struct ImmichSwiftUIApp: App {
    @State private var container = DependencyContainer.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .onChange(of: scenePhase) { _, phase in
                    container.appLock.scenePhaseChanged(to: phase)
                    switch phase {
                    case .background:
                        // No PhotoLibrary observer outside the foreground: it
                        // cannot fire usefully there, and it would race the
                        // BGTask window's own run.
                        container.libraryMonitor.stop()
                    case .active:
                        // "Upload at launch / on return": kick the gated
                        // engine directly when auto-backup is configured,
                        // then keep the pending background request alive so
                        // the next OS window picks up anything new.
                        container.kickOffAutoBackup()
                        container.syncLibraryMonitor()
                        if container.isAutoBackupEnabled() {
                            container.backupScheduler.submit()
                        }
                        // Ask WidgetKit for fresh timelines whenever the app
                        // comes up: the widget's own schedule is opaque (and a
                        // widget added before an extension update can sit on its
                        // placeholder without ever being re-queried).
                        WidgetCenter.shared.reloadAllTimelines()
                    default:
                        break
                    }
                }
                .onAppear {
                    // Cold launch: `onChange` does not deliver the initial phase.
                    container.appLock.scenePhaseChanged(to: scenePhase)
                    registerBackgroundBackup()
                    // The widget chain's only device-only link: whether the
                    // embedded appex is authorised for the app's keychain group.
                    // One line at `notice` so it shows without enabling Info/Debug.
                    _ = WidgetExtensionProbe.report()
                }
        }
    }

    /// Registers the one-shot background processing task. Launched by the OS
    /// at its discretion (low priority, network required). The pending
    /// request is re-submitted FIRST (shared scheduler instance) so the
    /// self-perpetuating chain survives even if the run is killed, expires
    /// or the process is terminated mid-flight — a run that never finishes
    /// is still retried on the next OS window.
    private func registerBackgroundBackup() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BGTaskBackupScheduler.taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else { return }
            if container.isAutoBackupEnabled() {
                container.backupScheduler.submit()
            }
            let upload = container.upload
            task.expirationHandler = {
                upload.engine.cancel()
            }
            Task {
                await upload.runBackup()
                // New photos landed: the widget is showing the library.
                WidgetCenter.shared.reloadAllTimelines()
                task.setTaskCompleted(
                    success: upload.engine.phase == .done && upload.engine.failedCount == 0
                )
            }
        }
    }
}
