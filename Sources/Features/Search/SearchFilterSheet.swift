import SwiftUI

/// The Filters sheet of the Search tab (search-filters): every constraint the
/// tab can send.
///
/// The sheet holds **no logic**: its controls write `vm.filter.*`; the requests
/// are the ViewModel's (`applyFilters()` on Done, `clearFilters()` on Reset).
/// Nothing here knows the client or builds a body.
///
/// It declares its own `NavigationStack` because it is presented *over* the
/// Search tab (whose stack lives in `SearchView`), not pushed from the "Me" hub.
struct SearchFilterSheet: View {
    @PVReduceMotion private var reduceMotion
    @Bindable var vm: SearchViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Rating") {
                    ratingRow
                    if vm.filter.rating != nil {
                        Button("Clear") { vm.filter.rating = nil }
                            .accessibilityIdentifier("searchFilterRatingClear")
                    }
                }

                Section {
                    TextField("Detected text", text: text($vm.filter.ocrText))
                        .accessibilityIdentifier("searchFilterOCR")
                } header: {
                    Text("OCR text")
                } footer: {
                    // A criterion the server has no field for is not offered:
                    // the structured `filter` is the only field for it, and the
                    // server refuses a body that mixes it with the flat fields
                    // a pre-v3.2.0 server would need.
                    if !vm.supportsStructuredSearch {
                        Text("Detected text search requires Immich \(SearchViewModel.structuredSearchMinimumLabel) or later.")
                            .accessibilityIdentifier("searchFilterVersionNotice")
                    }
                }
                .disabled(!vm.supportsStructuredSearch)

                Section("Location") {
                    TextField("City", text: text($vm.filter.city))
                        .accessibilityIdentifier("searchFilterCity")
                    TextField("State", text: text($vm.filter.state))
                        .accessibilityIdentifier("searchFilterState")
                    TextField("Country", text: text($vm.filter.country))
                        .accessibilityIdentifier("searchFilterCountry")
                }

                Section("Camera") {
                    TextField("Make", text: text($vm.filter.make))
                        .accessibilityIdentifier("searchFilterMake")
                    TextField("Model", text: text($vm.filter.model))
                        .accessibilityIdentifier("searchFilterModel")
                    TextField("Lens", text: text($vm.filter.lensModel))
                        .accessibilityIdentifier("searchFilterLens")
                }

                Section("Type & Favourites") {
                    Picker("Type", selection: $vm.filter.type) {
                        Text("Any").tag(String?.none)
                        Text("Photos").tag(String?.some(SearchFilter.photoType))
                        Text("Videos").tag(String?.some(SearchFilter.videoType))
                    }
                    .accessibilityIdentifier("searchFilterType")

                    Toggle("Favourites", isOn: favorite)
                        .accessibilityIdentifier("searchFilterFavorite")
                }

                Section("Dates") {
                    Toggle("Taken after", isOn: dateToggle($vm.filter.takenAfter))
                        .accessibilityIdentifier("searchFilterTakenAfter")
                    if vm.filter.takenAfter != nil {
                        DatePicker("From", selection: date($vm.filter.takenAfter), displayedComponents: .date)
                            .accessibilityIdentifier("searchFilterTakenAfterPicker")
                    }
                    Toggle("Taken before", isOn: dateToggle($vm.filter.takenBefore))
                        .accessibilityIdentifier("searchFilterTakenBefore")
                    if vm.filter.takenBefore != nil {
                        DatePicker("To", selection: date($vm.filter.takenBefore), displayedComponents: .date)
                            .accessibilityIdentifier("searchFilterTakenBeforePicker")
                    }
                }
            }
            .task {
                // The capabilities of the connected server decide what this
                // sheet can offer (the probe is cached in the ViewModel).
                await vm.probeSearchShape()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The sheet's own name lives on the app bar: an identifier on
                // the `Form` would propagate down and erase every control's own
                // (measured on `languageRelaunchToast`), while the app bar is a
                // single combined element with no identified descendants.
                ToolbarItem(placement: .principal) {
                    ImmichAppBar(title: "Filters")
                        .accessibilityIdentifier("searchFilterSheet")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { Task { await vm.clearFilters() } }
                        .accessibilityIdentifier("searchFilterReset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Closes either way: a search already in flight is simply
                    // not re-dispatched (`search()` guards on `isLoading`).
                    Button("Done") {
                        Task { await vm.applyFilters() }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("searchFilterDone")
                }
            }
            .immichAppBarTitleHeader("Filters")
        }
    }

    // MARK: - Rating

    /// Five 44 pt targets, the star-ratings interaction (tap the current rank
    /// again to clear it; hollow stars mean "not rated", never `0`) carrying the
    /// identifiers the sheet's UI tests address. Drawn here rather than reusing
    /// `PVRatingBar`: that view hard-codes the *asset* bar's identifiers
    /// (`assetRatingStar_<n>`) and belongs to another feature's files — the
    /// visual rules (44 pt target, `star.fill`/`star`, primary tint, symbol
    /// replacement) are the same.
    private var ratingRow: some View {
        HStack(spacing: PVSpacing.s4) {
            starButton(1, identifier: "searchFilterStar1")
            starButton(2, identifier: "searchFilterStar2")
            starButton(3, identifier: "searchFilterStar3")
            starButton(4, identifier: "searchFilterStar4")
            starButton(5, identifier: "searchFilterStar5")
        }
    }

    private func starButton(_ rank: Int, identifier: String) -> some View {
        Button {
            vm.filter.rating = vm.filter.rating == rank ? nil : rank
        } label: {
            Image(systemName: rank <= (vm.filter.rating ?? 0) ? "star.fill" : "star")
                .font(.system(size: 28)) // DS-exempt: 100 pt-scale rating glyphs (star-ratings)
                .foregroundStyle(rank <= (vm.filter.rating ?? 0) ? Color.immichPrimary : Color.textSecondaryPV)
                .frame(width: 44, height: 44)
                .contentTransition(PVMotion.contentChange(.symbolEffect(.replace), reduceMotion: reduceMotion))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(rank == vm.filter.rating ? Text("Remove rating") : Text("Rate \(rank) stars"))
    }

    // MARK: - Bindings

    /// A text field is a `String`, the constraint a `String?`: an empty field
    /// means "no constraint", so the binding normalizes `""` to `nil` and the
    /// key leaves the request body instead of being sent empty.
    private func text(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    /// Off is `nil`, not `false`: the contract has no "not a favourite" filter.
    private var favorite: Binding<Bool> {
        Binding(
            get: { vm.filter.isFavorite ?? false },
            set: { vm.filter.isFavorite = $0 ? true : nil }
        )
    }

    /// The `DatePicker` needs a concrete day; the constraint only exists while
    /// its toggle is on, and the toggle seeds it with today.
    private func date(_ value: Binding<Date?>) -> Binding<Date> {
        Binding(
            get: { value.wrappedValue ?? Self.today },
            set: { value.wrappedValue = $0 }
        )
    }

    private func dateToggle(_ value: Binding<Date?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { value.wrappedValue = $0 ? (value.wrappedValue ?? Self.today) : nil }
        )
    }

    private static var today: Date { Calendar.current.startOfDay(for: Date()) }
}
