import Foundation
import Testing
@testable import SplitSlipCore
import ReceiptDomain

private func person(_ name: String, _ seed: UInt8) -> ParticipantIdentity {
    ParticipantIdentity(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, seed)),
        displayName: name)
}

private func makeHappyModel(store: any DraftStore & SnapshotStore) -> ReceiptWorkspaceModel {
    let model = ReceiptWorkspaceModel(store: store)
    model.setExpectedTotal("30.00")
    model.participantNameInput = "Ana"
    model.addParticipant()
    model.participantNameInput = "Bo"
    model.addParticipant()
    model.addLine()
    let lineID = model.draft.lines[0].id
    model.setLineLabel(lineID, "Appetizer")
    model.setLineAmount(lineID, "30.00")
    model.assignEqually(rowID: lineID, isAdjustment: false)
    return model
}

@Suite("Issue 3 workspace model happy path")
struct WorkspaceHappyPathTests {
    @Test("create → allocate → review → finalize stores an immutable snapshot")
    func happyPath() throws {
        let store = InMemoryReceiptStore()
        let model = makeHappyModel(store: store)

        #expect(model.canFinalize, "unexpected blockers: \(model.finalizationBlockers())")
        let reviews = model.personReviews()
        #expect(reviews.map(\.total) == [MinorAmount(minorUnits: 1500), MinorAmount(minorUnits: 1500)])

        let snapshotID = try #require(model.finalizeNow())
        let snapshot = try store.loadSnapshot(id: snapshotID)
        #expect(snapshot.expectedTotal == MinorAmount(minorUnits: 3000))
        #expect(snapshot.personShares.map(\.totalMinorUnits) == [1500, 1500])
        #expect(model.isFinalized)
        // The finalized draft's row is gone; only the snapshot remains.
        #expect((try? store.loadDraft(id: model.draft.id)) == nil)
        #expect(try store.loadAllSnapshots().count == 1)
    }

    @Test("weighted split totals and the extra cent carry an explanation")
    func weightedSplitExtraCent() throws {
        let store = InMemoryReceiptStore()
        let model = ReceiptWorkspaceModel(store: store)
        model.setExpectedTotal("0.01")
        model.participantNameInput = "Ana"
        model.addParticipant()
        model.participantNameInput = "Bo"
        model.addParticipant()
        model.addLine()
        let lineID = model.draft.lines[0].id
        model.setLineLabel(lineID, "Single cent")
        model.setLineAmount(lineID, "0.01")
        model.assignEqually(rowID: lineID, isAdjustment: false)

        let reviews = model.personReviews()
        // 1¢ split equally: first person (stable order) receives the cent.
        #expect(reviews[0].total == MinorAmount(minorUnits: 1))
        #expect(reviews[1].total == .zero)
        #expect(reviews[0].extraCentNotes.count == 1)
        #expect(reviews[0].extraCentNotes[0].contains("Single cent"))
        #expect(reviews[1].extraCentNotes.isEmpty)
    }

    @Test("adjustment with explicit recipients reconciles to the printed total")
    func adjustments() throws {
        let store = InMemoryReceiptStore()
        let model = ReceiptWorkspaceModel(store: store)
        model.setExpectedTotal("11.00")
        model.participantNameInput = "Ana"
        model.addParticipant()
        model.participantNameInput = "Bo"
        model.addParticipant()
        model.addLine()
        let lineID = model.draft.lines[0].id
        model.setLineLabel(lineID, "Food")
        model.setLineAmount(lineID, "10.00")
        model.assignEqually(rowID: lineID, isAdjustment: false)
        model.addAdjustment()
        let adjID = model.draft.adjustments[0].id
        model.setAdjustmentLabel(adjID, "Service")
        model.setAdjustmentAmount(adjID, "1.00")
        model.toggleParticipant(model.draft.participants[0].id, onRow: adjID, isAdjustment: true)

        #expect(model.canFinalize, "\(model.finalizationBlockers())")
        let reviews = model.personReviews()
        #expect(reviews[0].total == MinorAmount(minorUnits: 600))
        #expect(reviews[1].total == MinorAmount(minorUnits: 500))
    }
}

