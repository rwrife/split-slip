import Foundation
import CoreTransferable
import ReceiptDomain
import ReceiptStore
import SplitSlipCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Store erasure used across the app so views don't pin the SwiftData type.
typealias AnyReceiptStore = any ReceiptLibraryStore

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
    @State private var searchText = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transfer: LibraryTransfer?
    @State private var showData = false
    @State private var deleteID: UUID?

    init(store: AnyReceiptStore,
         images: (any ReferenceImageStore)? = nil,
         continuity: (any ContinuityStore)? = nil,
         transfer: LibraryTransfer? = nil) {
        self.store = store
        self.images = images
        self.continuity = continuity
        self.transfer = transfer
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        if dynamicTypeSize.isAccessibilitySize {
                            Text("Good times. Fair shares.")
                                .font(.system(.headline, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                        Label("GOOD TIMES. FAIR SHARES.", systemImage: "sparkles")
                            .font(.caption.weight(.bold)).tracking(1.5)
                        Text("Together is better.\nSplitting is easy.")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("From one more appetizer to the weekly groceries. Give every cent a place.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button(action: createDraft) {
                            Label("Split a receipt", systemImage: "plus.circle.fill")
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .accessibilityIdentifier("home.newReceipt")
                    }
                    .padding(8)
                }
                .listRowBackground(SlipStyle.accent.opacity(0.09))
                if drafts.isEmpty && snapshots.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "receipt").font(.system(size: 42)).foregroundStyle(SlipStyle.accent)
                            Text("Your next shared moment starts here")
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                            Text("Add the receipt. Pick your people.\nWe’ll take care of the cents.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                        .accessibilityIdentifier("home.empty")
                    }
                }
                if !drafts.isEmpty {
                    Section("In the works · \(drafts.count)") {
                        ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                            if matchesSearch(draft.lines.map(\.label), people: draft.participants) {
                                Button { path.append(.draft(draft.id)) } label: {
                                    ReceiptCard(title: receiptTitle(draft.lines),
                                                names: draft.participants.map(\.displayName),
                                                amount: draft.expectedTotal, currency: draft.currency,
                                                status: draft.unassignedRowIDs().isEmpty ? "Continue editing" : "\(draft.unassignedRowIDs().count) items to assign",
                                                complete: false)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.draft.\(index)")
                                .contextMenu { if transfer != nil { Button("Delete receipt", role: .destructive) { deleteID = draft.id } } }
                                .swipeActions { if transfer != nil { Button("Delete", role: .destructive) { deleteID = draft.id } } }
                                if transfer != nil {
                                    Button("Delete receipt", role: .destructive) { deleteID = draft.id }
                                        .accessibilityIdentifier("home.draft.\(index).delete")
                                }
                            }
                        }
                    }
                }
                if !snapshots.isEmpty {
                    Section("Finished splits · \(snapshots.count)") {
                        ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                            if matchesSearch(snapshot.lines.map(\.label), people: snapshot.participants) {
                                Button { path.append(.snapshot(snapshot.id)) } label: {
                                    ReceiptCard(title: receiptTitle(snapshot.lines),
                                                names: snapshot.participants.map(\.displayName),
                                                amount: snapshot.expectedTotal, currency: snapshot.currency,
                                                status: "Ready to share", complete: true)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.snapshot.\(index)")
                                .contextMenu { if transfer != nil { Button("Delete receipt", role: .destructive) { deleteID = snapshot.id } } }
                                .swipeActions { if transfer != nil { Button("Delete", role: .destructive) { deleteID = snapshot.id } } }
                                if transfer != nil {
                                    Button("Delete receipt", role: .destructive) { deleteID = snapshot.id }
                                        .accessibilityIdentifier("home.snapshot.\(index).delete")
                                }
                            }
                        }
                    }
                }
                Section {
                    Label("Just on your phone. Just your business.", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }.listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SlipStyle.canvas)
            .searchable(text: $searchText, prompt: "Find a person or item")
            .navigationTitle("Split Slip")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.root")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showData = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Your data and backups").accessibilityIdentifier("home.data")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: createDraft) { Image(systemName: "plus") }
                        .accessibilityLabel("New receipt")
                        .accessibilityIdentifier("home.newReceiptToolbar")
                        .disabled(reloadMessage != nil)
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
            .sheet(isPresented: $showData, onDismiss: reload) {
                if let transfer { LibraryDataView(transfer: transfer) }
            }
            .alert("Delete this receipt?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
                Button("Delete receipt", role: .destructive) {
                    guard let id = deleteID else { return }
                    do { try transfer?.delete(receiptID: id); reload() }
                    catch { reloadMessage = error.localizedDescription }
                    deleteID = nil
                }
                Button("Keep receipt", role: .cancel) { deleteID = nil }
            } message: {
                Text("This removes the receipt, its private photo, and local recovery backups. Copies you already exported and device backups are not removed.")
            }
            .onAppear(perform: reload)
        }
        .tint(SlipStyle.accent)
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

    private func receiptTitle(_ lines: [ReceiptLine]) -> String {
        let first = lines.first?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? "A fresh split" : first + (lines.count > 1 ? " & more" : "")
    }

    private func matchesSearch(_ labels: [String], people: [ParticipantIdentity]) -> Bool {
        searchText.isEmpty || (labels + people.map(\.displayName)).contains { $0.localizedCaseInsensitiveContains(searchText) }
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
            try transfer?.recoverIfNeeded()
            drafts = try store.loadAllDrafts().sorted { $0.id.uuidString < $1.id.uuidString }
            snapshots = try store.loadAllSnapshots().sorted { $0.finalizedAt > $1.finalizedAt }
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
    @State private var showShare = false
    @State private var duplicateError: String?
    @State private var expandedPeople: Set<UUID> = []

    /// `referenceImageURL` is `throws` and the store is optional, so flatten
    /// both layers here; a failing store just means "no reference to show".
    private var storedReferenceURL: URL? {
        guard let images else { return nil }
        return try? images.referenceImageURL(receiptID: snapshot.id)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("EVERY CENT, ACCOUNTED FOR", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(SlipStyle.accent)
                    Text("Nicely split.").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("\(snapshot.expectedTotal) \(snapshot.currency.rawValue)")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                    Text("\(snapshot.participants.count) people · \(snapshot.lines.count) items · All reviewed")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button { showShare = true } label: {
                        Label("Preview & share", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .accessibilityIdentifier("snapshot.share")
                }.padding(.vertical, 8)
            }.listRowBackground(SlipStyle.accent.opacity(0.09))
            Section {
                ForEach(Array(snapshot.personShares.enumerated()), id: \.element.participant.id) { index, share in
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            if expandedPeople.contains(share.participant.id) { expandedPeople.remove(share.participant.id) }
                            else { expandedPeople.insert(share.participant.id) }
                        } label: {
                            HStack(spacing: 12) {
                                PersonBadge(name: share.participant.displayName, index: index)
                                LabeledContent(share.participant.displayName, value: "\(MinorAmount(minorUnits: share.totalMinorUnits)) \(snapshot.currency.rawValue)")
                                    .font(.headline).monospacedDigit()
                                Image(systemName: expandedPeople.contains(share.participant.id) ? "chevron.up" : "chevron.down")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(expandedPeople.contains(share.participant.id) ? "Expanded" : "Collapsed")
                        .accessibilityHint("Show or hide the items for this person")
                        .accessibilityIdentifier("snapshot.person.\(index).expand")
                        if expandedPeople.contains(share.participant.id) {
                            Divider()
                            personItems(share, index: index)
                        }
                    }
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
        .scrollContentBackground(.hidden)
        .background(SlipStyle.canvas)
        .navigationTitle("The split")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) { SummaryPreviewView(snapshot: snapshot) }
        .alert("Couldn’t duplicate receipt", isPresented: Binding(get: { duplicateError != nil }, set: { if !$0 { duplicateError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(duplicateError ?? "Please try again.") }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Duplicate to correct") { duplicate() }
                    .accessibilityIdentifier("snapshot.duplicate")
            }
        }
    }

    @ViewBuilder
    private func personItems(_ share: FinalizedPersonShare, index: Int) -> some View {
        if let split = snapshot.receiptSplit {
            Text(split[share.participant.id] == nil
                 ? "Equal share of the remainder after fixed amounts."
                 : "Fixed share of the whole receipt.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Shared receipt items · amounts below are the full item prices")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(snapshot.lines) { line in
                LabeledContent(line.label, value: line.amount.description)
            }
            ForEach(snapshot.adjustments) { adjustment in
                LabeledContent(adjustment.label, value: adjustment.amount.description)
            }
        } else {
            ForEach(snapshot.lines) { line in
                if let amount = share.rowShares[line.id] {
                    LabeledContent(line.label, value: MinorAmount(minorUnits: amount).description)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("snapshot.person.\(index).item.\(line.id)")
                }
            }
            ForEach(snapshot.adjustments) { adjustment in
                if let amount = share.rowShares[adjustment.id] {
                    LabeledContent(adjustment.label, value: MinorAmount(minorUnits: amount).description)
                }
            }
            if share.rowShares.isEmpty { Text("No items assigned to this person.").foregroundStyle(.secondary) }
        }
    }

    private func duplicate() {
        // The snapshot itself is never reopened; the fork is a brand-new draft.
        let fork = ReceiptWorkspaceModel.correctionDraft(from: snapshot)
        do {
            try images?.copyReference(from: snapshot.id, to: fork.id)
            do { try store.saveDraft(fork) }
            catch { try? images?.clearReferenceImage(receiptID: fork.id); throw error }
            continuity?.copySelection(from: snapshot.id, to: fork.id)
            onDuplicate(fork.id)
        } catch { duplicateError = "Your original is safe. \(error.localizedDescription)" }
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

// Shared visual language: native surfaces, rounded type, and a warm coral accent.
enum SlipStyle {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.48, blue: 0.37, alpha: 1)
            : UIColor(red: 0.72, green: 0.20, blue: 0.13, alpha: 1)
    })
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemGroupedBackground
            : UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
    })
}

