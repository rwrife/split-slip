import Foundation
import ReceiptDomain
import ReceiptStore
import SplitSlipCore
import SwiftUI
import UIKit

@main
struct SplitSlipApp: App {
    private let storeResult: Result<AppEnvironment, Error>

    init() {
        // A broken store must show an explicit error — never a blank app that
        // silently wipes data (PLAN: empty/malformed stores show errors).
        do {
            try BackupExport.cleanupAbandoned()
            try Self.prepareStoreDirectory()
            let environment = try AppEnvironment(storeURL: Self.storeURL,
                                                 imagesRoot: Self.imagesDirectory,
                                                 continuityURL: Self.continuityURL)
            Self.seedWorkspaceIfRequested(store: environment.store,
                                          images: environment.images,
                                          continuity: environment.continuity)
            storeResult = .success(environment)
        } catch {
            storeResult = .failure(error)
        }
    }

    /// UI-test launch arguments (never passed in normal use):
    /// - `-reset-store` deletes the on-disk store AND the issue #4
    ///   reference-image/continuity files at launch so journeys start
    ///   deterministic.
    /// - `-seed-workspace <uuid>` seeds one draft with a participant and a
    ///   line, plus a reference image and a non-default workspace selection
    ///   under that fixed id, so UI tests can exercise reference import
    ///   display and continuity restoration deterministically.
    private static func prepareStoreDirectory() throws {
        if CommandLine.arguments.contains("-reset-store") {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    static func seedWorkspaceIfRequested(store: AnyReceiptStore,
                                         images: any ReferenceImageStore,
                                         continuity: any ContinuityStore) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-seed-workspace"),
              index + 1 < arguments.count,
              let receiptID = UUID(uuidString: arguments[index + 1]) else { return }

        var draft = ReceiptDraft(id: receiptID)
        draft.participants = [ParticipantIdentity(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!,
                                                  displayName: "Ana")]
        draft.lines = [ReceiptLine(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000B1")!,
                                   label: "Food", amount: MinorAmount(minorUnits: 500))]
        try? store.saveDraft(draft)

        // Small solid-red JPEG rendered in-process: decodable by UIKit, no
        // binary fixture committed to the repository. Seeding is additive:
        // a relaunch WITHOUT -reset-store must not clobber state the test
        // itself changed (that would fake the continuity proof).
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let jpeg = renderer.jpegData(withCompressionQuality: 0.6) { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        if (try? images.referenceImageURL(receiptID: receiptID)) == nil {
            try? images.setReferenceImage(jpeg, receiptID: receiptID)
        }
        if continuity.loadSelection(receiptID: receiptID) == nil {
            continuity.saveSelection(WorkspaceSelection(tab: .receipt, referenceZoom: 2.0),
                                     receiptID: receiptID)
        }
    }

    private static var storeDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("SplitSlip", isDirectory: true)
    }

    private static var storeURL: URL {
        storeDirectory.appendingPathComponent("receipts.store")
    }

    static var imagesDirectory: URL {
        storeDirectory.appendingPathComponent("references", isDirectory: true)
    }

    static var continuityURL: URL {
        storeDirectory.appendingPathComponent("continuity.json")
    }

    var body: some Scene {
        WindowGroup {
            switch storeResult {
            case let .success(environment):
                SplitSlipRootView(store: environment.store,
                                  images: environment.images,
                                  continuity: environment.continuity,
                                  transfer: environment.transfer)
                    #if targetEnvironment(simulator)
                    .preferredColorScheme(CommandLine.arguments.contains("-ui-testing-dark") ? .dark : nil)
                    #endif
            case let .failure(error):
                StoreUnavailableView(error: error)
            }
        }
    }
}

/// Bundle of the sandbox-backed stores the app injects into views. Keeping
/// them behind one type means view code never constructs its own storage.
@MainActor
struct AppEnvironment {
    let store: AnyReceiptStore
    let images: any ReferenceImageStore
    let continuity: any ContinuityStore
    let transfer: LibraryTransfer

    init(storeURL: URL, imagesRoot: URL, continuityURL: URL) throws {
        #if canImport(SwiftData)
        self.store = try SwiftDataReceiptStore(url: storeURL)
        #else
        self.store = InMemoryReceiptStore()
        #endif
        self.images = try LocalReferenceImageStore(rootDirectory: imagesRoot)
        self.continuity = FileContinuityStore(url: continuityURL)
        self.transfer = LibraryTransfer(store: store, images: images, continuity: continuity,
            recoveryRoot: storeURL.deletingLastPathComponent().appendingPathComponent("recovery", isDirectory: true))
        try transfer.recoverIfNeeded()
    }
}
