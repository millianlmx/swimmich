---
name: ui-review
description: Revue UI d'ImmichSwiftUI sur le simulateur avec session réelle — capture tous les écrans (onglets, lecteur, feuilles, hub Me) et signale les défauts visuels par heuristiques.
---

# Revue UI sur simulateur (captures de tous les écrans)

Tourne l'app **réelle** (pas les stubs) sur le simulateur qui porte la session
`demo.immich.app`, parcourt tous les écrans atteignables et capture une image +
un arbre d'accessibilité par étape, avec des heuristiques qui signalent les
défauts visibles sans qu'on ait à tout relire.

Utiliser ce skill quand la demande est « regarde l'app et dis-moi ce qui cloche »,
« revue UI », « vérifie visuellement », « capture les écrans », ou avant/après une
retouche d'UI pour comparer. **Ne pas** l'utiliser pour prouver un comportement
(assertions, contrat réseau, régression) : c'est le rôle du harnais XCUITest
(`.omp/orchestration/uitest.sh` + `UITests/Scenarios/*`), qui lui tourne contre
des stubs et échoue quand une assertion casse.

## Lancer

```bash
python3 .omp/skills/ui-review/scripts/tour.py                 # tout (~4 min)
python3 .omp/skills/ui-review/scripts/tour.py --mode quick    # l'essentiel (~1 min)
python3 .omp/skills/ui-review/scripts/tour.py --only viewer   # une section
python3 .omp/skills/ui-review/scripts/tour.py --out /tmp/revue-2026-11
```

Sections : `timeline`, `selection`, `menu`, `viewer`, `search`, `tabs`, `me`, `sync`.
Durée mesurée : ~2 min en `quick` (14 étapes), ~5-7 min en `full` (toutes les lignes
du hub « Me » incluses).

Sortie (défaut `/tmp/ui-review`) : `NN-<nom>.png` + `NN-<nom>.tree.json` par étape,
`index.md` (table des captures, alertes, nombre d'éléments AX) et `index.html`
(**planche unique avec toutes les captures** — c'est le fichier à ouvrir pour la
relecture visuelle, les étapes signalées y sont en rouge).

## Prérequis

- `idb` + `idb_companion` (`brew install idb-companion` puis `pip install fb-idb`) :
  `/opt/homebrew/bin/idb`. Le script démarre le companion lui-même, détaché.
- Un device **avec une session valide** : par défaut `01E517EC…` (iPhone 17, iOS 26.3)
  qui porte la session `demo.immich.app` (compte `demo@immich.app` / `demo`, 32 869
  photos, 52 vidéos). Le script ne fait ni `erase` ni `uninstall` : la session survit.
  Un autre device se passe par `--udid`.
- **La tournée se reconnecte seule** si la session est morte (l'instance de démo
  révoque ses sessions sans prévenir : mesuré le 2026-10-07, token → 401 en ~30 min).
  Elle rejoue l'onboarding (`Commencer` → le champ d'URL est déjà prérempli depuis
  `authServerURL` → `Vérifier la connexion` → `Continuer` → e-mail + mot de passe →
  `Connexion`) et affiche `session : session-ok | session-reouverte | login-echec`.
  Identifiants surchargeables par `--server/--email/--password`. Sur un échec, la
  tournée s'arrête avec `session-perdue` : connecte-toi une fois à la main, puis relance.
