# Task: settings-parity — UI Brief

> Compagnon de `.omp/settings-parity/settings-parity.specs.md` (écrit le 2026-09-15). Ce document ne décrit que la **surface**. Ce n'est pas un écran unique : **un point d'entrée dans le hub « Me »**, **un écran poussé** qui tient les quatorze contrôles, et **quatre surfaces existantes** que ces réglages changent (timeline, viewer photo, lecteur vidéo, diaporama). Architecture, clés et approches rejetées : la spec.

## Design Philosophy

1. **Le défaut ne change rien.** Chaque réglage neuf vaut exactement le comportement d'aujourd'hui (`tilesPerRow = 3`, `groupBy = .day`, `loadOriginal = false`, `autoPlayVideo = true`, `theme = .system`, `accent = .immich`, `hapticsEnabled = true`) : la fiche est purement additive pour qui n'ouvre jamais l'écran.
2. **Chaque bascule se voit immédiatement, dans l'écran qui la subit.** Pas de « redémarrez l'app » : le thème repeint la hiérarchie entière, l'accent reteinte les contrôles, les haptiques se taisent au geste suivant, densité et groupement refrappent la timeline. Le store est lu **au moment du geste**, jamais à la construction de la vue.
3. **Un seul écran, l'idiome des réglages d'iOS** : `Form` comme `NotificationSettingsView`, un en-tête par section, une ligne par contrôle, le « Reset » à la fin en `Button(role: .destructive)`. Ni carte custom, ni verre — une page de service, pas une page de découverte.

## Placement dans la navigation

- **Hub « Me » (`ProfileView`)** : ligne neuve dans une section `General` portant son propre en-tête, insérée **avant** la section Language (seule ligne de la section : sans en-tête, rien ne dit que ce qu'on ouvre n'est ni le compte, ni le serveur, ni le stockage). Libellé `Preferences`, icône `slider.horizontal.3`, distincte de `globe` (Language), `gearshape.2` (Administration) et `icloud.and.arrow.up` (Backup).
- **`PreferencesView` est poussée, donc aucun `NavigationStack`** : `ProfileView` en porte déjà un (`Sources/Features/Profile/ProfileView.swift:25`) — même contrainte que `LanguageSettingsView`, `OfflineAssetsView` et `StackView`.
- **Le verrou Face ID et la langue ne sont pas déplacés** dans ce nouvel écran (hors périmètre).
- **Les réglages modifient des écrans hors de la navigation du hub** : l'en-tête de section annonce l'effet, et l'effet s'observe en fermant l'écran.

## Layout

