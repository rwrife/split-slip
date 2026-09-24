import Foundation
import Observation
import ReceiptDomain

/// One row in the person-review list: the running total plus the reasons a
/// cent may exceed the exact weighted share (PLAN: "display any extra cent
/// beside its reason").
public struct PersonReview: Identifiable, Hashable, Sendable {
    public let participant: ParticipantIdentity
    /// nil while the receipt still has unresolved rows.
    public let total: MinorAmount?
    public let extraCentNotes: [String]
    public let pendingRowLabels: [String]

    public var id: UUID { participant.id }
}

/// Everything the review surface shows for one row.
public struct RowReview: Identifiable, Hashable, Sendable {
    public let rowID: UUID
    public let label: String
    public let amount: MinorAmount
    public let allocation: RowAllocation
    public let isAdjustment: Bool
    public var id: UUID { rowID }

    public var isUnresolved: Bool { allocation.isEmpty }
}

/// View-model for one receipt being worked on (issue #3: manual entry
/// through reviewed finalization). All arithmetic delegates to
/// `ReceiptDomain`; this type only owns raw text fields, error copy and the
/// store interaction. Every successful edit auto-saves the draft; failed
/// validation keeps the previous stored state untouched.
@Observable
public final class ReceiptWorkspaceModel {
    public private(set) var draft: ReceiptDraft
    public let store: any DraftStore & SnapshotStore
    /// Optional issue #4 collaborators. `nil` keeps the model running the
    /// pure issue #3 flow (used by some unit tests); the app always injects.
    public let images: (any ReferenceImageStore)?
    public let continuity: (any ContinuityStore)?

    /// Restored/persisted workspace selection (tab, selected row/person,
    /// reference viewport). Views read it; they never own it.
    public private(set) var selection: WorkspaceSelection
    /// On-disk reference image for this receipt, if one has been imported.
    public private(set) var referenceImageURL: URL?

    // Raw user text (kept separate so invalid input never corrupts stored amounts).
    public var expectedTotalInput: String = ""
    public var personAmountInput: [UUID: String] = [:]
    public var participantNameInput: String = ""
    public var lineLabelInput: [UUID: String] = [:]
    public var lineAmountInput: [UUID: String] = [:]
    public var adjustmentLabelInput: [UUID: String] = [:]
    public var adjustmentAmountInput: [UUID: String] = [:]

    /// Field key -> visible message. Keys: "expectedTotal", "participant",
    /// "line:<id>:label", "line:<id>:amount", "adjustment:<id>:label",
    /// "adjustment:<id>:amount", "finalization", "store", "correction",
    /// "reference".
    public private(set) var fieldMessages: [String: String] = [:]
    public private(set) var isFinalized: Bool = false

    public init(
        draft: ReceiptDraft = ReceiptDraft(),
        store: any DraftStore & SnapshotStore,
        images: (any ReferenceImageStore)? = nil,
        continuity: (any ContinuityStore)? = nil
    ) {
        self.draft = draft
        self.store = store
        self.images = images
        self.continuity = continuity
        self.selection = continuity?.loadSelection(receiptID: draft.id) ?? WorkspaceSelection()
        self.referenceImageURL = try? images?.referenceImageURL(receiptID: draft.id)
        self.personAmountInput = draft.receiptSplit?.mapValues(\.description) ?? [:]
        self.expectedTotalInput = draft.expectedTotal == .zero ? "" : draft.expectedTotal.description
        for line in draft.lines {
            lineLabelInput[line.id] = line.label
            lineAmountInput[line.id] = line.amount.description
        }
        for adjustment in draft.adjustments {
            adjustmentLabelInput[adjustment.id] = adjustment.label
            adjustmentAmountInput[adjustment.id] = adjustment.amount.description
        }
    }

    // MARK: - Draft identity

    public var draftID: UUID { draft.id }
    public var isCorrection: Bool { draft.correctionOfSnapshotID != nil }

    // MARK: - Workspace continuity (issue #4)

    /// Persist the workspace selection (tab / selected row / selected person /
    /// reference viewport). Continuity failures are deliberately quiet: losing
    /// a selection must never surface as a receipt-data error.
    public func updateSelection(_ transform: (inout WorkspaceSelection) -> Void) {
        var next = selection
        transform(&next)
        selection = next.normalized()
        continuity?.saveSelection(selection, receiptID: draft.id)
    }

