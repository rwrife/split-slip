import Foundation
import Testing
@testable import ReceiptDomain

/// Synthetic JPEG builder for deterministic, platform-independent tests.
/// Produces marker-valid byte streams; they are never decoded, only parsed
/// structurally by the stripper.
private func syntheticJPEG(withMetadata metadata: [(marker: UInt8, payload: [UInt8])]) -> [UInt8] {
    func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = UInt16(payload.count + 2)
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }
    var bytes: [UInt8] = [0xFF, 0xD8] // SOI
    for meta in metadata {
        bytes.append(contentsOf: segment(meta.marker, meta.payload))
    }
    // DQT, SOF0, DHT — small valid-shaped segments.
    bytes.append(contentsOf: segment(0xDB, [0x00] + Array(repeating: 1, count: 8)))
    bytes.append(contentsOf: segment(0xC0, [0x08, 0x00, 0x08, 0x00, 0x08, 0x01, 0x01, 0x11, 0x00]))
    bytes.append(contentsOf: segment(0xC4, [0x00, 0x01, 0x01]))
    // SOS header + fake entropy data.
    bytes.append(contentsOf: segment(0xDA, [0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]))
    bytes.append(contentsOf: [0x11, 0x22, 0x33, 0xFF, 0x00, 0x44, 0xFF, 0xD0, 0x55])
    bytes.append(contentsOf: [0xFF, 0xD9]) // EOI
    return bytes
}

@Suite("Issue 4 reference image storage")
struct ReferenceImageStoreTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitslip-ref-tests-\(UUID().uuidString)", isDirectory: true)
        return root
    }

    @Test("set → read → replace → clear round-trip with owned files")
    func roundTrip() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalReferenceImageStore(rootDirectory: root)
        let id = UUID()

        #expect(try store.referenceImageURL(receiptID: id) == nil)
        try store.setReferenceImage(Data([1, 2, 3]), receiptID: id)
        let url = try #require(try store.referenceImageURL(receiptID: id))
        #expect(url.lastPathComponent == "\(id.uuidString).jpg")
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))

        try store.setReferenceImage(Data([9, 9]), receiptID: id) // replace
        #expect(try Data(contentsOf: #require(try store.referenceImageURL(receiptID: id))) == Data([9, 9]))

        try store.clearReferenceImage(receiptID: id)
        #expect(try store.referenceImageURL(receiptID: id) == nil)
    }

    @Test("empty payload and oversized payload are refused without touching storage")
    func refusals() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalReferenceImageStore(rootDirectory: root)
        let id = UUID()
        try store.setReferenceImage(Data([7]), receiptID: id)

        #expect(throws: ReferenceImageError.noData) {
            try store.setReferenceImage(Data(), receiptID: id)
        }
        let oversized = Data(count: ReferenceImageLimits.maximumEncodedBytes + 1)
        #expect(throws: ReferenceImageError.tooLarge(byteCount: oversized.count)) {
            try store.setReferenceImage(oversized, receiptID: id)
        }
        // The previous image survived both refusals.
        #expect(try Data(contentsOf: #require(try store.referenceImageURL(receiptID: id))) == Data([7]))
    }

    @Test("copyReference moves an image to a new receipt id; absent source is a no-op")
    func copyReference() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalReferenceImageStore(rootDirectory: root)
        let source = UUID()
        let destination = UUID()

        try store.copyReference(from: source, to: destination) // no source: no-op
        #expect(try store.referenceImageURL(receiptID: destination) == nil)

        try store.setReferenceImage(Data([5, 6]), receiptID: source)
        try store.copyReference(from: source, to: destination)
        #expect(try Data(contentsOf: #require(try store.referenceImageURL(receiptID: destination))) == Data([5, 6]))
        // Source keeps its copy until the caller clears it explicitly.
        #expect(try store.referenceImageURL(receiptID: source) != nil)
    }

    @Test("each receipt keeps its own image; clearing one never touches another")
    func isolation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalReferenceImageStore(rootDirectory: root)
        let a = UUID()
        let b = UUID()
        try store.setReferenceImage(Data([1]), receiptID: a)
        try store.setReferenceImage(Data([2]), receiptID: b)
        try store.clearReferenceImage(receiptID: a)
        #expect(try store.referenceImageURL(receiptID: a) == nil)
        #expect(try Data(contentsOf: #require(try store.referenceImageURL(receiptID: b))) == Data([2]))
    }
}
