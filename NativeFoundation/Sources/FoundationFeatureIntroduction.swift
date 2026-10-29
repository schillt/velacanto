import SwiftUI

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
            if history.needsOffer(hasPendingPinChoice: hasPendingPinChoice) {
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
    @ObservedObject private var history = FoundationIntroductionHistory.shared
    @Environment(\.dismiss) private var dismiss
    @State private var features: [FoundationIntroductionFeature] = []
    @State private var step = 0
    @State private var promptOwner = UUID()
    @State private var showsPinChoice = false
    @State private var started = false
    @State private var madePinDecision = false

    private var totalSteps: Int { features.count + (showsPinChoice ? 1 : 0) }
    private var isPinStep: Bool { step >= features.count && showsPinChoice }
    private var isLast: Bool { step + 1 >= totalSteps }

    var body: some View {
        VStack(spacing: 0) {
            if isPinStep, let sync {
                FoundationIntroductionPinStep(sync: sync) { madePinDecision = true }
            } else if features.indices.contains(step) {
                featurePage(features[step])
            } else {
                ContentUnavailableView("You’re up to date", systemImage: "checkmark.circle")
            }
            Divider()
            HStack {
                Button("Skip") { finish() }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Button(primaryActionTitle) {
                    if isLast {
                        finish(declinePin: isPinStep && !madePinDecision && !replay)
                    } else {
                        step += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .navigationTitle(isPinStep ? "iCloud Pins" : "What’s New")
        #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 460, idealHeight: 560)
        #endif
        .accessibilityIdentifier("feature-introduction-walkthrough")
        .onAppear {
            guard !started else { return }
            started = true
            features = replay ? FoundationIntroductionFeature.current : history.pending()
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

    private func featurePage(_ feature: FoundationIntroductionFeature) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 48)).foregroundStyle(.tint).accessibilityHidden(true)
                Text(feature.title).font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(feature.detail).font(.title3).foregroundStyle(.secondary)
                Text("\(step + 1) of \(totalSteps)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        dismiss()
    }
}

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
                    "Only pin identities and order sync for this server and account. Your music stays in your library. You can change this anytime in Settings. Turning sync off keeps cloud pins in iCloud."
                )
            }
        }
        .formStyle(.grouped)
    }
}
