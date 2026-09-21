import Foundation
import ReceiptDomain
import ReceiptStore
import SwiftUI

@main
struct SplitSlipApp: App {
    private let storeResult: Result<AnyReceiptStore, Error>

    init() {
        // A broken store must show an explicit error — never a blank app that
        // silently wipes data (PLAN: empty/malformed stores show errors).
        do {
            try Self.prepareStoreDirectory()
            storeResult = .success(try SwiftDataReceiptStore(url: Self.storeURL))
        } catch {
            storeResult = .failure(error)
        }
    }

    /// UI-test launch argument `-reset-store` deletes the on-disk store at
    /// launch so journeys start deterministic. Never passed in normal use.
    private static func prepareStoreDirectory() throws {
        if CommandLine.arguments.contains("-reset-store") {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    private static var storeDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("SplitSlip", isDirectory: true)
    }

    private static var storeURL: URL {
        storeDirectory.appendingPathComponent("receipts.store")
    }

    var body: some Scene {
        WindowGroup {
            switch storeResult {
            case let .success(store):
                SplitSlipRootView(store: store)
            case let .failure(error):
                StoreUnavailableView(error: error)
            }
        }
    }
}
