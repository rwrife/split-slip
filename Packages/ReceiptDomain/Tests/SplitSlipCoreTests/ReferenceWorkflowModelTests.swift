import Foundation
import Testing
@testable import SplitSlipCore
import ReceiptDomain

private func seededDraft() -> ReceiptDraft {
    var draft = ReceiptDraft()
    draft.expectedTotal = MinorAmount(minorUnits: 3000)
    draft.participants = [ParticipantIdentity(displayName: "Ana")]
    let line = ReceiptLine(label: "Appetizer", amount: MinorAmount(minorUnits: 3000))
    draft.lines = [line]
    draft.lineAllocations[line.id] = RowAllocation(shares: [
        .init(participantID: draft.participants[0].id, weight: 1)])
    return draft
}

private func makeStores() throws -> (InMemoryReceiptStore, LocalReferenceImageStore, FileContinuityStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("splitslip-model-\(UUID().uuidString)", isDirectory: true)
    let images = try LocalReferenceImageStore(rootDirectory: root)
    let continuity = FileContinuityStore(
        url: root.appendingPathComponent("continuity.json"))
    return (InMemoryReceiptStore(), images, continuity, root)
}

@Suite("Issue 4 model: reference import + continuity lifecycle")
struct ReferenceWorkflowModelTests {

    @Test("valid import stores stripped bytes; damaged import keeps the previous image")
    func importKeepsPreviousOnFailure() throws {
        let (store, images, continuity, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = seededDraft()
        let model = ReceiptWorkspaceModel(draft: draft, store: store, images: images, continuity: continuity)

        let good = makeJPEGWithMetadata(appSegments: [(0xE1, Array("Exif\0\0GPS:1,2".utf8))])
        // The synthetic fixture is not decodable by any codec, so sanitize
        // takes the pure structural strip path on every platform.
        let payload = good
        #expect(model.importReferenceImage(payload: payload))
        #expect(model.referenceImageURL != nil)
        let firstBytes = try Data(contentsOf: #require(model.referenceImageURL))
        #expect(!containsMarkerSegment(firstBytes, marker: 0xE1))

        // Corrupt payload after a good import: refusal, previous file intact.
        #expect(!model.importReferenceImage(payload: Data("not an image at all".utf8)))
        #expect(try Data(contentsOf: #require(model.referenceImageURL)) == firstBytes)
        #expect(model.fieldMessages["reference"] != nil)
    }

    @Test("cancel / nil payload is a quiet no-op")
    func nilPayloadNoOp() throws {
        let (store, images, continuity, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ReceiptWorkspaceModel(draft: seededDraft(), store: store, images: images, continuity: continuity)
        #expect(!model.importReferenceImage(payload: nil))
        #expect(model.referenceImageURL == nil)
        #expect(model.fieldMessages["reference"] == nil)
    }

    @Test("selection survives model recreation (relaunch) through the continuity store")
    func selectionSurvivesRelaunch() throws {
        let (store, images, continuity, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = seededDraft()
        try store.saveDraft(draft)
        let model = ReceiptWorkspaceModel(draft: draft, store: store, images: images, continuity: continuity)
        let lineID = draft.lines[0].id
        model.selectTab(.people)
        model.selectRow(lineID)
        model.selectParticipant(draft.participants[0].id)
        model.updateSelection {
            $0.referenceZoom = 3.5
            $0.referenceOffsetX = 12
            $0.referenceOffsetY = -4
        }

        // Simulate relaunch/rotation: a brand-new model for the same receipt.
        let reopened = ReceiptWorkspaceModel(
            draft: try store.loadDraft(id: draft.id), store: store,
            images: images,
            continuity: FileContinuityStore(url: root.appendingPathComponent("continuity.json")))
        #expect(reopened.selection.tab == .people)
        #expect(reopened.selection.selectedRowID == lineID)
        #expect(reopened.selection.selectedParticipantID == draft.participants[0].id)
        #expect(reopened.selection.referenceZoom == 3.5)
        #expect(reopened.selection.referenceOffsetX == 12)
        #expect(reopened.selection.referenceOffsetY == -4)
    }

    @Test("finalization transfers the reference image and selection to the snapshot; draft keys released")
    func finalizeTransfersOwnership() throws {
        let (store, images, continuity, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = seededDraft()
        let model = ReceiptWorkspaceModel(draft: draft, store: store, images: images, continuity: continuity)
        let payload = makeJPEGWithMetadata(appSegments: [])
        _ = model.importReferenceImage(payload: payload)
        model.selectTab(.people)

        let snapshotID = try #require(model.finalizeNow())
        #expect(try images.referenceImageURL(receiptID: snapshotID) != nil)
        #expect(try images.referenceImageURL(receiptID: draft.id) == nil)
        #expect(continuity.loadSelection(receiptID: snapshotID)?.tab == .people)
        #expect(continuity.loadSelection(receiptID: draft.id) == nil)
    }

    @Test("canceling a correction releases fork-owned keys and keeps the snapshot's")
    func cancelCorrectionReleasesForkKeys() throws {
        let (store, images, continuity, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = seededDraft()
        let model = ReceiptWorkspaceModel(draft: draft, store: store, images: images, continuity: continuity)
        _ = model.importReferenceImage(payload: makeJPEGWithMetadata(appSegments: []))
        model.selectTab(.people)
        let snapshotID = try #require(model.finalizeNow())
        let snapshot = try store.loadSnapshot(id: snapshotID)

        // Fork a correction draft; it inherits the snapshot's image+selection.
        let fork = ReceiptWorkspaceModel.correctionDraft(from: snapshot)
        try store.saveDraft(fork)
        try images.copyReference(from: snapshotID, to: fork.id)
        continuity.copySelection(from: snapshotID, to: fork.id)
        let forkModel = ReceiptWorkspaceModel(draft: fork, store: store, images: images, continuity: continuity)
        #expect(forkModel.referenceImageURL != nil)
        #expect(forkModel.selection.tab == .people)

        forkModel.cancelCorrectionIfFork()
        #expect(try images.referenceImageURL(receiptID: fork.id) == nil)
        #expect(continuity.loadSelection(receiptID: fork.id) == nil)
        // Snapshot keeps everything.
        #expect(try images.referenceImageURL(receiptID: snapshotID) != nil)
        #expect(continuity.loadSelection(receiptID: snapshotID) != nil)
        #expect(try store.loadSnapshot(id: snapshotID) == snapshot)
    }
}
