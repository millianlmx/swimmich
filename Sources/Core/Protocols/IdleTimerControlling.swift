import Foundation

/// Seam over the system's automatic screen lock (`isIdleTimerDisabled`).
/// `true` keeps the screen on while the app is in the foreground. The
/// slideshow is its only writer; tests substitute a fake.
@MainActor
protocol IdleTimerControlling: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
}
