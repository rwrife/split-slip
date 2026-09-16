import Foundation

/// Stable product bounds shared by the app and the future domain implementation.
/// These mirror the published MVP plan; issue #2 owns enforcement logic.
public enum ReceiptLimits {
    public static let maximumLinesPerReceipt = 200
    public static let maximumAdjustmentsPerReceipt = 50
    public static let maximumParticipantsPerReceipt = 30
    public static let maximumAbsoluteTotalMinorUnits: Int64 = 100_000_000
    public static let minimumShareWeight = 1
    public static let maximumShareWeight = 1_000
}

/// The only MVP currencies, all with exactly two decimal places.
public enum SupportedCurrency: String, CaseIterable, Sendable {
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"

    public var minorUnitsExponent: Int { 2 }
}

/// Identity is deliberately separate from a participant's user-editable display name.
public struct ParticipantIdentity: Hashable, Sendable {
    public let id: UUID
    public var displayName: String

    public init(id: UUID = UUID(), displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Allocation basis vocabulary promised by the MVP plan.
public enum AllocationBasis: String, CaseIterable, Sendable {
    case equal
    case weighted
}
