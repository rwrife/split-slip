import Foundation

/// Algorithm/schema version stamped into every snapshot. Restore rejects
/// unknown versions instead of guessing (PLAN: migration rejection is tested).
public struct AlgorithmVersion: Hashable, Sendable, Codable, CustomStringConvertible {
    public let schema: Int
    public let allocationRule: Int

    public init(schema: Int, allocationRule: Int) {
        self.schema = schema
        self.allocationRule = allocationRule
    }

    public static let current = AlgorithmVersion(schema: 1, allocationRule: 1)

    /// Only v1 schema with allocation rule 1 exists so far; anything else is
    /// an explicit, testable rejection.
    public static func validateRestorable(_ version: AlgorithmVersion) throws {
        guard version.schema == 1 else { throw SnapshotVersionError.unsupportedSchema(version.schema) }
        guard (1...2).contains(version.allocationRule) else { throw SnapshotVersionError.unsupportedAllocationRule(version.allocationRule) }
    }

    public var description: String { "schema \(schema) / allocation rule \(allocationRule)" }
}

public enum SnapshotVersionError: Error, Hashable, Sendable {
    case unsupportedSchema(Int)
    case unsupportedAllocationRule(Int)
}

/// One person's resolved total inside a snapshot, carrying the row-level
/// shares that produced it so a cent is always explainable beside its reason.
public struct FinalizedPersonShare: Hashable, Sendable, Codable {
    public let participant: ParticipantIdentity
    public let totalMinorUnits: Int64
    /// Row id -> that person's signed minor units on the row.
    public let rowShares: [UUID: Int64]
    /// Row id -> fractional remainder used for the row's rounding decision.
    public let rowRemainders: [UUID: Int]

    public init(participant: ParticipantIdentity, totalMinorUnits: Int64, rowShares: [UUID: Int64], rowRemainders: [UUID: Int]) {
        self.participant = participant
        self.totalMinorUnits = totalMinorUnits
        self.rowShares = rowShares
        self.rowRemainders = rowRemainders
    }
}

/// The immutable, versioned record produced by finalization. Stored once,
/// never mutated; corrections fork a new draft via `correctionDraft()`.
public struct FinalizedReceiptSnapshot: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let sourceDraftID: UUID
    public let finalizedAt: Date
    public let algorithmVersion: AlgorithmVersion

    public let receiptSplit: [UUID: MinorAmount]?
    public let currency: SupportedCurrency
    public let expectedTotal: MinorAmount
    public let computedTotal: MinorAmount
    public let participants: [ParticipantIdentity]
    public let lines: [ReceiptLine]
    public let lineAllocations: [UUID: RowAllocation]
    public let adjustments: [ReceiptAdjustment]
    public let adjustmentAllocations: [UUID: RowAllocation]
    public let personShares: [FinalizedPersonShare]
    /// Set when this snapshot was itself produced from correcting a previous
    /// snapshot, making the correction chain inspectable in both directions.
    public let correctsSnapshotID: UUID?

    public init(
        id: UUID = UUID(),
        sourceDraftID: UUID,
        finalizedAt: Date,
        algorithmVersion: AlgorithmVersion,
        currency: SupportedCurrency,
        expectedTotal: MinorAmount,
        computedTotal: MinorAmount,
        participants: [ParticipantIdentity],
        lines: [ReceiptLine],
        lineAllocations: [UUID: RowAllocation],
        adjustments: [ReceiptAdjustment],
        adjustmentAllocations: [UUID: RowAllocation],
        personShares: [FinalizedPersonShare],
        correctsSnapshotID: UUID?,
        receiptSplit: [UUID: MinorAmount]? = nil
    ) {
        self.id = id
        self.receiptSplit = receiptSplit
        self.sourceDraftID = sourceDraftID
        self.finalizedAt = finalizedAt
        self.algorithmVersion = algorithmVersion
        self.currency = currency
        self.expectedTotal = expectedTotal
        self.computedTotal = computedTotal
        self.participants = participants
        self.lines = lines
        self.lineAllocations = lineAllocations
        self.adjustments = adjustments
        self.adjustmentAllocations = adjustmentAllocations
        self.personShares = personShares
        self.correctsSnapshotID = correctsSnapshotID
    }

    /// Fork a *new* linked draft from this snapshot. The snapshot itself is
    /// never reopened for editing (PLAN: no hidden mutation of shared results).
    public func correctionDraft() -> ReceiptDraft {
        ReceiptDraft(
            currency: currency,
            expectedTotal: expectedTotal,
            participants: participants,
            lines: lines,
            lineAllocations: lineAllocations,
            adjustments: adjustments,
            adjustmentAllocations: adjustmentAllocations,
            correctionOfSnapshotID: id,
            receiptSplit: receiptSplit
        )
    }
}

public enum FinalizationError: Error, Hashable, Sendable {
    case invalidStructure(ReceiptValidationError)
    case reconciliation(ReconciliationProblem)
    case money(MoneyParseError)
    case allocation(AllocationError)
}

