import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationHandoffTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private let now: TimeInterval = 1_000

    func testCompleteQueueRoundTripPreservesDuplicateOccurrencesAndModes() throws {
        let original = payload()
        let restored = try FoundationHandoffPayload.decode(original.encoded())
        try restored.validate(scope: scope, now: now, expected: original.header)
        XCTAssertEqual(restored, original)
        let session = try XCTUnwrap(restored.session)
        XCTAssertEqual(session.entries.map(\.itemID), ["song", "song"])
        XCTAssertEqual(Set(session.entries.map(\.occurrence)).count, 2)
        XCTAssertEqual(session.selected, session.entries[1].occurrence)
        XCTAssertEqual(session.position, 73.25)
        XCTAssertTrue(session.shuffle)
        XCTAssertEqual(session.repeatMode, .all)
        XCTAssertFalse(session.wasPlaying)
    }

    func testRawQueueAndEffectiveVisibleSubsequenceRoundTripIndependently() throws {
        let original = payload()
        let entries = original.session!.entries
        let value = FoundationHandoffPayload(
            header: original.header,
            session: .init(
                entries: entries, selected: entries[1].occurrence, position: 5,
                shuffle: true, repeatMode: .one, wasPlaying: false,
                visibleOccurrences: [entries[1].occurrence]), destination: nil)
        let decoded = try FoundationHandoffPayload.decode(value.encoded())
        try decoded.validate(scope: scope, now: now)
        XCTAssertEqual(decoded.session?.entries, entries)
        XCTAssertEqual(decoded.session?.visibleOccurrences, [entries[1].occurrence])
    }

    func testMalformedEffectiveSubsequenceCannotApplyOrHideSelectedOccurrence() throws {
        let original = payload()
        let entries = original.session!.entries
        let malformed = [
            [entries[1].occurrence, entries[1].occurrence],
            [entries[1].occurrence, UUID()],
            [entries[1].occurrence, entries[0].occurrence],
            [entries[0].occurrence],
        ]
        for ids in malformed {
            let value = FoundationHandoffPayload(
                header: original.header,
                session: .init(
                    entries: entries, selected: entries[1].occurrence, position: 5,
                    shuffle: false, repeatMode: .off, wasPlaying: false,
                    visibleOccurrences: ids), destination: nil)
            XCTAssertThrowsError(try value.encoded())
        }
    }

    func testMaximumQueueTransfersEveryOccurrenceWithoutTruncation() throws {
        let entries = (0..<FoundationHandoffPayload.maximumEntries).map { index in
            FoundationHandoffPayload.Track(
                .init(
                    item: .init(
                        id: "song\(index)", title: "Song", subtitle: "", kind: .track,
                        duration: 200)))
        }
        let original = payload(entries: entries)
        let restored = try FoundationHandoffPayload.decode(original.encoded())
        try restored.validate(scope: scope, now: now)
        XCTAssertEqual(restored.session?.entries, entries)
    }

    func testOversizedQueueFailsRatherThanReturningAFirstPage() throws {
        let entry = payload().session!.entries[0]
        let entries = Array(repeating: entry, count: FoundationHandoffPayload.maximumEntries + 1)
        XCTAssertThrowsError(try payload(entries: entries).encoded()) {
            XCTAssertEqual($0 as? FoundationHandoffError, .tooLarge)
        }
    }

    func testAccountMismatchExpirationAndFutureTimestampAreRejected() throws {
        let header = payload().header
        XCTAssertThrowsError(try header.validate(scope: nil, now: now)) {
            XCTAssertEqual($0 as? FoundationHandoffError, .differentAccount)
        }
        XCTAssertThrowsError(
            try header.validate(scope: String(repeating: "b", count: 64), now: now))
        XCTAssertThrowsError(try header.validate(scope: scope, now: now + 301)) {
            XCTAssertEqual($0 as? FoundationHandoffError, .expired)
        }
        XCTAssertThrowsError(try header.validate(scope: scope, now: now - 31))
    }

    func testSourceDisplayDataBudgetRejectsOversizeWithoutTruncatingOccurrences() throws {
        let entries = (0..<FoundationHandoffPayload.maximumEntries).map { index in
            FoundationHandoffPayload.Track(
                .init(
                    item: .init(
                        id: "song\(index)", title: String(repeating: "x", count: 4_096),
                        subtitle: "", kind: .track, duration: 200)))
        }
        let value = payload(entries: entries)
        XCTAssertThrowsError(try value.encoded()) {
            XCTAssertEqual($0 as? FoundationHandoffError, .tooLarge)
        }
        XCTAssertEqual(value.session?.entries.count, FoundationHandoffPayload.maximumEntries)
    }

    func testActivityBindingRejectsAnotherTransferOrKind() throws {
        let value = payload()
        let other = FoundationHandoffPayload.Header(scope: scope, kind: .playback, createdAt: now)
        XCTAssertThrowsError(try value.validate(scope: scope, now: now, expected: other)) {
            XCTAssertEqual($0 as? FoundationHandoffError, .changed)
        }
    }

    func testUnknownVersionAndMalformedHeaderAreRejected() throws {
        let data = try payload().header.encoded()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 3
        let future = try FoundationHandoffPayload.Header.decode(
            JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try future.validate(scope: scope, now: now)) {
            XCTAssertEqual($0 as? FoundationHandoffError, .unsupported)
        }
        XCTAssertThrowsError(try FoundationHandoffPayload.Header.decode(Data([255])))
        XCTAssertThrowsError(
            try FoundationHandoffPayload.Header.decode(
                Data(repeating: 1, count: FoundationHandoffPayload.maximumHeaderBytes + 1)))
    }

    func testLegacyPeerWithoutReadinessClockProtocolIsExplicitlyUnsupported() throws {
        let data = try payload().header.encoded()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 1
        let legacy = try FoundationHandoffPayload.Header.decode(
            JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try legacy.validate(scope: scope, now: now)) {
            XCTAssertEqual($0 as? FoundationHandoffError, .unsupported)
        }
    }

    func testGenericSourceDeviceLabelRoundTripsAndIsBoundToTheOffer() throws {
        let original = payload()
        let header = FoundationHandoffPayload.Header(
            id: original.header.id, scope: scope, kind: .playback, createdAt: now,
            sourceDevice: .phone)
        let value = FoundationHandoffPayload(
            header: header, session: original.session, destination: nil)
        let restored = try FoundationHandoffPayload.decode(value.encoded())
        XCTAssertEqual(restored.header.sourceDevice?.displayName, "iPhone")
        let changedLabel = FoundationHandoffPayload.Header(
            id: header.id, scope: scope, kind: .playback, createdAt: now, sourceDevice: .mac)
        XCTAssertThrowsError(try restored.validate(scope: scope, now: now, expected: changedLabel))
        XCTAssertNil(
            try FoundationHandoffPayload.Header.decode(original.header.encoded()).sourceDevice)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: header.encoded()) as? [String: Any])
        XCTAssertEqual(json["sourceDevice"] as? String, "phone")
        XCTAssertNil(json["deviceName"])
        XCTAssertNil(json["deviceIdentifier"])
    }

    func testSmallControlMessagesValidatePositionAndCannotMasqueradeAsNativeStart() throws {
        let transfer = UUID()
        let occurrence = UUID()
        let nonce = UUID()
        for kind in [FoundationHandoffControl.Kind.authorize, .authorized, .position] {
            let value = FoundationHandoffControl(
                kind: kind, transfer: transfer, occurrence: occurrence, nonce: nonce)
            XCTAssertEqual(try FoundationHandoffControl.decode(value.encoded()), value)
            XCTAssertThrowsError(try FoundationHandoffAcknowledgement.decode(value.encoded()))
        }
        let clock = FoundationHandoffControl(
            kind: .positionValue, transfer: transfer,
            occurrence: occurrence, nonce: nonce, seconds: 42.125)
        XCTAssertEqual(try FoundationHandoffControl.decode(clock.encoded()), clock)
        XCTAssertLessThanOrEqual(try clock.encoded().count, 512)
        XCTAssertThrowsError(try FoundationHandoffAcknowledgement.decode(clock.encoded()))
        for seconds in [-1, Double.infinity, Double.nan] {
            XCTAssertThrowsError(
                try FoundationHandoffControl(
                    kind: .positionValue,
                    transfer: transfer, occurrence: occurrence, nonce: nonce, seconds: seconds
                ).encoded())
        }
        XCTAssertThrowsError(
            try FoundationHandoffControl(
                kind: .position,
                transfer: transfer, occurrence: occurrence, nonce: nonce, seconds: 1
            ).encoded())
        XCTAssertThrowsError(try FoundationHandoffControl.decode(Data(repeating: 1, count: 513)))
    }

    func testDuplicateOccurrenceAndMissingSelectionCannotReplaceAQueue() throws {
        let entry = payload().session!.entries[0]
        XCTAssertThrowsError(try payload(entries: [entry, entry]).encoded())
        let value = payload()
        let invalid = FoundationHandoffPayload(
            header: value.header,
            session: .init(
                entries: value.session!.entries, selected: UUID(), position: 0,
                shuffle: false, repeatMode: .off, wasPlaying: true), destination: nil)
        XCTAssertThrowsError(try invalid.encoded())
    }

    func testOnlyBoundedDisplayMetadataIsTransported() throws {
        var item = FoundationItem(
            id: "song", title: "Song", subtitle: "Artist", kind: .track, duration: 200)
        item.trackNumber = 7
        item.discNumber = 2
        item.sortName = "private-sort-value"
        item.primaryImageTag = "private-image-value"
        item.logoImageTag = "private-logo-value"
        item.backdropImageTag = "private-backdrop-value"
        item.playlistEntryID = "private-membership-value"
        let track = FoundationHandoffPayload.Track(.init(item: item))
        let data = try payload(entries: [track]).encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-"))
        XCTAssertFalse(text.contains("serverURL"))
        XCTAssertFalse(text.contains("accessToken"))
        XCTAssertFalse(text.contains("fileURL"))
        XCTAssertEqual(track.entry.item.id, item.id)
        XCTAssertNil(track.entry.item.primaryImageTag)
        XCTAssertNil(track.entry.item.playlistEntryID)
        XCTAssertEqual(track.entry.item.trackNumber, 7)
        XCTAssertEqual(track.entry.item.discNumber, 2)
    }

    func testInvalidIdentifiersAndUnboundedTimeAreRejected() throws {
        let item = FoundationItem(
            id: "../local/path", title: "Song", subtitle: "", kind: .track, duration: 200)
        XCTAssertThrowsError(try payload(entries: [.init(.init(item: item))]).encoded())
        let valid = payload()
        let bad = FoundationHandoffPayload(
            header: valid.header,
            session: .init(
                entries: valid.session!.entries, selected: valid.session!.selected,
                position: Double.greatestFiniteMagnitude, shuffle: false,
                repeatMode: .off, wasPlaying: false), destination: nil)
        XCTAssertThrowsError(try bad.encoded())
    }

    func testBrowseAndPlaybackHaveMutuallyExclusivePayloads() throws {
        let browse = FoundationHandoffPayload(
            header: .init(scope: scope, kind: .browse, createdAt: now), session: nil,
            destination: .init(id: "album", kind: .album))
        try browse.validate(scope: scope, now: now)
        let bad = FoundationHandoffPayload(
            header: browse.header, session: payload().session, destination: browse.destination)
        XCTAssertThrowsError(try bad.validate(scope: scope, now: now))
    }

    func testFragmentedFrameWaitsForTheCompleteQueueMessage() throws {
        let data = try payload().encoded()
        let frame = try FoundationHandoffFrame.encode(data)
        var decoder = FoundationHandoffFrame()
        for byte in frame.dropLast() {
            XCTAssertNil(try decoder.append(Data([byte])))
        }
        XCTAssertEqual(try decoder.append(Data([frame.last!])), data)
        XCTAssertTrue(decoder.complete)
        XCTAssertThrowsError(try decoder.append(Data([0])))
    }

    func testInvalidFrameLengthAndTrailingDataCannotProducePartialSuccess() throws {
        var zero = FoundationHandoffFrame()
        XCTAssertThrowsError(try zero.append(Data([0, 0, 0, 0])))
        var tooLarge = FoundationHandoffFrame()
        XCTAssertThrowsError(try tooLarge.append(Data([255, 255, 255, 255])))
        var trailing = FoundationHandoffFrame()
        XCTAssertThrowsError(try trailing.append(Data([0, 0, 0, 1, 65, 66])))
    }

    private func payload(
        entries supplied: [FoundationHandoffPayload.Track]? = nil
    ) -> FoundationHandoffPayload {
        let item = FoundationItem(
            id: "song", title: "Song", subtitle: "Artist", kind: .track, duration: 200)
        let entries = supplied ?? [.init(.init(item: item)), .init(.init(item: item))]
        return .init(
            header: .init(scope: scope, kind: .playback, createdAt: now),
            session: .init(
                entries: entries, selected: entries.last!.occurrence, position: 73.25,
                shuffle: true, repeatMode: .all, wasPlaying: false), destination: nil)
    }
}
