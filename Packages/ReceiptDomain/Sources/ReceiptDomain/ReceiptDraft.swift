import Foundation

/// Structural errors for receipt/draft validation. Kept separate from
/// `MoneyParseError` because these describe a whole receipt, not one string.
public enum ReceiptValidationError: Error, Hashable, Sendable {
    case tooManyLines(count: Int)
    case tooManyAdjustments(count: Int)
    case tooManyParticipants(count: Int)
    case duplicateParticipant(UUID)
    case emptyReceipt
    case emptyLineLabel
    case lineAmountNegative
    case adjustmentAmountZero
    case unknownAllocationParticipant(UUID)
    case weightOutOfRange(participant: UUID, weight: Int)
    case totalOutOfBounds(minorUnitsMagnitude: Int64)
}

/// A receipt line: nonnegative amount, positive quantity is expressed by the
/// caller through separate lines or weights (PLAN: no implicit per-unit math).
public struct ReceiptLine: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var label: String
    public var amount: MinorAmount

    public init(id: UUID = UUID(), label: String, amount: MinorAmount) {
        self.id = id
        self.label = label
        self.amount = amount
    }
}

/// An explicitly entered fee (positive) or discount (negative). The app never
/// infers percentages or tax treatment; the value is exactly what was printed.
public struct ReceiptAdjustment: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var label: String
    public var amount: MinorAmount

    public init(id: UUID = UUID(), label: String, amount: MinorAmount) {
        self.id = id
        self.label = label
        self.amount = amount
    }
}

/// Who shares one row and how. An empty recipient list is representable but
/// means *unresolved* — never "zero" and never "everyone".
public struct RowAllocation: Hashable, Sendable, Codable {
    public var shares: [ParticipantShare]

    public struct ParticipantShare: Hashable, Sendable, Codable {
        public let participantID: UUID
        public var weight: Int

        public init(participantID: UUID, weight: Int) {
            self.participantID = participantID
            self.weight = weight
        }
    }

    public init(shares: [ParticipantShare]) {
        self.shares = shares
    }

    public var isEmpty: Bool { shares.isEmpty }
}

