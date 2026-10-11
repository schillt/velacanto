import Combine
import Foundation
import Network

/// Advisory presentation state; an explicit normal request can override a stale path observation.
@MainActor
final class FoundationConnectivity: ObservableObject {
    enum Status: Equatable { case checking, available, connecting, unavailable, restricted }
    @Published private(set) var status: Status = .checking
    @Published private(set) var localOnly = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var isRetrying = false
    @Published private(set) var successfulRetryRevision = 0
    var hasConnectionIssue: Bool { localOnly || (status == .available && statusMessage != nil) }
    @Published private(set) var usesWiFiOrWired = false
    @Published private(set) var usesCellular = false
    var isConnected: Bool { status == .available }
    private var monitor: NWPathMonitor?
    private var settleTask: Task<Void, Never>?
    private var generation: UInt = 0
    private var isLive = true
    private let settleDuration: Duration
    private let retry: @Sendable () async throws -> Void
    private var observation: Observation?
    private struct Observation: Equatable {
        let status: Status
        let wifi: Bool
        let cellular: Bool
    }

    init(
        monitorConnectivity: Bool = true, settleDuration: Duration = .milliseconds(500),
        retry: @escaping @Sendable () async throws -> Void
    ) {
        self.retry = retry
        self.settleDuration = settleDuration
        if monitorConnectivity {
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let status: Status
                switch path.status {
                case .satisfied: status = .available
                case .requiresConnection: status = .connecting
                case .unsatisfied:
                    status = path.unsatisfiedReason == .notAvailable ? .unavailable : .restricted
                @unknown default: status = .checking
                }
                let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                let cellular = path.usesInterfaceType(.cellular)
                Task { @MainActor [weak self] in
                    self?.update(status: status, wifiOrWired: wifi, cellular: cellular)
                }
            }
            monitor.start(queue: DispatchQueue(label: "Velacanto.Connectivity"))
        }
    }

    isolated deinit {
        monitor?.cancel()
        settleTask?.cancel()
    }

    func update(status: Status, wifiOrWired: Bool, cellular: Bool) {
        guard isLive else { return }
        let next = Observation(status: status, wifi: wifiOrWired, cellular: cellular)
        guard observation != next else { return }
        observation = next
        generation &+= 1
        settleTask?.cancel()
        usesWiFiOrWired = wifiOrWired
        usesCellular = cellular
        if status == .unavailable || status == .restricted {
            let epoch = generation
            let delay = settleDuration
            settleTask = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.isLive, self.generation == epoch else { return }
                self.publish(status)
            }
        } else {
            publish(status)
        }
    }

    private func publish(_ next: Status) {
        status = next
        localOnly = next == .unavailable || next == .restricted
        switch next {
        case .checking: statusMessage = "Checking connection…"
        case .connecting: statusMessage = "Connecting. Downloaded music remains available."
        case .available: statusMessage = nil
        case .unavailable:
            statusMessage =
                "Offline. Downloaded music is in Library."
        case .restricted:
            statusMessage =
                "Network access is restricted. Downloaded music is in Library."
        }
    }

    func retryOnline() async {
        guard isLive, !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        let epoch = generation
        do {
            try await retry()
            guard isLive, epoch == generation else { return }
            settleTask?.cancel()
            publish(.available)
            successfulRetryRevision += 1
        } catch is CancellationError {
            return
        } catch {
            guard isLive, epoch == generation else { return }
            statusMessage = "Server unavailable. Downloaded music is in Library."
        }
    }

    func invalidate() {
        isLive = false
        generation &+= 1
        monitor?.cancel()
        settleTask?.cancel()
    }
}
