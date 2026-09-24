import Foundation

/// Bounded limits for one optional receipt reference image (issue #4).
public enum ReferenceImageLimits {
    /// Largest accepted encoded reference image, in bytes.
    public static let maximumEncodedBytes: Int = 12_000_000
    /// Reference images are stored with a fixed app-private file name per
    /// receipt; nothing is user-persistent until issue #5 backups.
    public static let fileExtension = "jpg"
}

/// Why an optional reference image was refused. Every case is visible copy —
/// a refusal never touches the previously stored image or the draft.
public enum ReferenceImageError: Error, Hashable, Sendable {
    case noData
    case tooLarge(byteCount: Int)
    case storageFailed(String)
    /// Payload is not a recognized image or the platform cannot decode this
    /// format without leaving metadata behind; nothing is stored.
    case unsupportedFormat(String)
    /// A structural rewrite could not be verified as a complete JPEG.
    case failedVerification
}

/// Reference-image storage contract. A store either has exactly zero or one
/// reference image per receipt id; setting replaces atomically and clearing
/// removes the owned file. Issue #5 deletion reuses `clear`.
public protocol ReferenceImageStore: Sendable {
    func referenceImageURL(receiptID: UUID) throws -> URL?
    func setReferenceImage(_ jpeg: Data, receiptID: UUID) throws
    func clearReferenceImage(receiptID: UUID) throws
    /// Copies a receipt's reference image to another receipt id (used when a
    /// finalized snapshot is duplicated to a correction draft). Absent source
    /// is a no-op; an existing destination is replaced atomically.
    func copyReference(from sourceID: UUID, to destinationID: UUID) throws
    func clearAllReferenceImages() throws
}

/// Filesystem-backed reference image store rooted inside the app sandbox.
/// Receipt ids are UUIDs so file names are structurally safe; the store still
/// refuses any id whose derived path escapes the root, and replaces files
/// write-temp-then-move so a failed write never truncates the old image.
public final class LocalReferenceImageStore: ReferenceImageStore, @unchecked Sendable {
    public let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // Reference images may contain printed receipt contents; keep the
        // directory owner-only where the platform supports it.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    private func fileURL(receiptID: UUID) throws -> URL {
        let candidate = rootDirectory
            .appendingPathComponent(receiptID.uuidString, isDirectory: false)
            .appendingPathExtension(ReferenceImageLimits.fileExtension)
        let standard = candidate.standardizedFileURL
        let root = rootDirectory.standardizedFileURL
        guard standard.path.hasPrefix(root.path + "/") else {
            // Structurally impossible for a real UUID; fail closed anyway.
            throw ReferenceImageError.storageFailed("derived path escapes the reference root")
        }
        return standard
    }

    public func referenceImageURL(receiptID: UUID) throws -> URL? {
        let url = try fileURL(receiptID: receiptID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func setReferenceImage(_ jpeg: Data, receiptID: UUID) throws {
        guard !jpeg.isEmpty else { throw ReferenceImageError.noData }
        guard jpeg.count <= ReferenceImageLimits.maximumEncodedBytes else {
            throw ReferenceImageError.tooLarge(byteCount: jpeg.count)
        }
        let url = try fileURL(receiptID: receiptID)
        do {
            // Foundation performs the same-volume rename atomically; never delete
            // the original before the replacement has successfully been written.
            try jpeg.write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ReferenceImageError.storageFailed("write: \(error)")
        }
    }

    public func clearReferenceImage(receiptID: UUID) throws {
        let url = try fileURL(receiptID: receiptID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func clearAllReferenceImages() throws {
        for url in try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) {
            let base = url.pathExtension == "tmp" ? url.deletingPathExtension() : url
            guard base.pathExtension == ReferenceImageLimits.fileExtension,
                  UUID(uuidString: base.deletingPathExtension().lastPathComponent) != nil else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    public func copyReference(from sourceID: UUID, to destinationID: UUID) throws {
        guard sourceID != destinationID else { return }
        guard let source = try referenceImageURL(receiptID: sourceID) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw ReferenceImageError.storageFailed("copy read: \(error)")
        }
        try setReferenceImage(data, receiptID: destinationID)
    }
}