/// A mutable receipt being worked on. Finalization produces an immutable
/// `FinalizedReceiptSnapshot`; corrections fork a *new* draft linked to the
/// snapshot, never mutating it.
public struct ReceiptDraft: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    /// nil preserves item-by-item splitting; an empty map means everyone splits equally.
    public var receiptSplit: [UUID: MinorAmount]?
    public var currency: SupportedCurrency
    /// The grand total printed on the receipt, entered by the user.
    public var expectedTotal: MinorAmount
    /// Stable, user-visible order. Tie priority in allocation follows this order.
    public var participants: [ParticipantIdentity]
    public var lines: [ReceiptLine]
    /// Allocation per line, keyed by line id. Missing key = unresolved row.
    public var lineAllocations: [UUID: RowAllocation]
    public var adjustments: [ReceiptAdjustment]
    public var adjustmentAllocations: [UUID: RowAllocation]
    /// When this draft was forked from a finalized snapshot, that snapshot's id.
    public var correctionOfSnapshotID: UUID?
    /// Rows whose allocation was invalidated (e.g. participant removed).
    /// Affected rows surface for review; costs are never silently reassigned.
    public var rowsNeedingReview: Set<UUID>

    public init(
        id: UUID = UUID(),
        currency: SupportedCurrency = .usd,
        expectedTotal: MinorAmount = .zero,
        participants: [ParticipantIdentity] = [],
        lines: [ReceiptLine] = [],
        lineAllocations: [UUID: RowAllocation] = [:],
        adjustments: [ReceiptAdjustment] = [],
        adjustmentAllocations: [UUID: RowAllocation] = [:],
        correctionOfSnapshotID: UUID? = nil,
        rowsNeedingReview: Set<UUID> = [],
        receiptSplit: [UUID: MinorAmount]? = nil
    ) {
        self.id = id
        self.receiptSplit = receiptSplit
        self.currency = currency
        self.expectedTotal = expectedTotal
        self.participants = participants
        self.lines = lines
        self.lineAllocations = lineAllocations
        self.adjustments = adjustments
        self.adjustmentAllocations = adjustmentAllocations
        self.correctionOfSnapshotID = correctionOfSnapshotID
        self.rowsNeedingReview = rowsNeedingReview
    }

    // MARK: - Structure validation

    public func validated() throws -> ReceiptDraft {
        guard lines.count <= ReceiptLimits.maximumLinesPerReceipt else {
            throw ReceiptValidationError.tooManyLines(count: lines.count)
        }
        guard adjustments.count <= ReceiptLimits.maximumAdjustmentsPerReceipt else {
            throw ReceiptValidationError.tooManyAdjustments(count: adjustments.count)
        }
        guard participants.count <= ReceiptLimits.maximumParticipantsPerReceipt else {
            throw ReceiptValidationError.tooManyParticipants(count: participants.count)
        }
        let ids = participants.map(\.id)
        if Set(ids).count != ids.count {
            var seen = Set<UUID>()
            for candidate in ids where !seen.insert(candidate).inserted {
                throw ReceiptValidationError.duplicateParticipant(candidate)
            }
        }
        guard !lines.isEmpty || !adjustments.isEmpty else {
            throw ReceiptValidationError.emptyReceipt
        }
        for line in lines {
            guard !line.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReceiptValidationError.emptyLineLabel
            }
            guard !line.amount.isNegative else { throw ReceiptValidationError.lineAmountNegative }
        }
        for adjustment in adjustments {
            guard adjustment.amount != .zero else { throw ReceiptValidationError.adjustmentAmountZero }
        }
        for (rowID, allocation) in lineAllocations {
            try validate(allocation: allocation, for: rowID, known: Set(participants.map(\.id)))
        }
        for (rowID, allocation) in adjustmentAllocations {
            try validate(allocation: allocation, for: rowID, known: Set(participants.map(\.id)))
        }
        _ = try expectedTotal.validated()
        return self
    }

    private func validate(allocation: RowAllocation, for rowID: UUID, known: Set<UUID>) throws {
        // An empty allocation is *representable* and means unresolved;
        // finalization refuses it explicitly. Structural checks below only
        // apply to shares that are present.
        let range = ReceiptLimits.minimumShareWeight...ReceiptLimits.maximumShareWeight
        for share in allocation.shares {
            guard known.contains(share.participantID) else {
                throw ReceiptValidationError.unknownAllocationParticipant(share.participantID)
            }
            guard range.contains(share.weight) else {
                throw ReceiptValidationError.weightOutOfRange(participant: share.participantID, weight: share.weight)
            }
        }
        _ = rowID
    }

    // MARK: - Participant removal

    /// Removes a participant and flags every row they touched for review,
    /// clearing that row's allocation so nothing is silently reallocated.
    public mutating func removeParticipant(id: UUID) {
        participants.removeAll { $0.id == id }
        receiptSplit?[id] = nil
        for (rowID, allocation) in lineAllocations where allocation.shares.contains(where: { $0.participantID == id }) {
            lineAllocations[rowID] = RowAllocation(shares: [])
            rowsNeedingReview.insert(rowID)
        }
        for (rowID, allocation) in adjustmentAllocations where allocation.shares.contains(where: { $0.participantID == id }) {
            adjustmentAllocations[rowID] = RowAllocation(shares: [])
            rowsNeedingReview.insert(rowID)
        }
    }

    // MARK: - Reconciliation

    /// Sum(items) + sum(adjustments) with checked arithmetic.
    public func computedTotal() throws -> MinorAmount {
        var total: Int64 = 0
        for line in lines {
            let r = total.addingReportingOverflow(line.amount.minorUnits)
            guard !r.overflow else { throw MoneyParseError.overflow }
            total = r.partialValue
        }
        for adjustment in adjustments {
            let r = total.addingReportingOverflow(adjustment.amount.minorUnits)
            guard !r.overflow else { throw MoneyParseError.overflow }
            total = r.partialValue
        }
        return MinorAmount(minorUnits: total)
    }

    /// expected grand total minus computed total; zero means the entered
    /// receipt reconciles with its rows.
    public func difference() throws -> MinorAmount {
        try expectedTotal.subtracting(computedTotal())
    }

    /// Rows (line ids + adjustment ids) whose allocation is missing or empty.
    public func unassignedRowIDs() -> [UUID] {
        if receiptSplit != nil && !participants.isEmpty { return [] }
        var unresolved: [UUID] = []
        for line in lines where lineAllocations[line.id]?.isEmpty ?? true {
            unresolved.append(line.id)
        }
        for adjustment in adjustments where adjustmentAllocations[adjustment.id]?.isEmpty ?? true {
            unresolved.append(adjustment.id)
        }
        return unresolved
    }

    private func receiptSplitTotals(_ fixed: [UUID: MinorAmount]) throws -> [ParticipantIdentity: MinorAmount] {
        guard !participants.isEmpty else { throw LibraryError.invalid("Add people to split this receipt.") }
        let known = Set(participants.map(\.id))
        guard Set(fixed.keys).isSubset(of: known) else { throw LibraryError.invalid("A fixed amount refers to a missing person.") }
        let total = try computedTotal().validated()
        var remainder = total
        var result: [ParticipantIdentity: MinorAmount] = [:]
        for person in participants {
            if let amount = fixed[person.id] {
                _ = try amount.validated()
                guard !amount.isNegative else { throw LibraryError.invalid("Person amounts cannot be negative.") }
                remainder = try remainder.subtracting(amount)
                result[person] = amount
            }
        }
        guard !remainder.isNegative else { throw LibraryError.invalid("Fixed amounts exceed the receipt items total. Lower an amount or clear it to make it automatic.") }
        let automatic = participants.filter { fixed[$0.id] == nil }
        if automatic.isEmpty {
            guard remainder == .zero else { throw LibraryError.invalid("Clear one person's amount to split the remaining balance automatically.") }
        } else {
            for share in try AllocationEngine.allocateEqually(amount: remainder, to: automatic) {
                result[share.participant] = MinorAmount(minorUnits: share.minorUnits)
            }
        }
        return result
    }

    /// Allocates every row through the engine and returns per-person totals
    /// (in participant order) plus exact-conservation confirmation. Throws if
    /// any row is unassigned or weights reference unknown people.
    public func personTotals() throws -> [ParticipantIdentity: MinorAmount] {
        if let fixed = receiptSplit { return try receiptSplitTotals(fixed) }
        var totals: [UUID: Int64] = [:]
        for participant in participants { totals[participant.id] = 0 }

        func accumulate(amount: MinorAmount, allocation: RowAllocation, rowID: UUID) throws {
            guard !allocation.isEmpty else {
                throw ReconciliationProblem.unassignedRow(rowID: rowID)
            }
            let byID = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
            var recipients: [(participant: ParticipantIdentity, weight: Int)] = []
            for share in allocation.shares {
                guard let identity = byID[share.participantID] else {
                    throw ReceiptValidationError.unknownAllocationParticipant(share.participantID)
                }
                recipients.append((identity, share.weight))
            }
            let shares = try AllocationEngine.allocate(amount: amount, to: recipients)
            for share in shares {
                let current = totals[share.participant.id] ?? 0
                let r = current.addingReportingOverflow(share.minorUnits)
                guard !r.overflow else { throw MoneyParseError.overflow }
                totals[share.participant.id] = r.partialValue
            }
        }

        for line in lines {
            try accumulate(amount: line.amount, allocation: lineAllocations[line.id] ?? RowAllocation(shares: []), rowID: line.id)
        }
        for adjustment in adjustments {
            try accumulate(amount: adjustment.amount, allocation: adjustmentAllocations[adjustment.id] ?? RowAllocation(shares: []), rowID: adjustment.id)
        }

        var result: [ParticipantIdentity: MinorAmount] = [:]
        for participant in participants {
            result[participant] = MinorAmount(minorUnits: totals[participant.id] ?? 0)
        }
        return result
    }
}

/// Reasons `finalize()` refuses. Each maps to one visible review state —
/// the app shows these; it never resolves them by assumption.
public enum ReconciliationProblem: Error, Hashable, Sendable {
    case totalMismatch(difference: MinorAmount)
    case unassignedRow(rowID: UUID)
    case noParticipants
    case negativeParticipantTotal(participant: ParticipantIdentity, minorUnits: Int64)
    case personTotalsDisagree(expectedTotal: MinorAmount, personSum: MinorAmount)
}
