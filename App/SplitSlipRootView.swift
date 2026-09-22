import Foundation
import ReceiptDomain
import ReceiptStore
import SplitSlipCore
import SwiftUI
import UIKit

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
    let images: (any ReferenceImageStore)?
    let continuity: (any ContinuityStore)?
    @State private var path: [WorkspaceRoute] = []
    @State private var drafts: [ReceiptDraft] = []
    @State private var snapshots: [FinalizedReceiptSnapshot] = []
    @State private var reloadMessage: String?

    init(store: AnyReceiptStore,
         images: (any ReferenceImageStore)? = nil,
         continuity: (any ContinuityStore)? = nil) {
        self.store = store
        self.images = images
        self.continuity = continuity
    }

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
                ReceiptEditorView(draft: draft, store: store, images: images, continuity: continuity, onClose: {
                    // A correction fork unwinds all the way to home; a plain
                    // draft returns to wherever it was opened from.
                    if draft.correctionOfSnapshotID != nil { popAll() } else { popOne() }
                })
            } else {
                ContentUnavailableView("Draft no longer exists", systemImage: "questionmark.circle")
            }
        case let .snapshot(id):
            if let snapshot = (try? store.loadSnapshot(id: id)) {
                SnapshotDetailView(snapshot: snapshot, store: store, images: images, continuity: continuity, onDuplicate: { forkID in
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
    let images: (any ReferenceImageStore)?
    let continuity: (any ContinuityStore)?
    /// Called with the id of a freshly forked correction draft so the
    /// owning navigation stack can push its editor.
    let onDuplicate: (UUID) -> Void

    /// `referenceImageURL` is `throws` and the store is optional, so flatten
    /// both layers here; a failing store just means "no reference to show".
    private var storedReferenceURL: URL? {
        guard let images else { return nil }
        return try? images.referenceImageURL(receiptID: snapshot.id)
    }

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
            if let imageURL = storedReferenceURL {
                // Read-only reference carried with the snapshot (issue #4).
                SnapshotReferenceView(imageURL: imageURL)
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
            // The fork inherits the snapshot's reference image and workspace
            // selection as copies; the snapshot keeps its own (issue #4).
            try? images?.copyReference(from: snapshot.id, to: fork.id)
            continuity?.copySelection(from: snapshot.id, to: fork.id)
            onDuplicate(fork.id)
        } catch {}
    }
}

/// Read-only reference photo inside a finalized snapshot review.
private struct SnapshotReferenceView: View {
    let imageURL: URL
    @State private var image: UIImage?

    var body: some View {
        Section("Reference photo") {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 220)
                    .clipped()
                    .accessibilityLabel("Receipt reference photo")
                    .accessibilityIdentifier("snapshot.reference")
            } else {
                Label("The stored reference image could not be displayed.",
                      systemImage: "photo.badge.exclamationmark")
                    .accessibilityIdentifier("snapshot.reference.unreadable")
            }
        }
        .task { image = UIImage(contentsOfFile: imageURL.path) }
    }
}
