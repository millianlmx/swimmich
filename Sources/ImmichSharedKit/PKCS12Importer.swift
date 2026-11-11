import Foundation
import Security

public enum ClientIdentityImportError: Error, Equatable {
    /// `errSecAuthFailed` / `errSecPkcs12VerifyFailure`. A PKCS#12 written with
    /// OpenSSL 3's default algorithms may be refused with the same status and
    /// the right password: the two cases cannot be told apart, so the message
    /// shown for this error also advises re-exporting with `-legacy`.
    case wrongPassword
    /// Not a PKCS#12, unreadable, or one without a private key.
    case unusableFile
}

/// Reads the identity (certificate + private key) of a PKCS#12 file.
///
/// On iOS `SecPKCS12Import` puts nothing in the keychain: the identity is only
/// returned, and `ClientIdentityStore` decides to keep it. Neither the password
/// nor the bytes are ever logged here.
public enum PKCS12Importer {
    private static let pkcs12VerifyFailure: OSStatus = -25264

    public static func identity(from data: Data, password: String) throws -> SecIdentity {
        guard !data.isEmpty else { throw ClientIdentityImportError.unusableFile }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        if status == errSecAuthFailed || status == pkcs12VerifyFailure {
            throw ClientIdentityImportError.wrongPassword
        }
        guard status == errSecSuccess, let array = items as? [[String: Any]] else {
            throw ClientIdentityImportError.unusableFile
        }
        for item in array {
            guard let reference = item[kSecImportItemIdentity as String] else { continue }
            let object = reference as AnyObject
            if CFGetTypeID(object) == SecIdentityGetTypeID() {
                return object as! SecIdentity // swiftlint:disable:this force_cast
            }
        }
        throw ClientIdentityImportError.unusableFile
    }
}
