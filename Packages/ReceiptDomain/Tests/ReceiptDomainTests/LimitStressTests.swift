import Foundation
import Testing
@testable import ReceiptDomain

/// Issue #6 criterion: stress deterministic rounding and quota/conservation
/// invariants *at the documented limits* (200 lines, 50 adjustments, 30
/// participants, 100,000,000 minor units, weights 1...1000) through the real
/// finalization pipeline — not just the engine — including participant
/// removal and a negative discount that leaves exactly one cent distributed.
/// These are pure-domain proofs: they run on Linux and macOS CI alike and
/// are supplementary to, never a replacement for, the native simulator gates.
@Suite("Issue 6 documented-limit stress through finalization")
struct LimitStressTests {
    private func person(_ seed: UInt8, _ name: String) -> ParticipantIdentity {
        ParticipantIdentity(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, seed)),
            displayName: name)
    }

    private func allPeople(_ people: [ParticipantIdentity], weight: Int) -> RowAllocation {
        RowAllocation(shares: people.map { RowAllocation.ParticipantShare(participantID: $0.id, weight: weight) })
    }

    /// Structurally maximal receipt: 200 lines at 500,000 cents each
    /// (exactly the 100,000,000 bound), 25 fee/discount pairs netting zero
    /// (50 adjustments), 30 participants, maximum weight 1000 on every line.
    private func makeMaximalDraft() throws -> ReceiptDraft {
        let people = (1...UInt8(ReceiptLimits.maximumParticipantsPerReceipt))
            .map { person($0, "P\($0)") }
        var lines: [ReceiptLine] = []
        var lineAllocations: [UUID: RowAllocation] = [:]
        for index in 0..<ReceiptLimits.maximumLinesPerReceipt {
            let line = ReceiptLine(label: "L\(index)", amount: MinorAmount(minorUnits: 500_000))
            lines.append(line)
            lineAllocations[line.id] = allPeople(people, weight: ReceiptLimits.maximumShareWeight)
        }
        var adjustments: [ReceiptAdjustment] = []
        var adjustmentAllocations: [UUID: RowAllocation] = [:]
        for index in 0..<(ReceiptLimits.maximumAdjustmentsPerReceipt / 2) {
            let fee = ReceiptAdjustment(label: "Fee\(index)", amount: MinorAmount(minorUnits: 500_000))
            let credit = ReceiptAdjustment(label: "Credit\(index)", amount: MinorAmount(minorUnits: -500_000))
            adjustments.append(fee)
            adjustments.append(credit)
            adjustmentAllocations[fee.id] = allPeople(people, weight: 1)
            adjustmentAllocations[credit.id] = allPeople(people, weight: 1)
        }
        return ReceiptDraft(
            expectedTotal: MinorAmount(minorUnits: ReceiptLimits.maximumAbsoluteTotalMinorUnits),
            participants: people,
            lines: lines,
            lineAllocations: lineAllocations,
            adjustments: adjustments,
            adjustmentAllocations: adjustmentAllocations)
    }

    @Test("Structurally maximal receipt finalizes with exact conservation")
    func maximalReceiptFinalizes() throws {
        let draft = try makeMaximalDraft()
        let snapshot = try draft.finalize(finalizedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.personShares.count == ReceiptLimits.maximumParticipantsPerReceipt)
        let personSum = snapshot.personShares.map(\.totalMinorUnits).reduce(Int64(0), +)
        #expect(personSum == ReceiptLimits.maximumAbsoluteTotalMinorUnits)
        #expect(snapshot.personShares.allSatisfy { $0.totalMinorUnits >= 0 })
        // Every line row conserves its 500,000 cents exactly.
        for line in snapshot.lines {
            let rowSum = snapshot.personShares.reduce(Int64(0)) { $0 + ($1.rowShares[line.id] ?? 0) }
            #expect(rowSum == 500_000, "line \(line.label) allocated \(rowSum)")
        }
        // Every adjustment row conserves its signed ±500,000 exactly.
        for adjustment in snapshot.adjustments {
            let rowSum = snapshot.personShares.reduce(Int64(0)) { $0 + ($1.rowShares[adjustment.id] ?? 0) }
            #expect(rowSum == adjustment.amount.minorUnits, "adjustment \(adjustment.label) allocated \(rowSum)")
        }
        // The shared export shows the exact bound total, no float drift.
        let text = ReceiptSummary.render(snapshot)
        #expect(text.contains("Receipt total: 1000000.00 USD"))
    }

    @Test("Maximal-receipt finalization is byte-for-byte deterministic")
    func maximalReceiptIsDeterministic() throws {
        let draft = try makeMaximalDraft()
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let a = try draft.finalize(finalizedAt: date)
        let b = try draft.finalize(finalizedAt: date)
        #expect(a.personShares == b.personShares)
        #expect(a.computedTotal == b.computedTotal)
    }

    @Test("Maximum-magnitude discount leaves one cent distributed to stored order")
    func oneCentLeftByMaxDiscountIsDeterministic() throws {
        // 1,000,000.00 line split evenly 30 ways, minus a 999,999.99 discount
        // split evenly 30 ways: rounding must leave exactly one cent, and the
        // winner must be person 9 by stored-order tie priority — never random.
        let people = (1...UInt8(30)).map { person($0, "P\($0)") }
        let line = ReceiptLine(label: "Grand", amount: MinorAmount(minorUnits: 100_000_000))
        let discount = ReceiptAdjustment(label: "Coupon", amount: MinorAmount(minorUnits: -99_999_999))
        let draft = ReceiptDraft(
            expectedTotal: MinorAmount(minorUnits: 1),
            participants: people,
            lines: [line],
            lineAllocations: [line.id: allPeople(people, weight: 1)],
            adjustments: [discount],
            adjustmentAllocations: [discount.id: allPeople(people, weight: 1)])
        let snapshot = try draft.finalize(finalizedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.personShares.map(\.totalMinorUnits).reduce(Int64(0), +) == 1)
        // Line: persons 0..<10 get 3,333,334, rest 3,333,333 (residual 10).
        // Discount: persons 0..<9 get -3,333,334, rest -3,333,333 (residual 9).
        // Net: person index 9 carries the single surviving cent.
        let totals = snapshot.personShares.map(\.totalMinorUnits)
        #expect(totals.reduce(0) { $1 == 1 ? $0 + 1 : $0 } == 1)
        #expect(totals[9] == 1)
        #expect(totals.enumerated().allSatisfy { index, value in index == 9 || value == 0 })
    }

    @Test("Extreme weight skew conserves and stays within one rounding step")
    func extremeWeightSkew() throws {
        // One person at the maximum weight against 29 people at the minimum,
        // at the full bound amount: the skewed person must absorb ~97.2% of
        // the total, everything is conserved, and every share sits within one
        // cent of its exact proportional value.
        let heavy = person(1, "Heavy")
        let others = (2...UInt8(30)).map { person($0, "P\($0)") }
        let line = ReceiptLine(label: "Cater", amount: MinorAmount(minorUnits: ReceiptLimits.maximumAbsoluteTotalMinorUnits))
        let allocation = RowAllocation(shares: [
            .init(participantID: heavy.id, weight: ReceiptLimits.maximumShareWeight),
        ] + others.map { .init(participantID: $0.id, weight: 1) })
        let draft = ReceiptDraft(
            expectedTotal: line.amount,
            participants: [heavy] + others,
            lines: [line],
            lineAllocations: [line.id: allocation])
        let snapshot = try draft.finalize(finalizedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let totals = snapshot.personShares.map(\.totalMinorUnits)
        #expect(totals.reduce(Int64(0), +) == ReceiptLimits.maximumAbsoluteTotalMinorUnits)
        let totalWeight = 1_000 + 29
        for share in snapshot.personShares {
            let weight = share.participant == heavy ? 1_000 : 1
            let exact = (ReceiptLimits.maximumAbsoluteTotalMinorUnits * Int64(weight)) / Int64(totalWeight)
            #expect(abs(share.totalMinorUnits - exact) <= 1, "\(share.participant.displayName) off by more than a cent")
        }
        #expect(snapshot.personShares.first?.totalMinorUnits ?? 0 > 97_000_000)
    }

    @Test("Removing a participant from a maximal receipt flags every row, never reallocates")
    func removalOnMaximalReceiptFlagsEverything() throws {
        let draft = try makeMaximalDraft()
        let victim = draft.participants[14]
        var broken = draft
        broken.removeParticipant(id: victim.id)
        #expect(broken.participants.count == ReceiptLimits.maximumParticipantsPerReceipt - 1)
        // The victim touched every row, so every one of the 250 rows must be
        // cleared AND flagged — the costs are never silently redistributed.
        #expect(broken.rowsNeedingReview.count == ReceiptLimits.maximumLinesPerReceipt + ReceiptLimits.maximumAdjustmentsPerReceipt)
        #expect(broken.unassignedRowIDs().count == ReceiptLimits.maximumLinesPerReceipt + ReceiptLimits.maximumAdjustmentsPerReceipt)
        #expect(throws: (any Error).self) { _ = try broken.finalize() }
    }

    @Test("ReceiptLibrary round-trips the maximal snapshot through backup validation")
    func maximalSnapshotPassesLibraryValidation() throws {
        // Restore-time validation recomputes finalization; the maximal
        // receipt must survive that re-derivation unchanged.
        let snapshot = try makeMaximalDraft().finalize(finalizedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let library = ReceiptLibrary(snapshots: [snapshot])
        try library.validate()  // throws on any inconsistency; test fails if it does
    }
}
