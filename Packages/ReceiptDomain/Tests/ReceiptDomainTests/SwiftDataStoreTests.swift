import Foundation
import Testing
import ReceiptDomain

#if canImport(SwiftData)
import SwiftData
@testable import ReceiptStore

/// Persistence acceptance for issue #2: draft edits persist, a reopened store
/// recovers them (restart), snapshots are immutable, and failures never wipe
/// previously stored state. Temporary stores only, always torn down.
@Suite("Issue 2 SwiftData persistence", .serialized)
struct SwiftDataStoreTests {
    private func temporaryStore() throws -> (SwiftDataReceiptStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitslip-tests-\(UUID().uuidString)")
            .appendingPathExtension("store")
        let store = try SwiftDataReceiptStore(url: url)
        return (store, url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
    }

    private func sampleDraft() throws -> ReceiptDraft {
        let ann = ParticipantIdentity(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)), displayName: "Ann")
        let bob = ParticipantIdentity(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)), displayName: "Bob")
        let line = ReceiptLine(label: "Soup", amount: try MinorAmount(parsing: "7.50"))
        return ReceiptDraft(
            expectedTotal: try MinorAmount(parsing: "7.50"),
            participants: [ann, bob],
            lines: [line],
            lineAllocations: [line.id: RowAllocation(shares: [
                .init(participantID: ann.id, weight: 1),
                .init(participantID: bob.id, weight: 2),
            ])])
    }

    @Test("Corrupt persisted amounts surface a read error without deleting records")
    func damagedStoreRead() throws {
        let (store, url) = try temporaryStore()
        defer { cleanup(url) }
        var draft = try sampleDraft()
        try store.saveDraft(draft)
        let context = ModelContext(store.container)
        let record = try #require(context.fetch(FetchDescriptor<DraftRecord>()).first)
        draft.expectedTotal = MinorAmount(minorUnits: .min)
        record.payload = try PropertyListEncoder().encode(draft)
        try context.save()
        #expect(throws: (any Error).self) { try store.loadAllDrafts() }
        #expect(try context.fetchCount(FetchDescriptor<DraftRecord>()) == 1)
    }

    @Test("Library replacement is durable and validates before deleting")
    func replaceLibrary() throws {
        let (store, url) = try temporaryStore()
        defer { cleanup(url) }
        var draft = try sampleDraft()
        try store.saveDraft(draft)
        let snapshot = try draft.finalize()
        // Reuse the same draft ID to exercise SwiftData's uniqueness constraint.
        draft.participants[0].displayName = "Updated name"
        try store.replaceLibrary(ReceiptLibrary(drafts: [draft], snapshots: [snapshot]))
        let reopened = try SwiftDataReceiptStore(url: url)
        #expect(try reopened.loadDraft(id: draft.id).participants[0].displayName == "Updated name")
        #expect(try reopened.loadAllSnapshots() == [snapshot])
        #expect(throws: (any Error).self) {
            try store.replaceLibrary(ReceiptLibrary(drafts: [draft, draft]))
        }
        #expect(try store.loadAllSnapshots() == [snapshot])
        try store.replaceLibrary(ReceiptLibrary())
        #expect(try store.loadAllDrafts().isEmpty)
        #expect(try store.loadAllSnapshots().isEmpty)
    }

    @Test("Draft save then reopen-in-new-store recovers the edit")
    func restartRecovery() throws {
        let (store, url) = try temporaryStore()
        defer { cleanup(url) }
        var draft = try sampleDraft()
        try store.saveDraft(draft)

        // Reopen: brand-new store over the same file — models a relaunch.
        let reopened = try SwiftDataReceiptStore(url: url)
        let recovered = try reopened.loadDraft(id: draft.id)
        #expect(recovered == draft)

        // Edit, persist, reopen again.
        draft.expectedTotal = try MinorAmount(parsing: "8.00")
        try reopened.saveDraft(draft)
        let recoveredAgain = try SwiftDataReceiptStore(url: url).loadDraft(id: draft.id)
        #expect(recoveredAgain.expectedTotal == (try MinorAmount(parsing: "8.00")))
        #expect(recoveredAgain == draft)
    }

    @Test("Snapshot round-trips and stays immutable to re-store")
    func snapshotImmutability() throws {
        let (store, url) = try temporaryStore()
        defer { cleanup(url) }
        let draft = try sampleDraft()
        let snapshot = try draft.finalize(finalizedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.storeSnapshot(snapshot)

        let reopened = try SwiftDataReceiptStore(url: url)
        let loaded = try reopened.loadSnapshot(id: snapshot.id)
        #expect(loaded == snapshot)

        // A second store of the same snapshot must be refused, not overwrite.
        #expect(throws: StoreFailure.duplicateIdentity("snapshot \(snapshot.id) already stored")) {
            try reopened.storeSnapshot(snapshot)
        }
        let stillThere = try reopened.loadSnapshot(id: snapshot.id)
        #expect(stillThere == snapshot)
    }

    @Test("Missing ids produce explicit errors rather than empty results")
    func missingRows() throws {
        let (store, url) = try temporaryStore()
        defer { cleanup(url) }
        let ghost = UUID()
        #expect(throws: StoreFailure.missingDraft(ghost)) { try store.loadDraft(id: ghost) }
        #expect(throws: StoreFailure.missingSnapshot(ghost)) { try store.loadSnapshot(id: ghost) }
        #expect(throws: StoreFailure.missingDraft(ghost)) { try store.deleteDraft(id: ghost) }
    }

    @Test("Unknown algorithm version refuses decode instead of guessing")
    func versionGate() throws {
        let draft = try sampleDraft()
        let snapshot = try draft.finalize(finalizedAt: Date())
        try AlgorithmVersion.validateRestorable(snapshot.algorithmVersion)
        #expect(throws: SnapshotVersionError.unsupportedSchema(99)) {
            try AlgorithmVersion.validateRestorable(AlgorithmVersion(schema: 99, allocationRule: 1))
        }
        #expect(throws: SnapshotVersionError.unsupportedAllocationRule(7)) {
            try AlgorithmVersion.validateRestorable(AlgorithmVersion(schema: 1, allocationRule: 7))
        }
    }

    @Test("Deleting a draft leaves snapshots and other drafts intact")
    func deleteIsolation() throws {
        let (store, url) = try temporaryStore()
        defer { cleanup(url) }
        let first = try sampleDraft()
        var second = try sampleDraft()
        second.expectedTotal = try MinorAmount(parsing: "3.00")
        let snapshot = try first.finalize(finalizedAt: Date(timeIntervalSince1970: 1_600_000_000))
        try store.saveDraft(first)
        try store.saveDraft(second)
        try store.storeSnapshot(snapshot)

        try store.deleteDraft(id: first.id)
        let reopened = try SwiftDataReceiptStore(url: url)
        #expect(throws: StoreFailure.missingDraft(first.id)) { try reopened.loadDraft(id: first.id) }
        #expect((try reopened.loadDraft(id: second.id)) == second)
        #expect((try reopened.loadSnapshot(id: snapshot.id)) == snapshot)
    }
}
#endif
