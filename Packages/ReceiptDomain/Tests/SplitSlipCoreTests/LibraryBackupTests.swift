import Foundation
import Testing
@testable import ReceiptDomain
@testable import SplitSlipCore

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

    @Test(arguments: ["=SUM(A1:A2)", "+123", "-1+2", "@SUM(A1)", "  =CMD()", "\tFormula", "\r=cmd", "\n+1"])
    func formulaTextIsNeutralized(_ input: String) {
        #expect(ReceiptSummary.cell(input).hasPrefix("\"'"))
    }

    @Test func csvQuotesCommasNewlinesAndQuotes() throws {
        let csv = ReceiptSummary.render(try reviewedReceipt(name: "=HYPERLINK(\"x\")"), format: .csv)
        #expect(csv.contains("\"'=HYPERLINK(\"\"x\"\")\""))
        #expect(csv.contains("\"Soup, \"\"shared\"\"\nwith bread\""))
        #expect(csv.contains(",5.01,\"USD\""))
        #expect(csv.hasSuffix("\r\n"))
    }

    @Test func roundTripIncludesEmptyDraftAndFinalSnapshot() throws {
        let draft = ReceiptDraft(), snapshot = try reviewedReceipt()
        let backup = try LibraryBackup(library: ReceiptLibrary(drafts: [draft], snapshots: [snapshot]))
        let loaded = try LibraryBackup.decode(files: backup.files())
        #expect(loaded.library.drafts == [draft])
        #expect(loaded.library.snapshots == [snapshot])
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
        #expect(try LibraryBackup.read(from: previous[0]).library.drafts == [draft])
        try transfer.delete(receiptID: snapshot.id)
        #expect(try store.loadAllSnapshots().isEmpty)
        #expect(try transfer.previousBackups().isEmpty)
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
