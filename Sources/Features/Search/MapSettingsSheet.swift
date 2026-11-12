import SwiftUI

/// Map settings sheet (gap G14b) — presented by the map segment.
///
/// A `Form` of native cells, **not** a navigation screen: it is a sheet like
/// `AdjustLocationSheet` / `LanguageSettingsView`, so it declares no
/// `NavigationStack` (two navigation bars otherwise).
///
/// Edits go to a local `draft` and are applied once, when the sheet closes —
/// toggling three switches must not fire three full-catalogue refetches. Swipe
/// down applies too: there is no silent cancel. The theme is the exception: it
/// is not part of the filter, so it is written to the store as it is picked and
/// the map behind the sheet repaints immediately.
struct MapSettingsSheet: View {
    @Bindable var store: MapSettingsStore
    /// Called with the edited filter on Done / swipe-down.
    let onApply: (MapMarkerFilter) -> Void
    /// Called after `onApply` when the sheet closed itself (Done).
    let onClose: () -> Void

    /// Local draft — nothing is applied until the sheet closes.
    @State private var draft: MapMarkerFilter
    /// Guards the two close paths (Done and swipe-down) from applying twice.
    @State private var applied = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Upstream `map_custom_time_range.dart` opens its pickers at
    /// `firstDate: DateTime(1970)`; the upper bound is today.
    private static let firstDate = Date(timeIntervalSince1970: 0)
    /// Preset list of the time dropdown: "All" plus the upstream entries.
    private static let presetDays = [0, 1, 7, 30, 365, 1095]
    /// Window a custom range starts from when the preset is "All" (nothing to
    /// pre-fill) — never leave the two pickers empty on first reveal.
    private static let defaultCustomDays = 30

    init(
        store: MapSettingsStore,
        onApply: @escaping (MapMarkerFilter) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.onApply = onApply
        self.onClose = onClose
        _draft = State(initialValue: store.filter)
    }

    var body: some View {
        Form {
            themeSection
            markersSection
            dateRangeSection
        }
        // Mirrors upstream's "remove custom date range": drops both bounds and
        // the relative preset in one action.
        .safeAreaInset(edge: .bottom) { doneBar }
        .interactiveDismissDisabled(!draft.isValid)
        .onDisappear {
            // Swipe-down closes the sheet without calling `finish()`; applying
            // here keeps both exits equivalent.
            if !applied, draft.isValid { onApply(draft) }
        }
    }

    // MARK: - Sections

    private var themeSection: some View {
        Section("Appearance") {
            themePicker
                .accessibilityIdentifier("mapSettingsThemePicker")
        }
    }

