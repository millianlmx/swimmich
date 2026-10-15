# Task: read-only-mode — UI Brief

> Compagnon de `.omp/read-only-mode/read-only-mode.specs.md` (écrit le 2026-09-15). Ne pas dupliquer la spec :
> ce document ne décrit que la **surface** — placement, hiérarchie de vues, gestes, états, tokens.

> **Révision du 2026-09-16 — l'avatar a grossi.** `ProfileAvatarButton` était un disque de 30 pt dans un
> cadre de 44 pt ; c'est désormais un disque de **44 pt** (cadre et cible de tap de la même taille : le
> `contentShape(Circle())` s'inscrit sur le cercle, plus sur une couronne de padding). Initiales passées de
> 13 à 18 pt. Demande de l'utilisateur, déclenchée par le bouton de synchronisation posé à sa gauche le même
> jour : le disque de verre de ce dernier fait 44 pt, et l'avatar de 30 pt paraissait plus petit que lui.
> Conséquence sur cette fiche : le cadenas est désormais ancré en `.overlay(alignment: .bottomTrailing)` du
> **cercle** (et non du cadre paddé) et passe de 10 à 12 pt — il chevauche le rim bas-droit, vérifié au
> scénario `ReadOnlyModeUITests` (`/tmp/shot-03-long-press-read-only-on.png`). La hauteur du bouton ne
> change pas : l'empreinte en barre reste 44 pt, seul le disque dessiné grandit.

## Design Philosophy

Le mode lecture seule est un **état de l'appareil**, pas un écran. Sa surface doit donc répondre à trois
exigences, dans cet ordre :

1. **Rien ne subsiste qui puisse détruire.** Quand le mode est actif, les affordances destructrices ne sont
   pas désactivées : elles **n'existent plus**. Un bouton grisé sans phrase d'explication est un bug d'UI —
   l'utilisateur doit pouvoir conclure « cette app ne me laisse pas supprimer en ce moment » sans deviner.
2. **L'état actif est visible sans occuper l'écran.** Un seul marqueur permanent : un cadenas de 12 pt sur
   l'avatar. **Aucun bandeau permanent**, aucune bannière, aucun filigrane, aucune barre teintée : le mode
   est fait pour durer des semaines, il ne doit pas crier en permanence.
3. **Sortir du mode tient en un geste.** Le même appui long qui l'a activé le désactive, ou le `Toggle` du
   hub « Me ». Aucun code, aucune confirmation, aucune alerte : c'est un garde-fou contre les fausses
   manœuvres, pas une frontière de sécurité (le PIN est le périmètre de `locked-folder`).

Corollaire de mise en œuvre : l'UI n'est **jamais** la garde. La garde est le décorateur `ReadOnlyGuardClient`
de la spec (étape 2) ; le travail de surface consiste à ne pas **montrer** ce qui ne peut plus aboutir.

## Placement dans la navigation

- **Le réglage** : `ProfileView` (hub « Me »), section **Security**, immédiatement après la ligne
  « Require Face ID » (`Sources/Features/Profile/ProfileView.swift:132`), avec le pied de section explicatif.
  Écart mesuré avec l'upstream : Flutter a un écran de réglages séparé avec une section « Advanced » ;
  **`ProfileView` n'a aucune section `Advanced`** dans ce dépôt, et ce réglage est une préférence d'appareil
  au même titre que Face ID juste au-dessus. On ne crée pas de section `Advanced` pour un seul interrupteur.
- **Le geste** : `ProfileAvatarButton`, en fin de `Sources/RootView.swift`, monté par la barre de navigation
  de **chaque** onglet. Le geste est donc disponible partout, y compris là où le hub n'est pas ouvert.
- **Le toggle du hub ne navigue pas.** L'upstream pousse la timeline après activation
  (`ReadOnlyModeNotifier.setMode`) ; côté iOS la bascule laisse l'utilisateur où il est. Une redirection
  involontaire depuis la feuille « Me » ferait perdre le contexte de réglage en cours.
- Aucune `NavigationStack` n'est ajoutée : `ProfileView` en porte déjà un, et le réglage ne crée pas d'écran.

## Layout

