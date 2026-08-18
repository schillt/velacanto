import SwiftUI

struct ProfileView: View {
    @ObservedObject var jellyfin: JellyfinSessionController

    let isPreparingPlaybackCheck: Bool
    let runPlaybackCheck: () -> Void

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

            #if DEBUG
                Section {
                    Button(action: runPlaybackCheck) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    isPreparingPlaybackCheck
                                        ? "Preparing Playback Check…"
                                        : "Run Playback Check"
                                )
                                .foregroundStyle(.primary)
                                Text("Play a generated 440 Hz diagnostic tone")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            if isPreparingPlaybackCheck {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                SourceIcon(
                                    symbolName: "waveform.badge.magnifyingglass"
                                )
                            }
                        }
                    }
                    .disabled(isPreparingPlaybackCheck)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text(
                        "The playback check uses the same player and system media controls as your music."
                    )
                }
            #endif

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Text("Native music playback for your personal library.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .progressivePageHeader("Profile & Settings")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
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
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0"
    }
}
