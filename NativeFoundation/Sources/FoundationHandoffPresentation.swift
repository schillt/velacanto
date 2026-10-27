import SwiftUI

private struct FoundationHandoffEnvironmentKey: EnvironmentKey {
    static let defaultValue: FoundationHandoffController? = nil
}

extension EnvironmentValues {
    var foundationHandoff: FoundationHandoffController? {
        get { self[FoundationHandoffEnvironmentKey.self] }
        set { self[FoundationHandoffEnvironmentKey.self] = newValue }
    }
}

struct FoundationHandoffRouteObserver: View {
    @ObservedObject var controller: FoundationHandoffController
    let open: (FoundationItem) -> Void
    @Environment(\.scenePhase) private var phase
    #if os(macOS)
        @Environment(\.controlActiveState) private var controlActiveState
    #endif

    private var canRoute: Bool {
        #if os(macOS)
            phase == .active && controlActiveState == .key
        #else
            phase == .active
        #endif
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onAppear { routeWhenReady() }
            .onChange(of: controller.browseRequest?.id) { _, _ in routeWhenReady() }
            .onChange(of: phase) { _, _ in routeWhenReady() }
            #if os(macOS)
                .onChange(of: controlActiveState) { _, _ in routeWhenReady() }
            #endif
    }

    private func routeWhenReady() {
        // onChange runs after observable assignment with this render's current
        // environment. No scheduled task can retain an obsolete key-window claim.
        guard canRoute, let item = controller.takeBrowseRequest() else { return }
        open(item)
    }
}

/// A single foreground window owns the confirmation even in a multi-window app.
struct FoundationHandoffPresentation: ViewModifier {
    @ObservedObject var controller: FoundationHandoffController
    let accountAlert: Bool
    @Environment(\.scenePhase) private var phase
    @State private var owner = UUID()
    #if os(macOS)
        @Environment(\.controlActiveState) private var controlActiveState
    #endif

    private var presented: Binding<Bool> {
        Binding(
            get: {
                controller.presentationOwner == owner && !accountAlert && phase == .active
                    && (controller.pending != nil || controller.notice != nil)
            },
            set: { value in
                if !value {
                    controller.releasePresentation(owner)
                }
            })
    }

    private var title: String {
        guard let pending = controller.pending else { return "Handoff" }
        guard pending.payload.session?.wasPlaying == true else { return "Continue VelaCanto?" }
        let device = pending.payload.header.sourceDevice?.displayName ?? "your other device"
        return "Continue listening from \(device)?"
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: controller.pending?.id) { _, _ in claim() }
            .onChange(of: controller.notice) { _, _ in claim() }
            .onChange(of: phase) { _, phase in
                if phase == .active { claim() } else { controller.releasePresentation(owner) }
            }
            .onChange(of: accountAlert) { _, _ in claim() }
            #if os(macOS)
                .onChange(of: controlActiveState) { _, _ in claim() }
            #endif
            .onDisappear { controller.releasePresentation(owner) }
            .alert(
                title,
                isPresented: presented
            ) {
                if controller.pending != nil {
                    Button(
                        controller.pending?.payload.session?.wasPlaying == true
                            ? "Transfer Playback Here" : "Restore Queue Here"
                    ) { controller.acceptPending() }
                    Button("Cancel", role: .cancel) { controller.dismissPending() }
                } else {
                    Button("OK") { controller.notice = nil }
                }
            } message: {
                if let pending = controller.pending, let session = pending.payload.session {
                    Text(
                        session.wasPlaying
                            ? "Move playback and the full queue here at the current position? After playback starts here, the other device’s playback and queue will be cleared."
                            : "Restore the queue, position, shuffle and repeat settings here? Playback will remain paused."
                    )
                } else {
                    Text(controller.notice ?? "")
                }
            }
    }

    private func claim() {
        #if os(macOS)
            guard controlActiveState == .key else { return }
        #endif
        guard phase == .active, !accountAlert,
            controller.pending != nil || controller.notice != nil
        else { return }
        controller.claimPresentation(owner)
    }
}

#if os(macOS)
    import AppKit

    /// Native streams must be requested inside the application continuation event.
    @MainActor
    final class FoundationHandoffApplicationDelegate: NSObject, NSApplicationDelegate {
        func application(
            _ application: NSApplication, continue userActivity: NSUserActivity,
            restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
        ) -> Bool {
            FoundationAppRuntime.model.receiveHandoff(userActivity)
        }
    }
#endif
