import Foundation
import Testing
@testable import ReceiptDomain
@testable import SplitSlipCore

/// Builds a marker-valid JPEG whose ONLY content beyond the required
/// segments is the given metadata segments (APPn/COM). Pure byte fixtures —
/// nothing here requires an image codec.
package func makeJPEGWithMetadata(appSegments: [(marker: UInt8, payload: [UInt8])]) -> Data {
    func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = UInt16(payload.count + 2)
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }
    var bytes: [UInt8] = [0xFF, 0xD8] // SOI
    for meta in appSegments {
        bytes.append(contentsOf: segment(meta.marker, meta.payload))
    }
    bytes.append(contentsOf: segment(0xDB, [0x00] + Array(repeating: 1, count: 8)))   // DQT
    bytes.append(contentsOf: segment(0xC0, [0x08, 0x00, 0x08, 0x00, 0x08, 0x01, 0x01, 0x11, 0x00])) // SOF0
    bytes.append(contentsOf: segment(0xC4, [0x00, 0x01, 0x01]))                        // DHT
    bytes.append(contentsOf: segment(0xDA, [0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]))     // SOS
    bytes.append(contentsOf: [0x11, 0x22, 0x33, 0xFF, 0x00, 0x44])                    // entropy data
    bytes.append(contentsOf: [0xFF, 0xD9])                                            // EOI
    return Data(bytes)
}

package func containsMarkerSegment(_ data: Data, marker: UInt8) -> Bool {
    let bytes = [UInt8](data)
    var i = 2 // skip SOI
    while i + 1 < bytes.count {
        guard bytes[i] == 0xFF else { i += 1; continue }
        var j = i
        while j < bytes.count, bytes[j] == 0xFF { j += 1 }
        guard j < bytes.count else { break }
        if bytes[j] == marker { return true }
        // Skip past this segment's declared length to avoid false hits in
        // entropy data (heuristic is fine for our fixtures).
        if j + 2 < bytes.count, !(bytes[j] == 0xD9 || bytes[j] == 0xDA || (0xD0...0xD7).contains(bytes[j])) {
            let length = (Int(bytes[j + 1]) << 8) | Int(bytes[j + 2])
            i = j + 1 + max(length, 2)
        } else {
            i = j + 1
        }
    }
    return false
}

@Suite("Issue 4 reference image import pipeline")
struct ReferenceImageSandboxTests {
    @Test("format detection by signature")
    func detection() {
        #expect(ReferenceImageSandbox.detectFormat(Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(ReferenceImageSandbox.detectFormat(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])) == .png)
        #expect(ReferenceImageSandbox.detectFormat(Data("GIF89a....".utf8)) == .gif)
        #expect(ReferenceImageSandbox.detectFormat(Data("BM......".utf8)) == .bmp)
        #expect(ReferenceImageSandbox.detectFormat(Data([0x49, 0x49, 0x2A, 0x00, 0])) == .tiff)
        var heic = [UInt8](repeating: 0, count: 12)
        heic[0...3] = [0, 0, 0, 24][...]
        heic[4..<8] = Array("ftyp".utf8)[...]
        heic[8..<12] = Array("heic".utf8)[...]
        #expect(ReferenceImageSandbox.detectFormat(Data(heic)) == .heic)
        #expect(ReferenceImageSandbox.detectFormat(Data("MZ......".utf8)) == .unknown)
    }

    @Test("JPEG EXIF/GPS/XMP/comment metadata is structurally removed")
    func jpegMetadataStripped() throws {
        let exifPayload = Array("Exif\0\0GPS:37.7749,-122.4194;camera=iPhone;owner=rwrife".utf8)
        let xmpPayload = Array("<xmp:CreatorTool>Leaked</xmp:CreatorTool>".utf8)
        let input = makeJPEGWithMetadata(appSegments: [
            (0xE0, Array("JFIF\0".utf8) + [1, 2]),        // JFIF (kept content is metadata too)
            (0xE1, exifPayload),                          // EXIF + GPS
            (0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1]), // ICC (APP2, stripped: policy is all APPn)
            (0xEE, Array("Adobe Photoshop junk".utf8)),   // APP14
            (0xFE, Array("Comment: private note".utf8)),  // COM
        ])
        let output = try ReferenceImageSandbox.stripJPEGMetadata(input)

