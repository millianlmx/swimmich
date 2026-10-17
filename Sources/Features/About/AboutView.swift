import SwiftUI

/// What this app is: its version, the highlights it shipped, the licences of
/// what it embeds (gap G23), its privacy policy and support pages, and how to
/// delete the account it signs in to.
///
/// Pushed from the Me hub, so it declares no `NavigationStack` — `ProfileView`
/// already carries one.
struct AboutView: View {
    @Bindable var whatsNew: WhatsNewViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            LabeledContent("Version", value: version)
                .accessibilityIdentifier("aboutVersionValue")

            NavigationLink {
                WhatsNewView(vm: whatsNew)
            } label: {
                Label("What's New", systemImage: "sparkles")
            }
            .accessibilityIdentifier("aboutWhatsNewRow")

            NavigationLink {
                LicensesView()
            } label: {
                Label("Licenses", systemImage: "doc.text")
            }
            .accessibilityIdentifier("aboutLicensesRow")

            Section {
                Button {
                    openURL(AboutLinks.privacyPolicy(languageCode: locale.language.languageCode?.identifier))
                } label: {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("aboutPrivacyPolicyRow")

                Button {
                    openURL(AboutLinks.support)
                } label: {
                    Label("Support", systemImage: "questionmark.bubble")
                }
                .accessibilityIdentifier("aboutSupportRow")
            }

            Section {
                Text("Swimmich doesn't create any account. Your account lives on your Immich server: to delete it, contact that server's administrator.")
                    .accessibilityIdentifier("aboutAccountDeletionText")
            } header: {
                Text("Account Deletion")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The bundle's own numbers, not `MARKETING_VERSION` read back from the
    /// project: what the user reports is what the running binary carries.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
