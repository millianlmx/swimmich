# Task: share-extension

> **Révision du 2026-09-16 — le groupe Keychain a été renommé.** Les trois entitlements (`ImmichSwiftUI`, `ImmichWidgets`,
> `ImmichShareExtension`) déclarent désormais `$(AppIdentifierPrefix)fr.millianlmx.swimmich` au lieu de
> `…fr.millianlmx.immich-ios`, et les trois `CFBundleDisplayName` valent `Swimmich`. Le groupe n'est donc plus dérivé d'un bundle id :
> c'est volontaire, il ne bougera plus si un bundle id change. Le mécanisme qui permet au code de ne citer aucun groupe est la règle
> Apple de `kSecAttrAccessGroup` (les groupes d'une app sont, dans l'ordre, ceux de l'entitlement puis son app ID ; une écriture sans
> groupe va dans le PREMIER) — conséquence à connaître : le groupe doit être autorisé par le profil (capacité Keychain Sharing) pour
> chacun des trois App IDs, sinon iOS refuse de lancer l'extension sans le dire. `WidgetExtensionProbe` le vérifie au lancement sur
> appareil. Le scénario `ShareExtensionUITests` a suivi : l'activité de la feuille de partage est matchée par le libellé `Swimmich`.

> **Audit 2026-09-15 — écart G21** : l'app ne peut rien recevoir depuis la feuille de partage d'iOS — `project.yml` ne déclare que 5 cibles
> (`ImmichSwiftUI`, `ImmichSharedKit`, `ImmichWidgets`, les deux bundles de tests) et **aucune** extension `com.apple.share-services`, alors qu'Immich
> Flutter embarque une cible `ShareExtension` ; preuve upstream : `mobile/ios/ShareExtension/Info.plist` @ `e55ac299` porte `NSExtensionPointIdentifier =
> com.apple.share-services`, une `NSExtensionActivationRule` (public.file-url / public.image / public.movie / public.url) et `AppGroupId =
> $(CUSTOM_GROUP_ID)` — et son `ShareViewController.swift` est réduit à `class ShareViewController: ShareHandlerIosViewController {}` (plugin
> `share_handler` du `pubspec.yaml`), tout l'upload étant fait côté Dart par `mobile/lib/pages/share_intent/share_intent.page.dart` +
> `share_intent_upload.provider.dart` (route `ShareIntentRoute`).

**Objectif** : l'utilisateur sélectionne une ou plusieurs photos/vidéos dans Photos, Messages ou Safari, choisit « Immich » dans la feuille de partage,
et une extension système s'ouvre avec une liste des pièces jointes sélectionnables, un sélecteur d'album, et un bouton Upload qui affiche l'état de
chaque envoi (en file / en cours avec pourcentage / terminé / échec). Les fichiers sont envoyés au serveur Immich de l'utilisateur depuis le processus
de l'extension (`POST /api/assets`), puis rattachés à l'album choisi ; aucune donnée ne transite par l'app (elle peut être fermée).

