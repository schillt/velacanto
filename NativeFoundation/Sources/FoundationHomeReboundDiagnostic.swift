#if DEBUG
    import Foundation
    import SwiftUI
    #if os(iOS)
        import UIKit
    #endif

    enum FoundationHomeReboundEvent: String, Codable, Sendable, CaseIterable {
        case homeEntered, homeLeft, phase, geometry, tracker, pointRequest
        case accessory, viewport, content, clearance, nativeViewport, expired
    }

    struct FoundationHomeClearanceDiagnostic: Equatable {
        let host: CGRect?
        let accessory: FoundationBottomChromeMeasurement?
        let nativeBottomInset: CGFloat?
        let reserve: CGFloat
        let hasQueue: Bool
        var nativeAtEnd = false
        var correctionCount = 0
        var naturalHeight: CGFloat?
        var offeredViewport: CGRect?
        var boundedHeight: CGFloat?

        var evidenceDescription: String {
            let measured = host != nil && accessory != nil && nativeBottomInset != nil
            return "measured=\(measured) hostBottom=\(host?.maxY ?? .nan)"
                + " accessoryTop=\(accessory?.frame.minY ?? .nan)"
                + " nativeBottomInset=\(nativeBottomInset ?? .nan) reserve=\(reserve)"
                + " placement=\(String(describing: accessory?.placement)) queue=\(hasQueue)"
                + " nativeAtEnd=\(nativeAtEnd) correctionCount=\(correctionCount)"
                + " naturalHeight=\(naturalHeight ?? .nan)"
                + " offeredBottom=\(offeredViewport?.maxY ?? .nan)"
                + " boundedHeight=\(boundedHeight ?? .nan)"
        }
    }

    enum FoundationHomeDeferredStage: Int {
        case scheduled = 1
        case cancelled, alreadyAtEnd
    }

    enum FoundationHomeReboundReason: String, Codable, Sendable, CaseIterable {
        case newInteraction, programmaticAnimation, programmaticIdle, contentChanged
        case widthChanged, topChanged, interactingReverse, pendingInvalidated
        case idleCandidateConsumed, idleCandidateRejected, idleDirectTarget, idleDirectRejected
        case inactivePhase, gestureRelinquished, noPriorEnd, viewportNotShrunk, bottomInsetDecreased
        case candidateArmed, candidateOffsetRejected, candidateRetained, trackingStarted
    }

    enum FoundationHomeReboundPhase: String, Codable, Sendable, CaseIterable {
        case idle, tracking, interacting, decelerating, animating, unknown

        init(_ phase: ScrollPhase) {
            switch phase {
            case .idle: self = .idle
            case .tracking: self = .tracking
            case .interacting: self = .interacting
            case .decelerating: self = .decelerating
            case .animating: self = .animating
            @unknown default: self = .unknown
            }
        }
    }

    enum FoundationHomeReboundPlacement: String, Codable, Sendable, CaseIterable {
        case normal, minimized, unknown
    }

    struct FoundationHomeReboundRecord: Codable, Sendable {
        var milliseconds: Int = 0
        var gesture: Int = 0
        let event: FoundationHomeReboundEvent
        var reason: FoundationHomeReboundReason?
        var phase: FoundationHomeReboundPhase?
        var previousPhase: FoundationHomeReboundPhase?
        var placement: FoundationHomeReboundPlacement?
        var previousGeometry: [String: Double]?
        var geometry: [String: Double]?
        var facts: [String: Double]?
    }

    struct FoundationHomeReboundSnapshot: Codable, Sendable {
        var schema = 3
        let build: Int
        let version: [Int]
        let os: [Int]
        var expired = false
        var evictedRecords = 0
        var sampledGeometry = 0
        var encodingEvictions = 0
        var recordLimit = FoundationHomeReboundBuffer.maximumRecords
        var gestureLimit = FoundationHomeReboundBuffer.maximumGestures
        var secondsLimit = FoundationHomeReboundBuffer.maximumSeconds
        var byteLimit = FoundationHomeReboundBuffer.maximumBytes
        var records: [FoundationHomeReboundRecord] = []
    }

    /// Fixed diagnostic window, not an observable model or a general logging channel.
    struct FoundationHomeReboundBuffer {
        static let maximumRecords = 1_024
        static let maximumGestures = 4
        static let maximumSeconds: TimeInterval = 300
        static let maximumBytes = 1_048_576
        private(set) var snapshot: FoundationHomeReboundSnapshot
        private var lastSampleTimes: [FoundationHomeReboundEvent: TimeInterval] = [:]
        private var gesture = 0

        init(build: Int, version: [Int], os: [Int]) {
            snapshot = .init(build: build, version: version, os: os)
        }

        mutating func append(
            _ input: FoundationHomeReboundRecord, elapsed: TimeInterval, critical: Bool = true,
            newGesture: Bool = false
        ) {
            guard !snapshot.expired else { return }
            guard elapsed.isFinite else { return }
            if elapsed >= Self.maximumSeconds {
                snapshot.expired = true
                var end = FoundationHomeReboundRecord(event: .expired)
                end.milliseconds = Int(Self.maximumSeconds * 1_000)
                end.gesture = gesture
                retain(end)
                return
            }
            if newGesture { gesture += 1 }
            if !critical, elapsed - (lastSampleTimes[input.event] ?? -.infinity) < 1 / 30 {
                snapshot.sampledGeometry += 1
                return
            }
            if !critical { lastSampleTimes[input.event] = elapsed }
            var record = input
            record.milliseconds = Int(max(0, elapsed) * 1_000)
            record.gesture = gesture
            retain(record)
        }

        private mutating func retain(_ record: FoundationHomeReboundRecord) {
            snapshot.records.append(record)
            let minimumGesture = max(0, gesture - Self.maximumGestures + 1)
            let oldCount = snapshot.records.count
            snapshot.records.removeAll { $0.gesture < minimumGesture }
            if snapshot.records.count > Self.maximumRecords {
                snapshot.records.removeFirst(snapshot.records.count - Self.maximumRecords)
            }
            snapshot.evictedRecords += oldCount - snapshot.records.count
        }
    }

    /// At most one in-flight write and one coalesced pending snapshot. All encoding/I/O
    /// occurs on the utility queue, outside the small handoff lock.
    final class FoundationHomeReboundWriter: @unchecked Sendable {
        private let queue = DispatchQueue(label: "velacanto.home-rebound-private", qos: .utility)
        private let lock = NSLock()
        private let directory: URL
        private var pending: FoundationHomeReboundSnapshot?
        private var running = false

        init(directory: URL) { self.directory = directory }

        func submit(_ snapshot: FoundationHomeReboundSnapshot) {
            lock.lock()
            pending = snapshot
            let start = !running
            running = true
            lock.unlock()
            if start { queue.async { self.drain() } }
        }

        private func drain() {
            while true {
                lock.lock()
                let next = pending
                pending = nil
                if next == nil { running = false }
                lock.unlock()
                guard var snapshot = next else { return }
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    var data = try encoder.encode(snapshot)
                    while data.count > FoundationHomeReboundBuffer.maximumBytes,
                        !snapshot.records.isEmpty
                    {
                        let count = max(1, snapshot.records.count / 4)
                        snapshot.records.removeFirst(count)
                        snapshot.encodingEvictions += count
                        data = try encoder.encode(snapshot)
                    }
                    guard data.count <= FoundationHomeReboundBuffer.maximumBytes else { continue }
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    var protectedDirectory = directory
                    try protectedDirectory.setResourceValues(values)
                    let file = directory.appendingPathComponent("current.json")
                    #if os(iOS)
                        try data.write(
                            to: file,
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    #else
                        try data.write(to: file, options: .atomic)
                    #endif
                } catch {
                    // Diagnostics never alter scrolling, playback, or account outcomes.
                    // Error descriptions/paths may contain private values and are not logged.
                }
            }
        }

        func waitUntilIdleForTests() { queue.sync {} }
    }

    @MainActor
    final class FoundationHomeReboundDiagnostic {
        static let argument = "-diagnosticHomeRebound"
        static func isRequested(arguments: [String]) -> Bool { arguments.contains(argument) }
        static let shared: FoundationHomeReboundDiagnostic? = {
            #if os(iOS)
                guard isRequested(arguments: ProcessInfo.processInfo.arguments),
                    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                        .first
                else { return nil }
                let info = Bundle.main.infoDictionary ?? [:]
                let version = (info["CFBundleShortVersionString"] as? String ?? "")
                    .split(separator: ".").compactMap { Int($0) }
                let os = ProcessInfo.processInfo.operatingSystemVersion
                return FoundationHomeReboundDiagnostic(
                    buffer: .init(
                        build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
                        version: version, os: [os.majorVersion, os.minorVersion, os.patchVersion]),
                    writer: .init(directory: cache.appendingPathComponent("HomeReboundDiagnostics"))
                )
            #else
                return nil
            #endif
        }()

        private var buffer: FoundationHomeReboundBuffer
        private let writer: FoundationHomeReboundWriter
        private var started: TimeInterval?
        private var active = false
        private var lastReason: FoundationHomeReboundReason?
        private var placement = FoundationHomeReboundPlacement.unknown
        private var accessoryFrame: [String: Double]?
        private var lastClearance: FoundationHomeClearanceDiagnostic?
        private var accessoryMeasuredAt: TimeInterval?
        private var measuredFrames:
            [FoundationHomeReboundEvent: (values: [String: Double], time: TimeInterval)] = [:]
        #if os(iOS)
            private weak var nativeScrollView: UIScrollView?
            private var nativeWasFound = false
            private var nativeIdentityConsistent = true
            private var lastNativeFacts: [String: Double]?
        #endif
        private var observedPhase = FoundationHomeReboundPhase.idle
        private var idleFlush: Task<Void, Never>?

        init(buffer: FoundationHomeReboundBuffer, writer: FoundationHomeReboundWriter) {
            self.buffer = buffer
            self.writer = writer
        }

        func homeActive(_ value: Bool) {
            guard !buffer.snapshot.expired else { return }
            if value, started == nil {
                started = ProcessInfo.processInfo.systemUptime
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(FoundationHomeReboundBuffer.maximumSeconds))
                    self?.expire()
                }
            }
            active = value
            if !value { idleFlush?.cancel() }
            record(.init(event: value ? .homeEntered : .homeLeft, placement: placement))
            if value {
                let now = ProcessInfo.processInfo.systemUptime
                if let lastClearance { recordClearance(lastClearance) }
                recordNativeViewport(critical: true)
                for (event, measurement) in measuredFrames {
                    var values = measurement.values
                    values["measurementAgeMs"] = max(0, now - measurement.time) * 1_000
                    record(.init(event: event, placement: placement, facts: values))
                }
                if var values = accessoryFrame, let time = accessoryMeasuredAt {
                    values["measurementAgeMs"] = max(0, now - time) * 1_000
                    record(.init(event: .accessory, placement: placement, facts: values))
                }
            }
            flush()
        }

        func phase(
            from previous: ScrollPhase, to current: ScrollPhase, geometry: ScrollGeometry
        ) {
            guard isRecording else { return }
            observedPhase = .init(current)
            if current != .idle { idleFlush?.cancel() }
            let newGesture =
                current == .tracking
                || (current == .interacting && previous != .tracking && previous != .interacting)
            record(
                .init(
                    event: .phase, phase: .init(current), previousPhase: .init(previous),
                    placement: placement, geometry: Self.metrics(geometry)), newGesture: newGesture)
            recordNativeViewport(critical: true)
        }

        func phaseFinished(_ phase: ScrollPhase) {
            guard isRecording, phase == .idle else { return }
            idleFlush?.cancel()
            idleFlush = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                self?.flush()
            }
        }

        func geometry(from previous: ScrollGeometry, to current: ScrollGeometry) {
            guard isRecording else { return }
            let critical =
                previous.contentSize != current.contentSize
                || previous.containerSize != current.containerSize
                || previous.contentInsets != current.contentInsets
            record(
                .init(
                    event: .geometry, phase: observedPhase, placement: placement,
                    previousGeometry: Self.metrics(previous), geometry: Self.metrics(current)),
                critical: critical)
            recordNativeViewport(critical: critical)
            if critical, observedPhase == .idle { flush() }
        }

        func tracker(
            _ reason: FoundationHomeReboundReason, phase: ScrollPhase,
            previous: FoundationScrollEndGeometry?, current: FoundationScrollEndGeometry,
            facts: [String: Double], target: CGFloat? = nil
        ) {
            guard isRecording else { return }
            let changed = lastReason != reason || target != nil
            lastReason = reason
            var values = facts.filter { $0.value.isFinite }
            if let target { values["targetY"] = Double(target) }
            record(
                .init(
                    event: .tracker, reason: reason, phase: .init(phase), placement: placement,
                    previousGeometry: previous.map(Self.metrics), geometry: Self.metrics(current),
                    facts: values), critical: changed)
        }

        func clearance(_ value: FoundationHomeClearanceDiagnostic) {
            guard !buffer.snapshot.expired else { return }
            let changed = lastClearance != value
            lastClearance = value
            guard isRecording, changed else { return }
            recordClearance(value)
            recordNativeViewport(critical: true)
            if observedPhase == .idle { flush() }
        }

        private func recordClearance(_ value: FoundationHomeClearanceDiagnostic) {
            var facts: [String: Double] = [
                "hostMeasured": value.host == nil ? 0 : 1,
                "accessoryMeasured": value.accessory == nil ? 0 : 1,
                "nativeBottomMeasured": value.nativeBottomInset == nil ? 0 : 1,
                "reserve": Double(value.reserve), "hasQueue": value.hasQueue ? 1 : 0,
                "nativeAtEnd": value.nativeAtEnd ? 1 : 0,
                "correctionCount": Double(value.correctionCount),
            ]
            if let host = value.host {
                for (key, number) in Self.metrics(host) { facts["host_" + key] = number }
                facts["hostBottom"] = Double(host.maxY)
            }
            if let accessory = value.accessory {
                for (key, number) in Self.metrics(accessory.frame) {
                    facts["accessory_" + key] = number
                }
                facts["accessoryTop"] = Double(accessory.frame.minY)
            }
            if let inset = value.nativeBottomInset { facts["nativeBottomInset"] = Double(inset) }
            if let height = value.naturalHeight { facts["naturalHeight"] = Double(height) }
            if let offered = value.offeredViewport {
                for (key, number) in Self.metrics(offered) { facts["offered_" + key] = number }
            }
            if let height = value.boundedHeight { facts["boundedHeight"] = Double(height) }
            let placement: FoundationHomeReboundPlacement =
                value.accessory?.placement == .normal
                ? .normal
                : value.accessory?.placement == .minimized ? .minimized : .unknown
            record(
                .init(
                    event: .clearance, placement: placement,
                    facts: facts.filter { $0.value.isFinite }))
        }

        func nativeDeferred(_ stage: FoundationHomeDeferredStage, targetY: CGFloat, count: Int) {
            guard isRecording else { return }
            record(
                .init(
                    event: .pointRequest, phase: observedPhase, placement: placement,
                    facts: [
                        "nativeApplied": 0, "deferredStage": Double(stage.rawValue),
                        "scheduledCount": Double(count), "targetY": Double(targetY),
                    ]), critical: true)
            recordNativeViewport(critical: true)
            flush()
        }

        func nativeCorrection(targetY: CGFloat, count: Int) {
            guard isRecording else { return }
            record(
                .init(
                    event: .pointRequest, phase: observedPhase, placement: placement,
                    facts: [
                        "nativeApplied": 1, "targetY": Double(targetY),
                        "correctionCount": Double(count),
                    ]), critical: true)
            recordNativeViewport(critical: true)
            flush()
        }

        #if os(iOS)
            func attachNativeScrollView(_ value: UIScrollView?) {
                guard !buffer.snapshot.expired else { return }
                if let value {
                    if nativeWasFound, nativeScrollView !== value {
                        nativeIdentityConsistent = false
                    }
                    nativeWasFound = true
                }
                nativeScrollView = value
            }
        #endif

        private func recordNativeViewport(critical: Bool) {
            #if os(iOS)
                guard isRecording else { return }
                let facts = FoundationHomeNativeScrollSnapshot.facts(
                    nativeScrollView, identityConsistent: nativeIdentityConsistent)
                guard critical || facts != lastNativeFacts else { return }
                lastNativeFacts = facts
                record(
                    .init(
                        event: .nativeViewport, phase: observedPhase,
                        placement: placement, facts: facts), critical: critical)
            #endif
        }

        func accessory(_ value: FoundationHomeReboundPlacement, frame: CGRect? = nil) {
            guard !buffer.snapshot.expired else { return }
            let changed = placement != value
            placement = value
            if changed, frame == nil {
                accessoryFrame = nil
                accessoryMeasuredAt = nil
            }
            if let frame {
                accessoryFrame = Self.metrics(frame)
                accessoryMeasuredAt = ProcessInfo.processInfo.systemUptime
            }
            guard isRecording else { return }
            record(
                .init(event: .accessory, placement: placement, facts: accessoryFrame),
                critical: changed)
            if changed { flush() }
        }

        func frame(_ frame: CGRect, event: FoundationHomeReboundEvent) {
            guard !buffer.snapshot.expired, event == .viewport || event == .content else { return }
            measuredFrames[event] = (Self.metrics(frame), ProcessInfo.processInfo.systemUptime)
            guard isRecording else { return }
            record(
                .init(event: event, placement: placement, facts: Self.metrics(frame)),
                critical: false)
        }

        func pointRequest(_ target: CGFloat, phase: ScrollPhase) {
            guard isRecording, target.isFinite else { return }
            record(
                .init(event: .pointRequest, phase: .init(phase), facts: ["targetY": Double(target)])
            )
        }

        private func record(
            _ record: FoundationHomeReboundRecord, critical: Bool = true, newGesture: Bool = false
        ) {
            guard let started, active || record.event == .homeLeft else { return }
            let wasExpired = buffer.snapshot.expired
            buffer.append(
                record, elapsed: ProcessInfo.processInfo.systemUptime - started,
                critical: critical, newGesture: newGesture)
            if !wasExpired, buffer.snapshot.expired { flush() }
        }

        private func expire() {
            guard started != nil else { return }
            idleFlush?.cancel()
            buffer.append(
                .init(event: .expired), elapsed: FoundationHomeReboundBuffer.maximumSeconds)
            flush()
            active = false
        }

        private var isRecording: Bool { active && started != nil && !buffer.snapshot.expired }

        private func flush() {
            guard started != nil else { return }
            writer.submit(buffer.snapshot)
        }

        private static func finite(_ values: [String: CGFloat]) -> [String: Double] {
            values.filter { $0.value.isFinite }.mapValues { Double($0) }
        }

        private static func metrics(_ frame: CGRect) -> [String: Double] {
            finite([
                "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
            ])
        }

        private static func metrics(_ geometry: FoundationScrollEndGeometry) -> [String: Double] {
            finite([
                "offsetY": geometry.contentOffsetY, "contentWidth": geometry.contentSize.width,
                "contentHeight": geometry.contentSize.height,
                "containerWidth": geometry.containerSize.width,
                "containerHeight": geometry.containerSize.height,
                "top": geometry.insetTop, "bottom": geometry.insetBottom,
                "visibleMaxY": geometry.visibleMaxY, "unobscuredBottom": geometry.unobscuredBottom,
            ])
        }

        private static func metrics(_ geometry: ScrollGeometry) -> [String: Double] {
            var values = metrics(FoundationScrollEndGeometry(geometry))
            values["offsetX"] = Double(geometry.contentOffset.x)
            values["leading"] = Double(geometry.contentInsets.leading)
            values["trailing"] = Double(geometry.contentInsets.trailing)
            for (key, value) in metrics(geometry.bounds) { values["bounds_" + key] = value }
            for (key, value) in metrics(geometry.visibleRect) { values["visible_" + key] = value }
            return values.filter { $0.value.isFinite }
        }
    }

    #if os(iOS)
        /// Observation only. No delegate, inset, offset or native view mutation.
        enum FoundationHomeNativeScrollSnapshot {
            @MainActor static func facts(
                _ scroll: UIScrollView?, identityConsistent: Bool
            ) -> [String: Double] {
                var values: [String: Double] = [
                    "found": scroll == nil ? 0 : 1,
                    "identityConsistent": identityConsistent ? 1 : 0,
                ]
                guard let scroll else { return values }
                func rectangle(_ prefix: String, _ rect: CGRect) {
                    values[prefix + "X"] = Double(rect.minX)
                    values[prefix + "Y"] = Double(rect.minY)
                    values[prefix + "Width"] = Double(rect.width)
                    values[prefix + "Height"] = Double(rect.height)
                }
                func insets(_ prefix: String, _ inset: UIEdgeInsets) {
                    values[prefix + "Top"] = Double(inset.top)
                    values[prefix + "Bottom"] = Double(inset.bottom)
                    values[prefix + "Left"] = Double(inset.left)
                    values[prefix + "Right"] = Double(inset.right)
                }
                rectangle("bounds", scroll.bounds)
                insets("contentInset", scroll.contentInset)
                insets("adjustedInset", scroll.adjustedContentInset)
                values["offsetX"] = Double(scroll.contentOffset.x)
                values["offsetY"] = Double(scroll.contentOffset.y)
                values["contentWidth"] = Double(scroll.contentSize.width)
                values["contentHeight"] = Double(scroll.contentSize.height)
                values["dragging"] = scroll.isDragging ? 1 : 0
                values["decelerating"] = scroll.isDecelerating ? 1 : 0
                values["inWindow"] = scroll.window == nil ? 0 : 1
                let minimum = -scroll.adjustedContentInset.top
                values["legalMinY"] = Double(minimum)
                values["legalMaxY"] = Double(
                    max(
                        minimum,
                        scroll.contentSize.height - scroll.bounds.height
                            + scroll.adjustedContentInset.bottom))
                if let window = scroll.window {
                    rectangle("windowFrame", scroll.convert(scroll.bounds, to: window))
                }
                return values.filter { $0.value.isFinite }
            }
        }

        private struct FoundationHomeNativeScrollProbe: UIViewRepresentable {
            let recorder: FoundationHomeReboundDiagnostic

            func makeUIView(context: Context) -> FoundationHomeNativeScrollProbeView {
                let view = FoundationHomeNativeScrollProbeView()
                view.recorder = recorder
                view.isUserInteractionEnabled = false
                return view
            }

            func updateUIView(_ view: FoundationHomeNativeScrollProbeView, context: Context) {
                view.recorder = recorder
                view.connectIfNeeded()
            }
        }

        private final class FoundationHomeNativeScrollProbeView: UIView {
            weak var recorder: FoundationHomeReboundDiagnostic?
            private weak var nearestScrollView: UIScrollView?

            override func didMoveToSuperview() {
                super.didMoveToSuperview()
                nearestScrollView = nil
                connectIfNeeded()
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                nearestScrollView = nil
                connectIfNeeded()
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                if nearestScrollView == nil { connectIfNeeded() }
            }

            func connectIfNeeded() {
                if let nearestScrollView {
                    recorder?.attachNativeScrollView(nearestScrollView)
                    return
                }
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView {
                        nearestScrollView = scroll
                        recorder?.attachNativeScrollView(scroll)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }

        struct FoundationHomeReboundViewportProbe: ViewModifier {
            let isActive: Bool

            @ViewBuilder func body(content: Content) -> some View {
                if let recorder = FoundationHomeReboundDiagnostic.shared {
                    content
                        .onAppear { recorder.homeActive(isActive) }
                        .onChange(of: isActive) { _, value in recorder.homeActive(value) }
                        .onDisappear { recorder.homeActive(false) }
                        .onScrollGeometryChange(for: ScrollGeometry.self) {
                            $0
                        } action: { old, new in
                            recorder.geometry(from: old, to: new)
                        }
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .global)
                        } action: {
                            recorder.frame($0, event: .viewport)
                        }
                } else {
                    content
                }
            }
        }

        struct FoundationHomeReboundContentProbe: ViewModifier {
            @ViewBuilder func body(content: Content) -> some View {
                if let recorder = FoundationHomeReboundDiagnostic.shared {
                    content
                        .background(FoundationHomeNativeScrollProbe(recorder: recorder))
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .global)
                        } action: {
                            recorder.frame($0, event: .content)
                        }
                } else {
                    content
                }
            }
        }

        struct FoundationHomeReboundAccessoryProbe: ViewModifier {
            let placement: TabViewBottomAccessoryPlacement?

            private var value: FoundationHomeReboundPlacement {
                placement == .inline ? .minimized : placement == .expanded ? .normal : .unknown
            }

            @ViewBuilder func body(content: Content) -> some View {
                if let recorder = FoundationHomeReboundDiagnostic.shared {
                    content
                        .onAppear { recorder.accessory(value) }
                        .onChange(of: placement) { _, _ in recorder.accessory(value) }
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .global)
                        } action: {
                            recorder.accessory(value, frame: $0)
                        }
                } else {
                    content
                }
            }
        }
    #endif
#endif
