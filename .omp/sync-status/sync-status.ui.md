# Task: sync-status — UI Brief

> Compagnon de `.omp/sync-status/sync-status.specs.md` (écrit le 2026-09-15). Ne pas dupliquer la spec :
> ce document ne décrit que la **surface** — placement, hiérarchie de vues, gestes, états, tokens.

> **Révision du 2026-09-16 — changement de porte et de présentation.** L'écran ne s'ouvre plus depuis la
> section Management du hub « Me » (la ligne `syncStatusRow` a été retirée : le hub porte déjà Backup, et
> deux surfaces de sauvegarde dans le même `Form` se lisaient comme un doublon). Il s'ouvre depuis
> `SyncStatusButton` — un bouton de barre posé à **gauche de l'avatar de profil**, dans les quatre barres
> d'onglet (Photos n'en a pas : le bouton rejoint l'overlay `topTrailing`, à droite de la pastille
> « Select » et à gauche de l'avatar) et **présenté en feuille** par `RootView`, comme le hub lui-même. La
> barre d'outils gagne donc un `Button("Done")` (`syncStatusDone`, `.confirmationAction`) : c'est la seule
> sortie explicite d'une feuille dont les actions destructives sont derrière un dialogue de confirmation.
> L'anneau de progression du run, qui entourait l'avatar de profil dans l'onglet Photos, entoure désormais
> le bouton de synchronisation — le bouton de profil ne porte plus aucun état de synchronisation.
> Identifiant du bouton : `syncStatusButton` (libellé VoiceOver « Sync Status », traduit).
>
> Geometrie de la paire (2026-09-16) : le disque de verre de `SyncStatusButton` fait 44 pt, et
> `ProfileAvatarButton` a été porté le même jour d'un disque de 30 pt (dans un cadre de 44) à un disque de
> **44 pt** — même diamètre, cible de tap inchangée à 44 pt. Les deux cercles se lisent comme une paire ;
> réduire l'un des deux casse cet équilibre.
>
> Glyphe du bouton (2026-09-16) : `icloud.and.arrow.up` — le « cloud backup » demandé par l'utilisateur, et
> le glyphe de sauvegarde du dépôt (ligne Backup du hub, `AppIntents`, Live Activity). L'ancien
> `arrow.triangle.2.circlepath` n'avait été choisi que pour ne pas concurrencer la ligne Backup dans la même
> liste du hub ; le bouton ayant quitté cette liste, la contrainte est tombée. Les glyphes **internes** à
> l'écran ne changent pas (`Run now` / `Check server` / l'état vide gardent `arrow.triangle.2.circlepath`,
> c'est-à-dire l'action de relancer, pas la sauvegarde).

## Design Philosophy

L'écran répond à une seule question, en trois secondes : **« où en est ma sauvegarde, et qu'est-ce qui
cloche ? »**. C'est une page de **constat**, pas de réglage : aucun contrôle n'y modifie une préférence.
La hiérarchie est donc celle d'un tableau de bord sobre — des chiffres alignés, un état par ligne, et une
seule action principale (« Run now ») qui reflète l'état courant (elle devient « Stop » pendant un run).
Le vocabulaire visuel est celui du reste de l'app (tokens du DesignSystem, verre réservé aux surfaces
flottantes) : rien n'est inventé ici.

## Placement dans la navigation

- Poussée depuis **`ProfileView`** (hub « Me »), section `Management`, **immédiatement après la ligne
  Backup** et avant Notifications. Justification : l'écran lit le ledger que l'écran Backup alimente ;
  l'upstream place la tuile de statut de sync dans le même groupe que le backup
  (`mobile/lib/pages/common/settings.page.dart`, tuile `SettingSection.beta`).
- `SyncStatusView` **ne déclare aucun `NavigationStack`** : `ProfileView` en porte déjà un
  (`Sources/Features/Profile/ProfileView.swift:24`). Un second stack produit deux barres de navigation
  (piège relevé lors de la livraison de `LanguageSettingsView`).
- Pas de rôle d'onglet, pas de feuille : c'est un écran de détail avec retour natif.

## Layout

