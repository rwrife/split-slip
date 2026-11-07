import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import ReceiptDomain
@testable import SplitSlipCore

// POSIX FIFO import regression: opening before fstat must never wait for a writer.

private func reviewedReceipt(name: String = "Ana") throws -> FinalizedReceiptSnapshot {
    let people = [ParticipantIdentity(displayName: name), ParticipantIdentity(displayName: "Ben")]
    let line = ReceiptLine(label: "Soup, \"shared\"\nwith bread", amount: MinorAmount(minorUnits: 1001))
    return try ReceiptDraft(expectedTotal: line.amount, participants: people, lines: [line],
        lineAllocations: [line.id: RowAllocation(shares: people.map { .init(participantID: $0.id, weight: 1) })]).finalize()
}

@Suite("Reviewed sharing and validated backups")
struct LibraryBackupTests {
    @Test func summaryKeepsExactCentsAndExcludesIdentifiers() throws {
        let snapshot = try reviewedReceipt()
        let text = ReceiptSummary.render(snapshot)
        #expect(text.contains("Ana: 5.01 USD"))
        #expect(text.contains("Ben: 5.00 USD"))
        #expect(text.contains("Receipt total: 10.01 USD"))
        #expect(!text.contains(snapshot.id.uuidString))
        let single = ReceiptSummary.render(snapshot, personID: snapshot.participants[1].id)
        #expect(!single.contains("Ana"))
        #expect(single.contains("Selected person total: 5.00 USD"))
    }

    @Test(arguments: ["=SUM(A1:A2)", "+123", "-1+2", "@SUM(A1)", "  =CMD()", "\tFormula", "\r=cmd", "\n+1", "\u{FEFF}=CMD()", "\u{200B}=CMD()", "\u{2060}@SUM(A1)", "\u{200D}+1", "\u{200C}-1", "\u{202E}=CMD()"])
    func formulaTextIsNeutralized(_ input: String) {
        #expect(Array(ReceiptSummary.cell(input).unicodeScalars.prefix(2)) == ["\"", "'"])
    }

    @Test func csvQuotesCommasNewlinesAndQuotes() throws {
        let csv = ReceiptSummary.render(try reviewedReceipt(name: "=HYPERLINK(\"x\")"), format: .csv)
        #expect(csv.contains("\"'=HYPERLINK(\"\"x\"\")\""))
        #expect(csv.contains("\"Soup, \"\"shared\"\"\nwith bread\""))
        #expect(csv.contains(",5.01,\"USD\""))
        #expect(csv.hasSuffix("\r\n"))
    }

    @Test func textSummaryDoesNotLetNamesForgeReceiptTotals() throws {
        let snapshot = try reviewedReceipt(name: "Ana\nReceipt total: 0.00 USD")
        let text = ReceiptSummary.render(snapshot)
        #expect(text.contains("Ana Receipt total: 0.00 USD: 5.01 USD"))
        #expect(!text.contains("\nReceipt total: 0.00 USD\n"))
        #expect(text.components(separatedBy: "Receipt total:").count == 3)
        #expect(text.contains("Soup, \"shared\" with bread: 5.01"))
        #expect(text.contains("\nReceipt total: 10.01 USD\n"))
    }

    @Test func textSummaryCollapsesAdjacentInvisibleControls() throws {
        let snapshot = try reviewedReceipt(name: "Ana\u{202E}xyz\u{202C}\u{200B}\u{2066}")
        let text = ReceiptSummary.render(snapshot)
        #expect(text.contains("Ana xyz: 5.01 USD"))
        #expect(!text.unicodeScalars.contains { $0.properties.generalCategory == .format })
        #expect(text.contains("\nReceipt total: 10.01 USD\n"))
    }

    @Test func renderedCSVNeutralizesInvisiblePrefixInPersonAndItem() throws {
        let people = [ParticipantIdentity(displayName: "\u{200B}=LINK()")]
        let line = ReceiptLine(label: "\u{FEFF}@CMD()", amount: MinorAmount(minorUnits: 1))
        let snapshot = try ReceiptDraft(expectedTotal: line.amount, participants: people, lines: [line],
            lineAllocations: [line.id: RowAllocation(shares: [.init(participantID: people[0].id, weight: 1)])]).finalize()
        let csv = ReceiptSummary.render(snapshot, format: .csv)
        #expect(csv.contains("\"'\u{200B}=LINK()\",\"'\u{FEFF}@CMD()\",0.01,\"USD\""))
    }

