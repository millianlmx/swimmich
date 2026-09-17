# Task: timeline-thumbhash

> **Technical Specification**: Decoding and rendering ThumbHash image placeholders on the photo library timeline grid while full thumbnails are loading.

**Goal**: Display a visually accurate preview (true colors, aspect ratio, and image structure) as soon as photo grid cells appear on the homescreen timeline, derived from the `thumbhash` field provided by the Immich server, with a smooth crossfade into the high-resolution thumbnail once loaded.

**Context & Problem**:
- Immich server provides a `thumbhash` (compact binary representation encoded in Base64) for each asset.
- Previously, `AssetThumbnailCell` ignored this field and `AuthenticatedAsyncImage` only rendered a generic `ShimmerPlaceholder` while waiting for the network download, resulting in blank tiles during slower network loads.
- Native photo apps (Apple Photos, official Immich client) show an instant blurred color/structure placeholder the moment a cell enters the viewport.

**Scope**:
- Dedicated native crash-safe ThumbHash decoder (`Sources/Services/ThumbHashDecoder.swift`) implementing Evan Wallace's algorithm (DCT LPQA $\rightarrow$ RGB) with strict bounds validation.
- In-memory `NSCache<NSString, UIImage>` for instant $O(1)$ synchronous cache hits during fast 60/120 fps grid scrolling.
- Integration into `AuthenticatedAsyncImage` via an optional `thumbhash: String? = nil` parameter with `.transition(.opacity)`.
- Forwarding `asset.thumbhash` from `AssetThumbnailCell`.
- Comprehensive unit test coverage in `Tests/ThumbHashDecoderTests.swift`.

**Architecture & Constraints**:
- Service Layer: `ThumbHashDecoder` is `@unchecked Sendable`, thread-safe, and auto-evicts under memory pressure via `NSCache`.
- Non-blocking UI: Uncached decoding tasks run on cooperative detached tasks (`Task.detached(priority: .userInitiated)`).
- Robustness: Tolerates empty, corrupted, or truncated strings gracefully without `fatalError` or crashes (returns `nil`).
- Design System: Strictly adheres to tokens (`PVMotion.gentle`, `Color.bgTertiary`, `Color.textSecondaryPV`).
