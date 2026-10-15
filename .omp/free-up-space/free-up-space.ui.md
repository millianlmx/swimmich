# Task: free-up-space — UI Brief

> Compagnon de `.omp/free-up-space/free-up-space.specs.md` (2026-09-15). Ce document ne décrit que la
> **surface** : placement, hiérarchie de vues, gestes, états, tokens — pas le scan ni le rôle du ledger.

## Design Philosophy

L'écran fait faire un geste **destructif sur la pellicule**, alors que sa promesse est paradoxale : « le
fichier ne vit plus que sur Immich ». Tout part d'une idée — **on supprime une copie, pas un asset** :
(1) « delete » n'apparaît jamais seul, chaque libellé dit **sur quoi** il porte (`from this device`) ;
(2) le poids de la confirmation est porté par le **contenu**, pas par la couleur — le `confirmationDialog`
explique volume, borne de date, destination (corbeille système) et sort de l'original côté serveur, il ne
redemande pas « êtes-vous sûr ? ».

Le reste est un formulaire sobre : date et filtres, puis scan, puis chiffres ; la revue est une **preuve
visuelle** avant l'action, pas un compteur.

## Placement dans la navigation

- Poussé depuis **`ProfileView`** (hub « Me »), section `Management`, **après** la ligne Offline Storage
  (`ProfileView.swift:107-112`, dernière de la section), avec `.accessibilityIdentifier("freeUpSpaceRow")` :
  c'est la seconde ligne qui agit sur **ce que l'appareil contient**, et le cluster Backup / Sync Status
  (ce qui monte) reste au-dessus, intact. (Le cluster a perdu sa seconde ligne le 2026-09-16 : Sync Status
  est devenu un bouton de barre à côté de l'avatar de profil. L'ancrage décrit ici ne bouge pas.)
- `FreeUpSpaceView` **ne déclare aucun `NavigationStack`** — `ProfileView` en porte un (`:25`).
  `CleanupReviewView` non plus : poussée par `NavigationLink` depuis `FreeUpSpaceView`, même pile.
- Retour natif. Après une suppression réussie, la revue se **dismiss** et le récapitulatif s'affiche sur
  l'écran de réglages (`vm.lastDeletedCount`). Pas d'onglet, pas de feuille, pas d'action en barre d'outils.

## Layout

```
ProfileView (NavigationStack du hub)
└── NavigationLink (« Free Up Space »)              id: freeUpSpaceRow
    └── FreeUpSpaceView            (@Bindable vm)
        ├── .navigationTitle("Free Up Space") · .navigationBarTitleDisplayMode(.inline)
        ├── .task { vm.loadAlbums() }
        └── Form
            ├── Section « Cutoff » (footer: borne inclusive)
            │   ├── DatePicker(.date, in: ...Date.now)     id: cleanupCutoffDatePicker
            │   └── ScrollView(.horizontal) → HStack(spacing: PVSpacing.s8)
            │       └── 6 CutoffPresetChip (30/60/90 days, 1/2/3 years)
            │                                              id: cleanupCutoffPreset_30d … _3y
            ├── Section « Keep » (footer: vm.keepSummary, calculé)
            │   ├── Toggle("Keep favorites")               id: cleanupKeepFavoritesToggle
            │   ├── Picker("Keep on device") → CleanupKeepMediaType.allCases
            │   │                                          id: cleanupKeepMediaTypePicker
            │   └── NavigationLink → AlbumPickerView("Keep albums", vm.albums, keepAlbumIDs)
            │                                              id: cleanupKeepAlbumsRow
            ├── Section « Scan »
            │   ├── Button("Scan") en PVPrimaryButtonStyle, .disabled(!vm.canScan)
            │   │                                          id: cleanupScanButton
            │   ├── if vm.isScanning: ProgressView + Text("Scanning your library…")
            │   │                                          id: cleanupScanProgress
            │   └── if vm.errorMessage != nil: InlineErrorBadge(message:retry:)
            └── Section « Result »  (si vm.scannedCount > 0)
                ├── LabeledContent "Scanned" / "To delete" / "Reclaimable"
                │     id: cleanupScannedValue, cleanupToDeleteValue, cleanupReclaimableValue
                ├── LabeledContent "Already gone from the server"  id: cleanupNotOnServerValue
                ├── LabeledContent "Kept in iCloud Shared Albums"  id: cleanupSharedAlbumValue
                ├── NavigationLink → CleanupReviewView(vm: vm) : « Review N items »,
                │     .disabled(candidates.isEmpty)        id: cleanupReviewRow
                ├── si scannedCount > 0 && candidates.isEmpty:
                │     ContentUnavailableView("Nothing to free up", …)
                └── footer: corbeille système + « reste disponible dans Immich » + albums iCloud

CleanupReviewView                  (@Bindable vm, @Environment(\.dismiss))
├── .navigationTitle("Review") · .navigationBarTitleDisplayMode(.inline)
├── en-tête (hors ScrollView) : LabeledContent("Reclaimable") id: cleanupReviewReclaimableValue
│                              LabeledContent("To delete")     id: cleanupReviewCountValue
├── ScrollView → LazyVStack(pinnedViews: .sectionHeaders), un jour par Section (décroissant)
│   ├── Section header: date abrégée + « N items » + volume du jour
│   └── LazyVGrid(3 × .flexible, spacing: PVSpacing.s4) → BackupThumbnailView(
│         localIdentifier: candidate.id).aspectRatio(1, .fill)
├── .safeAreaInset(edge: .bottom) → bouton destructif pleine largeur id: cleanupReviewFreeButton
└── .confirmationDialog(isPresented: $showDeleteConfirm), bouton destructif id: cleanupReviewConfirm
```

