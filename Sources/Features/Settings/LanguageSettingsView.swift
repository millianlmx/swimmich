import SwiftUI

/// Interface-language picker (issue #21) — reached from the "Me" hub.
///
/// Swimmich follows the device language by default; this screen pins one instead.
/// `AppLanguageStore` owns the choice, the picker only renders it — plus the one
/// consequence worth spelling out: iOS resolves a bundle's localizations at
/// launch, so part of the text follows only after a reopen, which is what the
/// `LanguageToast` overlay states.
///
/// Pushed from `ProfileView`'s `NavigationStack`, so it deliberately carries no
/// `NavigationStack` of its own (same convention as `TrashView`, `StackView`).
struct LanguageSettingsView: View {
    @Bindable var vm: LanguageSettingsViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
            Section {
                ForEach(vm.languages) { language in
                    languageRow(language)
                }
            } header: {
                Text("App Language")
            } footer: {
                Text("The language Swimmich's interface uses. A change takes effect the next time you open the app.")
            }

            Section {
                Toggle(isOn: systemLanguageBinding) {
                    Label("Use System Language", systemImage: "globe")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("useSystemLanguageToggle")
            } footer: {
                Text("Follows the language set in iOS Settings.")
            }
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if vm.requiresRelaunch {
                LanguageToast(onDismiss: { vm.dismissRelaunchPrompt() })
                    .padding(.bottom, PVSpacing.s16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(PVMotion.adaptive(PVMotion.gentle, reduceMotion: reduceMotion), value: vm.requiresRelaunch)
    }

    /// The picker row: the language named as this device would write it, the
    /// language's own name underneath (Apple's Language & Region layout), and a
    /// checkmark on the pinned one.
    @ViewBuilder
    private func languageRow(_ language: AppLanguage) -> some View {
        let isSelected = vm.isSelected(language)

        Button {
            vm.select(language)
        } label: {
            HStack(spacing: PVSpacing.s12) {
                VStack(alignment: .leading, spacing: PVSpacing.s2) {
                    // Verbatim: both names are resolved at runtime through
                    // `Locale` by `AppLanguage`, so they are data, not keys.
                    Text(verbatim: language.displayName)
                        .font(.pvBody)
                        .foregroundStyle(Color.textPrimaryPV)
                    Text(verbatim: language.nativeName)
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }

                Spacer(minLength: PVSpacing.s8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.pvHeadline)
                        .foregroundStyle(Color.immichPrimary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Select language: \(language.displayName)"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("languageRow.\(language.code)")
    }

    /// The Toggle writes through the view model (switching it off pins the
    /// language currently on screen), so it cannot be a `@Bindable` projection.
    private var systemLanguageBinding: Binding<Bool> {
        Binding(
            get: { vm.useSystemLanguage },
            set: { vm.setUseSystemLanguage($0) }
        )
    }
}
