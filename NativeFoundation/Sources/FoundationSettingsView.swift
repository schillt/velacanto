import SwiftUI

/// Presentation only: reuse the profile already loaded by the visible header.
struct FoundationSettingsView: View {
    let name: String
    let image: Image?
    let signOut: () -> Void
    var library: (any FoundationLibrary)? = nil
    @EnvironmentObject private var downloads: FoundationDownloads
    @State private var measuredCaches = false
    @State private var artworkDisk: Int64?
    @State private var artworkMemory: Int64?
    @State private var pageDisk: Int64?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: FoundationPlaybackPreferences
    @State private var showingLicenses = false
    #if DEBUG
        @State private var showingJournal = false
    #endif

    private static let versionLabel: String = {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (Build \(build))"
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        accountDetails
                    } label: {
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
                    .accessibilityIdentifier("FoundationSettingsAccount")
                }
                Section {
                    if downloads.isLoading {
                        ProgressView("Verifying downloaded storage…")
                    } else {
                        storageRow("Downloaded audio", bytes: downloads.audioBytes)
                        storageRow("Download-owned artwork", bytes: downloads.artworkBytes)
                        storageRow("Download metadata & other files", bytes: downloads.otherBytes)
                    }
                    if measuredCaches {
                        storageRow("Cached artwork", bytes: artworkDisk)
                        storageRow("Cached catalog pages", bytes: pageDisk)
                        storageRow("Artwork cache memory cost", bytes: artworkMemory)
                    } else {
                        ProgressView("Measuring caches…")
                    }
                    NavigationLink {
                        FoundationDownloadManagementView()
                    } label: {
                        Label("Downloaded Music", systemImage: "internaldrive")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text(
                        "Storage is for this account on this device. Download-owned artwork stays with downloaded music. Cached artwork and catalog pages are disposable and cleared on app updates. Artwork cache memory cost includes encoded images and decoded pixels, is temporary, and is not added to disk storage."
                    )
                }
                Section("Playback & Downloads") {
                    #if os(iOS)
                        Button("Playback & Download Settings", systemImage: "gearshape") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    #else
                        Toggle(
                            "Allow Cellular Streaming",
                            isOn: Binding(
                                get: { preferences.allowsCellularStreaming },
                                set: { preferences.setAllowsCellularStreaming($0) }))
                        Toggle(
                            "Allow Cellular Downloads",
                            isOn: Binding(
                                get: { preferences.allowsCellularDownloads },
                                set: { preferences.setAllowsCellularDownloads($0) }))
                    #endif
                }
                Section("About") {
                    Button {
                        showingLicenses = true
                    } label: {
                        Label("Open-source licenses", systemImage: "doc.text")
                    }
                }
                Section {
                    #if DEBUG
                        Button {
                            showingJournal = true
                        } label: {
                            Label("Local diagnostic snapshot", systemImage: "waveform.path.ecg")
                        }
                    #else
                        Text("Version and build information appear below.")
                            .foregroundStyle(.secondary)
                    #endif
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("No telemetry or diagnostic reports are sent automatically.")
                }
                Section {
                    Button("Sign out", role: .destructive, action: signOut)
                } footer: {
                    VStack(spacing: 12) {
                        Text("Signing out removes saved pins from this device.")
                        Text(Self.versionLabel)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .formStyle(.grouped)
            .task { await measureCaches() }
            .refreshable { await measureCaches() }
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
        #if os(macOS)
            .frame(minWidth: 420, idealWidth: 480, minHeight: 520)
        #endif
    }

    private func storageRow(_ title: String, bytes: Int64?) -> some View {
        LabeledContent(
            title,
            value: bytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "Unavailable")
    }

    @MainActor
    private func measureCaches() async {
        let adapter = library as? FoundationJellyfinLibrary
        let usage = await adapter?.artworkCache?.storageUsage()
        let pages = await library?.catalogPageCache?.storageBytes()
        guard !Task.isCancelled else { return }
        artworkDisk = usage?.disk
        artworkMemory = usage?.memory
        pageDisk = pages
        measuredCaches = true
    }

    private var accountDetails: some View {
        Form {
            Section("Account") {
                LabeledContent("Profile", value: name.isEmpty ? "Your profile" : name)
                LabeledContent("Provider", value: "Jellyfin")
            }
            Section("Server") {
                if let session = (library as? FoundationJellyfinLibrary)?.session {
                    LabeledContent("Server", value: session.serverURL.host() ?? "Unavailable")
                    LabeledContent(
                        "Connection", value: session.serverURL.scheme == "https" ? "HTTPS" : "HTTP")
                } else {
                    Text("Server details are unavailable for this account.")
                        .foregroundStyle(.secondary)
                }
                Text("Saved credentials are protected in Keychain and are not displayed here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Music Libraries") {
                Text("All music available to this Jellyfin account")
                Text(
                    "Velacanto browses the music your server grants this account access to. Library access is configured in Jellyfin; choosing an individual library in Velacanto is not available yet."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server & Account")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
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
                    Toggle("Record local diagnostics", isOn: $recording)
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