public extension ReceiptDraft {
    /// Gate + freeze in one step. Finalize only when: the structure is
    /// valid, there is at least one participant, every row (lines *and*
    /// adjustments) has an explicit allocation, the entered grand total
    /// equals sum(items)+sum(adjustments), no person total is negative, and
    /// the person totals sum exactly to the expected total.
    /// Any failure throws with the specific problem — never a partial snapshot.
    func finalize(finalizedAt: Date = Date()) throws -> FinalizedReceiptSnapshot {
        let validatedDraft: ReceiptDraft
        do {
            validatedDraft = try validated()
        } catch let error as ReceiptValidationError {
            throw FinalizationError.invalidStructure(error)
        } catch let error as MoneyParseError {
            throw FinalizationError.money(error)
        }

        guard !validatedDraft.participants.isEmpty else {
            throw FinalizationError.reconciliation(.noParticipants)
        }

        let difference: MinorAmount
        let computed: MinorAmount
        do {
            computed = try validatedDraft.computedTotal()
            difference = try validatedDraft.difference()
        } catch let error as MoneyParseError {
            throw FinalizationError.money(error)
        }
        guard difference == .zero else {
            throw FinalizationError.reconciliation(.totalMismatch(difference: difference))
        }

        // Explicit unassigned check before totals so the error names a row.
        for rowID in validatedDraft.unassignedRowIDs() {
            throw FinalizationError.reconciliation(.unassignedRow(rowID: rowID))
        }

        if receiptSplit != nil {
            let totals = try validatedDraft.personTotals()
            return FinalizedReceiptSnapshot(
                sourceDraftID: id, finalizedAt: finalizedAt,
                algorithmVersion: AlgorithmVersion(schema: 1, allocationRule: 2),
                currency: currency, expectedTotal: expectedTotal, computedTotal: computed,
                participants: participants, lines: lines, lineAllocations: lineAllocations,
                adjustments: adjustments, adjustmentAllocations: adjustmentAllocations,
                personShares: participants.map { FinalizedPersonShare(participant: $0,
                    totalMinorUnits: totals[$0]!.minorUnits, rowShares: [:], rowRemainders: [:]) },
                correctsSnapshotID: correctionOfSnapshotID, receiptSplit: receiptSplit)
        }

        // Row-level shares, accumulated per person with exact conservation.
        let byID = Dictionary(uniqueKeysWithValues: validatedDraft.participants.map { ($0.id, $0) })
        var rowShares: [UUID: [UUID: Int64]] = [:]   // participant -> row -> units
        var rowRemainders: [UUID: [UUID: Int]] = [:]
        var personTotals: [UUID: Int64] = [:]

        func consume(amount: MinorAmount, allocation: RowAllocation, rowID: UUID) throws {
            var recipients: [(participant: ParticipantIdentity, weight: Int)] = []
            for share in allocation.shares {
                guard let identity = byID[share.participantID] else {
                    throw FinalizationError.invalidStructure(.unknownAllocationParticipant(share.participantID))
                }
                recipients.append((identity, share.weight))
            }
            let shares: [AllocatedShare]
            do {
                shares = try AllocationEngine.allocate(amount: amount, to: recipients)
            } catch let error as AllocationError {
                throw FinalizationError.allocation(error)
            }
            for share in shares {
                let pid = share.participant.id
                rowShares[pid, default: [:]][rowID] = share.minorUnits
                rowRemainders[pid, default: [:]][rowID] = share.remainder
                let current = personTotals[pid] ?? 0
                let r = current.addingReportingOverflow(share.minorUnits)
                guard !r.overflow else { throw FinalizationError.money(MoneyParseError.overflow) }
                personTotals[pid] = r.partialValue
            }
        }

        for line in validatedDraft.lines {
            try consume(amount: line.amount, allocation: validatedDraft.lineAllocations[line.id]!, rowID: line.id)
        }
        for adjustment in validatedDraft.adjustments {
            try consume(amount: adjustment.amount, allocation: validatedDraft.adjustmentAllocations[adjustment.id]!, rowID: adjustment.id)
        }

        var personSum: Int64 = 0
        var personShares: [FinalizedPersonShare] = []
        for participant in validatedDraft.participants {
            let total = personTotals[participant.id] ?? 0
            guard total >= 0 else {
                throw FinalizationError.reconciliation(.negativeParticipantTotal(participant: participant, minorUnits: total))
            }
            let r = personSum.addingReportingOverflow(total)
            guard !r.overflow else { throw FinalizationError.money(MoneyParseError.overflow) }
            personSum = r.partialValue
            personShares.append(FinalizedPersonShare(
                participant: participant,
                totalMinorUnits: total,
                rowShares: rowShares[participant.id] ?? [:],
                rowRemainders: rowRemainders[participant.id] ?? [:]
            ))
        }
        guard MinorAmount(minorUnits: personSum) == validatedDraft.expectedTotal else {
            throw FinalizationError.reconciliation(.personTotalsDisagree(
                expectedTotal: validatedDraft.expectedTotal,
                personSum: MinorAmount(minorUnits: personSum)))
        }

        return FinalizedReceiptSnapshot(
            sourceDraftID: id,
            finalizedAt: finalizedAt,
            algorithmVersion: .current,
            currency: currency,
            expectedTotal: expectedTotal,
            computedTotal: computed,
            participants: participants,
            lines: lines,
            lineAllocations: lineAllocations,
            adjustments: adjustments,
            adjustmentAllocations: adjustmentAllocations,
            personShares: personShares,
            correctsSnapshotID: correctionOfSnapshotID
        )
    }
}
