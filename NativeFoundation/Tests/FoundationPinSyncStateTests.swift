import XCTest
@testable import VelacantoFoundation

final class FoundationPinSyncStateTests: XCTestCase {
    typealias State = FoundationPinSyncState
    private let scope = String(repeating: "a", count: 64)
    private let deviceA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let deviceB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let a = State.Identity(id: "synthetic-a", kind: "album")
    private let b = State.Identity(id: "synthetic-b", kind: "artist")

    func testInitialMigrationMergesWithoutDuplicatesAndHonorsRemoval() throws {
        var cloud = State(scope: scope)
        try cloud.edit([a, b], device: deviceA)
        try cloud.edit([b], device: deviceA)
        try cloud.migrate([a, a, b], device: deviceB)
        XCTAssertEqual(cloud.pins, [b])
        XCTAssertEqual(cloud.entries.count, 2)
    }

    func testOfflineStaleAdditionCannotResurrectRemovedPinWithHigherUnrelatedClock() throws {
        var original = State(scope: scope)
        try original.edit([a], device: deviceA)
        var offline = original
        for _ in 0..<10 { try offline.edit([a, b], device: deviceB) }
        var removal = original
        try removal.edit([], device: deviceA)
        let left = try offline.merging(removal)
        let right = try removal.merging(offline)
        XCTAssertEqual(left.pins, [b])
        XCTAssertEqual(left, right)
        XCTAssertEqual(try left.merging(offline).pins, [b])
    }

    func testConcurrentRemoveAndOfflineRemoveReAddRemainRemoved() throws {
        var initial = State(scope: scope)
        try initial.edit([a], device: deviceA)
        var offline = initial
        try offline.edit([], device: deviceB)
        try offline.edit([a], device: deviceB)
        var online = initial
        try online.edit([], device: deviceA)
        XCTAssertTrue(try offline.merging(online).pins.isEmpty)
        XCTAssertTrue(try online.merging(offline).pins.isEmpty)
    }

    func testExplicitReAddAfterObservingRemovalIsAllowed() throws {
        var state = State(scope: scope)
        try state.edit([a], device: deviceA)
        try state.edit([], device: deviceA)
        let deleted = state
        try state.edit([a], device: deviceB)
        XCTAssertEqual(try state.merging(deleted).pins, [a])
    }

    func testConcurrentOrderingConvergesWithoutLosingIndependentPins() throws {
        var left = State(scope: scope)
        try left.edit([a], device: deviceA)
        var right = left
        try left.edit([a, b], device: deviceA)
        try right.edit([b, a], device: deviceB)
        XCTAssertEqual(try left.merging(right).pins, [b, a])
        XCTAssertEqual(try right.merging(left).pins, [b, a])
        XCTAssertEqual(try left.merging(right).merging(left).pins, [b, a])
    }

    func testCloudEraseEpochRejectsOldOfflineState() throws {
        var stale = State(scope: scope)
        try stale.edit([a], device: deviceA)
        let erased = State(scope: scope)
        XCTAssertThrowsError(try erased.merging(stale))
        XCTAssertTrue(erased.pins.isEmpty)
    }

    func testDifferentAuthorizedScopesCannotMerge() throws {
        let first = State(scope: scope)
        let second = State(scope: String(repeating: "b", count: 64), epoch: first.epoch)
        XCTAssertThrowsError(try first.merging(second))
    }

    func testBoundsAndUnknownKindAreRejectedWithoutMutatingState() throws {
        var state = State(scope: scope)
        try state.edit([a], device: deviceA)
        let prior = state
        XCTAssertThrowsError(try state.edit([.init(id: "bad", kind: "track")], device: deviceA))
        XCTAssertEqual(state, prior)
        let tooMany = (0...State.maximumEntries).map { State.Identity(id: "\($0)", kind: "album") }
        XCTAssertThrowsError(try state.edit(tooMany, device: deviceA))
        XCTAssertEqual(state, prior)
        XCTAssertThrowsError(try state.edit([a, a], device: deviceA))
    }

    func testWirePayloadOnlyContainsIdentityAndOrderingFields() throws {
        var state = State(scope: scope)
        try state.edit([a], device: deviceA)
        let data = try JSONEncoder().encode(state)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["title", "subtitle", "token", "url", "artwork", "path", "password"] {
            XCTAssertFalse(text.lowercased().contains(forbidden))
        }
        XCTAssertEqual(try JSONDecoder().decode(State.self, from: data).validated(), state)
    }
}
