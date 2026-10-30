import Foundation
import ReceiptDomain
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func readRegularBackupFile(_ url: URL, limit: Int, directoryFD: Int32? = nil) throws -> Data {
    // Check the descriptor, not just the enumerated path: provider files may
    // change between listing and reading. O_NOFOLLOW rejects a swapped link.
    // O_NONBLOCK prevents an attacker-supplied FIFO from waiting for a writer
    // before fstat can reject it; regular files still read normally.
    // For imported folders openat pins the original root even if its path moves.
    let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
    let fd = directoryFD.map { openat($0, url.lastPathComponent, flags) }
        ?? open(url.path, flags)
    guard fd >= 0 else { throw LibraryError.invalid("Backup file cannot be opened safely.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else {
        throw LibraryError.invalid("Backup contains a link, directory, or oversized file.")
    }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw LibraryError.invalid("Backup file grew beyond its limit.") }
    return data
}

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
        var sanitized: [UUID: Data] = [:], total = 0
        for (id, bytes) in images {
            // ponytail: repeat transcoding at public backup boundary; optimize only if a verified sanitized-image type exists.
            let jpeg = try ReferenceImageSandbox.sanitize(bytes).jpeg
            total += jpeg.count
            guard total <= Self.maximumBytes else { throw LibraryError.invalid("Image data exceeds the backup size limit.") }
            sanitized[id] = jpeg
        }
        self.library = library; self.images = sanitized
        // Imported and programmatic backups share the same metadata-free boundary.
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
        let requiresRule2 = library.drafts.contains { $0.receiptSplit != nil } || library.snapshots.contains { $0.receiptSplit != nil }
        guard (manifest.algorithm.allocationRule == 2) == requiresRule2 else {
            throw LibraryError.invalid("The split method does not match the backup manifest allocation version.")
        }
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
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey]
        let root = try folder.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw LibraryError.invalid("Choose a backup folder, not a link.") }
        let rootFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw LibraryError.invalid("Backup folder cannot be opened safely.") }
        defer { _ = close(rootFD) }
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var rootInfo = stat(), pathInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, lstat(folder.path, &pathInfo) == 0,
              rootInfo.st_dev == pathInfo.st_dev, rootInfo.st_ino == pathInfo.st_ino else {
            throw LibraryError.invalid("Backup folder changed while reading.")
        }
        guard children.count <= 1_002 else { throw LibraryError.invalid("Too many backup files.") }
        var files: [String: Data] = [:], total = 0
        for child in children {
            // Do not trust path metadata after enumeration. The descriptor
            // check in `readRegularBackupFile` is authoritative and rejects
            // links, directories and oversized files at read time.
            let limit = child.pathExtension == "json" ? maximumJSONBytes : ReferenceImageLimits.maximumEncodedBytes
            let data = try readRegularBackupFile(child, limit: limit, directoryFD: rootFD)
            total += data.count
            guard total <= maximumBytes else { throw LibraryError.invalid("Backup exceeds 100 MB.") }
            files[child.lastPathComponent] = data
        }
        return try decode(files: files)
    }

    public func write(to folder: URL) throws {
        let contents = try files()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            // ponytail: POSIX permissions are best-effort: Files providers may
            // ignore chmod; keep the explicit export/privacy warning in the UI.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            for (name, data) in contents {
                let url = folder.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
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
                let sanitized = try ReferenceImageSandbox.sanitize(
                    readRegularBackupFile(url, limit: ReferenceImageLimits.maximumEncodedBytes)
                ).jpeg
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
