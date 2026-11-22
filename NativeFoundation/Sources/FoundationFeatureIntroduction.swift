import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// This is a nonmodal offer inside Home's natural scroll content. The user
/// chooses when to open it; startup account, Siri and Handoff retain their owners.
struct FoundationFeatureIntroductionOffer: View {
    let sync: FoundationPinSync?
    let isActive: Bool

    var body: some View {
        if let sync {
            FoundationPinIntroductionOffer(sync: sync, isActive: isActive)
        } else {
            FoundationIntroductionOfferContent(sync: nil, hasPendingPinChoice: false)
        }
    }
}

private struct FoundationPinIntroductionOffer: View {
    @ObservedObject var sync: FoundationPinSync
    let isActive: Bool
    @Environment(\.scenePhase) private var phase
    #if os(macOS)
        @Environment(\.controlActiveState) private var controlActiveState
    #endif

    private var canPrepare: Bool {
        #if os(macOS)
            isActive && phase == .active && controlActiveState == .key
        #else
            isActive && phase == .active
        #endif
    }

    var body: some View {
        FoundationIntroductionOfferContent(sync: sync, hasPendingPinChoice: sync.offersOptIn)
            .task(id: canPrepare) {
                guard canPrepare else { return }
                // Status only, once per account lifetime; no cloud record reads.
                await sync.prepareOptInPrompt()
            }
    }
}

private struct FoundationIntroductionOfferContent: View {
    let sync: FoundationPinSync?
    let hasPendingPinChoice: Bool
    @ObservedObject private var history = FoundationIntroductionHistory.shared
    @State private var showingIntroduction = false

    private var isWelcome: Bool {
        history.pending().contains { $0.id == FoundationIntroductionFeature.welcomeID }
    }

    var body: some View {
        Group {
            if !history.needsAutomaticPresentation(
                for: FoundationIntroductionHistory.marketingVersion),
                history.needsOffer(hasPendingPinChoice: hasPendingPinChoice)
            {
                Button {
                    showingIntroduction = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.title2).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isWelcome ? "Welcome to VelaCanto" : "What’s New").font(.headline)
                            Text("Explore features and choose what works for you.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("feature-introduction-offer")
            }
        }
        .sheet(isPresented: $showingIntroduction) {
            NavigationStack {
                FoundationFeatureIntroductionView(sync: sync)
            }
            #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            #endif
        }
    }
}

/// Shared native walkthrough, also pushed from the existing Settings stack.
/// Every cloud change is an explicit toggle action in the existing sync section.
struct FoundationFeatureIntroductionView: View {
    var sync: FoundationPinSync? = nil
    var replay = false
    var showsAllFeatures = false
    var onFinish: (() -> Void)? = nil
    @ObservedObject private var history = FoundationIntroductionHistory.shared
    @Environment(\.dismiss) private var dismiss
    @State private var features: [FoundationIntroductionFeature] = []
    @State private var step = 0
    @State private var promptOwner = UUID()
    @State private var showsPinChoice = false
    @State private var started = false
    @State private var madePinDecision = false
    @Environment(\.foundationReduceMotion) private var reduceMotion