    /// Three segments no longer fit side by side at accessibility sizes: the
    /// picker becomes a menu there.
    @ViewBuilder
    private var themePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Appearance", selection: themeBinding) {
                Text("System").tag(MapTheme.system)
                Text("Light").tag(MapTheme.light)
                Text("Dark").tag(MapTheme.dark)
            }
            .pickerStyle(.menu)
        } else {
            Picker("Appearance", selection: themeBinding) {
                Text("System").tag(MapTheme.system)
                Text("Light").tag(MapTheme.light)
                Text("Dark").tag(MapTheme.dark)
            }
            .pickerStyle(.segmented)
        }
    }

    private var markersSection: some View {
        Section("Markers") {
            Toggle("Only show favorites", isOn: $draft.onlyFavorites)
                .accessibilityIdentifier("mapSettingsFavoritesToggle")
            Toggle("Include archived", isOn: $draft.includeArchived)
                .accessibilityIdentifier("mapSettingsArchivedToggle")
            Toggle("Include partners", isOn: $draft.withPartners)
                .accessibilityIdentifier("mapSettingsPartnersToggle")
        }
    }

    private var dateRangeSection: some View {
        Section("Date range") {
            Picker("Show", selection: presetBinding) {
                ForEach(Self.presetDays, id: \.self) { days in
                    Text(Self.presetLabel(days: days)).tag(days)
                }
            }
            .accessibilityIdentifier("mapSettingsRangePicker")

            if usesCustomRange {
                boundRow(
                    "After",
                    date: draft.from,
                    set: { draft.from = $0 },
                    clear: { draft.from = nil },
                    pickerID: "mapSettingsFromDate",
                    clearID: "mapSettingsClearFrom",
                    clearLabel: "Clear start date"
                )
                boundRow(
                    "Before",
                    date: draft.to,
                    set: { draft.to = $0 },
                    clear: { draft.to = nil },
                    pickerID: "mapSettingsToDate",
                    clearID: "mapSettingsClearTo",
                    clearLabel: "Clear end date"
                )
                if !draft.isValid {
                    InlineErrorBadge(message: String(localized: "The start date is after the end date"))
                        .accessibilityIdentifier("mapSettingsRangeError")
                }
            }

            Toggle(isOn: customRangeBinding) {
                Text(customRangeLabel)
            }
            .accessibilityIdentifier("mapSettingsCustomRangeButton")
        }
    }

    private var doneBar: some View {
        Button("Done") { finish() }
            .buttonStyle(PVPrimaryButtonStyle())
            .disabled(!draft.isValid)
            .accessibilityIdentifier("mapSettingsDoneButton")
            .padding(.horizontal, PVSpacing.s16)
            .padding(.vertical, PVSpacing.s12)
            .background(.bar)
    }

    // MARK: - Rows

    /// One custom bound. The ✕ is a separate interactive element (its own
    /// identifier — never on the row, which would swallow it), and a cleared
    /// bound comes back as an "Add" affordance so the picker never shows a date
    /// the filter doesn't carry.
    @ViewBuilder
    private func boundRow(
        _ title: LocalizedStringKey,
        date: Date?,
        set: @escaping (Date) -> Void,
        clear: @escaping () -> Void,
        pickerID: String,
        clearID: String,
        clearLabel: LocalizedStringKey
    ) -> some View {
        PVAdaptiveStack(hAlignment: .center, spacing: PVSpacing.s8) {
            if let date {
                DatePicker(
                    title,
                    selection: Binding(get: { date }, set: set),
                    in: Self.firstDate...Date(),
                    displayedComponents: .date
                )
                .accessibilityIdentifier(pickerID)
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textSecondaryPV)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
                .accessibilityIdentifier(clearID)
            } else {
                Text(title)
                Spacer()
                Button("Add") { set(Date()) }
                    .accessibilityIdentifier(pickerID)
            }
        }
    }

    // MARK: - Bindings

    private var themeBinding: Binding<MapTheme> {
        Binding(get: { store.theme }, set: { store.setTheme($0) })
    }

    /// `nil`/`0` are the same "All" entry: the presets are stored as `Int`, so
    /// the picker needs no optional tag.
    private var presetBinding: Binding<Int> {
        Binding(
            get: { draft.relativeDays },
            set: { days in
                draft.relativeDays = days
                // Preset and custom range exclude each other.
                draft.from = nil
                draft.to = nil
            }
        )
    }

    private var usesCustomRange: Bool { draft.from != nil || draft.to != nil }

    /// Upstream flips the same control between "use" and "remove": the second
    /// label is how a custom range is dropped without touching a ✕.
    private var customRangeLabel: LocalizedStringKey {
        usesCustomRange ? "Remove custom date range" : "Use custom date range"
    }

    private var customRangeBinding: Binding<Bool> {
        Binding(
            get: { usesCustomRange },
            set: { on in
                if on {
                    // Pre-fill with the current preset's window so both rows
                    // show a real date the moment they appear.
                    let days = draft.relativeDays > 0 ? draft.relativeDays : Self.defaultCustomDays
                    let now = Date()
                    draft.from = Calendar.current.startOfDay(
                        for: now.addingTimeInterval(-Double(days) * 86_400)
                    )
                    draft.to = Calendar.current.startOfDay(for: now)
                    draft.relativeDays = 0
                } else {
                    draft.relativeDays = 0
                    draft.from = nil
                    draft.to = nil
                }
            }
        )
    }

    // MARK: - Labels

    /// Reuses the catalog entries the filter summary also uses, so the picker
    /// and the badge can't name the same range differently.
    private static func presetLabel(days: Int) -> LocalizedStringKey {
        switch days {
        case 1: "1 day"
        case 7: "7 days"
        case 30: "30 days"
        case 365: "1 year"
        case 1095: "3 years"
        default: "All"
        }
    }

    private func finish() {
        guard !applied else { return }
        applied = true
        onApply(draft)
        onClose()
    }
}
