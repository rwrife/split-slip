import Foundation
import ReceiptDomain

#if canImport(SwiftData)
import SwiftData

// MARK: - Persistent models

/// One draft row. The complete validated `ReceiptDraft` is stored as a JSON
/// blob under its schema version — the domain codable conformance is the
/// single source of truth, so the store cannot drift half the struct fields.
@Model
public final class DraftRecord {
    @Attribute(.unique) public var draftID: UUID
    public var schemaVersion: Int
    public var allocationRuleVersion: Int
    public var updatedAt: Date
    public var payload: Data

    public init(draftID: UUID, schemaVersion: Int, allocationRuleVersion: Int, updatedAt: Date, payload: Data) {
        self.draftID = draftID
        self.schemaVersion = schemaVersion
        self.allocationRuleVersion = allocationRuleVersion
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

@Model
public final class SnapshotRecord {
    @Attribute(.unique) public var snapshotID: UUID
    public var sourceDraftID: UUID
    public var finalizedAt: Date
    public var schemaVersion: Int
    public var allocationRuleVersion: Int
    public var payload: Data

    public init(snapshotID: UUID, sourceDraftID: UUID, finalizedAt: Date, schemaVersion: Int, allocationRuleVersion: Int, payload: Data) {
        self.snapshotID = snapshotID
        self.sourceDraftID = sourceDraftID
        self.finalizedAt = finalizedAt
        self.schemaVersion = schemaVersion
        self.allocationRuleVersion = allocationRuleVersion
        self.payload = payload
    }
}

// MARK: - SwiftData adapter

/// Transactional SwiftData adapter. Drafts are upserted and saved atomically;
/// snapshots are append-only (a second store of the same id is rejected).
/// Unknown algorithm versions fail closed on read. Failed writes surface as
/// `StoreFailure.writeFailed` after rollback, so previously stored bytes survive.
@available(iOS 17.0, macOS 14.0, *)
public final class SwiftDataReceiptStore: DraftStore, SnapshotStore, @unchecked Sendable {
    public let container: ModelContainer

    /// - Parameter url: local store URL, or nil for an in-memory store (tests).
    public init(url: URL? = nil) throws {
        let schema = Schema([DraftRecord.self, SnapshotRecord.self])
        let config: ModelConfiguration
        if let url {
            config = ModelConfiguration(schema: schema, url: url)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            throw StoreFailure.writeFailed("container: \(error)")
        }
    }

    private var encoder: PropertyListEncoder { PropertyListEncoder() }
    private var decoder: PropertyListDecoder { PropertyListDecoder() }

    // MARK: DraftStore

    public func saveDraft(_ draft: ReceiptDraft) throws {
        let data: Data
        do {
            data = try encoder.encode(draft)
        } catch {
            throw StoreFailure.encodingFailed("draft: \(error)")
        }
        let context = ModelContext(container)
        let id = draft.id
        let descriptor = FetchDescriptor<DraftRecord>(predicate: #Predicate { $0.draftID == id })
        if let existing = try? context.fetch(descriptor).first {
            existing.schemaVersion = AlgorithmVersion.current.schema
            existing.allocationRuleVersion = AlgorithmVersion.current.allocationRule
            existing.updatedAt = Date()
            existing.payload = data
        } else {
            context.insert(DraftRecord(
                draftID: id,
                schemaVersion: AlgorithmVersion.current.schema,
                allocationRuleVersion: AlgorithmVersion.current.allocationRule,
                updatedAt: Date(),
                payload: data))
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw StoreFailure.writeFailed("saveDraft: \(error)")
        }
    }

    public func loadDraft(id: UUID) throws -> ReceiptDraft {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DraftRecord>(predicate: #Predicate { $0.draftID == id })
        guard let record = try? context.fetch(descriptor).first else {
            throw StoreFailure.missingDraft(id)
        }
        return try decodeDraft(record)
    }

    public func loadAllDrafts() throws -> [ReceiptDraft] {
        let context = ModelContext(container)
        let records = (try? context.fetch(FetchDescriptor<DraftRecord>())) ?? []
        return try records.map(decodeDraft)
    }

    private func decodeDraft(_ record: DraftRecord) throws -> ReceiptDraft {
        try AlgorithmVersion.enforceRestorable(
            AlgorithmVersion(schema: record.schemaVersion, allocationRule: record.allocationRuleVersion))
        do {
            return try decoder.decode(ReceiptDraft.self, from: record.payload)
        } catch {
            throw StoreFailure.decodingFailed("draft \(record.draftID): \(error)")
        }
    }

    public func deleteDraft(id: UUID) throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DraftRecord>(predicate: #Predicate { $0.draftID == id })
        guard let record = try? context.fetch(descriptor).first else {
            throw StoreFailure.missingDraft(id)
        }
        context.delete(record)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw StoreFailure.writeFailed("deleteDraft: \(error)")
        }
    }

    // MARK: SnapshotStore

    public func storeSnapshot(_ snapshot: FinalizedReceiptSnapshot) throws {
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw StoreFailure.encodingFailed("snapshot: \(error)")
        }
        let context = ModelContext(container)
        let id = snapshot.id
        let descriptor = FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.snapshotID == id })
        guard (try? context.fetch(descriptor).first) == nil else {
            // Snapshots are immutable: never overwrite an existing record.
            throw StoreFailure.duplicateIdentity("snapshot \(id) already stored")
        }
        context.insert(SnapshotRecord(
            snapshotID: id,
            sourceDraftID: snapshot.sourceDraftID,
            finalizedAt: snapshot.finalizedAt,
            schemaVersion: snapshot.algorithmVersion.schema,
            allocationRuleVersion: snapshot.algorithmVersion.allocationRule,
            payload: data))
        do {
            try context.save()
        } catch {
            context.rollback()
            throw StoreFailure.writeFailed("storeSnapshot: \(error)")
        }
    }

    public func loadSnapshot(id: UUID) throws -> FinalizedReceiptSnapshot {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.snapshotID == id })
        guard let record = try? context.fetch(descriptor).first else {
            throw StoreFailure.missingSnapshot(id)
        }
        try AlgorithmVersion.enforceRestorable(
            AlgorithmVersion(schema: record.schemaVersion, allocationRule: record.allocationRuleVersion))
        do {
            return try decoder.decode(FinalizedReceiptSnapshot.self, from: record.payload)
        } catch {
            throw StoreFailure.decodingFailed("snapshot \(id): \(error)")
        }
    }

    public func loadAllSnapshots() throws -> [FinalizedReceiptSnapshot] {
        let context = ModelContext(container)
        let records = (try? context.fetch(FetchDescriptor<SnapshotRecord>())) ?? []
        return try records.map { record in
            try AlgorithmVersion.enforceRestorable(
                AlgorithmVersion(schema: record.schemaVersion, allocationRule: record.allocationRuleVersion))
            do {
                return try decoder.decode(FinalizedReceiptSnapshot.self, from: record.payload)
            } catch {
                throw StoreFailure.decodingFailed("snapshot \(record.snapshotID): \(error)")
            }
        }
    }
}
#endif
