import SwiftUI
import UniformTypeIdentifiers

/// The client certificate of one server: state, import / replace, remove (L-10).
///
/// A `Form` without a navigation stack of its own: the server step presents it
/// in a sheet's stack, the "Me" hub pushes it. The password section opens only
/// once a file was picked.
struct ClientCertificateView: View {
    @Bindable var vm: ClientCertificateViewModel

    var body: some View {
        Form {
            statusSection
            actionsSection
            if vm.pendingFileData != nil {
                passwordSection
            }
            if let message = vm.message {
                messageSection(message)
            }
        }
        .navigationTitle("Client Certificate")
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.refresh() }
        .fileImporter(
            isPresented: $vm.showsFilePicker,
            allowedContentTypes: [.pkcs12],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { vm.filePicked(result: .success(url)) }
            case .failure(let error):
                vm.filePicked(result: .failure(error))
            }
        }
        .alert("Remove the client certificate?", isPresented: $vm.confirmsRemoval) {
            Button("Remove", role: .destructive) {
                Task { await vm.confirmRemoval() }
            }
            .accessibilityIdentifier("clientCertificateRemoveConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Requests to this server will no longer present it.")
        }
    }

    private var statusSection: some View {
        Section {
            if let label = vm.serverLabel {
                Text(verbatim: label)
                    .font(.pvSubhead)
                    .foregroundStyle(Color.textSecondaryPV)
                    .accessibilityIdentifier("clientCertificateServer")
            }
            if vm.hasCertificate {
                Label("A client certificate is installed for this server.", systemImage: "checkmark.seal.fill")
                    .font(.pvBody)
                    .foregroundStyle(Color.immichSuccess)
                    .accessibilityIdentifier("clientCertificateStatus_installed")
            } else {
                Text("No client certificate is installed for this server.")
                    .font(.pvBody)
                    .foregroundStyle(Color.textSecondaryPV)
                    .accessibilityIdentifier("clientCertificateStatus_none")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await vm.startImport() }
            } label: {
                if vm.hasCertificate {
                    Text("Replace Certificate…")
                } else {
                    Text("Import Certificate…")
                }
            }
            .disabled(!vm.canImport)
            .accessibilityIdentifier("clientCertificateImportButton")

            Button(role: .destructive) {
                vm.requestRemoval()
            } label: {
                Text("Remove Certificate")
            }
            .disabled(!vm.canRemove)
            .accessibilityIdentifier("clientCertificateRemoveButton")
        }
    }

    private var passwordSection: some View {
        Section {
            SecureField("Password", text: $vm.password)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("clientCertificatePasswordField")

            Button("Import") {
                Task { await vm.submitPassword() }
            }
            .disabled(vm.isWorking)
            .accessibilityIdentifier("clientCertificatePasswordSubmit")

            Button("Cancel", role: .cancel) {
                vm.cancelPassword()
            }
            .accessibilityIdentifier("clientCertificatePasswordCancel")
        } header: {
            Text("Certificate Password")
        } footer: {
            Text("Enter the password that protects this file.")
        }
    }

    private func messageSection(_ message: ClientCertificateViewModel.Message) -> some View {
        Section {
            Group {
                if message.isSuccess {
                    Label(message.text, systemImage: "checkmark.circle.fill")
                        .font(.pvBody)
                        .foregroundStyle(Color.immichSuccess)
                } else {
                    InlineErrorBadge(message: message.text)
                }
            }
            .accessibilityIdentifier("clientCertificateMessage_\(message.kind)")
        }
    }
}