    public func selectTab(_ tab: WorkspaceSelection.Tab) {
        updateSelection { $0.tab = tab }
    }

    public func selectRow(_ rowID: UUID?) {
        updateSelection { $0.selectedRowID = rowID }
    }

    public func selectParticipant(_ participantID: UUID?) {
        updateSelection { $0.selectedParticipantID = participantID }
    }

    // MARK: - Reference image (issue #4)

    /// Import raw picker payload: sanitized (metadata stripped) then stored.
    /// Any failure keeps the previous image untouched and shows visible copy.
    /// - Returns: true when the new image replaced any previous one.
    @discardableResult
    public func importReferenceImage(payload: Data?) -> Bool {
        guard let payload else {
            // PhotosPicker cancel / unavailable asset: a no-op, not an error.
            return false
        }
        guard let images else {
            setFieldMessage("reference", "Reference images are unavailable right now.")
            return false
        }
        do {
            let sanitized = try ReferenceImageSandbox.sanitize(payload)
            try images.setReferenceImage(sanitized.jpeg, receiptID: draft.id)
            referenceImageURL = try images.referenceImageURL(receiptID: draft.id)
            setFieldMessage("reference", nil)
            return true
        } catch let error as ReferenceImageError {
            setFieldMessage("reference", DomainMessages.referenceImage(error))
            return false
        } catch {
            setFieldMessage("reference", "The image could not be stored. The previous reference is unchanged.")
            return false
        }
    }

    /// PhotosPicker returned an item but its data could not be loaded
    /// (denied/evicted asset). Visible refusal; nothing stored.
    public func referenceLoadFailed() {
        setFieldMessage("reference", "That photo could not be read from the library. Nothing was changed.")
    }

    public func removeReferenceImage() {
        guard let images else { return }
        do {
            try images.clearReferenceImage(receiptID: draft.id)
            referenceImageURL = nil
            setFieldMessage("reference", nil)
            // The viewport refers to a file that no longer exists.
            updateSelection {
                $0.referenceZoom = WorkspaceSelection.minimumZoom
                $0.referenceOffsetX = 0
                $0.referenceOffsetY = 0
            }
        } catch {
            setFieldMessage("reference", "The image could not be removed. Nothing else changed.")
        }
    }

    // MARK: - Helpers

    private func setFieldMessage(_ key: String, _ message: String?) {
        if let message { fieldMessages[key] = message } else { fieldMessages[key] = nil }
    }

    private func persist() {
        do {
            try store.saveDraft(draft)
            setFieldMessage("store", nil)
        } catch let error as StoreFailure {
            setFieldMessage("store", DomainMessages.store(error))
        } catch {
            setFieldMessage("store", "Could not save the draft: \(error).")
        }
    }

    // MARK: - Receipt header

    public func setCurrency(_ currency: SupportedCurrency) {
        guard draft.lines.isEmpty && draft.adjustments.isEmpty else {
            setFieldMessage("currency", "Currency is fixed once the receipt has rows.")
            return
        }
        setFieldMessage("currency", nil)
        draft.currency = currency
        persist()
    }

    public func setExpectedTotal(_ raw: String) {
        expectedTotalInput = raw
        guard !raw.isEmpty else {
            draft.expectedTotal = .zero
            setFieldMessage("expectedTotal", nil)
            persist()
            return
        }
        do {
            draft.expectedTotal = try MinorAmount(parsing: raw, currency: draft.currency)
            setFieldMessage("expectedTotal", nil)
            persist()
        } catch let error as MoneyParseError {
            setFieldMessage("expectedTotal", DomainMessages.moneyParse(error))
        } catch {
            setFieldMessage("expectedTotal", "Could not read that amount.")
        }
    }

    // MARK: - Participants

