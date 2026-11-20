# Swimmich — index de la documentation

Deux points d'entrée à la racine du dépôt : [`../README.md`](../README.md) (ce que fait l'app, en anglais ; [`../README.fr.md`](../README.fr.md) en français) et la documentation technique ([`TECHNICAL.md`](TECHNICAL.md), [`TECHNICAL.fr.md`](TECHNICAL.fr.md)) : comment l'app est construite, testée et publiée.

## Documents

| Doc | Contenu |
| --- | --- |
| [`TECHNICAL.md`](TECHNICAL.md) · [`TECHNICAL.fr.md`](TECHNICAL.fr.md) | Fonctionnalités par dossier de `Sources/Features/`, architecture, fonctionnement, démarrage, tests, CI, release App Store, contribution |
| [`mobile-features-vs-flutter.md`](mobile-features-vs-flutter.md) | Référence du client Flutter upstream, objectif de parité |
| [`parity-registry-v3.4.0.md`](parity-registry-v3.4.0.md) | Registre des écarts avec le client mobile Immich v3.4.0 et suivi des lots (contrôlé par `Scripts/check-parity-registry.sh`) |
| [`feature-parity-plan.md`](feature-parity-plan.md) | Plan de parité Flutter : programme de cartes, terminé |
| [`app-review-ats.txt`](app-review-ats.txt) | Justification App Review (anglais, à coller dans App Store Connect) de `NSAllowsArbitraryLoads` dans l'app, le widget et la Share Extension |
| [`../.omp/backlog/ImmichSwiftUI-backlog.md`](../.omp/backlog/ImmichSwiftUI-backlog.md) | Backlog : phases P0–P5, cartes AC, endpoints manquants |

## Ressources du README

| Dossier | Contenu | Régénération |
| --- | --- | --- |
| `docs/showcase/` | images de la vitrine, prises sur un vrai serveur Immich | `Scripts/showcase.sh` |
| `docs/media/` | la vidéo `swimmich.mp4` et son aperçu animé | `docs/video/` (Remotion), voir [`TECHNICAL.md`](TECHNICAL.md#showcase-and-video) |
| `docs/screenshots/` | les cinq captures de la section Screenshots de la documentation technique, prises sur un stub local | `Scripts/screenshots.sh` |
| `docs/logo/` | l'icône de l'app en trois variantes | `docs/logo/generate.py` |

## Plan du code

Le détail est dans la section [Architecture](TECHNICAL.md#architecture) de la documentation technique ; en bref :

- `Sources/DesignSystem/` : `Tokens/` et `Components/`.
- `Sources/Core/` : `Types/` (DTOs), `Protocols/` (contrats d'injection), `Utilities/`.
- `Sources/Services/` : implémentations des protocoles (`ImmichAPIClient`, `BackupEngine`, `ImageCache`, `RealtimeService`…).
- `Sources/Features/` : un dossier par fonctionnalité, MVVM (`*ViewModel.swift` + `*View.swift`).
- `Sources/ImmichSharedKit/`, `ImmichWidgets/`, `ImmichShareExtension/` : framework partagé, widgets et Live Activity, extension de partage.
- `Sources/RootView.swift` et `Sources/DependencyContainer.swift` : routeur et composition root.

## Démarrage

```bash
xcodegen generate
open ImmichSwiftUI.xcodeproj
```

Choisir un simulateur iOS 26, puis ⌘R. Les tests et la CI : [`TECHNICAL.md`](TECHNICAL.md#tests).