@Suite("Issue 3 validation, empty and error states")
struct WorkspaceValidationTests {
    @Test("invalid amounts show copy and never reach the stored draft")
    func invalidAmounts() throws {
        let store = InMemoryReceiptStore()
        let model = makeHappyModel(store: store)
        let lineID = model.draft.lines[0].id

        model.setLineAmount(lineID, "1,000.00")
        #expect(model.fieldMessages["line:\(lineID):amount"]?.contains("separators") == true)
        // The stored draft keeps its previous good amount.
        let stored = try store.loadDraft(id: model.draft.id)
        #expect(stored.lines[0].amount == MinorAmount(minorUnits: 3000))

        model.setExpectedTotal("12.345")
        #expect(model.fieldMessages["expectedTotal"]?.contains("decimal places") == true)
    }

    @Test("negative line amounts are refused with the adjustment hint")
    func negativeLine() throws {
        let model = ReceiptWorkspaceModel(store: InMemoryReceiptStore())
        model.addLine()
        let lineID = model.draft.lines[0].id
        model.setLineAmount(lineID, "-5.00")
        #expect(model.fieldMessages["line:\(lineID):amount"]?.contains("adjustment") == true)
    }

    @Test("zero adjustment amounts are refused")
    func zeroAdjustment() throws {
        let model = ReceiptWorkspaceModel(store: InMemoryReceiptStore())
        model.addAdjustment()
        let adjID = model.draft.adjustments[0].id
        model.setAdjustmentAmount(adjID, "0.00")
        #expect(model.fieldMessages["adjustment:\(adjID):amount"]?.contains("zero") == true)
    }

    @Test("empty receipt shows an explicit empty state")
    func emptyState() {
        let model = ReceiptWorkspaceModel(store: InMemoryReceiptStore())
        #expect(model.emptyStateMessage != nil)
        #expect(!model.canFinalize)
        model.addLine()
        #expect(model.emptyStateMessage == nil) // rows exist; blockers move on
    }

    @Test("total mismatch and unresolved rows block finalization visibly")
    func blockers() throws {
        let store = InMemoryReceiptStore()
        let model = ReceiptWorkspaceModel(store: store)
        model.setExpectedTotal("20.00")
        model.participantNameInput = "Ana"
        model.addParticipant()
        model.addLine()
        let lineID = model.draft.lines[0].id
        model.setLineLabel(lineID, "Food")
        model.setLineAmount(lineID, "10.00")
        // Unresolved + mismatch: two distinct visible blockers.
        let blockers = model.finalizationBlockers()
        #expect(blockers.contains(where: { $0.contains("mismatch") || $0.contains("short") }))
        #expect(blockers.contains(where: { $0.contains("unresolved") }))
        #expect(model.finalizeNow() == nil)
        // Store is untouched by the failed attempt.
        #expect(try store.loadAllSnapshots().isEmpty)
    }

    @Test("participant limit is enforced with copy")
    func participantLimit() {
        let model = ReceiptWorkspaceModel(store: InMemoryReceiptStore())
        for index in 0..<ReceiptLimits.maximumParticipantsPerReceipt {
            model.participantNameInput = "P\(index)"
            model.addParticipant()
        }
        model.participantNameInput = "One too many"
        model.addParticipant()
        #expect(model.draft.participants.count == ReceiptLimits.maximumParticipantsPerReceipt)
        #expect(model.fieldMessages["participant"]?.contains("Too many participants") == true)
    }

    @Test("participant removal flags affected rows instead of reassigning")
    func removalFlagsRows() throws {
        let model = makeHappyModel(store: InMemoryReceiptStore())
        let lineID = model.draft.lines[0].id
        let boID = model.draft.participants[1].id
        #expect(model.affectedRowLabels(forRemoval: boID) == ["Appetizer"])
        model.removeParticipant(id: boID)
        #expect(model.draft.rowsNeedingReview.contains(lineID))
        #expect(model.draft.lineAllocations[lineID]?.isEmpty == true)
        // Removing again is a no-op error surface, not a crash.
        model.removeParticipant(id: boID)
    }
}