- L'app doit être installée. Pour installer un build neuf :
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project
  ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI -destination 'platform=iOS Simulator,id=<UDID>'
  -derivedDataPath /tmp/dd && xcrun simctl install <UDID> /tmp/dd/Build/Products/Debug-iphonesimulator/ImmichSwiftUI.app`
  (ne PAS lancer `xcodegen` dans le checkout principal — voir la mémoire du dépôt).

## Lire les alertes de `index.md`

| Alerte | Signification |
|---|---|
| `tap-sans-effet` | capture identique à l'étape précédente : le tap n'a rien déclenché (cible absente, contrôle inerte) |
| `ecran-vide` | ≤ 2 éléments d'accessibilité (ex. lecteur avec chrome masqué) |
| `texte-ecrase` | un texte dont le cadre fait < 20 pt : c'est ainsi que le titre du lecteur a été trouvé tronqué à 1 caractère |
| `attendu-absent` | l'élément attendu après l'action n'est pas là (navigation muette) |
| `alerte-modale` | une alerte était ouverte (son titre + son message sont recopiés dans l'index, puis elle est refermée pour que la tournée continue) |
| `menu-contextuel-ouvert` | le menu d'appui long était encore affiché à l'étape suivante |

Deux comportements connus au 2026-10-07 (ne pas les prendre pour des artefacts du
script) : `Une erreur est survenue / Network error: annulé` apparaît **à chaque
remontée en haut de la timeline** (le pull-to-refresh est annulé et le ViewModel
publie l'annulation comme une erreur — `TimelineViewModel` ne filtre pas
`URLError.cancelled`, `APIError.swift:19` formate le message brut), et l'appui
long sur une vignette ouvre le menu contextuel (Favori/Archiver/Déplacer/Supprimer).

## Pièges encodés dans le script (ne pas les « corriger »)

1. **Les items de toolbar SwiftUI n'existent pas dans l'arbre AX** sous iOS 26 (ni
   idb ni le MCP ne les voient ; XCUITest oui). Ils se tapent donc **par
   coordonnées** : ✕ de la sélection `(36, 84)`, Filtres `(181, 78)`, « Terminé »
   de la feuille Filtres `(336, 100)`, onglets `x = 40/120/200/280` et bulle
   Recherche `(360, 832)`, tous mesurés sur iPhone 17 (402 × 874 pt).
2. **Les gestes idb bloquent ~90 s** côté client (`swipe`, `drag-and-drop`) alors que
   la gestuelle est délivrée. Le script n'utilise que `tap` (+ `--duration` pour
   l'appui long) et `scroll up|down` : tout est instantané.
3. **Le companion idb meurt** s'il est lancé depuis un shell qui se termine, et il
   peut se wedger après un geste : le script le lance détaché et le relance à la
   première connexion refusée.
4. **Les vidéos `visibility:"hidden"` du serveur démo répondent 404 en vignette**
   (original et playback : 200). L'onglet Recherche filtré Vidéos montre donc des
   tuiles grises : c'est un défaut serveur, pas l'app — ne pas le compter comme un
   bug d'implémentation.
5. `simctl launch` sur une app déjà lancée ne la réinitialise pas : pour revenir
   « maison », il faut `terminate` puis `launch` (c'est ce que fait `launch_app()`).
6. **Les permissions sont pré-grantées** (`simctl privacy … grant photos photos-add`)
   au démarrage : sans ça, ouvrir les réglages de Sauvegarde déclenche la demande
   système « Autoriser l'accès complet », qui avale toutes les étapes suivantes
   (mesuré : 20 lignes du hub « Me » restées introuvables derrière la boîte).
   `dismiss_modals()` sait aussi l'accorder si elle apparaît malgré tout.
7. **Le clavier déplace la barre d'outils de Recherche** : champ focalisé, le
   segmented control remonte et un tap « Filtres » par coordonnées tombe dessus
   (l'écran bascule en Explorer). La section `search` tape donc « Fermer » pour
   quitter le champ avant de viser la barre.
8. Une feuille dont le seul bouton de fermeture est un item de toolbar (feuille de
   partage du lecteur) ne peut pas être fermée par identifiant : la section
   `viewer` repart d'un `launch_app()` après sa capture.
9. **`idb ui text` est inutilisable pour de la ponctuation sur ce poste** (hôte et
   simulateur en AZERTY, keycodes HID mappés QWERTY) : « https://demo.immich.app »
   devient « httpsM==de,o:i,,ich:qpp.app » et « demo@immich.app » devient
   « de,o@i,,ich.qpp » — `m`, `a`, `q`, `z`, `w` et toute la ponctuation sortent
   faux. `type_in_field()` presse donc les touches **affichées** du clavier virtuel
   (elles portent leur caractère en label ; le clavier e-mail expose `@` et `.`).
10. **La boîte système « Enregistrer le mot de passe ? » (iCloud Keychain) vide
   l'arbre d'accessibilité de l'app** (1 seul élément) : impossible de la trouver
   par label. `dismiss_password_prompt()` tape la position connue de « Plus tard »
   (134, 552) quand l'arbre est vide, et `ensure_session` la refuse après un login.

## Étendre la tournée

- Nouvel écran : ajouter une fonction `tour_xxx(d)` dans `scripts/tour.py` et
  l'appeler dans `main()` (gardée par `section(d, "xxx", only)`), puis un
  `d.step("nom", expect_id=...)`. Un `expect_id` faux est utile : il produit une
  alerte `attendu-absent` au lieu d'un silence.
- `d.step()` fait capture + arbre + heuristiques. `allow_same=True` pour les étapes
  où une capture identique est normale (ex. après un scroll qui ne bouge pas).
- Le hub « Me » est parcouru **génériquement** : toutes les lignes `*Row` trouvées
  dans l'arbre sont tapées, capturées, puis refermées (retour, sinon
  Fermer/Terminé, sinon relance de l'app). Une ligne neuve est donc couverte sans
  toucher au script ; `--rows-limit N` borne l'exploration.
- Comparer deux revues : `diff <(grep '^|' ancien/index.md) <(grep '^|' nouveau/index.md)`.
