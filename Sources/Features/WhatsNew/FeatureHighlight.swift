import Foundation

/// One card of the "What's New" batch (gap G23).
///
/// The batch is **embedded**: the published API contract has no route and no DTO
/// for it, so the screen is complete offline. Upstream does the same — its
/// highlight list is a `const enum` in the app, not a server answer.
struct FeatureHighlight: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let body: String
    /// SF Symbol shown while the batch ships no screenshot. Upstream draws the
    /// same placeholder (`FeatureMessagePlaceholder`) when `image` is null.
    let systemImage: String
    /// Asset name of the screenshot, or `nil` while no asset is shipped — the
    /// field exists so a screenshot can be added without touching the view.
    let imageName: String?
}

enum FeatureHighlightCatalog {
    /// The release this batch was authored for. Content-defined, as upstream's
    /// release constant is: bump it only when publishing a new batch, never from
    /// the running app version (`MARKETING_VERSION` would re-present the sheet
    /// on every patch build).
    static let release = "3.0.0"

    /// The highlights visible on iOS, in presentation order. The batch's
    /// Android-only entry is deliberately not declared: a card here advertises a
    /// screen this app has, never one it will never show.
    static let all: [FeatureHighlight] = [
        FeatureHighlight(
            id: "shareQuality",
            title: String(localized: "Choose your share quality"),
            body: String(localized: "Press and hold the share button to choose the image quality before you share."),
            systemImage: "square.and.arrow.up",
            imageName: nil
        ),
        FeatureHighlight(
            id: "slideshow",
            title: String(localized: "Slideshow"),
            body: String(localized: "Sit back and watch your photos play in a full-screen slideshow."),
            systemImage: "play.rectangle",
            imageName: nil
        ),
        FeatureHighlight(
            id: "recentlyAdded",
            title: String(localized: "Recently added"),
            body: String(localized: "Jump straight to everything you've added lately on a dedicated page."),
            systemImage: "clock.arrow.circlepath",
            imageName: nil
        ),
        FeatureHighlight(
            id: "ocr",
            title: String(localized: "Search text in your photos"),
            body: String(localized: "Swimmich now searches the text inside your photos, so you can find them by what they say."),
            systemImage: "text.viewfinder",
            imageName: nil
        ),
        FeatureHighlight(
            id: "uploadToAlbum",
            title: String(localized: "Upload straight to an album"),
            body: String(localized: "For users that don't utilize the manual upload feature, you can now choose to add local photos directly into an album as you upload them, no need to upload then add to an album later anymore."),
            systemImage: "rectangle.stack.badge.plus",
            imageName: nil
        ),
    ]

    /// Whether `candidate` is a newer release than `seen`.
    ///
    /// Component-wise and **numeric**: a string comparison puts `"3.10.0"`
    /// *below* `"3.9.0"`, so the tenth minor release would never present its
    /// batch. Equal releases are not newer — that is what makes the sheet appear
    /// once per batch.
    static func isNewer(_ candidate: String, than seen: String) -> Bool {
        let lhs = candidate.components(separatedBy: ".").map { Int($0) ?? 0 }
        let rhs = seen.components(separatedBy: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
