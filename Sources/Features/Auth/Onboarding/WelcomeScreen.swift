import SwiftUI

/// Step 1 — Bienvenue. Single-screen welcome, Apple "What's New" style.
///
/// One screen, one message: a `PVHeaderBadge` hero in a rounded wash, a short
/// title + tagline, then the three value props as static rows (icon tile +
/// headline + detail). No paging, no skip, no looping motion — the single CTA
/// is pinned to the bottom over a material bar so it never scrolls out of
/// reach.
struct WelcomeScreen: View {
    let `continue`: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s32) {
                header

                VStack(alignment: .leading, spacing: PVSpacing.s16) {
                    ForEach(WelcomeBullet.all) { bullet in
                        WelcomeBulletRow(bullet: bullet)
                    }
                }
            }
            .padding(PVSpacing.s24)
        }
        .background(Color.bgPrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onboardingBottomBar {
            Button("Get Started", action: `continue`)
                .buttonStyle(PVPrimaryButtonStyle())
        }
    }

    private var header: some View {
        VStack(spacing: PVSpacing.s8) {
            PVHeaderBadge {
                ImmichMark()
                    .frame(width: 40, height: 40)
            }
            Text("Welcome to Swimmich")
                .font(.pvH2)
                .multilineTextAlignment(.center)
            Text("Set up your server and sign in.")
                .font(.pvSubhead)
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
            Text("Compatible with Immich servers.")
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("welcomeCompatibilityNote")
        }
        .padding(.top, PVSpacing.s8)
    }
}

// MARK: - Bullets

private struct WelcomeBullet: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String

    static let all: [WelcomeBullet] = [
        .init(
            symbol: "photo.stack",
            title: String(localized: "Your photo library"),
            detail: String(localized: "self-hosted, private, and durable.")
        ),
        .init(
            symbol: "lock.shield.fill",
            title: String(localized: "Your photos, your server"),
            detail: String(localized: "No third-party cloud. Your memories stay with you.")
        ),
        .init(
            symbol: "sparkles",
            title: String(localized: "Search & memories"),
            detail: String(localized: "Smart search, shared albums, timelines.")
        )
    ]
}

/// Static value-prop row: tinted icon tile + headline + detail line.
private struct WelcomeBulletRow: View {
    let bullet: WelcomeBullet

    var body: some View {
        HStack(alignment: .top, spacing: PVSpacing.s16) {
            Image(systemName: bullet.symbol)
                .font(.pvH5)
                .foregroundStyle(Color.immichPrimary)
                .frame(width: 48, height: 48)
                .background(Color.immichPrimary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))

            VStack(alignment: .leading, spacing: PVSpacing.s4) {
                Text(bullet.title)
                    .font(.pvHeadline)
                    .foregroundStyle(Color.textPrimaryPV)
                Text(bullet.detail)
                    .font(.pvBody)
                    .foregroundStyle(Color.textSecondaryPV)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
