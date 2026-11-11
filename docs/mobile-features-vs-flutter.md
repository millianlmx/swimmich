# Features du client mobile Flutter Immich (upstream)

Sources : `docs/docs/features/` + `mobile/lib/routing/router.dart` + GitHub releases v3.2.0
Date de référence : 2026-09-08
Révisé le 2026-09-15 contre `main` @ `e55ac299` (release v3.2.1) : cinq erreurs factuelles
corrigées (§3 ordonnanceur Android, §4 casting + OCR, §6 filtre OCR, §13 note par
étoiles, §20 réglages proxy/SSL/préférences, §23 feature fantôme « Cluster Groups »).
Revérifié le 2026-11-11 contre v3.4.0 (cible de parité). Registre courant des écarts :
`docs/parity-registry-v3.4.0.md` (il remplace `.omp/backlog/ImmichSwiftUI-backlog.md` §2.17, v3.2.1).

---

## 1. Authentification & Session

- Connexion par URL du serveur + email / mot de passe
- Changement de mot de passe (route `ChangePassword`)
- Local auth (Face ID / PIN) — `LockedGuard`
- Session persistante via `SecureStorageService`
- Déconnexion multi-appareils
- Gestion des appareils connectés (user settings)
- Rotation de clés API

## 2. Navigation Principale

Quatre onglets dans `TabShell` :

| Onglet | Route | Contenu |
|--------|-------|---------|
| Timeline | `MainTimelineRoute` | Vue chronologique principale |
| Recherche | `SearchRoute` | Recherche plein écran |
| Bibliothèque | `LibraryRoute` | Albums, dossiers, partenaires, liens partagés |
| Albums | `AlbumsRoute` | Liste tous les albums (locaux + distants) |

## 3. Backup / Synchronisation

- Sélection des albums à sauvegarder (`backup_album_selection.page.dart`)
- Exclusion d'albums spécifiques (double-tap)
- Détection automatique des nouveaux clichés (push / polling)
- Upload en arrière-plan :
  - iOS : `Background App Refresh` (géré par le système)
  - Android : `worker_manager` (ordonnanceur natif `BackgroundWorkerService` + `wm_executor.dart`), contrôle fin (seulement en charge, délai min)
- Conditions réseau configurables : Wi-Fi uniquement par défaut, mobile data possible
- Seulement en charge (Android)
- Délai minimum configurable entre prise et upload background (Android)
- Détection de doublons par checksum de contenu (évite re-upload)
- Backup au lancement et à la reprise de l'app
- Upload sélectionné manuellement depuis "On this device"
- Backup album synchronization (sync one-way device → server)
- Backfill existant via "Reorganize into album"
- Suivi de progression dans `upload_detail.page.dart`
- Gestion des erreurs réseau avec retry

## 4. Consultation de Média

- `AssetViewer` plein écran avec pager swipe
- Pinch-to-zoom + double-tap zoom
- Filmstrip en bas pour navigation rapide
- Lecture vidéo avec contrôles (`video.page.dart`)
- Support formats image : HEIC, HEIF, AVIF, JPEG, PNG, RAW, BMP, WEBP, GIF, SVG, TIFF, JP2, MPO, PSD
- Support formats vidéo : MP4, MOV, MKV, AVI, FLV, M4V, WebM, WMV, 3GP, M2TS
- Exif affiché dans les détails
- Indicateur de statut cloud (cloud icon sur tuile : syncé vs local uniquement)
- Slideshow (`slideshow.page.dart`)
- Overlay OCR du texte présent dans l'image (`ocr_overlay.widget.dart`, `ocr_toggle_button.widget.dart`) — présent sur mobile
- Casting Google Cast / Chromecast (`presentation/actions/cast.action.dart`, `widgets/asset_viewer/cast_dialog.dart`, `services/gcast.service.dart`, `NSBonjourServices _googlecast._tcp`) — présent sur mobile **et** web

## 5. Édition Photos Mobile