@Suite("Issue 3 draft recovery and correction")
struct WorkspaceRecoveryTests {
    @Test("edits auto-save; a new model rebuilt from the store keeps them")
    func draftRecovery() throws {
        let store = InMemoryReceiptStore()
        let model = makeHappyModel(store: store)
        // Simulate relaunch: rebuild from the persisted draft.
        let reloaded = ReceiptWorkspaceModel(draft: try store.loadDraft(id: model.draft.id), store: store)
        #expect(reloaded.expectedTotalInput == "30.00")
        #expect(reloaded.draft.participants.map(\.displayName) == ["Ana", "Bo"])
        #expect(reloaded.draft.lines.count == 1)
        #expect(reloaded.canFinalize, "\(reloaded.finalizationBlockers())")
    }

    @Test("duplicate-to-correct keeps the snapshot and links the fork")
    func correctionKeepsSnapshot() throws {
        let store = InMemoryReceiptStore()
        let model = makeHappyModel(store: store)
        let snapshotID = try #require(model.finalizeNow())
        let original = try store.loadSnapshot(id: snapshotID)

        // Fork a correction draft through the model's static helper.
        let forkDraft = ReceiptWorkspaceModel.correctionDraft(from: original)
        let fork = ReceiptWorkspaceModel(draft: forkDraft, store: store)
        #expect(fork.isCorrection)
        #expect(fork.draft.correctionOfSnapshotID == snapshotID)

        // Edit the fork and finalize a second snapshot.
        fork.setExpectedTotal("31.00")
        let lineID = try #require(fork.draft.lines.first?.id)
        fork.setLineAmount(lineID, "31.00")
        let secondID = try #require(fork.finalizeNow())
        let second = try store.loadSnapshot(id: secondID)
        #expect(second.correctsSnapshotID == snapshotID)

        // The original snapshot bytes are unchanged (immutable).
        let reloaded = try store.loadSnapshot(id: snapshotID)
        #expect(reloaded == original)
    }

    @Test("canceling a correction leaves the snapshot untouched")
    func cancelCorrection() throws {
        let store = InMemoryReceiptStore()
        let model = makeHappyModel(store: store)
        let snapshotID = try #require(model.finalizeNow())
        let original = try store.loadSnapshot(id: snapshotID)

        let fork = ReceiptWorkspaceModel(draft: ReceiptWorkspaceModel.correctionDraft(from: original), store: store)
        fork.setExpectedTotal("99.99")
        fork.cancelCorrectionIfFork()

        // Fork draft is gone; snapshot intact.
        #expect((try? store.loadDraft(id: fork.draft.id)) == nil)
        #expect(try store.loadSnapshot(id: snapshotID) == original)
        #expect(fork.fieldMessages["correction"]?.contains("unchanged") == true)
    }

    @Test("store write failures surface visibly without corrupting state")
    func storeFailureVisible() throws {
        let inner = InMemoryReceiptStore()
        let failing = FailingStore(inner: inner, failNextWrites: 1)
        let model = ReceiptWorkspaceModel(store: failing)
        model.setExpectedTotal("10.00")
        #expect(model.fieldMessages["store"]?.contains("Previous data is unchanged") == true)
        // Retrying the same edit succeeds once the injected failure drains.
        model.setExpectedTotal("10.00")
        #expect(model.fieldMessages["store"] == nil)
    }
}

/// Wraps a good store and fails the next N writes to exercise the failure path.
private final class FailingStore: DraftStore & SnapshotStore, @unchecked Sendable {
    private let inner: InMemoryReceiptStore
    private let lock = NSLock()
    private var failNextWrites: Int

    init(inner: InMemoryReceiptStore, failNextWrites: Int) {
        self.inner = inner
        self.failNextWrites = failNextWrites
    }

    private func maybeFail() throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextWrites > 0 {
            failNextWrites -= 1
            throw StoreFailure.writeFailed("injected")
        }
    }

    func saveDraft(_ draft: ReceiptDraft) throws {
        try maybeFail()
        try inner.saveDraft(draft)
    }

    func loadDraft(id: UUID) throws -> ReceiptDraft { try inner.loadDraft(id: id) }
    func loadAllDrafts() throws -> [ReceiptDraft] { try inner.loadAllDrafts() }
    func deleteDraft(id: UUID) throws { try inner.deleteDraft(id: id) }
    func storeSnapshot(_ snapshot: FinalizedReceiptSnapshot) throws { try inner.storeSnapshot(snapshot) }
    func loadSnapshot(id: UUID) throws -> FinalizedReceiptSnapshot { try inner.loadSnapshot(id: id) }
    func loadAllSnapshots() throws -> [FinalizedReceiptSnapshot] { try inner.loadAllSnapshots() }
}