```
ProfileAvatarButton                       (barre de navigation de CHAQUE onglet)
└── glyphe  contentShape(Circle()) + onTapGesture(action:) + onLongPressGesture(minimumDuration: 0.5)
    │   .accessibilityIdentifier("profileAvatar")  .accessibilityAddTraits(.isButton)
    │   .accessibilityLabel("Profile")  .accessibilityValue(isEnabled ? "Read-only" : "")
    ├── UserAvatarCircle
    └── Image(systemName: "lock.fill")    12 pt, coin bas-droit, UNIQUEMENT si readOnly.isEnabled
        .accessibilityHidden(true)        ← décoratif : l'état est porté par la value de l'avatar

ProfileView  (feuille « Me », NavigationStack déjà porté par ProfileView:23)
└── Form
    ├── (sections existantes : Account, Management…)
    └── Section « Security »
        ├── Toggle « Require Face ID »          (inchangé)
        ├── Toggle « Read-only Mode »           readOnlyModeToggle
        │     Binding(get: readOnly.isEnabled, set: readOnly.setEnabled)
        ├── PVStatusBadge « Read-only »          seulement si actif, `.immichWarning`
        └── footer  Text("Prevents deleting, editing and uploading. Browsing stays available.")

TrashView  (mode actif)
├── barre : bouton « Empty Trash »             ABSENT (pas grisé : retiré du ToolbarItem)
├── rangées : swipe + menu « Delete Permanently » ABSENT
└── corbeille vide → ContentUnavailableView("Trash is empty", systemImage: "trash",
                                            description: Text("Deleted assets appear here."))
                                            (chaîne neuve, extraite par Xcode comme les autres)

BackupSettingsView  (mode actif)
└── CTA de lancement de la section d'actions   .disabled(true)   ← seule exception « grisé » du dépôt
     │                                           (voir « Interactions » : le pied de section explique)
     └── footer existant de la section : « Read-only mode is on. Turn it off in Me to change your library. »
```

## Composants

Réutiliser, ne pas créer :

| Besoin | Composant existant |
|---|---|
| Barre d'outils d'un écran dont un bouton disparaît (corbeille de la timeline, corbeille) | `ImmichAppBar` — le `ToolbarItem` destructeur n'est **pas construit**, on ne le désactive pas |
| Marqueur d'état actif dans le hub | `PVStatusBadge` (`Read-only`, `.immichWarning`) — jamais un bandeau plein écran |
| Avatar | `UserAvatarCircle` (glyphe déjà utilisé par `ProfileAvatarButton`) ; le cadenas est une `Image(systemName: "lock.fill")` posée par-dessus |
| Retour d'un refus atteint malgré tout | `InlineErrorBadge` affichant `APIError.readOnlyMode` (`"Read-only mode is on. Turn it off in Me to change your library."`) — voir « Erreurs » §8 |
| Corbeille vide | `ContentUnavailableView` — l'état vide existant, sans CTA en mode lecture seule |
| Réglage | `Toggle` nu dans le `Form` de `ProfileView` (même forme que « Require Face ID ») — pas de `PVInputGroup`, pas de `PVFieldSurface` : ce n'est pas un formulaire de saisie |

Le seul composant **neuf** est le cadenas d'avatar : une `Image` de 12 pt, `Color.immichWarning`, avec un
liseré de 1 pt en `Color.bgPrimary` pour rester lisible sur n'importe quelle photo. Aucun `glassEffect`.

## Interactions

| Geste | Effet |
|---|---|
| Tap sur l'avatar | Ouvre la feuille « Me » — **inchangé** (le `Button` devient un glyphe à gestes explicites, spec étape 6) |
| **Premier appui long sur l'avatar** (≥ 0,5 s) | Bascule le mode **ON** : le cadenas apparaît instantanément sur l'avatar lui-même, la feuille « Me » **ne s'ouvre pas**. Aucun dialogue, aucune alerte, aucune navigation : le retour est le badge, sur le contrôle qu'on vient de presser. C'est la seule découvrabilité du geste — elle est donc **immédiate et locale**, jamais différée |
| Second appui long | Bascule **OFF**, le cadenas disparaît. Aucun autre changement à l'écran |
| Tap `readOnlyModeToggle` (hub) | `readOnly.setEnabled(_:)` — le badge d'avatar et le `PVStatusBadge` suivent dans le même frame |
| Appui long < 0,5 s relâché | Rien : la paire `onTapGesture` / `onLongPressGesture` fait échouer le tap quand l'appui dépasse sa durée (piège mesuré, spec étape 6) |
| Tap sur une affordance destructrice | **Impossible** : l'élément n'est pas dans la hiérarchie. Aucune alerte « action refusée », aucun bouton grisé |
| Tap sur le CTA de sauvegarde (écran Backup) | Ignoré (`.disabled`) — le pied de section de la section d'actions explique pourquoi ; `runBackup` republie le même message si le chemin automatique est emprunté |
| Pull-to-refresh, recherche, viewer, carte, liens partagés | Inchangés : la lecture ne paie aucune vérification |

### Ce qui disparaît à l'écran, par surface

