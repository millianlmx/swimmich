import SwiftUI

/// Root of the lock window's SwiftUI content. Reads language and theme in its
/// own `body` so the lock follows them by Observation, like the app window
/// (the lock window sits outside `RootView`'s environment).
struct AppLockCoverRoot: View {
    let appLock: AppLockViewModel
    let language: AppLanguageStore
    let appSettings: AppSettingsStore

    var body: some View {
        AppLockCoverView(appLock: appLock)
            .environment(\.locale, language.effectiveLocale)
            .preferredColorScheme(appSettings.theme.colorScheme)
            .tint(appSettings.accent.color)
    }
}

/// Opaque cover: the lock (title + Unlock button) or the bare privacy mask
/// shown while the app is `.inactive`. Anything but `.lock` — `.none` during
/// the window's fade-out included — renders the mask.
struct AppLockCoverView: View {
    /// The lock screen's title. A resource, so tests can check its catalog key.
    static let title: LocalizedStringResource = "Swimmich Locked"
    let appLock: AppLockViewModel
    @PVReduceMotion private var reduceMotion

    var body: some View {
        let isLock = appLock.cover == .lock
        ZStack {
            Color.bgPrimary.ignoresSafeArea()

            // Scrolls when the prompt outgrows the screen (large text); centred
            // when it fits, by a clear spacer as tall as the visible area.
            ScrollView {
                ZStack {
                    Color.clear
                        .containerRelativeFrame(.vertical)
                    if isLock {
                        AppLockPrompt(
                            onUnlock: { Task { _ = await appLock.authenticate() } },
                            reason: appLock.failure?.reason,
                            buttonTitle: appLock.unlockButtonTitle
                        )
                    } else {
                        AppLockGlyph()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isLock ? "AppLockOverlay" : "AppLockPrivacyMask")
        .animation(PVMotion.movement(PVMotion.gentle, reduceMotion: reduceMotion), value: appLock.cover)
        .animation(PVMotion.movement(PVMotion.gentle, reduceMotion: reduceMotion), value: appLock.failure)
        // VoiceOver reads the reason as soon as it appears (AC-803).
        .onChange(of: appLock.failure) { _, failure in
            guard let failure else { return }
            AccessibilityNotification.Announcement(String(localized: failure.reason)).post()
        }
    }
}

private struct AppLockGlyph: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 56)) // DS-exempt: hero illustration §8.6
            .foregroundStyle(Color.textSecondaryPV)
    }
}

/// The lock's content: glyph, title, the reason the last attempt failed (when
/// there is one) and the single Unlock / Try Again button. Everything wraps at
/// large text sizes; the parent scrolls when the content outgrows the screen.
struct AppLockPrompt: View {
    let onUnlock: () -> Void
    var reason: LocalizedStringResource?
    var buttonTitle: LocalizedStringResource = "Unlock"

    var body: some View {
        VStack(spacing: PVSpacing.s24) {
            AppLockGlyph()
            Text(AppLockCoverView.title)
                .font(.pvTitle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("appLockTitle")
            if let reason {
                Text(reason)
                    .font(.pvBody)
                    .foregroundStyle(Color.textSecondaryPV)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("appLockFailureReason")
                    .transition(.opacity)
            }
            Button(action: onUnlock) {
                Label { Text(buttonTitle) } icon: { Image(systemName: "faceid") }
            }
            .buttonStyle(PVPrimaryButtonStyle())
            .accessibilityIdentifier("appLockUnlockButton")
        }
        .padding(.horizontal, PVSpacing.s24)
    }
}
