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
    let appLock: AppLockViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isLock = appLock.cover == .lock
        ZStack {
            Color.bgPrimary.ignoresSafeArea()

            VStack(spacing: PVSpacing.s24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 56)) // DS-exempt: hero illustration §8.6
                    .foregroundStyle(Color.textSecondaryPV)
                if isLock {
                    Text("PhotoVault Locked")
                        .font(.pvTitle)
                    Button {
                        Task { _ = await appLock.authenticate() }
                    } label: {
                        Label("Unlock", systemImage: "faceid")
                    }
                    .buttonStyle(PVPrimaryButtonStyle())
                    .accessibilityIdentifier("appLockUnlockButton")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isLock ? "AppLockOverlay" : "AppLockPrivacyMask")
        .animation(PVMotion.adaptive(PVMotion.gentle, reduceMotion: reduceMotion), value: appLock.cover)
    }
}
