import Foundation
import ReceiptDomain

#if canImport(ImageIO)
import ImageIO
#endif

/// Result of a successful reference-image sanitization pass.
public struct SanitizedReferenceImage: Hashable, Sendable {
    /// Re-encoded, metadata-free JPEG bytes ready for app-private storage.
    public let jpeg: Data
    /// Format detected in the original payload (for user-facing copy).
    public let sourceFormat: ReferenceImageFormat
    /// True when the bytes were re-encoded through an image pipeline rather
    /// than structurally stripped; both paths remove metadata.
    public let reencoded: Bool
}

public enum ReferenceImageFormat: String, Hashable, Sendable {
    case jpeg
    case png
    case gif
    case bmp
    case tiff
    case heic
    case unknown
}

/// Platform-independent reference-image import pipeline (issue #4).
///
/// Every accepted payload becomes a JPEG with all metadata removed:
/// - Apple platforms require a successful bounded ImageIO decode and fresh
///   encode. Malformed JPEG marker streams are never accepted as images.
/// - Hosts without ImageIO retain the structural JPEG test implementation.
/// - Other decodable formats (PNG/GIF/BMP/TIFF/HEIC) are transcoded to JPEG
///   where the platform provides ImageIO; on hosts without a codec the
///   payload is rejected with a visible error, never stored unprocessed.
/// - Undetectable or undecodable payloads are rejected outright.
public enum ReferenceImageSandbox {
    /// Upper bound on the accepted payload, checked before any parsing.
    public static let maximumInputBytes = ReferenceImageLimits.maximumEncodedBytes

    // MARK: - Format detection (signature based, no decoding required)

