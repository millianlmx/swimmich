import SwiftUI

/// Cast sheet of the full-screen viewer (gap G9): is there a screen, is it
/// already receiving, and can *this* asset go there.
///
/// A sheet of the viewer, not a pushed screen — hence no `NavigationStack`
/// (a stack here would render a navigation bar with nothing to go back to).
/// It shows only what the system actually publishes: `AVRoutePickerView` is the
/// device list and it is the system's, so the sheet enumerates nothing, fakes
/// no progress, and disables the picker with a plain sentence when no screen is
/// reachable instead of leaving a control that does nothing.
struct CastSheet: View {
    let asset: AssetReactItem
    let service: any CastService
    /// A TLS client certificate is installed for the account's server: AirPlay
    /// plays a video by fetching it itself, so it cannot present the certificate
    /// (L-10).
    let clientCertificateActive: Bool

    /// The ViewModel is built here, from the injected service, so the sheet
    /// stays presentable with a mock in tests and the viewer never constructs
    /// the service graph.
    @State private var vm: CastViewModel
    @Environment(\.dismiss) private var dismiss

    init(asset: AssetReactItem, service: any CastService, clientCertificateActive: Bool = false) {
        self.asset = asset
        self.service = service
        self.clientCertificateActive = clientCertificateActive
        _vm = State(initialValue: CastViewModel(service: service))
    }

    var body: some View {
        VStack(spacing: PVSpacing.s16) {
            Text("Cast to a screen")
                .font(.pvHeadline)
                .foregroundStyle(Color.textPrimaryPV)

            castStatusRow
            castRoutePicker

            if !vm.canCast(asset) {
                castImageHint
                    .transition(.opacity)
            }

            if vm.showsClientCertificateHint(for: asset, clientCertificateActive: clientCertificateActive) {
                castClientCertificateHint
                    .transition(.opacity)
            }

            Spacer(minLength: PVSpacing.s12)

            Button("Done") { dismiss() }
                .buttonStyle(PVPrimaryButtonStyle())
        }
        .padding(PVSpacing.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgPrimary)
        .presentationDetents([.medium])
        .onAppear { vm.onAppear() }
        .onDisappear { vm.onDisappear() }
    }

    /// Connected → the route's own name, tinted; otherwise the explicit empty
    /// state. Read in `body` through the observable service, so a route change
    /// made from Control Center lands here without a manual subscription.
    @ViewBuilder
    private var castStatusRow: some View {
        Group {
            if let statusText = vm.statusText {
                PVStatusBadge(text: statusText, color: .immichPrimary, symbol: "airplayvideo")
            } else {
                Text("No external screen connected")
                    .font(.pvSubhead)
                    .foregroundStyle(Color.textSecondaryPV)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("castStatusRow")
    }

    /// The system picker, sized like every other control in the app. Disabled —
    /// not hidden — when no screen is reachable: the status row above says why.
    private var castRoutePicker: some View {
        RoutePickerView()
            .frame(width: 44, height: 44)
            .disabled(!vm.isAvailable)
            .accessibilityIdentifier("castRoutePicker")
    }

    /// The honest half of the feature: AirPlay does not carry a still image.
    private var castImageHint: some View {
        Label(
            "AirPlay cannot send a still photo. Use Screen Mirroring from Control Center.",
            systemImage: "info.circle"
        )
        .font(.pvCaption)
        .foregroundStyle(Color.textSecondaryPV)
        .multilineTextAlignment(.leading)
        .padding(PVSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
        .accessibilityIdentifier("castImageHint")
    }

    /// The video half of the same honesty: with a client certificate installed,
    /// AirPlay cannot play the stream; mirroring the screen still works.
    private var castClientCertificateHint: some View {
        Label(
            "AirPlay can’t play videos from a server that requires a client certificate. Use Screen Mirroring from Control Center.",
            systemImage: "info.circle"
        )
        .font(.pvCaption)
        .foregroundStyle(Color.textSecondaryPV)
        .multilineTextAlignment(.leading)
        .padding(PVSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
        .accessibilityIdentifier("castClientCertificateHint")
    }
}
