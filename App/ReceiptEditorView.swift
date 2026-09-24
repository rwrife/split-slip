import Foundation
import PhotosUI
import ReceiptDomain
import SplitSlipCore
import SwiftUI
import UIKit

/// Issue #4 editor layout: a Receipt tab (entries + adjustments + reference
/// image) and a People tab (participants + per-person review), plus a
/// reconciliation bar that stays visible on both tabs.
///
/// Continuity rule (PLAN): the selected tab, selected line/person and the
/// reference viewport live in `ReceiptWorkspaceModel.selection`
/// (`WorkspaceSelection`), NOT in view-local state, so navigation, app
/// relaunch and rotation can never lose them. Layout never drives state.
///
/// Accessibility: every state has a text/symbol companion (no color-only
/// indicators), all interactions have button alternatives (the reference
/// pan/zoom gestures are supplements to explicit buttons, never required),
/// controls are standard List buttons (44pt targets) and Dynamic Type sizes
/// flow through `.font(.body)`-family styles. No custom animations exist, so
/// Reduce Motion has nothing to suppress.
///
/// Future iPhone Duo: this view's surfaces map onto two native dual-screen
/// safe regions ONLY when public APIs exist; see
/// docs/issue-4-evidence.md (`ReceiptWorkspaceLayout` notes). No fold
/// detection, no hinge assumptions, no iPad implementation.
struct ReceiptEditorView: View {
    @State private var model: ReceiptWorkspaceModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let onClose: () -> Void
    @State private var showDeleteParticipantAlert = false
    @State private var pendingRemoval: (id: UUID, name: String, rows: [String])?
    @State private var showCancelCorrectionAlert = false
    @State private var finalizedSnapshotID: UUID?
    @State private var rowToRemove: (id: UUID, adjustment: Bool, label: String)?
    @State private var pickerItems: [PhotosPickerItem] = []
    /// Return-key / submit dismisses the soft keyboard so following controls
    /// stay reachable without gestures (accessibility: no drag-only flows).
    @FocusState private var focusedField: String?