    public static func detectFormat(_ data: Data) -> ReferenceImageFormat {
        let bytes = [UInt8](data.prefix(16))
        func prefix(_ count: Int, equals target: [UInt8]) -> Bool {
            bytes.count >= count && Array(bytes.prefix(count)) == target
        }
        if prefix(8, equals: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if prefix(6, equals: Array("GIF87a".utf8)) || prefix(6, equals: Array("GIF89a".utf8)) { return .gif }
        if prefix(2, equals: Array("BM".utf8)) { return .bmp }
        if prefix(4, equals: [0x49, 0x49, 0x2A, 0x00]) || prefix(4, equals: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = Array(bytes[8..<12])
            for candidate in ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"]
            where brand == Array(candidate.utf8) { return .heic }
        }
        if prefix(3, equals: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        return .unknown
    }

    // MARK: - Import

    /// Sanitize an imported payload. Throws typed, user-visible refusals;
    /// a throw never produces output, so callers never store partial work.
    public static func sanitize(_ payload: Data) throws -> SanitizedReferenceImage {
        guard !payload.isEmpty else { throw ReferenceImageError.noData }
        guard payload.count <= maximumInputBytes else {
            throw ReferenceImageError.tooLarge(byteCount: payload.count)
        }
        let format = detectFormat(payload)
        switch format {
        case .jpeg:
            #if canImport(ImageIO)
            guard let transcoded = transcodeToJPEG(payload), transcoded.count <= maximumInputBytes else {
                throw ReferenceImageError.failedVerification
            }
            return SanitizedReferenceImage(jpeg: transcoded, sourceFormat: .jpeg, reencoded: true)
            #else
            let stripped = try stripJPEGMetadata(payload)
            return SanitizedReferenceImage(jpeg: stripped, sourceFormat: .jpeg, reencoded: false)
            #endif
        case .png, .gif, .bmp, .tiff, .heic:
            #if canImport(ImageIO)
            if let transcoded = transcodeToJPEG(payload), transcoded.count <= maximumInputBytes {
                return SanitizedReferenceImage(jpeg: transcoded, sourceFormat: format, reencoded: true)
            }
            #endif
            throw ReferenceImageError.unsupportedFormat(format.rawValue)
        case .unknown:
            throw ReferenceImageError.unsupportedFormat("unrecognized")
        }
    }

    // MARK: - Structural JPEG metadata stripper (pure, deterministic)

    /// Rebuilds a JPEG keeping only SOI, non-metadata segments and the scan
    /// data, deleting every APPn (0xE0–0xEF, includes EXIF/JFIF/XMP) and
    /// comment (0xFE) segment. Output is verified to still contain an SOF,
    /// SOS and EOI before it is returned.
    static func stripJPEGMetadata(_ data: Data) throws -> Data {
        let input = [UInt8](data)
        guard input.count >= 4, input[0] == 0xFF, input[1] == 0xD8 else {
            throw ReferenceImageError.failedVerification
        }
        var output: [UInt8] = [0xFF, 0xD8]
        var sawStartOfFrame = false
        var sawStartOfScan = false
        var i = 2
        while i + 1 < input.count {
            guard input[i] == 0xFF else { throw ReferenceImageError.failedVerification }
            // Skip fill bytes (runs of 0xFF before a marker).
            var j = i
            while j < input.count, input[j] == 0xFF { j += 1 }
            guard j < input.count else { break }
            let marker = input[j]
            let markerStart = j - 1
            switch marker {
            case 0x01, 0xD8: // TEM, standalone SOI
                output.append(contentsOf: input[markerStart..<j + 1])
                i = j + 1
            case 0xD0...0xD7: // RSTn — appear inside scan data only
                output.append(contentsOf: input[markerStart..<j + 1])
                i = j + 1
            case 0xD9: // EOI
                output.append(contentsOf: [0xFF, 0xD9])
                i = input.count
            case 0xE0...0xEF, 0xFE: // APPn + COM: metadata → drop
                guard j + 3 <= input.count else { throw ReferenceImageError.failedVerification }
                let segmentLength = (Int(input[j + 1]) << 8) | Int(input[j + 2])
                guard segmentLength >= 2 else { throw ReferenceImageError.failedVerification }
                let end = j + 1 + segmentLength
                guard end <= input.count else { throw ReferenceImageError.failedVerification }
                i = end
            case 0xC0...0xCF: // SOFn family (C4/C8/CC are the extended variants)
                try copySegment(input, from: markerStart, j: j, into: &output)
                sawStartOfFrame = true
                let segmentLength = (Int(input[j + 1]) << 8) | Int(input[j + 2])
                i = j + 1 + segmentLength
            case 0xDA: // SOS — header plus entropy-coded remainder copied raw
                try copySegment(input, from: markerStart, j: j, into: &output)
                let scanHeaderEnd = j + 1 + ((Int(input[j + 1]) << 8) | Int(input[j + 2]))
                guard scanHeaderEnd < input.count else {
                    // SOS claiming to reach the end has no entropy data/EOI.
                    throw ReferenceImageError.failedVerification
                }
                output.append(contentsOf: input[scanHeaderEnd...])
                sawStartOfScan = true
                i = input.count
            default:
                try copySegment(input, from: markerStart, j: j, into: &output)
                let segmentLength = (Int(input[j + 1]) << 8) | Int(input[j + 2])
                i = j + 1 + segmentLength
            }
        }
        guard sawStartOfFrame, sawStartOfScan,
              output.count > 4, output[0] == 0xFF, output[1] == 0xD8,
              output[output.count - 2] == 0xFF, output[output.count - 1] == 0xD9
        else { throw ReferenceImageError.failedVerification }
        return Data(output)
    }

    private static func copySegment(_ input: [UInt8], from markerStart: Int, j: Int, into output: inout [UInt8]) throws {
        guard j + 3 <= input.count else { throw ReferenceImageError.failedVerification }
        let segmentLength = (Int(input[j + 1]) << 8) | Int(input[j + 2])
        guard segmentLength >= 2 else { throw ReferenceImageError.failedVerification }
        let end = j + 1 + segmentLength
        guard end <= input.count else { throw ReferenceImageError.failedVerification }
        output.append(contentsOf: input[markerStart..<end])
    }

    // MARK: - System codec transcode (Apple platforms only)

    #if canImport(ImageIO)
    /// Decodes any ImageIO-supported payload and re-encodes a fresh JPEG
    /// without passing through any source metadata.
    static func transcodeToJPEG(_ data: Data) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 48_000_000
        else { return nil }
        // Decode to a bounded working image and bake in orientation before
        // discarding metadata. Compressed byte size alone cannot bound memory.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }

        var hints: [CFString: Any] = [
            kCGImagePropertyHasAlpha: false,
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ]
        // Flatten alpha onto white so PNGs with transparency stay legible.
        hints[kCGImageDestinationBackgroundColor] = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, hints as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        // ImageIO may add fresh EXIF/JFIF records; drop those too. DRI/DNL
        // are length-bearing JPEG segments and remain intact in the stripper.
        return output.length > 0 ? try? stripJPEGMetadata(output as Data) : nil
    }
    #endif
}
