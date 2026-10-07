import SwiftUI

@MainActor
final class FoundationBrowseModel: ObservableObject {
    enum Request { case initial, refresh, more }
    @Published private(set) var items: [FoundationItem] = []
    @Published private(set) var nextStartIndex: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private(set) var loaded = false
    private var revision = UUID()
    private var pendingRequest = Request.initial
    private(set) var retryRequest = Request.initial

    /// Build only from already-loaded songs; preserve repeated occurrences.
    func trackQueue(selecting sourceIndex: Int) -> (items: [FoundationItem], index: Int)? {
        guard items.indices.contains(sourceIndex), items[sourceIndex].kind == .track else {
            return nil
        }
        return (
            items.filter { $0.kind == .track },
            items.prefix(sourceIndex).filter { $0.kind == .track }.count
        )
    }

    func request(_ request: Request) {
        revision = UUID()
        pendingRequest = request
    }

    func loadPending(
        ifActive isActive: Bool = true, using loader: (Int) async throws -> FoundationPage
    ) async {
        guard isActive, !Task.isCancelled else {
            #if DEBUG
                let disposition = isActive ? "cancelled-before-load" : "inactive"
                FoundationJournal.shared.record(
                    "browse disposition=\(disposition) \(FoundationTrace.fields)")
            #endif
            return
        }
        let request = pendingRequest
        pendingRequest = .initial
        await load(request, using: loader)
    }

    func load(_ request: Request, using loader: (Int) async throws -> FoundationPage) async {
        guard !Task.isCancelled else {
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=cancelled-before-load \(FoundationTrace.fields)")
            #endif
            return
        }
        if case .initial = request, loaded || errorMessage != nil {
            #if DEBUG
                let reason = loaded ? "loaded" : "error"
                FoundationJournal.shared.record(
                    "browse disposition=retained reason=\(reason) \(FoundationTrace.fields)")
            #endif
            return
        }
        let offset: Int
        if case .more = request {
            guard let nextStartIndex else {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "browse disposition=retained reason=complete \(FoundationTrace.fields)")
                #endif
                return
            }
            offset = nextStartIndex
        } else {
            offset = 0
        }
        if case .initial = request { retryRequest = .refresh } else { retryRequest = request }
        let owner = UUID()
        revision = owner
        isLoading = true
        errorMessage = nil
        defer { if revision == owner { isLoading = false } }
        #if DEBUG
            FoundationJournal.shared.record(
                "browse disposition=\(String(describing: request)) \(FoundationTrace.fields)")
        #endif
        do {
            let page = try await loader(offset)
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=load-returned result=success \(FoundationTrace.fields)")
            #endif
            guard !Task.isCancelled, revision == owner else {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "browse disposition=publication-discarded \(FoundationTrace.fields)")
                #endif
                return
            }
            if case .more = request {
                items.append(contentsOf: page.items)
            } else {
                items = page.items
            }
            nextStartIndex = page.nextStartIndex
            loaded = true
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=publication-committed \(FoundationTrace.fields)")
            #endif
        } catch {
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=load-returned result=failure \(FoundationTrace.fields)")
            #endif
            guard !Task.isCancelled, revision == owner else {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "browse disposition=publication-discarded \(FoundationTrace.fields)")
                #endif
                return
            }
            errorMessage = FoundationLibraryError.category(error).errorDescription
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=failure \(FoundationTrace.fields)")
            #endif
        }
    }
}
