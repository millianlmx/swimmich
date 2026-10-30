import SwiftUI

/// Adjust date/time sheet (gap #3): pick a new timestamp for the asset, Save
/// issues the write via `AssetDetailViewModel.setDateTime`. Error and in-flight
/// states surface inline; `onDone` reports whether the change persisted.
struct AdjustDateSheet: View {
    let asset: AssetReactItem
    let vm: AssetDetailViewModel
    let onDone: (Bool) -> Void

    @State private var date: Date
    @State private var isSaving = false

    init(asset: AssetReactItem, vm: AssetDetailViewModel, onDone: @escaping (Bool) -> Void) {
        self.asset = asset
        self.vm = vm
        self.onDone = onDone
        _date = State(initialValue: Self.initialDate(from: asset))
    }

    var body: some View {
        VStack(spacing: PVSpacing.s16) {
            header
            DatePicker(
                "Date",
                selection: $date,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .tint(Color.immichPrimary)
            footer
        }
        .padding(PVSpacing.s16)
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

    private var footer: some View {
        VStack(spacing: PVSpacing.s8) {
            if let error = vm.errorMessage {
                Text(error)
                    .font(.pvCaption)
                    .foregroundStyle(Color.immichError)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .disabled(isSaving)

                Button {
                    Task {
                        isSaving = true
                        await vm.setDateTime(date)
                        isSaving = false
                        if vm.errorMessage == nil {
                            onDone(true)
                        }
                    }
                } label: {
                    HStack(spacing: PVSpacing.s8) {
                        if isSaving {
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
                .disabled(isSaving)
            }
        }
    }

    /// Seed the picker from the asset's file creation timestamp; fall back to now.
    private static func initialDate(from asset: AssetReactItem) -> Date {
        if let d = ISO8601.immichFormatter.date(from: asset.fileCreatedAt) { return d }
        if let d = ISO8601.fallbackFormatter.date(from: asset.fileCreatedAt) { return d }
        return Date()
    }
}
