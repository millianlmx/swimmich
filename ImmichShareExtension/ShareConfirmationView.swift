import SwiftUI
import UIKit

/// The sheet's only screen: a pure projection of `ShareExtensionViewModel`.
///
/// The view holds no transport and no networking type of its own — it reads
/// state and calls `uploadAll()` / `toggle(_:)`, and nothing else. The hosting
/// controller is the composition root (see `ShareViewController`).
struct ShareConfirmationView: View {
    @Bindable var viewModel: ShareExtensionViewModel
    /// Ends the request without sending: `extensionContext.cancelRequest`.
    var onCancel: () -> Void
    /// Ends the request once the work is done: `extensionContext.completeRequest`.
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: PVSpacing.s0) {
            header
            Divider().overlay(Color.separatorPV)
            itemsList
            Divider().overlay(Color.separatorPV)
            albumRow
            if let message = viewModel.errorMessage {
                errorBadge(message)
            }
            actionBar
        }
        .background(Color.bgPrimary)
        // A sheet must answer immediately; a failed album list degrades to
        // "None" and says so in the error band rather than blocking the send.
        .task { await viewModel.loadAlbums() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s2) {
            HStack(spacing: PVSpacing.s8) {
                Text(String(localized: "Swimmich"))
                    .font(.pvHeadline)
                    .foregroundStyle(Color.textPrimaryPV)
                Spacer(minLength: PVSpacing.s8)
                Button(String(localized: "Cancel"), action: onCancel)
                    .font(.pvBody)
                    .foregroundStyle(Color.immichPrimary)
                    .accessibilityIdentifier("shareExtensionCancelButton")
            }
            Text(viewModel.headerTitle)
                .font(.pvBody)
                .foregroundStyle(Color.textPrimaryPV)
                .accessibilityIdentifier("shareExtensionHeaderCount")
            Text(viewModel.serverLabel)
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
                .lineLimit(1)
                .accessibilityIdentifier("shareExtensionServerLabel")
        }
        .padding(PVSpacing.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSecondary)
    }

    // MARK: - Items

    /// The only extensible zone: header, album and action bar stay fixed so
    /// "Upload" can never be pushed off a thirty-item share.
    private var itemsList: some View {
        ScrollView {
            LazyVStack(spacing: PVSpacing.s0) {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                    ShareItemRow(
                        item: item,
                        index: index,
                        statusText: viewModel.statusText(for: item.status),
                        onTap: { viewModel.toggle(item.id) }
                    )
                    Divider().overlay(Color.separatorPV)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Album

    private var albumRow: some View {
        HStack(spacing: PVSpacing.s8) {
            Text(String(localized: "Album"))
                .font(.pvBody)
                .foregroundStyle(Color.textPrimaryPV)
            Spacer(minLength: PVSpacing.s8)
            Picker(String(localized: "Album"), selection: $viewModel.selectedAlbumId) {
                // "None" means no album: nothing is attached afterwards.
                Text(String(localized: "None")).tag(String?.none)
                ForEach(viewModel.albums) { album in
                    Text(album.albumName).tag(String?.some(album.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(viewModel.isUploading)
            .accessibilityIdentifier("shareExtensionAlbumPicker")
        }
        .padding(.horizontal, PVSpacing.s16)
        .padding(.vertical, PVSpacing.s8)
    }

    // MARK: - Error

    private func errorBadge(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PVSpacing.s8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.immichError)
            Text(message)
                .font(.pvCaption)
                .foregroundStyle(Color.textPrimaryPV)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(PVSpacing.s8)
        .background(Color.immichError.opacity(0.12), in: RoundedRectangle(cornerRadius: PVRadius.sm))
        .padding(.horizontal, PVSpacing.s16)
        .accessibilityIdentifier("shareExtensionErrorBadge")
        .transition(.opacity)
    }

    // MARK: - Action bar

    /// One button with two jobs, both driven by the VM: send what is left, or
    /// close once there is nothing left to send. Disabled only while a run is
    /// in flight — the state is carried by the button, not by a modal alert.
    private var actionBar: some View {
        Button(viewModel.primaryActionTitle) {
            if viewModel.canUpload {
                Task { await viewModel.uploadAll() }
            } else {
                onFinish()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Color.immichPrimary)
        .frame(maxWidth: .infinity)
        .disabled(viewModel.isUploading)
        .accessibilityIdentifier(viewModel.isFinished ? "shareExtensionDoneButton" : "shareExtensionUploadButton")
        .padding(PVSpacing.s16)
        .background(Color.bgSecondary)
    }
}

// MARK: - Row

private struct ShareItemRow: View {
    let item: ShareItem
    let index: Int
    let statusText: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: PVSpacing.s12) {
                ShareThumbnail(item: item)
                VStack(alignment: .leading, spacing: PVSpacing.s2) {
                    Text(item.filename)
                        .font(.pvSubhead)
                        .foregroundStyle(Color.textPrimaryPV)
                        .lineLimit(1)
                    Text(item.byteCountText)
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                Spacer(minLength: PVSpacing.s8)
                ShareItemStatusIndicator(status: item.status)
                    .accessibilityIdentifier("shareExtensionItemStatus_\(index)")
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.pvHeadline)
                    .foregroundStyle(item.isSelected ? Color.immichPrimary : Color.textSecondaryPV)
            }
            .padding(.horizontal, PVSpacing.s16)
            .padding(.vertical, PVSpacing.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shareExtensionItemRow_\(index)")
        // One VoiceOver stop per row: three stops for a thumbnail, a name and a
        // state is unreadable at sheet speed.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.filename), \(item.byteCountText), \(statusText)")
    }
}

/// A local thumbnail. `AssetThumbnailCell` lives in the app's Timeline feature
/// and needs an `AssetReactItem`, neither of which a share extension can link —
/// this is the one place the sheet draws its own, and it only ever has a file.
private struct ShareThumbnail: View {
    let item: ShareItem
    @State private var image: UIImage?

    var body: some View {
        Group {
            if item.isVideo {
                Image(systemName: "video")
                    .font(.pvHeadline)
                    .foregroundStyle(Color.textSecondaryPV)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.pvHeadline)
                    .foregroundStyle(Color.textSecondaryPV)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.sm))
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.sm))
        .task(id: item.id) {
            guard !item.isVideo else { return }
            let url = item.fileURL
            // Off the main actor, and downscaled before it comes back: an
            // extension that decoded thirty full-resolution photos would be
            // killed long before the user could tap Upload.
            image = await Task.detached(priority: .userInitiated) {
                guard let full = UIImage(contentsOfFile: url.path) else { return nil }
                return await full.byPreparingThumbnail(ofSize: CGSize(width: 88, height: 88))
            }.value
        }
        .accessibilityHidden(true)
    }
}

private struct ShareItemStatusIndicator: View {
    let status: ShareItemStatus

    var body: some View {
        Group {
            switch status {
            case .enqueued:
                Image(systemName: "clock")
                    .foregroundStyle(Color.textSecondaryPV)
            case .running(let fraction):
                // Determinate on purpose: the fraction exists, and an
                // indeterminate spinner would say nothing about a run the user
                // is waiting on.
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .frame(width: 20, height: 20)
            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.immichSuccess)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.immichError)
            }
        }
        .contentTransition(.symbolEffect(.replace))
    }
}

// MARK: - No session

/// The only honest answer when the keychain holds no session: an extension
/// cannot call `UIApplication.open`, so it explains and offers a clean exit.
struct ShareNoSessionView: View {
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: PVSpacing.s16) {
            ContentUnavailableView(
                String(localized: "Sign in to Immich"),
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text(String(localized: "Open the Swimmich app, sign in, then share again."))
            )
            .accessibilityIdentifier("shareExtensionNoSessionView")
            Button(String(localized: "Close"), action: onClose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.immichPrimary)
                .accessibilityIdentifier("shareExtensionNoSessionCloseButton")
        }
        .padding(PVSpacing.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgPrimary)
    }
}