    private var totalSteps: Int { features.count + (showsPinChoice ? 1 : 0) }
    private var isPinStep: Bool { step >= features.count && showsPinChoice }
    private var isLast: Bool { step + 1 >= totalSteps }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
                if totalSteps > 0 {
                    TabView(selection: $step) {
                        ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                            featurePage(feature).tag(index)
                        }
                        if showsPinChoice, let sync {
                            FoundationIntroductionPinStep(sync: sync) { madePinDecision = true }
                                .tag(features.count)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                } else {
                    ContentUnavailableView("You’re up to date", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            #else
                Group {
                    if isPinStep, let sync {
                        FoundationIntroductionPinStep(sync: sync) { madePinDecision = true }
                    } else if features.indices.contains(step) {
                        featurePage(features[step])
                    } else {
                        ContentUnavailableView("You’re up to date", systemImage: "checkmark.circle")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
            slideProgress
            HStack(spacing: 16) {
                Button("Skip") { finish() }.foregroundStyle(.secondary)
                Spacer()
                if step > 0 {
                    Button("Back", systemImage: "chevron.left") { move(to: step - 1) }
                        .buttonStyle(.glass)
                }
                Button(primaryActionTitle) {
                    if isLast {
                        finish(declinePin: isPinStep && !madePinDecision && !replay)
                    } else {
                        move(to: step + 1)
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(.bar)
        }
        .navigationTitle("What’s New")
        #if os(macOS)
            .frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 620)
        #endif
        .accessibilityIdentifier("feature-introduction-walkthrough")
        .onAppear {
            guard !started else { return }
            started = true
            features =
                replay || showsAllFeatures
                ? FoundationIntroductionFeature.current : history.pending()
            if let sync {
                if replay {
                    showsPinChoice = sync.available
                } else {
                    // Claim is memory-only. Dismissing without choosing releases it.
                    showsPinChoice = sync.claimOptInPrompt(owner: promptOwner)
                }
            }
        }
        .onDisappear { sync?.releaseOptInPrompt(owner: promptOwner) }
    }

    @ViewBuilder
    private func featurePage(_ feature: FoundationIntroductionFeature) -> some View {
        #if os(iOS)
            if feature.id == FoundationIntroductionFeature.systemStorageID {
                FoundationIntroductionSystemStorageStep()
            } else {
                highlightPage(feature)
            }
        #else
            highlightPage(feature)
        #endif
    }

    private func highlightPage(_ feature: FoundationIntroductionFeature) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("VelaCanto \(feature.release)").font(.caption.weight(.semibold))
                    .textCase(.uppercase).tracking(1).foregroundStyle(.secondary)
                FoundationFeatureIllustration(feature: feature)
                    .frame(height: 250)
                    .accessibilityHidden(true)
                Text(feature.title).font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(feature.detail).font(.title3).foregroundStyle(.secondary)
                Label("Tips are in Profile → User Guide", systemImage: "book.closed")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var slideProgress: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(0, totalSteps), id: \.self) { index in
                Capsule().fill(index == step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == step ? 20 : 6, height: 6)
            }
        }
        .padding(.top, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(min(step + 1, totalSteps)) of \(totalSteps)")
    }

    private func move(to next: Int) {
        guard next >= 0, next < totalSteps else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { step = next }
    }

    private var primaryActionTitle: String {
        if !isLast { return "Continue" }
        if isPinStep && !madePinDecision && !replay { return "Not Now" }
        return "Finish"
    }

    private func finish(declinePin: Bool = false) {
        // Skipping highlights never decides an unseen account action. Only the
        // visible Not Now action declines; toggle changes are explicit consent.
        if declinePin { sync?.respondToOptInPrompt(owner: promptOwner, enable: false) }
        history.acknowledge(features.map(\.id))
        if let onFinish { onFinish() } else { dismiss() }
    }
}

#if os(iOS)
    /// Consent uses the app's existing preference owner. Merely viewing or finishing
    /// this feature never changes quality or enables system-managed downloads.
    struct FoundationIntroductionSystemStorageStep: View {
        @EnvironmentObject private var preferences: FoundationPlaybackPreferences

        private var storageName: String {
            UIDevice.current.userInterfaceIdiom == .pad ? "iPad Storage" : "iPhone Storage"
        }

        var body: some View {
            Form {
                Section {
                    Picker(
                        "New download quality",
                        selection: Binding(
                            get: { preferences.downloadQuality },
                            set: { Self.chooseQuality($0, preferences: preferences) })
                    ) {
                        ForEach(FoundationDownloadQuality.allCases, id: \.self) { quality in
                            Text(
                                quality == .original
                                    ? "Original · In VelaCanto" : "AAC · " + quality.title
                            )
                            .tag(quality)
                        }
                    }
                    .accessibilityIdentifier("introduction-system-storage-quality")
                    Toggle(
                        "Manage New Downloads in \(storageName)",
                        isOn: Binding(
                            get: { preferences.systemManagedDownloads },
                            set: { Self.setEnabled($0, preferences: preferences) })
                    )
                    .disabled(
                        preferences.downloadQuality == .original
                            && !preferences.systemManagedDownloads
                    )
                    .accessibilityIdentifier("introduction-system-storage-toggle")
                } header: {
                    Text("Your downloads, your choice")
                } footer: {
                    Text(
                        "Choose an AAC quality before turning this on. Original downloads stay in"
                            + " VelaCanto; choosing Original turns this option off."
                    )
                }
                Section {
                    Text(
                        "Find new AAC downloads in Settings → General → \(storageName) → VelaCanto."
                    )
                    Text(
                        "Existing downloads stay in VelaCanto. You can still play and remove music from its menu in the app."
                    )
                }
            }
            .formStyle(.grouped)
        }

        static func setEnabled(_ enabled: Bool, preferences: FoundationPlaybackPreferences) {
            guard !enabled || preferences.downloadQuality.aacBitrate != nil else { return }
            preferences.setSystemManagedDownloads(enabled)
        }

        static func chooseQuality(
            _ quality: FoundationDownloadQuality, preferences: FoundationPlaybackPreferences
        ) {
            preferences.setDownloadQuality(quality)
            if quality == .original { preferences.setSystemManagedDownloads(false) }
        }
    }
#endif

private struct FoundationIntroductionPinStep: View {
    @ObservedObject var sync: FoundationPinSync
    let onDecision: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Sync Pins with iCloud",
                    isOn: Binding(
                        get: { sync.enabled },
                        set: {
                            sync.setEnabled($0)
                            onDecision()
                        })
                )
                .disabled(!sync.available)
                .accessibilityIdentifier("introduction-pin-sync-toggle")
                Text(sync.message).font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Your pins, across devices")
            } footer: {
                Text(
                    "Only pin identities and order sync for this server and account. Your music"
                        + " stays in your library. You can change this anytime in Settings. Turning sync"
                        + " off keeps cloud pins in iCloud."
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// Static, local illustrations: no owner artwork, server requests or animation timers.
private struct FoundationFeatureIllustration: View {
    let feature: FoundationIntroductionFeature

    var body: some View {
        Group {
            if feature.id == FoundationIntroductionFeature.continuationID {
                FoundationHandoffDestinationIllustration()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 28).fill(Color.accentColor.opacity(0.10))
                    featureContent.padding(24)
                }
            }
        }
    }

    @ViewBuilder private var featureContent: some View {
        if feature.symbol == "quote.bubble" {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "quote.bubble.fill").font(.title).foregroundStyle(.tint)
                Text("Let the music lead").font(.title3.weight(.semibold)).foregroundStyle(
                    .secondary)
                Text("Follow every word").font(.title2.bold())
                Text("♪  • • •").font(.title3).foregroundStyle(.secondary)
                Capsule().fill(.tint).frame(width: 120, height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if feature.symbol == "list.bullet" {
            VStack(spacing: 12) {
                HStack {
                    Text("Up Next").font(.headline)
                    Spacer()
                    Image(systemName: "shuffle").foregroundStyle(.tint)
                }
                sampleRow("Your next favorite", cover: "PlaylistCoverFlow")
                sampleRow("One more song", cover: "PlaylistCoverResonance")
            }
        } else if feature.symbol == "person.text.rectangle" {
            VStack(spacing: 16) {
                Image(systemName: "person.2.wave.2.fill").font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("The people behind the song").font(.title3.bold())
                HStack(spacing: 20) {
                    Label("Artist", systemImage: "music.mic")
                    Label("Credits", systemImage: "text.alignleft")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .center, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    Image("PlaylistCoverFlow").resizable().scaledToFill()
                    Text(feature.symbol == "music.note.list" ? "My Mix" : "Your music")
                        .font(.headline).foregroundStyle(.white).padding(12)
                }
                .frame(width: 110, height: 140).clipShape(.rect(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: feature.symbol).font(.system(size: 36)).foregroundStyle(.tint)
                    Capsule().fill(.primary.opacity(0.2)).frame(width: 88, height: 7)
                    Capsule().fill(.primary.opacity(0.1)).frame(width: 64, height: 7)
                    Label("VelaCanto", systemImage: "music.note").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sampleRow(_ title: String, cover: String) -> some View {
        HStack(spacing: 12) {
            Image(cover).resizable().scaledToFill().frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 8))
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
        }
    }
}

/// A labelled illustration of the receiving platform's native Handoff surface.
/// Never shown for browser/server-player continuation.
struct FoundationHandoffDestinationIllustration: View {
    var animatesOnAppear = false
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @State private var replayTrigger = 0

    var body: some View {
        VStack(spacing: 12) {
            #if os(macOS)
                macDock
                Text("Illustration · Handoff in this Mac’s Dock")
            #else
                if UIDevice.current.userInterfaceIdiom == .pad {
                    iPadDock
                    Text("Illustration · Handoff in this iPad’s Dock")
                } else {
                    appSwitcher
                    Text("Illustration · Handoff in App Switcher")
                }
            #endif
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .overlay(alignment: .bottomTrailing) {
            if animatesOnAppear && !reduceMotion {
                Button("Replay", systemImage: "arrow.clockwise") { replayTrigger += 1 }
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityLabel("Replay Handoff example")
                    .offset(y: 26)
            }
        }
        .padding(.bottom, animatesOnAppear && !reduceMotion ? 26 : 0)
        .onAppear {
            if animatesOnAppear && !reduceMotion { replayTrigger += 1 }
        }
    }

    private var accessibilityDescription: String {
        #if os(macOS)
            "Illustration: VelaCanto’s Handoff icon in the Mac Dock has a small source-device badge."
        #else
            UIDevice.current.userInterfaceIdiom == .pad
                ? "Illustration: VelaCanto’s Handoff icon appears at the right end of the iPad Dock."
                : "Illustration: the VelaCanto Handoff banner appears at the bottom of App Switcher."
        #endif
    }

    #if os(macOS)
        private var macDock: some View {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 24).fill(Color.accentColor.opacity(0.1))
                VStack(spacing: 18) {
                    Label("Continue on this Mac", systemImage: "desktopcomputer")
                        .font(.headline).foregroundStyle(.primary)
                    HStack(spacing: 14) {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Image(systemName: "safari.fill").foregroundStyle(.teal)
                        Divider().frame(height: 40)
                        FoundationGuideAppIcon().frame(width: 56, height: 56)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "iphone.gen3").font(.caption.bold())
                                    .foregroundStyle(.primary).padding(5)
                                    .background(.regularMaterial, in: .circle).offset(x: 5, y: -5)
                            }
                            .modifier(
                                FoundationHandoffFocusCue(
                                    trigger: replayTrigger, reduceMotion: reduceMotion))
                    }
                    .font(.system(size: 40))
                    .padding(18)
                    .background(.regularMaterial, in: .rect(cornerRadius: 22))
                    Text("Click the badged icon near the right end").font(.subheadline)
                }
                .padding(24)
            }
            .frame(maxWidth: 420).frame(height: 220)
        }
    #else
        private var iPadDock: some View {
            VStack(spacing: 24) {
                Label("Continue on this iPad", systemImage: "ipad")
                    .font(.headline).foregroundStyle(.primary)
                HStack(spacing: 16) {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Image(systemName: "safari.fill").foregroundStyle(.teal)
                    Divider().frame(height: 36)
                    FoundationGuideAppIcon().frame(width: 52, height: 52)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "desktopcomputer").font(.caption.bold())
                                .foregroundStyle(.primary).padding(5)
                                .background(.regularMaterial, in: .circle).offset(x: 5, y: -5)
                        }
                        .modifier(
                            FoundationHandoffFocusCue(
                                trigger: replayTrigger, reduceMotion: reduceMotion))
                }
                .font(.system(size: 36)).padding(18)
                .background(.regularMaterial, in: .rect(cornerRadius: 22))
                Text("Tap VelaCanto’s badged icon").font(.subheadline)
            }
            .padding(24)
            .frame(maxWidth: 420).frame(height: 220)
            .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 24))
        }

        private var appSwitcher: some View {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(.primary.opacity(0.07))
                        .frame(width: 180, height: 104).rotationEffect(.degrees(-7)).offset(x: -28)
                    VStack(spacing: 8) {
                        Image("PlaylistCoverFlow").resizable().scaledToFill()
                            .frame(width: 54, height: 54).clipShape(.rect(cornerRadius: 10))
                        Text("Your music").font(.caption.weight(.semibold))
                    }
                    .frame(width: 180, height: 112)
                    .background(.regularMaterial, in: .rect(cornerRadius: 18))
                    .offset(x: 20)
                }
                HStack(spacing: 10) {
                    FoundationGuideAppIcon().frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("VelaCanto").font(.subheadline.weight(.semibold)).foregroundStyle(
                            .primary)
                        Text("From your Mac").font(.caption)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward.app").foregroundStyle(.primary)
                }
                .padding(12)
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
                .modifier(
                    FoundationHandoffFocusCue(
                        trigger: replayTrigger, reduceMotion: reduceMotion))
            }
            .padding(18)
            .frame(maxWidth: 340)
            .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 26))
        }
    #endif
}

