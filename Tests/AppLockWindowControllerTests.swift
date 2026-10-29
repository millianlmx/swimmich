import SwiftUI
import UIKit
import XCTest
@testable import ImmichSwiftUI

/// Hosted in the app, so a real `UIWindowScene` is available. Each test builds
/// its own model + controller and its own `.normal` windows; everything is
/// hidden again in `tearDown`.
final class AppLockWindowControllerTests: XCTestCase {
    private static let suiteName = "AppLockWindowControllerTests"

    private var appWindows: [UIWindow] = []
    private var controllers: [AppLockWindowController] = []

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: AppLockViewModel.enabledKey)
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for controller in controllers {
                controller.apply(.none)
                controller.window?.layer.removeAllAnimations()
                controller.window?.isHidden = true
            }
            for window in appWindows {
                window.accessibilityElementsHidden = false
                window.isHidden = true
            }
            controllers.removeAll()
            appWindows.removeAll()
        }
        UserDefaults.standard.removeObject(forKey: AppLockViewModel.enabledKey)
    }

    // MARK: - Helpers

    @MainActor
    private var scene: UIWindowScene {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
    }

    /// Enabled, unlocked model + attached controller.
    @MainActor
    private func makeController(
        notifications: NotificationCenter = .default
    ) -> (vm: AppLockViewModel, controller: AppLockWindowController) {
        let suite = UserDefaults(suiteName: Self.suiteName)!
        let vm = AppLockViewModel(evaluator: { false })
        vm.setEnabled(true)
        let controller = AppLockWindowController(
            appLock: vm,
            language: AppLanguageStore(defaults: suite),
            appSettings: AppSettingsStore(defaults: suite),
            sceneNotifications: notifications
        )
        controller.attach(to: scene)
        controllers.append(controller)
        return (vm, controller)
    }

    @MainActor
    private func makeAppWindow() -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        appWindows.append(window)
        return window
    }

    @MainActor
    private func addTextField(to window: UIWindow, text: String = "abc") -> UITextField {
        let field = UITextField(frame: CGRect(x: 20, y: 100, width: 200, height: 40))
        field.text = text
        window.rootViewController!.view.addSubview(field)
        return field
    }

    @MainActor
    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    @MainActor
    private func waitUntilHidden(_ window: UIWindow) async {
        var attempts = 0
        while !window.isHidden, attempts < 200 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Window

    // AC-1: opaque window above alerts, full scene, never key.
    @MainActor
    func test_AC_1_lockShowsOpaqueWindowAboveAlert() throws {
        let (_, controller) = makeController()
        XCTAssertTrue(controller.window?.isHidden == true, "no cover while unlocked")
        controller.apply(.lock)

        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isHidden)
        XCTAssertEqual(window.windowLevel, .alert + 1)
        XCTAssertEqual(window.frame, scene.coordinateSpace.bounds)
        XCTAssertFalse(window.isKeyWindow)
        let background = try XCTUnwrap(window.rootViewController?.view.backgroundColor)
        XCTAssertEqual(background.resolvedColor(with: window.traitCollection).cgColor.alpha, 1)
    }

    // AC-5: alerts live in the app window, which sits below the lock window.
    @MainActor
    func test_AC_5_alertPresentedInAppWindowIsCovered() async throws {
        let (_, controller) = makeController()
        let appWindow = makeAppWindow()
        let alert = UIAlertController(title: "Delete?", message: nil, preferredStyle: .alert)
        appWindow.rootViewController!.present(alert, animated: false)
        await settle()

        controller.apply(.lock)
        let alertWindow = try XCTUnwrap(alert.view.window)
        let lockLevel = try XCTUnwrap(controller.window).windowLevel
        XCTAssertLessThan(alertWindow.windowLevel, lockLevel)
        XCTAssertTrue(alertWindow.accessibilityElementsHidden)
    }

    // AC-6: a full-screen presentation is still under the lock window.
    @MainActor
    func test_AC_6_fullScreenPresentationIsCovered() async throws {
        let (_, controller) = makeController()
        let appWindow = makeAppWindow()
        let presented = UIViewController()
        presented.modalPresentationStyle = .fullScreen
        appWindow.rootViewController!.present(presented, animated: false)
        await settle()

        controller.apply(.lock)
        let lockWindow = try XCTUnwrap(controller.window)
        let center = CGPoint(x: lockWindow.bounds.midX, y: lockWindow.bounds.midY)
        let hit = try XCTUnwrap(lockWindow.hitTest(center, with: nil))
        XCTAssertTrue(hit.window === lockWindow)
        let presentedWindow = try XCTUnwrap(presented.view.window)
        XCTAssertLessThan(presentedWindow.windowLevel, lockWindow.windowLevel)
    }

    // AC-7: every point of the screen is answered by the lock window.
    @MainActor
    func test_AC_7_lockWindowSwallowsTouches() throws {
        let (_, controller) = makeController()
        _ = makeAppWindow()
        controller.apply(.lock)

        let lockWindow = try XCTUnwrap(controller.window)
        let b = lockWindow.bounds
        let points = [
            CGPoint(x: b.minX + 1, y: b.minY + 1), CGPoint(x: b.maxX - 1, y: b.minY + 1),
            CGPoint(x: b.minX + 1, y: b.maxY - 1), CGPoint(x: b.maxX - 1, y: b.maxY - 1),
            CGPoint(x: b.midX, y: b.midY)
        ]
        for point in points {
            let hit = try XCTUnwrap(lockWindow.hitTest(point, with: nil), "\(point)")
            XCTAssertTrue(hit.window === lockWindow, "\(point)")
        }
    }

    // AC-8: VoiceOver only sees the lock; original accessibility state is restored.
    @MainActor
    func test_AC_8_otherWindowsHiddenFromAccessibility() throws {
        let (_, controller) = makeController()
        let visible = makeAppWindow()
        let alreadyHidden = makeAppWindow()
        alreadyHidden.accessibilityElementsHidden = true
        controller.apply(.lock)

        let lockWindow = try XCTUnwrap(controller.window)
        let late = makeAppWindow()
        for window in scene.windows where window !== lockWindow && !window.isHidden {
            XCTAssertTrue(window.accessibilityElementsHidden, "\(window)")
        }
        XCTAssertTrue(late.accessibilityElementsHidden, "window shown after the lock")

        controller.apply(.none)
        XCTAssertFalse(visible.accessibilityElementsHidden)
        XCTAssertFalse(late.accessibilityElementsHidden)
        XCTAssertTrue(alreadyHidden.accessibilityElementsHidden, "pre-existing hiding is kept")
    }

    // MARK: - Scene lifecycle

    // AC-11: willDeactivate masks at once; didEnterBackground locks; disabling hides.
    @MainActor
    func test_AC_11_sceneDeactivationShowsMaskSynchronously() async throws {
        let center = NotificationCenter()
        let (vm, controller) = makeController(notifications: center)
        let window = try XCTUnwrap(controller.window)

        center.post(name: UIScene.willDeactivateNotification, object: nil)
        XCTAssertEqual(controller.currentCover, .none)
        XCTAssertTrue(window.isHidden)

        center.post(name: UIScene.willDeactivateNotification, object: scene)
        XCTAssertEqual(controller.currentCover, .mask)
        XCTAssertFalse(window.isHidden)
        XCTAssertEqual(window.alpha, 1)
        XCTAssertFalse(window.isKeyWindow)

        center.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        XCTAssertEqual(controller.currentCover, .lock)

        vm.setEnabled(false)
        await waitUntilHidden(window)
        XCTAssertTrue(window.isHidden)
    }

    // AC-11: entering background drops the keyboard focus before the snapshot.
    @MainActor
    func test_AC_11_backgroundResignsFocusSynchronously() throws {
        let center = NotificationCenter()
        let (_, controller) = makeController(notifications: center)
        let field = addTextField(to: makeAppWindow())
        XCTAssertTrue(field.becomeFirstResponder())

        center.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        XCTAssertEqual(controller.currentCover, .lock)
        XCTAssertFalse(field.isFirstResponder)
    }

    // AC-12: the privacy mask never touches focus (Control Center round trip).
    @MainActor
    func test_AC_12_maskKeepsFirstResponder() {
        let (_, controller) = makeController()
        let field = addTextField(to: makeAppWindow())
        XCTAssertTrue(field.becomeFirstResponder())

        controller.apply(.mask)
        XCTAssertTrue(field.isFirstResponder)
        controller.apply(.none)
        XCTAssertTrue(field.isFirstResponder)
    }

    // AC-21: lock drops focus, refuses refocus (field and text view), keeps text.
    @MainActor
    func test_AC_21_lockResignsAndBlocksRefocus() {
        let (_, controller) = makeController()
        let window = makeAppWindow()
        let field = addTextField(to: window, text: "abc")
        let textView = UITextView(frame: CGRect(x: 20, y: 200, width: 200, height: 80))
        textView.text = "def"
        window.rootViewController!.view.addSubview(textView)
        XCTAssertTrue(field.becomeFirstResponder())

        controller.apply(.lock)
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertEqual(field.text, "abc")

        _ = field.becomeFirstResponder()
        XCTAssertFalse(field.isFirstResponder, "refocus while locked must be cancelled")
        _ = textView.becomeFirstResponder()
        XCTAssertFalse(textView.isFirstResponder, "refocus while locked must be cancelled")
        XCTAssertEqual(textView.text, "def")

        controller.apply(.none)
        XCTAssertTrue(field.becomeFirstResponder())
    }
}