**Hors périmètre** :
- Aucun écran dans l'app : rien n'est ajouté à `RootView`/`DependencyContainer` en tant que destination de navigation, donc pas de `NavigationStack` à
  déclarer (les vues poussées depuis le hub « Me » n'en déclarent pas non plus).
- Pas de bouton « Partager depuis Immich » (sortie), ni de partage vers d'autres apps : uniquement l'entrée.
- Pas de `bulkUploadCheck` préalable (le serveur répond déjà `status: duplicate` sur `POST /api/assets`) ni de reprise après interruption/relance de
  l'extension.
- Pas d'App Group et pas de handoff App↔app : l'upload se fait dans le processus de l'extension, qui stage ses fichiers dans son propre conteneur ; la
  **seule** ressource partagée avec l'app reste l'item Keychain décrit plus bas (voir « Incertitudes » pour le cas vidéo volumineuse).
- Pas de parité avec `ShareIntentRoute` en tant que route Dart : l'extension est native SwiftUI/UIKit, le plugin `share_handler` n'est pas importé.

**Hypothèses** (vérifiées dans le dépôt et contre `immich-app/immich@main` @ `e55ac299`, le 2026-09-15) :
- `project.yml:91-113` — la cible d'extension existe déjà comme modèle : `ImmichWidgets`, `type: app-extension`,
  `info.properties.NSExtension.NSExtensionPointIdentifier: com.apple.widgetkit-extension`, `CODE_SIGN_ENTITLEMENTS:
  Resources/ImmichWidgets.entitlements`, `dependencies: - target: ImmichSharedKit` / `embed: true`. `project.yml:114-142` (scheme) ne build que
  `ImmichSwiftUI` + `ImmichWidgets` : une cible non listée n'est pas construite.
- `project.yml:17-24` — l'app compile **tout** `Sources/` en une seule entrée (`- path: Sources`) ; c'est ce qui explique que `Sources/ImmichSharedKit/`
  soit compilée deux fois (cible app + framework) et qu'un fichier déplacé sous `Sources/ImmichSharedKit/` reste compilé par l'app sans toucher sa liste
  de sources.
- `Sources/ImmichSharedKit/WidgetSession.swift:5-18` — `WidgetSession` (`baseURL`, `token`, `userName`, `userId`, `trustedHosts`) est déjà le véhicule
  inter-processus app → extension ; `:54-60` documente le mécanisme exact réutilisé ici : aucun `kSecAttrAccessGroup` n'est passé, l'item tombe dans le
  groupe par défaut du processus, qui est le groupe dérivé de l'App ID listé dans les deux entitlements — donc l'extension lira ce que l'app écrit.
  `:62-110` `WidgetSessionStore` (service `app.immich.swiftui.widget`, compte `session`, accessibilité `afterFirstUnlockThisDeviceOnly`) est `public`.
- `Sources/ImmichSharedKit/WidgetDataProvider.swift:170-172` — `public static func interactive(sessionStore:) -> URLSession` construit déjà une session
  configurée pour un processus *hors app* (délégué de confiance pour un serveur à certificat auto-signé, échéances courtes) : c'est le transport à
  réutiliser, sans quoi un Immich en HTTPS auto-signé échoue à chaque requête depuis l'extension, exactement comme dans le widget.
- `Sources/Services/MultipartBody.swift:1-19` — `struct MultipartBody` (internal) expose `writeStreamed(fileField:fields:to:)`, qui recopie le fichier
  **par blocs de 1 Mio** depuis le disque (« Never holds the file in memory ») : c'est ce qui rend l'upload d'une vidéo tenable dans une extension à
  budget mémoire réduit, et c'est la raison du déplacement en étape 4 plutôt que d'une réécriture.
- `Sources/Services/ImmichAPIClient.swift:630-671` —
  `uploadAsset(fileURL:fileCreatedAt:fileModifiedAt:filename:duration:isFavorite:visibility:livePhotoVideoId:checksum:deviceAssetId:deviceId:)` poste le
  multipart sur `ImmichAPI.assets.path("")` avec le Bearer posé à la main et `ImmichHeader.checksum` ; `:331-343` prouve qu'un upload sans
  `isFavorite`/`visibility`/`livePhotoVideoId` est accepté (c'est le jeu de champs du chemin lien partagé, livré et testé) ; `:206-208` `getAlbums()` →
  `GET /api/albums` ; `:226-228` `addAssetsToAlbum(albumId:dto:)` → `PUT /api/albums/{id}/assets` avec `BulkIdsDto` (`{ids}`). OpenAPI `main`
  (`/tmp/immich-openapi-main.json`, `info.version = 3.2.0`) : `AssetMediaResponseDto = {id, status}`, `AssetMediaStatus.enum = created, duplicate`.
- `Sources/Core/Protocols/ImmichClient.swift:10-12` — `protocol ImmichClient: AnyObject, Sendable` et son `configure(baseURL:token:)` vivent dans la
  cible **app** ; `Sources/DependencyContainer.swift:2,88` est son unique racine de composition (`buildWidgetDependencies` y injecte
  `WidgetSessionStore()`). L'extension ne verra donc ni `ImmichClient`, ni `DependencyContainer`, ni `DeviceIdentity`, ni les `*Dto` de
  `Sources/Core/Types` : elle a besoin de sa propre couture et la fiche doit la placer dans `ImmichSharedKit`.
- `Sources/Features/Auth/AuthViewModel.swift:152-163` — `publishWidgetSession()` est le site unique qui écrit `WidgetSession(...)` dans le Keychain
  (appelé après login, switch de compte, restauration). `Sources/Services/DeviceIdentity.swift:20-33` — `DeviceIdentity.current` est l'identifiant
  stable d'installation ; il est `internal` et lu dans `UserDefaults.standard` de l'app, **illisible** depuis le conteneur de l'extension : c'est
  pourquoi il doit voyager dans `WidgetSession` (le commentaire `ImmichAPIClient.swift:260-262` rappelle que `deviceAssetId` + `deviceId` servent au
  filtrage par appareil côté web, donc un second id rendrait les imports du partage méconnaissables).
- `Tests/ImmichAPIClientTests.swift:112` — le harnais `CapturingURLProtocol.lastRequest` est le patron de test transport déjà en place pour les uploads
  multipart (assertions sur les `name="…"` du corps).
- Contrainte de compilation déjà payée (`Sources/ImmichSharedKit/` compilée deux fois) : un test ne fait **jamais** `import ImmichSharedKit` — il
  atteint les symboles du kit via `@testable import ImmichSwiftUI` seul, sinon chaque symbole devient ambigu.

**Approche retenue** : A — une **cible d'extension native** `ImmichShareExtension` (`NSExtensionPointIdentifier = com.apple.share-services`, classe
principale `ShareViewController`), dont le transport et le modèle de session sont ajoutés à `ImmichSharedKit` afin d'être partagés et testables, et qui
uploade elle-même depuis son processus avec la session lue dans le Keychain.
- **B (rejetée)** : faire dépendre l'extension des fichiers de la cible app pour réutiliser `ImmichAPIClient`/`DependencyContainer` → impossible sans
  réécrire `project.yml` : la cible app déclare `sources: - path: Sources` (l.20), donc « réutiliser la couche service » veut dire compiler dans une
  extension à budget mémoire serré l'ensemble `Sources/Features/**` (BackupEngine, Live Activities, SocketIO, la photothèque) ; mesurable :
  `ImmichWidgets` ne dépend que d'`ImmichSharedKit` pour cette exacte raison (`project.yml:111-113`), et aucune extension de ce dépôt ne compile
  `Sources/Core/Types`.
- **C (rejetée)** : reproduire le modèle Flutter — l'extension se contente de déposer les fichiers dans un conteneur partagé et rend la main à l'app,
  qui uploade avec son moteur foreground (c'est littéralement l'architecture upstream : `ShareViewController` = `ShareHandlerIosViewController` vide, la
  page Dart `ShareIntentRoute` fait l'upload) → rejetée parce qu'elle exige (1) un écran d'attente **dans l'app**, alors que la surface fixée est «
  extension + son écran de confirmation, aucun écran dans l'app », (2) un chemin d'ouverture app→extension (`UIApplication.open` interdit depuis une
  extension : seul `extensionContext.open` existe, et il n'est pas disponible pour `com.apple.share-services`), et (3) une autorisation Photos +
  `BackupEngine` pour des fichiers qui ne sont pas dans la photothèque de l'appareil.

## Étapes

1. **Entitlements de l'extension** — NEW `Resources/ImmichShareExtension.entitlements` : unique clé `keychain-access-groups =
   ["$(AppIdentifierPrefix)fr.millianlmx.swimmich"]` (valeur du 2026-09-16 ; elle était `…fr.millianlmx.immich-ios` à la livraison), copie de
   `Resources/ImmichWidgets.entitlements`. Fichier sans commentaire (Xcode le re-sérialise
   au build et échoue si son entrée a changé — commentaire déjà présent dans `project.yml` côté cible app).
2. **Info.plist de l'extension** — NEW `ImmichShareExtension/Info.plist` : `CFBundleDisplayName: Swimmich` (`Immich` à la livraison, renommé le
   2026-09-16 — c'est ce libellé que Photos affiche dans sa feuille de partage), `CFBundleShortVersionString`/`CFBundleVersion`
   sur `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` (comme `ImmichWidgets`, project.yml:95-99), `NSAppTransportSecurity.NSAllowsArbitraryLoads:
   true` (un Immich auto-hébergé est souvent en HTTP simple sur le LAN ; le loopback est exempt d'ATS, donc rien ne le détecte en test simulateur), puis
   `NSExtension` = `NSExtensionPointIdentifier: com.apple.share-services`, `NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ShareViewController`,
   `NSExtensionAttributes.PHSupportedMediaTypes: [Image, Video]`, et la même `NSExtensionActivationRule` `SUBQUERY` sur `public.image`/`public.movie`
   que l'upstream (`mobile/ios/ShareExtension/Info.plist`), sans storyboard.
3. **Cible Xcode** — EDIT `project.yml` : ajouter le bloc `ImmichShareExtension` (`type: app-extension`, `platform: iOS`, `sources:
   [ImmichShareExtension]` + `Resources/Localizable.xcstrings` en resources comme pour le widget, `info.path: ImmichShareExtension/Info.plist`, settings
   `PRODUCT_BUNDLE_IDENTIFIER: fr.millianlmx.immich-ios.share-extension`, `DEVELOPMENT_TEAM: 2MJF39L8VY`, `INFOPLIST_FILE`, `CODE_SIGN_ENTITLEMENTS:
   Resources/ImmichShareExtension.entitlements`, `dependencies: [- target: ImmichSharedKit, embed: true]`) ; dans la cible app (l.66-72) ajouter `-
   target: ImmichShareExtension` / `embed: true` à côté d'`ImmichWidgets` ; dans `schemes.ImmichSwiftUI.build.targets` ajouter `ImmichShareExtension:
   all`.
4. **Multipart partagé** — NEW `Sources/ImmichSharedKit/MultipartBody.swift` : **déplacement** de `Sources/Services/MultipartBody.swift` (l'ancien
   fichier est supprimé), plus passage en `public` de `struct MultipartBody`, `init(boundary:)`, `append(name:value:)`,
   `append(name:filename:contentType:data:)`, `encoded()`, `totalLength`, `writeStreamed(fileField:fields:to:)`, `var contentType`. Aucun appelant de
   l'app ne change : `ImmichAPIClient.swift` résout sa copie interne exactement comme aujourd'hui (le fichier reste sous `Sources/`).
5. **Couture de session** — EDIT `Sources/ImmichSharedKit/WidgetSession.swift` : ajouter `public var deviceId: String?` à `WidgetSession` et un
   paramètre `deviceId: String? = nil` à son `init` — optionnel pour la même raison que `trustedHosts` (commentaire l.23-26 : une session écrite par un
   build antérieur doit continuer à décoder).
6. **Écriture côté app** — EDIT `Sources/Features/Auth/AuthViewModel.swift` : dans `publishWidgetSession()` (l.152-163), passer `deviceId:
   DeviceIdentity.current` à la construction de `WidgetSession(...)`.
7. **Client d'upload partagé** — NEW `Sources/ImmichSharedKit/SharedUploadClient.swift` : (a) `public protocol ShareUploading: Sendable { func
   upload(fileURL:filename:createdAt:modifiedAt:duration:deviceAssetId:) async throws -> SharedUploadResult ; func albums() async throws -> [ShareAlbum]
   }` ; (b) `public struct SharedUploadResult: Decodable, Sendable { public let id: String ; public let status: String }` (décodage de
   `AssetMediaResponseDto`, `status ∈ {created, duplicate}`) ; (c) `public struct ShareAlbum: Decodable, Sendable, Identifiable { public let id: String
   ; public let albumName: String }` ; (d) `public struct SharedUploadClient: ShareUploading` prenant `baseURL: String`, `token: String`, `deviceId:
   String`, `session: URLSession` (défaut `WidgetDataProvider.interactive()`), et `public enum ShareUploadError: Error { case invalidServerURL,
   transport(Int), server(Int, String), unreadableFile }`. `upload` construit le corps avec `MultipartBody.writeStreamed` (`fileField: ("assetData",
   filename, "application/octet-stream", fileURL)`, `fields:` `fileCreatedAt`, `fileModifiedAt`, `deviceAssetId`, `deviceId`, `isFavorite=false`,
   `duration` si non nil), écrit un `POST {baseURL}/api/assets`, en-têtes `Content-Type: multipart/form-data; boundary=…`, `Authorization: Bearer
   {token}` et `x-immich-checksum: {sha1 base64}` (CryptoKit `Insecure.SHA1`), upload via `URLSession.uploadTask(with:fromFile:)` puis supprime le corps
   temporaire dans un `defer` ; `albums()` fait `GET /api/albums` et mappe `[ShareAlbum]`.
8. **Rattachement à l'album** — NEW (même fichier que l'étape 7) : `func addAssets(_ ids: [String], toAlbum albumId: String) async throws` sur
   `ShareUploading`, sérialisé en `{"ids": [...]}` (`BulkIdsDto`), `PUT {baseURL}/api/albums/{albumId}/assets`, Bearer, réponse `[BulkIdResponseDto]`
   ignorée. Appelé par le ViewModel après que **tous** les items sont `complete` ou `failed`, uniquement si un album est sélectionné.
9. **Modèle d'un partage** — NEW `ImmichShareExtension/ShareItem.swift` : `struct ShareItem: Identifiable, Sendable` (`id: UUID`, `filename`, `fileURL`
   (copie stagée), `isVideo: Bool`, `byteCount: Int`, `createdAt: Date`, `status: ShareItemStatus`) et `enum ShareItemStatus: Equatable { case enqueued,
   running(Double), complete(assetId: String), failed(String) }` — miroir exact des états de l'`UploadStatusIcon` de `share_intent.page.dart`
   (`enqueued`, `running`+`progress`, `complete`, `failed`).
10. **ViewModel de l'extension** — NEW `ImmichShareExtension/ShareExtensionViewModel.swift` : `@Observable @MainActor final class
    ShareExtensionViewModel`, `init(uploader: any ShareUploading, stage: URL, serverLabel: String)` ; API `var items: [ShareItem]`, `var albums:
    [ShareAlbum]`, `var selectedAlbumId: String?`, `var serverLabel: String`, `var isUploading: Bool`, `var errorMessage: String?`, `var canUpload:
    Bool` (au moins un item sélectionné et pas en cours), `func setItems(_:)`, `func toggle(_:)`, `func loadAlbums()`, `func uploadAll()`. `uploadAll`
    boucle les items sélectionnés, publie `running(0)` puis `complete(assetId:)`/`failed(message:)`, puis appelle `addAssets` si `selectedAlbumId !=
    nil`. Le ViewModel est **le seul** à connaître `ShareUploading` : la vue ne fait que projeter (`project.yml` ne liste aucun `DependencyContainer`
    ici — la racine de composition est l'étape 12).
11. **Écran de confirmation** — NEW `ImmichShareExtension/ShareConfirmationView.swift` : vues SwiftUI stateless prenant le ViewModel en
    `@Bindable`/paramètre — en-tête (nombre d'items + `serverLabel` sous le titre, comme `upload_to_immich(count:)` + endpoint de
    `share_intent.page.dart`), `List` de lignes (vignette `UIImage` pour une image, icône `video` sinon ; nom ; taille ; indicateur d'état :
    `checkmark.circle` gris non sélectionné, `clock` en file, `ProgressView(value:)` + pourcentage en cours, `checkmark.circle.fill` vert terminé,
    `exclamationmark.triangle` rouge en échec), `Picker` d'album (« Aucun album » = `selectedAlbumId = nil`), bouton principal « Upload » désactivé
    quand `!canUpload` et affichant « {n}/{total} » pendant l'envoi, bandeau d'erreur sur `errorMessage`. Palette/tokens du `DesignSystem` de l'app,
    aucune logique métier dans les vues.
12. **Contrôleur de l'extension** — NEW `ImmichShareExtension/ShareViewController.swift` : `final class ShareViewController: UIViewController`,
    `override func viewDidLoad()` lit `extensionContext?.inputItems` → `NSExtensionItem.attachments`, retient les `NSItemProvider` conformes à
    `UTType.image`/`UTType.movie`, appelle `loadFileRepresentation(forTypeIdentifier:)` et **copie** chaque fichier dans
    `FileManager.default.temporaryDirectory.appendingPathComponent(UUID())` pendant que le conteneur de l'app hôte est encore lisible, construit
    `WidgetSessionStore().load()` → `SharedUploadClient(...)`, puis installe un `UIHostingController(rootView: ShareConfirmationView(viewModel:))` ;
    bouton « Annuler » → `extensionContext?.cancelRequest(withError:)`, fin de traitement → `completeRequest(returningItems: nil)`. Aucune session
    trouvée (utilisateur déconnecté) ⇒ écran d'erreur « Connectez-vous à Immich » + `cancelRequest`.
13. **Tests du kit** — NEW `Tests/ShareUploadClientTests.swift` (`@testable import ImmichSwiftUI`, **jamais** `import ImmichSharedKit`) : avec
    `CapturingURLProtocol` (patron `Tests/ImmichAPIClientTests.swift:112`) — (a) le corps multipart contient `name="assetData"` + les quatre champs et
    l'en-tête `Authorization` porte le token ; (b) `x-immich-checksum` vaut le SHA1 base64 attendu ; (c) `{"id":"a1","status":"duplicate"}` se décode ;
    (d) un 401 lève `ShareUploadError.server(401, _)`. NEW `Tests/ShareExtensionViewModelTests.swift` avec un double `ShareUploading` : l'ordre des
    états (`enqueued → running → complete`) et `addAssets` **non appelé** sans album sélectionné, appelé avec les ids des items réussis quand un album
    est choisi.
14. **Vérification bout en bout** — `xcodegen generate` (des fichiers et une cible ont été ajoutés) puis `xcodebuild test -scheme ImmichSwiftUI
    -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ImmichSwiftUITests`, et vérification manuelle sur **appareil** : partager une
    photo depuis Photos → l'extension apparaît → choisir un album → Upload → asset visible dans l'album, puis contrôler que le partage d'une vidéo et
    d'un partage multi-items fonctionne ; le piège de provisionnement du groupe Keychain est invisible sur simulateur, donc l'essai appareil est la
    seule preuve acceptable (même enseignement que le groupe Keychain du widget).

## Incertitudes à lever à l'implémentation

- **Capacité « Keychain Sharing » de l'App ID de l'extension** : sans elle, iOS refuse de lancer le processus de l'extension (symptôme : rien ne se
  passe à l'ouverture du partage, aucun log) et c'est invisible sur simulateur. Trancher avant tout : `security cms -D -i
  <chemin>/embedded.mobileprovision | plutil -extract Entitlements xml1 -o - - | grep -A3 keychain-access-groups` sur un build appareil, et enregistrer
  la capacité sur les deux App IDs dans le portail.
- **Champ du nom d'album** : `AlbumResponseDto` porte-t-il bien `albumName` (et non `name`) ? Trancher : `jq -r
  '.components.schemas.AlbumResponseDto.properties|keys_unsorted' /tmp/immich-openapi-main.json`.
- **Upload sans `isFavorite`/`visibility`** : le chemin lien partagé l'omet (`ImmichAPIClient.swift:331-343`) mais l'app les envoie pour l'upload
  propriétaire. Trancher : poster un upload sans ces deux champs contre un serveur auto-hébergé (`curl -X POST -H "Authorization: Bearer $T" -F
  fileCreatedAt=… -F fileModifiedAt=… -F deviceAssetId=x -F deviceId=y -F assetData=@photo.jpg "$URL/api/assets"`).
- **Vidéo volumineuse vs budget d'extension** : aucune reprise n'est prévue (hors périmètre) ; si une vidéo de plusieurs Go dépasse la fenêtre de vie de
  l'extension, la seule issue propre est un `URLSessionConfiguration.background(withIdentifier:)` partagé avec l'app (donc un App Group +
  `handleEventsForBackgroundURLSession` côté app, à ouvrir comme une fiche fille). Trancher en mesurant : `log stream --predicate 'process CONTAINS
  "ShareExtension"'` pendant un partage de vidéo de 1 Go sur appareil.
- **Taille de la liste d'items** : iOS limite le nombre de pièces jointes et la mémoire d'une extension ; si un partage de 30 photos échoue, plafonner
  l'acceptation dans `ShareViewController` (refus explicite plutôt qu'OOM silencieux). Trancher en partageant 30 photos depuis Photos sur appareil.
- **`duration` pour les vidéos** : la valeur attendue par le serveur (secondes entières, arrondi) n'est pas documentée ; lire
  `AVURLAsset.load(.duration)` et vérifier dans l'UI web que la vignette vidéo affiche la bonne durée. Trancher : upload d'une vidéo de 12 s puis
  lecture de `duration` via `GET /api/assets/{id}`.

