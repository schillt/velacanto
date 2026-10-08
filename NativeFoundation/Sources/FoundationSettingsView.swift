import SwiftUI

#if DEBUG
    #if os(iOS)
        import UIKit
    #else
        import AppKit
    #endif
#endif

/// Presentation only: reuse the profile already loaded by the visible header.
struct FoundationSettingsView: View {
    let name: String
    let image: Image?
    let signOut: () -> Void
    var library: (any FoundationLibrary)? = nil
    var librarySelection: FoundationMusicLibrarySelection? = nil
    var signInAgain: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: FoundationPlaybackPreferences
    #if DEBUG
        @State private var diagnosticSnapshot: FoundationJournalSnapshot?
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
                    #if os(macOS)
                        profileRow.accessibilityIdentifier("FoundationSettingsAccount")
                    #else
                        NavigationLink {
                            accountDetails
                        } label: {
                            profileRow
                        }
                        .accessibilityIdentifier("FoundationSettingsAccount")
                    #endif
                }
                #if os(macOS)
                    accountSections
                    if let signInAgain {
                        Section {
                            Button("Sign In Again…", action: signInAgain)
                        }
                    }
                #endif
                Section("Storage") {
                    NavigationLink {
                        FoundationDownloadManagementView()
                    } label: {
                        Label("Downloaded Music", systemImage: "internaldrive")
                    }
                    NavigationLink {
                        FoundationCachedMediaView(library: library)
                    } label: {
                        Label("Cached Media", systemImage: "photo.stack")
                    }
                }
                Section("Playback") {
                    #if os(iOS)
                        Button("Playback Settings", systemImage: "gearshape") {
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
                    #endif
                }
                #if DEBUG
                    FoundationJournalSection { text in
                        diagnosticSnapshot = FoundationJournalSnapshot(text: text)
                    }
                #else
                    Section {
                        Text("Version and build information appear below.")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Diagnostics")
                    } footer: {
                        Text("No telemetry or diagnostic reports are sent automatically.")
                    }
                #endif
                Section {
                    Button("Sign out", role: .destructive, action: signOut)
                } footer: {
                    VStack(spacing: 12) {
                        Text("Signing out removes saved pins from this device.")
                        Text(Self.versionLabel)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                Section {
                    NavigationLink {
                        FoundationLicensesView()
                    } label: {
                        Label("Open-source licenses", systemImage: "doc.text")
                    }
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("foundation-profile-form")
            .navigationTitle("Profile & Settings")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            #endif
        }
        #if DEBUG
            .sheet(item: $diagnosticSnapshot) { snapshot in
                FoundationJournalSnapshotViewer(text: snapshot.text)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
        #endif
        #if os(macOS)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 520)
        #endif
    }

    private var profileRow: some View {
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

    @ViewBuilder private var accountSections: some View {
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

    private var accountDetails: some View {
        Form { accountSections }
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

private struct FoundationCachedMediaView: View {
    let library: (any FoundationLibrary)?
    @State private var measured = false
    @State private var measuring = false
    @State private var artworkDisk: Int64?
    @State private var artworkMemory: Int64?
    @State private var pageDisk: Int64?
    @State private var measurementRevision = 0

    var body: some View {
        Form {
            Section {
                if measured {
                    storageRow("Cached artwork", bytes: artworkDisk)
                    storageRow("Cached catalog pages", bytes: pageDisk)
                } else {
                    ProgressView("Measuring caches…")
                }
            } header: {
                Text("On This Device")
            } footer: {
                Text(
                    "Cached artwork and catalog pages are disposable storage for this account on this device. They are cleared on app updates and are separate from downloaded music and its artwork."
                )
            }
            Section {
                if measured {
                    storageRow("Artwork cache memory cost", bytes: artworkMemory)
                }
            } header: {
                Text("Temporary Memory")
            } footer: {
                Text(
                    "Artwork cache memory cost includes encoded images and decoded pixels. It is temporary and is not added to disk storage."
                )
            }
            Section {
                Button("Refresh measurements") { measurementRevision += 1 }
                    .disabled(measuring)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cached Media")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: measurementRevision) { await measure() }
        .refreshable { await measure() }
    }

    private func storageRow(_ title: String, bytes: Int64?) -> some View {
        LabeledContent(
            title,
            value: bytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "Unavailable")
    }

    @MainActor private func measure() async {
        guard !measuring else { return }
        measuring = true
        defer { measuring = false }
        let adapter = library as? FoundationJellyfinLibrary
        let usage = await adapter?.artworkCache?.storageUsage()
        let pages = await library?.catalogPageCache?.storageBytes()
        guard !Task.isCancelled else { return }
        artworkDisk = usage?.disk
        artworkMemory = usage?.memory
        pageDisk = pages
        measured = true
    }
}

private struct FoundationLicenseNotice: Identifiable {
    let title: String
    let version: String
    let text: String
    var id: String { title }
}

private struct FoundationLicensesView: View {
    private static let notices: (introduction: String, dependencies: [FoundationLicenseNotice]) = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return ("License notices could not be loaded.", []) }
        let sections = text.components(
            separatedBy:
                "\n========================================================================\n")
        let names = [
            "get": "Get",
            "jellyfin-sdk-swift": "Jellyfin Swift SDK",
            "swift-atomics": "Swift Atomics",
            "swift-collections": "Swift Collections",
            "swift-nio": "Swift NIO",
            "swift-nio-transport-services": "Swift NIO Transport Services",
            "swift-system": "Swift System",
        ]
        let dependencies = sections.dropFirst().compactMap { section -> FoundationLicenseNotice? in
            guard let header = section.split(separator: "\n", maxSplits: 1).first else {
                return nil
            }
            let fields = header.split(separator: " ", maxSplits: 1)
            guard let package = fields.first else { return nil }
            let title = names[String(package)] ?? String(package)
            let version = fields.count > 1 ? String(fields[1]) : ""
            return FoundationLicenseNotice(title: title, version: version, text: section)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (sections.first ?? "", dependencies)
    }()

    var body: some View {
        List {
            Section {
                ForEach(Self.notices.dependencies) { notice in
                    NavigationLink {
                        ScrollView {
                            Text(verbatim: notice.text).font(.footnote).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                        .navigationTitle(notice.title)
                        #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                        #endif
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.title)
                            Text(notice.version).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                DisclosureGroup("About these notices") {
                    Text(verbatim: Self.notices.introduction).font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Open-source licenses")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if DEBUG
    private struct FoundationJournalSnapshot: Identifiable {
        let id = UUID()
        let text: String
    }

    private struct FoundationJournalSection: View {
        let openSnapshot: (String) -> Void
        @State private var recording = true
        @State private var text = ""
        private var hasSnapshot: Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var body: some View {
            Section {
                Toggle("Record local diagnostics", isOn: $recording)
                    .onChange(of: recording) { _, value in
                        FoundationJournal.shared.setEnabled(value)
                    }
                Button("Refresh snapshot") { text = FoundationJournal.shared.snapshot() }
                ShareLink("Share diagnostic snapshot", item: text).disabled(!hasSnapshot)
                Button("Diagnostic snapshot") { openSnapshot(text) }
                    .disabled(!hasSnapshot)
                    .accessibilityIdentifier("diagnostic-snapshot-open")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("No telemetry or diagnostic reports are sent automatically.")
            }
            .task {
                recording = FoundationJournal.shared.isEnabled
                text = FoundationJournal.shared.snapshot()
            }
        }
    }

    private struct FoundationJournalSnapshotViewer: View {
        let text: String
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                FoundationJournalTextView(text: text)
                    .navigationTitle("Diagnostic snapshot")
                    #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            #if os(macOS)
                .frame(minWidth: 520, idealWidth: 720, minHeight: 420, idealHeight: 600)
            #endif
        }
    }
    // Native text containers lay out the visible viewport instead of measuring
    // the entire bounded journal as one SwiftUI Text before the sheet appears.
    #if os(iOS)
        private struct FoundationJournalTextView: UIViewRepresentable {
            let text: String

            func makeUIView(context: Context) -> UITextView {
                let view = UITextView(usingTextLayoutManager: true)
                view.isEditable = false
                view.isSelectable = true
                view.alwaysBounceVertical = true
                view.backgroundColor = .clear
                view.textColor = .label
                view.font = .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .regular)
                view.adjustsFontForContentSizeCategory = true
                view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
                view.isAccessibilityElement = true
                view.accessibilityLabel = "Diagnostic snapshot text"
                view.accessibilityIdentifier = "diagnostic-snapshot-content"
                view.text = text
                return view
            }

            func updateUIView(_ view: UITextView, context: Context) {
                if view.text != text { view.text = text }
            }
        }
    #else
        private struct FoundationJournalTextView: NSViewRepresentable {
            let text: String

            func makeNSView(context: Context) -> NSScrollView {
                let scrollView = NSTextView.scrollableTextView()
                guard let view = scrollView.documentView as? NSTextView else {
                    return scrollView
                }
                view.isEditable = false
                view.isSelectable = true
                view.drawsBackground = false
                view.textColor = .labelColor
                view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                view.textContainerInset = NSSize(width: 16, height: 16)
                view.setAccessibilityIdentifier("diagnostic-snapshot-content")
                view.string = text
                scrollView.drawsBackground = false
                return scrollView
            }

            func updateNSView(_ scrollView: NSScrollView, context: Context) {
                guard let view = scrollView.documentView as? NSTextView else { return }
                if view.string != text { view.string = text }
            }
        }
    #endif
#endif

#if os(macOS)
    /// The app owns one native settings window, independent of catalog navigation.
    struct FoundationMacSettingsRoot: View {
        @ObservedObject var model: FoundationAppModel
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            Group {
                if model.library == nil || model.requiresSignIn || model.settingsShowsSignIn {
                    FoundationSignInView(model: model)
                } else if let library = model.library, let downloads = model.downloads,
                    let connectivity = model.connectivity
                {
                    FoundationSettingsView(
                        name: model.profileName, image: model.profileImage,
                        signOut: {
                            // Close the settings window so account results appear in the main window.
                            dismiss()
                            model.signOut()
                        },
                        library: library, librarySelection: model.librarySelection,
                        signInAgain: { model.settingsShowsSignIn = true }
                    )
                    .environmentObject(model.playbackPreferences)
                    .environmentObject(downloads)
                    .environmentObject(connectivity)
                } else {
                    ProgressView("Preparing account…")
                }
            }
            .frame(minWidth: 520, idealWidth: 560, minHeight: 600, idealHeight: 680)
        }
    }
#endif