/// Triggered once for visible help (or by Replay); decorative slides stay still.
private struct FoundationHandoffFocusCue: ViewModifier {
    let trigger: Int
    let reduceMotion: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, phase in
                view.scaleEffect(1 + phase * 0.035)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                Color.accentColor.opacity(Double(phase) * 0.85), lineWidth: 3)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: pointerSymbol).font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .opacity(Double(phase)).offset(x: 12, y: 14 - phase * 6)
                            .accessibilityHidden(true)
                    }
                    .allowsHitTesting(false)
            } keyframes: { _ in
                LinearKeyframe(0, duration: 0.18)
                CubicKeyframe(1, duration: 0.22)
                LinearKeyframe(1, duration: 0.65)
                CubicKeyframe(0, duration: 0.3)
            }
        }
    }

    nonisolated private var pointerSymbol: String {
        #if os(macOS)
            "cursorarrow.click"
        #else
            "hand.tap.fill"
        #endif
    }
}

private struct FoundationGuideAppIcon: View {
    var body: some View {
        Group {
            #if os(macOS)
                if let icon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    fallback
                }
            #else
                if let icon = UIImage(named: "AppIcon60x60") {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else {
                    fallback
                }
            #endif
        }
        .clipShape(.rect(cornerRadius: 10))
    }

