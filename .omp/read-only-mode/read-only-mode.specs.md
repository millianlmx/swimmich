# Task: read-only-mode

> **Révision du 2026-09-16 — le store est un paramètre OBLIGATOIRE d'`UploadViewModel`.** Il était `readOnly: ReadOnlyModeStore? = nil`
> avec, en repli, `ReadOnlyModeStore()`, c'est-à-dire `UserDefaults.standard` : les tests unitaires tournant DANS le processus de
> l'app, un harness qui ne l'injectait pas lisait le drapeau `readOnlyModeEnabled` laissé sur le simulateur par un scénario UI, et
> `runBackup()` refusait tout — 20 échecs dans `SyncStatusViewModelTests` le 2026-09-16 sans qu'une ligne de code ait changé. La
> signature n'a plus de défaut : chaque appelant nomme le mode qu'il veut (le conteneur le store de l'app, un test
> `ReadOnlyModeStore.ephemeral()`). Ajouter un harness qui appelle un run demande donc, au compilateur, de trancher.

> **Audit 2026-09-15 — écart G17** (`.omp/backlog/ImmichSwiftUI-backlog.md` §2.17, phase P5) : le client Flutter a un mode lecture seule —
> `mobile/lib/providers/infrastructure/readonly_mode.provider.dart` (vérifié sur `immich-app/immich@main`, 2026-09-15) définit
> `class ReadOnlyModeNotifier extends Notifier<bool>`, alimenté par `AppSettingsService.getSetting(AppSettingsEnum.readonlyModeEnabled)`,
> avec `setMode(bool)`, `setReadonlyMode(bool)` et `toggleReadonlyMode()`, exposé par `final readonlyModeProvider = NotifierProvider<ReadOnlyModeNotifier, bool>(…)` ;
> la surface est documentée dans `docs/docs/features/mobile-app.mdx` § « Read-only/kid Mode ».
> Côté iOS, `grep -rn "readOnly\|readonly" Sources/` ne renvoie **aucun** symbole : aucun réglage, aucune garde,
> et les points d'entrée destructeurs du dépôt (inventaire complet ci-dessous) sont tous armés en permanence.

**Objectif** : après cette fiche, l'utilisateur peut basculer l'app en consultation seule — un interrupteur « Read-only Mode » dans le hub « Me », plus un appui long sur l'avatar de la barre de navigation de chaque onglet —
et l'app cesse alors toute **écriture côté serveur** :
suppressions (timeline, viewer, corbeille, doublons, album), retraits d'asset d'album, suppression d'album / de pile / de tag / de lien partagé / d'utilisateur d'album,
mémoires, activités, partenaires, actions d'admin destructrices, upload manuel et sauvegarde automatique, et modifications (favori, note, description, nom d'album).
La lecture, la recherche, le viewer, la carte, le visionnage des liens partagés et les actions purement locales restent intacts.

**Hors périmètre** :
- Un **contrôle serveur** : l'upstream est purement client (le provider ne fait que lire/écrire un réglage local et rediriger vers la timeline). Aucune route de `/tmp/immich-openapi-main.json` n'expose un mode lecture seule ; la fiche n'ajoute ni appel réseau ni champ de DTO.
- Un **verrou par code** sur la désactivation (PIN / biométrie) : c'est le périmètre de `locked-folder` (dossier verrouillé + PIN), pas celui-ci. Ici l'interrupteur est libre — c'est un garde-fou contre les fausses manœuvres, pas une frontière de sécurité.
- Le blocage des opérations **purement locales** : purge du cache hors-ligne (`PhotoViewer.swift:1240`, « Remove from Offline »), `reset backup tracking` (`UploadViewModel.swift:482`), suppression d'un état d'édition local (`Sources/Services/EditStateStore.swift:53`), déconnexion, changement de serveur. Elles ne touchent pas la bibliothèque du serveur.
- Toute nouvelle **vue poussée** : le réglage vit dans `ProfileView`, qui porte déjà le `NavigationStack` (`Sources/Features/Profile/ProfileView.swift:23`) — convention du dépôt : les vues poussées depuis le hub « Me » n'en déclarent pas (`LanguageSettingsView.swift:12` le documente).
- La **traduction** des libellés : les clés sont les chaînes anglaises, extraites par Xcode (catalogue `Resources/Localizable.xcstrings`, `sourceLanguage = en`, un enregistrement par langue cible).

