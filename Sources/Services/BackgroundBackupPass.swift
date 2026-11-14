import Foundation

/// One background backup pass (L-26): the address is evaluated first, so the
/// upload goes to the address that answers now (the external one when the local
/// address, retained earlier, is out of reach), and only then does the engine run.
struct BackgroundBackupPass {
    let evaluate: @MainActor () async -> Void
    let runBackup: @MainActor () async -> Void

    @MainActor
    func run() async {
        await evaluate()
        await runBackup()
    }
}