        for marker: UInt8 in [0xE0, 0xE1, 0xE2, 0xEE, 0xFE] {
            #expect(!containsMarkerSegment(output, marker: marker),
                    "marker 0x\(String(marker, radix: 16)) survived the strip")
        }
        // Required structure still present and intact.
        #expect(containsMarkerSegment(output, marker: 0xC0))
        #expect(containsMarkerSegment(output, marker: 0xDA))
        #expect(output.count < input.count)
        #expect([UInt8](output.prefix(2)) == [0xFF, 0xD8])
        #expect([UInt8](output.suffix(2)) == [0xFF, 0xD9])
        // No leaked ASCII from the metadata survives anywhere in output.
        let text = String(decoding: output, as: UTF8.self)
        #expect(!text.contains("37.7749"))
        #expect(!text.contains("Leaked"))
        #expect(!text.contains("private note"))
        #expect(!text.contains("Photoshop"))
    }

    @Test("stripping is deterministic and idempotent")
    func idempotent() throws {
        let input = makeJPEGWithMetadata(appSegments: [(0xE1, Array("Exif\0\0secret".utf8))])
        let once = try ReferenceImageSandbox.stripJPEGMetadata(input)
        let twice = try ReferenceImageSandbox.stripJPEGMetadata(once)
        #expect(once == twice)
    }

    @Test("truncated and malformed JPEGs fail closed")
    func malformedRejected() {
        let valid = makeJPEGWithMetadata(appSegments: [(0xE1, Array("Exif\0\0x".utf8))])
        #expect(throws: ReferenceImageError.failedVerification) {
            _ = try ReferenceImageSandbox.stripJPEGMetadata(valid.prefix(60))
        }
        // Length field claiming more bytes than remain.
        var corrupt = [UInt8](valid)
        corrupt[2] = 0xFF
        corrupt[3] = 0xE1
        corrupt[4] = 0xFF
        corrupt[5] = 0xFF
        #expect(throws: ReferenceImageError.failedVerification) {
            _ = try ReferenceImageSandbox.stripJPEGMetadata(Data(corrupt))
        }
        #expect(throws: ReferenceImageError.failedVerification) {
            _ = try ReferenceImageSandbox.stripJPEGMetadata(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        }
    }

    @Test("sanitize refuses empty, oversized and unrecognized payloads")
    func sanitizeRefusals() {
        #expect(throws: ReferenceImageError.noData) {
            _ = try ReferenceImageSandbox.sanitize(Data())
        }
        let big = Data(count: ReferenceImageSandbox.maximumInputBytes + 1)
        #expect(throws: ReferenceImageError.tooLarge(byteCount: big.count)) {
            _ = try ReferenceImageSandbox.sanitize(big)
        }
        let notAnImage = Data(repeating: 0x42, count: 64)
        #expect(throws: ReferenceImageError.unsupportedFormat("unrecognized")) {
            _ = try ReferenceImageSandbox.sanitize(notAnImage)
        }
    }

    @Test("sanitize accepts JPEG payloads and output carries no metadata segments")
    func sanitizeJPEG() throws {
        #if canImport(ImageIO)
        // On Apple platforms the ImageIO transcode path owns this; the
        // pure stripper is still exercised directly above on every host.
        #else
        let input = makeJPEGWithMetadata(appSegments: [(0xE1, Array("Exif\0\0GPS:1,2".utf8))])
        let result = try ReferenceImageSandbox.sanitize(input)
        #expect(result.sourceFormat == .jpeg)
        #expect(!containsMarkerSegment(result.jpeg, marker: 0xE1))
        #expect(result.jpeg.count < input.count)
        #endif
    }
}

@Suite("Issue 4 workspace continuity")
struct WorkspaceContinuityTests {
    @Test("selection normalizes out-of-range viewport values instead of trusting them")
    func normalization() {
        let damaged = WorkspaceSelection(
            tab: .people,
            selectedRowID: nil,
            selectedParticipantID: nil,
            referenceZoom: .nan,
            referenceOffsetX: .infinity,
            referenceOffsetY: 999_999)
        let safe = damaged.normalized()
        #expect(safe.referenceZoom == WorkspaceSelection.minimumZoom)
        #expect(safe.referenceOffsetX == 0)
        #expect(safe.referenceOffsetY == WorkspaceSelection.maximumOffsetMagnitude)
        #expect(safe.tab == .people)
    }

    @Test("in-memory continuity round-trips per receipt id and copies atomically by id")
    func memoryStore() {
        let store = InMemoryContinuityStore()
        let a = UUID()
        let b = UUID()
        store.saveSelection(WorkspaceSelection(tab: .people, referenceZoom: 2.5), receiptID: a)
        #expect(store.loadSelection(receiptID: a)?.tab == .people)
        #expect(store.loadSelection(receiptID: a)?.referenceZoom == 2.5)
        #expect(store.loadSelection(receiptID: b) == nil)

        store.copySelection(from: a, to: b)
        #expect(store.loadSelection(receiptID: b)?.referenceZoom == 2.5)
        store.clearSelection(receiptID: a)
        #expect(store.loadSelection(receiptID: a) == nil)
        #expect(store.loadSelection(receiptID: b) != nil)
    }

    @Test("file continuity store survives store recreation (relaunch simulation) and rejects corruption")
    func fileStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitslip-continuity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()

        let first = FileContinuityStore(url: url)
        first.saveSelection(WorkspaceSelection(tab: .people, selectedRowID: id, referenceZoom: 4,
                                               referenceOffsetX: -3, referenceOffsetY: 7),
                            receiptID: id)
        // "Relaunch": a fresh store over the same file restores the selection.
        let second = FileContinuityStore(url: url)
        let restored = try #require(second.loadSelection(receiptID: id))
        #expect(restored.tab == .people)
        #expect(restored.selectedRowID == id)
        #expect(restored.referenceZoom == 4)
        #expect(restored.referenceOffsetX == -3)
        #expect(restored.referenceOffsetY == 7)

        // Corrupt file: degrades to empty rather than crashing or crashing.
        try Data("{ not json".utf8).write(to: url)
        let damaged = FileContinuityStore(url: url)
        #expect(damaged.loadSelection(receiptID: id) == nil)
        // Still writable.
        damaged.saveSelection(WorkspaceSelection(tab: .receipt), receiptID: id)
        #expect(damaged.loadSelection(receiptID: id)?.tab == .receipt)
    }
}
