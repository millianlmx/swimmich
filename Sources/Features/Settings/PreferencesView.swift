import SwiftUI

/// The Preferences screen (settings-parity, gap G22) — reached from the "Me"
/// hub's General section, so it deliberately carries **no** `NavigationStack`
/// of its own (same convention as `LanguageSettingsView`, `OfflineAssetsView`,
/// `StackView`: the hub's stack is already there, and a second one would draw a
/// second navigation bar).
///
/// One `Form`, six sections, one row per control. Every row is bound to
/// `PreferencesViewModel`, which is a pass-through to `AppSettingsStore` — the
/// same store the timeline, the viewer, the video player and the slideshow
/// read, so nothing here can disagree with what those screens do.
///
/// No glass and no custom surface: this is a service page, not a discovery one.
struct PreferencesView: View {
    @Bindable var vm: PreferencesViewModel

    @State private var showResetConfirm = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The accent swatch grows with the row's text (16 pt by default).
    @ScaledMetric(relativeTo: .body) private var swatch: CGFloat = 16

    var body: some View {
        Form {
            Section {
                Picker("Group By", selection: $vm.groupBy) {
                    ForEach(TimelineGroupBy.allCases) { grouping in
                        Text(grouping.label).tag(grouping)
                    }
                }
                .accessibilityIdentifier("preferencesGroupPicker")

                Stepper(value: $vm.tilesPerRow, in: 2...7) {
                    LabeledContent("Columns") {
                        Text("\(vm.tilesPerRow)")
                            .font(.pvNumeric)
                            .foregroundStyle(Color.textSecondaryPV)
                    }
                }
                .accessibilityIdentifier("preferencesColumnsStepper")

                Toggle("Smooth Scrubbing", isOn: $vm.smoothScrubbing)
                    .accessibilityIdentifier("preferencesSmoothScrubbingToggle")
            } header: {
                Text("Photos")
            } footer: {
                Text("When on, releasing the date scrubber stops at the exact spot in the month. When off, it snaps to the month's first photo.")
            }

            Section("Viewer") {
                Toggle("Load Full Quality", isOn: $vm.loadOriginal)
                    .accessibilityIdentifier("preferencesLoadOriginalToggle")

                Toggle("Tap to Navigate", isOn: $vm.tapToNavigate)
                    .accessibilityIdentifier("preferencesTapToNavigateToggle")
            }

            Section {
                sharePicker
                    .accessibilityIdentifier("preferencesShareQualityPicker")
            } header: {
                Text("Sharing")
            } footer: {
                Text("Used when you share from the viewer. Press and hold the Share button to choose for a single share. Videos are always shared in their original quality.")
            }

            Section("Video") {
                Toggle("Auto-Play", isOn: $vm.autoPlayVideo)
                    .accessibilityIdentifier("preferencesAutoPlayToggle")

                Toggle("Loop", isOn: $vm.loopVideo)
                    .accessibilityIdentifier("preferencesLoopVideoToggle")

                Toggle("Stream Original", isOn: $vm.loadOriginalVideo)
                    .accessibilityIdentifier("preferencesOriginalVideoToggle")
            }

            Section("Slideshow") {
                Toggle("Repeat", isOn: $vm.slideshowRepeat)
                    .accessibilityIdentifier("preferencesSlideshowRepeatToggle")

                Picker("Speed", selection: $vm.slideshowSpeed) {
                    ForEach(SlideshowViewModel.SlideshowSpeed.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .accessibilityIdentifier("preferencesSlideshowSpeedPicker")

                Picker("Look", selection: $vm.slideshowLook) {
                    ForEach(SlideshowViewModel.SlideshowTransitionStyle.allCases) { look in
                        Text(look.label).tag(look)
                    }
                }
                .accessibilityIdentifier("preferencesSlideshowLookPicker")

                Toggle("Reverse Order", isOn: $vm.slideshowReverse)
                    .accessibilityIdentifier("preferencesSlideshowReverseToggle")
            }

            Section("Appearance") {
                Picker("Theme", selection: $vm.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .accessibilityIdentifier("preferencesThemePicker")

                Picker("Accent Color", selection: $vm.accent) {
                    ForEach(AppAccent.allCases) { preset in
                        Label {
                            Text(preset.label)
                        } icon: {
                            // Decorative: the row must announce "Accent Color,
                            // Blue", not "Accent Color, circle".
                            Circle()
                                .fill(preset.color)
                                .frame(width: swatch, height: swatch)
                                .accessibilityHidden(true)
                        }
                        .tag(preset)
                    }
                }
                .accessibilityIdentifier("preferencesAccentPicker")
            }

            Section("Feedback") {
                Toggle("Haptic Feedback", isOn: $vm.hapticsEnabled)
                    .accessibilityIdentifier("preferencesHapticsToggle")
            }

            Section {
                Button("Reset", role: .destructive) {
                    showResetConfirm = true
                }
                .accessibilityIdentifier("preferencesResetButton")
            } footer: {
                Text("Puts every preference on this screen back to its default.")
            }
        }
        .labeledContentStyle(.pvAdaptive)
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        // Destructive and confirmed: the reset is not undoable, and it is a
        // swipe away from a row the user may have tapped by accident.
        .confirmationDialog("Reset Preferences?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { vm.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Two segments fit everywhere except at accessibility sizes, where the
    /// picker becomes a menu so no label is truncated (`MapSettingsSheet`).
    @ViewBuilder
    private var sharePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Share Quality", selection: $vm.shareQuality) {
                ForEach(ShareQuality.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
        } else {
            Picker("Share Quality", selection: $vm.shareQuality) {
                ForEach(ShareQuality.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}