**Hypothèses** (vérifiées dans le dépôt et contre `immich-app/immich@main`, le 2026-09-15) :

- **Upstream — le mécanisme, 100 % client** :
  - `ReadOnlyModeNotifier.build()` lit `AppSettingsEnum.readonlyModeEnabled` ; `setMode(bool)` persiste **puis** publie l'état et, si `value && authProvider.isAuthenticated`, pousse `MainTimelineRoute()` ;
    `toggleReadonlyMode()` = `state = !state; setMode(state)` ; `setReadonlyMode(bool)` = `state = isEnabled; setMode(state)` — deux points d'entrée pour la même mutation, ce que la fiche reproduit avec `setEnabled(_:)` et `toggle()`.
  - Aucun appel réseau, aucun `serverVersion.supports(…)` : le mode est un `bool` de réglage d'app, gardé par un provider Riverpod que les widgets d'action consultent.
  - La documentation associée est `docs/docs/features/mobile-app.mdx` § « Read-only/kid Mode » ; l'upstream ne l'expose que sur mobile, pas d'équivalent web.
- **La couture d'écriture est unique et typée côté iOS** : toutes les VMs et le moteur de backup reçoivent `client as any ImmichClient` depuis `DependencyContainer`
  (`Sources/DependencyContainer.swift:71` pour `UploadViewModel`, `:93` pour `TimelineViewModel`, `:215` pour `OfflineDownloadViewModel`). Un seul point de passage ⇒ une seule garde à poser, et les vues qui appellent le client directement (`PhotoViewer`, `StackSheet`) sont couvertes sans être modifiées.
- **Les 22 méthodes destructrices ou modificatrices du protocole**, `Sources/Core/Protocols/ImmichClient.swift` :
  - `deleteAssets(ids:force:)` `:49`, `restoreTrashAssets(ids:)` `:52`, `restoreAllTrash()` `:53`, `emptyTrash()` `:54` ;
  - `deleteAlbum(id:)` `:74`, `removeAssetsFromAlbum(albumId:dto:)` `:76`, `deleteSharedLink(id:)` `:98` ;
  - `uploadAssetToSharedLink(…)` `:140`, `uploadAsset(…)` `:264` ;
  - `deleteTag(id:)` `:155`, `deleteActivity(id:)` `:193`, `deleteMemory(id:)` `:204` ;
  - `deleteStack(id:)` `:230`, `removeAssetFromStack(stackId:assetId:)` `:231` ;
  - `deleteAdminUser(id:force:)` `:237`, `deleteLibrary(id:)` `:243`, `deleteAPIKey(id:)` `:246` ;
  - et les modifications : `updateAsset(id:dto:)` `:48`, `updateAlbum(id:dto:)` `:73`, `updateTag(id:color:)` `:154`, `updateMemory(id:dto:)` `:203`, `updateStack(id:primaryAssetId:)` `:229`.
  - `ImmichAPIClient` les implémente en clair et sans garde (`Sources/Services/ImmichAPIClient.swift:154` `deleteAssets` → `DELETE /api/assets`, `:169` `emptyTrash` → `POST /api/trash/empty`, `:222` `deleteAlbum` → `DELETE /api/albums/{id}`, `:433` `removePartner`, `:525` `deleteStack`).
