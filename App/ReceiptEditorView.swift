import Foundation
import ReceiptDomain
import SplitSlipCore
import SwiftUI

struct ReceiptEditorView: View {
    @State private var model: ReceiptWorkspaceModel
    private let onClose: () -> Void
    @State private var showDeleteParticipantAlert = false
    @State private var pendingRemoval: (id: UUID, name: String, rows: [String])?
    @State private var showCancelCorrectionAlert = false
    @State private var finalizedSnapshotID: UUID?
    /// Return-key / submit dismisses the soft keyboard so following controls
    /// stay reachable without gestures (accessibility: no drag-only flows).
    @FocusState private var focusedField: String?

    init(draft: ReceiptDraft, store: AnyReceiptStore, onClose: @escaping () -> Void) {
        _model = State(initialValue: ReceiptWorkspaceModel(draft: draft, store: store))
        self.onClose = onClose
    }

    var body: some View {
        List {
            headerSection
            participantsSection
            linesSection
            adjustmentsSection
            reviewSection
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.root")
        .navigationTitle(model.isCorrection ? "Correction draft" : "Receipt")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Finalize") {
                    finalizedSnapshotID = model.finalizeNow()
                }
                    .disabled(!model.canFinalize)
                    .accessibilityIdentifier("editor.finalize")
            }
            if focusedField != nil {
                ToolbarItem(placement: .keyboard) {
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("editor.dismissKeyboard")
                }
            }
            if model.isCorrection {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel correction") { showCancelCorrectionAlert = true }
                        .accessibilityIdentifier("editor.cancelCorrection")
                }
            }
        }
        .alert("Remove participant?", isPresented: $showDeleteParticipantAlert, presenting: pendingRemoval) { victim in
            Button("Remove \(victim.name)", role: .destructive) {
                model.removeParticipant(id: victim.id)
                pendingRemoval = nil
            }
            Button("Keep", role: .cancel) { pendingRemoval = nil }
        } message: { victim in
            Text(victim.rows.isEmpty
                 ? "This person is not on any allocated row."
                 : "Their rows (“\(victim.rows.joined(separator: ", "))”) will need new recipients — nothing is reassigned silently.")
        }
        .alert("Cancel this correction?", isPresented: $showCancelCorrectionAlert) {
            Button("Cancel correction", role: .destructive) {
                model.cancelCorrectionIfFork()
                onClose()
            }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The finalized receipt you duplicated stays exactly as it is.")
        }
        .onChange(of: finalizedSnapshotID, initial: false) { _, id in
            if id != nil { onClose() }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section("Receipt") {
            Picker("Currency", selection: Binding(
                get: { model.draft.currency },
                set: { model.setCurrency($0) })) {
                ForEach(SupportedCurrency.allCases, id: \.self) { currency in
                    Text(currency.rawValue).tag(currency)
                }
            }
            .accessibilityIdentifier("editor.currency")

            TextField("Printed grand total", text: Binding(
                get: { model.expectedTotalInput },
                set: { model.setExpectedTotal($0) }))
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .accessibilityIdentifier("editor.expectedTotal")
                .focused($focusedField, equals: "expectedTotal")
                .onSubmit { focusedField = nil }
            if let message = model.fieldMessages["expectedTotal"] {
                fieldError(message, key: "expectedTotal")
            }

            if let difference = model.difference(), difference != .zero {
                Label {
                    Text(difference.minorUnits > 0
                         ? "Rows are short of the total by \(difference)"
                         : "Rows exceed the total by \(MinorAmount(minorUnits: -difference.minorUnits))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .accessibilityIdentifier("editor.mismatch")
            } else if model.expectedTotalInput != "" {
                Label("Rows match the entered total", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("editor.matched")
            }
            if let message = model.fieldMessages["store"] {
                fieldError(message, key: "store")
            }
        }
    }

    private var participantsSection: some View {
        Section("People") {
            if model.draft.participants.isEmpty {
                Text("Add the people sharing this receipt.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.draft.participants, id: \.id) { participant in
                HStack {
                    Text(participant.displayName)
                    Spacer()
                    Button("Remove \(participant.displayName)") {
                        pendingRemoval = (participant.id, participant.displayName,
                                          model.affectedRowLabels(forRemoval: participant.id))
                        showDeleteParticipantAlert = true
                    }
                    .accessibilityIdentifier("editor.removeParticipant.\(participant.displayName)")
                }
            }
            HStack {
                TextField("Nickname", text: $model.participantNameInput)
                    .accessibilityIdentifier("editor.participantName")
                .focused($focusedField, equals: "participant")
                .onSubmit { focusedField = nil }
                Button("Add") { model.addParticipant() }
                    .accessibilityIdentifier("editor.addParticipant")
            }
            if let message = model.fieldMessages["participant"] {
                fieldError(message, key: "participant")
            }
        }
    }

    private var linesSection: some View {
        Section("Lines") {
            ForEach(Array(model.draft.lines.enumerated()), id: \.element.id) { index, line in
                lineRow(line, index: index)
            }
            Button("Add line") { model.addLine() }
                .accessibilityIdentifier("editor.addLine")
        }
    }

    private func lineRow(_ line: ReceiptLine, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Item name", text: Binding(
                get: { model.lineLabelInput[line.id] ?? "" },
                set: { model.setLineLabel(line.id, $0) }))
                .autocorrectionDisabled()
                .accessibilityIdentifier("editor.line.\(index).label")
                .focused($focusedField, equals: "line:\(index):label")
                .onSubmit { focusedField = nil }
            if let message = model.fieldMessages["line:\(line.id):label"] {
                fieldError(message, key: "line:\(line.id):label")
            }
            TextField("Amount", text: Binding(
                get: { model.lineAmountInput[line.id] ?? "" },
                set: { model.setLineAmount(line.id, $0) }))
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .accessibilityIdentifier("editor.line.\(index).amount")
                .focused($focusedField, equals: "line:\(index):amount")
                .onSubmit { focusedField = nil }
            if let message = model.fieldMessages["line:\(line.id):amount"] {
                fieldError(message, key: "line:\(line.id):amount")
            }
            allocationEditor(rowID: line.id, isAdjustment: false, index: index,
                             allocation: model.draft.lineAllocations[line.id] ?? RowAllocation(shares: []))
            if model.draft.rowsNeedingReview.contains(line.id) {
                Label("Needs review after a participant was removed", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("editor.line.\(index).needsReview")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var adjustmentsSection: some View {
        Section("Adjustments (fees, discounts)") {
            ForEach(Array(model.draft.adjustments.enumerated()), id: \.element.id) { index, adjustment in
                adjustmentRow(adjustment, index: index)
            }
            Button("Add adjustment") { model.addAdjustment() }
                .accessibilityIdentifier("editor.addAdjustment")
        }
    }

    private func adjustmentRow(_ adjustment: ReceiptAdjustment, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Fee or discount", text: Binding(
                get: { model.adjustmentLabelInput[adjustment.id] ?? "" },
                set: { model.setAdjustmentLabel(adjustment.id, $0) }))
                .autocorrectionDisabled()
                .accessibilityIdentifier("editor.adjustment.\(index).label")
                .focused($focusedField, equals: "adjustment:\(index):label")
                .onSubmit { focusedField = nil }
            TextField("Amount (− for discount)", text: Binding(
                get: { model.adjustmentAmountInput[adjustment.id] ?? "" },
                set: { model.setAdjustmentAmount(adjustment.id, $0) }))
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .accessibilityIdentifier("editor.adjustment.\(index).amount")
                .focused($focusedField, equals: "adjustment:\(index):amount")
                .onSubmit { focusedField = nil }
            if let message = model.fieldMessages["adjustment:\(adjustment.id):amount"] {
                fieldError(message, key: "adjustment:\(adjustment.id):amount")
            }
            allocationEditor(rowID: adjustment.id, isAdjustment: true, index: index,
                             allocation: model.draft.adjustmentAllocations[adjustment.id] ?? RowAllocation(shares: []))
        }
        .accessibilityElement(children: .contain)
    }

    private func allocationEditor(rowID: UUID, isAdjustment: Bool, index: Int, allocation: RowAllocation) -> some View {
        let prefix = isAdjustment ? "adjustment" : "line"
        return VStack(alignment: .leading, spacing: 6) {
            if allocation.isEmpty {
                Label("No one yet — unresolved, never shared automatically", systemImage: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("editor.\(prefix).\(index).unresolved")
            }
            Button("Split equally") { model.assignEqually(rowID: rowID, isAdjustment: isAdjustment) }
                .accessibilityIdentifier("editor.\(prefix).\(index).splitEqually")
            ForEach(model.draft.participants, id: \.id) { participant in
                let included = allocation.shares.first(where: { $0.participantID == participant.id })
                HStack {
                    Toggle(participant.displayName, isOn: Binding(
                        get: { included != nil },
                        set: { _ in model.toggleParticipant(participant.id, onRow: rowID, isAdjustment: isAdjustment) }))
                        .accessibilityIdentifier("editor.\(prefix).\(index).person.\(participant.displayName)")
                    if let included {
                        TextField("Weight", text: Binding(
                            get: { String(included.weight) },
                            set: { model.setWeight(participantID: participant.id, onRow: rowID, isAdjustment: isAdjustment, raw: $0) }))
                            .keyboardType(.numberPad)
                            .frame(width: 52)
                            .accessibilityIdentifier("editor.\(prefix).\(index).weight.\(participant.displayName)")
                .focused($focusedField, equals: "weight:\(prefix):\(index):\(participant.displayName)")
                .onSubmit { focusedField = nil }
                    }
                }
            }
        }
    }

    private var reviewSection: some View {
        Section("Review") {
            if model.emptyStateMessage == nil && model.draft.participants.isEmpty {
                Text("Add at least one participant.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.personReviews().enumerated()), id: \.element.id) { index, review in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(review.participant.displayName,
                                   value: review.total.map(\.description) ?? "— unresolved rows")
                        .accessibilityIdentifier("review.person.\(index).total")
                    ForEach(Array(review.extraCentNotes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("review.person.\(index).extraCent")
                    }
                    ForEach(Array(review.pendingRowLabels.enumerated()), id: \.offset) { _, label in
                        Text("Waiting on “\(label)”")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            ForEach(Array(model.finalizationBlockers().enumerated()), id: \.offset) { index, blocker in
                Label(blocker, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("review.blocker.\(index)")
            }
            if let message = model.fieldMessages["finalization"] {
                fieldError(message, key: "finalization")
            }
        }
    }

    private func fieldError(_ message: String, key: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("editor.error.\(key)")
    }
}