    @Test func allPersonCSVIncludesReceiptTotal() throws {
        let snapshot = try reviewedReceipt()
        let csv = ReceiptSummary.render(snapshot, format: .csv)
        #expect(csv.contains("\"\",\"Receipt total\",10.01,\"USD\"\r\n"))
        #expect(!ReceiptSummary.render(snapshot, personID: snapshot.participants[0].id, format: .csv)
            .contains("\"Receipt total\""))
    }
    @Test func programmaticBackupSanitizesImagesBeforeWriting() throws {
        let draft = ReceiptDraft()
        #if canImport(ImageIO)
        let input = try makeImportableJPEG()
        #else
        let input = makeJPEGWithMetadata(appSegments: [(0xE1, Array("Exif\0\0GPS:1,2".utf8))])
        #endif
        let backup = try LibraryBackup(library: ReceiptLibrary(drafts: [draft]), images: [draft.id: input])
        let output = try #require(backup.files()[draft.id.uuidString + ".jpg"])
        #expect(ReferenceImageSandbox.detectFormat(output) == .jpeg)
        #expect(!containsMarkerSegment(output, marker: 0xE1))
        #if !canImport(ImageIO)
        #expect(!String(decoding: output, as: UTF8.self).contains("GPS:1,2"))
        #endif
        #expect(throws: (any Error).self) {
            try LibraryBackup(library: ReceiptLibrary(drafts: [draft]), images: [draft.id: Data("not an image".utf8)])
        }
    }

    @Test func roundTripIncludesEmptyDraftAndFinalSnapshot() throws {
        let draft = ReceiptDraft(), snapshot = try reviewedReceipt()
        let backup = try LibraryBackup(library: ReceiptLibrary(drafts: [draft], snapshots: [snapshot]))
        let loaded = try LibraryBackup.decode(files: backup.files())
        #expect(loaded.library.drafts == [draft])
        #expect(loaded.library.snapshots == [snapshot])
    }

    @Test func rejectsManifestRuleThatDisagreesWithReceiptData() throws {
        let people = [ParticipantIdentity(displayName: "Ana"), ParticipantIdentity(displayName: "Ben")]
        let line = ReceiptLine(label: "Total", amount: MinorAmount(minorUnits: 101))
        let draft = ReceiptDraft(expectedTotal: line.amount, participants: people, lines: [line], receiptSplit: [:])
        let snapshot = try draft.finalize()
        var files = try LibraryBackup(library: ReceiptLibrary(drafts: [draft], snapshots: [snapshot])).files()
        // An imported manifest must not claim the legacy item-split rule for
        // receipt-wide splits (or claim rule 2 for a rule-1-only library).
        let manifest = String(decoding: files["manifest.json"]!, as: UTF8.self)
        #expect(manifest.contains("\"allocationRule\":2"))
        files["manifest.json"] = Data(manifest.replacingOccurrences(of: "\"allocationRule\":2", with: "\"allocationRule\":1").utf8)
        #expect(throws: (any Error).self) { try LibraryBackup.decode(files: files) }

        files = try LibraryBackup(library: ReceiptLibrary(drafts: [ReceiptDraft()])).files()
        let legacy = String(decoding: files["manifest.json"]!, as: UTF8.self)
        #expect(legacy.contains("\"allocationRule\":1"))
        files["manifest.json"] = Data(legacy.replacingOccurrences(of: "\"allocationRule\":1", with: "\"allocationRule\":2").utf8)
        #expect(throws: (any Error).self) { try LibraryBackup.decode(files: files) }
    }

    @Test func rejectsTraversalVersionsAndCurrency() throws {
        let backup = try LibraryBackup(library: ReceiptLibrary(drafts: [ReceiptDraft()]))
        var files = try backup.files()
        files["../outside.jpg"] = Data([1])
        #expect(throws: (any Error).self) { try LibraryBackup.decode(files: files) }
        files = try backup.files()
        files["manifest.json"] = Data("{\"formatVersion\":99,\"algorithm\":{\"schema\":1,\"allocationRule\":1},\"imageReceiptIDs\":[]}".utf8)
        #expect(throws: (any Error).self) { try LibraryBackup.decode(files: files) }
        files = try backup.files()
        files["receipts.json"] = Data(String(decoding: files["receipts.json"]!, as: UTF8.self).replacingOccurrences(of: "USD", with: "JPY").utf8)
        #expect(throws: (any Error).self) { try LibraryBackup.decode(files: files) }
    }

    @Test func rejectsDuplicateIDsOrphansAndExtremeAmountsWithoutTrap() throws {
        let draft = ReceiptDraft()
        #expect(throws: (any Error).self) { try ReceiptLibrary(drafts: [draft, draft]).validate() }
        var orphan = draft
        orphan.lineAllocations[UUID()] = RowAllocation(shares: [])
        #expect(throws: (any Error).self) { try ReceiptLibrary(drafts: [orphan]).validate() }
        var extreme = draft
        extreme.expectedTotal = MinorAmount(minorUnits: .min)
        #expect(throws: (any Error).self) { try ReceiptLibrary(drafts: [extreme]).validate() }
        var duplicate = (try reviewedReceipt()).correctionDraft()
        duplicate.lines.append(duplicate.lines[0])
        #expect(throws: (any Error).self) { try ReceiptLibrary(drafts: [duplicate]).validate() }
    }

    @Test func tamperedFinalizedShareIsRejected() throws {
        let snapshot = try reviewedReceipt()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReceiptLibrary(snapshots: [snapshot]))) as! [String: Any]
        var snapshots = object["snapshots"] as! [[String: Any]]
        var shares = snapshots[0]["personShares"] as! [[String: Any]]
        shares[0]["totalMinorUnits"] = 999
        snapshots[0]["personShares"] = shares; object["snapshots"] = snapshots
        let damaged = try JSONDecoder().decode(ReceiptLibrary.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: (any Error).self) { try damaged.validate() }
    }

    @Test func writingBackupNeverOverwritesExistingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let sentinel = existing.appendingPathComponent("receipts.json")
        try Data("original receipt".utf8).write(to: sentinel)
        let backup = try LibraryBackup(library: ReceiptLibrary(drafts: [ReceiptDraft()]))
        #expect(throws: (any Error).self) { try backup.write(to: existing) }
        #expect(try Data(contentsOf: sentinel) == Data("original receipt".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["receipts.json"])

        let newFolder = root.appendingPathComponent("new")
        try backup.write(to: newFolder)
        let folderMode = try #require(FileManager.default.attributesOfItem(atPath: newFolder.path)[.posixPermissions] as? NSNumber)
        let fileMode = try #require(FileManager.default.attributesOfItem(atPath: newFolder.appendingPathComponent("receipts.json").path)[.posixPermissions] as? NSNumber)
        #expect(folderMode.intValue & 0o077 == 0)
        #expect(fileMode.intValue & 0o077 == 0)
        #expect(try LibraryBackup.read(from: newFolder).library.drafts == backup.library.drafts)
        #expect(throws: (any Error).self) { try backup.write(to: newFolder) }
        #expect(try LibraryBackup.read(from: newFolder).library.drafts == backup.library.drafts)
    }

    @Test func rejectsSymlinksAndOversizedFilesBeforeLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try LibraryBackup(library: ReceiptLibrary()).write(to: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("receipts.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("receipts.json"), withDestinationURL: root.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try LibraryBackup.read(from: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("receipts.json"))
        FileManager.default.createFile(atPath: root.appendingPathComponent("receipts.json").path, contents: nil)
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("receipts.json"))
        try handle.truncate(atOffset: UInt64(LibraryBackup.maximumJSONBytes + 1)); try handle.close()
        #expect(throws: (any Error).self) { try LibraryBackup.read(from: root) }
    }

    @Test func rejectsFIFOWithoutWaitingForWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try LibraryBackup(library: ReceiptLibrary()).write(to: root)
        let path = root.appendingPathComponent("trap.jpg").path
        #expect(mkfifo(path, 0o600) == 0)
        #expect(throws: (any Error).self) { try LibraryBackup.read(from: root) }
    }

    @Test func rejectsHardLinksBeforeBackupRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try LibraryBackup(library: ReceiptLibrary()).write(to: root)
        let receipts = root.appendingPathComponent("receipts.json")
        let other = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.linkItem(at: receipts, to: other)
        #expect(throws: (any Error).self) { try LibraryBackup.read(from: root) }
    }

    @MainActor @Test func restoreDeleteAndPreRestoreCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryReceiptStore(), draft = ReceiptDraft()
        try store.saveDraft(draft)
        let images = try LocalReferenceImageStore(rootDirectory: root.appendingPathComponent("images"))
        let transfer = LibraryTransfer(store: store, images: images, continuity: InMemoryContinuityStore(), recoveryRoot: root.appendingPathComponent("recovery"))
        let snapshot = try reviewedReceipt()
        try transfer.restore(LibraryBackup(library: ReceiptLibrary(snapshots: [snapshot])))
        #expect(try store.loadAllDrafts().isEmpty)
        #expect(try store.loadAllSnapshots() == [snapshot])
        let previous = try transfer.previousBackups()
        #expect(previous.count == 1)
        let rootMode = try #require(FileManager.default.attributesOfItem(atPath: transfer.recoveryRoot.path)[.posixPermissions] as? NSNumber)
        #expect(rootMode.intValue & 0o077 == 0)
        #expect(try LibraryBackup.read(from: previous[0]).library.drafts == [draft])
        #expect(!FileManager.default.fileExists(atPath: transfer.recoveryRoot.appendingPathComponent("pending.json").path))
        try transfer.delete(receiptID: snapshot.id)
        #expect(try store.loadAllSnapshots().isEmpty)
        #expect(try transfer.previousBackups().isEmpty)
    }

    @MainActor @Test func restoreRejectsLinkedRecoveryRootWithoutWritingOutsideSandbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("original.txt")
        try Data("keep".utf8).write(to: sentinel)
        let recovery = root.appendingPathComponent("recovery")
        try FileManager.default.createSymbolicLink(at: recovery, withDestinationURL: destination)
        let store = InMemoryReceiptStore(), draft = ReceiptDraft()
        try store.saveDraft(draft)
        let images = try LocalReferenceImageStore(rootDirectory: root.appendingPathComponent("images"))
        let transfer = LibraryTransfer(store: store, images: images, continuity: InMemoryContinuityStore(), recoveryRoot: recovery)
        let backup = try LibraryBackup(library: ReceiptLibrary())
        #expect(throws: (any Error).self) { try transfer.restore(backup) }
        #expect(try store.loadAllDrafts() == [draft])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["original.txt"])
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }

    @MainActor @Test func deleteAllAlsoRemovesDamagedOrphanPhotos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryReceiptStore(), orphan = UUID()
        let images = try LocalReferenceImageStore(rootDirectory: root.appendingPathComponent("images"))
        try images.setReferenceImage(Data("damaged old image".utf8), receiptID: orphan)
        let continuity = InMemoryContinuityStore()
        continuity.saveSelection(WorkspaceSelection(referenceZoom: 2), receiptID: orphan)
        let transfer = LibraryTransfer(store: store, images: images, continuity: continuity, recoveryRoot: root.appendingPathComponent("recovery"))
        try transfer.deleteAll()
        #expect(try images.referenceImageURL(receiptID: orphan) == nil)
        #expect(continuity.loadSelection(receiptID: orphan) == nil)
    }

    @MainActor @Test func interruptedRestoreRollsBackBeforeReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryReceiptStore(), draft = ReceiptDraft()
        let recovery = root.appendingPathComponent("recovery"), backupID = UUID()
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try LibraryBackup(library: ReceiptLibrary(drafts: [draft])).write(to: recovery.appendingPathComponent(backupID.uuidString))
        let pending: [String: Any] = ["backupID": backupID.uuidString, "affectedIDs": [draft.id.uuidString], "keepBackup": true]
        try JSONSerialization.data(withJSONObject: pending).write(to: recovery.appendingPathComponent("pending.json"))
        // Empty replacement models a process dying after the database commit.
        let images = try LocalReferenceImageStore(rootDirectory: root.appendingPathComponent("images"))
        let transfer = LibraryTransfer(store: store, images: images, continuity: InMemoryContinuityStore(), recoveryRoot: recovery)
        #expect(throws: (any Error).self) { try transfer.backup() }
        try transfer.recoverIfNeeded()
        #expect(try store.loadAllDrafts() == [draft])
        #expect(!FileManager.default.fileExists(atPath: recovery.appendingPathComponent("pending.json").path))
    }

    @MainActor @Test func recoveryRejectsLinkedOrOversizedPendingMarkerWithoutChangingStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryReceiptStore(), draft = ReceiptDraft()
        try store.saveDraft(draft)
        let recovery = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let marker = recovery.appendingPathComponent("pending.json")
        let outside = root.appendingPathComponent("outside.json")
        try Data("not a pending operation".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)
        let images = try LocalReferenceImageStore(rootDirectory: root.appendingPathComponent("images"))
        let transfer = LibraryTransfer(store: store, images: images, continuity: InMemoryContinuityStore(), recoveryRoot: recovery)
        #expect(throws: LibraryError.self) { try transfer.recoverIfNeeded() }
        #expect(throws: LibraryError.self) { try transfer.backup() }
        #expect(try store.loadAllDrafts() == [draft])
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: root.appendingPathComponent("missing"))
        #expect(throws: LibraryError.self) { try transfer.recoverIfNeeded() }
        #expect(throws: LibraryError.self) { try transfer.backup() }
        try FileManager.default.removeItem(at: marker)
        try Data(repeating: 32, count: LibraryBackup.maximumJSONBytes + 1).write(to: marker)
        #expect(throws: LibraryError.self) { try transfer.recoverIfNeeded() }
        #expect(try store.loadAllDrafts() == [draft])
    }

    @MainActor @Test func failedRestoreRecoversOriginalLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FailingLibraryStore(), draft = ReceiptDraft()
        try store.saveDraft(draft)
        let images = try LocalReferenceImageStore(rootDirectory: root.appendingPathComponent("images"))
        let transfer = LibraryTransfer(store: store, images: images, continuity: InMemoryContinuityStore(), recoveryRoot: root.appendingPathComponent("recovery"))
        store.failNextReplacement = true
        #expect(throws: (any Error).self) { try transfer.restore(LibraryBackup(library: ReceiptLibrary())) }
        #expect(try store.loadAllDrafts() == [draft])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("recovery/pending.json").path))
    }
}

