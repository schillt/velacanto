import Foundation

/// The wire format deliberately has no title, artwork, URL, credential or local path fields.
struct FoundationPinSyncState: Codable, Equatable, Sendable {
    static let maximumEntries = 2_048
    static let maximumBytes = 512_000

    struct Identity: Codable, Hashable, Comparable, Sendable {
        let id: String
        let kind: String
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.kind == rhs.kind ? lhs.id < rhs.id : lhs.kind < rhs.kind
        }
        var valid: Bool {
            !id.isEmpty && id.utf8.count <= 512
                && ["album", "artist", "playlist", "genre"].contains(kind)
        }
    }

    struct Stamp: Codable, Equatable, Comparable, Sendable {
        let counter: UInt64
        let device: UUID
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.counter == rhs.counter
                ? lhs.device.uuidString < rhs.device.uuidString : lhs.counter < rhs.counter
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        let identity: Identity
        var addition: Stamp
        var observedRemovals: [String: UInt64] = [:]
        var removals: [String: UInt64] = [:]
        var isPresent: Bool { observedRemovals == removals }
    }

    enum Failure: Error { case invalid, capacity, epochChanged }
    let version: Int
    let scope: String
    let epoch: UUID
    var entries: [Entry]
    var order: [Identity]
    var orderStamp: Stamp?

    init(scope: String, epoch: UUID = UUID()) {
        version = 1
        self.scope = scope
        self.epoch = epoch
        entries = []
        order = []
    }

    func validated() throws -> Self {
        guard version == 1, scope.count == 64, scope.allSatisfy({ $0.isHexDigit }),
            entries.count <= Self.maximumEntries, order.count <= Self.maximumEntries,
            entries.allSatisfy({ entry in
                entry.identity.valid && entry.removals.count <= 32
                    && entry.observedRemovals.count <= 32
                    && entry.removals.keys.allSatisfy { UUID(uuidString: $0) != nil }
                    && entry.observedRemovals.keys.allSatisfy { UUID(uuidString: $0) != nil }
            }),
            Set(entries.map(\.identity)).count == entries.count,
            Set(order).count == order.count,
            order.allSatisfy({ identity in entries.contains { $0.identity == identity } }),
            try JSONEncoder().encode(self).count <= Self.maximumBytes
        else { throw Failure.invalid }
        return self
    }

    var pins: [Identity] {
        let present = Set(entries.filter(\.isPresent).map(\.identity))
        return order.filter { present.contains($0) } + present.subtracting(order).sorted()
    }

    private func nextStamp(device: UUID) throws -> Stamp {
        let counters: [UInt64] =
            entries.flatMap { entry -> [UInt64] in
                [entry.addition.counter] + Array(entry.removals.values)
                    + Array(entry.observedRemovals.values)
            } + [orderStamp?.counter ?? 0]
        let maximum = counters.max() ?? 0
        guard maximum < UInt64.max else { throw Failure.capacity }
        return Stamp(counter: maximum + 1, device: device)
    }

    /// Call only for an explicit local membership/order change. Initial migration passes
    /// only identities never seen in the cloud, so stale snapshots cannot undo tombstones.
    mutating func edit(_ desired: [Identity], device: UUID) throws {
        guard desired.count <= Self.maximumEntries, Set(desired).count == desired.count,
            desired.allSatisfy(\.valid)
        else { throw Failure.invalid }
        var updated = self
        let stamp = try nextStamp(device: device)
        let wanted = Set(desired)
        for index in updated.entries.indices {
            if wanted.contains(updated.entries[index].identity) {
                if !updated.entries[index].isPresent {
                    updated.entries[index].addition = stamp
                    updated.entries[index].observedRemovals = updated.entries[index].removals
                }
            } else if updated.entries[index].isPresent {
                updated.entries[index].removals[device.uuidString] = stamp.counter
            }
        }
        let known = Set(updated.entries.map(\.identity))
        updated.entries += desired.filter { !known.contains($0) }.map {
            Entry(identity: $0, addition: stamp)
        }
        updated.order = desired
        updated.orderStamp = stamp
        self = try updated.validated()
    }

    mutating func migrate(_ local: [Identity], device: UUID) throws {
        let known = Set(entries.map(\.identity))
        let unseen = local.filter { !known.contains($0) }
        var seen = Set<Identity>()
        let desired = (pins + unseen).filter { seen.insert($0).inserted }
        if desired != pins { try edit(desired, device: device) }
    }

    func merging(_ other: Self) throws -> Self {
        _ = try validated()
        _ = try other.validated()
        guard scope == other.scope else { throw Failure.invalid }
        guard epoch == other.epoch else { throw Failure.epochChanged }
        var result = self
        var merged = Dictionary(uniqueKeysWithValues: entries.map { ($0.identity, $0) })
        for incoming in other.entries {
            guard var existing = merged[incoming.identity] else {
                merged[incoming.identity] = incoming
                continue
            }
            if existing.addition < incoming.addition {
                existing.addition = incoming.addition
                existing.observedRemovals = incoming.observedRemovals
            }
            for (device, counter) in incoming.removals {
                existing.removals[device] = max(existing.removals[device] ?? 0, counter)
            }
            merged[incoming.identity] = existing
        }
        result.entries = merged.values.sorted { $0.identity < $1.identity }
        if let stamp = other.orderStamp, orderStamp == nil || orderStamp! < stamp {
            result.orderStamp = stamp
            result.order = other.order
        }
        return try result.validated()
    }
}
