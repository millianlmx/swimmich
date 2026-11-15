import SwiftUI

/// Failure card of a full-screen photo page: what failed and "Try Again".
/// Sits over the provisional image, which stays visible (L-29). The
/// identifiers go on the text and on the button, never on the stack: one on
/// the container would replace those of its descendants.
struct ViewerImageFailureView: View {
    let assetID: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: PVSpacing.s12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.pvH2)
                .accessibilityHidden(true)
            Text("Couldn't load this photo")
                .font(.pvSubhead)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("viewerImageError_\(assetID)")
            Button("Try Again", action: retry)
                .buttonStyle(.plain)
                .font(.pvSubhead.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("viewerImageRetry_\(assetID)")
        }
        .padding(PVSpacing.s16)
        .pvFloating(.bar)
        .pvFullscreenChromeTextCap()
        .padding(.horizontal, PVSpacing.s24)
    }
}
