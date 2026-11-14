import SwiftUI

/// Adjust date/time sheet (gap #3, L-33): the date and time are read as a wall
/// clock (the picker runs under a UTC environment), the time zone is chosen from
/// a sorted, searchable list, and Save sends both through `AdjustDateViewModel`
/// as `yyyy-MM-ddTHH:mm:ss±HH:MM`. Error and in-flight states surface inline;
/// `onDone` reports whether the change persisted.
struct AdjustDateSheet: View {
    @Bindable var vm: AdjustDateViewModel
    let onDone: (Bool) -> Void

    @State private var showZones = false

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s16) {
                header
                DatePicker(
                    "Date",
                    selection: $vm.wallClock,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .tint(Color.immichPrimary)
                .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .gmt)
                .accessibilityIdentifier("adjustDatePicker")
                zoneRow
                footer
            }
            .padding(PVSpacing.s16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sheet(isPresented: $showZones) {
            AdjustDateZoneList(vm: vm) { showZones = false }
                .presentationDetents([.large])
        }
    }

    private var header: some View {
        VStack(spacing: PVSpacing.s4) {
            Text("Adjust Date & Time")
                .font(.pvH6)
                .foregroundStyle(Color.textPrimaryPV)
            Text("Set the timestamp this photo was taken.")
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
        }
    }

    /// "Time Zone · Europe/Paris · +02:00 ›" — opens the zone list.
    private var zoneRow: some View {
        let entry = vm.selectedEntry
        let spoken: String = entry.identifier + ", " + entry.offsetText
        return Button {
            showZones = true
        } label: {
            HStack(spacing: PVSpacing.s8) {
                Text("Time Zone")
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                Spacer(minLength: PVSpacing.s8)
                Text(entry.identifier)
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                    .multilineTextAlignment(.trailing)
                Text(entry.offsetText)
                    .font(.pvCaption)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondaryPV)
                Image(systemName: "chevron.right")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, PVSpacing.s12)
            .padding(.vertical, PVSpacing.s12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous).fill(Color.gray.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time Zone")
        .accessibilityValue(spoken)
        .accessibilityIdentifier("adjustDateZoneButton")
    }

    private var footer: some View {
        VStack(spacing: PVSpacing.s8) {
            if let error = vm.detail.errorMessage {
                Text(error)
                    .font(.pvCaption)
                    .foregroundStyle(Color.immichError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("adjustDateError")
            }
            HStack(spacing: PVSpacing.s12) {
                Button {
                    onDone(false)
                } label: {
                    Text("Cancel")
                        .font(.pvBody.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PVSpacing.s12)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous).fill(Color.gray.opacity(0.12)))
                .disabled(vm.isSaving)
                .accessibilityIdentifier("adjustDateCancelButton")

                Button {
                    Task {
                        if await vm.save() {
                            onDone(true)
                        }
                    }
                } label: {
                    HStack(spacing: PVSpacing.s8) {
                        if vm.isSaving {
                            ProgressView()
                        }
                        Text("Save")
                            .font(.pvBody.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, PVSpacing.s12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .background(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous).fill(Color.immichPrimary))
                .disabled(vm.isSaving)
                .accessibilityIdentifier("adjustDateSaveButton")
            }
        }
    }
}

/// The zone list: every zone with its offset at the sheet's date, sorted by
/// offset then name, filtered by the search field. Picking a row selects the
/// zone and returns to the date sheet.
private struct AdjustDateZoneList: View {
    @Bindable var vm: AdjustDateViewModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            let entries = vm.zoneEntries
            ScrollViewReader { proxy in
                List {
                    if entries.isEmpty {
                        Text("No time zones match “\(vm.filterText)”.")
                            .font(.pvBody)
                            .foregroundStyle(Color.textSecondaryPV)
                            .accessibilityIdentifier("adjustDateZoneEmpty")
                    }
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                .onAppear {
                    guard vm.filterText.isEmpty else { return }
                    proxy.scrollTo(vm.selectedZoneIdentifier, anchor: .center)
                }
            }
            .searchable(text: $vm.filterText, prompt: "Search time zones")
            .navigationTitle("Time Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose() }
                        .accessibilityIdentifier("adjustDateZoneCancel")
                }
            }
        }
    }

    private func row(_ entry: AdjustDateViewModel.TimeZoneEntry) -> some View {
        let isSelected = entry.identifier == vm.selectedZoneIdentifier
        return Button {
            vm.selectZone(entry.identifier)
            onClose()
        } label: {
            HStack(spacing: PVSpacing.s8) {
                Text(entry.identifier)
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                Spacer(minLength: PVSpacing.s8)
                Text(entry.offsetText)
                    .font(.pvCaption)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondaryPV)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.immichPrimary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.identifier)
        .accessibilityValue(entry.offsetText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("adjustDateZoneRow_\(entry.identifier)")
        .id(entry.identifier)
    }
}