```
SyncStatusView                            (poussée par ProfileView)
└── ScrollView
    └── VStack(spacing: PVSpacing.s16)
        ├── Section « Ledger & run »      → VStack(spacing: PVSpacing.s8)
        │   ├── Card: statistiques        → LazyVGrid(2 colonnes, spacing: PVSpacing.s8)
        │   │   ├── StatTile(Tracked)          StatTile(Waiting)
        │   │   ├── StatTile(Ready to upload)  StatTile(Already on server)
        │   │   ├── StatTile(Failed)           StatTile(Offline)
        │   │   └── StatTile(Offline size)     — (cellule vide si impair)
        │   ├── Row: Last run              → LabeledContent + PVStatusBadge
        │   └── Row: Last server check     → LabeledContent + PVStatusBadge
        ├── Section « Actions »
        │   ├── Button « Run now » / « Stop »   (.borderedProminent, pleine largeur)
        │   ├── Button « Check server »         (.bordered)
        │   └── Button « Reset tracking »       (.bordered, role: .destructive)
        ├── Section « Offline »
        │   ├── LabeledContent: assets épinglés + volume
        │   └── Button « Purge offline cache »  (.bordered, role: .destructive)
        └── Section « Failures » (seulement si vm.failures est non vide)
            └── DisclosureGroup « N failed » → lignes nom de fichier + raison
```

- **Barre d'outils** : `ToolbarItem(placement: .principal) { ImmichAppBar(title: "Sync Status") }` à
  l'intérieur de la feuille, `.navigationBarTitleDisplayMode(.inline)`, et — la feuille étant la seule
  sortie — un `ToolbarItem(placement: .confirmationAction) { Button("Done") }` (`syncStatusDone`), comme
  `DownloadInfoView` : « Done » ne fait que refermer l'écran, un run lancé ici continue.
- **Progression vivante** : quand `vm.isRunning`, insérer entre les statistiques et les actions une
  `ProgressView(value: vm.progressFraction)` (barre déterminée) suivie du nom du fichier courant en
  `.pvCaption` — la même grammaire que le segment bar de `BackupSettingsView`, jamais un `ProgressView()`
  indéterminé, qui ne dit rien.
