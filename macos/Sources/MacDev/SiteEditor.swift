import AppKit
import MacDevCore
import SwiftUI

struct SiteEditor: View {
    @ObservedObject var store: SiteStore
    let site: Site?
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var root = ""
    @State private var version = ""
    @State private var useCustomCertificate = false
    @State private var certificate = ""
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(site == nil ? "Add Site" : "Edit Site").font(.title2.weight(.semibold))
            Form {
                TextField("Domain", text: $domain, prompt: Text("myapp.test"))
                HStack {
                    TextField(
                        site == nil ? "Project folder" : "Document root", text: $root,
                        prompt: Text("~/workspace/myapp"))
                    Button("Choose…") { chooseFolder() }
                }
                if site == nil {
                    Text("If the project has a public folder, MacDev uses it as the document root.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if site == nil || site?.fpm != nil {
                    Picker("PHP version", selection: $version) {
                        Text("Choose version").tag("")
                        ForEach(store.phpVersions, id: \.self) { Text("PHP \($0)").tag($0) }
                    }
                }
                Toggle("Use an existing certificate and private key", isOn: $useCustomCertificate)
                if useCustomCertificate {
                    certificateField("Certificate", value: $certificate, prompt: "certificate.pem")
                    certificateField("Private key", value: $key, prompt: "certificate-key.pem")
                } else {
                    Text(
                        site == nil
                            ? "MacDev generates a certificate using your existing mkcert authority. Set up trust once with mkcert -install if needed."
                            : "The current certificate is kept. Renaming an HTTPS domain generates a certificate for the new name."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)
            if let error = store.error {
                ScrollView {
                    Text(error).foregroundStyle(.red).textSelection(.enabled).frame(
                        maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
            HStack {
                if store.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.isBusy)
                Button(site == nil ? "Create Site" : "Save Changes") {
                    Task {
                        if await store.saveSite(
                            site, domain: domain.trimmingCharacters(in: .whitespaces), root: root,
                            version: version, certificate: useCustomCertificate ? certificate : "",
                            key: useCustomCertificate ? key : "")
                        {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    store.isBusy || domain.isEmpty || root.isEmpty
                        || ((site == nil || site?.fpm != nil) && version.isEmpty)
                        || (useCustomCertificate && (certificate.isEmpty || key.isEmpty)))
            }
        }
        .padding(24).frame(width: 630)
        .interactiveDismissDisabled(store.isBusy)
        .onAppear {
            domain = site?.domain ?? ""
            root = site?.root ?? ""
            version = site?.phpVersion ?? (site == nil ? store.phpVersions.first ?? "" : "")
            store.error = nil
        }
    }

    private func certificateField(_ title: String, value: Binding<String>, prompt: String) -> some View {
        HStack {
            TextField(title, text: value, prompt: Text(prompt))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.message = "Choose the \(title.lowercased()) file in PEM format."
                panel.prompt = "Choose"
                panel.directoryURL = startDirectory(for: value.wrappedValue)
                if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message =
            site == nil
            ? "Choose the project folder. MacDev uses its public folder as the document root if there is one."
            : "Choose the folder nginx serves for this site."
        panel.prompt = "Choose"
        panel.directoryURL = startDirectory(for: root)
        if panel.runModal() == .OK, let url = panel.url { root = url.path }
    }

    /// Opens panels next to the current value instead of the last-used location.
    private func startDirectory(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let expanded =
            path.hasPrefix("~/")
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
            : path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return nil }
        let url = URL(fileURLWithPath: expanded)
        return isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }
}
