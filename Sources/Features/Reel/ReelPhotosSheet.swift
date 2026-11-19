import SwiftUI

/// The reel's photos, to add and remove by hand: a tap takes a photo out of
/// the reel, or puts one of the others in. Changes apply at once, the player
/// starting over behind the sheet.
struct ReelPhotosSheet: View {
    @Bindable var vm: ReelViewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(
                        title: Text("In the reel (\(vm.picks.count))"),
                        footer: vm.canRemove
                            ? Text("Tap a photo to take it out.")
                            : Text("A reel needs at least \(ReelPlan.minPhotos) photos."),
                        photos: vm.picks,
                        inReel: true
                    )
                    if !vm.morePhotos.isEmpty {
                        section(
                            title: Text("More photos"),
                            footer: Text("Tap a photo to add it."),
                            photos: vm.morePhotos,
                            inReel: false
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("Reel photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("reelPhotosDone")
                }
            }
        }
    }

    private func section(title: Text, footer: Text, photos: [DumpCandidate], inReel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.pvHeadline)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(photos) { photo in
                    tile(photo, inReel: inReel)
                }
            }
            footer
                .font(.pvCaption)
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ photo: DumpCandidate, inReel: Bool) -> some View {
        Button {
            Task {
                if inReel { await vm.remove(photo.id) } else { await vm.add(photo.id) }
            }
        } label: {
            Color.gray.opacity(0.15)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    AuthenticatedAsyncImage(url: vm.thumbnailURL(for: photo.asset), token: vm.token, contentMode: .fill)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: inReel ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.body.weight(.bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, inReel ? Color.red : Color.green)
                        .padding(4)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inReel && !vm.canRemove)
        .accessibilityLabel(inReel ? Text("Remove from the reel") : Text("Add to the reel"))
        .accessibilityIdentifier(inReel ? "reelPhotoRemove_\(photo.id)" : "reelPhotoAdd_\(photo.id)")
    }
}