| Surface | Affordance retirée (site mesuré) | Ce que l'utilisateur voit |
|---|---|---|
| Timeline | Bouton corbeille de la barre (`TimelineView.swift:546`), entrée en sélection multiple (`:238`), menu contextuel de tuile « Delete » / « Delete Permanently » (`AssetThumbnailCell.swift:99`, `:121`) | La barre n'a plus de bouton destructeur ; le menu contextuel de tuile perd ses deux entrées et garde les autres ; la sélection multiple ne s'arme plus |
| Viewer photo | Menu delete (`PhotoViewer.swift:584`), `confirmDelete()` (`:246`), les deux appels directs `:781` / `:792` | Le menu du viewer n'a plus d'entrée de suppression |
| Album (détail) | Sélection + suppression (`AlbumDetailView.swift:144`, `:324`, `:428`), retrait d'asset (`:522`), suppression d'album (`:251`, `:293`), révocation de partage (`AlbumShareSheet.swift:54`, `:147`), suppression de lien (`deleteSharedLink`) | La barre de l'album n'a plus « Delete Album » ni les actions de sélection ; la feuille de partage perd ses rangées de révocation |
| Piles | Swipe de suppression (`StackView.swift:42`), unstack (`StackDetailView.swift:112`), retrait d'un membre (`:160`, `:179`), actions du `StackSheet` (`:86`, `:97`) | Les `swipeActions` destructrices disparaissent (le swipe n'offre plus d'action) ; le menu de pile garde ses entrées de lecture |
| Corbeille | Suppression définitive unitaire (`TrashView.swift:53`), « Empty Trash » (`:67`, `:243`) | Voir le bloc `TrashView` du layout : plus aucun CTA dans la barre, aucune action par rangée |
| Doublons | Suppression de groupe (`DuplicatesView.swift:58`, `:90`) | L'écran reste consultable, sans action de résolution |
| Tags / Mémoires / Activités / Admin / Partenaires | `TagsViewModel:41`, `MemoriesView.swift:121` + `MemoryMomentView.swift:307`, `ActivityFeedSheet.swift:34`, `AdminView.swift:73`, `:83`, `:234`, `removePartner` | Les rangées de suppression / retrait disparaissent de ces listes |
| Upload manuel et sauvegarde auto | `uploadAsset` (`ImmichClient.swift:264`) | Le CTA est grisé **avec** le pied de section qui l'explique — seule exception au principe « on retire, on ne grise pas » |

## Liquid Glass / matériaux

Pas de `glassEffect` sur cette feature. Le verre du dépôt est réservé aux surfaces **flottantes** ; l'avatar
vit déjà dans une barre de navigation dont le système gère le matériau, et un `GlassEffectContainer` autour
d'un cadenas de 12 pt serait du bruit. Le liseré `bgPrimary` du badge suffit à le détacher d'une photo claire.
Le `PVStatusBadge` du hub est un badge ordinaire (fond `bgSecondary`), pas une surface en verre.

## Accessibilité

