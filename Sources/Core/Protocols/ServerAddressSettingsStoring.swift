import Foundation
import ImmichSharedKit

/// Where the local and external address of each saved account are kept. The
/// key is `SavedAccount.id`, so a setting follows its account and nothing else.
protocol ServerAddressSettingsStoring: AnyObject, Sendable {
    func settings(for accountID: String) -> ServerAddressSettings
    func save(_ settings: ServerAddressSettings, for accountID: String)
    func remove(for accountID: String)
    func removeAll()
}