    private var fallback: some View {
        Image(systemName: "sailboat.fill").resizable().scaledToFit().padding(8)
            .foregroundStyle(.white).background(.blue.gradient)
    }
}

/// Persistent how-to documentation. Opening this guide never changes feature consent.
struct FoundationUserGuideView: View {
    var body: some View {
        List {
            Section {
                Text("Find a feature, learn the steps, then get back to your music.")
                    .foregroundStyle(.secondary)
            }
            ForEach(FoundationUserGuideTopic.all) { topic in
                NavigationLink {
                    FoundationUserGuideArticle(topic: topic)
                } label: {
                    Label(topic.title, systemImage: topic.symbol)
                }
                .accessibilityIdentifier("user-guide-" + topic.id)
            }
        }
        .navigationTitle("User Guide")
        .accessibilityIdentifier("foundation-user-guide")
    }
}

struct FoundationContinueListeningUserGuide: View {
    var body: some View {
        if let topic = FoundationUserGuideTopic.all.first(where: { $0.id == "continue" }) {
            FoundationUserGuideArticle(topic: topic)
        }
    }
}

private struct FoundationUserGuideTopic: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let steps: [String]

    static let all: [Self] = [
        .init(
            id: "browsing", title: "Browse your library", symbol: "music.note.house",
            summary: "Your music is organized across Home, Library and Search.",
            steps: [
                "Use Home for recent music, favorites and genre albums.",
                "Open Library to browse albums, artists, songs, genres and playlists.",
                "Use Search to find music and playlists containing matching songs.",
            ]),
        .init(
            id: "queue", title: "Now Playing & Queue", symbol: "list.bullet",
            summary: "Decide what plays next without stopping the current song.",
            steps: [
                "Open Queue from the player to see Up Next and listening history.",
                "Swipe right for Play Next or Play Last; swipe left to remove an upcoming song.",
                "Drag a reorder handle to change Up Next. Clear History leaves the current song and Up Next intact.",
            ]),
        .init(
            id: "lyrics", title: "Lyrics & Song Credits", symbol: "quote.bubble",
            summary: "Read along and learn more about a recording.",
            steps: [
                "Open Lyrics from the player. Timed lyrics highlight as the music plays.",
                "Select a timed line to seek. After scrolling away, choose Follow Current Lyric to resume following.",
                "Find Song Credits in a song’s menu. On Mac, use the Now Playing artwork or title menu.",
                "A dimmed, slashed Lyrics icon means lyrics are unavailable or the app is offline.",
            ]),
        .init(
            id: "playlists", title: "Manage playlists", symbol: "music.note.list",
            summary: "Edit a playlist in one place.",
            steps: [
                "Choose Manage Playlist from a playlist’s menu.",
                "Edit its name and description, choose a cover, or change Public Playlist"
                    + " when server permissions allow it.",
                "Use Add Songs to search music. Select songs directly or open an album or artist result.",
                "Drag handles to reorder songs. On iPhone, use Select for a batch; on Mac,"
                    + " use Command-click or Shift-click.",
                "Save to keep changes. Delete Playlist removes the playlist from the server, not its music.",
            ]),
        .init(
            id: "downloads", title: "Downloads & Offline Mode", symbol: "arrow.down.circle",
            summary: "Keep music ready without a connection.",
            steps: [
                "Choose Download from a song, album or playlist menu.",
                "Choose download quality in Settings, and enable Offline Mode in Profile & Settings.",
                "Find downloaded music in Library and manage its space in Profile & Settings"
                    + " → Storage → Downloaded Music.",
                "On iPhone or iPad, open Playback Settings, choose AAC quality and enable"
                    + " Manage New Downloads in iPhone or iPad Storage. Original downloads remain in"
                    + " VelaCanto.",
                "Find managed AAC downloads in Settings → General → iPhone or iPad Storage → VelaCanto.",
                "The system may label managed downloads as videos. Removing a download does"
                    + " not remove music from your server.",
            ]),
        .init(
            id: "continue", title: "Continue Listening",
            symbol: "arrow.trianglehead.2.clockwise.rotate.90",
            summary: "Pick up playback from another device or server player.",
            steps: [
                "For VelaCanto on nearby Apple devices, use the receiving device’s native"
                    + " Handoff icon or banner shown below.",
                "Keep the source device’s VelaCanto open. Both devices need the same Apple"
                    + " Account, Wi-Fi, Bluetooth and Handoff enabled.",
                "For another server player, select its Continue Listening card in Home and"
                    + " confirm. VelaCanto resumes the song and includes a usable reported queue"
                    + " when available.",
                "Source stopping depends on the other player. Stop it manually if it keeps playing.",
                "If native Handoff is missing, unlock the source device, keep both devices"
                    + " nearby, and check Handoff, Wi-Fi, Bluetooth and the Apple Account on both.",
                "On Mac, look near the right end of the Dock (at its bottom if the Dock is on"
                    + " a side). On iPhone, look below the App Switcher cards. On iPad, look at the"
                    + " right end of the Dock.",
                "Native Handoff works between VelaCanto apps. Browser and other server"
                    + " players use the in-app Continue Listening card instead; no Apple Handoff"
                    + " banner is expected for them.",
            ]),
        .init(
            id: "pins", title: "Pins & iCloud", symbol: "pin",
            summary: "Keep favorite destinations close, with optional pin syncing.",
            steps: [
                "Choose Pin from an album, artist or playlist menu.",
                "Reorder pins to arrange your library shortcuts.",
                "Enable Sync Pins with iCloud in Profile & Settings to sync pin identities"
                    + " and order for this server and account.",
                "Syncing is optional. Turning it off keeps cloud-saved pins; deleting"
                    + " cloud-saved pins is a separate action.",
            ]),
        .init(
            id: "genres", title: "Genres, sorting & filtering", symbol: "guitars",
            summary: "Browse a genre as albums, tracks or artists.",
            steps: [
                "Open a genre in Home or Library. Albums are shown first.",
                "Use Albums, Tracks or Artists to change the view.",
                "Open Sort and filter to change alphabetical order or show downloaded music.",
                "Library refresh and genre rebuilding are available in Settings, not the browsing screen.",
            ]),
    ]
}

