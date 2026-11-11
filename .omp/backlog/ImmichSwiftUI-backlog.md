# ImmichSwiftUI — Backlog d'Implémentation

> **Objectif** : Porter l'intégralité des fonctionnalités du client Flutter Immich upstream vers ImmichSwiftUI (iOS 26, SwiftUI, MVVM).
>
> **Architecture cible** : MVVM strict 4 couches — Core/Protocols, Core/Types, Services, Features, DesignSystem.
>
> **Validation** : `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17'` — baseline **886 tests** (dernier relevé le 2026-09-14, TEST SUCCEEDED ; comptage direct : 886 `func test*` dans `Tests/`). Chaque scénario XCUITest exige *son* stub sur le port 8421 : la régression se compte sur la suite unitaire (`-only-testing:ImmichSwiftUITests`).

---

## Table des matières

1. [Tableau de suivi](#tableau-de-suivi)
2. [Phases d'implémentation](#phases-dimplémentation)
3. [Fiches features détaillées](#fiches-features-détaillées)
4. [Référence API — endpoints ImmichClient](#référence-api--endpoints-immichclient)
5. [Checklists de vérification](#checklists-de-vérification)

---

## Tableau de suivi

| # | Feature | Phase | AC Cards | Spéc | Prompt | Status | Endpoints manquants | Tests | Progression |
|---|---------|-------|----------|------|--------|--------|---------------------|-------|-------------|
| 1 | **Backup Auto** | P2 | AC-BK01–BK10 | .omp/backup-auto/ | Voir §2.1 | ✅ Terminé | — | suite 692 verte | 7/10 AC (BK05, BK06, BK08 obsolètes) |
| 2 | **OAuth2 UI** | P5 | AC-3000–3007 | .omp/oauth2-ui/ | Voir §2.2 | ✅ Terminé | — (wire) | 6 `test_oauth_*` | 8/8 AC |
| 3 | **Partners UI** | P3 | AC-3100–3113 | .omp/partners-ui/ | Voir §2.3 | ✅ Terminé | — (2 wire, 1 corrigé) | 14 + 4 + 1 XCUITest | 14/14 AC |
| 4 | **Memories Complete** | P4 | AC-3200–3208 | .omp/memories-complete/ | Voir §2.4 | ✅ Terminé | — (100% wire) | 16 + 7 + 1 XCUITest | 9/9 AC |
| 5 | **Notifications** (ex « Push Notifications ») | P5 | AC-4100–4107 | .omp/push-notifications/ | Voir §2.5 | ✅ Terminé | — (aucun : pas de contrat serveur) | 6 + 1 XCUITest | 8/8 AC |
| 6 | **Shared Links Enriched** | P3 | AC-3900–3909 | .omp/shared-links-enriched/ | Voir §2.6 | ✅ Terminé | — (slug + URL builder + presets, 100% wire) | suite 736 → 749 | 10/10 AC |
| 7 | **Offline Download** | P4 | AC-3500–3512 | .omp/offline-download/ | Voir §2.7 | ✅ Terminé | — (FileManager) | 17 + 8 + 1 XCUITest | 13/13 AC |
| 8 | **Widgets Home Screen** | P5 | AC-3600–3620 | .omp/widgets-homescreen/ | Voir §2.8 | ✅ Terminé | — (3 widgets + Lock Screen, Keychain partagé) | 14 + 13 tests | 12/12 AC |
| 9 | **Stacks UI** | P3 | AC-3700–3709 | .omp/stacks-ui/ | Voir §2.9 | ✅ Terminé | — (100% wire) | 13 + 7 + 3 + 1 | 10/10 AC |
| 10 | **i18n Completing** | P5 | AC-3800–3807 | .omp/i18n/ | Voir §2.10 | ✅ Terminé | — (localisation) | 14 + 1 XCUITest | 7/7 AC |
| 11 | **Backup — Live Photos** | P2 | AC-LP01–LP07 | .omp/backup-auto/backup-live-photos.specs.md | Voir §2.11 | ✅ Terminé | — (updateAsset wire) | 11 | 7/7 AC |
| 12 | **Backup — Album Scoping** | P2 | AC-AS01–AS08 | .omp/backup-auto/backup-album-scoping.specs.md | Voir §2.12 | ✅ Terminé | — | 5 + 3 | 8/8 AC |
| 13 | **Backup — Ledger Reconciliation** | P2 | AC-LR01–LR08 | .omp/backup-auto/backup-ledger-reconciliation.specs.md | Voir §2.13 | ✅ Terminé | — (bulk-upload-check wire) | 13 | 8/8 AC |
| 14 | **Backup — Network Policy** | P2 | AC-NP01–NP07 | .omp/backup-auto/backup-network-policy.specs.md | Voir §2.14 | ✅ Terminé | — | 7 | 7/7 AC |
| 15 | **Backup — Library Observer** | P2 | AC-LO01–LO08 | .omp/backup-auto/backup-library-observer.specs.md | Voir §2.15 | ✅ Terminé | — (PhotosKit) | 6 | 7/8 AC (LO08 manuel) |
| 16 | **Shared Link Viewer** (issue #22) | P3 | AC-4000–4005 | — (feature neuve, sans parité Flutter) | Voir §2.16 | ✅ Terminé | — (100% wire) | 6 + 20 + 1 XCUITest | 6/6 AC |

**Legend** :
- 🔴 **Pending** — Spéc existante, pas de card AC générée
- 🟡 **Plan** — Card AC générée, phase planifiée
- 🟢 **En cours** — Implémentation en cours
- ✅ **Terminé** — Tous les AC passent

---

## Phases d'implémentation

```
P0 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ API Foundation (DTOs, Endpoints)
P1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ Core UX (Navigation, Auth, Settings)
P2 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ Backup (Auto-backup, Live Activity)
P3 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ Social (Partners, Stacks, Shared Links)
P4 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ Discovery (Memories, Offline, Search)
P5 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ Platform (Widgets, Push, OAuth2, i18n)
```

---

## Fiches features détaillées

### 2.1. Backup Auto (P2) — ✅ Terminé (2026-09-09, clôturé le 2026-09-10)

**Fichier spec** : `.omp/backup-auto/backup-auto.specs.md` (section « État au 2026-09-09 »)
**Card AC** : `.opencode/scratch/backup-auto.acceptance.md`
**UI brief** : `.omp/backup-auto/backup-auto.ui.md`
**AC Cards** : AC-BK01 – AC-BK10
**Phase** : P2 — Backup

#### Résultat
AC-BK01, BK02, BK03, BK04, BK07, BK10 **PASS**. Suite complète **691 tests, TEST SUCCEEDED** (iPhone 17, 2026-09-10). Les 5 suites P2 (§2.11 – §2.15) et les cards `backup-engine` / `backup-live-activity` sont vertes sur leurs checks grep — révision du 2026-09-10 de 8 checks périmés (signatures de protocole et surfaces évoluées entre-temps, un check `grep -qA3 | grep` structurellement inopérant, trois summaries /tmp orphelins).

**AC-BK05 et AC-BK06 sont OBSOLÈTES** : `UploadProgressBanner` a été supprimé volontairement et remplacé par l'anneau de progression autour de l'avatar (`TimelineView.avatarBackupRing`). Les critères pinnent une surface UI abandonnée — ne pas les « réparer ».

**AC-BK08 est OBSOLÈTE depuis le 2026-09-10** : la sheet Backfill (glass morphing) a été retirée — doublon du scoping d'albums + « Run now ». AC-BK03/BK04/BK07 ont été révisés en conséquence, et AC-BK10 couvre le remplacement (mode d'albums tri-état).

**Le toggle « Require Face ID » a quitté l'écran Backup le 2026-09-10** pour ProfileView (« Me » → Security) : l'app lock garde l'application entière, pas la sauvegarde (AC-114 suit la surface).

#### Livré
- `BackupSettingsStore` : `isEnabled`, `onlyOnWiFi`, `onlyWhenCharging`, `allowCellularForPhotos`, `allowCellularForVideos`, `autoDetectNewPhotos`, mode d'albums tri-état + les deux ensembles d'albums, persistés clés `photoBackup*` (`UploadViewModel.swift:24-160`) — ⚠ `excludeCameraRoll`/`excludeWhatsApp` ont été SUPPRIMÉS par §2.12 (heuristiques nom-de-fichier fausses sur iOS)
- `UploadViewModel` : `resumeUpload()`, `uploadHistory`, `kickOffAutoBackupIfConfigured()` — ⚠ le backfill (`runBackfill`/`BackfillSheet`) a été **retiré le 2026-09-10** : doublon du scoping d'albums + « Run now », et le libellé « Reorganize » mentait (aucune réorganisation côté serveur)
- `BackupSettingsView` (Auto backup + Albums + Progress + Backup tracking/Server check/Reset), `AlbumPickerView`, `BackupFailuresSheet`, `BackupThumbnailView`
- Pipeline durci : export→SHA1 streamé→upload séquentiel (mémoire bornée par `maxBatchBytes`), `ContinuationGate`, `BackupLedger` anti-re-download, bucket `deferredCount` pour l'iCloud pas encore local
- Chaîne BGTask auto-resoumise en tête de handler (`ImmichSwiftUIApp.swift:44-63`), assertion background UIKit, Live Activity + Dynamic Island, anneau in-app
- Tests : `BackupEngineTests` (55 tests), `UploadViewModelTests` + `UploadViewModelLiveActivityTests`, `BackupLedgerReconciliationTests`, `PhotoLibraryChangeMonitorTests`

#### Suites (écarts réels restants vs Flutter)
Cinq items séparés, tous en P2 et **livrés** : §2.11 Live Photos, §2.12 Album Scoping, §2.13 Ledger Reconciliation, §2.14 Network Policy, §2.15 Library Observer.

#### Résidu connu (hors périmètre backup)
15 chaînes d'UI neuves de l'écran Backup (dont « Run now », « Retry failed », « Use cellular for photos/videos », « Last server check », « Tracked photos », « Albums to back up/skip ») **n'ont pas d'entrée dans `Resources/Localizable.xcstrings`** — elles s'affichent en anglais, comme les 126 autres littéraux de `Sources/` déjà sans clé. **SOLDÉ le 2026-09-14** par §2.10 (issue #21) : ces 15 chaînes ont leur clé, le catalogue couvre désormais 629 clés en fr/de/es/it et plus aucun littéral de `Sources/` n'est orphelin.

---

### 2.2. OAuth2 UI (P5) — ✅ Terminé (2026-09-08, réconcilié le 2026-09-10)

**Fichier spec** : `.omp/oauth2-ui/oauth2-ui.specs.md`
**Card AC** : `.opencode/scratch/oauth2-ui.acceptance.md`
**UI brief** : `.omp/oauth2-ui/oauth2-ui.ui.md`
**AC Cards** : AC-3000 – AC-3007
**Phase** : P5 — Auth & Platform

#### Résultat
AC-3000 – AC-3007 **PASS** (8/8, vérifiés par exécution de chaque check le 2026-09-10). Suite complète **692 tests, TEST SUCCEEDED** (iPhone 17, baseline 691).

#### Livré
- `AuthViewModel` (`Sources/Features/Auth/AuthViewModel.swift`) : `oauthRedirectURI = "app.immich:///oauth-callback"` (l.32), `oauthSessionHandler: (URL) async -> URL?` injectable (l.35-37), `canOAuthLogin` gate sur `serverConfig.oauthButtonText` (l.239), `startOAuthFlow()` — authorize (PKCE) → session navigateur → `exchangeOAuthCode` → `applySession` partagé avec le login mot de passe (l.248-289)
- `OAuthPKCE` (`Sources/Core/Utilities/OAuthPKCE.swift`) : `state`, `codeVerifier`, `codeChallenge` = base64url(SHA256(verifier)) sans padding
- `OAuthSessionPresenter` (`Sources/Services/OAuthSessionPresenter.swift`) : `ASWebAuthenticationSession` + ancre première `UIWindowScene` key-window, `callbackScheme = "app.immich"` (doit matcher `CFBundleURLTypes`, `Resources/Info.plist:25-33`)
- `LoginScreen` (`Sources/Features/Auth/Onboarding/LoginScreen.swift`) : bouton SSO conditionnel libellé par le serveur (fallback « Sign in with SSO »), séparateur `orDivider` « OU », spinner in-flight (l.53-74, 110-119)
- Tests : 6 `test_oauth_*` dans `Tests/AuthViewModelTests.swift` (gate serveur, succès complet, annulation, URL malformée, erreur serveur, serveur sans OAuth)

#### Réconciliation (2026-09-10)
Les critères d'origine pinnaient une surface **jamais construite** et écartée par la conception : `oauthResult`/`oauthAuthorizationURL`/`handleOAuthCallback(url:)`, `OAuthLoadingView.swift` (sheet glass), `.onOpenURL` dans `ImmichSwiftUIApp`, littéral « Sign in with Provider ». Le callback est capturé par `ASWebAuthenticationSession` (`callbackURLScheme`) — un handler de deep link serait du code mort. Carte, spec et UI brief réécrits sur la surface réelle ; même classe de dérive que les 8 checks réécrits le même jour pour `backup-engine`/`backup-live-activity`.

#### Correctif trouvé pendant la réconciliation
`startOAuthFlow()` sortait par `return` sur annulation et sur URL provider malformée **avant** `isLoading = false` → le CTA de login restait désactivé et le bouton SSO grisé définitivement. Corrigé par `defer { isLoading = false }` (l.256) + `test_oauth_cancelLeavesStateUntouched` et `test_oauth_malformedProviderURLResetsLoading` (échec prouvé avant correctif, PASS après).

#### Limite assumée
Flow non vérifiable bout-en-bout sans serveur Immich avec provider OIDC : la session navigateur est injectée, la vérification reste manuelle.

---

### 2.3. Partners UI (P3) — ✅ Terminé (2026-09-13)

**Fichier spec** : `.omp/partners-ui/partners-ui.specs.md`
**Card AC** : `.opencode/scratch/partners-ui.acceptance.md`
**UI brief** : `.omp/partners-ui/partners-ui.ui.md`
**AC Cards** : AC-3100 – AC-3113
**Phase** : P3 — Social

#### Résultat (2026-09-13)
**14/14 AC PASS.** Suite **724 → 736 tests, TEST SUCCEEDED** (iPhone 17) + `test_06_partners` de bout en bout contre le stub **committé** `UITests/stubs/immich_stub_partners.py` (le premier stub du dépôt : celui des piles vit dans `/tmp`). `Sources/Features/Partners/` : `PartnersViewModel` (deux directions, invitation par annuaire, mutations bornées à leur collection), `PartnersView` (deux sections dans le hub « Me »), `InvitePartnerSheet` (annuaire − soi − déjà partenaires, CTA armé à la sélection), `PartnerRow`/`PartnerAvatarCircle` (déplacés depuis `SharedLinksView`, scindés par mode : entrant = toggle, sortant = retrait). Bloc partenaires **retiré** de `SharedLinksView`/`SharedLinksViewModel`. Le journal du stub après le scénario prouve ce que l'app envoie : deux `GET` avec `direction`, un `POST` `{sharedWithId}`, un `DELETE` sur le partenaire **sortant**, et aucune requête sans `direction` (celle qui répondait 400). Piège majeur : `.buttonStyle(.plain)` sur un `Button` dans une `List` avale le tap (le CTA d'invitation restait grisé) — même classe de défaut que le picker de piles.

> **Révision du 2026-09-13 (avant implémentation)** — vérification faite sur l'OpenAPI publié (`main`, `v1.106.0`, `v1.135.0`, `v1.140.0`, `v1.142.0`) et les sources serveur. Quatre erreurs de la fiche d'origine sont corrigées ici :
> - **`GET /api/partners?direction=` n'est pas optionnel** : `direction` est `required` dans toutes les versions vérifiées. Le `getPartners()` **actuellement wire** (`ImmichAPIClient.swift:324`, appelé par `SharedLinksView`) part donc sans query et reçoit un **400** — la section partenaires de l'onglet Shared est cassée au runtime aujourd'hui. Aucun test ne l'a vu : `test_P0_getPartners_hitsPartnersEndpoint` (`ImmichAPIClientTests.swift:461`) asserte le chemin, jamais la query.
> - **La création prend un userId, pas un email** : `POST /api/partners` → `{sharedWithId: <uuid>}`. `createPartner(email:)` est inimplémentable tel quel ; la sélection passe par l'annuaire `GET /api/users` (et un email saisi doit être résolu par correspondance).
> - **La mutation est un `PUT`, pas un `PATCH`** (`partner.controller.ts`, `@Put(':id')`).
> - **Les deux directions ne portent pas les mêmes actions** : `PUT /api/partners/{id}` vaut pour `sharedById = id, sharedWithId = moi` (lignes **shared-with**), `DELETE /api/partners/{id}` vaut pour l'inverse (lignes **shared-by**). Une liste fusionnée avec toggle *et* poubelle sur chaque ligne est structurellement fausse.
>
> Sémantique (le DTO renvoyé est **toujours l'autre** utilisateur) : `shared-by` = les gens que **j'ai** ajoutés (« Sharing »), `shared-with` = ceux qui partagent **leur** photothèque avec moi (« Shared with me »). Le toggle timeline du Flutter porte sur `shared-with`.
>
> **Rattachement** : écran dédié poussé depuis le hub « Me » (comme Trash, Backup, Duplicates, People, Tags, Stacks), et **retrait** du bloc partenaires de `SharedLinksView` — le web range le partage partenaire dans `User Settings > Partner Sharing`.

#### Objectif
Interface complète de partage entre partenaires : écran dédié à deux sections (« Shared with me » / « Sharing »), invitation par sélection dans l'annuaire de l'instance, toggle « Show in timeline » sur les partenaires entrants, retrait des partenaires sortants.

#### Points d'entrée
- `PartnerCreateDto { sharedWithId }` + `PartnerDirection` (`shared-by` / `shared-with`) — `DTOs+People.swift`
- `PartnersView` — deux sections dans une `Form` + bouton « + » → `InvitePartnerSheet`
- `PartnersViewModel` — `load`, `invite(userId:)`, `setInTimeline(partnerId:enabled:)`, `remove(partnerId:)`, `loadCandidates`
- `InvitePartnerSheet` — annuaire filtré (nom/email) + CTA « Invite » ; pas de vue imbriquée
- `PartnerRow` + `PartnerAvatarCircle` — déplacés depuis `SharedLinksView.swift:341-407`, scindés par mode (entrant = toggle, sortant = retrait)

#### Endpoint API
- `GET /api/partners?direction=shared-by|shared-with` — **manquant** (le `direction` est requis)
- `POST /api/partners` — **manquant** (corps `{sharedWithId}`)
- `PUT /api/partners/:id`, `DELETE /api/partners/:id` — existants, mais chacun valide sur une seule direction

#### Étapes d'implémentation
1. Créer `PartnerCreateDto` + `PartnerDirection` dans `DTOs+People.swift`
2. Corriger `getPartners(direction:)` (**non optionnel**) + ajouter `createPartner(sharedWithId:)` dans `ImmichClient` + `ImmichAPIClient`
3. Créer `PartnersViewModel` dans `Sources/Features/Partners/`
4. Créer `PartnersView` (deux sections + bouton « + »)
5. Créer `InvitePartnerSheet`
6. Déplacer `PartnerRow`/`PartnerAvatarCircle` et retirer le bloc partenaires de `SharedLinksView`/`SharedLinksViewModel`
7. Ajouter le lien « Partners » dans `ProfileView` → `PartnersView`
8. Mock `createPartner(sharedWithId:)` + `getPartners(direction:)` (deux fixtures distinctes) dans `MockImmichClient`
9. Tests de comportement + tests de transport + scénario XCUITest sur stub committé

#### Tests attendus
- `Tests/PartnersViewModelTests.swift` : direction, invitation, refus des mutations hors portée (aucun PUT sur un sortant, aucun DELETE sur un entrant), retrait après succès, erreur
- `Tests/ImmichAPIClientTests.swift` : 4 tests de transport (query `direction`, corps `{sharedWithId}`, `PUT`/`DELETE` sur `/api/partners/{id}`)
- `UITests/stubs/immich_stub_partners.py` + scénario `test_06_partners` (le stub refuse un `/api/partners` sans `direction`)
- Regression : suite ≥ baseline (724 au 2026-09-13)

---

### 2.4. Memories Complete (P4) — ✅ Terminé (2026-09-13)

**Fichier spec** : `.omp/memories-complete/memories-complete.specs.md`
**Card AC** : `.opencode/scratch/memories-complete.acceptance.md` (réécrite le 2026-09-13 sur le contrat réel — AC-3200…AC-3208)
**UI brief** : `.omp/memories-complete/memories-complete.ui.md`
**Phase** : P4 — Discovery
**Issue** : #15

#### Résultat (2026-09-13)
**9/9 AC PASS.** Suite **749 → 772 tests, TEST SUCCEEDED** (iPhone 17) + `test_08_memories` de bout en bout contre le stub **committé** `UITests/stubs/immich_stub_memories.py` (nouveau : il sert aussi le handshake OAuth, 8 assets de bibliothèque en un bucket, `POST /api/search/metadata` pour la grille de sélection, et quatre comportements que le scénario vérifie sur le fil).

Livré : `MemoryCreateDto` / `MemoryUpdateDto` / `MemoryStatisticsResponseDto` (`DTOs+Social.swift`) ; 7 méthodes sur `ImmichClient` + `ImmichAPIClient` ; `MemoriesViewModel` (save/unsave, create, delete, add/remove assets, flux de sélection paginé) ; `MemoriesView` (bookmark par carte, menu contextuel, bouton « + », `CreateMemorySheet`, `AddPhotosToMemorySheet`, confirmation de suppression) ; `MemoryMomentView` (rangée d'actions : save, ajouter des photos, retirer la photo affichée, supprimer — et fermeture automatique quand la mémoire perd sa dernière photo) ; `AssetMultiSelectGrid` (NEW, `Sources/Features/Timeline/`) qui remplace `StackPhotoPicker.swift` **supprimé** et sert les 4 feuilles (créer/étendre une pile, créer/étendre une mémoire).

#### Corrections du 2026-09-13 (avant implémentation)

Vérifié sur l'OpenAPI publié (`main` sha `bace1792…`, `v1.135.0`) et les sources serveur (`memory.controller.ts`, `memory.repository.ts`, `memory.service.ts`, `dtos/memory.dto.ts`). Quatre erreurs de la fiche d'origine :

- **`PATCH /api/memories/:id` n'existe pas** → `PUT` (`@Put(':id')`). Un PATCH rend 404, même famille que le `PUT` des shared links.
- **`POST /api/memories/:id/assets` n'existe pas** → `PUT` (la route est `put|delete`). Les deux routes prennent **`BulkIdsDto` (`{ids}`)** et répondent **`BulkIdResponseDto`** (champ **`id`**, erreur `NO_PERMISSION` en majuscules) — à ne pas confondre avec `AssetIdsDto`/`AssetIdsResponseDto` des shared links (`assetIds`, `no_permission`).
- **`MemoryType.first_day` / `.yearly_recap` n'existent pas** : l'enum serveur est `["on_this_day"]` seul dans les deux versions. Un POST qui les envoie part en 400.
- **Le champ « titre » de `CreateMemorySheet` est sans objet** : aucun DTO mémoire ne porte de nom. `MemoryCreateDto` requiert `data:{year}`, `memoryAt` et `type` (+ `assetIds` optionnel) ; le libellé affiché vient de la date.

Deux comportements serveur qui dictent l'UI : `GET /api/memories` **filtre les mémoires sans asset** (`MemoryService.search`) — d'où la fermeture de l'écran après le retrait de la dernière photo ; et le ménage `MemoryRepository.cleanup` supprime les mémoires **non sauvegardées** de plus de 30 jours — la création envoie donc `isSaved: true`.

#### Résidu i18n (même classe que celui du backup)
Les ~18 chaînes neuves de cette feature (« New Memory », « Save Memory », « Unsave Memory », « Add Photos », « Delete Memory », « Delete this memory? », « Memory date », les messages de sélection, …) **n'ont pas d'entrée dans `Resources/Localizable.xcstrings`** : l'extraction de Xcode ne tourne pas en build CLI, et un build déclenché depuis Xcode **supprime des clés valides** (`Copy link`, `Custom URL` — parcourues par un build incrémental partiel), donc le catalogue n'est pas touché ici. Les chaînes de la grille de piles (`Nothing to add`, « Pick at least 2 photos… ») n'y étaient déjà pas. **SOLDÉ le 2026-09-14** par §2.10 (issue #21).

#### Objectif
Compléter le module Memories avec CRUD complet : save/unsave, create, delete, add/remove assets. Currently read-only (`getMemories()` only).

> **Trois demandes de la fiche d'origine sont sans objet serveur** (vérifié 2026-09-13) : `MemoryType` = `["on_this_day"]` seul (pas de `first_day`/`yearly_recap`), et aucun DTO mémoire ne porte de **titre** — le libellé affiché vient de `data`/`memoryAt`. `CreateMemorySheet` ne doit donc exposer ni sélecteur de type multi-valeurs ni champ titre.

#### Points d'entrée
- `MemoryCreateDto` + `MemoryUpdateDto` — `DTOs+Social.swift`
- `MemoryType` — reste `on_this_day` (enum serveur d'une seule valeur)
- `MemoriesViewModel` — saveMemory, unsaveMemory, createMemory, deleteMemory, memoryDate, selectedAssets
- `CreateMemorySheet` — date picker + sélection de photos → `POST /api/memories`

#### Endpoint API (7 nouveaux — verbes vérifiés le 2026-09-13 sur l'OpenAPI publié)
- `GET /api/memories/:id` — getMemory
- `PUT /api/memories/:id` — updateMemory (**PUT**, pas PATCH — `MemoryUpdateDto` : `isSaved?`, `memoryAt?`, `seenAt?`, tous optionnels — c'est **tout** le schéma serveur)
- `DELETE /api/memories/:id` — deleteMemory
- `POST /api/memories` — createMemory (`MemoryCreateDto` : `data:{year}` **requis**, `memoryAt` **requis**, `type` **requis**, `assetIds` — pas de champ titre ni de `slug`)
- `PUT /api/memories/:id/assets` — addAssetsToMemory (**PUT**, pas POST)
- `DELETE /api/memories/:id/assets` — removeAssetsFromMemory
- `GET /api/memories/statistics` — getMemoriesStatistics

⚠ **Corrections du 2026-09-13** (OpenAPI `main` sha `bace1792…` et `v1.135.0`, `jq '.paths|keys'` → `PUT /memories/{id}`, `PUT /memories/{id}/assets`) : la fiche annonçait `PATCH /memories/:id` et `POST /memories/:id/assets` — les deux rendraient 404/405. Elle demandait aussi d'ajouter `MemoryType.first_day` / `.yearly_recap` et un champ **titre** dans `CreateMemorySheet` : l'enum serveur est `["on_this_day"]` **seul** dans les deux versions, et aucun DTO mémoire ne porte de titre (`MemoryResponseDto` expose `data: OnThisDayDto`, `assets`, `memoryAt`…). Ces trois points sont tombés avant implémentation ; la carte `memories-complete.acceptance.md` a été réécrite sur le contrat réel le même jour.

Deux comportements serveur que l'UI doit respecter : `PUT`/`DELETE /api/memories/{id}/assets` prennent **`BulkIdsDto` (`{ids}`)** et répondent **`BulkIdResponseDto`** (champ `id`, erreur `NO_PERMISSION`) — pas les DTOs `AssetIds*` des liens partagés ; et `GET /api/memories` **filtre les mémoires sans asset** (`MemoryService.search`), d'où la fermeture de l'écran après le retrait de la dernière photo.

#### Étapes d'implémentation (livrées)
1. `MemoryCreateDto` (`data:{year}`, `memoryAt`, `type`, `assetIds`, `isSaved`) + `MemoryUpdateDto` (`isSaved?`, `memoryAt?`, `seenAt?`) + `MemoryStatisticsResponseDto` (`{total}`) — `MemoryType` inchangé
2. 7 méthodes dans `ImmichClient` + `ImmichAPIClient` (**`PUT`** pour `updateMemory` et `addAssetsToMemory`, corps `BulkIdsDto` pour les routes assets)
3. `MemoriesViewModel` : CRUD + flux de sélection paginé (`beginPicking` / `loadMoreAssets` / `orderedSelection`)
4. `MemoriesView` : bookmark par carte, menu contextuel, bouton « + », dialogues
5. `CreateMemorySheet` + `AddPhotosToMemorySheet` (date + sélection, pas de titre) ; `MemoryMomentView` gagne sa rangée d'actions
6. `AssetMultiSelectGrid` extrait (`Sources/Features/Timeline/`) et partagé par les 4 feuilles ; `StackPhotoPicker.swift` supprimé
7. `MockImmichClient` : 7 méthodes + fixtures par id
8. Tests : `MemoriesViewModelTests` +16, `ImmichAPIClientTests` +7 (transport)
9. Stub **committé** `UITests/stubs/immich_stub_memories.py` + scénario `test_08_memories`
10. `xcodegen generate` + suite complète

#### Tests livrés
- `Tests/MemoriesViewModelTests.swift` : 16 tests (save/unsave + échec, create — payload, année/`memoryAt` UTC, échec qui garde la feuille —, delete, add/remove assets, dernière photo = fermeture, picker/ordre)
- `Tests/ImmichAPIClientTests.swift` : 7 tests de transport `test_mem_*` (verbes, chemins, corps, `BulkIdErrorReason`)
- `UITests/ImmichRenderScreenshots.swift/test_08_memories` + stub committé
- Regression : suite 749 → **772**, TEST SUCCEEDED

---

### 2.5. Notifications — autorisation OS (P5) — ✅ Terminé (2026-09-13)

**Fichier spec** : `.omp/push-notifications/push-notifications.specs.md` (décrit encore la pile APNs fantôme)
**Card AC** : `.opencode/scratch/push-notifications.acceptance.md` (réécrite le 2026-09-13 — AC-4100…AC-4107)
**UI brief** : `.omp/push-notifications/push-notifications.ui.md` (brief de la pile fantôme, non suivi)
**AC Cards** : AC-4100 – AC-4107
**Phase** : P5 — Auth & Platform
**Issue** : #16

#### Résultat (2026-09-13)
**8/8 AC PASS.** Suite **831 → 837 tests TEST SUCCEEDED** (iPhone 17, `-only-testing:ImmichSwiftUITests`) ; le pré-état 831 a été mesuré sur un worktree `HEAD` (c741730), les huit checks rejoués verbatim avant/après. `test_10_notifications` vert deux fois contre le stub **committé** `UITests/stubs/immich_stub_offline.py` (réutilisé : la feature n'a aucun comportement serveur propre), et les **deux** états de l'écran exercés en vrai — simulateur chaud (« Activé » + « Ouvrir les réglages système ») puis après `xcrun simctl uninstall` (« Désactivé » + « Activer les notifications » → alerte système iOS → bascule sur « Activé »).

Livré : `NotificationService` (seam unique `NotificationServicing` : `permission()`, `requestAuthorization()`, `notifyBackupComplete(...)` — `BackupNotificationService.swift` supprimé), `NotificationsViewModel` (permission, `loaded`, `isRequesting`, `isEnabled`, `canAsk`, guard de réentrance), `NotificationSettingsView` (statut + Enable / Open System Settings + footer par état), ligne `notificationsRow` dans le hub « Me » juste après « Backup », 8 clés EN/FR au catalogue, 6 tests unitaires + le scénario XCUITest.

#### Ce que la fiche d'origine demandait, et qui n'existe pas
Vérifié le 2026-09-13 : `POST /api/users/me/device-token` = **0 occurrence** dans l'OpenAPI publié (`main`, `v1.135.0`), aucun schéma APNs/push — le serveur n'expose que `/notifications` (GET/PUT/DELETE), consommé par le **web** seul. Le client Flutter n'a **aucun** push (`mobile/pubspec.yaml` : `flutter_local_notifications` + `socket_io_client`, pas de `firebase_messaging`) ; son écran `notification_setting.dart` ne fait que l'état de permission OS + « Open Settings ». Les 9 AC d'origine (AC-3300…AC-3308) ne pinnaient que des `grep` de fichiers locaux et ont été **retirés**. Restent hors périmètre, parce qu'ils n'existent nulle part côté serveur : APNs, device-token, notifications in-app (`/api/notifications`).


---

### 2.6. Shared Links Enriched (P3) — ✅ Terminé (2026-09-13)

**Fichier spec** : `.omp/shared-links-enriched/shared-links-enriched.specs.md`
**Card AC** : `.opencode/scratch/shared-links-enriched.acceptance.md`
**UI brief** : `.omp/shared-links-enriched/shared-links-enriched.ui.md`
**AC Cards** : AC-3900 – AC-3909 (réécrites le 2026-09-13 ; les AC-3400–3409 d'origine pinnaient une surface inexistante)
**Phase** : P3 — Social
**Issue** : #17 — Viewer public scindé dans **#22** (`shared-link-viewer`)

#### Objectif
Fermer les 5 écarts réels vs Flutter : builder d'URL publique (bug), champ `slug`, presets d'expiration, `ShareLink` à côté du copier, écran « lien prêt » après création. Le CRUD de base, le copier-lien et le `DatePicker` d'expiration existaient déjà.

#### Points d'entrée
- NEW `Sources/Core/Utilities/SharedLinkURL.swift` — builder unique (`externalDomain` sinon serveur ; `/s/<slug>` sinon `/share/<key>`), les 2 appelants migrés
- `SharedLinkCreateDto` / `SharedLinkEditDto` — champ `slug`
- `ImmichAPIClient` — `PATCH /shared-links/{id}` (le `PUT` rendait 404) + `addAssetsToSharedLink` (`PUT /shared-links/{id}/assets`)
- NEW `Sources/Features/SharedLinks/SharedLinkExpiryPicker.swift` — 9 presets + date/heure
- `CreateSharedLinkSheet` — slug + presets + écran « lien prêt » ; `EditSharedLinkSheet` — slug + presets
- `SharedLinkRow` — URL du builder + `ShareLink` ; `PhotoShareViewModel` — URL du builder
- `AuthViewModel.restoreSession()` — charge `serverConfig()` (sinon `externalDomain` inconnu après relaunch)

#### Endpoints
Aucun endpoint manquant : les 3 routes annoncées ici (`public/:slug`, `:slug/assets`, `:slug/check-password`) **n'existent pas** — voir « Endpoints fantômes retirés ». Le seul verbe fautif était `PUT /api/shared-links/{id}`, corrigé en `PATCH`.

#### Tests attendus
- `Tests/SharedLinkURLTests.swift` : 4 cas d'URL
- `ImmichAPIClientTests` : POST avec slug, PATCH avec slug, `PUT /shared-links/{id}/assets` + `AssetIdsDto`
- `SharedLinksViewModelTests` : création slug + expiration, ajout d'assets
- `UITests/ImmichRenderScreenshots.swift/test_07_sharedLinks` sur stub committé `UITests/stubs/immich_stub_shared_links.py`
- Regression : suite ≥ 736

---

### 2.7. Offline Download (P4) — ✅ Terminé (2026-09-13)

> **LIVRÉ le 2026-09-13** en un commit `ebf43e4`, issue [#18](https://github.com/millianlmx/swimmich/issues/18) fermée, item 18 du projet #2 en `Done`. **13/13 AC PASS**, suite 805 → **831 tests TEST SUCCEEDED** (iPhone 17, `-only-testing:ImmichSwiftUITests`), `test_09_offlineDownload` vert 3× contre le stub **committé** `UITests/stubs/immich_stub_offline.py`. Carte de référence : `.opencode/scratch/offline-download.acceptance.md` (AC-3500–AC-3512). Ce qui suit décrit la feature livrée ; les écarts constatés à l'implémentation sont listés dans la carte (§ « Écarts constatés »).

**Fichier spec** : `.omp/offline-download/offline-download.specs.md`
**Card AC** : `.opencode/scratch/offline-download.acceptance.md`
**UI brief** : `.omp/offline-download/offline-download.ui.md`
**AC Cards** : AC-3500 – AC-3512 (carte révisée le 2026-09-13)
**Phase** : P4 — Discovery

#### Objectif
Téléchargement d'assets pour consultation hors-ligne. Cache fichiers durable sous Application Support, **restitution réelle sans réseau** (viewer + grille + timeline), indicateur de disponibilité offline, gestion de la taille de cache.

#### Points d'entrée
- `OfflineAssetStore` (Services, `actor`) — `download`, `cachedInfo`, `fileURL`, `allCached`, `isCached`, `totalBytes`, `remove`, `clearAll`, `maxCacheSize`, `CachedAssetInfo`
- `OfflineAssetIndex` (Features/Offline/, `@Observable`) — état « en cache » lu par les cellules via l'environnement
- `OfflineDownloadViewModel` (Features/Offline/) — cachedAssets, downloadAsset, removeFromOffline, clearAll, cacheUsage, progression par asset
- `OfflineAssetsView` (Features/Offline/) — grille d'assets + clear all + jauge d'occupation
- `AuthenticatedAsyncImage` — étage « fichier local » (c'est le chemin de rendu hors-ligne)
- `PhotoViewer` — « Download for Offline » / « Remove from Offline » dans le partage
- `AssetThumbnailCell` — indicateur d'asset en cache (`offlineBadge`)

#### Endpoint API
- `GET /api/assets/:id/original` — existant (`operationId: downloadAsset`, `application/octet-stream`) — **vérifié le 2026-09-13** sur l'OpenAPI `main` (`jq '.paths["/assets/{id}/original"]' /tmp/immich-openapi-main.json`). Aucune route « offline » n'existe côté serveur.

#### Étapes d'implémentation (telles que livrées — voir la carte AC-3500–AC-3512)
1. NEW `Sources/Services/OfflineAssetStore.swift` — `actor`, cache fichiers + `index.json` sous **Application Support** (`Caches` est purgeable par l'OS, la spec d'origine se trompait), API `download/cachedInfo/fileURL/allCached/isCached/totalBytes/remove/clearAll/maxCacheSize`, `init(folderURL:transport:fileManager:defaults:)` injectable pour les tests.
2. NEW `Sources/Services/ImageDownsampler.swift` — ImageIO (`CGImageSourceCreateThumbnailAtIndex`), 2048 px ; `videoPoster(at:)` (AVAssetImageGenerator) pour la vignette d'une **vidéo** en cache (ImageIO ne lit pas un `.mp4`).
3. NEW `Sources/Core/Protocols/FileDownloadTransport.swift` + `Sources/Services/URLSessionFileDownloadTransport.swift` — couture de téléchargement : `URLSession.download` écrit un fichier temporaire (jamais de `Data` en mémoire) et un double peut rejouer une progression, ce qu'un `URLProtocol` ne permet pas.
4. EDIT `Sources/Services/AuthenticatedAsyncImage.swift` — étage 0 `localFileURL` : c'est **ce qui rend la consultation hors-ligne réelle** (sans lui le store n'est qu'une liste de tailles).
5. NEW `Sources/Features/Offline/OfflineAssetIndex.swift` — `@MainActor @Observable`, injecté dans l'environnement (les 6 sites d'`AssetThumbnailCell` ne doivent pas recevoir un paramètre de plus). Ses tables restent **observées** : `@ObservationIgnored` rendrait le badge du timeline muet.
6. NEW `Sources/Features/Offline/OfflineDownloadViewModel.swift` — `cachedAssets`, `cacheUsage`, `maxCacheSize`, `downloadAsset(id:)`, `removeFromOffline(id:)`, `clearAll()`, `load()`, progression par asset.
7. NEW `Sources/Features/Offline/OfflineAssetsView.swift` — `LazyVGrid` + carte d'occupation (anneau) + suppression par asset + « Clear All » + état vide.
8. EDIT `Sources/Features/Timeline/AssetThumbnailCell.swift` — badge `offlineBadge` + image servie depuis le fichier local (identifier de tuile `assetTile_<id>`).
9. EDIT `Sources/Features/PhotoViewer/` — `localFileURL` dans `ZoomableImageView`, **lecture vidéo depuis le fichier local** (`VideoPlaybackViewModel.prepare(…, localFileURL:)` → `VideoPlayerView`), diaporama (`SlideshowView`, `KenBurnsImageView`), et section « Offline » du partage (`PhotoShareSheet`).
10. EDIT `Sources/Features/Profile/ProfileView.swift` — lien « Offline Storage » (section Management, identifier `offlineStorageRow`).
11. EDIT `Sources/DependencyContainer.swift` + `Sources/RootView.swift` — instances process-wide + `.environment(offlineIndex)`.
12. EDIT `Resources/Localizable.xcstrings` — 24 clés EN+FR ajoutées à la main.

#### Tests attendus
- `Tests/OfflineAssetStoreTests.swift` — **17 cas** : write+index, cache hit, cache miss, remove, clearAll, refus avant transfert, éviction à la limite, réconciliation d'index, `.partial` orphelin, statut HTTP, payload vide, rendu local sans réseau, plafond du downsampler, extension serveur, progression, poster vidéo, poster refusé sur un non-vidéo.
- `Tests/OfflineDownloadViewModelTests.swift` — **8 cas** : load, download succès, download échec, progression, remove, clear, recherche, anneau sans limite. `Tests/Mocks/{MockFileDownloadTransport,VideoFixture}.swift` fournissent le transport asservi et un vrai MP4 H.264.
- `UITests/stubs/immich_stub_offline.py` (committé, self-contained, port 8421) + `test_09_offlineDownload` : viewer → « Download for Offline » → badge timeline → écran Offline Storage (**serveur coupé** : le stub répond 503 à tout `/api/assets/*` et `/api/timeline/*`, et le scénario exige zéro requête de ce type) → suppression.
- Regression : suite **831 tests TEST SUCCEEDED** (baseline 805 mesurée le 2026-09-13, `-only-testing:ImmichSwiftUITests`).

---

### 2.8. Widgets Home Screen (P5) — ✅ Terminé (2026-09-13)

> **CONFIRMÉ SUR APPAREIL le 2026-09-14 par l'utilisateur** : les trois widgets affichent les photos. Cause racine (AC-3620) : l'entrée de timeline portait les vignettes brutes du serveur (plusieurs Mo) et une entrée trop lourde **ne s'archive pas** — le widget restait sur son placeholder redacté, sans photo, sans message, sans log côté extension. Invisible sur simulateur (le stub sert des PNG 8×8).
>
> **CORRECTIFS du 2026-09-14** (rapport utilisateur « les photos ne s'affichent pas dans le widget ») : reproduction montée de bout en bout — simulateur neuf, connexion OAuth réelle, **widget réellement posé sur l'écran d'accueil** via SpringBoard, logs du processus widget lus (`UITests/ImmichWidgetHomeScreen.swift`, nouveau). Le widget fonctionne (Keychain partagé, fetch, décodage, rendu — vérifié sur `127.0.0.1` et sur un hostname `.local` en HTTP) ; trois vrais défauts corrigés : l'appex n'avait **aucune** politique ATS, le widget fetchait **sans gestionnaire de certificat** (un serveur auto-signé accepté dans l'app était injoignable depuis le widget), et l'état vide **mentait** (« pas connecté » et « serveur injoignable » affichaient tous deux « Pas encore de photos »). AC-3612 à AC-3615 ajoutés. Diagnostic du rapport : la pastille du widget ne contenait que des **rectangles gris uniformes sans caractères** (rendu *redacté* de WidgetKit ⇒ la timeline n'est jamais arrivée) — l'ancien build, qui fetchait via `URLSession.shared` avec ses timeouts de 60 s, pouvait consommer tout le budget de WidgetKit sur un serveur injoignable ; le fetch est désormais borné (10 s) et rejoue à 5 min en cas d'échec. Second retour (« toujours vide, aucun log ») traité par AC-3616 : les plaques sans octets passent en dégradé de marque plein (elles ressemblaient au placeholder redacté du système, ce qui empêchait de trancher) et l'état vide imprime **le serveur interrogé et la raison** (« nas.local · certificate refused », « … · no answer in 10s », « keychain »). Les logs du widget sont dans le processus `ImmichWidgets` (Console : filtrer sur le processus, pas sur l'app). Troisième retour (« toujours vide, aucun log » + log de l'app montrant `immich.1000co.fr:443`, donc HTTPS public ⇒ ni ATS ni réseau local) : AC-3617 — l'app vérifie désormais à chaque lancement, depuis son **propre** log (`subsystem app.immich.swiftui`, catégorie `widget-probe`), que le profil de provisionnement autorise le groupe Keychain partagé dont l'extension a besoin. C'est le seul échec strictement impossible à voir sur simulateur : si le profil ne l'autorise pas, iOS tue le processus de l'extension au lancement — aucun log côté extension, aucune timeline, placeholder figé. Keychain finalement disculpé : le profil d'équipe (joker `2MJF39L8VY.*`) autorise le groupe pour l'app **et** l'extension, et l'appex signé appareil le porte bien ; l'erreur de build « Entitlements file was modified during the build » est Xcode qui met à jour le profil pour ce droit pendant le build (le build suivant passe). **CAUSE RACINE trouvée le 2026-09-14** : l'entrée de timeline embarquait les vignettes brutes du serveur (~300 Ko pour un héro en `size=preview`, plusieurs Mo pour un mur). WidgetKit archive l'entrée avant de rendre ; trop lourde, elle ne s'archive pas, et le widget reste sur son placeholder **pour toujours** — sans photo, sans message, sans une ligne de log côté extension. Invisible sur simulateur parce que le stub de test sert des PNG 8×8 (entrée minuscule) : c'est le seul défaut qui expliquait l'écart simulateur/appareil. Corrigé par AC-3620 (ré-encodage héro ≤ 900 px / cellule ≤ 320 px / JPEG 0,6, budget 256 Ko, héro prioritaire) ; l'app demande en plus un rafraîchissement des timelines au retour au premier plan et après une sauvegarde. Dernier étage du diagnostic : l'aperçu de **galerie** sert désormais le même contenu que l'écran d'accueil (AC-3619) — l'échantillon qu'il servait avant a précisément masqué le bug deux jours ; et une capture utilisateur montrant les plaques sombres du nouveau build sous des barres grises (rendu redacté) sans aucune ligne `Request began` côté chronod indique un widget **ajouté avant la mise à jour** : le descripteur n'est plus réinterrogé, il faut le retirer et le reposer. Le log système rendu par l'utilisateur (`WidgetRenderer_Default Content load failed: unable to find or unarchive file for key … .chrono-timeline`) confirme qu'**aucune timeline n'a jamais été écrite** par l'extension. D'où un second correctif : AC-3618 — l'appex annonçait 1.0 quand l'app annonce 0.1.0 (xcodegen met 1.0/1 en dur dans le plist de l'extension), désaccord qui peut faire refuser l'association/lancement de l'extension après mise à jour. Les entitlements sont désormais sans commentaire (Xcode les re-sérialise au build). Limite : le simulateur n'applique pas ATS, donc la parité ATS est défensive et reste à confirmer sur appareil.
>
> **LIVRÉ le 2026-09-13**, issue [#19](https://github.com/millianlmx/swimmich/issues/19) fermée, item 19 du projet #2 en `Done`. **21/21 AC PASS** (carte réécrite le 2026-09-13 puis complétée le 2026-09-14, AC-3600–AC-3620), suite 837 → **869 tests TEST SUCCEEDED** (iPhone 17, `-only-testing:ImmichSwiftUITests`). Trois widgets data-driven + familles Lock Screen, interactifs (`Button(intent:)`), alimentés par le vrai serveur depuis le processus widget via un **Keychain partagé** qu'il a fallu câbler (prérequis absent du dépôt). Les compositions ont été rasterisées et inspectées à l'œil (`ImageRenderer`), ce qui a fait tomber trois défauts réels avant livraison (familles non déclarées dans les previews, pastille rognée en small, watermark peint sous une mosaïque opaque).

**Fichier spec** : `.omp/widgets-homescreen/widgets-homescreen.specs.md`
**Card AC** : `.opencode/scratch/widgets-homescreen.acceptance.md`
**UI brief** : `.omp/widgets-homescreen/widgets-homescreen.ui.md` (corrigé le 2026-09-13 : la couche vitrée passait par `glassEffect`, réservé à l'UI de l'app)
**AC Cards** : AC-3600 – AC-3614
**Phase** : P5 — Auth & Platform
**Issue** : #19

#### Livré
- **NEW** `Sources/ImmichSharedKit/WidgetSession.swift` — `WidgetSession` + `WidgetSessionStore` (Keychain, `afterFirstUnlock` : un widget d'écran verrouillé doit lire alors que l'appareil est verrouillé ; le token d'auth de l'app reste en `whenUnlocked`)
- **NEW** `Sources/ImmichSharedKit/WidgetDataProvider.swift` — `WidgetPhoto`/`PhotoWall`/`WidgetMemory` + provider : buckets (`isFavorite=true` pour les favoris) → bucket columnar → vignettes en parallèle (hero en `size=preview`, cellules en `size=thumbnail`) ; toute panne (pas de session, 401, 500, payload invalide, vignette manquante) dégrade sans crash
- **NEW** `Sources/ImmichSharedKit/WidgetViews.swift` — palette de marque partagée avec la Live Activity, copie localisée (`WidgetCopy`), atomes (tuile photo, pastille, cœur, shuffle, état vide), les 3 compositions, `WidgetPlaceholder` (galerie), `WidgetCanvas` (platter + marges d'accessoires)
- **NEW** `Sources/ImmichSharedKit/WidgetIntents.swift` — `ShuffleMemoriesIntent` (aucun réseau : avance un offset persisté et recharge la timeline), `ToggleFavoriteIntent` (`PATCH /api/assets/{id}`, session 15 s)
- **NEW** `Sources/ImmichSharedKit/WidgetDeepLink.swift` — forme d'URL `app.immich://asset/<id>?day=<bucket>|memories|backup` (parse + builder, source unique des deux côtés)
- **NEW** `ImmichWidgets/{ImmichGridWidget,ImmichMemoriesWidget,ImmichFavoritesWidget,ImmichWidgetsBundle}.swift` — déclarations + `TimelineProvider` ; le `@main` a quitté `BackupLiveActivity.swift`
- **EDIT** `ImmichWidgets/ImmichHomeWidget.swift` — plaque de lancement à la marque ; son deep link `app.immich://backup` fonctionne enfin, et l'icône est un SF Symbol (`Image("AppIcon")` ne résolvait rien : l'extension n'a pas de catalogue d'assets)
- **EDIT** `Sources/Features/Auth/AuthViewModel.swift` — `publishWidgetSession()` sur login/OAuth/restauration/changement de compte, `clear()` à la déconnexion
- **EDIT** `Sources/RootView.swift` — `.onOpenURL` : asset (onglet Photos + scroll au bucket), `memories`, `backup` (Photos + moteur gated)
- **EDIT** `project.yml`, `Resources/{ImmichSwiftUI,ImmichWidgets}.entitlements` — `CODE_SIGN_ENTITLEMENTS` câblé des deux côtés sur le **même** groupe Keychain ; le catalogue de traduction est embarqué dans l'appex (sinon tout texte de widget reste en anglais)
- **EDIT** `Resources/Localizable.xcstrings` — 31 clés EN+FR à la main (le catalogue est réécrit par l'extraction Xcode ; cf. piège connu)
- **NEW** `Tests/WidgetDataProviderTests.swift` (12 + 2), `Tests/WidgetDeepLinkTests.swift` (13)

#### Le contrat réel (trois erreurs de la fiche corrigées avant implémentation)
- **`GET /api/assets?isFavorite=true` n'existe pas** : `/assets` n'expose que `delete|post|put` (OpenAPI publié, vérifié 2026-09-13). Les favoris passent par `GET /api/timeline/buckets?isFavorite=true` puis `GET /api/timeline/bucket?timeBucket=…` — le chemin du timeline.
- **Le token n'était pas partageable** : `Resources/ImmichSwiftUI.entitlements` existait sans être référencé dans `project.yml`, et aucun code n'écrivait de groupe d'accès. Un widget est un bundle distinct (`fr.millianlmx.immich-ios.widgets`) : sans groupe commun, chaque fetch serait un 401. Le groupe retenu est celui de l'app (`$(AppIdentifierPrefix)fr.millianlmx.immich-ios`), déclaré par **les deux** cibles — l'app écrit sans groupe explicite (son défaut), l'extension liste ce groupe pour lire.
- **`glassEffect` n'existe pas dans un widget** (API d'UI d'app ; un widget rend sa platter) et **un widget n'a qu'un seul `widgetURL`** : les deep links par cellule passent par `Link(destination:)`. Les « configuration à l'écran d'accueil » et « pull-to-refresh du widget » du brief n'existent pas côté WidgetKit et ont été retirés.

#### Non vérifié
Le widget réellement posé sur l'écran d'accueil : le dépôt n'a aucune automatisation SpringBoard, donc la lecture du Keychain **depuis le processus widget**, les marges/platter de WidgetKit et les `Button(intent:)` en conditions réelles restent à confirmer sur appareil. Ce qui est prouvé : les entitlements sont dans les deux binaires livrés, la lecture du store passe dans les tests, et le contrat HTTP du provider est testé contre des réponses serveur réalistes.

#### Ancienne fiche (conservée pour l'historique)

**Fichier spec** : `.omp/widgets-homescreen/widgets-homescreen.specs.md`
**Card AC** : `.opencode/scratch/widgets-homescreen.acceptance.md`
**UI brief** : `.omp/widgets-homescreen/widgets-homescreen.ui.md`
**AC Cards** : AC-3600 – AC-3608
**Phase** : P5 — Auth & Platform

#### Objectif
3 widgets Home Screen (Grid, Memories, Favorites) + WidgetKit TimelineProvider + access Keychain token dans processus widget. Live Activity backup déjà existante.

#### Points d'entrée
- `ImmichGridWidget` — SystemSmall (2x2) + SystemMedium (4x2), LazyVGrid photos
- `ImmichMemoriesWidget` — SystemSmall + SystemMedium, OnThisDay card + asset grid + widgetURL
- `ImmichFavoritesWidget` — SystemSmall + SystemMedium, favorites grid + widgetURL
- `WidgetDataProvider` — fetchTimelineAssets, fetchMemories, fetchFavorites (Keychain + URLSession)

#### Endpoint API
- `GET /api/timeline/bucket` — existant (fetchTimelineAssets)
- `GET /api/memories` — existant (fetchMemories)
- `GET /api/assets?isFavorite=true` — existant (fetchFavorites)

#### Étapes d'implémentation
1. Créer `ImmichGridWidget` dans `ImmichWidgets/` — TimelineProvider + LazyVGrid
2. Créer `ImmichMemoriesWidget` dans `ImmichWidgets/` — OnThisDay + widgetURL
3. Créer `ImmichFavoritesWidget` dans `ImmichWidgets/` — favorites + widgetURL
4. Créer `WidgetDataProvider` — Keychain token + URLSession fetch
5. Register widgets dans `ImmichSwiftUIApp` (ajout au bundle existant)
6. Ajouter `.widgetURL` handler pour deep links (app.immich://asset/{id})
7. Tests ≥3

#### Tests attendus
- `Tests/WidgetDataProviderTests.swift` ≥3 tests : fetch timeline, fetch memories, fetch favorites
- Regression : suite ≥ baseline

---

### 2.9. Stacks UI (P3) — ✅ Terminé (2026-09-13)

**Fichier spec** : `.omp/stacks-ui/stacks-ui.specs.md`
**Card AC** : `.opencode/scratch/stacks-ui.acceptance.md`
**UI brief** : `.omp/stacks-ui/stacks-ui.ui.md`
**AC Cards** : AC-3700 – AC-3711
**Phase** : P3 — Social

#### Résultat (2026-09-13)
AC-3700 – AC-3711 **PASS** (12/12, checks rejoués depuis la carte). Suite complète **724 tests, TEST SUCCEEDED** (iPhone 17, baseline mesurée 695 avant implémentation). Vérification d'exécution réelle, 3 scénarios XCUITest contre un stub Immich local : badge de pile → détail → hub ; **ajout d'une photo à une pile existante** (couverture conservée, nouvel id suivi) ; création d'une pile depuis le hub. Captures : `/tmp/shot-1{1,2,5,9}-*.png`, `/tmp/shot-2{0,1,2}-*.png`.

#### Livré
- **NEW** `Sources/Features/Stacks/StacksViewModel.swift` — liste, `loadStack`, CRUD, `addPhotos`, flux de picker partagé (pagination `searchMetadata`, `orderedSelection`)
- **NEW** `StackView.swift` — liste (couverture + compte + «Cover: fichier»), création, swipe «Unstack», navigation. Pas de `NavigationStack` propre
- **NEW** `StackDetailView.swift` — couverture, «Make cover», «Remove from stack», **«Add photos»**, «Unstack» (confirmation), viewer sur les membres ; `stackId` **mutable** (l'ajout change l'id côté serveur)
- **NEW** `StackPhotoPicker.swift` — grille multi-sélection paginée, **partagée** par `CreateStackSheet` et `AddToStackSheet`, avec `excluding:` pour ne pas reproposer les membres
- **NEW** `CreateStackSheet.swift` / `AddToStackSheet.swift` — coquilles minces autour du picker
- `AssetReactItem` — `stackId`, `stackCount`, `stackedExtraCount` ; commentaire du champ `stack` corrigé (tuple wire, count en **chaîne**, couverture incluse)
- `TimelineViewModel` — `withStacked = true` sur les 6 appels ; `stackSelected()` ordonne par position dans la grille (le 1er id devient la couverture) ; corbeille laissée en `nil`
- `AssetThumbnailCell` — badge de pile `+N`, un seul élément d'accessibilité
- `TimelineView` — `navigationDestination(item:)` : une tuile empilée ouvre le détail de la pile, pas le pager plat
- `ProfileView` / `DependencyContainer` / `RootView` — lien «Stacks», `makeStacksViewModel()`, VM unique partagé timeline + hub
- Tests (+29 unitaires, +3 scénarios XCUITest) : `StacksViewModelTests` (18), routes stacks (7), timeline stacking (3), décodage du tuple wire (1)

#### Ajouter une photo à une pile — le contrat réel
**Aucune route n'ajoute un asset à une pile.** Vérifié sur l'OpenAPI publié (`main` : 7 opérations ; `v1.135.0` : 6) et sur `server/src/controllers/stack.controller.ts` : la surface est `GET/POST /stacks`, `GET/PUT/DELETE /stacks/{id}`, `DELETE /stacks/{id}/assets/{assetId}`. Le `POST /api/assets/:stackId/assets` que ce backlog annonçait **n'existe pas** (il a été retiré de la table de référence).

Le chemin sanctionné est le contrat de fusion de `POST /api/stacks` (« If any of the provided asset IDs are primary assets of an existing stack, the existing stack will be merged into the newly created stack »). `StackRepository.create` l'implémente en cherchant les piles possédées dont la `primaryAssetId` figure dans le payload, en absorbant **tous** leurs membres, en supprimant ces piles, puis en insérant une pile neuve avec `primaryAssetId = assetIds[0]` et en re-parentant chaque asset collecté. Trois conséquences encodées dans `StacksViewModel.addPhotos` :
1. la **couverture courante doit ouvrir le payload** (`assetIds[0]` devient la primaire — poster les nouvelles photos d'abord volerait la couverture) ;
2. **l'id de la pile change** (suppression + réinsertion) : la méthode renvoie le nouvel id et `StackDetailView` le suit, sinon l'écran pointe une pile morte ;
3. un asset n'appartient qu'à **une** pile : une photo déjà empilée est déplacée, et choisir la couverture d'une autre pile fusionne toute cette pile (comportement documenté du serveur).

#### Pièges rencontrés
- **Le tap de la grille du picker ne sélectionnait rien** : `AssetThumbnailCell` porte son propre `onTapGesture`, qui gagne sur l'action d'un `Button` englobant et **avale** le tap. La grille s'affichait, ne sélectionnait jamais. Corrigé en passant `onTap:` à la cellule ; le défaut touchait aussi `CreateStackSheet` depuis sa livraison — seul un test d'exécution pouvait le voir.
- **Les libellés de CTA sont localisés** (« Create » → « Créer ») : les tests UI visent des `accessibilityIdentifier`, jamais le texte affiché.
- Un `.accessibilityLabel` posé sur un conteneur **fusionne** ses enfants (le `+2` du badge disparaissait de l'arbre XCUITest → `children: .ignore` + `identifier`).
- La 1re rangée du timeline vit sous le header de date flottant, et le hub «Me» est une `Form` paresseuse : le harnais UI scrolle avant d'assertir.
- Côté stub : un tableau `ratio` plus court que `id` fait rendre un **timeline vide** (garde-fou FM-1 d'`AssetReactItem.zip`), et l'état serveur survit d'un test à l'autre sans `GET /__reset`.

#### Suivi (non bloquant)
- `TrashViewModel` demande toujours la liste plate (`withStacked: nil`) — volontaire : la corbeille doit montrer chaque asset.
- Le harnais UI dépend d'un stub local `/tmp/immich_stub_stacks.py` : il se skippe sans lui.

#### Endpoint API
- 6 routes déjà wire, **aucun ajout** : `searchStacks`, `createStack` (qui sert aussi à **étendre** une pile par fusion), `getStack`, `updateStack`, `deleteStack`, `removeAssetFromStack`.

---

### 2.10. i18n Completing (P5) — ✅ Terminé (2026-09-14)

> **LIVRÉ le 2026-09-14** en un commit `36075ea`, issue [#21](https://github.com/millianlmx/swimmich/issues/21) fermée, item 21 du projet #2 en `Done`. **7/7 AC PASS** (carte `.opencode/scratch/i18n.acceptance.md`, AC-3800–AC-3807), suite 876 → **886 tests TEST SUCCEEDED** (iPhone 17, `-only-testing:ImmichSwiftUITests`), et scénario `test_11_languagePicker` vert (85 s) contre le stub **committé** `UITests/stubs/immich_stub_memories.py` : Me → Language → 5 langues + toggle système → choix de l'allemand → bandeau de relance + corps retraduit en place → **relance de l'app** → sélection conservée → langue rendue au système. Ce qui suit décrit la surface livrée.

> **Ce que la carte annonçait était en dessous du réel** : l'app était bilingue par accident — l'onboarding (accueil, URL serveur, connexion) était **en français en dur**, donc français pour tout le monde, pendant que le reste était anglais avec un catalogue à 341 clés sur 442. Audit par l'extraction d'Xcode (`SWIFT_EMIT_LOC_STRINGS=YES` → `*.stringsdata`, qui sont des **JSON**, pas des plists) : **204 clés réclamées par le code et absentes du catalogue**, **81 clés mortes**. Cible dépassée sur décision utilisateur du 2026-09-14 : **fr + de + es + it** au lieu de « FR + EN minimum ».

**Fichier spec** : `.omp/i18n/i18n.specs.md`
**Card AC** : `.opencode/scratch/i18n.acceptance.md`
**UI brief** : `.omp/i18n/i18n.ui.md`
**AC Cards** : AC-3800 – AC-3807
**Phase** : P5 — Auth & Platform

#### Objectif
Internationalisation complète : externaliser TOUS les textes hardcodés dans `Localizable.xcstrings` (≥200 clés), ajouter sélecteur de langue, formatter de dates réutilisés.

#### Points d'entrée
- `Localizable.xcstrings` — Compléter avec ≥200 clés (FR + EN minimum)
- Migration strings → `String(localized:)` / `Text("key", bundle: .module)` dans TOUS les Views
- `LanguageSettingsView` (Features/Settings/) — Liste langues + toggle "Use System Language"
- `LanguageSettingsViewModel` (Features/Settings/) — selectedLocale, useSystemLanguage, applyLanguage
- `AppDateFormat` (DesignSystem/) — DateFormatters singleton réutilisés

#### Étapes d'implémentation
1. Audit des strings hardcodés dans tous les Views
2. Compléter `Localizable.xcstrings` avec ≥200 clés (FR + EN)
3. Migrer TOUS les string literals → `String(localized:)` dans :
   - Auth: LoginScreen, WelcomeScreen, ServerURLScreen
   - Timeline: TimelineView
   - Viewer: PhotoViewer, PhotoInfoPanel, PhotoEditor
   - Albums: AlbumsView, AlbumDetailView
   - Search: SearchView, MapView
   - Memories: MemoriesView
   - People: PeopleView
   - Tags: TagsView
   - Admin: AdminView
   - Upload: BackupSettingsView, UploadViewModel
   - SharedLinks: SharedLinksView
   - Trash: TrashView
   - Profile: ProfileView
   - Settings: PushNotificationSettingsView, etc.
4. Créer `LanguageSettingsView` + `LanguageSettingsViewModel`
5. Créer `AppDateFormat` singleton dans DesignSystem
6. Tests ≥3 (vérifier traductions complètes pour 3 écrans)

#### Tests attendus
- `Tests/LocalizationTests.swift` ≥3 tests : traductions complètes pour 3 écrans
- Regression : suite ≥ baseline

#### Livré
- **Catalogue** : 629 clés, `sourceLanguage = en`, la clé **est** la chaîne anglaise, et fr/de/es/it pour chaque clé porteuse de mots (620 × 4 ; 7 clés mémoire portent en plus un `en` explicite ; seules `· %@` et `360°` n'ont rien à traduire). Invariant mesuré : **catalogue ≡ extraction du code — 0 clé manquante, 0 clé morte, 0 trou de traduction**. 13 clés françaises héritées (`Continuer`, `Identifiez-vous`, `Partager`, `Réessayer`…) réécrites en clés anglaises dans le code puis supprimées, avec 80 autres clés mortes.
- **Sélecteur de langue** : `AppLanguage` (nom localisé + nom natif, `available(in:)` = `supported` ∩ `Bundle.main.localizations`), `AppLanguageStore` (`UserDefaults["appLanguage"]` + `AppleLanguages`, drapeau de relance seulement si la langue rendue change vraiment), `LanguageSettingsViewModel`/`View` (poussée **sans** `NavigationStack` propre, lignes identifiées `languageRow.<code>`, toggle `useSystemLanguageToggle`), `LanguageToast` (bandeau glass, `languageToastDismiss`). Entrée « Language » dans la section **General** de `ProfileView`.
- **Application de la langue, en deux temps et volontairement** : `RootView` injecte `.environment(\.locale, …)` → tout `Text("…")` se retraduit immédiatement ; `AppleLanguages` fait suivre les chaînes construites hors rendu (view models, notifications, copie des widgets) **au prochain lancement**. iOS n'expose aucune API de relance d'app : le bandeau dit ce qui se passe au lieu d'offrir un bouton mort (écart assumé au brief UI, qui demandait « Relaunch »/« Later »).
- **Dates** : `Sources/DesignSystem/AppDateFormat.swift` — cache unique indexé (style, locale, timeZone, firstWeekday) sous `NSLock`, `Style` reproduisant les 7 configurations existantes + `relativeString`. Migrés : `LongDateFormatter` (garde ses parseurs ISO), `DateHeaderFormatter` (cache privé supprimé), `TimelineSectionBuilder`, `MemoriesView`, `MemoryMomentPresentation`, `ActivityFeedSheet` (un formatter **par ligne de liste** → partagé).
- **Tests** : `LocalizationTests` (10 : catalogues compilés pour fr/de/es/it, copie traduite dans les 5 langues, noms natifs, persistance de la relance, drapeau, VM) et `AppStringsTests` réécrit (4 gardes, dont « chaque clé porteuse de mots a fr/de/es/it »). `Tests/LocalizationTestSupport.swift` a rendu agnostiques 11 tests de VM/moteur qui pinnaient le texte **anglais** d'un message désormais localisé (le simulateur de la machine tourne en `fr-FR`).
- **Limite connue** : le titre de la barre de navigation ne se retraduit pas à chaud (ponté vers UIKit) — il suit au lancement suivant ; le corps de l'écran, lui, se retraduit immédiatement (vérifié : `App-Sprache` après sélection de l'allemand). Dit dans le scénario, pas corrigé.

---

### 2.11. Backup — Live Photos (P2)

#### Résultat (2026-09-10)
AC-LP01 – AC-LP07 **PASS**. `LivePhotoBackupTests` (11 tests) : ordre vidéo→photo, id renvoyé porté par la photo, rattachement rétroactif via `Result.assetId` + `updateAsset`, skip si `isTrashed`, defer du pair = defer de l'asset, échec dur du pair = échec sans upload, nettoyage des temps (fin de run + annulation), non-régression image simple.

**Fichier spec** : `.omp/backup-auto/backup-live-photos.specs.md`
**Card AC** : `.opencode/scratch/backup-live-photos.acceptance.md`
**AC Cards** : AC-LP01 – AC-LP07
**Phase** : P2 — Backup

#### Objectif
Sauvegarder les Live Photos **comme des Live Photos**. `BackupEngine.processBatch` upload aujourd'hui avec `livePhotoVideoId: nil` en dur (`BackupEngine.swift:410`) et n'exporte jamais la ressource `.pairedVideo` : le serveur reçoit une image morte et le `.MOV` n'existe nulle part ailleurs que sur l'appareil.

#### Points d'entrée
- `BackupCandidate` — ajouter `isLivePhoto` (défaut `false`, dernière position, init memberwise préservé)
- `BackupAssetSource` — `exportPairedVideo(for:onState:) -> URL?`
- `PhotoLibraryServiceImpl` — `mediaSubtypes.contains(.photoLive)`, ressource `.pairedVideo`, extraction de `writeResource` (la boucle de retry iCloud 1005 + `StallWatchdog` NE DOIT PAS être dupliquée)
- `BackupEngine` — staging à 4 champs, upload vidéo `visibility: .hidden` avant la photo, helper unique `removeStaged` pour le nettoyage des temps

#### Endpoint API
- `POST /api/assets` — existant (`visibility`, `livePhotoVideoId` déjà supportés)
- `PATCH /api/assets/:id` — existant (`updateAsset` + `UpdateAssetDto.livePhotoVideoId`)

#### Étapes d'implémentation
1. `BackupCandidate.isLivePhoto` + `exportPairedVideo` au protocole
2. `PhotoLibraryServiceImpl` : `writeResource` partagé, sélection `.pairedVideo` / `.fullSizePairedVideo`
3. `BackupEngine` : export + hash du pair au staging, `batchBytes` cumule les deux tailles
4. Chemin `accept` : vidéo `.hidden` → `response.id` → photo avec `livePhotoVideoId`
5. Chemin `reject` : `Result.assetId` (présent sur les rejects) → vidéo + `updateAsset(livePhotoVideoId:)` — **seul moyen de réparer les Live Photos déjà montées en images mortes**
6. Mocks (ordre des uploads, `visibility`, `updateAsset`) + tests

#### Tests attendus
- `Tests/BackupEngineTests.swift` → `LivePhotoBackupTests` ≥7 tests : ordre d'upload, id renvoyé, rattachement rétroactif, defer du pair, unité de progression unique, nettoyage temp à l'annulation, non-régression image simple
- Regression : suite ≥ 645

---

### 2.12. Backup — Album Scoping (P2)

#### Résultat (2026-09-10)
AC-AS01 – AC-AS08 **PASS**. `BackupEngineExclusionTests` (5 tests) + migration/persistance dans `BackupSettingsStoreTests` (3) : la source résout l'exclusion par soustraction d'identifiants (un `PHAsset.fetchAssets` par album exclu au lieu d'un `fetchAssetCollectionsContaining` par asset), smart albums exposés avec des ids stables (`BackupAlbum.SmartID`), anciennes clés supprimées après migration one-shot de `excludeScreenshots`.

**Fichier spec** : `.omp/backup-auto/backup-album-scoping.specs.md`
**Card AC** : `.opencode/scratch/backup-album-scoping.acceptance.md`
**AC Cards** : AC-AS01 – AC-AS08
**Phase** : P2 — Backup

#### Objectif
Remplacer les exclusions heuristiques par nom de fichier par une vraie sélection/exclusion d'albums. `excludeCameraRoll` = `!hasPrefix("IMG_")` exclut presque toute une pellicule iPhone ; `excludeWhatsApp` = `!contains("WhatsApp")` ne filtre rien sur iOS. `excludeScreenshots` compare `albumName`, qui n'est **qu'un** album par asset.

#### Points d'entrée
- `BackupSettings` / `BackupSettingsStore` — `excludedAlbumIDs` (clé `photoBackupExcludedAlbums`), suppression des 3 anciens booléens + migration one-shot de `excludeScreenshots`
- `BackupAssetSource` — `fetchCandidates(in:excluding:)`, `BackupAlbum.isSmart`, suppression de `BackupCandidate.albumName`
- `PhotoLibraryServiceImpl` — smart albums (`smartAlbumScreenshots`…) dans `fetchAlbums`, exclusion par `Set<String>` de `localIdentifier`, suppression de `assetAlbumName`
- `BackupSettingsView` / `AlbumPickerView` — « Albums to back up » + « Albums to skip », picker paramétré par `Binding<Set<String>>`

#### Endpoint API
- Aucun (PhotosKit uniquement)

#### Étapes d'implémentation
1. Protocole : `excluding:`, `isSmart`, retrait de `albumName`
2. Source : ensemble d'exclusion calculé en amont — supprime au passage le `fetchAssetCollectionsContaining` **par asset** du scan complet
3. Engine : suppression des 3 `filter` (l.209-217) et de `screenshotsAlbumName`
4. Store : nouvelle clé + migration + `removeObject` des clés mortes
5. UI : deux périmètres d'albums, plus aucun toggle d'exclusion heuristique
6. Tests

#### Tests attendus
- `Tests/UploadViewModelTests.swift` → `BackupEngineExclusionTests` réécrite, ≥5 tests : transmission du scoping, `IMG_0001.HEIC` sauvegardé, migration `excludeScreenshots`, persistance, clés legacy supprimées
- Regression : TEST SUCCEEDED (le compte peut baisser — les tests qui pinnaient les filtres nom-de-fichier meurent avec le code)

---

### 2.13. Backup — Ledger Reconciliation (P2)

#### Résultat (2026-09-10)
AC-LR01 – AC-LR08 **PASS**. `BackupLedgerReconciliationTests` (13 tests) : fichier v2 versionné + v1 toujours lisible, checksum mémorisé aux deux `markBackedUp`, passe hebdo par chunks de `checkChunkSize` (100), `isTrashed` conservé, erreur réseau silencieuse, asset oublié re-uploadé dans le même run, `deviceAssetId`/`deviceId` envoyés, `DeviceIdentity` (UUID persisté, pas `identifierForVendor`).

**Fichier spec** : `.omp/backup-auto/backup-ledger-reconciliation.specs.md`
**Card AC** : `.opencode/scratch/backup-ledger-reconciliation.acceptance.md`
**AC Cards** : AC-LR01 – AC-LR08
**Phase** : P2 — Backup

#### Objectif
Rendre `BackupLedger` auto-réparant. Il n'est jamais confronté au serveur : un asset supprimé côté serveur reste marqué « backed up », est filtré avant export (`BackupEngine.swift:224`) et ne remonte **jamais**. Le client Flutter n'a pas ce trou (dédup = `remote_asset_entity` réalimentée par `/api/sync/stream`).

#### Points d'entrée
- `BackupLedgerStoring` / `BackupLedger` — `markBackedUp(id:signature:checksum:)`, `entriesForReconciliation()`, `forget(ids:)`, `lastReconciliation`, fichier JSON **versionné** (v1 `[String: String]` reste lisible)
- `BackupEngine` — `reconcileLedgerIfDue()` avant `fetchCandidates`, chunks de `checkChunkSize`, `reconcileInterval = 7 jours`
- `ImmichAPIClient.uploadAsset` — ajouter `deviceAssetId` + `deviceId` aux champs multipart (l.480-491 : **aucun des deux n'est envoyé** aujourd'hui)
- **NEW** `Sources/Services/DeviceIdentity.swift` — UUID persisté (⚠ pas `identifierForVendor`)
- `BackupSettingsView` — « Last server check » + action non destructive « Check server now » à côté du reset

#### Endpoint API
- `POST /api/assets/bulk-upload-check` — existant : `action == "accept"` = le serveur ne l'a pas. Le checksum est **déjà calculé** par le run, donc la réconciliation ne coûte aucun octet de média.
- `GET /api/assets/device/:deviceId` — **écarté** (inutilisable sur l'historique : champs device jamais envoyés ; dépend de la version serveur)

#### Étapes d'implémentation
1. Protocole + `BackupLedger` v2 (`Entry { signature, checksum? }`, `lastReconciliation`) avec fallback v1
2. Passer le checksum aux deux `markBackedUp` (reject l.362-364, upload l.414)
3. `reconcileLedgerIfDue()` off-main ; une erreur réseau n'est **pas** un échec de run (ni `lastError` ni `failures`)
4. `deviceAssetId` / `deviceId` + `DeviceIdentity`
5. UI Backup tracking + tests, puis `xcodegen generate`

#### Tests attendus
- `Tests/BackupLedgerReconciliationTests.swift` ≥10 tests : migration v1, round-trip v2, oubli des entrées absentes du serveur, conservation des rejects, `isTrashed` conservé, throttle, erreur réseau silencieuse, chunking, ré-upload dans le même run, entrées sans checksum ignorées, `deviceAssetId`/`deviceId` envoyés
- Regression : suite ≥ 655

#### Pièges cadrés dans la spec
- `isTrashed == true` ⇒ le serveur l'a : **ne pas** oublier l'entrée
- Changement de compte : vider le ledger explicitement (sinon la réconciliation le vide à l'aveugle → re-backup complet d'une photothèque iCloud)

---

### 2.14. Backup — Network Policy (P2)

#### Résultat (2026-09-10)
AC-NP01 – AC-NP07 **PASS**. `NetworkPolicyTests` (7 tests) : gate `isOnline` global, décision par asset avant export (zéro download iCloud pour un asset reporté), `allowCellularForPhotos`/`ForVideos`, report typé (`BackupDeferralReason`) jamais compté en échec, run manuel hors politique, `test_backup_wifiGateBlocksRun` remplacé.

**Fichier spec** : `.omp/backup-auto/backup-network-policy.specs.md`
**Card AC** : `.opencode/scratch/backup-network-policy.acceptance.md`
**AC Cards** : AC-NP01 – AC-NP07
**Phase** : P2 — Backup

#### Objectif
Politique réseau par type de média (parité `useCellularForPhotos` / `useCellularForVideos`) et vraie notion de hors-ligne. Aujourd'hui le gate est tout-ou-rien (`BackupEngine.swift:186-189`) et un run hors ligne exporte, hashe, puis compte **tous** les assets en `failedCount` — exactement la classe de faux échecs que le bucket `deferred` a éliminée pour l'iCloud.

#### Points d'entrée
- `BackupEnvironment` — `isOnline` (le `NWPathMonitor` de `SystemBackupEnvironment` reçoit déjà le `path`)
- `BackupSettings` — `allowCellularForPhotos`, `allowCellularForVideos`
- `BackupEngine` — gate global `isOnline` + `isUploadAllowedNow(candidate:settings:)` testé **avant** `exportOriginal` ; résultat = `deferredCount`, pas `failedCount` ; `BackupDeferralReason`
- `BackupSettingsView` — 2 toggles indentés sous « Wi-Fi only » + légende « Waiting for Wi-Fi » vs « Waiting for iCloud »

#### Endpoint API
- Aucun (Network.framework)

#### Étapes d'implémentation
1. `isOnline` au protocole + cache `NWPathMonitor`
2. Gate global hors-ligne (branche `!manual` uniquement)
3. Décision par asset → defer avant tout export (aucun download iCloud pour un asset reporté)
4. `deferralReason` + libellés UI
5. Tests

#### Tests attendus
- `Tests/BackupEngineTests.swift` → `NetworkPolicyTests` ≥7 tests : hors-ligne = pipeline non entré, photo uploadée / vidéo reportée en cellulaire, asset reporté jamais exporté, pas de `lastError`, Wi-Fi ignore les toggles, run manuel ignore la politique, raison du report
- `test_backup_wifiGateBlocksRun` pinne l'ancien contrat tout-ou-rien : **remplacé**, pas re-pinné
- Regression : suite ≥ 645

---

### 2.15. Backup — Library Observer (P2)

#### Résultat (2026-09-10)
AC-LO01 – AC-LO07 **PASS**, AC-LO08 **manuel** (non simulable : `PHPhotoLibraryChangeObserver`). `PhotoLibraryChangeMonitorTests` (6 tests) : règle `shouldObserveLibraryChanges`, réveil unique malgré deux insertions, réveil ignoré pendant un run. `PhotoLibraryChangeMonitor` filtre sur `insertedObjects` (une édition ne déclenche pas de scan complet) et débounce 5 s.

**Fichier spec** : `.omp/backup-auto/backup-library-observer.specs.md`
**Card AC** : `.opencode/scratch/backup-library-observer.acceptance.md`
**AC Cards** : AC-LO01 – AC-LO08
**Phase** : P2 — Backup

#### Objectif
Faire que « Auto-detect new photos » détecte réellement les nouvelles photos. Aucun `PHPhotoLibraryChangeObserver` n'existe dans `Sources/` : le toggle n'autorise qu'un scan à l'activation de scène (`DependencyContainer.kickOffAutoBackup` ← `ImmichSwiftUIApp.swift:24`). Le libellé promet ce que le code ne fait pas.

#### Points d'entrée
- **NEW** `Sources/Core/Protocols/PhotoLibraryChangeMonitoring.swift` — `onAssetsInserted`, `start()`, `stop()`
- **NEW** `Sources/Services/PhotoLibraryChangeMonitor.swift` — baseline `PHFetchResult`, réveil **uniquement** si `changeDetails.insertedObjects` non vide, débounce 5 s, hop `@MainActor`
- `DependencyContainer` — `libraryMonitor` injectable + `syncLibraryMonitor()`
- `ImmichSwiftUIApp` — `sync` sur `.active`, `stop()` sur `.background`
- `BackupSettingsView` — libellé « Back up new photos automatically » + footer qui assume les deux régimes (temps réel au premier plan, BGTask sinon)

#### Contrainte plateforme
iOS n'a pas d'équivalent des content-URI triggers Android utilisés par Flutter (étude §3.3). Les seuls déclencheurs sont : activation au premier plan, fenêtres `BGTaskScheduler`, et `PHPhotoLibraryChangeObserver` **pendant que l'app tourne**.

#### Étapes d'implémentation
1. Protocole + monitor (filtre insertions, débounce, idempotent, `deinit` → `stop`)
2. Câblage `DependencyContainer` + cycle de vie de scène
3. Libellé + footer honnêtes
4. `MockLibraryMonitor` + tests, puis `xcodegen generate` (2 fichiers NEW)

#### Tests attendus
- `Tests/PhotoLibraryChangeMonitorTests.swift` ≥6 tests (via mock) : start/stop selon les 2 toggles, callback → un seul run, ignoré pendant un run, débounce coalescant
- **AC-LO08 manuel** : app ouverte, ajout d'une photo, run déclenché en <10 s (anneau visible autour de l'avatar) — non simulable en unitaire
- Regression : suite ≥ 645

---

### 2.16. Shared Link Viewer (P3, issue #22) — ✅ Terminé (2026-09-13)

**Fichier spec** : aucun (feature neuve, hors parité Flutter)
**Card AC** : `.opencode/scratch/shared-link-viewer.acceptance.md` (AC-4000…AC-4005, réécrite le 2026-09-13 sur le contrat réel puis livrée)
**Phase** : P3 — Social

#### Résultat (2026-09-13)
**6/6 AC PASS.** Suite **772 → 805 tests, TEST SUCCEEDED** (iPhone 17, `-only-testing:ImmichSwiftUITests`) + `test_SLV_viewer` de bout en bout contre le stub **committé** `UITests/stubs/immich_stub_shared_link_viewer.py`, vert sur **deux runs consécutifs**.

#### Objectif
Ouvrir un lien partagé **reçu** : vérifier son mot de passe, parcourir ses photos, et — quand le lien l'autorise — y déposer une photo. Feature neuve : le client Flutter n'a qu'une page liste et une page création/édition, et les trois routes que #17 annonçait pour ce viewer (`/shared-links/public/:slug`, `/:slug/assets`, `/:slug/check-password`) n'existent pas côté serveur.

#### Contrat réel (vérifié le 2026-09-13)
- `GET /api/shared-links/me?key=<base64url>` **ou** `?slug=<slug>` — auth `sharedLink: true` ; un lien protégé répond **401 `"Password required"`** tant que le cookie de login manque
- `POST /api/shared-links/login?key=|slug=` body `{password}` → DTO + `Set-Cookie: immich_shared_link_token` ; mauvais mot de passe = 401 `"Invalid password"`
- `POST /api/search/metadata?key=` avec `albumIds` — **seule** recherche autorisée sous auth partagée (« Shared link access is only allowed in combination with an albumIds filter », `search.service.ts:93`) ; un lien INDIVIDUAL porte ses `assets` dans le DTO
- `POST /api/assets?key=` (multipart) gardé par `requireUploadAccess` : **401 nu** si `allowUpload` est faux

#### Livré
- `ImmichAPIClient.sendSharedLinkRaw` — chemin **distinct** : pas de bearer, credential en query, cookie de login rejoué, et 401 qui **n'atteint jamais `authDelegate`** (sinon demander un mot de passe aurait déconnecté l'utilisateur — FM-4)
- **4 méthodes** sur `ImmichClient` + `ImmichAPIClient` : `getSharedLinkMine`, `loginToSharedLink`, `getSharedLinkAlbumAssets`, `uploadAssetToSharedLink`
- `SharedLinkCredential` (`key` ou `slug` — le serveur lit l'un **ou** l'autre), `SharedLinkLoginDto`, `ImmichCookie.sharedLinkToken`
- `SharedLinkURL.reference(from:)` — lit un lien collé (`/s/<slug>`, `/share/<key>`, sans schéma, ou jeton nu désambiguïsé par forme)
- **NEW** `Sources/Features/SharedLinks/SharedLinkViewerViewModel.swift` + `SharedLinkViewerView.swift` — phases `entry`/`passwordRequired`/`loading`/`opened`/`deadLink`/`failed`, pagination de l'album, upload invité, pager plein écran réutilisant `ZoomableImageView`
- `AssetThumbnailCell` + `ImmichAssetURL` + `AssetReactItem` gagnent un `sharedLink:` (credential dans l'URL de vignette ; le menu contextuel du propriétaire disparaît pour un visiteur)
- Entrée : bouton dans la barre de l'onglet Partage → feuille `SharedLinkViewerView`

#### Tests livrés
- `Tests/ImmichAPIClientTests.swift` : 7 tests `test_SLV_*` (sans bearer, slug, cookie conservé, 401 du lien qui ne déconnecte pas, recherche album, upload multipart, refus d'upload)
- `Tests/SharedLinkViewerViewModelTests.swift` : 20 tests (entrée, hôte étranger, mot de passe, lien mort, pagination, upload, reset)
- `Tests/SharedLinkURLTests.swift` : +6 tests de lecture de lien
- `UITests/ImmichRenderScreenshots.swift/test_SLV_viewer` + stub committé
- Regression : suite 772 → **805**, TEST SUCCEEDED

#### Pièges
- **Vignette publique en plein écran** : `size=fullsize` redirige vers `original` (permission `AssetDownload`) — le serveur force `edited = true` sous auth partagée, ce qui neutralise la redirection. Sans cela, les photos d'un lien en lecture seule auraient été cassées.
- **`AuthenticatedAsyncImage` met les vignettes en cache disque par URL** : avec des ids d'assets fixes, le 2ᵉ run du scénario trouvait les images en cache et la requête prouvant le credential n'était plus émise. Le stub régénère donc ses ids à chaque `/__reset`.
- **Les stubs frères servent des JPEG que ImageIO ne décode pas** (`immich_stub_memories.py`, `immich_stub_shared_links.py`, octets 1×1) : leurs captures montrent une grille d'images cassées alors que l'app est correcte. Ce stub-ci génère un vrai PNG 8×8.

---

### 2.17. Registre des écarts vs upstream — audit 2026-09-15 (aucune carte AC ouverte)

> Ce registre (v3.2.1, audit 2026-09-15) est remplacé par `docs/parity-registry-v3.4.0.md` (cible v3.4.0, audit 2026-11-11) ; il reste ici en historique.

Audit du client officiel `immich-app/immich` @ `main` (`e55ac299`, release **v3.2.1** du
2026-09-14), comparé à l'état du dépôt au 2026-09-15. Sources upstream : `mobile/lib/routing/router.dart`
(57 routes, 3 guards), `mobile/lib/{pages,presentation/pages,services,domain/services,widgets/settings}`,
`mobile/pubspec.yaml`, `mobile/ios/**` + `AndroidManifest.xml`, `docs/docs/features/**` (20 docs),
`web/src/routes/**`. Endpoints relus sur `/tmp/immich-openapi-main.json` (OpenAPI publié `main`).

La référence de parité `docs/mobile-features-vs-flutter.md` a été corrigée par le même audit
(casting mobile, OCR, note par étoiles, ordonnanceur Android, §23 « Cluster Groups » = feature
fantôme, table des gaps #1/#2/#5/#12 close).

#### Écarts ouverts, par phase proposée

| # | Feature upstream | État iOS | Preuve upstream | Endpoint / mécanisme |
|---|------------------|----------|-----------------|----------------------|
| G1 | **Free Up Space** (nettoyage des originaux déjà sauvegardés) | ❌ absent | `presentation/pages/cleanup_preview.page.dart` (route `CleanupPreviewRoute`), `services/cleanup.service.dart`, `providers/cleanup.provider.dart`, `widgets/settings/free_up_space_settings.dart`, doc `mobile-app.mdx` § Free Up Space | PhotoKit local + `POST /api/assets/bulk-upload-check` ; cutoff date, keep favorites/albums, exclusion albums iCloud partagés, lots 10 000 (iOS) |
| G2 | **Album Sync** (miroir device → albums serveur + « Reorganize into album ») | ❌ absent | `domain/services/sync_linked_album.service.dart`, `local_sync.service.dart`, `local_album.service.dart` | `POST /api/albums`, `PUT /api/albums/{id}/assets`, `GET /api/albums` |
| G3 | **Bibliothèque locale « On this device »** (timeline locale, albums locaux, upload d'une sélection) | ❌ absent | routes `LocalTimelineRoute`, `LocalAlbumsRoute`, `LocalMediaSummaryRoute`, `RemoteMediaSummaryRoute` ; `presentation/pages/local_timeline.page.dart`, `local_album.page.dart`, `dev/media_stat.page.dart` | PhotoKit (`photo_manager`) + `POST /api/assets` |
| G4 | Écran de **statut de synchronisation** (sync beta) | ❌ absent | `pages/settings/sync_status.page.dart` (route `SyncStatusRoute`), `widgets/settings/beta_sync_settings/*` | état local + `GET /api/sync/stream`-free (compteurs locaux) |
| G5 | **Détail d'upload par asset** | 🟡 barre globale + Live Activity, pas d'écran par asset | `pages/backup/upload_detail.page.dart`, `backup_asset_detail.page.dart` | état local |
| G6 | **Indicateur de statut cloud** sur les tuiles (syncé vs local-only) | 🟡 badge offline seulement | doc `mobile-app.mdx` § Sync only selected photos, `widgets/settings/asset_list_settings/*` | état local (ledger) |
| G7 | **Note par étoiles 1–5 éditable** + filtre de recherche | 🟡 lecture seule (`PhotoInfoPanel.swift` affiche `exif.rating`) | `asset_viewer/rating_bar.widget.dart`, `asset_details/rating_details.widget.dart`, `search_filter/star_rating_picker.dart` | `PUT /api/assets` (`AssetBulkUpdateDto.rating`) ; filtre `rating` de `POST /api/search/metadata` |
| G8 | **Overlay OCR** (texte dans l'image) + recherche OCR | ❌ absent | `asset_viewer/ocr_overlay.widget.dart`, `ocr_toggle_button.widget.dart`, `domain/services/ocr.service.dart` | `GET /api/assets/{id}/ocr` ; filtre `ocr` de `POST /api/search/metadata` |
| G9 | **Casting Google Cast / Chromecast** | ❌ absent | `presentation/actions/cast.action.dart`, `widgets/asset_viewer/cast_dialog.dart`, `services/gcast.service.dart`, plugin `cast: ^2.1.0`, `NSBonjourServices _googlecast._tcp` | protocole Cast (mDNS + récepteur) |
| G10 | **Panneau de téléchargement** (originaux, file + progression) | 🟡 offline = épinglage, pas de file | `pages/common/download_panel.dart`, `presentation/pages/download_info.page.dart` (route `DownloadInfoRoute`) | `GET /api/assets/{id}/original` |
| G11 | **Vue dossiers** (arborescence, bibliothèques externes) | ❌ absent | `pages/library/folder/folder.page.dart` (route `FolderRoute`), `services/folder.service.dart` | `GET /api/view/folder`, `GET /api/view/folder/unique-paths` |
| G12 | **Dossier verrouillé + PIN** | ❌ absent (`AppLock` = verrou d'app, pas un dossier) | `presentation/pages/locked_folder.page.dart`, `routing/locked_guard.dart`, `pages/library/locked/pin_auth.page.dart`, plugin `pinput` | visibilité `locked` de `AssetVisibility` via `PUT /api/assets` ; **le PIN est serveur** : `POST /api/auth/pin-code` (6 chiffres), `PUT /api/auth/pin-code`, `POST /api/auth/session/unlock` (`isElevated`), `POST /api/auth/session/lock`, `GET /api/auth/status` — vérifié le 2026-09-15 sur l'OpenAPI `main`, aucune de ces 5 routes n'est câblée aujourd'hui |
| G13 | **Récemment pris / récemment ajoutés** | ❌ absent (`AssetOrderBy` existe, non branché) | routes `RecentlyTakenRoute`, `RecentlyAddedRoute`, `presentation/pages/recently_taken.page.dart`, `recently_added.page.dart` — l'upstream trie sur sa réplique locale Drift (`uploadedAt`), pas sur une route | `GET /api/timeline/buckets?orderBy=` (`takenAt` \| `createdAt`) : c'est la **seule** route capable de produire « récemment ajoutés » — `POST /api/search/metadata` ne le peut pas (`SearchOrderField` = `fileCreatedAt` \| `localDateTime` \| `fileSizeInBytes` \| `rating`, vérifié le 2026-09-15) |
| G14 | Filtres de recherche avancés (note, OCR, options d'affichage) + réglages carte (plage de temps, feuille carte dans le viewer) | 🟡 | `search_filter/{star_rating_picker,display_option_picker}.dart`, `widgets/map/map_settings/map_custom_time_range.dart`, `widgets/bottom_sheet/map_bottom_sheet.widget.dart` | paramètres de `POST /api/search/metadata` / `GET /api/map/markers` |
| G15 | Édition de l'**anniversaire** d'une personne | ❌ absent | `widgets/people/person_edit_birthday_modal.widget.dart` | `PUT /api/people/{id}` (`birthDate`) |
| G16 | **Photo de profil** (upload + crop) | ❌ absent (avatars à initiales) | `presentation/pages/profile/profile_picture_crop.page.dart` (route `ProfilePictureCropRoute`) | `GET /api/users/me/profile-image`, `POST /api/users/profile-image` |
| G17 | **Mode lecture seule / kid mode** | ❌ absent | `providers/infrastructure/readonly_mode.provider.dart`, doc `mobile-app.mdx` § Read-only/kid Mode | garde client (aucun endpoint) |
| G18 | **Changement de mot de passe** | ❌ absent (`shouldChangePassword` non consommé) | `pages/login/change_password.page.dart` (route `ChangePasswordRoute`) | `POST /api/auth/change-password` |
| G19 | **Sessions / appareils connectés** | ❌ absent | `user-settings-page/DeviceCard.svelte` (web) + écrans de compte du client mobile | `GET /api/sessions`, `DELETE /api/sessions/{id}`, `POST /api/auth/session/{lock,unlock}` |
| G20 | **Clés API utilisateur** (hors admin) + rotation | 🟡 admin seulement (`/api/api-keys`) | `user-settings-page/UserApiKeyGrid.svelte` | `GET /api/api-keys` (liste des clés de l'utilisateur courant, non réservée aux admins), `GET /api/api-keys/me` (**une seule** clé : celle qui porte la requête), `POST /api/api-keys`, `DELETE /api/api-keys/{id}`, **`POST` `/api/api-keys/{id}/rotate`** (pas PUT — coquille corrigée le 2026-09-15 par la spec `user-api-keys`) |
| G21 | **Extension de partage iOS** (partager une photo *vers* Immich) | ✅ livré (cible `ImmichShareExtension`, `project.yml:187-227`) | `mobile/ios/ShareExtension/`, plugin `share_handler`, route `ShareIntentRoute` | `POST /api/assets` (upload depuis la share sheet) |
| G22 | Réglages manquants : photo grid (regroupement/layout), viewer (qualité image, tap-to-navigate, vidéo, slideshow), préférences (thème, couleur primaire, haptique) | 🟡 | `widgets/settings/{asset_list_settings,asset_viewer_settings,preference_settings}/*` | client |
| G23 | Écrans « Quoi de neuf » + licences open-source | ❌ absent | route `WhatsNewRoute`, `presentation/pages/feature_message/whats_new.page.dart`, `utils/licenses.dart` | client (+ `feature_message` serveur) |
| G24 | Utilitaires : logs applicatifs, dépannage asset, infos de téléchargement, stats média | ❌ absent (seuls stockage + doublons existent) | routes `AppLogRoute`, `AppLogDetailRoute`, `AssetTroubleshootRoute`, `DownloadInfoRoute` ; `pages/common/app_log{,_detail}.page.dart`, `presentation/pages/asset_troubleshoot.page.dart` | client (+ `POST /api/assets/bulk-upload-check`, `GET /api/assets/{id}/original`) |

Hors périmètre iOS (Android seulement) : VIEW intent (`services/view_intent.service.dart`),
foreground service de sync, Obtainium, empreintes de certificats de release.

#### Au-delà de la parité (livré, rien à faire)

Live Activity + Dynamic Island (absentes du Flutter), 4 widgets + AppIntents/Spotlight (Flutter : 1 widget
iOS, 2 Android), viewer public de lien partagé (le Flutter n'a que liste + édition), résolution des
doublons, panneau d'administration (web-only côté upstream), RoadTrip, multi-comptes/multi-serveurs,
filtres de timeline `personId`/`withPartners`/`visibility`/`withStacked`.

#### Divergences assumées (pas des écarts)

- **IA d'onglets** : iOS = 5 onglets (Photos, Memories, Albums, Shared, Search) + hub « Me » portant
  Trash/Backup/People/Tags/Stacks/Partners/Admin/Offline/Notifications/Language ; Flutter = 4 onglets
  (Timeline, Search, Library, Albums).
- **Notations** : Flutter = `workmanager` historique remplacé par `worker_manager` ; iOS = `BGTaskScheduler`.
- **Réglages de sécurité** : iOS applique `AppLock` global (Face ID) ; le PIN n'existe chez Flutter que
  pour le dossier verrouillé (G12).

#### Limites de l'audit

- `mobile/generated/openapi` n'a pas été énuméré : une fonctionnalité peut exister côté DTO sans UI mobile
  (elle n'est alors pas dans ce registre).
- Les vérifications d'absence sont des greps sur l'arbre récursif `mobile/lib` à `e55ac299` ; elles
  portent sur le code, pas sur le comportement runtime du client Flutter.

---

## Plan des écarts — ce qu'il reste à faire (post-audit 2026-09-15)

16 cartes sont livrées (§2.1–§2.16). Le registre §2.17 a produit **25 features restantes**, chacune
avec son dossier de specs dans `.omp/<slug>/` :

| Fichier | Contenu |
|---|---|
| `<slug>.specs.md` | exigences, hypothèses vérifiées (fichiers/symboles/routes), approches A/B/C avec rationale, étapes numérotées NEW/EDIT, incertitudes à lever |
| `<slug>.ui.md` | brief UI/UX : philosophie, placement dans la navigation, layout, composants et tokens, interactions, accessibilité, animations, **erreurs à ne pas faire** (mesurées dans ce dépôt) |
| `<slug>.AC.md` | critères d'acceptance exécutables (grep + `sh -c`, pré-état FAIL justifié / post-état PASS), dernier critère = régression de la suite |

> **Dossiers livrés le 2026-09-15** : les 25 fiches ont leurs trois fichiers — **75 fichiers, 11 588 lignes**
> (specs ≈ 120–200 lignes, briefs UI ≈ 150–200, cartes AC ≈ 110–180). Les **250 critères d'acceptance**
> ont tous été exécutés en pré-état sur le dépôt : `FAIL` dans les 25 cartes, sans erreur de syntaxe
> (9 par carte + 1 régression, bandes `AC-5000` → `AC-5249` disjointes). La colonne « Statut » du tableau
> ci-dessous décrit l'**implémentation du code**, pas l'écriture des specs.

**Corrections que les specs ont apportées à l'audit** (vérifiées pendant leur rédaction) :

- **Dossier verrouillé** : le PIN est **serveur** (`POST|PUT /api/auth/pin-code`, `POST /api/auth/session/unlock`,
  `GET /api/auth/status → isElevated`), pas un garde local — corrigé dans §2.17.
- **Récemment ajoutés** : seule `GET /api/timeline/buckets?orderBy=createdAt` le permet ; `POST /api/search/metadata`
  n'a aucune date d'ajout triable — corrigé dans §2.17.
- **Clés API** : la rotation est un **POST**, et la liste vient de `GET /api/api-keys` (non admin) tandis que
  `GET /api/api-keys/me` ne rend **qu'une** clé — corrigé dans §2.17.
- **Casting** : Google ne publie pas de paquet SPM officiel du SDK Cast et le dépôt n'a pas de `Podfile` ;
  l'approche retenue livre **AirPlay** (`AVRoutePickerView` + `AVRouteDetector`) et laisse le Cast conditionné.
  Conséquence assumée : AirPlay ne transporte pas d'image fixe — **G9 reste partiellement ouvert pour la photo**.
- **Téléchargement** : il existe un chemin **de lot** en deux temps (`POST /download/info` puis
  `POST /download/archive`, décrit par le contrat) que l'audit ignorait.
- **OCR** : le filtre scalaire `ocr` est déprécié depuis v3.2.0 au profit de `filter.ocr` (`StringSimilarityFilter`) ;
  les tons de dépannage (`ratingsEnabled`, `GET /assets/{id}/ocr`) restent inchangés.
- **Note par étoiles** : la dénotation exige un `null` **explicite** (les DTOs locaux utilisent `encodeIfPresent`,
  qui omet la clé) — un DTO dédié est prescrit ; `0` et `-1` sont invalides en écriture depuis la v3.
- **« Quoi de neuf »** : les notes sont **embarquées** dans l'app (aucun endpoint `featureMessage`), la release
  vue est le seul état persistant.
- **Sessions/appareils** : `DELETE /api/sessions` **ne supprime pas** la session courante (le serveur exclut
  `currentSessionId`), `POST /api/auth/session/lock` est **sans corps** et retire l'accès élevé,
  `POST /api/auth/session/unlock` ne lit que `pinCode` et pose un **TTL de 15 min côté serveur** ; les deux
  routes `/auth/session/*` exigent un **token de session** (400 pour un compte par clé API) ; l'élévation
  n'est exposée par **aucun** champ de `SessionResponseDto`, mais elle se lit sur le serveur par
  `GET /api/auth/status` (`AuthStatusResponseDto.isElevated`), dans le dossier verrouillé comme dans l'écran
  des sessions. Le client Flutter n'a **rien** sur les
  sessions : l'écran iOS s'aligne sur `DeviceCard.svelte` (web).
- **Sync/dossier** : les deux features s'appuient sur `POST /api/assets/bulk-upload-check` + le ledger
  (`BackupLedger.entriesForReconciliation()`), pas sur une base locale.

Convention de livraison inchangée (mêmes règles que les 16 cartes livrées) : une issue GitHub par
feature dans le projet [#2](https://github.com/users/millianlmx/projects/2) (fermée par
l'automatisation « Auto-close » quand l'item passe en `Done`), implémentation par la card AC,
rapport AC pass/fail, entrée mémoire datée, régénération `xcodegen` et suite complète.

### Tableau de suivi

| # | Feature | Slug (`.omp/`) | Phase | Bande AC | Endpoints / mécanisme | Statut |
|---|---------|----------------|-------|----------|-----------------------|--------|
| 17 | Journal applicatif, dépannage asset, infos download, stats média | `app-utilities` | P5 | AC-5240–5249 | `GET /api/assets/{id}`, `POST /api/assets/bulk-upload-check`, `GET /api/server/statistics`, état local du cache | ✅ Livré (2026-09-15) — 10/10 AC |
| 18 | Free Up Space | `free-up-space` | P2 | AC-5000–5009 | PhotoKit `PHPhotoLibrary.performChanges` + `POST /api/assets/bulk-upload-check` | ✅ Livré (2026-09-15) — 10/10 AC |
| 19 | Album Sync + Reorganize | `album-sync` | P2 | AC-5010–5019 | `GET /api/albums`, `POST /api/albums`, `PUT /api/albums/{id}/assets` | ✅ Livré (2026-09-15) — 10/10 AC |
| 20 | Bibliothèque locale « On this device » | `local-library` | P2 | AC-5020–5029 | PhotoKit + `POST /api/assets` | ✅ Livré (2026-09-15) — 10/10 AC |
| 21 | Écran de statut de synchronisation | `sync-status` | P2 | AC-5030–5039 | état local (`BackupLedger`, file, index offline) | ✅ Livré (2026-09-15) — 10/10 AC |
| 22 | Détail d'upload par asset | `upload-detail` | P2 | AC-5040–5049 | état local du `BackupEngine` | ✅ Livré (2026-09-15) — 10/10 AC |
| 23 | Indicateur de statut cloud sur les tuiles | `sync-badge` | P2 | AC-5050–5059 | `POST /api/assets/bulk-upload-check` + ledger | ✅ Livré (2026-09-15) — 10/10 AC |
| 24 | Note par étoiles éditable + filtre | `star-ratings` | P3 | AC-5060–5069 | `PUT /api/assets` (`rating`), filtre `rating` de `POST /api/search/metadata` | ✅ Livré (2026-09-15) — 10/10 AC |
| 25 | Overlay OCR + recherche par texte | `ocr-text` | P3 | AC-5070–5079 | `GET /api/assets/{id}/ocr`, filtre `ocr` | ✅ Livré (2026-09-15) — 10/10 AC |
| 26 | Casting vers un écran | `chromecast` | P3 | AC-5080–5089 | client (AVRoutePicker/AirPlay ou Google Cast SDK) | ✅ Livré (2026-09-15) — 10/10 AC |
| 27 | Panneau de téléchargement | `download-panel` | P3 | AC-5090–5099 | `GET /api/assets/{id}/original`, `…/video/playback` | ✅ Livré (2026-09-15) — 10/10 AC |
| 28 | Vue dossiers | `folder-view` | P4 | AC-5100–5109 | `GET /api/view/folder`, `GET /api/view/folder/unique-paths` | ✅ Livré (2026-09-15) — 10/10 AC |
| 29 | Dossier verrouillé + PIN | `locked-folder` | P4 | AC-5110–5119 | `PUT /api/assets` (`visibility: locked`), buckets `visibility=locked` | ✅ Livré (2026-09-15) — 10/10 AC |
| 30 | Récemment pris / récemment ajoutés | `recently-taken` | P4 | AC-5120–5129 | `POST /api/search/metadata` (`orderBy`) | ✅ Livré (2026-09-15) — 10/10 AC |
| 31 | Filtres de recherche avancés | `search-filters` | P4 | AC-5130–5139 | champs de `MetadataSearchDto` (`rating`, `ocr`, `orderBy`, …) | ✅ Livré (2026-09-15) — 10/10 AC |
| 32 | Réglages carte + carte dans le viewer | `map-settings` | P4 | AC-5140–5149 | `GET /api/map/markers`, plage temporelle de recherche | ✅ Livré (2026-09-15) — 10/10 AC |
| 33 | Anniversaire d'une personne | `person-birthday` | P4 | AC-5150–5159 | `PUT /api/people/{id}` | ✅ Livré (2026-09-15) — 10/10 AC |
| 34 | Photo de profil (upload + crop) | `profile-picture` | P4 | AC-5160–5169 | routes `profile-image` de `/api/users` (multipart) | ✅ Livré (2026-09-15) — 10/10 AC |
| 35 | Mode lecture seule / kid mode | `read-only-mode` | P5 | AC-5170–5179 | client (garde sur les actions destructrices) | ✅ Livré (2026-09-15) — 10/10 AC |
| 36 | Changement de mot de passe | `change-password` | P5 | AC-5180–5189 | `POST /api/auth/change-password` | ✅ Livré (2026-09-15) — 10/10 AC |
| 37 | Sessions / appareils connectés | `device-sessions` | P5 | AC-5190–5199 | `GET /api/sessions`, `DELETE /api/sessions/{id}`, `POST /api/auth/session/{lock,unlock}` | ✅ Livré (2026-09-15) — 10/10 AC |
| 38 | Clés API utilisateur | `user-api-keys` | P5 | AC-5200–5209 | `GET /api/api-keys/me`, `POST /api/api-keys`, `DELETE /api/api-keys/{id}`, rotation | ✅ Livré (2026-09-15) — 10/10 AC |
| 39 | Extension de partage iOS | `share-extension` | P5 | AC-5210–5219 | nouvelle cible `ShareExtension` + `POST /api/assets` (Keychain partagé) | ✅ Livré (2026-09-15) — 10/10 AC |
| 40 | Réglages grid / viewer / préférences | `settings-parity` | P5 | AC-5220–5229 | client (`@AppStorage`) | ✅ Livré (2026-09-15) — 10/10 AC |
| 41 | « Quoi de neuf » + licences | `whats-new` | P5 | AC-5230–5239 | notes embarquées ou serveur (à trancher en lisant l'upstream) | ✅ Livré (2026-09-15) — 10/10 AC |

### Ordre d'implémentation conseillé

Un seul critère d'ordre : une feature qui **produit un socle réutilisé** passe avant celles qui le
consomment. Les features d'une même phase restent indépendantes entre elles.

**P2 — cœur de l'app (back-up et espace disque)**

1. `sync-badge` — introduit le prédicat « cet asset est-il sur le serveur ? » (ledger + `bulk-upload-check`).
2. `upload-detail` — expose l'état par asset du dernier run (le même prédicat, à l'échelle d'un asset).
3. `sync-status` — agrège ledger + file + index offline ; consomme l'état exposé par l'étape 2.
4. `free-up-space` — consomme le prédicat de l'étape 1 pour ne supprimer que le sauvegardé (feature destructive : la faire après les surfaces d'inspection).
5. `album-sync` — ajoute l'énumération des albums et la création/fusion côté serveur.
6. `local-library` — réutilise l'énumération de l'étape 5 pour la timeline locale et l'upload de sélection.

**P3 — viewer** : `star-ratings` (contrat `PUT /api/assets` + DTO) → `ocr-text` (réutilise le viewer) →
`download-panel` (réutilise la file offline) → `chromecast` (décision de dépendance à assumer, donc en dernier).

**P4 — découverte** : `search-filters` **après** `star-ratings` et `ocr-text` (il expose leurs filtres) →
`recently-taken` → `map-settings` → `folder-view` → `person-birthday` → `profile-picture` → `locked-folder`
(le plus lourd : PIN, visibilité, écran protégé).

**P5 — plateforme** : `change-password` → `device-sessions` → `user-api-keys` (réutilise l'écran Admin) →
`settings-parity` → `read-only-mode` → `whats-new` → `app-utilities` → `share-extension` (nouvelle cible Xcode).

### Ce qui n'est PAS dans ce plan

- **Features fantômes** : « Cluster Groups » (référence §23) n'existe ni sur mobile ni sur web — ne pas l'implémenter (corrigé dans `docs/mobile-features-vs-flutter.md`).
- **Web uniquement côté upstream** (pas de parité à atteindre) : workflows d'automatisation, large-files, correction de géolocalisation, assistant de restauration, Immich+, raccourcis clavier, drag-and-drop upload, CLI.
- **Android uniquement** : VIEW intent, foreground service, Obtainium, empreintes de certificats de release.
- **Déjà au-delà de la parité** : Live Activity + Dynamic Island, 4 widgets + AppIntents/Spotlight, viewer public de lien partagé, résolution des doublons, panneau d'administration, RoadTrip, multi-comptes.


---

### 2.18. Batch parallèle du 2026-09-15 — les 25 features livrées

Les 25 fiches du plan des écarts ont été implémentées **en parallèle**, une branche
`feat/<slug>` par feature dans son propre worktree, par des sous-agents, l'orchestrateur
fusionnant et vérifiant. Quatre vagues (P2, P3, P4, P5), plus une migration ciblée
accordée en cours de route.

**Méthode, et ce qu'elle a coûté**

- Un sous-agent par feature, chacun dans `immich_swiftui.worktrees/<slug>`, avec un
  contrat commun écrit (`.omp/orchestration/BRIEF.md`) : carte AC = autorité, périmètre
  de fichiers, hunks additifs aux ancres nommées, i18n par fragment (jamais le
  `xcstrings` partagé), `project.pbxproj` jamais commité, pas de suite complète.
- Trois simulateurs de slot neufs et trois DerivedData, sérialisés par un sémaphore
  (`.omp/orchestration/verify.sh`) : 25 branches qui compilent en parallèle sur un seul
  poste, sans que deux `xcodebuild` se disputent le même appareil.
- Fusion des branches en `union` (driver `.gitattributes` temporaire, retiré depuis) :
  zéro conflit, au prix de **neuf sites de concaténation** là où deux branches touchaient
  la même ligne (init du conteneur, appel `ProfileView` dupliqué jusqu'à sept fois,
  accolades perdues) — tous rattrapés par la porte de compilation, aucun par la suite.
- Vérification : une **matrice AC** (`ac.py`) rejoue les 250 checks des 25 cartes sur
  l'arbre intégré, et la suite complète y tourne **deux fois** (simulateur du dépôt en
  allemand, slot neuf en anglais).

**Résultat**

| | |
|---|---|
| Features livrées | **25 / 25** (60/60 AC en P2, 40/40 en P3, 70/70 en P4, 80/80 en P5) |
| Checks AC sur l'arbre intégré | **250 / 250 PASS** |
| Suite | 886 → **1193 tests, TEST SUCCEEDED** (les deux environnements) |
| Catalogue | 648 → **1035 clés** (fr/de/es/it) |
| Fuite trouvée dans les cartes | 7 défauts, chacun prouvé et arbitré (voir ci-dessous) |

**Ce que le batch a trouvé en dehors des cartes**

1. **La baseline était rouge sur `main`** avant toute feature : 16 entrées mortes du
   catalogue (`%@ Photos`, `API Keys (%@)`…) que la garde `AppStringsTests` exigeait
   traduites, chacune ayant un jumeau `%lld` vivant — résidus de la migration des
   littéraux interpolés. Supprimées (diagnostic par extraction CLI `.stringsdata`).
2. **Sept défauts de carte**, tous de la même famille : une carte antérieure au code.
   - `AC-5045` : parenthèses non échappées dans un ERE — le motif ne pouvait pas correspondre.
   - `AC-5075` : mêmes parenthèses dans un BRE (`grep -A4`, sans `-E`) — le grep refusait le motif.
   - `AC-5081` : `routeDetectionEnabled`, que le SDK renomme `isRouteDetectionEnabled`.
   - `AC-5201` : littéral `"permissions": permissions` qu'aucun code qui compile ne peut écrire.
   - `AC-5171` : `struct` décorant un protocole `AnyObject` — interdit par le langage.
   - `AC-5244`/`AC-5246` : `DownloadInfoView`, déjà pris par `download-panel`.
   - `AC-5128`, `AC-5131`, `AC-5067`, `AC-5068` : **deux cartes se contredisaient** sur le
     contenu d'un même fichier partagé (et sur la sémantique de `clearSearch`). C'est la
     matrice AC qui les a fait apparaître — `ocr-text` et `star-ratings` étaient vertes,
     puis rouges à la fusion de `search-filters`.
3. **Une règle serveur qui invalidait une conception** : depuis la v3.2.0, `filter`,
   `orderBy` et `cursor` sont **mutuellement exclusifs** avec tous les champs plats
   dépréciés de `MetadataSearchDto` (`page` compris). `ocr-text` et `search-filters`
   émettaient donc des requêtes en 400. Migration livrée (branche `feat/search-shape`) :
   au-dessus de v3.2.0 le corps part en forme structurée (`filter` + `orderBy` +
   `cursor`, zéro champ plat), en dessous il reste plat ; la pagination suit la forme.

**Écarts assumés, à ne pas « réparer »**

- `chromecast` livre **AirPlay**, pas Google Cast (aucun paquet SPM officiel, pas de
  `Podfile`) : **G9 reste partiellement ouvert pour l'image fixe**, qu'AirPlay ne transporte pas.
- `locked-folder` : le PIN est **serveur**, l'élévation (`isElevated`) n'est exposée par
  aucun champ de session, mais elle se lit sur le serveur par `GET /api/auth/status` (`isElevated`) ;
  les deux routes `/auth/session/*` exigent un token de session (un compte par clé API reçoit un 400).
- `device-sessions` s'aligne sur `DeviceCard.svelte` (le client Flutter n'a rien) :
  `DELETE /api/sessions` ne supprime pas la session courante.
- `settings-parity` ajoute deux réglages sans équivalent upstream (densité 5/3/2, clé
  `searchGridDensity`) : convention neuve du dépôt, pas de la parité.


---

### 2.19. Vague XCUITest du 2026-09-15 — un scénario par carte

Décision utilisateur : **pas de conteneur Immich** (jugé trop lourd), **un scénario XCUITest
par carte**, AirPlay suffisant pour G9, retrait des réglages inventés, sonde
`GET /api/auth/status` après chaque action de l'écran des sessions, simulateurs conservés.

**Ce qui a été construit**

- `UITests/stubs/immich_stub_base.py` — socle de stub partagé (handshake OAuth, buckets,
  vignettes PNG réelles, `/__requests`, `/__whoami`) ; **25 stubs de feature** fins par-dessus.
- `UITests/Scenarios/` — **25 classes `XCTestCase`** (26 tests) dans leurs propres fichiers,
  une par carte, chacune pilotant l'app réelle contre **son** stub, avec assertions d'écran
  **et de fil** et un contrôle négatif obligatoire (casser la preuve, montrer l'échec, restaurer).
- `.omp/orchestration/uitest.sh` — le lanceur : un slot = un appareil + un port **tiré au sort**
  + une vérification d'identité `/__whoami` ; DerivedData **par worktree** ; flux
  `build-for-testing → install → grant Photos → seed des médias → test-without-building` ;
  **refus d'un scénario qui s'est « skipped »** (un scénario sauté ne prouve rien).
- `.omp/orchestration/run-scenarios.sh` — rejeu de **tous** les scénarios, avec la table des
  médias à semer par carte (sans elle, 5 scénarios échouent pour la mauvaise raison).

**Résultat sur l'arbre intégré**

| | |
|---|---|
| Scénarios XCUITest | **26 / 26 verts** (`passed`, aucun `skipped`) |
| Checks AC des 25 cartes | **250 / 250 PASS** |
| Suite unitaire | **1193 tests, TEST SUCCEEDED** (arbre propre) |

**Quatre défauts de production trouvés — qu'aucun test unitaire ne pouvait voir**

1. **Crash P0** : « Moi → Backup » tuait l'app. Les valeurs injectées par `.environment(_:)`
   sur la chaîne d'`AuthenticatedRoot` n'atteignent ni le contenu d'une feuille ni les écrans
   qu'elle pousse (celles injectées un cran plus haut, comme `auth`, y arrivent) : crash pour
   le seul lecteur non optionnel, et **perte silencieuse** des pastilles cloud pour les
   lecteurs optionnels. Corrigé en re-déclarant les six valeurs dans la feuille (`884aa6c`).
2. **Barre de progression morte** : `URLSessionFileDownloadTransport` n'appelait jamais
   `onProgress` — la variante *async* de `download(for:delegate:)` ne livre aucun callback de
   delegate (mesuré : 0 vs 15 `didWriteData`). Le panneau de téléchargement **et** le cache
   hors-ligne étaient figés. Corrigé par la feature download-panel (`61fba7d`).
3. **Pieds de `Section` tronqués** : un footer dont le ViewBuilder contient plusieurs vues
   n'en dessine et n'en publie que la **première**. Deux sites (hub, écran Backup) : les
   phrases qui expliquent l'interface n'existaient pas. Corrigé (`60b392e`).
4. **Mur de navigation** : dans une même pile, SwiftUI garde les destinations **par valeur
   sous** les destinations-vue — un `NavigationLink(value:)` ne s'affiche alors jamais. Le
   drill-down des **Dossiers** et des **Personnes** ne s'ouvrait pas (`07c24a2`, `af04ef0`).

**Pièges de harnais mesurés (à ne pas réapprendre)**

Un stub résiduel qui squatte un port fixe sert le scénario d'un autre (d'où port tiré au sort
et `/__whoami`) ; deux lanceurs avec des verrous différents se battent pour un appareil ;
le handler d'interruption **par défaut** d'XCUITest répond « Ajout uniquement » à l'alerte
Photos ; le libellé français porte une **apostrophe typographique** (U+2019) ; un appareil
effacé contient déjà **6 photos d'exemple** et `simctl addmedia` renomme les fichiers en DCIM ;
un `Toggle` de `Form` veut un tap à `dx = 0.9` ; la feuille « Moi » ne se ferme pas par un
drag partant de `dy = 0.06` et `navigationBars.firstMatch` y est la barre de la timeline
couverte ; `__pycache__` sous `UITests/stubs` devient une ressource du bundle au
`xcodegen generate`.

**Ce qui reste non prouvé (déclaré par les scénarios eux-mêmes)**

`chromecast` — la feuille ne s'ouvre pas dans un simulateur (aucune route AirPlay) : la
pastille désactivée, le tap inerte et le silence du fil sont prouvés, pas la sortie vers un
écran réel ; `download-panel` — l'annulation n'est pas tapée (état asserté seulement) et la
voie multi-assets n'est pas couverte ; `whats-new` — un `markSeen()` devenu no-op passerait
(l'écriture est couverte par les tests unitaires) ; `share-extension` — la feuille système est
pilotée et l'upload multipart prouvé au checksum près, mais contre un stub, pas un vrai serveur.

---

### 2.20. Marque de l'app — un mark propre, plus celui d'Apple (2026-09-16)

**Décision :** l'app dessine SA marque (`ImmichMark`), ni la silhouette d'Apple, ni la fleur
d'immich.

**Pourquoi.** Le mark précédent était un **traçage** de l'icône Swift d'Apple
(`developer.apple.com/assets/elements/icons/swiftui`, export 512 pt, 124 cubiques) et portait
son propre `NOTE FOR REVIEW`. Les textes sont sans ambiguïté : Apple interdit l'usage d'un de
ses symboles graphiques « on or in connection with … products … except pursuant to an express
written trademark license » (Guidelines for Using Apple Trademarks and Copyrights, Unauthorized
Use §2), et l'App Review le refuse — 2.3.9 (droits sur tous les matériaux de l'icône), 4.1(c)
(icône/marque d'un autre développeur), 5.2.1 (matériel protégé d'un tiers). Le mark était donc
un prototype, à remplacer avant toute soumission publique. Au passage, la fleur d'immich (le
vrai logo amont, `design/immich-logo.svg`) n'est pas un oiseau : c'est une fleur à cinq
pétales — la silhouette tracée n'était donc la marque de personne.

**Ce qu'elle est.** Une **lentille** vectorielle : bandeau de barillet (1,00 → 0,84) coupé en
cinq arcs, cinq fentes d'iris (largeur 0,06, une par anneau — l'air du jeu reste de l'air), et
une ouverture dont le **vide** est le motif de pétales (profil polaire, base 0,48, hauteur 0,16,
exposant 1,6, 240 échantillons, spline Catmull-Rom). Apparentée à immich — cinq, rotation,
photographie, et les cinq teintes de `LinearGradient.immichLogo` — sans être sa fleur. Tout est
formule (`ImmichMarkGeometry`, `Sources/DesignSystem/Components/ImmichMark.swift`) : pas de
données tracées, on retouche le mark en changeant des nombres, et le chemin est construit une
fois dans le cercle unité puis mappé au `rect`.

**Icône.** `Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` est régénérable :
`.omp/brand/render-icon.swift` (miroir des constantes ci-dessus) —
`swiftc -O .omp/brand/render-icon.swift -o /tmp/render-icon && /tmp/render-icon`. L'icône est
le seul support que le mark ne peut pas dessiner lui-même (une banque d'assets est un raster).

**Vérification (2026-09-16, slot français).** En situation : 40 pt (badge d'accueil) et 24 pt
(barre d'outils « On this device ») relus comme cinq pétales et cinq arcs, nets et délibérés.
Icône 1024 : **symétrie 5-fold IoU 0,994** à chaque pas de 72° (l'« asymétrie » perçue par un
relecteur d'image est une hallucination — la géométrie est exacte et mesurée), jeu
barillet/plaque vide à r = 0,815, ouverture vide jusqu'au centre. `LocalLibraryUITests` (un
scénario committé, donc un écran réel du dépôt) vert avec le nouveau mark ; suite 1193 tests
0 échec ; 250/250 checks AC.

**Méthode.** Six familles de candidats ont été rendues et mesurées avant le choix (rendu
CoreGraphics au même format que le `Shape`, colonnes 24/40/96 pt, métriques d'encre, d'épaisseur
minimale et de composants connexes) : leçon mesurée — les modèles de relecture d'image comptent
mal (fentes annoncées « trois » quand la mesure en donne cinq) et inventent des asymétries ; ce
sont les mesures (anneaux d'encre, IoU de rotation, écart de spline) qui tranchent, pas l'œil.

---

## Référence API — endpoints ImmichClient

### Endpoints déjà wire (existants)

| Méthode | Endpoint | ImmichClient | Usage |
|---------|----------|-------------|-------|
| GET | /api/timeline/bucket | getTimeBuckets() | Timeline, widgets |
| POST | /api/assets | uploadAsset() | Upload, offline |
| POST | /api/assets/bulk-upload-check | bulkUploadCheck() | Backup dedup |
| POST | /api/assets/:id | updateAsset() | Modify |
| DELETE | /api/assets/:id | deleteAsset() | Trash |
| POST | /api/auth/login | login() | Auth |
| POST | /api/auth/logout | logout() | Auth |
| POST | /api/oauth/authorize | authorizeOAuth() | OAuth2 |
| POST | /api/oauth/callback | exchangeOAuthCode() | OAuth2 |
| GET | /api/albums | getAlbums() | Albums |
| POST | /api/albums | createAlbum() | Albums |
| PATCH | /api/albums/:id | updateAlbum() | Albums |
| DELETE | /api/albums/:id | deleteAlbum() | Albums |
| GET | /api/users | getUsers() | Partners, shares |
| GET | /api/partners?direction= | getPartners(direction:) | Partners — `direction` (`shared-by`/`shared-with`) est **requis** (vérifié 2026-09-13) |
| PUT | /api/partners/:id | updatePartner() | Partners — **PUT**, et valide uniquement sur une ligne `shared-with` |
| DELETE | /api/partners/:id | removePartner() | Partners — valide uniquement sur une ligne `shared-by` |
| GET | /api/memories | getMemories() | Memories read |
| PUT | /api/memories/:id/assets | addAssetsToMemory() | Memories — **PUT** depuis le 2026-09-13 (un `POST` rend 404), corps `BulkIdsDto` (`{ids}`), réponse `BulkIdResponseDto` |
| PUT | /api/memories/:id | updateMemory() | Memories — **PUT** depuis le 2026-09-13 (un `PATCH` rend 404) |
| DELETE | /api/memories/:id | deleteMemory() | Memories — 204 |
| POST | /api/memories | createMemory() | Memories — `data:{year}` + `memoryAt` + `type` requis, pas de champ nom |
| GET | /api/memories/:id | getMemory() | Memories |
| GET | /api/memories/statistics | getMemoriesStatistics() | Memories — compte les lignes, sans le filtre « a des assets » de la liste |
| DELETE | /api/memories/:id/assets | removeAssetsFromMemory() | Memories — corps `BulkIdsDto`, réponse 200 (pas 204) |
| POST | /api/shared-links | createSharedLink() | Shared links |
| PATCH | /api/shared-links/:id | updateSharedLink() | Shared links — **PATCH** (le `PUT` envoyé jusqu'au 2026-09-13 rendait 404) |
| PUT | /api/shared-links/:id/assets | addAssetsToSharedLink() | Shared links — propriétaire, corps `AssetIdsDto`, type `INDIVIDUAL` seulement |
| DELETE | /api/shared-links/:id | deleteSharedLink() | Shared links |
| GET | /api/shared-links/me?key=\|slug= | getSharedLinkMine(_:) | **Visiteur** — 401 `"Password required"` tant que le cookie de login manque |
| POST | /api/shared-links/login?key=\|slug= | loginToSharedLink(_:password:) | **Visiteur** — réponse **201** + `Set-Cookie: immich_shared_link_token`, rejoué ensuite |
| POST | /api/search/metadata?key= | getSharedLinkAlbumAssets(_:albumId:page:size:) | **Visiteur** — `albumIds` **obligatoire** sous auth partagée |
| POST | /api/assets?key= | uploadAssetToSharedLink(...) | **Visiteur** — 401 nu si `allowUpload` est faux |
| GET | /api/stacks | searchStacks() | Stacks |
| POST | /api/stacks | createStack() | Stacks — **sert aussi à étendre une pile** (contrat de fusion, cf. §2.9) |
| GET | /api/stacks/:id | getStack() | Stacks |
| PUT | /api/stacks/:id | updateStack() | Stacks |
| DELETE | /api/stacks/:id | deleteStack() | Stacks |
| DELETE | /api/stacks/:id/assets/:assetId | removeAssetFromStack() | Stacks |
| GET | /api/assets/:id/original | downloadAsset() | Offline |

### Endpoints manquants vs Flutter

| # | Endpoint | Feature | Priority |
|---|----------|---------|----------|
| 1 | `POST /api/users/me/device-token` | Push Notifications | P5 |

Les deux lignes partenaires (1 et 2) étaient listées ici comme manquantes : elles sont **wire depuis le 2026-09-13** (§2.3).

**Champs manquants (pas des endpoints)** — `POST /api/assets` n'envoie ni `deviceAssetId` ni `deviceId` (`ImmichAPIClient.swift:480-491`). Corrigé par §2.13 ; prérequis de toute réconciliation par appareil.

**Endpoints fantômes retirés** — `POST /api/assets/:stackId/assets` était listé ici comme « addAssetToStack ». Il **n'existe pas** : l'OpenAPI publié ne l'expose ni sur `main` (7 opérations `stacks`) ni sur `v1.135.0` (6), et `server/src/controllers/stack.controller.ts` ne déclare aucun ajout de membre. Étendre une pile = `POST /api/stacks` avec la couverture **en tête** du payload (contrat de fusion — cf. §2.9). Trois autres routes fantômes sont retirées de la même façon le 2026-09-13 : `GET /api/shared-links/public/:slug`, `POST /api/shared-links/:slug/assets` et `POST /api/shared-links/:slug/check-password` n'existent ni dans `server/src/controllers/shared-link.controller.ts` ni dans l'OpenAPI publié (sha256 `bace1792…`) — l'équivalent réel est `GET /shared-links/me?key=…|?slug=…` pour la visite publique, `PUT /shared-links/{id}/assets` pour l'ajout par le propriétaire, `POST /shared-links/login` pour le mot de passe, et `POST /api/assets?key=…` pour l'upload invité (cf. §2.6 et la carte `shared-link-viewer`, issue #22). Corollaire de méthode : une route recopiée de mémoire dans un backlog finit par être crue ; chaque endpoint cité doit être adossé à l'OpenAPI du serveur.

---

## Checklists de vérification

### Checklist commune à TOUTES les features

- [ ] `xcodebuild build` réussit sans warning nouveau
- [ ] `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17'` — suite ≥ 805 tests (baseline mesurée le 2026-09-13)
- [ ] Mock dans `MockImmichClient` mis à jour
- [ ] `DependencyContainer` injecte le nouveau ViewModel
- [ ] `ProfileView` navigation mise à jour si feature ajoutée
- [ ] Test files nommés `*Tests.swift` avec `func test_` prefix
- [ ] No new warnings in `xcodebuild build` output

### Checklist par feature

**Backup Auto** : ✅ terminé (691 tests verts, 5 suites P2 livrées le 2026-09-10, cards `backup-engine`/`backup-live-activity` re-vérifiées le même jour). Suites : Live Photos §2.11, Album Scoping §2.12, Ledger Reconciliation §2.13, Network Policy §2.14, Library Observer §2.15 — chacune a sa card AC dans `.opencode/scratch/backup-*.acceptance.md` — ⚠ §2.12 **supprime** `excludeCameraRoll`/`excludeWhatsApp` : ne pas les greper comme critère de succès.
**OAuth2 UI** : ✅ terminé (692 tests verts, 8/8 AC PASS le 2026-09-10). Check : `grep -q "ASWebAuthenticationSession" Sources/Services/OAuthSessionPresenter.swift` ✓ — ⚠ la session vit dans le **service**, pas dans `AuthViewModel` (qui ne connaît que `oauthSessionHandler`) ; pas de `handleOAuthCallback`, pas d'`OAuthLoadingView`, pas d'`.onOpenURL` : ces surfaces ont été écartées par la conception, ne pas les « rétablir ».
**Partners UI** : Créer `PartnerShellViewModel.swift` + `PartnerShellView.swift` + `InvitePartnerSheet.swift`
**Memories Complete** : 7 nouvelles méthodes ImmichClient + `CreateMemorySheet.swift`
**Push Notifications** : 4 nouveaux fichiers (Service, Store, ViewModel, View) + 3 intégrations
**Shared Links Enriched** : 3 nouvelles méthodes + `ExternalLinkPreviewView.swift` + `UploadFromLinkView.swift`
**Offline Download** (P4) : ✅ terminé (831 tests verts, 13/13 AC PASS le 2026-09-13). Fichiers : `Sources/Services/OfflineAssetStore.swift` (actor, fichiers + `index.json` sous Application Support), `Sources/Services/ImageDownsampler.swift` (ImageIO), `Sources/Services/URLSessionFileDownloadTransport.swift` + `Sources/Core/Protocols/FileDownloadTransport.swift` (couture de téléchargement), `Sources/Features/Offline/{OfflineAssetIndex,OfflineDownloadViewModel,OfflineAssetsView}.swift` ; étage 0 `localFileURL` dans `AuthenticatedAsyncImage`, badge `offlineBadge` dans `AssetThumbnailCell`, section `OfflineSection` de `PhotoShareSheet`, ligne «Offline Storage» dans `ProfileView` (identifier `offlineStorageRow`), câblage `DependencyContainer`+`RootView`, 24 clés i18n EN+FR, `Tests/OfflineAssetStoreTests` (15) + `Tests/OfflineDownloadViewModelTests` (8), stub committé `UITests/stubs/immich_stub_offline.py` + `test_09_offlineDownload`. ⚠ Le cache vit sous **Application Support** (jamais `Caches`, purgeable) ; ⚠ **les tables de l'index et l'état de progression doivent rester OBSERVÉS** (`@ObservationIgnored` les invisibilise au `body` : le badge ne se rafraîchit plus) ; ⚠ `fileSizeInByte` est dans `exifInfo`, pas sur l'asset ; ⚠ le stub expose `/__network?down=1` — c'est ce qui prouve le rendu disque (le scénario exige 0 requête `offline: true`).
**Widgets** : 3 Widget + `WidgetDataProvider.swift` + ImmichWidgetsBundle
Stacks UI : ✅ terminé (724 tests verts, 12/12 AC PASS le 2026-09-13). Fichiers : `StacksViewModel.swift` + `StackView.swift` + `StackDetailView.swift` + `CreateStackSheet.swift` + `AddToStackSheet.swift` (`Sources/Features/Stacks/`) — la grille de sélection partagée vit désormais dans `Sources/Features/Timeline/AssetMultiSelectGrid.swift` (`StackPhotoPicker.swift` supprimé le 2026-09-13, cf. §2.4) ; `withStacked = true` dans `TimelineViewModel` + badge `+N` dans `AssetThumbnailCell` + routage du tap vers la pile dans `TimelineView` ; lien «Stacks» dans `ProfileView`. ⚠ `StackSheet` (PhotoViewer) est **inchangée** — elle faisait déjà couverture/membre/dissolution ; l'AC d'origine qui la visait était déjà PASS avant implémentation. ⚠ **Aucune route n'ajoute un asset à une pile** : `addPhotos` étend une pile en re-postant `POST /api/stacks` avec la couverture en tête (contrat de fusion), ce qui **change l'id de la pile** — l'écran doit suivre le nouvel id. ⚠ Le tap d'une grille de vignettes passe par `onTap:` d'`AssetThumbnailCell` : l'envelopper dans un `Button` **avale** le tap (défaut silencieux, invisible aux tests unitaires).
**i18n** : ✅ terminé (886 tests verts, 7/7 AC PASS le 2026-09-14). Fichiers : `Resources/Localizable.xcstrings` (629 clés, EN source + fr/de/es/it), `Sources/Features/Settings/{AppLanguage,AppLanguageStore,LanguageSettingsView,LanguageSettingsViewModel,LanguageToast}.swift`, `Sources/DesignSystem/AppDateFormat.swift`, ligne « Language » (section General) dans `ProfileView`, locale injectée par `RootView`, `let language` + `makeLanguageSettingsViewModel()` dans `DependencyContainer`, `Tests/{LocalizationTests,LocalizationTestSupport,AppStringsTests}.swift`, `test_11_languagePicker`. ⚠ L'extraction de chaînes tourne **en CLI** avec `SWIFT_EMIT_LOC_STRINGS=YES` (elle écrit des `.stringsdata` JSON et **ne touche pas** le catalogue) — c'est un build **Xcode** qui réécrit le catalogue et peut supprimer des clés valides ; ⚠ un littéral passé à une propriété `String` d'un composant n'est jamais extrait ni localisé (typer `LocalizedStringKey`) ; ⚠ un `LocalizedStringKey` vide devient la clé `""` ; ⚠ `accessibilityIdentifier` sur un conteneur écrase celui de ses descendants ; ⚠ `String(localized:locale:)` résout via la langue du **processus**, pas via `locale:` — les tests qui pinnaient l'anglais sont passés par `Tests/LocalizationTestSupport.swift`.
**Shared Link Viewer** (issue #22) : ✅ terminé (805 tests verts, 6/6 AC PASS le 2026-09-13). Fichiers : `SharedLinkViewerViewModel.swift` + `SharedLinkViewerView.swift` (`Sources/Features/SharedLinks/`), `sendSharedLinkRaw` + 4 méthodes visiteur dans `ImmichAPIClient`/`ImmichClient`, `SharedLinkCredential` + `SharedLinkLoginDto` (`DTOs+SharedLink.swift`), `SharedLinkURL.reference(from:)`. Stub committé `UITests/stubs/immich_stub_shared_link_viewer.py` + `test_SLV_viewer`. ⚠ Le chemin visiteur ne doit **jamais** passer par `sendAuthedRaw` (token requis) **ni** par `validate` (un 401 prévient `authDelegate` et déconnecte) ; ⚠ un lien ALBUM n'a pas d'`assets` dans son DTO — ses photos viennent de `POST /search/metadata` avec `albumIds` ; ⚠ ne pas « rétablir » `getSharedLinkPublic`/`checkSharedLinkPassword`/`uploadToSharedLink` : ces routes n'existent pas (AC-4004 les interdit).

---

*Généré depuis les specs .omp/ et les acceptance cards .opencode/scratch/ — 2026-09-08, mis à jour le 2026-09-14 : **i18n Completing** (P5, issue #21) ✅ clôturé — 7/7 AC PASS, 876 → **886 tests TEST SUCCEEDED**, `test_11_languagePicker` vert contre le stub **committé** `UITests/stubs/immich_stub_memories.py` (choix de langue → bandeau → relance → sélection conservée) (§2.10) ; le catalogue est passé de 442 à **629 clés en 5 langues** (EN source + fr/de/es/it) et le paysage réel était pire que la carte : l'onboarding était en **français en dur**, 204 clés réclamées par le code manquaient, 81 clés du catalogue étaient mortes ; l'audit se fait désormais par l'extraction CLI (`SWIFT_EMIT_LOC_STRINGS=YES` → `.stringsdata`, des JSON) qui **ne touche pas** le catalogue, contrairement à un build Xcode ; quatre pièges de clé corrigés au passage (littéral passé à une propriété `String` jamais localisé, `LocalizedStringKey` vide → clé ``, `accessibilityIdentifier` de conteneur qui écrase ses descendants, `String(localized:locale:)` qui suit le processus) ; **Widgets Home Screen** (P5, issue #19) ✅ clôturé — **confirmé sur appareil par l'utilisateur** (les trois widgets affichent les photos), 21/21 AC PASS, 837 → **876 tests TEST SUCCEEDED** (§2.8) ; **cause racine des widgets vides** : l'entrée de timeline portait les vignettes brutes du serveur (plusieurs Mo) et une entrée trop lourde **ne s'archive pas** — WidgetKit laisse alors le widget sur son placeholder redacté indéfiniment, sans photo ni message ni log côté extension, ce qui est invisible sur simulateur (le stub sert des PNG 8×8) — corrigé en ré-encodant les vignettes à la taille dessinée avec un budget de 256 Ko par entrée. Trois widgets data-driven (Photos, Souvenirs, Favoris) + familles Lock Screen, interactifs (`Button(intent:)`), avec prérequis non écrit dans le dépôt : un **Keychain partagé** câblé des deux côtés (`CODE_SIGN_ENTITLEMENTS` manquait, et un widget est un bundle distinct — sans groupe commun chaque fetch serait un 401) et le catalogue de traduction embarqué dans l'appex. Deux corrections de contrat : `GET /api/assets?isFavorite=true` n'existe pas (les favoris passent par `/api/timeline/buckets?isFavorite=true`), et `glassEffect`/`widgetURL`-par-cellule/configuration éditable ne s'appliquent pas à un widget. Compositions rasterisées et inspectées à l'œil — trois défauts visuels réels corrigés avant livraison. Reste non vérifié : le widget réellement posé sur l'écran d'accueil (aucune automatisation SpringBoard) ; **Notifications** (P5, issue #16) ✅ clôturé — 8/8 AC PASS, 831 → **837 tests TEST SUCCEEDED**, `test_10_notifications` vert 2× contre le stub **committé** `UITests/stubs/immich_stub_offline.py` (§2.5) ; le contrat annoncé (`POST /users/me/device-token`, APNs) était **fantôme** : 0 occurrence dans l'OpenAPI publié, aucun push dans le client Flutter — seule l'autorisation OS est livrée ; **Offline Download** (P4, issue #18) ✅ clôturé — 13/13 AC PASS, 805 → **831 tests TEST SUCCEEDED**, `test_09_offlineDownload` vert 3× contre le stub **committé** `UITests/stubs/immich_stub_offline.py` (§2.7) ; **Shared Link Viewer** ✅ clôturé (#22, 6/6 AC PASS, 772 → 805 tests, `test_SLV_viewer` vert deux fois de suite sur le stub **committé** `UITests/stubs/immich_stub_shared_link_viewer.py`) ; feature sans équivalent Flutter — contrat réel : `GET /shared-links/me?key=|slug=`, `POST /shared-links/login` (+ cookie), `POST /search/metadata` avec `albumIds`, `POST /assets?key=`) — **Memories Complete** ✅ clôturé (9/9 AC PASS, 749 → 772 tests, `test_08_memories` de bout en bout sur le stub **committé** `UITests/stubs/immich_stub_memories.py`) après révision du contrat serveur (`PUT` et non `PATCH` sur `/memories/{id}` ; `PUT`/`DELETE` et non `POST` sur `{id}/assets`, corps `BulkIdsDto`, réponse `BulkIdResponseDto` ; `MemoryType` mono-valeur — `first_day`/`yearly_recap` n'existent pas ; aucun champ titre dans l'API ; la liste filtre les mémoires sans asset, la création est `isSaved: true` pour échapper au ménage des 30 jours) — **Partners UI** ✅ clôturé (14/14 AC PASS, 724 → 736 tests, `test_06_partners` de bout en bout sur le premier stub **committé** du dépôt) après révision complète du contrat serveur (`direction` **requis** sur `GET /api/partners` — l'appel sans query rendait 400 au runtime ; création par `sharedWithId` et non par email ; `PUT`/`DELETE` valides chacun sur une seule direction ; rattachement au hub « Me ») — **Stacks UI** ✅ clôturé : 12/12 AC PASS, dont l'ajout de photos à une pile — **aucune route serveur ne l'expose**, le contrat réel est la fusion de `POST /api/stacks` : couverture en tête du payload et **id de pile neuf à suivre** ; carte AC réécrite sur la surface réelle + 3 scénarios XCUITest de bout en bout, et un tap de grille mort corrigé dans le picker partagé — baseline 695 → 724 tests. Précédemment : Backup Auto ✅ clôturé le 2026-09-10 avec ses 5 suites P2 ; OAuth2 UI ✅ clôturé le 2026-09-10, 8/8 AC PASS après réécriture de la carte/spec/UI brief sur la surface réelle et correction de la fuite de `isLoading`.*