- Recadrage (crop) — `edit.page.dart`
- Rotation
- Miroir (flip)
- Édition non destructive (version séparée, original conservé)
- Téléchargement de la version édité ou de l'original

## 6. Recherche Mobile

- `SearchRoute` — recherche visuelle plein écran
- Recherche par reconnaissance contextuelle CLIP (ML)
- Recherche par visages (`People`)
- Recherche par lieu (geo / reverse geocoding GeoNames)
- Recherche par tags
- Recherche par dates (time frame)
- Recherche par type média (image / vidéo / les deux)
- Filtres avancés : archive, favorite, album, camera
- Recherche OCR (texte dans images)
- Recherche par nom de fichier / extension
- Recherche par dossier / chemin complet
- Recherche par description
- Recherche par star rating
- Recherche par make / model / lens model
- Recherche par texte détecté (OCR) — filtre `ocr` (`domain/services/ocr.service.dart`, `search_filter/`)
- Filtre d'affichage de résultats (colonnes, tri) — `search_filter/display_option_picker.dart`

## 7. Albums

- Créer des albums distants (`create_album.page.dart`)
- Sélection d'utilisateurs (`UserSelectionRoute`)
- Éditer titre / description d'un album
- Supprimer des assets d'un album
- Albums partagés (view / edit roles : éditeurs ou viewers)
- Albums distants (`RemoteAlbum`)
- Albums locaux (`LocalAlbum`)
- Sélection multiple d'assets pour ajout à album
- Options album (`album_options.page.dart`)

## 8. Partenaires (Partner Sharing)

