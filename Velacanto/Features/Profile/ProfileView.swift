import SwiftUI

struct ProfileView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @AppStorage(PlaybackDiagnosticJournal.recordingEnabledDefaultsKey)
    private var isRecordingPlaybackDiagnostics =
        PlaybackDiagnosticJournal.defaultRecordingEnabled

    let dismiss: () -> Void

    var body: some View {
        Form {
            Section("Music Server") {
                NavigationLink {
                    JellyfinAccessView(jellyfin: jellyfin)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(jellyfin.isSignedIn ? "Manage Jellyfin" : "Connect to Jellyfin")
                                .foregroundStyle(.primary)
                            Text(jellyfinStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        SourceIcon(symbolName: "server.rack")
                    }
                }
            }

            Section("Diagnostics") {
                Toggle(
                    "Record playback diagnostics",
                    isOn: $isRecordingPlaybackDiagnostics
                )
                Text(
                    "Saves a small, privacy-safe playback journal on this device while enabled."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Text("Native music playback for your personal library.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .progressiveScreenHeader("Profile & Settings") {
            Button("Done", action: dismiss)
        }
    }

    private var jellyfinStatus: String {
        if let session = jellyfin.session {
            return "\(session.username) · \(session.serverName)"
        }
        if jellyfin.phase == .restoring {
            return "Restoring your saved session"
        }
        return "Add your personal music server"
    }

    private var appVersion: String {
        let marketingVersion =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.2.5"
        guard
            let buildVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            !buildVersion.isEmpty
        else {
            return marketingVersion
        }
        return "\(marketingVersion) (\(buildVersion))"
    }
}