Fond `Color.bgPrimary` ; le `Form` reste natif (groupé, insets système), comme `BackupSettingsView` — pas de seconde grammaire de formulaire dans le même hub.

## Composants

| Besoin | Composant existant |
|---|---|
| Bouton principal « Scan » | `PVPrimaryButtonStyle` (`PVButtonStyle.swift:9`) |
| Bouton destructif de la revue | `Button(role: .destructive)` en `PVSubtleButtonStyle`, pleine largeur |
| Erreur non bloquante du scan | `InlineErrorBadge` (`InlineErrorBadge.swift:11`) |
| Vignette d'un candidat | `BackupThumbnailView` (`UploadViewModel.swift:976`) |
| Choix des albums conservés | `AlbumPickerView` (`UploadViewModel.swift:921`) — `@Binding Set<String>` |
| Mise en forme des octets | `StorageStatsViewModel.format(_:)` — **unique** implémentation |
| État « rien à libérer » | `ContentUnavailableView` (patron de `OfflineAssetsView`) |
| Chiffre d'une ligne du scan | `LabeledContent` natif + `Font.pvNumeric` + `.contentTransition(.numericText())` |

Les pastilles de date sont un composant **privé** à `FreeUpSpaceView.swift` —
`CutoffPresetChip(title:days:isSelected:action:)` : `Button` en `Capsule(style: .continuous)`,
`minHeight: 44`, fond `Color.immichPrimary` si sélectionnée sinon `Color.bgSecondary`, `.pvSubhead` en
`.white` / `Color.textPrimaryPV`, `.buttonStyle(.plain)`. `PVGridCell`, `PVSkeletonGrid` et
`UserAvatarCircle` ne sont **pas** utilisés : vignettes locales de PhotoKit (rien à squelettiser), aucun
utilisateur à montrer dans la revue.

## Interactions

| Geste | Effet |
|---|---|
| Choix d'une date au `DatePicker` | `vm.setCutoff(date)` — **vide `candidates`**, `scannedCount = 0` |
| Tap sur une pastille 30 j … 3 ans | `vm.setCutoff(Calendar.current.date(byAdding: .day, value: -N, to: .now))`, même invalidation |
| Changement d'un filtre (favoris, catégorie, albums conservés) | `vm.setKeepFavorites` / `setKeepMediaType` / `toggleKeepAlbum` — **invalide le scan** dans les trois cas |
| Tap « Scan » | `Task { await vm.scan() }` ; désactivé si `!vm.canScan` (pas de date, scan ou suppression en cours) |
| Tap « Review N items » | pousse `CleanupReviewView` ; désactivé si aucun candidat |
| Tap « Free up space » (revue) | ouvre le `confirmationDialog` (`@State` de la vue, pas du ViewModel) |
| Tap « Delete » du dialogue | `await vm.deleteConfirmed()` puis `dismiss()` si non nil ; l'**alerte système PhotoKit** suit aussitôt |
| Tap « Cancel » | ferme le dialogue ; aucun appel à `deleteLocalAssets` |
| Apparition de l'écran | `vm.loadAlbums()` (`.task`) : purge les albums disparus, applique les albums messagerie une seule fois |
| Suppression réussie | `.onChange(of: vm.lastDeletedCount)` → alerte « Space freed » sur l'écran de réglages ; `vm.resetScan()` vide les candidats **sans toucher aux filtres persistés** |