@Suite("Receipt-wide amounts and automatic remainder")
struct ReceiptWideSplitTests {
    @Test func fixedAmountsRebalanceAndSurviveRestore() throws {
        let store = InMemoryReceiptStore()
        let model = makeHappyModel(store: store)
        model.participantNameInput = "Cy"; model.addParticipant()
        model.splitReceiptEqually()
        let people = model.draft.participants
        let row = model.draft.lines[0].id
        #expect(try model.draft.personTotals()[people[0]]?.minorUnits == 1000)
        model.setPersonAmount(people[0].id, "8.00")
        #expect(try model.draft.personTotals()[people[1]]?.minorUnits == 1100)
        model.setPersonAmount(people[1].id, "9.00")
        #expect(try model.draft.personTotals()[people[2]]?.minorUnits == 1300)
        model.setLineAmount(row, "35.01")
        model.setExpectedTotal("35.01")
        #expect(try model.draft.personTotals()[people[0]]?.minorUnits == 800)
        #expect(try model.draft.personTotals()[people[2]]?.minorUnits == 1801)
        model.setPersonAmount(people[1].id, "")
        #expect(try model.draft.personTotals()[people[1]]?.minorUnits == 1351)
        #expect(try model.draft.personTotals()[people[2]]?.minorUnits == 1350)
        let decoded = try JSONDecoder().decode(ReceiptDraft.self, from: JSONEncoder().encode(model.draft))
        let snapshot = try decoded.finalize()
        try ReceiptLibrary(snapshots: [snapshot]).validate()
        #expect(snapshot.correctionDraft().receiptSplit == decoded.receiptSplit)
        #expect(snapshot.personShares.map(\.totalMinorUnits) == [800, 1351, 1350])
        #expect(ReceiptSummary.render(snapshot).contains("Bo: 13.51 USD"))
        model.splitReceiptEqually()
        #expect(try model.draft.personTotals()[people[0]]?.minorUnits == 1167)
    }

    @Test func overcommitAndInvalidInputBlockFinalizeWithoutDiscardingAmounts() throws {
        let model = makeHappyModel(store: InMemoryReceiptStore())
        let id = model.draft.participants[0].id
        model.setPersonAmount(id, "31.00")
        #expect(!model.canFinalize)
        #expect(model.finalizationBlockers().contains { $0.contains("exceed") })
        model.setPersonAmount(id, "10.00")
        #expect(model.canFinalize)
        model.setPersonAmount(id, "oops")
        #expect(!model.canFinalize)
        #expect(model.draft.receiptSplit?[id]?.minorUnits == 1000)
        model.setPersonAmount(id, "")
        #expect(model.canFinalize)
        model.setPersonAmount(id, "0")
        #expect(try model.draft.personTotals()[model.draft.participants[1]]?.minorUnits == 3000)
    }

    @Test func participantAndAdjustmentChangesRebalance() throws {
        let model = makeHappyModel(store: InMemoryReceiptStore())
        model.splitReceiptEqually()
        model.setPersonAmount(model.draft.participants[0].id, "10")
        model.participantNameInput = "Cy"; model.addParticipant()
        model.addAdjustment()
        let adjustment = model.draft.adjustments[0].id
        model.setAdjustmentAmount(adjustment, "-2.01")
        #expect(try model.draft.personTotals()[model.draft.participants[1]]?.minorUnits == 900)
        #expect(try model.draft.personTotals()[model.draft.participants[2]]?.minorUnits == 899)
        model.removeParticipant(id: model.draft.participants[0].id)
        #expect(try model.draft.personTotals()[model.draft.participants[0]]?.minorUnits == 1400)
        model.removeLine(model.draft.lines[0].id)
        #expect(!model.canFinalize)
    }

    @Test func oldDraftsDecodeWithoutNewSplitField() throws {
        let draft = makeHappyModel(store: InMemoryReceiptStore()).draft
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String: Any]
        json.removeValue(forKey: "receiptSplit")
        let restored = try JSONDecoder().decode(ReceiptDraft.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.receiptSplit == nil)
        #expect(try restored.finalize().personShares.map(\.totalMinorUnits) == [1500, 1500])
    }
}