    init(draft: ReceiptDraft, store: AnyReceiptStore,
         images: (any ReferenceImageStore)? = nil,
         continuity: (any ContinuityStore)? = nil,
         onClose: @escaping () -> Void) {
        _model = State(initialValue: ReceiptWorkspaceModel(
            draft: draft, store: store, images: images, continuity: continuity))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            // Reconciliation strip pinned under the nav bar: visible on both
            // tabs, never inside the virtualized List, and away from the tab
            // bar so keyboard layout passes can't move tab items.
            reconciliationBar
            HStack {
                Button("Split equally", systemImage: "equal.circle.fill") { model.splitReceiptEqually() }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(model.draft.participants.isEmpty)
                    .accessibilityIdentifier("editor.splitEqually")
                if model.draft.receiptSplit != nil {
                    Button("Assign by item") { model.useItemAssignments() }
                        .accessibilityIdentifier("editor.assignByItem")
                }
            }
            .padding(.horizontal).padding(.bottom, 8)
            .frame(maxWidth: .infinity).background(SlipStyle.canvas)
            TabView(selection: Binding(
                get: { model.selection.tab },
                set: { model.selectTab($0) })) {
                receiptTab
                    .tabItem { Label("Receipt", systemImage: "list.bullet") }
                    .tag(WorkspaceSelection.Tab.receipt)
                peopleTab
                    .tabItem { Label("People", systemImage: "person.2") }
                    .tag(WorkspaceSelection.Tab.people)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.root")
        .tint(SlipStyle.accent)
        .navigationTitle(model.isCorrection ? "Make a correction" : "Let’s split it")
        .navigationBarTitleDisplayMode(.inline)
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
            Text(model.draft.receiptSplit != nil
                 ? "Their fixed amount will be removed and the remainder recalculated for the remaining people."
                 : (victim.rows.isEmpty ? "This person is not on any allocated row." : "Their rows (“\(victim.rows.joined(separator: ", "))”) will need new recipients — nothing is reassigned silently."))
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
        .alert("Remove this item?", isPresented: Binding(get: { rowToRemove != nil }, set: { if !$0 { rowToRemove = nil } })) {
            Button("Remove item", role: .destructive) {
                if let row = rowToRemove {
                    if row.adjustment { model.removeAdjustment(row.id) } else { model.removeLine(row.id) }
                }
                rowToRemove = nil
            }
            Button("Keep item", role: .cancel) { rowToRemove = nil }
        } message: { Text("\(rowToRemove?.label ?? "This item") and its assignments will be removed. Check your receipt total afterward.") }
        .onChange(of: pickerItems, initial: false) { _, items in
            guard let item = items.first else { return }
            Task {
                // A picker cancel leaves `pickerItems` empty: no data request,
                // no error, no change to the stored reference.
                do {
                    if let payload = try await item.loadTransferable(type: Data.self) {
                        model.importReferenceImage(payload: payload)
                    } else {
                        model.referenceLoadFailed()
                    }
                } catch {
                    model.referenceLoadFailed()
                }
                pickerItems = []
            }
        }
        .onChange(of: finalizedSnapshotID, initial: false) { _, id in
            if id != nil { onClose() }
        }
    }

    // MARK: - Reconciliation bar (visible on both tabs)

    private var reconciliationBar: some View {
        let selectedRowLabel = model.draft.lines.first(where: { $0.id == model.selection.selectedRowID })?.label
            ?? model.draft.adjustments.first(where: { $0.id == model.selection.selectedRowID })?.label
        let selectedPersonName = model.draft.participants.first(where: { $0.id == model.selection.selectedParticipantID })?.displayName
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("THE RECEIPT TOTAL").font(.caption2.weight(.bold)).tracking(1)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(model.draft.expectedTotal) \(model.draft.currency.rawValue)")
                        .font(.system(dynamicTypeSize.isAccessibilitySize ? .headline : .title2, design: .rounded, weight: .bold)).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Receipt total \(model.draft.expectedTotal) \(model.draft.currency.rawValue)")
                }
                Spacer()
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: model.canFinalize ? "checkmark.seal.fill" : "receipt")
                        .font(.title).foregroundStyle(SlipStyle.accent).accessibilityHidden(true)
                }
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
            HStack {
                if model.unassignedCount > 0 {
                    Label("\(model.unassignedCount) row\(model.unassignedCount == 1 ? "" : "s") unresolved",
                          systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("editor.bar.unresolved")
                }
                if selectedRowLabel != nil || selectedPersonName != nil {
                    Spacer(minLength: 4)
                    Text("Line: \(selectedRowLabel ?? "none") · Person: \(selectedPersonName ?? "none")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("editor.bar.selection")
                }
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 14)
        .background(SlipStyle.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.reconcileBar")
    }

    // MARK: - Receipt tab

    private var receiptTab: some View {
        List {
            headerSection
            linesSection
            adjustmentsSection
            referenceSection
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.receiptTab")
        .scrollContentBackground(.hidden)
        .background(SlipStyle.canvas)
        .buttonStyle(.borderless)
    }

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
            if let message = model.fieldMessages["store"] {
                fieldError(message, key: "store")
            }
        }
    }

    // MARK: - Reference photo (issue #4)

    @ViewBuilder
    private var referenceSection: some View {
        Section {
            if let imageURL = model.referenceImageURL {
                ReferenceViewportView(imageURL: imageURL, model: model)
                Button("Remove reference") { model.removeReferenceImage() }
                    .accessibilityIdentifier("editor.reference.remove")
            } else {
                PhotosPicker("Add reference photo",
                             selection: $pickerItems,
                             matching: .images,
                             photoLibrary: .shared())
                    .accessibilityIdentifier("editor.reference.pick")
                Text("Optional. Only the photo you pick is copied in, re-encoded with location and camera metadata removed. The photo library itself is not read.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let message = model.fieldMessages["reference"] {
                fieldError(message, key: "reference")
            }
        } header: {
            Text("Reference photo")
        }
        // NEVER put accessibilityIdentifier on a Section: SwiftUI cascades
        // it onto every child element in the List section, overwriting the
        // children's own identifiers (proven by the run 35849431871 AX
        // snapshot: every reference control surfaced as
        // identifier='editor.reference.section', so editor.reference.zoomIn
        // never existed and every reveal failed). The section is identified
        // through its header text and child identifiers instead.
    }

    // MARK: - People tab

    private var peopleTab: some View {
        List {
            participantsSection
            personAmountsSection
            reviewSection
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.peopleTab")
        .scrollContentBackground(.hidden)
        .background(SlipStyle.canvas)
        .buttonStyle(.borderless)
    }

    private var personAmountsSection: some View {
        Section {
            ForEach(model.draft.participants, id: \.id) { person in
                VStack(alignment: .leading, spacing: 6) {
                    let total = model.personReviews().first { $0.id == person.id }?.total
                    LabeledContent(person.displayName) {
                        Text(total?.description ?? "—").monospacedDigit()
                    }
                    TextField("Automatic share", text: Binding(
                        get: { model.personAmountInput[person.id] ?? "" },
                        set: { model.setPersonAmount(person.id, $0) }))
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Amount for \(person.displayName)")
                        .accessibilityIdentifier("editor.person.\(person.displayName).amount")
                        .focused($focusedField, equals: "personAmount:\(person.id)")
                    Text(model.draft.receiptSplit == nil ? "Currently assigned by item · enter an amount to split the whole receipt" : (model.draft.receiptSplit?[person.id] == nil ? "Automatic · shares the remainder" : "Fixed amount · clear to make automatic"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = model.fieldMessages["personAmount:\(person.id)"] {
                        fieldError(message, key: "personAmount:\(person.id)")
                    }
                }
            }
        } header: { Text("Split the receipt") }
        footer: { Text("Enter an amount for anyone paying a fixed share. The rest is split equally among the others and updates when receipt items change. Extra cents go in people order.") }
    }

    private var participantsSection: some View {
        Section("People") {
            if model.draft.participants.isEmpty {
                Text("Add the people sharing this receipt.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.draft.participants, id: \.id) { participant in
                let isSelected = model.selection.selectedParticipantID == participant.id
                HStack {
                    Text(participant.displayName)
                    if isSelected {
                        // Non-color-only selection indicator. Exposed as an
                        // accessibility element so it is a hittable leaf in
                        // the XCUITest tree (a merged/icon-only Label would
                        // otherwise report isHittable == false).
                        Label("Selected", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("\(participant.displayName) selected")
                            .accessibilityIdentifier("editor.person.\(participant.displayName).selected")
                            .accessibilityElement()
                    }
                    Spacer()
                    Button(isSelected ? "Deselect" : "Select") {
                        model.selectParticipant(isSelected ? nil : participant.id)
                    }
                    .accessibilityIdentifier("editor.person.\(participant.displayName).select")
                    Button {
                        pendingRemoval = (participant.id, participant.displayName,
                                          model.affectedRowLabels(forRemoval: participant.id))
                        showDeleteParticipantAlert = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.minus").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Remove \(participant.displayName)")
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

    // MARK: - Lines and adjustments (Receipt tab)

    private var linesSection: some View {
        Section {
            ForEach(Array(model.draft.lines.enumerated()), id: \.element.id) { index, line in
                lineRow(line, index: index)
            }
            Button { model.addLine() } label: {
                Label("Add an item", systemImage: "plus.circle.fill").frame(minHeight: 44)
            }.accessibilityIdentifier("editor.addLine")
        } header: { Text("What’s on the receipt?") }
        footer: { Text(model.draft.totalOnlyLineID != nil
            ? "This item follows your receipt total. Add people and tap Split equally, or add individual items instead."
            : "Enter each printed line total, then choose who shares it.") }
    }

    private func lineRow(_ line: ReceiptLine, index: Int) -> some View {
        let isSelected = model.selection.selectedRowID == line.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Item name", text: Binding(
                    get: { model.lineLabelInput[line.id] ?? "" },
                    set: { model.setLineLabel(line.id, $0) }))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("editor.line.\(index).label")
                    .focused($focusedField, equals: "line:\(index):label")
                    .onSubmit { focusedField = nil }
                if isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Line \(line.label) selected")
                        .accessibilityIdentifier("editor.line.\(index).selected")
                }
                Button(isSelected ? "Deselect" : "Select") {
                    model.selectRow(isSelected ? nil : line.id)
                }
                .accessibilityIdentifier("editor.line.\(index).select")
                Button { rowToRemove = (line.id, false, line.label) } label: {
                    Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Remove \(line.label)")
                    .accessibilityIdentifier("editor.line.\(index).remove")
            }
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
            if model.draft.receiptSplit == nil { allocationEditor(rowID: line.id, isAdjustment: false, index: index,
                             allocation: model.draft.lineAllocations[line.id] ?? RowAllocation(shares: [])) }
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
        Section("The little extras") {
            ForEach(Array(model.draft.adjustments.enumerated()), id: \.element.id) { index, adjustment in
                adjustmentRow(adjustment, index: index)
            }
            Button("Add adjustment") { model.addAdjustment() }
                .accessibilityIdentifier("editor.addAdjustment")
        }
    }

    private func adjustmentRow(_ adjustment: ReceiptAdjustment, index: Int) -> some View {
        let isSelected = model.selection.selectedRowID == adjustment.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Fee or discount", text: Binding(
                    get: { model.adjustmentLabelInput[adjustment.id] ?? "" },
                    set: { model.setAdjustmentLabel(adjustment.id, $0) }))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("editor.adjustment.\(index).label")
                    .focused($focusedField, equals: "adjustment:\(index):label")
                    .onSubmit { focusedField = nil }
                if isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("editor.adjustment.\(index).selected")
                }
                Button(isSelected ? "Deselect" : "Select") {
                    model.selectRow(isSelected ? nil : adjustment.id)
                }
                .accessibilityIdentifier("editor.adjustment.\(index).select")
                Button { rowToRemove = (adjustment.id, true, adjustment.label) } label: {
                    Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Remove \(adjustment.label)")
                    .accessibilityIdentifier("editor.adjustment.\(index).remove")
            }
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
            if model.draft.receiptSplit == nil { allocationEditor(rowID: adjustment.id, isAdjustment: true, index: index,
                             allocation: model.draft.adjustmentAllocations[adjustment.id] ?? RowAllocation(shares: [])) }
        }
        .accessibilityElement(children: .contain)
    }

    private func allocationEditor(rowID: UUID, isAdjustment: Bool, index: Int, allocation: RowAllocation) -> some View {
        let prefix = isAdjustment ? "adjustment" : "line"
        return VStack(alignment: .leading, spacing: 6) {
            if allocation.isEmpty {
                Label("Who’s sharing this? Choose people below.", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("editor.\(prefix).\(index).unresolved")
            }
            ForEach(model.draft.participants, id: \.id) { participant in
                let included = allocation.shares.first(where: { $0.participantID == participant.id })
                HStack(spacing: 16) {
                    Text(participant.displayName).frame(maxWidth: .infinity, alignment: .leading)
                    TextField("Weight", text: Binding(
                        get: { included.map { String($0.weight) } ?? "" },
                        set: { model.setWeight(participantID: participant.id, onRow: rowID, isAdjustment: isAdjustment, raw: $0) }))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 56, height: 44)
                        .background(SlipStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .opacity(included == nil ? 0 : 1)
                        .disabled(included == nil)
                        .accessibilityHidden(included == nil)
                        .accessibilityLabel("Share weight for \(participant.displayName)")
                        .accessibilityIdentifier("editor.\(prefix).\(index).weight.\(participant.displayName)")
                        .focused($focusedField, equals: "weight:\(prefix):\(index):\(participant.displayName)")
                        .onSubmit { focusedField = nil }
                    Toggle(participant.displayName, isOn: Binding(
                        get: { included != nil },
                        set: { _ in model.toggleParticipant(participant.id, onRow: rowID, isAdjustment: isAdjustment) }))
                        .labelsHidden().fixedSize()
                        .accessibilityIdentifier("editor.\(prefix).\(index).person.\(participant.displayName)")
                }
                .padding(.vertical, 10)

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

/// Reference-image viewport. Zoom/pan state is read from and written to
/// `model.selection` — never view-local — so the exact viewport returns
/// after tab switches, relaunch and rotation. Explicit buttons are the
/// primary control (VoiceOver + no-gesture flows); the magnify/drag
/// gestures are optional supplements.
private struct ReferenceViewportView: View {
    let imageURL: URL
    @Bindable var model: ReceiptWorkspaceModel
    @State private var image: UIImage?

    private static let panStep: Double = 40
    private static let zoomStep: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    // The zoom/pan transforms render beyond the visible
                    // viewport, and an accessibilityElement() leaf attached
                    // to the transformed view reports the SCALED visual
                    // bounds — its AX frame then overlaps the button rows
                    // below and XCUITest reports those buttons found-but-
                    // never-hittable (run 35844245213; allowsHitTesting
                    // cannot help because the block is at the AX-tree level,
                    // and 35803374058 showed contentShape can't either).
                    // Nest the transforms inside a fixed-size container and
                    // leaf the CONTAINER: its bounds are the visible 180pt
                    // viewport, so controls below stay hittable.
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(model.selection.referenceZoom)
                            .offset(x: model.selection.referenceOffsetX,
                                    y: model.selection.referenceOffsetY)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
                    // Decorative photo. It must NOT be an AX element: an
                    // accessibilityElement() leaf on (or wrapping) scaled/
                    // offset content reports a frame that overflows the
                    // clipped 180pt viewport and covers the control rows
                    // below — XCUITest then reports those buttons found-but-
                    // never-hittable no matter the shape/ hit-testing
                    // modifiers (proven across runs 35796551900, 35802428979,
                    // 35803374058, 35844245213, 35851183961: leaf on image,
                    // contentShape, leaf-on-container, allowsHitTesting all
                    // fail identically; the single-snapshot AX dump in
                    // 35857097157 shows the leaf + buttons virtualized while
                    // sibling rows persist). VoiceOver operates the photo
                    // through the labeled zoom/pan/reset buttons, whose
                    // labels carry the full state; the viewport itself is
                    // proven present via editor.reference.zoomLabel.
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                } else {
                    // Corrupt/unreadable owned file: visible state, not a blank.
                    Label("The stored reference image could not be displayed. Its controls still work.",
                          systemImage: "photo.badge.exclamationmark")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityIdentifier("editor.reference.unreadable")
                }
            }
            HStack {
                Button {
                    zoom(by: Self.zoomStep)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .accessibilityLabel("Zoom in on reference photo")
                .accessibilityIdentifier("editor.reference.zoomIn")

                Text(zoomLabel)
                    .monospacedDigit()
                    .accessibilityIdentifier("editor.reference.zoomLabel")

                Button {
                    zoom(by: -Self.zoomStep)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .accessibilityLabel("Zoom out on reference photo")
                .accessibilityIdentifier("editor.reference.zoomOut")

                Button("Reset view") {
                    model.updateSelection {
                        $0.referenceZoom = WorkspaceSelection.minimumZoom
                        $0.referenceOffsetX = 0
                        $0.referenceOffsetY = 0
                    }
                }
                .accessibilityIdentifier("editor.reference.reset")
            }
            .buttonBorderShape(.roundedRectangle)
            .frame(minHeight: 44)

            HStack {
                panButton(system: "arrow.left", label: "Pan reference left", dx: -Self.panStep, dy: 0)
                panButton(system: "arrow.right", label: "Pan reference right", dx: Self.panStep, dy: 0)
                panButton(system: "arrow.up", label: "Pan reference up", dx: 0, dy: -Self.panStep)
                panButton(system: "arrow.down", label: "Pan reference down", dx: 0, dy: Self.panStep)
            }
            .buttonBorderShape(.roundedRectangle)
            .frame(minHeight: 44)
        }
        .task {
            image = UIImage(contentsOfFile: imageURL.path)
        }
    }

    private var zoomLabel: String {
        String(format: "%.1f×", model.selection.referenceZoom)
    }

    private func zoom(by delta: Double) {
        model.updateSelection {
            $0.referenceZoom = min(max($0.referenceZoom + delta,
                                       WorkspaceSelection.minimumZoom),
                                   WorkspaceSelection.maximumZoom)
        }
    }

    private func pan(dx: Double, dy: Double) {
        model.updateSelection {
            $0.referenceOffsetX += dx
            $0.referenceOffsetY += dy
        }
    }

    private func panButton(system: String, label: String, dx: Double, dy: Double) -> some View {
        Button {
            pan(dx: dx, dy: dy)
        } label: {
            Image(systemName: system)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier("editor.reference.pan.\(system)")
    }
}