## Liquid Glass / matériaux

Aucun `glassEffect` sur ces deux écrans : le verre est réservé dans ce dépôt aux surfaces **flottantes**
(barres de recherche, bandeaux, îlot Live Activity), jamais aux écrans de contenu poussés —
`OfflineAssetsView` et `StackView`, poussés depuis le même hub, n'en utilisent pas. Ici ce serait en plus
contre-productif : la revue montre des images, un fond translucide dégraderait leur contraste. Séparateurs
`Color.separatorPV`, fonds `bgPrimary` / `bgSecondary`, insets système du `Form`.

## Accessibilité

- **Identifiants** (sur l'élément interactif ou la valeur qui le porte, jamais sur un conteneur) :
  `freeUpSpaceRow`, `cleanupCutoffDatePicker`, `cleanupCutoffPreset_30d` … `cleanupCutoffPreset_3y`,
  `cleanupKeepFavoritesToggle`, `cleanupKeepMediaTypePicker`, `cleanupKeepAlbumsRow`, `cleanupScanButton`,
  `cleanupScanProgress`, `cleanupScannedValue`, `cleanupToDeleteValue`, `cleanupReclaimableValue`,
  `cleanupNotOnServerValue`, `cleanupSharedAlbumValue`, `cleanupReviewRow`, `cleanupReviewReclaimableValue`,
  `cleanupReviewCountValue`, `cleanupReviewFreeButton`, `cleanupReviewConfirm` (les six pastilles portent
  `cleanupCutoffPreset_30d` / `_60d` / `_90d` / `_1y` / `_2y` / `_3y`).
- **VoiceOver** : chaque cellule de la revue est **un seul** élément (`.accessibilityElement(children:
  .ignore)` + `.accessibilityLabel(vm.accessibilityLabel(for: candidate))`), le ViewModel produisant la
  phrase (« Photo, 12 March 2024, 2.4 MB ») — deux lectures séparées vignette / taille rendraient une
  grille de 200 items impraticable. Les `LabeledContent` du scan gardent l'association native libellé/valeur.
- **Cibles ≥ 44 pt** : pastilles de date (`minHeight: 44`), lignes du `Form` (natives), bouton de revue en
  `.safeAreaInset(edge: .bottom)` pleine largeur — jamais un petit bouton en barre d'outils.
- **Dynamic Type** : grille à **3 colonnes fixes** (comme la timeline), aucune `frame(height:)` figée sur
  les cellules, `LabeledContent` qui passe à la ligne au lieu de tronquer.
- **Reduce Motion** : les `.contentTransition(.numericText())` sont neutralisés par le système ; aucune
  autre animation n'est introduite.
- **Libellés** : chaînes **anglaises** (`Free Up Space`, `Cutoff date`, `30 days` … `3 years`,
  `Keep favorites`, `Keep on device`, `Keep albums`, `Scan`, `Scanning your library…`, `Reclaimable`,
  `To delete`, `Review %lld items`, `Nothing to free up`, `Space freed`) ; la ligne du hub passe par une
  `LocalizedStringKey` (`Label("Free Up Space", …)`), sinon elle n'est jamais extraite et reste en anglais.

## Animations

| Transition | Implémentation | Reduce Motion |
|---|---|---|
| Chiffres du scan qui changent | `.contentTransition(.numericText())` sur les valeurs | neutralisé par le système |
| Apparition de la section « Result » | `.transition(.opacity)` + `PVMotion.standard` | fondu conservé |
| « Scanning… » ⇄ bouton « Scan » | `.transition(.opacity)` sur le remplacement | fondu conservé |
| Sélection d'une pastille de date | `.animation(PVMotion.snappy, value: vm.settings.cutoffDate)` | couleur posée sans transition |
| Grille de revue qui se remplit | aucune animation par cellule (pas de stagger) | — |

Pas de morphing, pas de `glassEffectID`, pas de `scrollTransition` sur la grille : l'écran ne se transforme
pas, il rend une liste. Une apparition en cascade de 10 000 cellules animerait le geste le plus risqué.

## Fichiers touchés

- NEW `Sources/Core/Protocols/LocalCleanupSource.swift` — `CleanupCandidate`, `CleanupScanResult`, `CleanupKeepMediaType`, `LocalCleanupSource`.
- NEW `Sources/Features/FreeUpSpace/CleanupSettingsStore.swift` — filtres persistés + défauts messagerie.
- NEW `Sources/Features/FreeUpSpace/FreeUpSpaceViewModel.swift` — scan, invalidation, suppression.
- NEW `Sources/Features/FreeUpSpace/FreeUpSpaceView.swift` — l'écran de réglages + `CutoffPresetChip`.
- NEW `Sources/Features/FreeUpSpace/CleanupReviewView.swift` — la revue et son `confirmationDialog`.
- NEW `Tests/FreeUpSpaceViewModelTests.swift` — 8 cas nommés (voir spec étape 10).
- EDIT `Sources/Services/PhotoLibraryServiceImpl.swift` — extension `LocalCleanupSource`.
- EDIT `Sources/DependencyContainer.swift` — `cleanupSource` + `makeFreeUpSpaceViewModel()`.
- EDIT `Sources/RootView.swift` — `@State private var freeUpSpace`, passage à `ProfileView`.
- EDIT `Sources/Features/Profile/ProfileView.swift` — `@State var freeUpSpace` + ligne `freeUpSpaceRow`.
- EDIT `Resources/Localizable.xcstrings` — extraction au build, aucune écriture manuelle.
- EDIT `ImmichSwiftUI.xcodeproj/project.pbxproj` — **généré** par `xcodegen generate`, jamais à la main.

## Erreurs à ne pas faire (mesurées dans ce dépôt)

1. **Déclarer un `NavigationStack` dans `FreeUpSpaceView` ou `CleanupReviewView`** : elles vivent dans la
   pile de `ProfileView` (`:25`) ; un second stack donne deux barres de navigation (piège de `LanguageSettingsView`).
2. **Écrire « Delete from Immich », « Remove from the server » ou « Delete permanently »** : ces assets
   **restent sur le serveur** ; seul `deleteLocalAssets` est appelé, jamais `deleteAssets(ids:force:)`.
3. **Annoncer l'espace comme libéré au moment du tap** : les assets partent dans la **corbeille système
   iOS**, que l'app ne peut pas vider ; « Reclaimable » est une **projection**, rendue réelle après avoir
   vidé « Récents supprimés » (~30 jours).
4. **Empiler une deuxième confirmation sans expliquer la première** : `PHAssetChangeRequest.deleteAssets`
   déclenche **toujours** l'alerte système « Autoriser la suppression de N éléments ? » ; notre dialogue ne
   redemande donc pas la même chose (volume, borne de date, destination, sort de l'original côté serveur).
5. **Afficher « Nothing to free up » dès l'entrée dans l'écran** : cet état exige
   `scannedCount > 0 && candidates.isEmpty` ; avant le premier scan, l'écran montre ses réglages, un bouton
   désactivé et le footer « Choose a cutoff date to start scanning. ».
6. **Inverser la sémantique d'`AlbumPickerView`** (`UploadViewModel.swift:921`) : sa sélection signifie
   « albums à traiter » pour Upload, ici « albums à **conserver** » — le libellé porte la différence.
7. **Ne pas invalider le scan quand un filtre change** : `setCutoff` / `setKeepFavorites` / `setKeepMediaType`
   / `toggleKeepAlbum` vident `candidates` (règle upstream de `CleanupNotifier`).
8. **Poser un `accessibilityIdentifier` sur un conteneur** (`Section` « Result », `LazyVGrid`) : il écrase
   ceux des valeurs et boutons qu'il contient (mesuré sur `languageRelaunchToast`) ; un test vise un
   identifiant (`cleanupScanButton`, `cleanupReviewConfirm`), jamais un libellé affiché.
9. **Dupliquer la mise en forme des octets** : `StorageStatsViewModel.format(_:)` (déjà appelée par
   `ProfileView.swift:217`) est l'unique implémentation.
10. **Purger le ledger après la suppression** : ces assets sont toujours sur le serveur ; garder les
    entrées évite un ré-upload complet si l'utilisateur les restaure depuis la corbeille système.
