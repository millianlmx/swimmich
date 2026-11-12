import SwiftUI

// MARK: - PhotoVault Button Styles
//
// Two ButtonStyles covering the primary + subtle interaction tiers. Press
// feedback uses a 0.97 scaleEffect animated with `PVMotion.snappy`; both are
// dropped under Reduce Motion.

/// Primary CTA: indigo fill, white label, capsule, 50pt min height.
struct PVPrimaryButtonStyle: ButtonStyle {
    @PVReduceMotion private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pvHeadline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.immichPrimary)
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.control, style: .continuous))
            .scaleEffect(PVMotion.scale(configuration.isPressed ? 0.97 : 1.0, reduceMotion: reduceMotion))
            .animation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Subtle / secondary action: tertiary background, primary text, capsule.
struct PVSubtleButtonStyle: ButtonStyle {
    @PVReduceMotion private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pvSubhead)
            .foregroundStyle(Color.textPrimaryPV)
            .frame(minHeight: 44)
            .padding(.horizontal, PVSpacing.s16)
            .background(Color.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.control, style: .continuous))
            .scaleEffect(PVMotion.scale(configuration.isPressed ? 0.97 : 1.0, reduceMotion: reduceMotion))
            .animation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
