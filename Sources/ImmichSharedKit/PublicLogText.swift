import Foundation

/// The only description of an error the app, its widgets and its share
/// extension may publish with `privacy: .public` in `os.Logger` (need B-15).
///
/// `localizedDescription` and `String(describing:)` print free text: a
/// `URLError` quotes the failing URL (host, port, sub-path, `?key=`), a server
/// error carries the response body. Here only the **shape** of the error comes
/// out — its type, its case, its numeric code — never a string a producer wrote:
///
/// - `URLError` → `URLError -1004`;
/// - an enum → `Type.case`, with the integers and the nested errors of its
///   associated values (`APIError.network(URLError -1004)`); every other
///   associated value (string, URL, data, decoding context) is dropped;
/// - an enum that prints itself (`CustomStringConvertible`), whose text may be
///   free, and any other error → `<domain> <code>`.
public enum PublicLogText {
    /// How deep nested errors are followed before `…`.
    private static let maxDepth = 4

    public static func describe(_ error: Error) -> String {
        describe(error, depth: 0)
    }

    private static func describe(_ error: Error, depth: Int) -> String {
        if depth >= maxDepth { return "…" }
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue)"
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "URLError \(ns.code)"
        }
        let mirror = Mirror(reflecting: error)
        let selfPrinting = error is CustomStringConvertible || error is CustomDebugStringConvertible
        guard mirror.displayStyle == .enum, !selfPrinting else {
            return "\(ns.domain) \(ns.code)"
        }
        let type = String(describing: Swift.type(of: error))
        guard let first = mirror.children.first else {
            // A case without a payload prints only its own name.
            return "\(type).\(String(describing: error))"
        }
        let label = first.label ?? "?"
        let kept = payload(first.value, depth: depth + 1)
        return kept.isEmpty ? "\(type).\(label)" : "\(type).\(label)(\(kept.joined(separator: ", ")))"
    }

    /// The parts of an associated value that are safe to print: integers and
    /// errors, in order. A tuple contributes each of its elements.
    private static func payload(_ value: Any, depth: Int) -> [String] {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .tuple:
            return mirror.children.flatMap { payload($0.value, depth: depth) }
        case .optional:
            guard let wrapped = mirror.children.first else { return [] }
            return payload(wrapped.value, depth: depth)
        default:
            break
        }
        if let integer = value as? any BinaryInteger {
            return ["\(integer)"]
        }
        if let error = value as? Error {
            return [describe(error, depth: depth)]
        }
        return []
    }
}