private struct FoundationUserGuideArticle: View {
    let topic: FoundationUserGuideTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if topic.id == "continue" {
                    FoundationHandoffDestinationIllustration(animatesOnAppear: true)
                }
                Label(topic.title, systemImage: topic.symbol).font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(topic.summary).font(.title3).foregroundStyle(.secondary)
                ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)").font(.headline).foregroundStyle(.tint)
                            .frame(width: 24)
                        Text(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(topic.title)
    }
}

/// Library-owned sheets report upward so first-launch content never stacks over them.
struct FoundationIntroductionBlockerPreferenceKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// One foreground root owns the automatic release presentation. No feature toggle
/// or version acknowledgement changes until the user makes an explicit choice.
struct FoundationAutomaticIntroductionPresentation: ViewModifier {
    let isReady: Bool
    let hasOtherPresentation: Bool
    let hasAccountAlert: Bool
    let catalogScope: String
    let sync: FoundationPinSync?
    let preferences: FoundationPlaybackPreferences
    @ObservedObject var controller: FoundationHandoffController
    @ObservedObject private var history = FoundationIntroductionHistory.shared
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @State private var owner = UUID()
    @State private var presented = false
    @State private var closing = false
    @State private var presentedScope = ""

    private var version: String? { FoundationIntroductionHistory.marketingVersion }
    private var foreground: Bool {
        #if os(macOS)
            scenePhase == .active && controlActiveState == .key
        #else
            scenePhase == .active
        #endif
    }
    private var eligibility: FoundationAutomaticIntroductionEligibility {
        .init(
            isReady: isReady, isForeground: foreground,
            hasOtherPresentation: hasOtherPresentation, hasAccountAlert: hasAccountAlert,
            hasHandoff: controller.pending != nil || controller.notice != nil)
    }
    private var presentationKey: String {
        "\(version ?? ""):\(catalogScope):\(eligibility.canPresent):\(foreground):\(isReady):"
            + "\(hasAccountAlert):\(history.acknowledgedVersion ?? ""):\(closing):"
            + "\(history.automaticPresentationOwner?.uuidString ?? "")"
    }

