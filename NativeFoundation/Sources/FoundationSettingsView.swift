import SwiftUI

/// Presentation only: reuse the profile already loaded by the visible header.
struct FoundationSettingsView: View {
    let name: String
    let image: Image?
    let signOut: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingLicenses = false
    #if DEBUG
        @State private var showingJournal = false
    #endif

    private static let versionLabel: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (Build \(build))"
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(.quaternary)
                            if let image {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.fill").font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }.frame(width: 64, height: 64).clipShape(Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name.isEmpty ? "Your profile" : name).font(.title3.bold())
                            Text("Music library account").font(.subheadline).foregroundStyle(
                                .secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section("About") {
                    Button {
                        showingLicenses = true
                    } label: {
                        Label("Open-source licenses", systemImage: "doc.text")
                    }
                }
                #if DEBUG
                    Section("Internal") {
                        Button {
                            showingJournal = true
                        } label: {
                            Label("Diagnostics", systemImage: "waveform.path.ecg")
                        }
                    }
                #endif
                Section {
                    Button("Sign out", role: .destructive, action: signOut)
                } footer: {
                    Text(Self.versionLabel)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Profile & Settings")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingLicenses) { FoundationLicensesView() }
            #if DEBUG
                .sheet(isPresented: $showingJournal) { FoundationJournalView() }
            #endif
        }
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
            .frame(minWidth: 420, idealWidth: 480, minHeight: 520)
        #endif
    }
}

private struct FoundationLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    private static let notices: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "License notices could not be loaded." }
        return text
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(Self.notices).font(.footnote).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle("Open-source licenses")
            .toolbar { Button("Done") { dismiss() } }
        }
        #if os(macOS)
            .frame(minWidth: 540, minHeight: 420)
        #endif
    }
}

#if DEBUG
    private struct FoundationJournalView: View {
        @Environment(\.dismiss) private var dismiss
        @State private var recording = true
        @State private var text = ""
        var body: some View {
            NavigationStack {
                Form {
                    Toggle("Record internal diagnostics", isOn: $recording)
                        .onChange(of: recording) { _, value in
                            FoundationJournal.shared.setEnabled(value)
                        }
                    Button("Refresh snapshot") { text = FoundationJournal.shared.snapshot() }
                    ShareLink("Share diagnostic snapshot", item: text)
                    Text(text).font(.caption.monospaced()).textSelection(.enabled)
                }
                .navigationTitle("Diagnostics")
                .toolbar { Button("Done") { dismiss() } }
                .task {
                    recording = FoundationJournal.shared.isEnabled
                    text = FoundationJournal.shared.snapshot()
                }
            }
        }
    }
#endif