- **Identifiants** — posés sur les éléments **interactifs**, jamais sur un conteneur qui en contient (piège
  mesuré sur `languageRelaunchToast`, où le conteneur écrasait l'identifiant de son bouton) :
  `profileAvatar` (conservé — le test UI existant s'y accroche), `readOnlyModeToggle` (nouveau).
  Les affordances **retirées** n'ont évidemment aucun identifiant : les tests s'appuient sur leur absence
  (`!app.buttons["…"].exists`), pas sur un état désactivé.
- **Le cadenas n'est pas un élément d'accessibilité** : `.accessibilityHidden(true)`. L'état est exposé par
  `.accessibilityValue(Text("Read-only"))` sur l'avatar, pour qu'une seule annonce soit faite.
- **VoiceOver ne peut pas faire d'appui long** : l'avatar porte une `.accessibilityAction(named: Text("Read-only Mode"))`
  qui appelle le même `readOnly.toggle()`. Le réglage du hub reste la seconde voie.
- **Cible ≥ 44 pt** : le glyphe conserve `contentShape(Circle())` sur toute sa boîte — le geste long ne dépend
  pas de la précision sur le cadenas (qui est décoratif, donc non tappable isolément).
- **Dynamic Type** : aucun `frame` figé ; le pied de section du `Toggle` et le texte du
  `ContentUnavailableView` suivent la taille du texte.
- **Reduce Motion** : seule animation concernée, l'apparition du cadenas (voir ci-dessous) ; neutralisée par
  le système, l'état restant lisible sans mouvement.
- **Chaînes** (clés anglaises, extraites par Xcode) : `Read-only Mode`, `Read-only`,
  `Prevents deleting, editing and uploading. Browsing stays available.`,
  `Read-only mode is on. Turn it off in Me to change your library.`, plus la chaîne de l'état vide de la
  corbeille. Aucune écriture manuelle dans `Resources/Localizable.xcstrings`.

## Animations

| Transition | Implémentation | Reduce Motion |
|---|---|---|
| Cadenas qui apparaît / disparaît | `.transition(.opacity.combined(with: .scale(scale: 0.7)))`, `PVMotion.standard`, pilotée par `withAnimation` autour de la bascule | fondu conservé (le liseré reste), le badge ne « pousse » plus |
| `PVStatusBadge` du hub | même `withAnimation` que la bascule | système |
| Affordances qui disparaissent | **aucune animation d'adieu** : les `ToolbarItem` / entrées de menu ne sont pas construits. Une animation de sortie sur un bouton qu'on vient de retirer est un scintillement sans information | — |
| CTA grisé de la sauvegarde | changement d'état `.disabled` (opacité système) | système |

Pas de morphing, pas de `matchedGeometryEffect`, pas de `glassEffectID` : rien ne se transforme, un mode
change d'état.

## Fichiers touchés

- NEW `Sources/Features/ReadOnly/ReadOnlyModeStore.swift` — `@MainActor @Observable`, clé `readOnlyModeEnabled`, `nonisolated static isEnabledIn(_:)`.
- NEW `Sources/Features/ReadOnly/ReadOnlyGuardClient.swift` — le décorateur des 22 méthodes d'écriture.
- EDIT `Sources/Core/Types/APIError.swift` — `case readOnlyMode` + `errorDescription`.
- EDIT `Sources/DependencyContainer.swift` — `readOnly`, `guardedClient`, remplacement des `client as any ImmichClient`.
- EDIT `Sources/RootView.swift` — `.environment(readOnly)`, passage à `ProfileView`, et le geste + le badge de `ProfileAvatarButton`.
- EDIT `Sources/Features/Profile/ProfileView.swift` — `@State var readOnly` + `Toggle` dans Security + `PVStatusBadge`.
- EDIT `Sources/Features/Upload/UploadViewModel.swift` — garde en tête de `runBackup` + `.disabled` sur le CTA.
- NEW `Tests/ReadOnlyModeTests.swift` — les 7 cas de la spec.

## Erreurs à ne pas faire (mesurées dans ce dépôt)

1. **Poser le badge sur un conteneur.** Un `accessibilityIdentifier` sur un conteneur écrase celui de tous ses
   descendants (mesuré sur `languageRelaunchToast`) : ici il ferait perdre `profileAvatar` et `readOnlyModeToggle`.
2. **Griser un contrôle destructeur au lieu de le retirer.** Aucune affordance destructrice ne doit rester
   visible en mode actif : un bouton grisé sans phrase d'explication laisse croire à une panne. La seule
   exception du dépôt est le CTA de sauvegarde, et elle est **expliquée par le pied de section**.
3. **Ajouter un bandeau permanent** « Read-only mode is on ». Le mode dure des semaines : le marqueur
   permanent est le cadenas de l'avatar ; le message long n'apparaît que là où une action est refusée
   (`InlineErrorBadge`) ou grisée (pied de l'écran Backup).
4. **Mettre l'appui long sur un `Button` avec `.simultaneousGesture(LongPressGesture…)`** : les deux gestes
   se déclenchent, la feuille « Me » s'ouvre **et** le mode bascule (piège relevé à l'étape 6 de la spec).
   D'où le glyphe à `onTapGesture` / `onLongPressGesture` explicites, avec `contentShape(Circle())`.
5. **Croire que l'UI suffit à bloquer.** Huit sites appellent le client depuis une **vue**
   (`PhotoViewer.swift:781`, `:792` ; `StackSheet.swift:121`, `:132` ; `StackDetailView.swift:163`, `:179`)
   ou depuis une fermeture de cellule (`AssetThumbnailCell`), et il existe des `swipeActions` et des `Menu`
   imbriqués : un site oublié ne fait échouer aucun test — il supprime.
6. **Laisser `catch {}` avaler le refus.** `PhotoViewer.swift:781` et `:792` avalent les erreurs : sans
   changement, l'utilisateur n'aurait **aucun** retour si ces sites étaient atteints. Ils doivent remonter
   `APIError.readOnlyMode` jusqu'à l'`InlineErrorBadge`.
7. **Déclarer une `NavigationStack`** : le réglage vit dans `ProfileView`, qui en porte déjà une ; les vues
   poussées depuis le hub « Me » n'en déclarent pas.
8. **Écrire un littéral français dans une vue** : la clé du catalogue est la chaîne anglaise.
9. **Annoncer un geste que le test UI ne peut plus trouver.** Le passage du `Button` au glyphe à gestes peut
   changer le type d'élément XCUITest : vérifier que le test qui tape `profileAvatar` trouve toujours un
   élément de type `Button` ; sinon, repli documenté par la spec — garder le `Button` et déplacer l'appui
   long sur un `contextMenu` de l'avatar.
