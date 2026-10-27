@preconcurrency import CloudKit
import CryptoKit
import Foundation

/// Private database only; construction requires the reviewed container identifier.
/// No default container, capability creation, account login or background retry occurs.
actor FoundationPinSyncCloud {
    enum Failure: Error { case unavailable, accountChanged, conflict }
    struct Result: Sendable {
        let state: FoundationPinSyncState
        let account: String
        let reset: Bool
    }
    private let container: CKContainer

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    func exchange(
        scope: String, local: FoundationPinSyncState?, initial: [FoundationPinSyncState.Identity],
        device: UUID, expectedAccount: String?, erase: Bool = false
    ) async throws -> Result {
        _ = try FoundationPinSyncState(scope: scope).validated()
        try Task.checkCancellation()
        guard try await container.accountStatus() == .available else { throw Failure.unavailable }
        try Task.checkCancellation()
        let user = try await container.userRecordID()
        try Task.checkCancellation()
        let identity = SHA256.hash(data: Data(user.recordName.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard expectedAccount == nil || expectedAccount == identity else {
            throw Failure.accountChanged
        }
        let database = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: "pins-v1-" + scope)
        // A single bounded compare-and-save retry, never a periodic retry loop.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let record: CKRecord
            do { record = try await database.record(for: id) } catch let error as CKError
                where error.code == .unknownItem
            {
                record = CKRecord(recordType: "VelaCantoPinsV1", recordID: id)
            }
            guard record.recordType == "VelaCantoPinsV1" else {
                throw FoundationPinSyncState.Failure.invalid
            }
            let remote: FoundationPinSyncState
            if let data = record["payload"] as? Data {
                guard data.count <= FoundationPinSyncState.maximumBytes else {
                    throw FoundationPinSyncState.Failure.invalid
                }
                remote = try JSONDecoder().decode(FoundationPinSyncState.self, from: data)
                    .validated()
                guard remote.scope == scope else { throw FoundationPinSyncState.Failure.invalid }
            } else if record.recordChangeTag == nil {
                remote = FoundationPinSyncState(scope: scope, epoch: local?.epoch ?? UUID())
            } else {
                throw FoundationPinSyncState.Failure.invalid
            }
            var updated = remote
            let reset = local != nil && local?.epoch != remote.epoch
            if erase {
                updated = FoundationPinSyncState(scope: scope)
            } else if let local, !reset {
                updated = try remote.merging(local)
            } else if local == nil {
                try updated.migrate(initial, device: device)
            }
            // An old epoch is never uploaded, even if the offline device has newer edits.
            if reset && !erase { return Result(state: remote, account: identity, reset: true) }
            let payload = try JSONEncoder().encode(updated.validated())
            record["payload"] = payload as CKRecordValue
            try Task.checkCancellation()
            guard try await container.userRecordID() == user else { throw Failure.accountChanged }
            try Task.checkCancellation()
            do {
                let result = try await database.modifyRecords(
                    saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged,
                    atomically: true)
                guard let saved = result.saveResults[id] else { throw Failure.unavailable }
                _ = try saved.get()
                try Task.checkCancellation()
                guard try await container.userRecordID() == user else {
                    throw Failure.accountChanged
                }
                return Result(state: updated, account: identity, reset: false)
            } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 {
                continue
            }
        }
        throw Failure.conflict
    }
}
