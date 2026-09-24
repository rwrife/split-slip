import Foundation

/// What the workspace must remember for one receipt: which tab was open,
/// the selected line/adjustment and person, and the reference-image viewport
/// (issue #4: preserved through navigation, relaunch and rotation).
/// Layout never drives state — views read this value, they do not own it.
public struct WorkspaceSelection: Codable, Hashable, Sendable {
    public enum Tab: String, Codable, Sendable {
        case receipt
        case people
    }

    public var tab: Tab
    public var selectedRowID: UUID?
    public var selectedParticipantID: UUID?
    /// Reference viewport, deliberately bounded and validated so a corrupt
    /// stored value can never wedge the viewer.
    public var referenceZoom: Double
    public var referenceOffsetX: Double
    public var referenceOffsetY: Double

    public static let minimumZoom = 1.0
    public static let maximumZoom = 6.0
    public static let maximumOffsetMagnitude = 10_000.0

    public init(
        tab: Tab = .receipt,
        selectedRowID: UUID? = nil,
        selectedParticipantID: UUID? = nil,
        referenceZoom: Double = WorkspaceSelection.minimumZoom,
        referenceOffsetX: Double = 0,
        referenceOffsetY: Double = 0
    ) {
        self.tab = tab
        self.selectedRowID = selectedRowID
        self.selectedParticipantID = selectedParticipantID
        self.referenceZoom = referenceZoom
        self.referenceOffsetX = referenceOffsetX
        self.referenceOffsetY = referenceOffsetY
    }

    /// Clamps a stored/incoming viewport into its bounds instead of failing;
    /// out-of-range stored values are treated as damage, not trust.
    public func normalized() -> WorkspaceSelection {
        var copy = self
        copy.referenceZoom = min(max(referenceZoom, Self.minimumZoom), Self.maximumZoom)
        copy.referenceOffsetX = min(max(referenceOffsetX, -Self.maximumOffsetMagnitude), Self.maximumOffsetMagnitude)
        copy.referenceOffsetY = min(max(referenceOffsetY, -Self.maximumOffsetMagnitude), Self.maximumOffsetMagnitude)
        if !referenceZoom.isFinite { copy.referenceZoom = Self.minimumZoom }
        if !referenceOffsetX.isFinite { copy.referenceOffsetX = 0 }
        if !referenceOffsetY.isFinite { copy.referenceOffsetY = 0 }
        return copy
    }
}

/// Persistence for workspace selection only. Deliberately separate from the
/// draft store: losing continuity must never affect receipt data, and
/// clearing it must never touch drafts, snapshots or images.
public protocol ContinuityStore: Sendable {
    func loadSelection(receiptID: UUID) -> WorkspaceSelection?
    func saveSelection(_ selection: WorkspaceSelection, receiptID: UUID)
    func clearSelection(receiptID: UUID)
    func clearAllSelections() throws
    /// Transfers a selection to a new receipt id (draft → finalized snapshot,
    /// or snapshot → correction fork). Absent source is a no-op.
    func copySelection(from sourceID: UUID, to destinationID: UUID)
}

/// Test helper and lightweight fallback.
public final class InMemoryContinuityStore: ContinuityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: WorkspaceSelection] = [:]

    public init() {}

    public func loadSelection(receiptID: UUID) -> WorkspaceSelection? {
        lock.lock(); defer { lock.unlock() }
        return storage[receiptID]?.normalized()
    }

    public func saveSelection(_ selection: WorkspaceSelection, receiptID: UUID) {
        lock.lock(); defer { lock.unlock() }
        storage[receiptID] = selection.normalized()
    }

    public func clearSelection(receiptID: UUID) {
        lock.lock(); defer { lock.unlock() }
        storage[receiptID] = nil
    }

    public func clearAllSelections() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }

    public func copySelection(from sourceID: UUID, to destinationID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard sourceID != destinationID, let selection = storage[sourceID] else { return }
        storage[destinationID] = selection
    }
}

/// JSON-file continuity store written atomically in the app sandbox. A
/// corrupt file degrades to an empty store (the receipt data itself lives
/// elsewhere); every save replaces the file atomically.
public final class FileContinuityStore: ContinuityStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cache: [UUID: WorkspaceSelection] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: WorkspaceSelection].self, from: data) {
            for (key, value) in decoded {
                if let id = UUID(uuidString: key) { cache[id] = value }
            }
        }
    }

    public func loadSelection(receiptID: UUID) -> WorkspaceSelection? {
        lock.lock(); defer { lock.unlock() }
        return cache[receiptID]?.normalized()
    }

    public func saveSelection(_ selection: WorkspaceSelection, receiptID: UUID) {
        lock.lock(); defer { lock.unlock() }
        cache[receiptID] = selection.normalized()
        flushLocked()
    }

    public func clearSelection(receiptID: UUID) {
        lock.lock(); defer { lock.unlock() }
        cache[receiptID] = nil
        flushLocked()
    }

    public func clearAllSelections() throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url, options: .atomic)
        cache.removeAll()
    }

    public func copySelection(from sourceID: UUID, to destinationID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard sourceID != destinationID, let selection = cache[sourceID] else { return }
        cache[destinationID] = selection
        flushLocked()
    }

    private func flushLocked() {
        let encoder = JSONEncoder()
        let payload = cache.mapKeys { $0.uuidString }
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

private extension Dictionary {
    func mapKeys<Transformed: Hashable>(_ transform: (Key) -> Transformed) -> [Transformed: Value] {
        var result: [Transformed: Value] = [:]
        for (key, value) in self { result[transform(key)] = value }
        return result
    }
}
