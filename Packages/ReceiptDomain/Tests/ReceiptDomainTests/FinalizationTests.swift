import Foundation
import Testing
@testable import ReceiptDomain

/// Independently specified examples from issue #2 acceptance criteria for
/// drafts, reconciliation, finalization and snapshots.
@Suite("Issue 2 reconciliation and finalization")
struct FinalizationTests {
    private func person(_ name: String, _ seed: UInt8) -> ParticipantIdentity {
        ParticipantIdentity(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, seed)),
            displayName: name)
    }

    private func allocation(_ pairs: [(ParticipantIdentity, Int)]) -> RowAllocation {
        RowAllocation(shares: pairs.map { RowAllocation.ParticipantShare(participantID: $0.id, weight: $1) })
    }

    /// 30.00 total: 20.00 line split 3 ways + 10.00 line split 1:2.
    private func makeHappyDraft(total: String = "30.00") throws -> (ReceiptDraft, [ParticipantIdentity], UUID, UUID) {
        let people = [person("Ann", 1), person("Bob", 2), person("Cee", 3)]
        let line1 = ReceiptLine(label: "Dinner", amount: try MinorAmount(parsing: "20.00"))
        let line2 = ReceiptLine(label: "Wine", amount: try MinorAmount(parsing: "10.00"))
        let draft = ReceiptDraft(
            expectedTotal: try MinorAmount(parsing: total),
            participants: people,
            lines: [line1, line2],
            lineAllocations: [
                line1.id: allocation(people.map { ($0, 1) }),
                line2.id: allocation([(people[0], 1), (people[1], 2)]),
            ])
        return (draft, people, line1.id, line2.id)
    }

    @Test("A fully reconciled receipt finalizes with exact person totals")
    func happyPath() throws {
        let (draft, _, _, _) = try makeHappyDraft()
        let snapshot = try draft.finalize(finalizedAt: Date(timeIntervalSince1970: 1_800_000_000))
        // Dinner 2000c three ways: bases 666/666/666, all remainders tied at 2,
        // residual 2 cents to the first two in stored order -> 667/667/666.
        // Wine 1000c weights 1:2: bases 333/666, remainders 1/2, residual to
        // the larger remainder (Bob) -> 333/667.
        #expect(snapshot.personShares.map(\.totalMinorUnits) == [1000, 1334, 666])
        let personSum = snapshot.personShares.map(\.totalMinorUnits).reduce(0, +)
        #expect(personSum == Int64(snapshot.expectedTotal.minorUnits))
        #expect(snapshot.expectedTotal == snapshot.computedTotal)
        #expect(snapshot.algorithmVersion == .current)
    }

    @Test("Row-level shares are conserved per row inside the snapshot")
    func perRowConservation() throws {
        let (draft, people, line1ID, line2ID) = try makeHappyDraft()
        let snapshot = try draft.finalize(finalizedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let line1Sum = snapshot.personShares.reduce(Int64(0)) { $0 + ($1.rowShares[line1ID] ?? 0) }
        let line2Sum = snapshot.personShares.reduce(Int64(0)) { $0 + ($1.rowShares[line2ID] ?? 0) }
        #expect(line1Sum == 2000)
        #expect(line2Sum == 1000)
        // Every cent belongs to exactly one participant row share.
        let totals = snapshot.personShares.map(\.totalMinorUnits).reduce(0, +)
        #expect(totals == 3000)
        _ = people
    }

    @Test("Mismatched expected total blocks finalization and names the gap")
    func mismatchBlocks() throws {
        let (draft, _, _, _) = try makeHappyDraft(total: "29.99")
        do {
            _ = try draft.finalize()
            Issue.record("finalization must fail on mismatch")
        } catch let error as FinalizationError {
            guard case .reconciliation(.totalMismatch(let difference)) = error else {
                Issue.record("expected totalMismatch, got \(error)")
                return
            }
            #expect(difference.minorUnits == -1)
        }
    }

    @Test("An unassigned line blocks finalization by row id")
    func unassignedBlocks() throws {
        let (draft, _, _, line2ID) = try makeHappyDraft()
        var broken = draft
        broken.lineAllocations[line2ID] = RowAllocation(shares: [])  // explicitly unresolved
        do {
            _ = try broken.finalize()
            Issue.record("finalization must fail with an unassigned row")
        } catch let error as FinalizationError {
            guard case .reconciliation(.unassignedRow(let rowID)) = error else {
                Issue.record("expected unassignedRow, got \(error)")
                return
            }
            #expect(rowID == line2ID)
        }
    }

    @Test("Missing allocation key is unresolved, not an even split")
    func missingKeyIsUnresolved() throws {
        let (draft, _, _, line2ID) = try makeHappyDraft()
        var broken = draft
        broken.lineAllocations[line2ID] = nil
        #expect(broken.unassignedRowIDs() == [line2ID])
        #expect(throws: (any Error).self) { try broken.finalize() }
    }

    @Test("Zero participants blocks finalization")
    func noParticipantsBlocks() throws {
        let (draft, _, _, _) = try makeHappyDraft()
        var empty = draft
        empty.participants = []
        empty.lineAllocations = [:]
        do {
            _ = try empty.finalize()
            Issue.record("must block without participants")
        } catch let error as FinalizationError {
            guard case .reconciliation(.noParticipants) = error else {
                Issue.record("expected noParticipants, got \(error)")
                return
            }
        }
    }

    @Test("A discount that drives one person negative blocks finalization")
    func negativePersonBlocks() throws {
        let people = [person("Ann", 1), person("Bob", 2)]
        let line = ReceiptLine(label: "Main", amount: try MinorAmount(parsing: "10.00"))
        let coupon = ReceiptAdjustment(label: "Coupon", amount: try MinorAmount(parsing: "-8.00"))
        // Ann carries the whole 10.00 line; the 8.00 coupon is split evenly.
        // Ann = 1000 - 400 = 600, Bob = 0 - 400 = -400 -> must block.
        let draft = ReceiptDraft(
            expectedTotal: try MinorAmount(parsing: "2.00"),
            participants: people,
            lines: [line],
            lineAllocations: [line.id: allocation([(people[0], 1)])],
            adjustments: [coupon],
            adjustmentAllocations: [coupon.id: allocation(people.map { ($0, 1) })])
        do {
            _ = try draft.finalize()
            Issue.record("must block negative participant total")
        } catch let error as FinalizationError {
            guard case .reconciliation(.negativeParticipantTotal(let who, let units)) = error else {
                Issue.record("expected negativeParticipantTotal, got \(error)")
                return
            }
            #expect(who == people[1])
            #expect(units == -400)
        }
    }

    @Test("Discount with the whole receipt reconciling finalizes cleanly")
    func discountFinalizes() throws {
        let people = [person("Ann", 1), person("Bob", 2)]
        let line = ReceiptLine(label: "Brunch", amount: try MinorAmount(parsing: "30.03"))
        let discount = ReceiptAdjustment(label: "Promo", amount: try MinorAmount(parsing: "-0.03"))
        var draft = ReceiptDraft(
            expectedTotal: try MinorAmount(parsing: "30.00"),
            participants: people,
            lines: [line],
            lineAllocations: [line.id: allocation(people.map { ($0, 1) })],
            adjustments: [discount])
        draft.adjustmentAllocations[discount.id] = allocation(people.map { ($0, 1) })
        let snapshot = try draft.finalize(finalizedAt: Date(timeIntervalSince1970: 1_800_000_000))
        // Line 3003: Ann 1502, Bob 1501. Discount -3: -2/-1 symmetric mirror of 2/1.
        #expect(snapshot.personShares.map(\.totalMinorUnits) == [1500, 1500])
        let sum = snapshot.personShares.map(\.totalMinorUnits).reduce(0, +)
        #expect(sum == 3000)
    }

    @Test("Finalizing the same draft twice yields identical content under a fresh id")
    func finalizationIsDeterministic() throws {
        let (draft, _, _, _) = try makeHappyDraft()
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let a = try draft.finalize(finalizedAt: date)
        let b = try draft.finalize(finalizedAt: date)
        // Only the snapshot's own id differs; every allocation outcome repeats.
        #expect(a.id != b.id)
        #expect(a.sourceDraftID == b.sourceDraftID)
        #expect(a.finalizedAt == b.finalizedAt)
        #expect(a.algorithmVersion == b.algorithmVersion)
        #expect(a.expectedTotal == b.expectedTotal)
        #expect(a.computedTotal == b.computedTotal)
        #expect(a.participants == b.participants)
        #expect(a.lines == b.lines)
        #expect(a.lineAllocations == b.lineAllocations)
        #expect(a.adjustments == b.adjustments)
        #expect(a.adjustmentAllocations == b.adjustmentAllocations)
        #expect(a.personShares == b.personShares)
        #expect(a.correctsSnapshotID == b.correctsSnapshotID)
    }

    @Test("Correction forks a linked draft; the snapshot stays untouched")
    func correctionLinksDraft() throws {
        let (draft, _, _, _) = try makeHappyDraft()
        let snapshot = try draft.finalize(finalizedAt: Date(timeIntervalSince1970: 1_800_000_000))
        var corrected = snapshot.correctionDraft()
        #expect(corrected.correctionOfSnapshotID == snapshot.id)
        let extra = ReceiptLine(label: "Tip", amount: try MinorAmount(parsing: "1.00"))
        corrected.lines.append(extra)
        corrected.lineAllocations[extra.id] = allocation([(snapshot.participants[0], 1)])
        corrected.expectedTotal = try MinorAmount(parsing: "31.00")
        let originalTotal = try MinorAmount(parsing: "30.00")
        #expect(snapshot.expectedTotal == originalTotal)  // immutable
        let second = try corrected.finalize(finalizedAt: Date(timeIntervalSince1970: 1_800_000_001))
        #expect(second.correctsSnapshotID == snapshot.id)
        #expect(second.sourceDraftID == corrected.id)
    }

    @Test("Removing a participant flags affected rows instead of reallocating")
    func removalFlagsReview() throws {
        let (draft, people, line1ID, line2ID) = try makeHappyDraft()
        var broken = draft
        broken.removeParticipant(id: people[2].id)
        #expect(broken.participants.count == 2)
        // Both lines involved Cee -> both cleared and flagged.
        #expect(broken.lineAllocations[line1ID]?.isEmpty == true)
        #expect(broken.lineAllocations[line2ID] != nil)  // line2 never included Cee
        #expect(broken.rowsNeedingReview == [line1ID])
        // Unresolved, not silently redistributed: finalization refuses.
        #expect(throws: (any Error).self) { try broken.finalize() }
        // The cleared row shows as unassigned rather than zero-cost.
        #expect(broken.unassignedRowIDs() == [line1ID])
    }

    @Test("Structure bounds refuse oversized receipts")
    func structuralBounds() throws {
        let personA = person("Ann", 1)
        var draft = ReceiptDraft(expectedTotal: .zero, participants: [personA])
        for index in 0...ReceiptLimits.maximumLinesPerReceipt {
            draft.lines.append(ReceiptLine(label: "L\(index)", amount: .zero))
        }
        #expect(throws: ReceiptValidationError.tooManyLines(count: ReceiptLimits.maximumLinesPerReceipt + 1)) {
            try draft.validated()
        }

        var manyPeople = ReceiptDraft(expectedTotal: .zero, lines: [ReceiptLine(label: "X", amount: .zero)])
        for index in 0...ReceiptLimits.maximumParticipantsPerReceipt {
            manyPeople.participants.append(person("P\(index)", UInt8(index)))
        }
        #expect(throws: (any Error).self) { try manyPeople.validated() }
    }

    @Test("Empty receipts and blank labels refuse")
    func emptyGuards() {
        let personA = person("Ann", 1)
        let empty = ReceiptDraft(participants: [personA])
        #expect(throws: ReceiptValidationError.emptyReceipt) { try empty.validated() }
        var blank = ReceiptDraft(participants: [personA], lines: [ReceiptLine(label: "   ", amount: .zero)])
        blank.lines[0].amount = MinorAmount(minorUnits: 100)
        #expect(throws: ReceiptValidationError.emptyLineLabel) { try blank.validated() }
        // Negative item amounts refuse; adjustments may go negative but not zero.
        let negativeLine = ReceiptDraft(participants: [personA], lines: [ReceiptLine(label: "X", amount: MinorAmount(minorUnits: -1))])
        #expect(throws: ReceiptValidationError.lineAmountNegative) { try negativeLine.validated() }
        let zeroAdjustment = ReceiptDraft(
            participants: [personA],
            adjustments: [ReceiptAdjustment(label: "Nothing", amount: .zero)])
        #expect(throws: ReceiptValidationError.adjustmentAmountZero) { try zeroAdjustment.validated() }
    }

    @Test("Allocations referencing unknown participants or bad weights refuse")
    func allocationIntegrity() throws {
        let present = person("Ann", 1)
        let ghost = person("Ghost", 9)
        var draft = ReceiptDraft(
            participants: [present],
            lines: [ReceiptLine(label: "X", amount: MinorAmount(minorUnits: 100))])
        let lineID = draft.lines[0].id
        draft.lineAllocations[lineID] = RowAllocation(shares: [.init(participantID: ghost.id, weight: 1)])
        #expect(throws: ReceiptValidationError.unknownAllocationParticipant(ghost.id)) { try draft.validated() }
        draft.lineAllocations[lineID] = RowAllocation(shares: [.init(participantID: present.id, weight: 5_000)])
        #expect(throws: (any Error).self) { try draft.validated() }
        // An empty allocation row is representable (unresolved) but finalization
        // refuses it explicitly rather than defaulting.
        draft.lineAllocations[lineID] = RowAllocation(shares: [])
        #expect((try? draft.validated()) != nil)
        #expect(draft.unassignedRowIDs() == [lineID])
    }
}
