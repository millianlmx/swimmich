# Swimmich — documentation index

Where to read what. Each user-facing document exists in English and French.

## Start here

| Doc | For | Content |
|---|---|---|
| [`../README.md`](../README.md) · [`../README.fr.md`](../README.fr.md) | Anyone | What Swimmich is and does: the library, the things you can make to share, backup, how to get the app |
| [`TECHNICAL.md`](TECHNICAL.md) · [`TECHNICAL.fr.md`](TECHNICAL.fr.md) | Contributors | How the app is built, tested and released: features by source folder, architecture, quick start, tests, CI, App Store release, contribution rules |
| [`../PRIVACY.md`](../PRIVACY.md) | Users | Privacy policy, also in [French](../PRIVACY.fr.md), [German](../PRIVACY.de.md), [Spanish](../PRIVACY.es.md) and [Italian](../PRIVACY.it.md) |

## Reference

| Doc | Content |
|---|---|
| [`mobile-features-vs-flutter.md`](mobile-features-vs-flutter.md) | The upstream Flutter client, the parity target |
| [`parity-registry-v3.4.0.md`](parity-registry-v3.4.0.md) | Gaps against the Immich mobile client v3.4.0 and the tracking of the batches |
| [`feature-parity-plan.md`](feature-parity-plan.md) | The Flutter parity plan |
| [`app-review-ats.txt`](app-review-ats.txt) | App Review justification (English, to paste into App Store Connect) for `NSAllowsArbitraryLoads` in the app, the widget and the Share Extension |
| [`../.omp/backlog/ImmichSwiftUI-backlog.md`](../.omp/backlog/ImmichSwiftUI-backlog.md) | Backlog: phases P0–P5, acceptance cards, missing endpoints |
| [`../.omp/<feature>/`](../.omp/) | Specs (`*.specs.md`), UI briefs (`*.ui.md`) and acceptance cards (`*.AC.md`) per feature |

## Media

| Folder | Content |
|---|---|
| `screenshots/` | The five README screenshots, taken over CC0 sample photos by `Scripts/screenshots.sh` |
| `showcase/` | The showcase pictures of the README, taken by `Scripts/showcase.sh` |
| `media/` | The demo video and its animated preview |
| `video/` | The Remotion project the demo video is cut with |
| `logo/` | The app icon sources |

## Where is the code?

The map of the source folders and the layers is in [Architecture](TECHNICAL.md#architecture); to build and run, follow the [Quick Start](TECHNICAL.md#quick-start).
