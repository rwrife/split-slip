import Foundation
import ReceiptDomain

/// Flat, bounded folder format: no archive extraction and no caller-provided paths.
public struct LibraryBackup: Sendable {
    public static let maximumBytes = 100 * 1_024 * 1_024
    public static let maximumJSONBytes = 16 * 1_024 * 1_024
    public let library: ReceiptLibrary
    public let images: [UUID: Data]

    private struct Manifest: Codable {
        let formatVersion: Int
        let algorithm: AlgorithmVersion
        let imageReceiptIDs: [UUID]
    }

    public init(library: ReceiptLibrary, images: [UUID: Data] = [:]) throws {
        try library.validate()
        guard Set(images.keys).isSubset(of: library.receiptIDs) else { throw LibraryError.invalid("An image has no receipt.") }
        guard images.values.allSatisfy({ !$0.isEmpty && $0.count <= ReferenceImageLimits.maximumEncodedBytes }) else {
            throw LibraryError.invalid("An image is empty or too large.")
        }
        guard images.values.reduce(0, { $0 + $1.count }) <= Self.maximumBytes else {
            throw LibraryError.invalid("Image data exceeds the backup size limit.")
        }
        self.library = library; self.images = images
    }

    public func files() throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let receipts = try encoder.encode(library)
        guard receipts.count <= Self.maximumJSONBytes else { throw LibraryError.invalid("Receipt data is too large.") }
        let hasReceiptSplit = library.drafts.contains { $0.receiptSplit != nil } || library.snapshots.contains { $0.receiptSplit != nil }
        let manifest = Manifest(formatVersion: 1, algorithm: AlgorithmVersion(schema: 1, allocationRule: hasReceiptSplit ? 2 : 1), imageReceiptIDs: images.keys.sorted { $0.uuidString < $1.uuidString })
        var result = ["manifest.json": try encoder.encode(manifest), "receipts.json": receipts]
        for (id, data) in images { result[Self.imageName(id)] = data }
        guard result.values.reduce(0, { $0 + $1.count }) <= Self.maximumBytes else { throw LibraryError.invalid("Backup exceeds 100 MB.") }
        return result
    }

    public static func decode(files: [String: Data]) throws -> LibraryBackup {
        guard files.count <= 1_002, files.values.reduce(0, { $0 + $1.count }) <= maximumBytes,
              let manifestData = files["manifest.json"], manifestData.count <= 100_000,
              let receipts = files["receipts.json"], receipts.count <= maximumJSONBytes else {
            throw LibraryError.invalid("This is not a supported Split Slip backup, or it is too large.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.formatVersion == 1 else { throw LibraryError.invalid("Unsupported backup version.") }
        try AlgorithmVersion.validateRestorable(manifest.algorithm)
        guard Set(manifest.imageReceiptIDs).count == manifest.imageReceiptIDs.count else { throw LibraryError.invalid("Duplicate image IDs.") }
        let expected = Set(["manifest.json", "receipts.json"] + manifest.imageReceiptIDs.map(imageName))
        guard Set(files.keys) == expected else { throw LibraryError.invalid("Unexpected, missing, or unsafe backup files.") }
        let library = try JSONDecoder().decode(ReceiptLibrary.self, from: receipts)
        try library.validate()
        var images: [UUID: Data] = [:]
        var decodedBytes = receipts.count + manifestData.count
        for id in manifest.imageReceiptIDs {
            // Never trust imported metadata, even when a manifest claims sanitization.
            let image = try ReferenceImageSandbox.sanitize(files[imageName(id)]!)
            #if canImport(ImageIO)
            guard image.reencoded else { throw LibraryError.invalid("An image could not be decoded.") }
            #endif
            decodedBytes += image.jpeg.count
            guard decodedBytes <= maximumBytes else { throw LibraryError.invalid("Decoded backup exceeds 100 MB.") }
            images[id] = image.jpeg
        }
        return try LibraryBackup(library: library, images: images)
    }

    public static func read(from folder: URL) throws -> LibraryBackup {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let root = try folder.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw LibraryError.invalid("Choose a backup folder, not a link.") }
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        guard children.count <= 1_002 else { throw LibraryError.invalid("Too many backup files.") }
        var files: [String: Data] = [:], total = 0
        for child in children {
            let attributes = try child.resourceValues(forKeys: keys)
            let limit = child.pathExtension == "json" ? maximumJSONBytes : ReferenceImageLimits.maximumEncodedBytes
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size <= limit else { throw LibraryError.invalid("Backup contains a link, directory, or oversized file.") }
            total += size
            guard total <= maximumBytes else { throw LibraryError.invalid("Backup exceeds 100 MB.") }
            // Bound reads as well as checking metadata (a provider can change a file).
            let handle = try FileHandle(forReadingFrom: child)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw LibraryError.invalid("Backup file grew beyond its limit.") }
            files[child.lastPathComponent] = data
        }
        return try decode(files: files)
    }

    public func write(to folder: URL) throws {
        let contents = try files()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            for (name, data) in contents { try data.write(to: folder.appendingPathComponent(name), options: .atomic) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
    private static func imageName(_ id: UUID) -> String { id.uuidString + ".jpg" }
}

/// Journaled cross-store replacement. Startup rolls back an interrupted operation
/// before the UI can open. The original folder remains available after a restore.
@MainActor
public final class LibraryTransfer {
    private let store: any ReceiptLibraryStore
    private let images: any ReferenceImageStore
    private let continuity: any ContinuityStore
    public let recoveryRoot: URL
    private var marker: URL { recoveryRoot.appendingPathComponent("pending.json") }
    private struct Pending: Codable { let backupID: UUID; let affectedIDs: [UUID]; let keepBackup: Bool; let selections: [UUID: WorkspaceSelection]? }

    public init(store: any ReceiptLibraryStore, images: any ReferenceImageStore,
                continuity: any ContinuityStore, recoveryRoot: URL) {
        self.store = store; self.images = images; self.continuity = continuity; self.recoveryRoot = recoveryRoot
    }

    public func backup() throws -> LibraryBackup {
        guard !FileManager.default.fileExists(atPath: marker.path) else {
            throw LibraryError.invalid("A previous operation needs recovery. Close and reopen Split Slip before continuing.")
        }
        let library = try store.readLibrary()
        var bytes: [UUID: Data] = [:]
        var totalBytes = 0
        for id in library.receiptIDs {
            if let url = try images.referenceImageURL(receiptID: id) {
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= ReferenceImageLimits.maximumEncodedBytes else {
                    throw LibraryError.invalid("A reference image cannot be backed up safely.")
                }
                totalBytes += attributes.fileSize ?? LibraryBackup.maximumBytes
                guard totalBytes <= LibraryBackup.maximumBytes - LibraryBackup.maximumJSONBytes else {
                    throw LibraryError.invalid("The image collection exceeds the backup size limit.")
                }
                let sanitized = try ReferenceImageSandbox.sanitize(Data(contentsOf: url)).jpeg
                totalBytes += sanitized.count - (attributes.fileSize ?? 0)
                guard totalBytes <= LibraryBackup.maximumBytes - LibraryBackup.maximumJSONBytes else {
                    throw LibraryError.invalid("Decoded images exceed the backup size limit.")
                }
                bytes[id] = sanitized
            }
        }
        return try LibraryBackup(library: library, images: bytes)
    }

    public func recoverIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: marker))
        let original = try LibraryBackup.read(from: recoveryRoot.appendingPathComponent(pending.backupID.uuidString))
        try apply(original, affected: Set(pending.affectedIDs))
        for (id, selection) in pending.selections ?? [:] { continuity.saveSelection(selection, receiptID: id) }
        try FileManager.default.removeItem(at: marker)
        if !pending.keepBackup { try? FileManager.default.removeItem(at: recoveryRoot.appendingPathComponent(pending.backupID.uuidString)) }
    }

    public func restore(_ backup: LibraryBackup, keepPrevious: Bool = true) throws {
        try recoverIfNeeded()
        // Revalidate before any writes. Imported data is staged entirely in memory.
        try backup.library.validate()
        let original = try self.backup()
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let id = UUID(), affected = original.library.receiptIDs.union(backup.library.receiptIDs)
        let folder = recoveryRoot.appendingPathComponent(id.uuidString)
        try original.write(to: folder)
        let selections = Dictionary(uniqueKeysWithValues: affected.compactMap { id in
            continuity.loadSelection(receiptID: id).map { (id, $0) }
        })
        let pending = Pending(backupID: id, affectedIDs: Array(affected), keepBackup: keepPrevious, selections: selections)
        try JSONEncoder().encode(pending).write(to: marker, options: .atomic)
        do {
            try apply(backup, affected: affected)
            try FileManager.default.removeItem(at: marker)
        } catch {
            do { try recoverIfNeeded() }
            catch { throw LibraryError.invalid("Recovery is pending. Close and reopen Split Slip before continuing. Your original backup is retained. \(error.localizedDescription)") }
            throw error
        }
        if !keepPrevious { try? FileManager.default.removeItem(at: folder) }
    }

    public func delete(receiptID: UUID) throws {
        let current = try backup()
        let library = ReceiptLibrary(drafts: current.library.drafts.filter { $0.id != receiptID },
                                     snapshots: current.library.snapshots.filter { $0.id != receiptID })
        try restore(LibraryBackup(library: library, images: current.images.filter { $0.key != receiptID }), keepPrevious: false)
        // Old recovery copies can also contain the deleted receipt.
        try clearPreviousBackups()
    }

    public func deleteAll() throws {
        try recoverIfNeeded()
        // Explicitly confirmed deletion must also work with unreadable photos;
        // it does not require exporting/sanitizing data the user is discarding.
        try store.replaceLibrary(ReceiptLibrary())
        try images.clearAllReferenceImages()
        try continuity.clearAllSelections()
        try clearPreviousBackups()
    }

    public func previousBackups() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: recoveryRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func clearPreviousBackups() throws {
        for folder in try previousBackups() { try FileManager.default.removeItem(at: folder) }
    }
    private func apply(_ backup: LibraryBackup, affected: Set<UUID>) throws {
        for id in affected {
            if let data = backup.images[id] { try images.setReferenceImage(data, receiptID: id) }
            else { try images.clearReferenceImage(receiptID: id) }
        }
        try store.replaceLibrary(backup.library)
        for id in affected { continuity.clearSelection(receiptID: id) }
    }
}
