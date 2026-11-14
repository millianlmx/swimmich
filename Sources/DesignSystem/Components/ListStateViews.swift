import SwiftUI

// MARK: - List states
//
// Shared pieces of the loading / empty / error / refresh contract of every
// list screen (L-16, B-20). There is deliberately no generic wrapper view:
// each screen switches on its view model's `ListRenderState` and keeps its own
// container, so the container that carries `.refreshable` never changes under
// a pull-to-refresh in flight.

/// The single rendering a list screen is in. Computed by the view model
/// through `resolve`, never by the view.
enum ListRenderState: Equatable {
    /// First read in flight (or not started), or a "Try Again" with no data.
    case loading
    /// Nothing to show and the last read failed.
    case error(String)
    /// The read succeeded and returned nothing.
    case empty
    case data(DataStatus)

    /// - Parameters:
    ///   - isEmpty: the screen's collection has no element.
    ///   - hasLoaded: a read has succeeded at least once.
    ///   - isLoading: a read is in flight.
    ///   - isRefreshing: that read comes from a pull-to-refresh.
    ///   - loadError: message of the last failed read, cleared by a success.
    static func resolve(
        isEmpty: Bool,
        hasLoaded: Bool,
        isLoading: Bool,
        isRefreshing: Bool,
        loadError: String?
    ) -> ListRenderState {
        if isEmpty {
            if (isLoading && !isRefreshing) || (!hasLoaded && loadError == nil) {
                return .loading
            }
            if let loadError { return .error(loadError) }
            return .empty
        }
        if isLoading && !isRefreshing { return .data(.reloading) }
        if let loadError { return .data(.failed(loadError)) }
        return .data(.idle)
    }
}

/// Sub-state of a screen that already shows data.
enum DataStatus: Equatable {
    case idle
    /// A "Try Again" is reading: the data stays, an indicator stands in
    /// for the banner.
    case reloading
    /// The last read failed: the data stays, a banner carries the reason.
    case failed(String)
}

extension View {
    /// Makes a `ProgressView` or a skeleton one VoiceOver element with a
    /// localized label (default "Loading…", or a more specific one) and an identifier XCUITest can find.
    func pvLoadingIndicator(_ identifier: String, label: LocalizedStringKey = "Loading…") -> some View {
        self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(identifier)
    }
}

/// Error state of a list with nothing to show: title, reason, "Try Again".
/// The identifiers go on the message and on the button, never on the stack:
/// an identifier on a container would replace those of its descendants.
struct PVErrorStateView: View {
    let title: LocalizedStringKey
    let message: String
    let identifierPrefix: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: PVSpacing.s16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.pvBody)
                .foregroundStyle(Color.immichWarning)
                .accessibilityHidden(true)
            Text(title)
                .font(.pvSubhead)
                .foregroundStyle(Color.textPrimaryPV)
            Text(verbatim: message)
                .font(.pvBody)
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("\(identifierPrefix)Error")
            Button("Try Again", action: retry)
                .buttonStyle(PVPrimaryButtonStyle())
                .accessibilityIdentifier("\(identifierPrefix)ErrorRetry")
        }
        .frame(maxWidth: .infinity)
        .padding(PVSpacing.s24)
    }
}
