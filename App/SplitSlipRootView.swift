import Foundation
import ReceiptDomain
import ReceiptStore
import SplitSlipCore
import SwiftUI

/// Store erasure used across the app so views don't pin the SwiftData type.
typealias AnyReceiptStore = any DraftStore & SnapshotStore

struct StoreUnavailableView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("Receipts unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Split Slip could not open its local store. Existing data has not been modified.")
            Text(String(describing: error))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("home.storeError")
    }
}

enum WorkspaceRoute: Hashable {
    case draft(UUID)
    case snapshot(UUID)
}

struct SplitSlipRootView: View {
    let store: AnyReceiptStore
    @State private var path: [WorkspaceRoute] = []
    @State private var drafts: [ReceiptDraft] = []
    @State private var snapshots: [FinalizedReceiptSnapshot] = []
    @State private var reloadMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if drafts.isEmpty && snapshots.isEmpty {
                    Text("No receipts yet. Create one to get started.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.empty")
                }
                Section("Drafts") {
                    ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                        Button {
                            path.append(.draft(draft.id))
                        } label: {
                            Label("Draft — \(draft.participants.count) people", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("home.draft.\(index)")
                    }
                }
                Section("Finalized") {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        Button {
                            path.append(.snapshot(snapshot.id))
                        } label: {
                            Label("Finalized — \(snapshot.participants.count) people", systemImage: "checkmark.seal")
                        }
                        .accessibilityIdentifier("home.snapshot.\(index)")
                    }
                }
            }
            .navigationTitle("Split Slip")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.root")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New receipt") { createDraft() }
                        .accessibilityIdentifier("home.newReceipt")
                }
            }
            .navigationDestination(for: WorkspaceRoute.self) { route in
                destination(for: route)
            }
            .overlay {
                if let reloadMessage {
                    ContentUnavailableView(reloadMessage, systemImage: "exclamationmark.triangle")
                }
            }
            .onAppear(perform: reload)
        }
    }

    @ViewBuilder
    private func destination(for route: WorkspaceRoute) -> some View {
        switch route {
        case let .draft(id):
            if let draft = (try? store.loadDraft(id: id)) {
                ReceiptEditorView(draft: draft, store: store, onClose: {
                    // A correction fork unwinds all the way to home; a plain
                    // draft returns to wherever it was opened from.
                    if draft.correctionOfSnapshotID != nil { popAll() } else { popOne() }
                })
            } else {
                ContentUnavailableView("Draft no longer exists", systemImage: "questionmark.circle")
            }
        case let .snapshot(id):
            if let snapshot = (try? store.loadSnapshot(id: id)) {
                SnapshotDetailView(snapshot: snapshot, store: store, onDuplicate: { forkID in
                    path.append(.draft(forkID))
                })
            } else {
                ContentUnavailableView("Finalized receipt no longer exists", systemImage: "questionmark.circle")
            }
        }
    }

    private func popOne() {
        if !path.isEmpty { path.removeLast() }
        reload()
    }

    /// Pops every pushed destination, landing back on home.
    private func popAll() {
        while !path.isEmpty { path.removeLast() }
        reload()
    }

    private func reload() {
        reloadMessage = nil
        do {
            drafts = try store.loadAllDrafts()
            snapshots = try store.loadAllSnapshots()
        } catch let error as StoreFailure {
            reloadMessage = DomainMessages.store(error)
        } catch {
            reloadMessage = "Could not read stored receipts: \(error)"
        }
    }

    private func createDraft() {
        let draft = ReceiptDraft()
        do {
            try store.saveDraft(draft)
            path.append(.draft(draft.id))
            reload()
        } catch let error as StoreFailure {
            reloadMessage = DomainMessages.store(error)
        } catch {
            reloadMessage = "Could not create the draft: \(error)"
        }
    }
}

/// Read-only review of a finalized snapshot plus duplicate-to-correct entry.
struct SnapshotDetailView: View {
    let snapshot: FinalizedReceiptSnapshot
    let store: AnyReceiptStore
    /// Called with the id of a freshly forked correction draft so the
    /// owning navigation stack can push its editor.
    let onDuplicate: (UUID) -> Void

    var body: some View {
        List {
            Section {
                ForEach(Array(snapshot.personShares.enumerated()), id: \.element.participant.id) { index, share in
                    LabeledContent(share.participant.displayName, value: MinorAmount(minorUnits: share.totalMinorUnits).description)
                        .accessibilityIdentifier("snapshot.total.\(index)")
                }
                LabeledContent("Receipt total", value: snapshot.expectedTotal.description)
                    .accessibilityIdentifier("snapshot.grandTotal")
                if snapshot.correctsSnapshotID != nil {
                    Text("Corrects an earlier finalized receipt.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Finalized — read-only")
            } footer: {
                Text("Snapshots never change. Duplicating to correct starts a new linked draft; the original stays as it is.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snapshot.readonly")
        .navigationTitle("Finalized receipt")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Duplicate to correct") { duplicate() }
                    .accessibilityIdentifier("snapshot.duplicate")
            }
        }
    }

    private func duplicate() {
        // The snapshot itself is never reopened; the fork is a brand-new draft.
        let fork = ReceiptWorkspaceModel.correctionDraft(from: snapshot)
        do {
            try store.saveDraft(fork)
            onDuplicate(fork.id)
        } catch {}
    }
}