    public func addParticipant() {
        let name = participantNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            setFieldMessage("participant", "Enter a nickname first.")
            return
        }
        guard draft.participants.count < ReceiptLimits.maximumParticipantsPerReceipt else {
            setFieldMessage("participant", DomainMessages.receiptValidation(.tooManyParticipants(count: draft.participants.count + 1)))
            return
        }
        setFieldMessage("participant", nil)
        draft.participants.append(ParticipantIdentity(displayName: name))
        participantNameInput = ""
        persist()
    }

    /// Row labels a participant currently touches — shown by the UI's
    /// destructive confirmation before `removeParticipant` runs.
    public func affectedRowLabels(forRemoval participantID: UUID) -> [String] {
        var labels: [String] = []
        for line in draft.lines where draft.lineAllocations[line.id]?.shares.contains(where: { $0.participantID == participantID }) ?? false {
            labels.append(line.label)
        }
        for adjustment in draft.adjustments where draft.adjustmentAllocations[adjustment.id]?.shares.contains(where: { $0.participantID == participantID }) ?? false {
            labels.append(adjustment.label)
        }
        return labels
    }

    public func removeParticipant(id: UUID) {
        draft.removeParticipant(id: id)
        personAmountInput[id] = nil
        setFieldMessage("personAmount:\(id)", nil)
        if draft.receiptSplit != nil { draft.rowsNeedingReview = [] }
        persist()
    }

    // MARK: - Lines

    public func addLine() {
        guard draft.lines.count < ReceiptLimits.maximumLinesPerReceipt else {
            setFieldMessage("addLine", DomainMessages.receiptValidation(.tooManyLines(count: draft.lines.count + 1)))
            return
        }
        setFieldMessage("addLine", nil)
        draft.lines.append(ReceiptLine(label: "", amount: .zero))
        persist()
    }

    public func setLineLabel(_ id: UUID, _ raw: String) {
        lineLabelInput[id] = raw
        if let index = draft.lines.firstIndex(where: { $0.id == id }) {
            draft.lines[index].label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            persist()
        }
    }

    public func setLineAmount(_ id: UUID, _ raw: String) {
        lineAmountInput[id] = raw
        guard !raw.isEmpty else {
            if let index = draft.lines.firstIndex(where: { $0.id == id }) {
                draft.lines[index].amount = .zero
                setFieldMessage("line:\(id):amount", nil)
                persist()
            }
            return
        }
        do {
            let parsed = try MinorAmount(parsing: raw, currency: draft.currency)
            if parsed.isNegative {
                setFieldMessage("line:\(id):amount", "Line amounts cannot be negative; use an adjustment for discounts.")
                return
            }
            if let index = draft.lines.firstIndex(where: { $0.id == id }) {
                draft.lines[index].amount = parsed
                setFieldMessage("line:\(id):amount", nil)
                persist()
            }
        } catch let error as MoneyParseError {
            setFieldMessage("line:\(id):amount", DomainMessages.moneyParse(error))
        } catch {
            setFieldMessage("line:\(id):amount", "Could not read that amount.")
        }
    }

    public func removeLine(_ id: UUID) {
        draft.lines.removeAll { $0.id == id }
        draft.lineAllocations[id] = nil
        draft.rowsNeedingReview.remove(id)
        lineLabelInput[id] = nil
        lineAmountInput[id] = nil
        persist()
    }

    // MARK: - Adjustments

    public func addAdjustment() {
        guard draft.adjustments.count < ReceiptLimits.maximumAdjustmentsPerReceipt else {
            setFieldMessage("addAdjustment", DomainMessages.receiptValidation(.tooManyAdjustments(count: draft.adjustments.count + 1)))
            return
        }
        setFieldMessage("addAdjustment", nil)
        draft.adjustments.append(ReceiptAdjustment(label: "", amount: .zero))
        persist()
    }

    public func setAdjustmentLabel(_ id: UUID, _ raw: String) {
        adjustmentLabelInput[id] = raw
        if let index = draft.adjustments.firstIndex(where: { $0.id == id }) {
            draft.adjustments[index].label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            persist()
        }
    }

    /// Positive = fee, negative = discount — exactly as printed, never inferred.
    public func setAdjustmentAmount(_ id: UUID, _ raw: String) {
        adjustmentAmountInput[id] = raw
        guard !raw.isEmpty else {
            if let index = draft.adjustments.firstIndex(where: { $0.id == id }) {
                draft.adjustments[index].amount = .zero
                setFieldMessage("adjustment:\(id):amount", nil)
                persist()
            }
            return
        }
        do {
            let parsed = try MinorAmount(parsing: raw, currency: draft.currency)
            if parsed == .zero {
                setFieldMessage("adjustment:\(id):amount", "Adjustment amounts cannot be zero.")
                return
            }
            if let index = draft.adjustments.firstIndex(where: { $0.id == id }) {
                draft.adjustments[index].amount = parsed
                setFieldMessage("adjustment:\(id):amount", nil)
                persist()
            }
        } catch let error as MoneyParseError {
            setFieldMessage("adjustment:\(id):amount", DomainMessages.moneyParse(error))
        } catch {
            setFieldMessage("adjustment:\(id):amount", "Could not read that amount.")
        }
    }

    public func removeAdjustment(_ id: UUID) {
        draft.adjustments.removeAll { $0.id == id }
        draft.adjustmentAllocations[id] = nil
        draft.rowsNeedingReview.remove(id)
        adjustmentLabelInput[id] = nil
        adjustmentAmountInput[id] = nil
        persist()
    }

    // MARK: - Allocation

    public func assignEqually(rowID: UUID, isAdjustment: Bool) {
        guard !draft.participants.isEmpty else {
            setFieldMessage("finalization", DomainMessages.reconciliation(.noParticipants))
            return
        }
        setFieldMessage("finalization", nil)
        set(RowAllocation(shares: draft.participants.map { RowAllocation.ParticipantShare(participantID: $0.id, weight: 1) }), for: rowID, isAdjustment: isAdjustment)
    }

    /// Adds/removes one person from a row's recipients (default weight 1).
    public func toggleParticipant(_ participantID: UUID, onRow rowID: UUID, isAdjustment: Bool) {
        var allocation = currentAllocation(for: rowID, isAdjustment: isAdjustment) ?? RowAllocation(shares: [])
        if let index = allocation.shares.firstIndex(where: { $0.participantID == participantID }) {
            allocation.shares.remove(at: index)
        } else {
            allocation.shares.append(RowAllocation.ParticipantShare(participantID: participantID, weight: 1))
        }
        set(allocation, for: rowID, isAdjustment: isAdjustment)
    }

    public func setWeight(participantID: UUID, onRow rowID: UUID, isAdjustment: Bool, raw: String) {
        guard let weight = Int(raw),
              (ReceiptLimits.minimumShareWeight...ReceiptLimits.maximumShareWeight).contains(weight) else {
            setFieldMessage("weight:\(rowID):\(participantID)", "Weights must be whole numbers from \(ReceiptLimits.minimumShareWeight) to \(ReceiptLimits.maximumShareWeight).")
            return
        }
        setFieldMessage("weight:\(rowID):\(participantID)", nil)
        guard var allocation = currentAllocation(for: rowID, isAdjustment: isAdjustment),
              let index = allocation.shares.firstIndex(where: { $0.participantID == participantID }) else {
            return
        }
        allocation.shares[index].weight = weight
        set(allocation, for: rowID, isAdjustment: isAdjustment)
    }

    private func currentAllocation(for rowID: UUID, isAdjustment: Bool) -> RowAllocation? {
        isAdjustment ? draft.adjustmentAllocations[rowID] : draft.lineAllocations[rowID]
    }

    private func set(_ allocation: RowAllocation, for rowID: UUID, isAdjustment: Bool) {
        if isAdjustment { draft.adjustmentAllocations[rowID] = allocation }
        else { draft.lineAllocations[rowID] = allocation }
        if !allocation.isEmpty { draft.rowsNeedingReview.remove(rowID) }
        persist()
    }

    /// A single receipt-wide action. Future item edits and newly added people
    /// continue to participate in the automatic remainder.
    public func splitReceiptEqually() {
        draft.receiptSplit = [:]
        personAmountInput = [:]
        fieldMessages = fieldMessages.filter { !$0.key.hasPrefix("personAmount:") }
        draft.rowsNeedingReview = []
        persist()
    }

    public func useItemAssignments() {
        draft.receiptSplit = nil
        personAmountInput = [:]
        fieldMessages = fieldMessages.filter { !$0.key.hasPrefix("personAmount:") }
        persist()
    }

    public func setPersonAmount(_ id: UUID, _ raw: String) {
        guard draft.participants.contains(where: { $0.id == id }) else { return }
        personAmountInput[id] = raw
        let key = "personAmount:\(id)"
        do {
            let amount = raw.isEmpty ? nil : try MinorAmount(parsing: raw, currency: draft.currency)
            guard amount?.isNegative != true else { throw LibraryError.invalid("Person amounts cannot be negative.") }
            if draft.receiptSplit == nil { draft.receiptSplit = [:] }
            draft.rowsNeedingReview = []
            draft.receiptSplit?[id] = amount
            setFieldMessage(key, nil)
            persist()
        } catch {
            setFieldMessage(key, "Enter a valid nonnegative amount, or clear it for an automatic share.")
        }
    }

    // MARK: - Reconciliation views

    public func computedTotal() -> MinorAmount? {
        try? draft.computedTotal()
    }

    public func difference() -> MinorAmount? {
        try? draft.difference()
    }

    public var unassignedCount: Int { draft.unassignedRowIDs().count }

    public var hasRows: Bool { !draft.lines.isEmpty || !draft.adjustments.isEmpty }

    public var emptyStateMessage: String? {
        hasRows ? nil : "Add at least one line or adjustment to get started."
    }

    public func rowReviews() -> [RowReview] {
        draft.lines.map {
            RowReview(rowID: $0.id, label: $0.label, amount: $0.amount,
                      allocation: draft.lineAllocations[$0.id] ?? RowAllocation(shares: []),
                      isAdjustment: false)
        } + draft.adjustments.map {
            RowReview(rowID: $0.id, label: $0.label, amount: $0.amount,
                      allocation: draft.adjustmentAllocations[$0.id] ?? RowAllocation(shares: []),
                      isAdjustment: true)
        }
    }

    /// Per-person review: totals once every row resolves, plus a note beside
    /// each extra rounding cent and the labels of rows still unresolved.
    public func personReviews() -> [PersonReview] {
        if draft.receiptSplit != nil {
            let totals = try? draft.personTotals()
            return draft.participants.map { person in
                PersonReview(participant: person, total: totals?[person], extraCentNotes: [], pendingRowLabels: [])
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: draft.participants.map { ($0.id, $0) })
        var totals: [UUID: MinorAmount] = [:]
        var extraNotes: [UUID: [String]] = [:]
        var pending: [UUID: [String]] = [:]
        let totalsPossible = draft.unassignedRowIDs().isEmpty
        if totalsPossible {
            guard let computed = try? draft.personTotals() else {
                return draft.participants.map {
                    PersonReview(participant: $0, total: nil, extraCentNotes: [], pendingRowLabels: ["unresolved rows"])
                }
            }
            for (identity, total) in computed { totals[identity.id] = total }
            for review in rowReviews() {
                guard !review.allocation.isEmpty else { continue }
                var recipients: [(participant: ParticipantIdentity, weight: Int)] = []
                for share in review.allocation.shares {
                    guard let identity = byID[share.participantID] else { continue }
                    recipients.append((identity, share.weight))
                }
                guard let shares = try? AllocationEngine.allocate(amount: review.amount, to: recipients) else { continue }
                let sumWeight = recipients.reduce(0) { $0 + $1.weight }
                for share in shares {
                    // base share vs. awarded share reveals the extra cent.
                    let base = review.amount.magnitude.multipliedReportingOverflow(by: Int64(share.weight))
                    guard !base.overflow else { continue }
                    let floored = abs(base.partialValue / Int64(sumWeight))
                    let awarded = abs(share.minorUnits)
                    if awarded > floored {
                        extraNotes[share.participant.id, default: []].append(
                            "+1¢ on “\(review.label.isEmpty ? "row" : review.label)” — largest fractional remainder")
                    }
                }
            }
        } else {
            for review in rowReviews() where review.isUnresolved {
                for participant in draft.participants {
                    pending[participant.id, default: []].append(review.label.isEmpty ? "untitled row" : review.label)
                }
            }
        }

        return draft.participants.map { participant in
            PersonReview(
                participant: participant,
                total: totalsPossible ? (totals[participant.id] ?? .zero) : nil,
                extraCentNotes: extraNotes[participant.id] ?? [],
                pendingRowLabels: pending[participant.id] ?? [])
        }
    }

    /// Non-empty when finalization must stay blocked; each entry is visible copy.
    public func finalizationBlockers() -> [String] {
        var blockers = fieldMessages.filter { $0.key.hasPrefix("personAmount:") }.map(\.value)
        do {
            _ = try draft.validated()
        } catch let error as ReceiptValidationError {
            blockers.append(DomainMessages.receiptValidation(error))
        } catch let error as MoneyParseError {
            blockers.append(DomainMessages.moneyParse(error))
        } catch {
            blockers.append("The draft failed validation.")
        }
        if draft.participants.isEmpty {
            blockers.append(DomainMessages.reconciliation(.noParticipants))
        }
        if let difference = try? draft.difference(), difference != .zero {
            blockers.append(DomainMessages.reconciliation(.totalMismatch(difference: difference)))
        }
        let unassigned = draft.unassignedRowIDs()
        if !unassigned.isEmpty {
            blockers.append("\(unassigned.count) row\(unassigned.count == 1 ? "" : "s") still unresolved — pick recipients.")
        }
        if blockers.isEmpty {
            // Person-total sanity only once everything above passes.
            do {
                let totals = try draft.personTotals()
                for (participant, total) in totals where total.isNegative {
                    blockers.append(DomainMessages.reconciliation(.negativeParticipantTotal(participant: participant, minorUnits: total.minorUnits)))
                }
            } catch let error as ReconciliationProblem {
                blockers.append(DomainMessages.reconciliation(error))
            } catch let error as ReceiptValidationError {
                blockers.append(DomainMessages.receiptValidation(error))
            } catch {
                blockers.append(error.localizedDescription)
            }
        }
        return blockers
    }

    public var canFinalize: Bool { finalizationBlockers().isEmpty }

    // MARK: - Finalization

    /// Freezes the draft into an immutable snapshot. Returns the snapshot id
    /// on success; on failure the draft, the store and `isFinalized` are
    /// untouched and `finalizationBlockers()` explains why.
    public func finalizeNow(finalizedAt: Date = Date()) -> UUID? {
        let blockers = finalizationBlockers()
        guard blockers.isEmpty else {
            setFieldMessage("finalization", blockers.joined(separator: " "))
            return nil
        }
        do {
            let snapshot = try draft.finalize(finalizedAt: finalizedAt)
            // Prepare the owned photo first so a failed copy cannot silently
            // finalize a receipt without its reference. Keep the draft intact.
            if let images, referenceImageURL != nil {
                try images.copyReference(from: draft.id, to: snapshot.id)
            }
            do {
                if let libraryStore = store as? any ReceiptLibraryStore {
                    var library = try libraryStore.readLibrary()
                    library.drafts.removeAll { $0.id == draft.id }
                    library.snapshots.append(snapshot)
                    try libraryStore.replaceLibrary(library)
                } else {
                    // Compatibility for minimal injected stores; the app uses
                    // the transactional ReceiptLibraryStore path above.
                    try store.storeSnapshot(snapshot)
                    try store.deleteDraft(id: draft.id)
                }
            } catch {
                try? images?.clearReferenceImage(receiptID: snapshot.id)
                throw error
            }
            try? images?.clearReferenceImage(receiptID: draft.id)
            if let continuity {
                continuity.copySelection(from: draft.id, to: snapshot.id)
                continuity.clearSelection(receiptID: draft.id)
            }
            isFinalized = true
            setFieldMessage("finalization", nil)
            setFieldMessage("store", nil)
            return snapshot.id
        } catch let error as FinalizationError {
            setFieldMessage("finalization", DomainMessages.finalization(error))
            return nil
        } catch let error as StoreFailure {
            setFieldMessage("store", DomainMessages.store(error))
            return nil
        } catch {
            setFieldMessage("finalization", "Finalization failed: \(error)")
            return nil
        }
    }

    // MARK: - Correction (duplicate-to-correct)

    /// Fork a *new* draft from a stored snapshot. The snapshot is never
    /// re-opened for editing; the fork carries `correctionOfSnapshotID`.
    public static func correctionDraft(from snapshot: FinalizedReceiptSnapshot) -> ReceiptDraft {
        snapshot.correctionDraft()
    }

    /// Explicitly cancel a correction fork: the fork's draft edits are
    /// discarded, the original snapshot is untouched (data-loss-free cancel).
    public func cancelCorrectionIfFork() {
        guard draft.correctionOfSnapshotID != nil else { return }
        try? store.deleteDraft(id: draft.id)
        // Release the fork's own continuity keys; the snapshot's remain.
        try? images?.clearReferenceImage(receiptID: draft.id)
        continuity?.clearSelection(receiptID: draft.id)
        fieldMessages["correction"] = "Correction cancelled — the finalized receipt is unchanged."
    }
}
