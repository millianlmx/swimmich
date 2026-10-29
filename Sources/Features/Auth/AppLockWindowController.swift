import SwiftUI
import UIKit

/// Owns the dedicated UIKit window that carries the App Lock cover.
///
/// A SwiftUI overlay in `RootView` cannot cover `.sheet` / `.fullScreenCover`
/// / alerts: UIKit presents them above the whole hosting hierarchy. A window at
/// `.alert + 1` sits above every presentation of the app window. It is driven
/// synchronously by `AppLockViewModel.onCoverChange` and by the UIKit scene
/// notifications, so the cover is on screen before iOS captures the
/// app-switcher snapshot (QA1838). It is never key (share sheet and OAuth
/// presenters pick the key window).
@MainActor
final class AppLockWindowController {
    private struct WeakWindow { weak var window: UIWindow? }

    private let appLock: AppLockViewModel
    private let language: AppLanguageStore
    private let appSettings: AppSettingsStore
    private let sceneNotifications: NotificationCenter
    private weak var scene: UIWindowScene?
    /// Windows whose accessibility we hid; only those flipped from `false`.
    private var hiddenWindows: [WeakWindow] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private(set) var window: UIWindow?
    private(set) var currentCover: AppLockCover = .none

    init(
        appLock: AppLockViewModel,
        language: AppLanguageStore,
        appSettings: AppSettingsStore,
        sceneNotifications: NotificationCenter = .default
    ) {
        self.appLock = appLock
        self.language = language
        self.appSettings = appSettings
        self.sceneNotifications = sceneNotifications

        // While locked, a field that grabs focus (programmatic focus such as
        // the locked-folder PIN, or iOS restoring the keyboard) is dropped at
        // once: the keyboard lives in its own window above the lock.
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            observe(.default, name, object: nil) { [weak self] note in
                let field = note.object as? UIView
                MainActor.assumeIsolated { self?.fieldDidBeginEditing(field) }
            }
        }
        observe(.default, UIWindow.didBecomeVisibleNotification, object: nil) { [weak self] note in
            let shown = note.object as? UIWindow
            MainActor.assumeIsolated { self?.windowDidBecomeVisible(shown) }
        }
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    func attach(to scene: UIWindowScene) {
        guard window == nil else { return }
        self.scene = scene

        let background = UIColor(named: "BgPrimary")
        let lockWindow = UIWindow(windowScene: scene)
        lockWindow.windowLevel = .alert + 1
        lockWindow.backgroundColor = background
        lockWindow.isHidden = true
        let host = UIHostingController(
            rootView: AppLockCoverRoot(appLock: appLock, language: language, appSettings: appSettings)
        )
        host.view.backgroundColor = background
        host.view.accessibilityViewIsModal = true
        host.loadViewIfNeeded()
        lockWindow.rootViewController = host
        window = lockWindow

        // `.active` stays driven by SwiftUI; these two must not wait for it.
        observe(sceneNotifications, UIScene.willDeactivateNotification, object: scene) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.appLock.scenePhaseChanged(to: .inactive) }
        }
        observe(sceneNotifications, UIScene.didEnterBackgroundNotification, object: scene) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.appLock.scenePhaseChanged(to: .background) }
        }
        appLock.onCoverChange = { [weak self] in self?.apply($0) }
        apply(appLock.cover)
    }

    func apply(_ cover: AppLockCover) {
        currentCover = cover
        guard let window else { return }
        switch cover {
        case .mask, .lock:
            window.layer.removeAllAnimations()
            window.alpha = 1
            window.isHidden = false
            hideOtherWindowsFromAccessibility()
            if cover == .lock { resignFocusInOtherWindows() }
        case .none:
            restoreAccessibility()
            guard !window.isHidden else { return }
            if UIAccessibility.isReduceMotionEnabled {
                window.isHidden = true
            } else {
                UIView.animate(withDuration: 0.25) {
                    window.alpha = 0
                } completion: { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.currentCover == .none else { return }
                        window.isHidden = true
                        window.alpha = 1
                    }
                }
            }
        }
    }

    // MARK: - Other windows

    private var otherWindows: [UIWindow] {
        (scene?.windows ?? []).filter { $0 !== window }
    }

    private func hideOtherWindowsFromAccessibility() {
        for other in otherWindows where !other.isHidden { hideFromAccessibility(other) }
    }

    private func hideFromAccessibility(_ other: UIWindow) {
        guard !other.accessibilityElementsHidden else { return }
        other.accessibilityElementsHidden = true
        hiddenWindows.append(WeakWindow(window: other))
    }

    private func restoreAccessibility() {
        for entry in hiddenWindows { entry.window?.accessibilityElementsHidden = false }
        hiddenWindows.removeAll()
    }

    /// Synchronous and animation-free so the stored snapshot has no keyboard.
    private func resignFocusInOtherWindows() {
        UIView.performWithoutAnimation {
            for other in otherWindows { other.endEditing(true) }
        }
    }

    private func fieldDidBeginEditing(_ field: UIView?) {
        guard currentCover == .lock, let field, field.window !== window else { return }
        field.resignFirstResponder()
    }

    private func windowDidBecomeVisible(_ shown: UIWindow?) {
        guard currentCover != .none, let shown, shown !== window,
              shown.windowScene === scene else { return }
        hideFromAccessibility(shown)
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        object: AnyObject?,
        _ handler: @escaping @Sendable (Notification) -> Void
    ) {
        observers.append((center, center.addObserver(forName: name, object: object, queue: nil, using: handler)))
    }
}

/// Transparent, inert anchor placed in `RootView`'s background. It only exists
/// to learn the `UIWindowScene` and hand it to the controller; the controller
/// lives as long as the view's coordinator.
struct AppLockWindowInstaller: UIViewRepresentable {
    let appLock: AppLockViewModel
    let language: AppLanguageStore
    let appSettings: AppSettingsStore

    func makeCoordinator() -> AppLockWindowController {
        AppLockWindowController(appLock: appLock, language: language, appSettings: appSettings)
    }

    func makeUIView(context: Context) -> UIView {
        let view = InstallerView()
        view.controller = context.coordinator
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class InstallerView: UIView {
        var controller: AppLockWindowController?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { controller?.attach(to: scene) }
        }
    }
}
