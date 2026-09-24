import Foundation
import ReceiptDomain

/// Actor-backed in-memory `DraftStore` + `SnapshotStore` with the same
/// transactional guarantees described by the protocols: a failed encode
/// leaves prior state intact, snapshots are append-only, and unknown
/// ids raise the named `StoreFailure` cases.
///
/// This exists so the UI layer (and UI-test launches) can run against a
/// deterministic store on any platform, while the app itself uses the
/// SwiftData-backed `SwiftDataReceiptStore` shipped in `ReceiptStore`.
public final class InMemoryReceiptStore: ReceiptLibraryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [UUID: ReceiptDraft] = [:]
    private var snapshots: [UUID: FinalizedReceiptSnapshot] = [:]

    public init() {}

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: DraftStore

    public func saveDraft(_ draft: ReceiptDraft) throws {
        try withLock {
            // Round-trip through Codable so an unsavable draft fails here
            // (all-or-nothing) exactly like the encoding step in the real store.
            let data = try JSONEncoder().encode(draft)
            let roundTripped = try JSONDecoder().decode(ReceiptDraft.self, from: data)
            drafts[draft.id] = roundTripped
        }
    }

    public func loadDraft(id: UUID) throws -> ReceiptDraft {
        try withLock {
            guard let draft = drafts[id] else { throw StoreFailure.missingDraft(id) }
            return draft
        }
    }

    public func loadAllDrafts() throws -> [ReceiptDraft] {
        try withLock { Array(drafts.values) }
    }

    public func deleteDraft(id: UUID) throws {
        try withLock {
            guard drafts.removeValue(forKey: id) != nil else { throw StoreFailure.missingDraft(id) }
        }
    }

    // MARK: SnapshotStore

    public func storeSnapshot(_ snapshot: FinalizedReceiptSnapshot) throws {
        try withLock {
            guard snapshots[snapshot.id] == nil else {
                throw StoreFailure.duplicateIdentity("snapshot \(snapshot.id) already stored")
            }
            snapshots[snapshot.id] = snapshot
        }
    }

    public func loadSnapshot(id: UUID) throws -> FinalizedReceiptSnapshot {
        try withLock {
            guard let snapshot = snapshots[id] else { throw StoreFailure.missingSnapshot(id) }
            return snapshot
        }
    }

    public func loadAllSnapshots() throws -> [FinalizedReceiptSnapshot] {
        try withLock { Array(snapshots.values) }
    }
    public func replaceLibrary(_ library: ReceiptLibrary) throws {
        try library.validate()
        try withLock {
            drafts = Dictionary(uniqueKeysWithValues: library.drafts.map { ($0.id, $0) })
            snapshots = Dictionary(uniqueKeysWithValues: library.snapshots.map { ($0.id, $0) })
        }
    }

}
