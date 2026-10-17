# immich_swiftui — documentation index

Le point d'entrée est le [README](../README.md) à la racine : présentation du projet, motivations, architecture, fonctionnement, démarrage et contribution.

## Documents

| Doc | Contenu |
| --- | --- |
| [`../README.md`](../README.md) | Entrée canonique : projet, architecture, build, tests, contribution |
| [`mobile-features-vs-flutter.md`](mobile-features-vs-flutter.md) | Référence du client Flutter upstream — objectif de parité |
| [`feature-parity-plan.md`](feature-parity-plan.md) | Plan de parité Flutter |
| [`app-review-ats.txt`](app-review-ats.txt) | Justification App Review (anglais, à coller dans App Store Connect) de `NSAllowsArbitraryLoads` dans l'app, le widget et la Share Extension |
| [`../.omp/backlog/ImmichSwiftUI-backlog.md`](../.omp/backlog/ImmichSwiftUI-backlog.md) | Backlog : phases P0–P5, cartes AC, endpoints manquants |
| [`../.omp/<feature>/`](../.omp/) | Specs (`*.specs.md`), briefs UI (`*.ui.md`) et cartes d'acceptance (`*.AC.md`) par feature |

## Code map (résumé)

- `Sources/DesignSystem/` — tokens (`Tokens/`, couleurs canoniques dans `Tokens/ImmichColors.swift`) + composants (`Components/`).
- `Sources/Core/` — `Types/` (DTOs), `Protocols/` (contrats d'injection), `Utilities/`.
- `Sources/Services/` — `ImmichAPIClient`, `BackupEngine`, `ImageCache`, `AuthenticatedAsyncImage`, `RealtimeService`, …
- `Sources/Features/` — un dossier par feature, MVVM (`*ViewModel.swift` + `*View.swift`).
- `Sources/ImmichSharedKit/` + `ImmichWidgets/` — framework partagé et extension widget (Live Activity).
- `Sources/RootView.swift` + `Sources/DependencyContainer.swift` — routeur auth-gated et composition root.

Détails dans le [README](../README.md#architecture).

## Quick start

```bash
xcodegen generate        # régénère ImmichSwiftUI.xcodeproj depuis project.yml
open ImmichSwiftUI.xcodeproj
# choisir un simulateur, ⌘R
```