```
ProfileView                                   (hub « Me », porte le NavigationStack)
└── Form (listStyle .insetGrouped)
    ├── Section header: Text("General")                       ← section neuve
    │   └── NavigationLink → PreferencesView       id: preferencesRow
    └── Sections Language / Backup / Notifications / Administration : inchangées
        (Sync Status a quitté ce hub le 2026-09-16 : bouton de barre à côté de l'avatar de profil)

PreferencesView                               (poussée, AUCUN NavigationStack)
└── Form
    ├── ToolbarItem(.principal) { ImmichAppBar(title: "Preferences") }   .inline
    ├── Section "Photos"
    │   ├── Picker("Group By", selection: $vm.groupBy)   .menu → .day / .month / .flat
    │   └── Stepper("Columns", value: $vm.tilesPerRow, in: 2...7)   valeur en pvNumeric
    ├── Section "Viewer"
    │   ├── Toggle("Load Full Quality", isOn: $vm.loadOriginal)
    │   └── Toggle("Tap to Navigate", isOn: $vm.tapToNavigate)
    ├── Section "Video"
    │   ├── Toggle("Auto-Play", isOn: $vm.autoPlayVideo)
    │   ├── Toggle("Loop", isOn: $vm.loopVideo)
    │   └── Toggle("Stream Original", isOn: $vm.loadOriginalVideo)
    ├── Section "Slideshow"
    │   ├── Toggle("Repeat", isOn: $vm.slideshowRepeat)
    │   ├── Picker("Speed", …)  .menu → 2s / 3s / 5s
    │   ├── Picker("Look", …)   .menu → dissolve / slide / kenBurns
    │   └── Toggle("Reverse Order", isOn: $vm.slideshowReverse)
    ├── Section "Appearance"
    │   ├── Picker("Theme", selection: $vm.theme)         .menu → System / Light / Dark
    │   └── Picker("Accent Color", selection: $vm.accent) .menu → pastille + libellé
    ├── Section "Feedback"
    │   └── Toggle("Haptic Feedback", isOn: $vm.hapticsEnabled)
    └── Section { Button("Reset", role: .destructive) → confirmationDialog }

Consommateurs (écrans existants qui lisent le store)
├── TimelineView       → build(from:groupBy:) ; baseColumns = tilesPerRow ; onChange réamorce gridScale
├── PhotoViewer        → tap : chrome ⇄ asset suivant selon tapToNavigate
├── ZoomableImageView  → .original(…) ⇄ .thumbnailURL(…, size: .fullsize) selon loadOriginal
├── VideoPlayerView    → VideoPlaybackViewModel(engine:appSettings:)
└── SlideshowView      → speed / look / reverse / repeat semés depuis le store
```

Fond `Color.bgPrimary`, lignes `Color.bgSecondary` : aucun blanc littéral, aucune `List` nue. Le `Stepper` de densité est le seul endroit de l'app où la densité s'affiche comme un nombre.

## Composants

Réutiliser, ne rien créer côté DesignSystem : `ImmichAppBar` en `ToolbarItem(placement: .principal)`, `Section { … } header: { Text("…") }` du `Form`, `Button(role: .destructive)` (ou `PVButtonStyle` pour un CTA), `Font.pvNumeric` pour la valeur du `Stepper`, `PVSpacing.s16` pour la pastille, `Color.separatorPV`, `bgPrimary`, `bgSecondary` pour les fonds. `PVStatusBadge`, `PVGridCell`, `PVSkeletonGrid`, `PVFieldSurface`, `PVInputGroup`, `InlineErrorBadge`, `UserAvatarCircle` et `ContentUnavailableView` ne servent pas ici : un réglage n'est pas un état, et cet écran n'a ni grille, ni champ, ni erreur à montrer.

```swift
// Ligne du hub — l'identifiant va sur le NavigationLink (l'élément actionnable), jamais sur la Section qui le contient.
Section {
    NavigationLink { PreferencesView(vm: appSettings) } label: {
        Label("Preferences", systemImage: "slider.horizontal.3")
    }
    .accessibilityIdentifier("preferencesRow")
} header: { Text("General") }
```

```swift
// Photos — les deux contrôles écrivent le MÊME store que le pincement de TimelineView : l'écran et la timeline ne peuvent pas diverger.
Section("Photos") {
    Picker("Group By", selection: $vm.groupBy) {
        ForEach(TimelineGroupBy.allCases) { Text($0.label).tag($0) }
    }
    .accessibilityIdentifier("preferencesGroupPicker")
    Stepper(value: $vm.tilesPerRow, in: 2...7) {
        LabeledContent("Columns") {
            Text("\(vm.tilesPerRow)").font(.pvNumeric).foregroundStyle(Color.textSecondaryPV)
        }
    }
    .accessibilityIdentifier("preferencesColumnsStepper")
}
```

