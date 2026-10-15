# Task: sync-status

Status: planifié — **aucune AC ouverte** (écart G4 du registre `.omp/backlog/ImmichSwiftUI-backlog.md` §2.17).

## Plan (résumé)

**Objectif** : écran « Sync Status », agrégant l'état réel de la
synchronisation locale : compteurs du ledger, file du run courant, échecs, index hors-ligne, dernière
exécution, dernière confrontation serveur — plus les actions relancer / arrêter / confronter / réinitialiser
le suivi / purger le cache hors-ligne.

**Approche retenue** : A — un `SyncStatusViewModel` qui **compose** les deux ViewModels de processus déjà
existants (`UploadViewModel` pour le ledger et le moteur, `OfflineDownloadViewModel` pour l'index
hors-ligne), sans état propre, plus une vue stateless présentée en feuille depuis la racine authentifiée,
ouverte par un bouton de barre à côté de l'avatar de profil.

**Étapes** : (1) NEW `SyncStatusViewModel.swift` ; (2) NEW `SyncStatusView.swift` ; (3)
EDIT `DependencyContainer.swift` (`makeSyncStatusViewModel(upload:offline:)`) ; (4) EDIT `RootView.swift`
(`@State syncStatus` + clé d'environnement `openSyncStatus` + feuille `NavigationStack { SyncStatusView(vm:) }`) ; (5) EDIT les
cinq barres (les quatre onglets + l'overlay Photos) pour y poser `SyncStatusButton` ; (6) NEW
`Tests/SyncStatusViewModelTests.swift` (8 cas) ; (7) `xcodegen generate` + suite.

> **Révision du 2026-09-16** — le point d'entrée a quitté le hub « Me ». La ligne `syncStatusRow` de la
> section Management a été retirée : le hub porte déjà Backup, et un relevé du ledger deux lignes sous
> l'écran qui l'alimente se lisait comme la même fonctionnalité énoncée deux fois. L'écran s'ouvre
> désormais depuis `SyncStatusButton`, un bouton de barre à gauche de l'avatar de profil dans les quatre
> onglets à barre de navigation et dans l'overlay de l'onglet Photos. Conséquences : l'écran est présenté
> en feuille par `RootView` (il porte donc un bouton « Done », `syncStatusDone`), et l'anneau de
> progression du run, qui entourait l'avatar, entoure maintenant le bouton de synchronisation
> (`TimelineView.backupProgressRing`) — le bouton de profil ne porte plus aucun état de synchronisation.
> AC-5033 et AC-5034 sont réécrites ci-dessous ; les autres restent valides.

**Incertitudes** : libellé et icône exacts du bouton de barre (voir la révision : son `accessibilityLabel`
reste « Sync Status ») ; comportement de `refresh()` pendant un run
(voir `.omp/sync-status/sync-status.specs.md` § Incertitudes) ; profondeur du lien vers les échecs tant que
`upload-detail` (AC-5040–5049) n'existe pas.

## Critères

```
### AC-5030 [type: new]
Assertion: SyncStatusViewModel expose les projections du ledger/du run et les actions qui délèguent aux ViewModels existants (compteurs, hors-ligne, dates mises en forme, run/cancel/reconcile/reset/clear/refresh).
Check post-impl: sh -c 'f=Sources/Features/SyncStatus/SyncStatusViewModel.swift; test -f "$f" && grep -qE "var trackedCount" "$f" && grep -qE "var pendingCount" "$f" && grep -qE "var stagedCount" "$f" && grep -qE "var failedCount" "$f" && grep -qE "var offlineCount" "$f" && grep -qE "func formattedOfflineBytes" "$f" && grep -qE "func runNow" "$f" && grep -qE "func cancelRun" "$f" && grep -qE "func reconcileNow" "$f" && grep -qE "func resetLedger" "$f" && grep -qE "func clearOfflineCache" "$f" && grep -qE "func refresh" "$f" && echo PASS || echo FAIL'
Pre-state attendu: FAIL (fichier absent — `grep -rn "SyncStatus" Sources/` ne renvoie rien, aucun dossier `Sources/Features/SyncStatus`)
Post-state attendu: PASS
```

```
### AC-5031 [type: new]
Assertion: SyncStatusView est stateless, ne déclare AUCUN NavigationStack (elle est poussée par ProfileView) et rend les tuiles de statistiques.
Check post-impl: sh -c 'f=Sources/Features/SyncStatus/SyncStatusView.swift; test -f "$f" && grep -qE "struct SyncStatusView" "$f" && grep -qE "SyncStatusViewModel" "$f" && grep -qE "StatTile" "$f" && grep -qE "refreshable" "$f" && ! grep -qE "NavigationStack \{" "$f" && echo PASS || echo FAIL'
Pre-state attendu: FAIL (fichier absent)
Post-state attendu: PASS
Note: le check vise la DÉCLARATION (`NavigationStack {`) — un grep du seul mot échouerait sur le doc-comment qui explique justement l'absence de stack (piège de la carte stacks-ui).
```

```
### AC-5032 [type: new]
Assertion: l'écran est construit par le composition root (factory dans DependencyContainer) et non par la vue.
Check post-impl: sh -c 'f=Sources/DependencyContainer.swift; grep -qE "func makeSyncStatusViewModel" "$f" && grep -qE "SyncStatusViewModel\(upload:" "$f" && echo PASS || echo FAIL'
Pre-state attendu: FAIL (aucune factory SyncStatus)
Post-state attendu: PASS
```

```
### AC-5033 [type: new]
Assertion: RootView possède l'instance (un seul ViewModel pour toute la session, comme UploadViewModel/OfflineDownloadViewModel) et l'injecte dans la feuille qui présente SyncStatusView.
Check post-impl: sh -c 'f=Sources/RootView.swift; grep -qE "syncStatus: SyncStatusViewModel" "$f" && grep -qE "makeSyncStatusViewModel" "$f" && grep -qE "NavigationStack \{ SyncStatusView\(vm: syncStatus\) \}" "$f" && echo PASS || echo FAIL'
Pre-state attendu: FAIL
Post-state attendu: PASS
Note: l'assertion visait « la passe à ProfileView » avant la révision du 2026-09-16 ; le hub ne la reçoit plus, la feuille si.
```

```
### AC-5034 [type: new]
Assertion: l'écran s'ouvre depuis un bouton de barre à côté de l'avatar de profil — `SyncStatusButton` est déclaré dans RootView, posé dans les cinq surfaces qui portent l'avatar (quatre barres d'onglet + l'overlay Photos), la racine le câble à une feuille, et aucune ligne `Sync Status` ne subsiste dans le hub « Me ».
Check post-impl: sh -c 'g=Sources/RootView.swift; p=Sources/Features/Profile/ProfileView.swift; test "$(grep -rl "SyncStatusButton { openSyncStatus() }" Sources/Features | wc -l | tr -d " ")" -eq 5 && grep -qE "struct SyncStatusButton: View" "$g" && grep -qE "accessibilityIdentifier\(\"syncStatusButton\"\)" "$g" && grep -qE "openSyncStatus" "$g" && grep -qE "showSyncStatus" "$g" && ! grep -qE "syncStatusRow|SyncStatusView|SyncStatusViewModel" "$p" && echo PASS || echo FAIL'
Pre-state attendu: FAIL
Post-state attendu: PASS
Note: le check vise les CINQ surfaces (Albums, Memories, SharedLinks, Search, Timeline) : un bouton posé sur une seule barre laisserait quatre onglets sans point d'entrée. Le `!` sur ProfileView est la moitié load-bearing de la carte — c'est le retrait de la ligne du hub qui répond à la demande.
```

```
### AC-5035 [type: new — la composition ne recrée pas de moteur]
Assertion: l'écran ne construit ni ne stocke de `BackupEngine` ni d'`OfflineAssetStore` : il lit les ViewModels de processus (deux engines se disputeraient la Live Activity et afficheraient des compteurs faux).
Check post-impl: sh -c 'd=Sources/Features/SyncStatus; ! grep -qE "BackupEngine\(" "$d"/*.swift && ! grep -qE "OfflineAssetStore\(" "$d"/*.swift && grep -qE "private let upload: UploadViewModel" "$d/SyncStatusViewModel.swift" && grep -qE "private let offline: OfflineDownloadViewModel" "$d/SyncStatusViewModel.swift" && echo PASS || echo FAIL'
Pre-state attendu: FAIL (dossier absent)
Post-state attendu: PASS
```

```
### AC-5036 [type: new — aucune requête réseau propre à l'écran]
Assertion: le nouvel écran ne fait aucun appel réseau : l'état vient du ledger et de l'index, pas d'un endpoint (le contrat « sync » de l'OpenAPI est la réplication de la base locale Flutter, sans équivalent iOS).
Check post-impl: sh -c 'd=Sources/Features/SyncStatus; ! grep -qE "URLRequest|URLSession|ImmichClient" "$d"/*.swift && echo PASS || echo FAIL'
Pre-state attendu: FAIL (dossier absent)
Post-state attendu: PASS
```

```
### AC-5037 [type: new — les deux actions destructives sont confirmées]
Assertion: « Reset tracking » et « Purge offline cache » passent par une confirmation explicite avant d'agir.
Check post-impl: sh -c 'f=Sources/Features/SyncStatus/SyncStatusView.swift; n=$(grep -cE "confirmationDialog" "$f"); test "$n" -ge 2 && grep -qE "showResetLedgerConfirm" "$f" && grep -qE "showClearOfflineConfirm" "$f" && echo PASS || echo FAIL'
Pre-state attendu: FAIL (fichier absent)
Post-state attendu: PASS
```

```
### AC-5038 [type: new]
Assertion: SyncStatusViewModelTests expose ≥ 8 cas nommés couvrant les compteurs (ledger, file, hors-ligne), la dernière exécution, la dernière confrontation et la délégation des actions.
Check post-impl: sh -c 'f=Tests/SyncStatusViewModelTests.swift; test -f "$f" && n=$(grep -cE "func test_" "$f"); test "$n" -ge 8 && grep -qE "test_counters_mirrorEngineAndLedger" "$f" && grep -qE "test_lastRun_isTheMostRecentHistoryEntry" "$f" && grep -qE "test_offlineCount_andBytes_comeFromTheDownloadViewModel" "$f" && grep -qE "test_resetLedger_delegates" "$f" && echo PASS || echo FAIL'
Pre-state attendu: FAIL (fichier absent)
Post-state attendu: PASS
Note: un nouveau `Tests/*.swift` n'est compilé qu'après `xcodegen generate` — sans régénération la suite passe « verte » par omission.
```

```
### AC-5039 [type: regression]
Assertion: suite complète ≥ baseline mesurée avant implémentation (dernier relevé connu : 886 tests, `-only-testing:ImmichSwiftUITests`) et TEST SUCCEEDED.
Check post-impl: sh -c 'grep -qE "TEST SUCCEEDED" /tmp/immich_syncstatus_test.log && n=$(grep -oE "Executed [0-9]+ tests" /tmp/immich_syncstatus_test.log | grep -oE "[0-9]+" | sort -n | tail -1); test "$n" -ge 886 && echo PASS || echo FAIL'
Pre-state attendu: FAIL (log absent)
Post-state attendu: PASS
```
