import AppKit
import MochiKernel
import SwiftUI

struct AboutSettingsView: View {
    @State private var characterLicence: String?
    @State private var licenceError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppIdentity.name).font(.title2.bold())
                        Text(Self.versionDescription).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Conversation and speaking practice.").font(.callout)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Links") {
                LabeledContent("Author") { Link("@xiaolai", destination: AppIdentity.authorURL) }
                Link("Project Page", destination: AppIdentity.repositoryURL)
                Link("Release Notes", destination: AppIdentity.repositoryURL.appending(path: "releases"))
                Link("Report an Issue", destination: AppIdentity.repositoryURL.appending(path: "issues"))
            }
            Section("Acknowledgements") {
                Text("Mochi © 2026 HANDO K.K. Used under the Mochi Character Licence.").foregroundStyle(.secondary)
                if let url = AppResources.url("Mochi-LICENSE", "md") {
                    Button("Character Licence…") {
                        do {
                            characterLicence = try String(contentsOf: url, encoding: .utf8)
                            licenceError = nil
                        } catch {
                            licenceError = "Couldn’t open the character licence: \(error.localizedDescription)"
                        }
                    }
                }
                if let licenceError { Text(licenceError).foregroundStyle(.red).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { characterLicence != nil }, set: { if !$0 { characterLicence = nil } })) {
            VStack(alignment: .trailing, spacing: 12) {
                ScrollView {
                    Text(characterLicence ?? "").font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Done") { characterLicence = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .frame(width: 560, height: 460)
        }
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String,
            let build = info["CFBundleVersion"] as? String
        else { return String(localized: "Development build") }
        return String(localized: "Version \(version) (build \(build))")
    }
}