```swift
// Apparence — le thème sort en ColorScheme? (nil = « System ») ; l'accent est une liste fermée dont le cas .immich rend Color.immichPrimary : « ne rien changer » est le défaut exact.
Section("Appearance") {
    Picker("Theme", selection: $vm.theme) {
        ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
    }
    .accessibilityIdentifier("preferencesThemePicker")
    Picker("Accent Color", selection: $vm.accent) {
        ForEach(AppAccent.allCases) { preset in
            Label { Text(preset.label) } icon: {
                Circle().fill(preset.color)      // .immich == Color.immichPrimary
                    .frame(width: PVSpacing.s16, height: PVSpacing.s16)
                    .accessibilityHidden(true)   // décoratif : la ligne dit « Blue », pas « cercle »
            }
            .tag(preset)
        }
    }
    .accessibilityIdentifier("preferencesAccentPicker")
}
```

Côté sites consommateurs, seul le nom de l'appel change : `content.appSensoryFeedback(.success, trigger: didCopy)` — la valeur et le trigger restent ceux que la vue déclare, la condition vit dans le modificateur.

**Pourquoi le thème et l'accent ne passent pas par les tokens.** `ImmichColors.swift` est un jeu **unique** de couleurs dynamiques `Color(light:dark:)`, un token par intention, partagé par tout le DesignSystem : le réécrire par preset doublerait chaque token et chaque composant. L'accent se projette donc sur **un seul `.tint(...)` à la racine** — un modificateur, pas une palette : `Picker`, `Toggle`, `Stepper`, `.borderedProminent` et `NavigationLink` se reteintent sans qu'aucune vue ne change, et le cas `.immich` réinjecte exactement `Color.immichPrimary`. Le thème passe par `preferredColorScheme(theme.colorScheme)` : `nil` pour « System » (iOS décide), `.light` / `.dark` sinon — et les couleurs `Color(light:dark:)` basculent **d'elles-mêmes**, rien à repeindre à la main. Les deux modificateurs se posent sur le `ZStack` **extérieur** de `RootView`, pas sur la racine authentifiée : le thème et l'accent doivent couvrir aussi l'onboarding et `LockView`.

## Interactions

