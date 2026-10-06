import Foundation

/// The one place a video duration becomes display text.
///
/// Two entries and no more, because the app holds durations from two clocks
/// that do NOT share a unit:
///
/// - Immich's DTOs (`TimeBucketAssetResponseDto`, `AssetResponseDto`) carry
///   `duration` in **milliseconds** — the grid badges, the viewer filmstrip and
///   the offline tiles all read that cell;
/// - AVFoundation's player clock (`AVPlayer.currentTime()`,
///   `asset.load(.duration)`) is in **seconds** — the transport labels and the
///   progress bar read that one.
///
/// Reading a millisecond cell as seconds is exactly the defect this type closes
/// (7173 ms rendered as "119:33"): each entry point names its unit, so no call
/// site has to decide, and under the hour both read the same "m:ss". Past the
/// hour the two surfaces keep their own precision: a tile badge, already
/// widened by an hour column, drops the seconds ("2:00"), while the playback
/// counter keeps them ("2:00:00") — a counter frozen on "2:00" would read as a
/// hang.
enum VideoDurationFormatter {
    /// "m:ss" from an Immich duration, in milliseconds, compacted to "h:mm"
    /// past the hour. 7173 → "0:07"; 7_200_000 → "2:00".
    static func string(milliseconds: Int) -> String {
        // The ONLY milliseconds→seconds conversion in the module.
        render(seconds: (Double(milliseconds) / 1000).rounded(), secondsPastTheHour: false)
    }

    /// "m:ss" from the player clock, in seconds, widened to "h:mm:ss" past the
    /// hour. 7.173 → "0:07"; 7200 → "2:00:00".
    static func string(seconds: Double) -> String {
        // NaN/±infinity: an indefinite media hands the player no duration, and
        // `Int(rounded())` traps on those.
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        // A finite Double can still sit past Int.max (a corrupt value) where the
        // conversion traps too; clamp so rendering can never crash playback.
        return render(seconds: min(seconds, Double(Int.max / 2)).rounded(), secondsPastTheHour: true)
    }

    /// The single rendering rule, inherited from the grid badge ("V11"):
    /// `m:ss` under the hour; past it `h:mm` — or `h:mm:ss` when the surface is
    /// the playback counter. Hours stay unbounded (596:xx renders, it never
    /// wraps into a day), seconds are always two digits.
    private static func render(seconds: Double, secondsPastTheHour: Bool) -> String {
        let whole = Int(seconds)
        guard whole > 0 else { return "0:00" }
        let minutes = whole / 60
        let secondsPart = whole % 60
        guard minutes >= 60 else {
            return "\(minutes):\(String(format: "%02d", secondsPart))"
        }
        // Interpolated hours and format-only minutes/seconds: `%d` with a Swift
        // `Int` reads 32 bits of the 64-bit vararg, which wraps the head column
        // once a duration passes Int32 of it.
        let hourPart = "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
        return secondsPastTheHour ? "\(hourPart):\(String(format: "%02d", secondsPart))" : hourPart
    }
}
