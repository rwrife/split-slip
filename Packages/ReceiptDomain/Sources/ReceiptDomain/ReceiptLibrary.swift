import Foundation

public enum LibraryError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

/// A validated replacement, not a merge. Empty and unfinished drafts are legal.
public struct ReceiptLibrary: Codable, Sendable {
    public var drafts: [ReceiptDraft]
    public var snapshots: [FinalizedReceiptSnapshot]
    public init(drafts: [ReceiptDraft] = [], snapshots: [FinalizedReceiptSnapshot] = []) {
        self.drafts = drafts; self.snapshots = snapshots
    }
    public var receiptIDs: Set<UUID> { Set(drafts.map(\.id) + snapshots.map(\.id)) }

    public func validate() throws {
        guard drafts.count + snapshots.count <= 1_000 else { throw LibraryError.invalid("A backup may contain at most 1,000 receipts.") }
        guard receiptIDs.count == drafts.count + snapshots.count else { throw LibraryError.invalid("Duplicate receipt IDs.") }
        for draft in drafts { try Self.validateDraft(draft) }
        for snapshot in snapshots {
            try AlgorithmVersion.validateRestorable(snapshot.algorithmVersion)
            let draft = ReceiptDraft(id: snapshot.sourceDraftID, currency: snapshot.currency,
                expectedTotal: snapshot.expectedTotal, participants: snapshot.participants,
                lines: snapshot.lines, lineAllocations: snapshot.lineAllocations,
                adjustments: snapshot.adjustments, adjustmentAllocations: snapshot.adjustmentAllocations)
            try Self.validateDraft(draft)
            let recalculated = try draft.finalize(finalizedAt: snapshot.finalizedAt)
            guard recalculated.computedTotal == snapshot.computedTotal,
                  recalculated.personShares == snapshot.personShares,
                  zip(recalculated.personShares, snapshot.personShares).allSatisfy({ $0.participant.displayName == $1.participant.displayName }) else {
                throw LibraryError.invalid("A finalized receipt has inconsistent totals or shares.")
            }
        }
    }

    private static func validateDraft(_ draft: ReceiptDraft) throws {
        func require(_ valid: Bool, _ reason: String) throws {
            guard valid else { throw LibraryError.invalid(reason) }
        }
        func amount(_ value: MinorAmount) throws {
            let limit = ReceiptLimits.maximumAbsoluteTotalMinorUnits
            try require(value.minorUnits >= -limit && value.minorUnits <= limit, "An amount is outside the supported range.")
        }
        try require(draft.lines.count <= 200 && draft.adjustments.count <= 50 && draft.participants.count <= 30, "A receipt exceeds the item or people limits.")
        let people = Set(draft.participants.map(\.id))
        try require(people.count == draft.participants.count, "Duplicate participant IDs.")
        let lineIDs = Set(draft.lines.map(\.id)), adjustmentIDs = Set(draft.adjustments.map(\.id))
        try require(lineIDs.count == draft.lines.count && adjustmentIDs.count == draft.adjustments.count && lineIDs.isDisjoint(with: adjustmentIDs), "Duplicate row IDs.")
        try require(Set(draft.lineAllocations.keys).isSubset(of: lineIDs) && Set(draft.adjustmentAllocations.keys).isSubset(of: adjustmentIDs), "An allocation refers to a missing row.")
        try require(draft.rowsNeedingReview.isSubset(of: lineIDs.union(adjustmentIDs)), "A review marker refers to a missing row.")
        try amount(draft.expectedTotal)
        try require(!draft.expectedTotal.isNegative, "Receipt totals must not be negative.")
        for name in draft.participants.map(\.displayName) + draft.lines.map(\.label) + draft.adjustments.map(\.label) {
            try require(name.utf8.count <= 4_096, "A receipt label is too long.")
        }
        for line in draft.lines { try amount(line.amount); try require(!line.amount.isNegative, "Item amounts must not be negative.") }
        for adjustment in draft.adjustments { try amount(adjustment.amount) }
        for allocation in Array(draft.lineAllocations.values) + Array(draft.adjustmentAllocations.values) {
            let recipients = Set(allocation.shares.map(\.participantID))
            try require(recipients.count == allocation.shares.count && recipients.isSubset(of: people), "Duplicate or unknown allocation recipient.")
            try require(allocation.shares.allSatisfy { (1...1_000).contains($0.weight) }, "Invalid split weight.")
        }
        try amount(draft.computedTotal())
    }
}

public protocol ReceiptLibraryStore: DraftStore, SnapshotStore {
    /// Must atomically replace both collections or leave both untouched.
    func replaceLibrary(_ library: ReceiptLibrary) throws
}

public extension ReceiptLibraryStore {
    func readLibrary() throws -> ReceiptLibrary {
        ReceiptLibrary(drafts: try loadAllDrafts(), snapshots: try loadAllSnapshots())
    }
}