| Geste | Effet immédiat |
|---|---|
| Tap « Preferences » (hub) | Pousse `PreferencesView` ; le hub ne bouge pas |
| Changer « Theme » | L'app entière repeint, **y compris l'écran de préférences** et `LockView` ; aucun redémarrage |
| Changer « Accent Color » | Contrôles reteintés partout ; la marque (`Color.immichPrimary`) reste intacte |
| Changer « Group By » | Timeline refrappée : `.day` = en-tête de mois + groupes jour (aujourd'hui), `.month` = un en-tête par mois, `.flat` = une seule liste sans en-tête |
| Changer « Columns » | La grille prend la densité (2…7) sans pincement : `onChange(of: appSettings.tilesPerRow)` réamorce `gridScale` |
| Pincer la timeline | Écrit `tilesPerRow` : le `Stepper` affiche la même valeur à la réouverture (le geste est l'écrivain, seule la persistance manquait) |
| Changer « Load Full Quality » | L'image suivante est servie en original plutôt qu'en `.fullsize` ; lu au tap, donc le viewer déjà ouvert suit |
| Changer « Tap to Navigate » | Tap simple : désactivé = bascule du chrome (actuel), activé = asset suivant sans toucher au chrome |
| Changer « Auto-Play », « Loop », « Stream Original » | Lus **au moment de `prepare`** : la vidéo suivante démarre (ou non), boucle (ou non), sur l'URL originale (ou transcodée) ; la lecture en cours n'est pas coupée |
| Changer « Repeat », « Speed », « Look » ou « Reverse » | Le diaporama ouvert suit : le ticker ne s'arrête plus à la dernière diapositive quand « Repeat » est actif |
| Couper « Haptic Feedback » | Les **20** retours des 14 fichiers se taisent au geste suivant : le modificateur rend `nil`, la vue continue de déclarer son intention |
| Tap « Reset » | `confirmationDialog` destructif (« Reset Preferences? » → « Reset ») puis purge des 14 clés : retour à l'état d'usine sans réinstaller |

## Liquid Glass / matériaux

Pas de `glassEffect` sur `PreferencesView` : le verre est réservé aux surfaces **flottantes** (chrome du viewer, barres, bandeaux), jamais à un écran de service poussé — `StackView` et `OfflineAssetsView` n'en posent pas non plus.

Une précaution à vérifier visuellement : `.tint` reteinte les contrôles, mais les surfaces de verre du viewer et de la barre d'onglets portent leur propre teinte (`.glassEffect(.regular.tint(…))`). Si un preset dégrade leur contraste, restreindre `.tint` au `Group` intérieur plutôt qu'au `ZStack` — décision d'implémentation, pas de design.

## Accessibilité

- **Identifiants sur les éléments interactifs** (jamais sur la `Section` qui les contient) : `preferencesRow`, `preferencesGroupPicker`, `preferencesColumnsStepper`, `preferencesLoadOriginalToggle`, `preferencesTapToNavigateToggle`, `preferencesAutoPlayToggle`, `preferencesLoopVideoToggle`, `preferencesOriginalVideoToggle`, `preferencesSlideshowRepeatToggle`, `preferencesSlideshowSpeedPicker`, `preferencesSlideshowLookPicker`, `preferencesSlideshowReverseToggle`, `preferencesThemePicker`, `preferencesAccentPicker`, `preferencesHapticsToggle`, `preferencesResetButton`.
- **VoiceOver** : chaque ligne est un contrôle natif (`Toggle`, `Picker`, `Stepper`) : libellé anglais **et** valeur sont lus ensemble, sans `accessibilityElement(children: .combine)`. La pastille de couleur est décorative (`accessibilityHidden(true)`) pour que la ligne s'annonce « Accent Color, Blue ».
- **Cibles ≥ 44 pt** : atteintes par les lignes de `Form` ; aucun `frame(height:)` figé sur les `Toggle` et le `Stepper`. **Dynamic Type** : aucune largeur fixe, `LabeledContent("Columns")` laisse le libellé et sa valeur se replier aux tailles d'accessibilité.
- **Reduce Motion** : rien à déclarer — l'écran n'anime rien, et le changement de thème est un redraw.
- **Chaînes** : clés anglaises (`Preferences`, `General`, `Photos`, `Group By`, `Columns`, `Viewer`, `Load Full Quality`, `Tap to Navigate`, `Video`, `Auto-Play`, `Loop`, `Stream Original`, `Slideshow`, `Repeat`, `Speed`, `Look`, `Reverse Order`, `Appearance`, `Theme`, `System`, `Light`, `Dark`, `Accent Color`, `Feedback`, `Haptic Feedback`, `Reset Preferences?`, `Reset`). Aucune écriture manuelle dans `Resources/Localizable.xcstrings` : l'extraction se fait au build.

## Animations

| Transition | Implémentation | Reduce Motion |
|---|---|---|
| Bascule de thème | `preferredColorScheme` — redraw instantané, aucune animation | sans objet |
| Bascule d'accent | `.tint` — redraw instantané des contrôles | sans objet |
| `Stepper` de densité | animation native du contrôle | système |
| Push / pop de `PreferencesView` | transition de navigation standard | système |
| Diaporama suivi à chaud | animation existante de `SlideshowView`, inchangée | inchangée |

Aucun `withAnimation`, aucun `matchedGeometryEffect`, aucun `glassEffectID` : un réglage qui se voit ne se met pas en scène. Le seul mouvement introduit par la fiche est **en aval**, dans des vues qui en ont déjà.

## Fichiers touchés

- NEW `Sources/Features/Settings/AppTheme.swift` — `AppTheme` (`colorScheme: ColorScheme?`), `AppAccent` (`color`).
- NEW `Sources/Features/Settings/AppSettingsStore.swift` — les 14 réglages, `resetToDefaults()`.
- NEW `Sources/Features/Settings/HapticsEnvironment.swift` — `EnvironmentKey`, modificateur, surcharge optionnelle du SDK.
- NEW `Sources/Features/Settings/PreferencesViewModel.swift` — passe-plat, aucun état propre.
- NEW `Sources/Features/Settings/PreferencesView.swift` — l'écran ci-dessus.
- NEW `Tests/AppSettingsStoreTests.swift` — 7 cas.
- EDIT `Sources/DependencyContainer.swift` — `appSettings` + `makeAppSettingsViewModel()`.
- EDIT `Sources/RootView.swift` — `.environment(appSettings)`, `\.hapticsEnabled`, `preferredColorScheme`, `.tint` ; passage à `ProfileView`.
- EDIT `Sources/Features/Profile/ProfileView.swift` — paramètre + section `General` + `preferencesRow`.
- EDIT `Sources/Features/Timeline/TimelineSectionBuilder.swift` — `TimelineGroupBy`, cas mois et `.flat`.
- EDIT `Sources/Features/Timeline/TimelineView.swift` — densité persistée, `onChange`, `groupBy`.
- EDIT `Sources/Features/PhotoViewer/ZoomableImageView.swift` — variante d'image selon `loadOriginal`.
- EDIT `Sources/Features/PhotoViewer/PhotoViewer.swift` — tap selon `tapToNavigate`.
- EDIT `Sources/Features/PhotoViewer/VideoPlaybackViewModel.swift` + `VideoPlayerView.swift` — les trois réglages vidéo.
- EDIT `Sources/Features/PhotoViewer/SlideshowViewModel.swift` + `SlideshowView.swift` — cadence, style, ordre, répétition.
- EDIT les 14 fichiers portant les 20 `.sensoryFeedback` (liste en spec, hypothèses) — renommage en `.appSensoryFeedback`.

## Erreurs à ne pas faire (mesurées dans ce dépôt)

1. **Poser un identifiant sur la `Section`, le `Form` ou un conteneur** : il se propage aux descendants et écrase le leur — mesuré sur `languageRelaunchToast`, où le bouton devenait introuvable par son propre identifiant alors qu'il était visible. Les identifiants vont sur le `NavigationLink`, le `Toggle`, le `Picker`, le `Stepper`, le `Button`.
2. **Déclarer un `NavigationStack` dans `PreferencesView`** : `ProfileView` en porte un ; un second stack produit deux barres de navigation (piège relevé à la livraison de `LanguageSettingsView`).
3. **Réécrire les tokens pour l'accent** : un second axe de palette doublerait chaque token du DesignSystem et casserait l'invariant documenté dans `ImmichColors.swift`.
4. **Remplacer `.sensoryFeedback` par 20 `if hapticsEnabled`** : 20 conditions dispersées, et le prochain appel oublié. Une porte unique — le modificateur qui rend `nil` — avec `defaultValue = true` sur la clé d'environnement, sinon un aperçu Xcode hors de l'arbre racine plante à la lecture.
5. **Lire le store à la construction d'une vue consommatrice** : le viewer déjà ouvert ignorerait la bascule. Lecture au moment du geste (image, tap, `prepare` de la vidéo).
6. **Deux sources pour la densité** : le pincement et le `Stepper` écrivent la **même** propriété du **même** store — deux `@AppStorage` indépendants ne se synchronisent pas, c'est le bug que `DependencyContainer.swift:53` documente pour la langue.
7. **Chercher `.sensoryFeedback(` dans un commentaire** : les checks visent la **déclaration** ; laisser la forme appelée en commentaire ferait passer un grep qui n'a rien vérifié. Et jamais de littéral français dans une vue : la clé du catalogue est la chaîne anglaise.
8. **Promettre un effet qui n'existe pas** : `loadOriginal` change la variante demandée, pas une qualité garantie (le serveur peut transcoder) ; « Stream Original » ne touche ni la Live Activity ni la sauvegarde, qui lisent le fichier, pas la source de lecture.