- **Rafraîchissement** : `.refreshable { await vm.refresh() }` (recharge l'index hors-ligne) et
  `.task { await vm.refresh() }` au premier affichage.
- **Fond** : `Color.bgPrimary`. Les cartes utilisent `Color.bgSecondary` (jamais de blanc littéral).

## Composants

Réutiliser, ne pas créer :

| Besoin | Composant existant |
|---|---|
| Tuile de statistique | motif local `StatTile` (voir ci-dessous), bâti sur `PVHeaderBadge`/**`Font.pvNumeric`**, ou `PVStatusBadge` pour l'état |
| En-tête de section | `Section { … } header: { Text("…") }` dans un `Form`, ou `PVHeaderBadge` en `ScrollView` |
| État d'une ligne (idle/syncing/success/error) | `PVStatusBadge` (couleurs `.immichSuccess/.immichWarning/.immichError`) |
| Erreur non bloquante | `InlineErrorBadge` |
| Avatar / icône secondaire | `Image(systemName:)` en `.font(.pvHeadline)` — pas de glyphe héros |

```swift
/// Contrat local à l'écran (à déclarer dans SyncStatusView.swift).
private struct StatTile: View {
    let title: LocalizedStringKey        // clé EN, jamais un littéral français
    let value: String                    // déjà mis en forme par le ViewModel
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s4) {
            Label(title, systemImage: systemImage)
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
            Text(value)
                .font(.pvNumeric)                         // chiffres alignés entre tuiles
                .foregroundStyle(Color.textPrimaryPV)
                .contentTransition(.numericText())        // les compteurs ne « sautent » pas
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PVSpacing.s12)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
    }
}
```

Le ViewModel fournit **des chaînes déjà mises en forme** pour les compteurs et les dates
(`vm.formattedOfflineBytes()`, `vm.formattedLastRun()`) : la vue ne formate jamais un nombre ou une date
(une seule mise en forme de bytes dans le dépôt, celle d'`OfflineDownloadViewModel.formattedUsage(_:)`).

## Interactions

| Geste | Effet |
|---|---|
| Tap « Run now » | `await vm.runNow()` — reprend la file, puis attend la fin du run ; le bouton devient « Stop » dès que `vm.isRunning` |
| Tap « Stop » | `vm.cancelRun()` — le run se termine proprement (`isCancelling` affiché en `.immichWarning`) |
| Tap « Check server » | `await vm.reconcileNow()` — confrontation du ledger au serveur ; désactivé pendant un run |
| Tap « Reset tracking » | `confirmationDialog` destructif → `vm.resetLedger()` (le prochain backup recontrôlera tout) |
| Tap « Purge offline cache » | `confirmationDialog` destructif → `await vm.clearOfflineCache()` |
| Pull-to-refresh | `await vm.refresh()` |
| Tap sur une ligne d'échec | Rien dans cette fiche : la liste se déplie, la navigation par asset appartient à `upload-detail` (AC-5040–5049) |
| État vide (`vm.isEmpty`) | `ContentUnavailableView("Nothing to sync yet", systemImage: "arrow.triangle.2.circlepath", description: Text("Back up your library to see its status here."))` — pas de tuiles à 0 empilées |

Chaque action destructive s'arrête si un run est en cours ou si le VM est occupé ; l'état désactivé est
porté par le bouton (`.disabled(...)`), jamais par une alerte d'erreur.

## Liquid Glass / matériaux

Pas de `glassEffect` sur cet écran. Précédent du dépôt : le verre est réservé aux surfaces **flottantes**
(barres de recherche, bandeaux, îlot Live Activity), pas aux écrans de contenu poussés — `StackView` et
`OfflineAssetsView` n'en utilisent pas non plus. Les séparateurs `Color.separatorPV` et les fonds
`bgSecondary` suffisent ; ajouter du verre ici casserait la cohérence des écrans du hub « Me ».
Une seule exception, et elle est hors de l'écran : dans l'onglet Photos, le bouton de synchronisation
n'est pas dans une barre de navigation — iOS n'y dessine donc pas le chrome — et il porte un disque
`glassEffect(.regular, in: Circle())`, de la même famille que la pastille « Select » voisine. Dans les
quatre onglets à barre, un `glassEffect` manuel **doublerait** le verre système et se ferait rogner
(mesure de `SearchView`) : le bouton y reste un glyphe nu.

## Accessibilité

- **Identifiants** (sur les éléments interactifs, jamais sur un conteneur qui en contient) :
  `syncStatusButton` (bouton de barre, `RootView`), `syncStatusDone` (sortie de la feuille), `syncStatusRunButton`, `syncStatusCancelButton`, `syncStatusReconcileButton`,
  `syncStatusResetButton`, `syncStatusPurgeOfflineButton`, `syncStatusTrackedValue`, `syncStatusPendingValue`,
  `syncStatusStagedValue`, `syncStatusUploadedValue`, `syncStatusAlreadyOnServerValue`, `syncStatusFailedValue`,
  `syncStatusOfflineValue`, `syncStatusOfflineBytesValue`, `syncStatusLastRunValue`, `syncStatusLastCheckValue`,
  `syncStatusProgress`, `syncStatusFailureRow_<index>`.
- **VoiceOver** : chaque tuile est un seul élément (`accessibilityElement(children: .combine)`) avec un label
  parlant produit par le VM (`"12 tracked assets"`), jamais deux lectures séparées libellé/valeur.
- **Dynamic Type** : `LazyVGrid` à 2 colonnes fixes ; les valeurs en `.pvNumeric` tolèrent les tailles
  d'accessibilité (pas de `frame(height:)` figé sur les tuiles).
- **Cibles** ≥ 44 pt : boutons en pleine largeur pour la section Actions.
- **Reduce Motion** : `contentTransition(.numericText())` est neutralisé automatiquement ; aucune autre
  animation n'est introduite.
- Le libellé du bouton de barre reste « Sync Status » ; les autres chaînes sont des clés anglaises
  (`Tracked`, `Waiting`, `Ready to upload`, `Already on server`, `Failed`, `Offline`, `Last run`,
  `Last server check`, `Never`, `Run now`, `Stop`, `Check server`, `Reset tracking`, `Purge offline cache`,
  `Nothing to sync yet`).

## Animations

| Transition | Implémentation | Reduce Motion |
|---|---|---|
| Compteurs qui changent | `.contentTransition(.numericText())` sur les valeurs | neutralisé par le système |
| Apparition de la barre de progression | `.transition(.opacity)` sur le bloc, `PVMotion.standard` | fondu conservé |
| Bascule Run now ⇄ Stop | `.contentTransition(.symbolEffect(.replace))` sur l'icône | remplacement instantané |
| Lignes d'échec dépliées | `DisclosureGroup` (animation système) | système |

Aucune animation de morphing, aucun `matchedGeometryEffect`, aucun `glassEffectID` : l'écran ne se
transforme pas, il se met à jour.

## Fichiers touchés

- NEW `Sources/Features/SyncStatus/SyncStatusView.swift` — l'écran et son `StatTile` privé.
- NEW `Sources/Features/SyncStatus/SyncStatusViewModel.swift` — projections calculées + délégation (voir la spec).
- NEW `Tests/SyncStatusViewModelTests.swift` — 8 cas nommés.
- EDIT `Sources/DependencyContainer.swift` — `makeSyncStatusViewModel(upload:offline:)`.
- EDIT `Sources/RootView.swift` — `@State private var syncStatus`, clé d'environnement `openSyncStatus`, `SyncStatusButton` (déclaration + `syncStatusButton`), la feuille `NavigationStack { SyncStatusView(vm:) }`, et le bouton posé dans les barres d'Albums / Memories / SharedLinks / Search.
- EDIT `Sources/Features/Timeline/TimelineView.swift` — `SyncStatusButton` dans l'overlay `topTrailing` (disque de verre) et `backupProgressRing` déplacé de l'avatar vers ce bouton.
- REMOVED `Sources/Features/Profile/ProfileView.swift` — la propriété `syncStatus` et la ligne `syncStatusRow` de Management.

## Erreurs à ne pas faire (mesurées dans ce dépôt)

1. **Créer un second `BackupEngine` pour lire les compteurs du run** : deux engines se disputent la Live
   Activity et le second afficherait « 0 en attente » pendant qu'un run tourne dans `container.upload`
   (le commentaire du champ `upload` de `DependencyContainer` documente ce bug). Cet écran **compose** les
   ViewModels existants.
2. **Poser un `accessibilityIdentifier` sur le conteneur de tuiles** : il écraserait les identifiants des
   valeurs (mesuré sur `languageRelaunchToast`, où le bouton devenait introuvable).
3. **Déclarer un `NavigationStack` dans `SyncStatusView`** : c'est la feuille de `RootView` qui porte le
   sien (même règle que `DownloadInfoView`), un second dessinerait deux barres de navigation.
4. **Poser un `glassEffect` manuel sur le bouton dans une barre de navigation** : iOS 26 y dessine déjà son
   verre ; un disque manuel double la couche et se fait rogner (mesuré sur `SearchView`). Le seul site qui
   en a besoin est l'overlay de l'onglet Photos, qui n'a pas de barre.
5. **Attendre les deux boutons dans la barre de résultats de l'onglet Search** : cette barre déborde déjà en
   menu « … » sans le bouton de synchronisation (mesuré le 2026-09-16 par A/B : avec et sans lui, la barre
   montre quatre icônes puis « … », l'avatar compris dans le menu). Le bouton y est atteignable, pas visible
   en clair — ce n'est pas une régression, et l'onglet Search hors mode résultats montre bien les deux.
6. **Afficher un `ProgressView()` indéterminé** pendant un run : `progressFraction` est disponible, la barre
   doit être déterminée, avec le nom du fichier courant.
7. **Recalculer une mise en forme de bytes ou de date dans la vue** : deux implémentations divergent
   (une seule existe aujourd'hui, `OfflineDownloadViewModel.formattedUsage(_:)`).
8. **Écrire un littéral français dans la vue** : la clé du catalogue est la chaîne anglaise.
9. **Rendre les actions destructives sans confirmation** : `resetLedger()` et `clearOfflineCache()` passent
   par un `confirmationDialog` (le hub utilise déjà ce motif pour « Delete user? »).
10. **Lire le compteur « Failed » comme une liste d'assets cliquable** : la navigation par asset appartient
   à `upload-detail` ; ici on affiche une liste dépliable, sans promesse d'écran qui n'existe pas.
