import Foundation

/// Immich-flavored JSON helpers. Server emits ISO8601 with 3-digit fractional
/// seconds and a literal `Z` suffix (Node `Date.toISOString()`), e.g.
/// `"2024-07-01T12:34:56.000Z"`. TimeBucket strings are plain `YYYY-MM-DD`
/// (handled as plain strings, no Date decoding).
extension JSONEncoder {
    /// A NEW encoder on every read: `JSONEncoder` is a class, and a caller that
    /// tunes it (the offline index sets `.prettyPrinted`) must not reformat the
    /// request bodies of the whole app.
    static var immich: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .immichISO8601
        return e
    }
}

extension JSONDecoder {
    static let immich: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .immichISO8601
        return d
    }()
}

extension JSONEncoder.DateEncodingStrategy {
    static var immichISO8601: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.immichFormatter.string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var immichISO8601: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            // Try fractional-seconds format first; fall back to plain ISO8601.
            if let date = ISO8601.immichFormatter.date(from: s) { return date }
            if let date = ISO8601.fallbackFormatter.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(s)")
        }
    }
}

enum ISO8601 {
    /// `yyyy-MM-dd'T'HH:mm:ss.SSSZ` (GMT, 3 fractional digits, literal Z).
    static let immichFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    /// Tolerant fallback without fractional seconds.
    static let fallbackFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()
}

extension ImmichAPI {
    static let acceptJSON = "application/json"
}

extension MultipartBody {
    static func contentType(forBoundary boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }
}
