import Foundation
import os

/// Checks the one link of the widget chain that a simulator can never fail: the
/// widget extension reads what the app writes into the shared keychain, which
/// requires its App ID to be *authorised* for that group by the provisioning
/// profile. When it is not, iOS refuses to launch the extension at all — the
/// widget then sits on its placeholder forever, no log line is ever written, and
/// the app looks perfectly healthy. Exactly the kind of silence that costs a
/// day.
///
/// On iOS the app cannot read another bundle's signature (`SecCode` is macOS
/// only), but it *can* read its own `embedded.mobileprovision`, which lists the
/// entitlements Apple has granted — and the extension is signed with the same
/// profile. One line, at `notice` level, so it shows without turning on
/// Info/Debug messages.
enum WidgetExtensionProbe {

    static let subsystem = "app.immich.swiftui"
    static let category = "widget-probe"

    /// The keychain group the three entitlements declare — shared by the app,
    /// the widget and the share extension.
    ///
    /// It is NOT derived from a bundle identifier: the whole point of naming it
    /// after the product is that renaming a target's bundle id leaves the group
    /// (and therefore everyone's stored session) alone.
    private static let sharedKeychainGroup = "fr.millianlmx.swimmich"

    /// A single line, meant to be pasted into a report.
    static func report(logger: Logger = Logger(subsystem: subsystem, category: category)) -> String {
        let message = diagnose()
        logger.notice("\(message, privacy: .public)")
        return message
    }

    static func diagnose() -> String {
        guard let appex = embeddedExtensionName() else {
            return "widget: no appex embedded in this app — the widget extension was not installed with it"
        }
        guard let profile = profileEntitlements() else {
            return "widget: \(appex) present; no provisioning profile to inspect (simulator build — this link can only fail on a device)"
        }
        return verdict(
            extensionName: appex,
            profileEntitlements: profile
        )
    }

    /// The decision, separated from the file reading so it can be tested: given
    /// what Apple granted, is the group the shared session lives in covered?
    static func verdict(
        extensionName: String,
        profileEntitlements profile: [String: Any]
    ) -> String {
        // `ApplicationIdentifierPrefix` is the reliable source: a team profile
        // carries `application-identifier = <team>.*` for a wildcard App ID, so
        // deriving the prefix from that string does not work.
        guard let teamPrefix = (profile["ApplicationIdentifierPrefix"] as? [String])?.first else {
            return "widget: \(extensionName) present; profile has no ApplicationIdentifierPrefix — cannot derive the keychain group"
        }

        let sharedGroup = teamPrefix + sharedKeychainGroup
        let authorised = profile["keychain-access-groups"] as? [String] ?? []
        // A team profile authorises `<team>.*`, which covers every group of that
        // team — comparing strings exactly would report a mismatch that is not
        // one, and send the reader hunting a capability problem that does not
        // exist.
        let covered = authorised.contains { entry in
            entry == sharedGroup || (entry.hasSuffix(".*") && sharedGroup.hasPrefix(String(entry.dropLast(1))))
        }
        if covered {
            return "widget: ok — profile authorises \(sharedGroup) for both binaries (via \(authorised.first { $0 == sharedGroup } ?? authorised.joined(separator: ", ")))"
        }
        return "widget: MISMATCH — profile authorises \(authorised.isEmpty ? "no keychain group" : authorised.joined(separator: ", "))"
            + ", but the extension needs \(sharedGroup). Add Keychain Sharing to the ImmichWidgets target (Xcode › Signing & Capabilities) so the profile is regenerated, then reinstall."
    }

    private static func embeddedExtensionName() -> String? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let contents = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        else { return nil }
        return contents.first { $0.pathExtension == "appex" }?.lastPathComponent
    }

    /// The plist Apple wraps in the CMS blob that is `embedded.mobileprovision`.
    private static func profileEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let blob = try? Data(contentsOf: url),
              let xmlStart = blob.range(of: Data("<?xml".utf8)),
              let xmlEnd = blob.range(of: Data("</plist>".utf8), in: xmlStart.lowerBound..<blob.endIndex)
        else { return nil }

        let plistData = blob.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements
    }
}