- Partage de bibliothèque entière avec d'autres utilisateurs
- Vue des assets partenaires (`partner.page.dart`, `partner_detail.page.dart`)
- Toggle "Show in timeline" par partenaire
- Les partenaires voient archives, trash, metadata GPS
- Partage **one-way** (l'autre doit aussi partager)
- Risque de doublons dans la timeline principale
- Pas de partage des albums partenaires, favorites, ou données de reconnaissance faciale

## 9. Partage Public

- Créer un lien public pour un asset individuel
- Créer un lien public pour un album
- Options du lien : expiration, mot de passe, permissions
- Vue des liens partagés (`SharedLinkRoute`)
- Édition du lien (`SharedLinkEditRoute`)
- Upload depuis un lien public
- URL secrète aléatoire

## 10. Reconnaissance Faciale

- Détection de visages automatique (ML model)
- Regroupement en personnes (`PeopleCollectionRoute`, `PersonRoute`)
- Attribuer un nom à une personne
- Photo de visage par défaut (featured photo)
- Cacher des personnes de la vue Explore / timeline
- Date de naissance → affichage âge sur la photo
- Fusionner des personnes (`Person` merge)
- Favoriter une personne (pin en haut de la liste)
- Visages affichés dans le détail de l'asset
- Réexécution de la reconnaissance faciale
- Configuration ML : modèle, score min détection, distance max recognition, min recognized faces

## 11. Mémoires (Memories)

- "Jours comme il y a X" (this day memories)
- Page dédiée des mémoires (`MemoryListRoute`)
- Favoriter une mémoire (ne se supprime pas)
- Visionnage individuel (`MemoryRoute`)
- Vidéos dans les mémoires

## 12. Carte / Map

- Affichage des assets sur carte OpenStreetMap (`MapRoute`, Maplibre GL)
- Compte d'assets dans la vue carte (v3.2.0+)
- Géolocalisation reverse GeoNames
- Affichage des villes, états, pays dans les détails
- `MapLocationPickerRoute` — localisation précise

## 13. Favoris & Tri

- Marquer / démarquer comme favori (`FavoriteRoute`)
- Archive / désarchive (`ArchiveRoute`)
- Corbeille (`TrashRoute`) — restoration et suppression permanente
- Star rating utilisateur (1-5 étoiles)
- Récents (`RecentlyTakenRoute`)
- Récemment ajoutés (`RecentlyAddedRoute`)
- Stacking de photos / vidéos similaires (trié par date de création)
- Note par étoiles 1–5, éditable depuis le viewer (`rating_bar.widget.dart`) et affichée dans les détails (`asset_details/rating_details.widget.dart`)

## 14. Dossiers (Folder View)

- Vue arborescente type explorateur de fichiers (`FolderRoute`)
- Navigation par dossiers
- Visible pour les libraries externes
- Toggle dans Account Settings > Features > Folders

## 15. Tags

- Créer / assigner des tags aux assets
- Tags hiérarchiques
- Lecture des tags existants (XMP `TagsList`, IPTC `Keywords`)
- Écriture des tags dans sidecar XMP
- Vue tags dédiée

## 16. Dossiers Verrouillés (Locked Folder)

- Dossier verrouillé séparé (`LockedFolderRoute`)
- Authentification par PIN / Local Auth (`PinAuthRoute`, `LockedGuard`)
- Assets exclus de la timeline principale
- Accès sécurisé

## 17. Library Locale ("On this device")

- Vue des albums locaux (`LocalAlbumsRoute`)
- Upload de photos sélectionnées depuis le device
- Sync avec les albums distants
- Backup des albums WhatsApp exclus par défaut dans "Free Up Space"
- Stock indicator sur les tuiles (paramètre Settings > Photo Grid)

## 18. Free Up Space

- Supprimer les photos déjà sauvegardées du device
- Date limite configurable (cutoff date)
- Conserver les favoris
- Conserver des albums spécifiques
- "Always keep photos" / "Always keep videos"
- Écran de revue avant suppression (`CleanupPreviewRoute`)
- Suppression par lots vers la corbeille système (2000 Android, 10000 iOS)
- Exclusion automatique des iCloud Shared Albums (iOS)
- Compatibilité WhatsApp (Keep albums)
- Assets supprimés accessible depuis l'app Immich

## 19. Mode Lecture Seule / Kid Mode

- Empêcher la suppression de photos
- Seule la vue timeline est active
- Activation : long-press sur icône profil ou `Settings > Advanced > Read-only Mode`

## 20. Paramètres (Settings)

- Afficher l'indicateur de stockage sur les tuiles
- Options de backup (réseau, charge, délai)
- Photo grid settings
- Read-only mode toggle
- Settings avancés (`SettingsSubRoute`)
- Stats de l'account (usage)
- Gestion des appareils connectés
- Gestion des clés API
- Toggle features (tags, folders)
- Profil (photo, nom, email, crop `ProfilePictureCropRoute`)
- Configuration HTTP headers (`HeaderSettingsRoute`)
- Langues
- En-têtes proxy personnalisés (`custom_proxy_headers_settings/`) et certificat client SSL (`ssl_client_cert_settings.dart`)
- Préférences : thème, couleur primaire, retour haptique, comportement de partage (`preference_settings/`)
- Écran « Quoi de neuf » (`presentation/pages/feature_message/whats_new.page.dart`)

## 21. Système / Intégration

- Share intent (partage vers Immich depuis d'autres apps — `ShareIntentRoute`)
- Widget iOS (Memories widget)
- Deep linking
- Gestion des permissions (camera, photos, location)
- AppLock (Face ID / Touch ID pour rouvrir l'app)
- Background App Refresh (iOS — `General > Background App Refresh`)
- Background work manager (Android)
- Battery optimization Android (don't kill my app)
- Support Obtainium (Android)
- Certificats SHA-256 : Google Play, GitHub releases, F-Droid

## 22. Assets Partagés

- Voir les assets d'autres utilisateurs
- Stacking synchronisé via websocket
- Affichage du propriétaire dans les détails (v3.2.0+)
- Résolution des assets possédés par un partenaire identique (v3.2.0+)

## 23. Cluster Groups — ❌ feature fantôme (vérifié 2026-09-15)

La version précédente de cette section décrivait des « groupes d'utilisateurs pour
clustering facial croisé » et un reset de reconnaissance par groupe. Vérification sur
`main` @ `e55ac299` : aucune occurrence `cluster` dans `mobile/lib`, aucune route, aucun
écran. Le mot « cluster » n'apparaît dans la documentation upstream que pour l'algorithme
DBSCAN qui regroupe les visages en personnes
(`docs/docs/features/facial-recognition.md`) — c'est le comportement normal de la
reconnaissance faciale, pas une fonctionnalité de groupes d'utilisateurs.

**À ne pas implémenter** : la cible de parité ne contient aucune feature de ce nom.

## 24. Multi-sélection

- Sélection multiple d'assets dans la timeline
- Sélection multiple dans la recherche
- Sélection multiple dans les albums
- Actions batch : favorite, archive, trash, delete, add to album
- Indicateur du nombre sélectionné

## 25. Admin / Utilitaire Mobile

- Logs de l'app (`AppLogRoute`, `AppLogDetailRoute`)
- Asset troubleshoot (`AssetTroubleshootRoute`)
- Download info (`DownloadInfoRoute`)
- Media stats dev (`MediaStatRoute`)
- Status de synchronisation (`SyncStatusRoute`)
- Widgets iOS / Android

## 26. Fonctions Communes Web & Mobile

- Stacking de photos similaires
- Duplicates utility (résolution via checksum ML) — **web uniquement** : aucun chemin `mobile/lib/**` ne touche aux doublons en v3.4.0. Swimmich offre les doublons au-delà de la parité (`Sources/Features/Duplicates/DuplicatesView.swift`)
- Workflow automations (tags trigger, actions) — **web uniquement** : 0 occurrence `workflow` dans `mobile/lib`
- Tag renaming (renommer les tags, v3.2.0+) — **web uniquement** (PR #27909) : `mobile/lib/data/server/tag.dart@v3.4.0` n'a que `bulkTagAssets`, `untagAssets`, `getAll` et `upsert`
- XMP sidecar (lecture + écriture metadata) — **serveur uniquement** : 0 occurrence `xmp` dans `mobile/lib`, aucune UI mobile
- External library support (scan, exclusion patterns)
- Reverse geocoding GeoNames
- Support XMP sidecars : Lightroom, Darktable, digiKam

---

## Fonctions Desktop Unique (PAS sur mobile)

| Fonction | Détail |
|----------|--------|
| Duplicates utility desktop | Page de résolution complète |
| Admin panel | Users, libraries, settings |
| CLI | Command line interface |
| Hardware transcoding config | Config server-side |
| View assets in map viewport | Web seulement (v3.2.0+) |
| External library management | Web admin only |

## Gaps Identifiés dans le client mobile

Les endpoints listés comme "gap" dans le code :

| Gap | Endpoint | État |
|-----|----------|------|
| gap #1 | Stacks | ✅ couvert — `searchStacks/createStack/getStack/updateStack/deleteStack/removeAssetFromStack` (`ImmichClient.swift`), UI Stacks livrée 2026-09-13 |
| gap #2 | Tags (admin) | ✅ couvert — `getAllTags/createTag/updateTag/deleteTag/tagAssets/untagAssets`, UI Tags |
| gap #5 | Faces API | ✅ couvert — `getFaces/reassignFace/mergePeople/updatePerson/getPersonStatistics`, UI People |
| gap #12 | Admin API | ✅ couvert — `getAdminUsers/createAdminUser/updateAdminUser/deleteAdminUser/restoreAdminUser/getJobsStatus/sendJobCommand/getLibraries/scanLibrary/deleteLibrary`, UI Admin (`Sources/Features/Admin/AdminView.swift`) ; `getAPIKeys/createAPIKey/deleteAPIKey`, UI Clés API (`Sources/Features/UserApiKeys/UserApiKeysView.swift`, ouverte à tout compte depuis le hub « Me ») |
