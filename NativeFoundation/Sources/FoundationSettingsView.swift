import SwiftUI

/// Presentation only: reuse the profile already loaded by the visible header.
struct FoundationSettingsView: View {
    let name: String
    let image: Image?
    let signOut: () -> Void
    var library: (any FoundationLibrary)? = nil
    var librarySelection: FoundationMusicLibrarySelection? = nil
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
                if let librarySelection {
                    FoundationMusicLibrarySettingsRow(selection: librarySelection)
                } else {
                    Text("All music available to this Jellyfin account")
                    Text("Library selection is unavailable for this connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server & Account")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

}

/// The account owns committed scope; this destination owns only an uncommitted draft.
private struct FoundationMusicLibrarySettingsRow: View {
    @ObservedObject var selection: FoundationMusicLibrarySelection

    var body: some View {
        NavigationLink {
            FoundationMusicLibrarySelectionView(selection: selection)
        } label: {
            LabeledContent(
                "Browse music",
                value: selection.selectionReadFailed
                    ? "Saved selection unavailable"
                    : (selection.selectedID == nil
                        ? "All music libraries" : (selection.selectedName ?? "Selected library")))
        }
        .accessibilityIdentifier("FoundationSettingsMusicLibraries")
    }
}

private struct FoundationMusicLibrarySelectionView: View {
    @ObservedObject var selection: FoundationMusicLibrarySelection
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [FoundationMusicLibraryChoice] = []
    @State private var draftID: String?
    @State private var hasDraft = false
    @State private var hasExplicitDraft = false
    @State private var loading = false
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var retry = 0
    @State private var isApplying = false
    @State private var applyTask: Task<Void, Never>?

    private struct LoadIdentity: Hashable {
        let localOnly: Bool
        let retry: Int
    }

    private var canSave: Bool {
        loaded && !loading && !isApplying && !connectivity.localOnly
            && (draftID != selection.selectedID
                || (selection.selectionReadFailed && hasExplicitDraft))
            && (draftID == nil || choices.contains { $0.id == draftID })
    }

    var body: some View {
        List {
            Section {
                LabeledContent(
                    "Current selection",
                    value: selection.selectionReadFailed
                        ? "Saved selection unavailable"
                        : (selection.selectedID == nil
                            ? "All music libraries"
                            : (selection.selectedName ?? "Selected library")))
            }
            Section {
                if selection.selectionReadFailed {
                    Label(
                        "Your saved library selection could not be read. Choose a library or all music libraries, then Save to restore browsing.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                }
                if connectivity.localOnly {
                    Label("Connect to choose a music library.", systemImage: "wifi.slash")
                    Text("Your current selection is kept for cached browsing.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if loading {
                    ProgressView("Loading your music libraries…")
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Retry") { retry += 1 }
                        .accessibilityIdentifier("FoundationMusicLibraryRetry")
                } else if loaded {
                    choiceRow(name: "All music libraries", id: nil)
                    ForEach(choices) { choice in
                        choiceRow(name: choice.name, id: choice.id)
                    }
                    if choices.isEmpty {
                        Text("No individual music libraries are available to this account.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let selected = selection.selectedID,
                        !choices.contains(where: { $0.id == selected })
                    {
                        Label(
                            "Your selected library is no longer available. Choose another library or all music libraries.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                    }
                }
            } header: {
                Text("Browse Music")
            } footer: {
                Text(
                    "Choose a library, then Save. Downloaded music and playlists remain available across all libraries in this account. Changing this selection does not interrupt playback."
                )
            }
            if isApplying { ProgressView("Saving library selection…") }
        }
        .navigationTitle("Music Libraries")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(isApplying)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(isApplying)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(!canSave)
                    .accessibilityIdentifier("FoundationMusicLibrarySave")
            }
        }
        .task(id: LoadIdentity(localOnly: connectivity.localOnly, retry: retry)) {
            if !hasDraft {
                draftID = selection.selectedID
                hasDraft = true
            }
            guard !connectivity.localOnly else {
                loading = false
                return
            }
            loading = true
            errorMessage = nil
            do {
                let result = try await selection.loadChoices()
                try Task.checkCancellation()
                choices = result
                loaded = true
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = FoundationLibraryError.category(error).errorDescription
            }
            guard !Task.isCancelled else { return }
            loading = false
        }
        .onDisappear {
            applyTask?.cancel()
            applyTask = nil
        }
    }

    private func choiceRow(name: String, id: String?) -> some View {
        Button {
            draftID = id
            hasExplicitDraft = true
            errorMessage = nil
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if draftID == id && (!selection.selectionReadFailed || hasExplicitDraft) {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(isApplying)
        .accessibilityValue(
            draftID == id && (!selection.selectionReadFailed || hasExplicitDraft)
                ? "Selected" : "Not selected"
        )
        .accessibilityHint("Selection is applied when you choose Save")
        .accessibilityAddTraits(
            draftID == id && (!selection.selectionReadFailed || hasExplicitDraft) ? .isSelected : []
        )
        .accessibilityIdentifier(
            id == nil ? "FoundationMusicLibraryAll" : "FoundationMusicLibraryChoice")
    }

    private func save() {
        guard canSave else { return }
        let choice = draftID.flatMap { id in choices.first { $0.id == id } }
        isApplying = true
        errorMessage = nil
        applyTask = Task {
            do {
                try await selection.select(choice)
                try Task.checkCancellation()
                isApplying = false
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                isApplying = false
                errorMessage = FoundationLibraryError.category(error).errorDescription
            }
        }
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