struct PersonBadge: View {
    let name: String
    let index: Int
    private var color: Color { [SlipStyle.accent, .teal, .indigo, .purple][index % 4] }
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(color.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct ReceiptCard: View {
    let title: String
    let names: [String]
    let amount: MinorAmount
    let currency: SupportedCurrency
    let status: String
    let complete: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: complete ? "checkmark.seal" : "receipt")
                    .font(.title2).foregroundStyle(SlipStyle.accent)
                    .frame(width: 48, height: 48)
                    .background(SlipStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(.headline, design: .rounded)).foregroundStyle(.primary)
                    Text(names.isEmpty ? "Add your people" : names.joined(separator: ", "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(status).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(amount) \(currency.rawValue)").font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(amount) \(currency.rawValue)").font(.headline).monospacedDigit()
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SummaryPreviewView: View {
    let snapshot: FinalizedReceiptSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var personID: UUID?
    @State private var format: ReceiptSummary.Format = .text
    @State private var exporting = false
    @State private var exportError: String?

    private var summary: String { ReceiptSummary.render(snapshot, personID: personID, format: format) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Include", selection: $personID) {
                        Text("Everyone").tag(nil as UUID?)
                        ForEach(snapshot.participants, id: \.id) { person in
                            Text(person.displayName).tag(Optional(person.id))
                        }
                    }.accessibilityIdentifier("share.people")
                    Picker("Format", selection: $format) {
                        ForEach(ReceiptSummary.Format.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }.pickerStyle(.segmented).accessibilityIdentifier("share.format")
                } footer: {
                    Text("Includes names, items, and amounts. Receipt photos and internal IDs stay private. Choose who receives this in the share sheet.")
                }
                Section("What you’ll share") {
                    Text(summary).font(format == .csv ? .system(.footnote, design: .monospaced) : .body)
                        .textSelection(.enabled).accessibilityIdentifier("share.preview")
                }
                Section {
                    if format == .text {
                        ShareLink(item: summary) {
                            Label("Share this split", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.accessibilityIdentifier("share.send")
                    } else {
                        ShareLink(item: CSVShare(text: summary), preview: SharePreview("Split Slip CSV")) {
                            Label("Share CSV", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.accessibilityIdentifier("share.sendCSV")
                        Button { exporting = true } label: {
                            Label("Save CSV", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.accessibilityIdentifier("share.saveCSV")
                    }
                }
            }
            .scrollContentBackground(.hidden).background(SlipStyle.canvas)
            .navigationTitle("Ready to share?").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: SummaryDocument(text: summary), contentType: .commaSeparatedText, defaultFilename: "Split Slip") { result in
                if case let .failure(error) = result { exportError = error.localizedDescription }
            }
            .alert("Couldn’t export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportError ?? "Try again.") }
        }.tint(SlipStyle.accent)
    }
}

private struct SummaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Each native folder export gets a unique temporary name. Completion,
/// cancellation, and the next launch clean up the app-owned staging directory.
struct BackupExport: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    private static let prefix = "SplitSlipExport-"
    let filename: String
    let files: [String: Data]
    init(backup: LibraryBackup) throws {
        filename = Self.prefix + UUID().uuidString
        files = try backup.files()
    }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(directoryWithFileWrappers: files.mapValues { FileWrapper(regularFileWithContents: $0) })
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(filename))
    }
    static func cleanupAbandoned() throws {
        for folder in try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            let name = folder.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            try FileManager.default.removeItem(at: folder)
        }
    }
}

private struct LibraryDataView: View {
    let transfer: LibraryTransfer
    @Environment(\.dismiss) private var dismiss
    @State private var document: BackupExport?
    @State private var exporting = false
    @State private var importing = false
    @State private var staged: LibraryBackup?
    @State private var confirmingRestore = false
    @State private var confirmingDelete = false
    @State private var message: String?
    @State private var previous: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Your receipts. Your control.", systemImage: "lock.shield.fill")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("Everything stays on this device unless you choose to export it.")
                        .foregroundStyle(.secondary)
                }.listRowBackground(SlipStyle.accent.opacity(0.09))
                Section {
                    Button { perform { document = try BackupExport(backup: transfer.backup()); exporting = true } } label: {
                        Label("Save a private backup", systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("data.backup")
                    Button { importing = true } label: {
                        Label("Restore from a backup", systemImage: "arrow.counterclockwise")
                    }.accessibilityIdentifier("data.restore")
                } header: { Text("Take it with you") } footer: {
                    Text("Backups include names, amounts, and receipt photos. Save them somewhere private. Files providers may upload to cloud storage. Your device’s backup settings may also include this app’s local data; it is not a separately encrypted vault.")
                }
                if !previous.isEmpty {
                    Section {
                        ForEach(previous, id: \.self) { folder in
                            Button("Save recovery backup \(previous.firstIndex(of: folder)! + 1)") {
                                perform { document = try BackupExport(backup: LibraryBackup.read(from: folder)); exporting = true }
                            }
                        }
                    } header: { Text("Before your last restores") } footer: {
                        Text("Your previous library was saved here before replacement. Export it to restore it later. Deleting receipts clears these local recovery copies too.")
                    }
                }
                Section {
                    Button("Delete all local data", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("data.deleteAll")
                } footer: {
                    Text("Removes all receipts, their photos, and local recovery copies. Exported copies and OS backups remain under your control.")
                }

            }
            .scrollContentBackground(.hidden).background(SlipStyle.canvas)
            .safeAreaInset(edge: .bottom) {
                if let message {
                    Text(message).font(.footnote).padding()
                        .frame(maxWidth: .infinity).background(.regularMaterial)
                        .accessibilityIdentifier("data.message")
                }
            }
            .navigationTitle("Your data").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { refresh() }
            .fileExporter(isPresented: $exporting, document: document, contentTypes: [.folder], defaultFilename: document?.filename, onCompletion: { result in
                defer { document?.cleanup(); document = nil }
                switch result {
                case .success: message = "Backup saved. Keep this folder and all its contents together."
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                }
            }, onCancellation: { document?.cleanup(); document = nil })
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                perform {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    staged = try LibraryBackup.read(from: url)
                    confirmingRestore = true
                }
            }
            .alert("Replace your local receipts?", isPresented: $confirmingRestore) {
                Button("Replace library", role: .destructive) {
                    guard let staged else { return }
                    perform { try transfer.restore(staged); message = "Backup restored. Your previous library is available as a recovery backup." }
                    self.staged = nil
                    refresh()
                }
                Button("Keep current receipts", role: .cancel) { staged = nil }
            } message: {
                Text("This backup contains \(staged?.library.drafts.count ?? 0) drafts, \(staged?.library.snapshots.count ?? 0) finalized splits, and \(staged?.images.count ?? 0) photos. It replaces your current library. A private recovery copy will be kept first.")
            }
            .alert("Delete everything on this device?", isPresented: $confirmingDelete) {
                Button("Delete all local data", role: .destructive) {
                    perform {
                        try transfer.deleteAll()
                        try BackupExport.cleanupAbandoned()
                        message = "Local receipts, photos, and recovery copies deleted."
                    }
                    refresh()
                }
                Button("Keep my data", role: .cancel) {}
            } message: { Text("This cannot be undone here. Exported copies and device backups are not removed.") }
        }.tint(SlipStyle.accent)
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch {
            if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
        }
    }
    private func refresh() { perform { previous = try transfer.previousBackups() } }
}

private struct CSVShare: Transferable {
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { item in Data(item.text.utf8) }
            .suggestedFileName("Split Slip.csv")
    }
}