- **Inventaire des points d'entrée destructeurs du dépôt iOS** (grep du 2026-09-15 ; `chemin:ligne`) :
  - *Suppression d'assets*
    - `Sources/Features/Timeline/TimelineView.swift:238` (multi), `:262` (unitaire), `:546` (bouton de barre) → `TimelineViewModel.deleteSelected()` `:112` / `delete(id:)` `:346` → `client.deleteAssets(force: false)` `:117`, `:348`.
    - `Sources/Features/Timeline/AssetThumbnailCell.swift:99` (`onDeletePermanent`) et `:121` (`onDelete`) — menu contextuel de chaque tuile, deux entrées distinctes.
    - `Sources/Features/Albums/AlbumDetailView.swift:158`, `:309`, `:428` → `AlbumDetailViewModel.deleteSelected()` `:103` → `client.deleteAssets` `:108`.
    - `Sources/Features/PhotoViewer/PhotoViewer.swift:246` (`confirmDelete()`), `:584` (libellé du menu), et les **deux appels directs au client dans la vue** : `:781` (`force: true`) et `:792` (`force: false`).
    - `Sources/Features/Trash/TrashView.swift:53` (unitaire permanent), `:243` (bouton « Empty Trash ») → `TrashViewModel.deletePermanently(id:)` `:132` → `client.deleteAssets(force: true)` `:134`.
    - `Sources/Features/Duplicates/DuplicatesView.swift:58` (dialog) et `:90` (rangée) → `DuplicatesViewModel.deleteGroup(id:)` `:43` → `client.deleteAssets` `:52`.
  - *Corbeille*
    - `Sources/Features/Trash/TrashView.swift:67` (alert « Empty Trash? ») → `TrashViewModel.emptyTrash()` `:148` → `client.emptyTrash()` `:150`.
  - *Retrait d'asset d'album*
    - `Sources/Features/Albums/AlbumDetailView.swift:144` (sélection), `:324` (alert), `:428` et `:522` (unitaire) → `AlbumDetailViewModel.removeSelected()` / `removeAssets(ids:)` `:186` → `client.removeAssetsFromAlbum` `:66`, `:186`.
  - *Album et son partage*
    - `AlbumDetailView.swift:251` + `:293` → `AlbumDetailViewModel.deleteAlbum()` `:202` → `client.deleteAlbum` `:204`.
    - `Sources/Features/Albums/AlbumShareSheet.swift:54` (dialog) et `:147` (rangée) → `vm.revoke(userId:)`.
    - `AlbumDetailViewModel.deleteSharedLink` `:321` → `client.deleteSharedLink` `:321`.
  - *Piles*
    - `Sources/Features/Stacks/StackView.swift:42` (swipe) → `StacksViewModel.deleteStack(id:)` `:110` → `client.deleteStack` `:112`.
    - `Sources/Features/Stacks/StackDetailView.swift:64`, `:112` (unstack) et `:160`, `:179` (retrait d'un membre, swipe + menu) → `StacksViewModel.removeAssetFromStack` `:131` → `client.removeAssetFromStack` `:133`.
    - `Sources/Features/PhotoViewer/StackSheet.swift:86`, `:97` — **appels directs au client dans la vue** : `:121` (`removeAssetFromStack`) et `:132` (`deleteStack`).
  - *Tags* — `Sources/Features/Tags/TagsViewModel.swift:41` → `client.deleteTag` `:43`.
  - *Mémoires* — `Sources/Features/Memories/MemoriesView.swift:121` et `Sources/Features/Memories/MemoryMomentView.swift:307` → `MemoriesViewModel.deleteMemory(id:)` `:150` → `client.deleteMemory` `:152`.
  - *Activités* — `Sources/Features/Albums/ActivityFeedSheet.swift:34` → `ActivityFeedViewModel.deleteActivity(id:)` `:97` → `client.deleteActivity` `:99`.
  - *Admin* — `Sources/Features/Admin/AdminView.swift:73` (user, `force: true`), `:83` (bibliothèque), `:234` (clé API) → `AdminViewModel.deleteUser` `:70`, `deleteLibrary` `:113`, `deleteAPIKey` `:136`.
  - *Partenaires* — `client.removePartner(id:)` (`ImmichAPIClient.swift:433`, `DELETE /api/partners/{id}`) : liste bloquée même si la vue correspondante n'a pas été relevée ligne à ligne.
  - *Upload manuel et automatique* — `client.uploadAsset(…)` (`ImmichClient.swift:264`), appelé par le moteur que `UploadViewModel` construit avec le client du conteneur (`DependencyContainer.swift:71`).
- **Ce qui rend la fiche nécessaire** :
  - Huit sites au moins appellent le client **depuis une vue** (`PhotoViewer.swift:781`, `:792` ; `StackSheet.swift:121`, `:132` ; `StackDetailView.swift:163`, `:179`) ou depuis une fermeture d'action de cellule (`AssetThumbnailCell.swift:99`, `:121`) : tout gating posé dans un ViewModel les rate par construction.
  - Les seuls garde-fous existants sont des `confirmationDialog` par action, qui ne protègent ni d'un oubli ni d'un appui long involontaire — et il n'existe aucune garde au niveau du client.
- **Précédents à réutiliser** :
  - `AppLanguageStore` (`Sources/Features/Settings/AppLanguageStore.swift`) est déjà `@MainActor @Observable` avec persistance d'un réglage d'appareil, injecté dans l'arbre depuis `RootView`.
  - `AuthenticatedRoot` injecte déjà deux objets de processus via `.environment(container.offlineIndex)` et `.environment(offline)` (`Sources/RootView.swift:199-202`).
  - L'avatar est `struct ProfileAvatarButton` (fin de `Sources/RootView.swift`), un `Button` portant `.accessibilityIdentifier("profileAvatar")` et `.accessibilityLabel("Profile")`, monté par chaque onglet.

**Approche retenue** : A — un `ReadOnlyModeStore` (`@MainActor @Observable`, persistant) injecté dans l'environnement pour l'UI, **plus** un décorateur `ReadOnlyGuardClient: ImmichClient` posé une seule fois dans `DependencyContainer`,
qui jette `APIError.readOnlyMode` sur les 22 méthodes d'écriture listées et relaie les lectures. Deux effets complémentaires : l'UI ne propose plus l'action, et le client refuse encore si un chemin oublié la déclenche.
- **B (rejetée)** : ne poser que des `.disabled` / `if !readOnly.isEnabled` sur les boutons destructeurs → l'inventaire ci-dessus compte huit sites où la vue appelle le client hors de tout ViewModel, plus des `swipeActions` et des `Menu`/`contextMenu` imbriqués (`StackView.swift:41`, `AssetThumbnailCell.swift:99`) ; un site oublié ne fait échouer aucun test — il supprime. Le décorateur, lui, est contrôlé par le compilateur : une méthode non relayée **ne compile pas**.
- **C (rejetée)** : refuser au niveau HTTP dans `sendAuthed`/`sendAuthedRaw` (`Sources/Services/ImmichAPIClient.swift`) selon le verbe et le chemin → il faudrait ré-encoder en correspondance de routes une sémantique déjà portée par des méthodes typées (le même `POST` porte `emptyTrash` et `restoreAllTrash`, qu'il faut distinguer), et l'ajout d'une méthode destructrice au protocole ne ferait plus échouer la compilation : la garde deviendrait silencieusement incomplète.

## Étapes

1. **Le store** — NEW `Sources/Features/ReadOnly/ReadOnlyModeStore.swift` : `import Foundation`, `import Observation`.
   `@MainActor @Observable final class ReadOnlyModeStore` avec `static let defaultsKey = "readOnlyModeEnabled"` (le nom du réglage upstream, `AppSettingsEnum.readonlyModeEnabled`), `private let defaults: UserDefaults`,
   `private(set) var isEnabled: Bool`, `init(defaults: UserDefaults = .standard)` qui lit `defaults.bool(forKey: Self.defaultsKey)`,
   `func setEnabled(_ value: Bool)` qui écrit `defaults.set(value, forKey: Self.defaultsKey)` **avant** de publier `isEnabled = value` (même ordre que `ReadOnlyModeNotifier.setMode`, pour qu'un kill immédiat ne perde pas le réglage), `func toggle() { setEnabled(!isEnabled) }`,
   et `nonisolated static func isEnabledIn(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: defaultsKey) }` — lecture thread-safe appelée depuis le décorateur de l'étape 2, qui ne peut pas toucher un `@MainActor` depuis une méthode `async` non isolée.
2. **Le décorateur** — NEW `Sources/Features/ReadOnly/ReadOnlyGuardClient.swift` : `struct ReadOnlyGuardClient: ImmichClient` avec `let inner: any ImmichClient`, `let isEnabled: @Sendable () -> Bool`, et `private func assertWritable() throws { if isEnabled() { throw APIError.readOnlyMode } }`.
   Il relaie **toutes** les méthodes de `ImmichClient` (`try await inner.getMemories()`, `try await inner.searchMetadata(dto: dto)` `:57`, `try await inner.getServerStatistics()` `:249` : la signature exacte de chaque méthode relayée est recopiée de `ImmichClient.swift`), sauf les 22 de l'inventaire, qui commencent par `try assertWritable()`. Les lectures ne paient aucune vérification.
   Commentaire d'en-tête : « Toute méthode d'écriture ajoutée à `ImmichClient` DOIT être classée ici ; le compilateur force la relecture de ce fichier, pas la classification — c'est le seul endroit à regarder ».
3. **L'erreur** — EDIT `Sources/Core/Types/APIError.swift` : ajouter `case readOnlyMode` à l'`enum APIError` (`:5-11`) et sa branche dans `var errorDescription` (`:13`) → `String(localized: "Read-only mode is on. Turn it off in Me to change your library.")`.
4. **L'injection conteneur** — EDIT `Sources/DependencyContainer.swift` : ajouter `let readOnly: ReadOnlyModeStore` et `private let guardedClient: any ImmichClient`.
   Dans `init()` (`:56`) : construire le client, puis `self.readOnly = ReadOnlyModeStore()`, puis
   `self.guardedClient = ReadOnlyGuardClient(inner: client as any ImmichClient, isEnabled: { ReadOnlyModeStore.isEnabledIn(defaults) })` **avant** la construction de `self.upload` (`:71`) ;
   remplacer ensuite les occurrences de `client as any ImmichClient` passées aux VMs (`:71`, `:93`, `:215`, et les `make*ViewModel()` suivants) par `guardedClient`.
   Le champ `let client: ImmichAPIClient` (`:9`) reste tel quel : il sert aux appels bas niveau du conteneur (confiance serveur, session), pas à la bibliothèque.
5. **Le câblage racine** — EDIT `Sources/RootView.swift` : dans `AuthenticatedRoot`, ajouter `.environment(readOnly)` à côté de `.environment(container.offlineIndex)` / `.environment(offline)` (`:199-202`), en lisant le store depuis le conteneur, et passer `readOnly: readOnly` à l'appel `ProfileView(…)` du `.sheet(isPresented: $showProfile)`.
6. **Le geste sur l'avatar** — EDIT `Sources/RootView.swift` (`struct ProfileAvatarButton`) : ajouter `@Environment(ReadOnlyModeStore.self) private var readOnly`.
   Le `Button(action:)` devient le même glyphe portant `contentShape(Circle())`, `.onTapGesture(perform: action)`, `.onLongPressGesture(minimumDuration: 0.5) { readOnly.toggle() }` et `.accessibilityAddTraits(.isButton)` —
   la paire tap/long-press de SwiftUI fait échouer le tap quand l'appui dépasse sa durée, donc l'appui long n'ouvre pas la feuille « Me » ; un `Button` avec `.simultaneousGesture(LongPressGesture…)` déclencherait les deux.
   `.accessibilityIdentifier("profileAvatar")` et `.accessibilityLabel("Profile")` sont conservés (le test UI s'y accroche), et un badge `Image(systemName: "lock.fill")` de 12 pt est superposé sur le coin bas-droit du cercle **uniquement** quand `readOnly.isEnabled` (12 pt depuis le 2026-09-16, quand l'avatar est passé d'un disque de 30 pt à un disque de 44 pt : le badge est ancré sur le cercle lui-même, plus sur une couronne de padding) : l'appui long a alors un effet visible immédiatement, sur le contrôle lui-même.
7. **Le réglage** — EDIT `Sources/Features/Profile/ProfileView.swift` : ajouter `@State var readOnly: ReadOnlyModeStore` aux propriétés stockées (après `language`, `:19`), puis dans la section Security qui porte déjà `Toggle("Require Face ID", isOn: $appLockEnabled)` (`:132`) une ligne
   `Toggle("Read-only Mode", isOn: Binding(get: { readOnly.isEnabled }, set: { readOnly.setEnabled($0) }))` portant `.accessibilityIdentifier("readOnlyModeToggle")`, avec `Text("Prevents deleting, editing and uploading. Browsing stays available.")` en pied de section.
   Le placement dans Security est délibéré : `ProfileView` n'a pas de section « Advanced » (contrairement à l'upstream, dont le hub de réglages est un écran séparé) et ce réglage est une préférence d'appareil au même titre que Face ID juste au-dessus.
8. **L'upload** — EDIT `Sources/Features/Upload/UploadViewModel.swift` : d'une part, en tête de `runBackup(overrideSettings:manual:)` (`:298`), un `guard !readOnly.isEnabled else { return }` précédé de la publication du message d'échec déjà rendu par l'écran Backup (propriété d'erreur du VM, à confirmer) ; d'autre part le CTA de lancement de la section d'actions (`:651-919`) reçoit `.disabled(readOnly.isEnabled)`.
   Le réglage est lu par `@Environment(ReadOnlyModeStore.self)` dans la vue d'actions du même fichier ; le VM reçoit le store dans son `init` (le conteneur le construit, `DependencyContainer.swift:71`).
   La garde du décorateur (étape 2) bloquerait de toute façon chaque `uploadAsset`, mais refuser le run en amont évite de produire N échecs pour un refus unique.
9. **Les tests** — NEW `Tests/ReadOnlyModeTests.swift` : `import XCTest`, `@testable import ImmichSwiftUI`, `final class ReadOnlyModeTests: XCTestCase`, `@MainActor`, avec les dépendances déjà en place dans `Tests/` (`UserDefaults(suiteName: "read-only-\(UUID().uuidString)")!`, `MockImmichClient`) :
   `test_defaultsToDisabled`, `test_setEnabled_persistsAcrossInstances` (un second `ReadOnlyModeStore` sur le même `UserDefaults` relit `true`), `test_toggle_flipsAndPersists`, `test_guardClient_blocksDeletion` (chaque méthode destructrice lève `APIError.readOnlyMode` et le mock n'enregistre **aucun** appel), `test_guardClient_blocksUpload`, `test_guardClient_forwardsReadsWhenEnabled` (`getTimelineBuckets` / `getAsset` atteignent le mock), `test_guardClient_forwardsWritesWhenDisabled`.
10. **Le catalogue de chaînes** — aucune écriture manuelle dans `Resources/Localizable.xcstrings` : la clé est la chaîne anglaise, extraite par Xcode au build. Chaînes neuves des étapes 3, 6 et 7 : `Read-only Mode`, `Read-only`, `Prevents deleting, editing and uploading. Browsing stays available.`, `Read-only mode is on. Turn it off in Me to change your library.`
11. `xcodegen generate` (deux fichiers source et un fichier de test ont été ajoutés : sans régénération ils ne sont pas compilés) puis la suite complète `-only-testing:ImmichSwiftUITests`.

## Incertitudes à lever à l'implémentation

- **Le nom exact de la propriété d'erreur d'`UploadViewModel`** (étape 8) et le nom du journal d'appels de `MockImmichClient` (étape 9). Vérifier par : `grep -n "errorMessage\|lastError\|message" Sources/Features/Upload/UploadViewModel.swift Tests/MockImmichClient.swift`.
- **L'instance de `UserDefaults` du conteneur** (étape 4) : la garde doit lire **la même** instance que le store, sinon elle lira un magasin différent. Vérifier par : `grep -n "UserDefaults" Sources/DependencyContainer.swift` — si le conteneur injecte déjà une suite nommée (comme `BackupSettingsStore(suiteName:)`), la réutiliser.
- **La complétude des 22 méthodes bloquées** : la liste vient d'un grep sur `ImmichClient.swift` ; d'autres écritures peuvent exister (`createAlbum`, `createSharedLink`, `createMemory`, `createActivity`, `tagAssets`/`untagAssets`, `addUsersToAlbum`, `removeUserFromAlbum`, `addAssetsToSharedLink`). Vérifier par : `grep -n "^    func " Sources/Core/Protocols/ImmichClient.swift` et classer chaque méthode en lecture/écriture — le compilateur garantit que le décorateur implémente tout, pas qu'il classe bien.
- **Le test UI de l'avatar** (étape 6) : remplacer le `Button` par un glyphe à gestes explicites doit rester atteignable par XCUITest. Vérifier par : `xcodebuild test -only-testing:ImmichSwiftUITests -destination 'platform=iOS Simulator,name=iPhone 17'` sur le test qui tape `profileAvatar` (la feuille « Me » doit toujours s'ouvrir) — si la requête ne trouve plus d'élément de type `Button`, revenir au `Button` et déplacer l'appui long sur un `contextMenu` de l'avatar.
- **Le refus côté viewer** : `PhotoViewer.swift:781` et `:792` avalent les erreurs (`catch {}`). Une fois la garde active, l'utilisateur n'aurait **aucun** retour si ces deux sites étaient atteints. Vérifier par : `grep -n "catch {}" Sources/Features/PhotoViewer/PhotoViewer.swift` puis décider si ces appels remontent l'erreur au lieu de l'avaler.
- **L'effet sur la sauvegarde automatique** : `container.kickOffAutoBackup()` est déclenché par le deep link `.backup` (`Sources/RootView.swift`, `.onOpenURL`) et par l'observation de la photothèque. Vérifier par : `grep -n "kickOffAutoBackup" Sources/DependencyContainer.swift` — si le chemin contourne `runBackup`, y poser la même garde qu'à l'étape 8.
