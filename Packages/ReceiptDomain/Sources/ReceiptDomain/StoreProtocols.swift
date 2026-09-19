import Foundation

/// Explicit failure vocabulary for the persistence layer so callers can react
/// transactionally: a failed save must leave the previous stored state intact.
public enum StoreFailure: Error, Hashable, Sendable {
    case encodingFailed(String)
    case decodingFailed(String)
    case versionMismatch(AlgorithmVersion)
    case writeFailed(String)
    case missingDraft(UUID)
    case missingSnapshot(UUID)
    case duplicateIdentity(String)
}

/// Where drafts live. Every method is all-or-nothing at the store's
/// transaction boundary; implementations must never leave a half-written row.
public protocol DraftStore: Sendable {
    func saveDraft(_ draft: ReceiptDraft) throws
    func loadDraft(id: UUID) throws -> ReceiptDraft
    func loadAllDrafts() throws -> [ReceiptDraft]
    func deleteDraft(id: UUID) throws
}

/// Where immutable finalized snapshots live. Snapshots are never updated in
/// place — a correction forks a new draft (`FinalizedReceiptSnapshot.correctionDraft`).
public protocol SnapshotStore: Sendable {
    func storeSnapshot(_ snapshot: FinalizedReceiptSnapshot) throws
    func loadSnapshot(id: UUID) throws -> FinalizedReceiptSnapshot
    func loadAllSnapshots() throws -> [FinalizedReceiptSnapshot]
}

public extension AlgorithmVersion {
    /// Guard used by stores before decoding any payload: unknown versions are
    /// refused rather than partially interpreted (restore-validation hook for #5).
    static func enforceRestorable(_ version: AlgorithmVersion) throws {
        try validateRestorable(version)
    }
}