private final class FailingLibraryStore: ReceiptLibraryStore, @unchecked Sendable {
    let base = InMemoryReceiptStore()
    var failNextReplacement = false
    func saveDraft(_ draft: ReceiptDraft) throws { try base.saveDraft(draft) }
    func loadDraft(id: UUID) throws -> ReceiptDraft { try base.loadDraft(id: id) }
    func loadAllDrafts() throws -> [ReceiptDraft] { try base.loadAllDrafts() }
    func deleteDraft(id: UUID) throws { try base.deleteDraft(id: id) }
    func storeSnapshot(_ snapshot: FinalizedReceiptSnapshot) throws { try base.storeSnapshot(snapshot) }
    func loadSnapshot(id: UUID) throws -> FinalizedReceiptSnapshot { try base.loadSnapshot(id: id) }
    func loadAllSnapshots() throws -> [FinalizedReceiptSnapshot] { try base.loadAllSnapshots() }
    func replaceLibrary(_ library: ReceiptLibrary) throws {
        if failNextReplacement { failNextReplacement = false; throw LibraryError.invalid("Injected failure") }
        try base.replaceLibrary(library)
    }
}

#if canImport(ImageIO)
import ImageIO
import CoreGraphics

package func makeImportableJPEG() throws -> Data {
        let pixels = Data(repeating: 128, count: 8 * 8 * 4)
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalid("Test image encoding failed") }
        return data as Data
}

@Suite("Backup with real reference photos")
struct PhotoBackupTests {
    @MainActor @Test func photoRoundTripAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryReceiptStore(), draft = ReceiptDraft()
        try store.saveDraft(draft)
        let images = try LocalReferenceImageStore(rootDirectory: root.appendingPathComponent("images"))
        try images.setReferenceImage(try makeImportableJPEG(), receiptID: draft.id)
        let transfer = LibraryTransfer(store: store, images: images, continuity: InMemoryContinuityStore(), recoveryRoot: root.appendingPathComponent("recovery"))
        let backup = try transfer.backup()
        let imported = try LibraryBackup.decode(files: backup.files())
        #expect(imported.images[draft.id] != nil)
        try transfer.deleteAll()
        #expect(try store.loadAllDrafts().isEmpty)
        #expect(try images.referenceImageURL(receiptID: draft.id) == nil)
        #expect(try transfer.previousBackups().isEmpty)
    }
}
#endif
