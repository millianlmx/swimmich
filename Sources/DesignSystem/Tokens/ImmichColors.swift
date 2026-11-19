import SwiftUI

// MARK: - Immich brand colors
//
// Valeurs reprises du thème officiel Immich (`--immich-primary`, `--immich-error`, etc.)
// afin que le port SwiftUI conserve l'identité visuelle exacte de l'app originale.
// Toutes les couleurs sont dynamiques (light/dark) via UIColor(dynamicProvider:).

extension Color {

    /// Couleur d'accent principale d'Immich — le bleu-violet du logo et des CTA.
    /// Light: #4250AF · Dark: #ACCBFA
    static let immichPrimary = Color(
        light: Color(red: 66 / 255, green: 80 / 255, blue: 175 / 255),
        dark: Color(red: 172 / 255, green: 203 / 255, blue: 250 / 255)
    )

    /// Contenu posé sur un aplat `immichPrimary` (libellé de CTA, initiales, badge
    /// de compteur). Le blanc ne tient que sur l'indigo clair (7,0:1) ; sur le
    /// bleu pâle du mode sombre il tombe à 1,66:1, d'où un bleu nuit (≈ 11:1).
    /// Light: #FFFFFF · Dark: #081430
    static let immichOnPrimary = Color(
        light: .white,
        dark: Color(red: 8 / 255, green: 20 / 255, blue: 48 / 255)
    )

    /// Fond principal — noir pur en dark mode (pas de gris système),
    /// pour un rendu très contrasté façon "cinema mode" sur les photos.
    /// Light: #FFFFFF · Dark: #000000
    static let immichBackground = Color(
        light: .white,
        dark: .black
    )

    /// Texte primaire.
    /// Light: #000000 · Dark: #E5E7EB
    static let immichForeground = Color(
        light: .black,
        dark: Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255)
    )

    /// Fond secondaire — cards, cellules, zones neutres.
    /// Light: #F6F6F4 · Dark: #212121
    static let immichGray = Color(
        light: Color(red: 246 / 255, green: 246 / 255, blue: 244 / 255),
        dark: Color(red: 33 / 255, green: 33 / 255, blue: 33 / 255)
    )

    /// Succès — upload réussi, confirmation.
    /// Light: #81C784 · Dark: #388E3C
    static let immichSuccess = Color(
        light: Color(red: 129 / 255, green: 199 / 255, blue: 132 / 255),
        dark: Color(red: 56 / 255, green: 142 / 255, blue: 60 / 255)
    )

    /// Erreur — échec, suppression, alerte.
    /// Light: #E57373 · Dark: #D32F2F
    static let immichError = Color(
        light: Color(red: 229 / 255, green: 115 / 255, blue: 115 / 255),
        dark: Color(red: 211 / 255, green: 47 / 255, blue: 47 / 255)
    )

    /// Avertissement — quota bientôt atteint, action à surveiller.
    /// Light: #FFB74D · Dark: #F57C00
    static let immichWarning = Color(
        light: Color(red: 255 / 255, green: 183 / 255, blue: 77 / 255),
        dark: Color(red: 245 / 255, green: 124 / 255, blue: 0 / 255)
    )

    /// Helper générique pour déclarer une couleur dynamique light/dark
    /// sans passer par un Asset Catalog.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor(dynamicProvider: { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        }))
    }
}

// MARK: - Contenu sur la teinte (boutons `.borderedProminent`)
//
// `.borderedProminent` remplit le bouton de la teinte (`.tint`, l'accent choisi
// dans Préférences) et garde un libellé système blanc : 1,66:1 sur l'accent
// sombre #ACCBFA, sous le seuil texte de 4,5:1. Ces boutons passent par
// `pvProminentButtonStyle()`, qui pose `pvOnTint`, l'encre de la teinte courante.

extension Color {
    /// Encre lisible sur un aplat `fill` : blanc ou noir, celui qui contraste le
    /// plus, résolu séparément en clair et en sombre. L'un des deux dépasse
    /// toujours 4,58:1 (WCAG), quelle que soit la couleur de l'aplat.
    static func pvInk(on fill: Color) -> Color {
        Color(light: ink(on: fill, .light), dark: ink(on: fill, .dark))
    }

    private static func ink(on fill: Color, _ scheme: ColorScheme) -> Color {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let c = fill.resolve(in: environment)
        let luminance = 0.2126 * Double(c.linearRed) + 0.7152 * Double(c.linearGreen) + 0.0722 * Double(c.linearBlue)
        // Le blanc l'emporte quand 1,05 / (L + 0,05) > (L + 0,05) / 0,05.
        return (luminance + 0.05) * (luminance + 0.05) < 1.05 * 0.05 ? .white : .black
    }
}

extension EnvironmentValues {
    /// Encre des libellés posés sur la teinte courante. La racine la pose à côté
    /// de `.tint`, depuis le même accent ; la valeur par défaut est celle de la
    /// teinte par défaut, `immichPrimary`.
    @Entry var pvOnTint: Color = .immichOnPrimary
}

extension View {
    /// `.borderedProminent` avec un libellé lisible sur la teinte courante.
    func pvProminentButtonStyle() -> some View {
        modifier(PVProminentButtonModifier())
    }
}

private struct PVProminentButtonModifier: ViewModifier {
    @Environment(\.pvOnTint) private var onTint

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .foregroundStyle(onTint)
    }
}

// MARK: - Usage recommandé
//
// - `Color.immichPrimary` remplace `Color.accentColor` partout où l'identité
//   de marque doit être visible (CTA principaux, sélection active, liens).
// - `Color.immichBackground` / `.immichForeground` / `.immichGray` ne
//   remplacent PAS systématiquement les semantic colors iOS — à utiliser
//   uniquement là où le rendu "cinema mode" noir pur d'Immich compte
//   vraiment (ex: fond de la visionneuse plein écran), pas sur les écrans
//   de formulaires/réglages qui doivent rester 100% natifs iOS.
// - `.immichSuccess` / `.immichError` / `.immichWarning` remplacent
//   `Color.green` / `.red` / `.orange` pour les toasts, badges de statut
//   d'upload, et indicateurs de quota.
//
// Exemple :
//
// struct UploadBadge: View {
//     var body: some View {
//         Label("Sauvegardé", systemImage: "checkmark.circle.fill")
//             .foregroundStyle(Color.immichSuccess)
//     }
// }