    func body(content: Content) -> some View {
        ZStack {
            // Keep the existing library subtree mounted. Its bounded startup,
            // genre preparation and cache owners continue behind the presentation.
            content
                .disabled(presented).accessibilityHidden(presented)
                #if os(macOS)
                    .blur(radius: presented ? 10 : 0)
                #endif
            #if os(iOS)
                if presented {
                    introduction
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { Rectangle().fill(.background).ignoresSafeArea() }
                        .accessibilityElement(children: .contain)
                        .zIndex(100)
                        .onDisappear { presentationEnded() }
                }
            #endif
        }
        #if os(macOS)
            .sheet(isPresented: $presented, onDismiss: presentationEnded) {
                introduction.interactiveDismissDisabled()
            }
        #endif
        .task(id: presentationKey) {
            if presented {
                if !isReady || hasAccountAlert || catalogScope != presentedScope {
                    closeWithoutAcknowledgement()
                }
                return
            }
            guard !closing, eligibility.canPresent, let version,
                history.needsAutomaticPresentation(for: version)
            else { return }
            // Optional iCloud readiness must not delay the version introduction.
            // If not ready, the existing Home offer retains the pending pin choice.
            guard !Task.isCancelled, eligibility.canPresent,
                history.claimAutomaticPresentation(version: version, owner: owner)
            else { return }
            presentedScope = catalogScope
            #if os(iOS)
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
            presented = true
        }
        .onDisappear {
            if !presented { history.releaseAutomaticPresentation(owner: owner) }
        }
    }

    private var introduction: some View {
        NavigationStack {
            FoundationFeatureIntroductionView(
                sync: sync, showsAllFeatures: true,
                onFinish: {
                    if let version {
                        history.acknowledgeAutomaticPresentation(version: version, owner: owner)
                    }
                    closeWithoutAcknowledgement()
                })
        }
        .environmentObject(preferences)
        .accessibilityIdentifier("automatic-whats-new")
    }

    private func closeWithoutAcknowledgement() {
        guard presented else { return }
        closing = true
        presented = false
    }

    private func presentationEnded() {
        history.releaseAutomaticPresentation(owner: owner)
        closing = false
    }
}
