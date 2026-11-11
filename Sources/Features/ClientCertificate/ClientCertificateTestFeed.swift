import Foundation

/// UI-test seam (L-10): with `-uiTestClientCertificateFeed <url>` on the launch
/// arguments, "Import Certificate…" skips the system file picker and downloads
/// the PKCS#12 bytes from that URL — the control port of the test stub, which
/// serves the file the test selected. The password is still typed in the
/// interface. Absent in production: the key is never written by the app.
enum ClientCertificateTestFeed {
    static let defaultsKey = "uiTestClientCertificateFeed"
    static let url: URL? = UserDefaults.standard.string(forKey: defaultsKey).flatMap(URL.init(string:))
}
