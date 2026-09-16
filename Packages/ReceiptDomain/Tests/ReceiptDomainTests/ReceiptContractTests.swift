import Foundation
import Testing
@testable import ReceiptDomain

@Suite("Issue 1 domain contract")
struct ReceiptContractTests {
    @Test("Published MVP bounds remain coherent")
    func limitsAreCoherent() {
        #expect(ReceiptLimits.maximumLinesPerReceipt == 200)
        #expect(ReceiptLimits.maximumAdjustmentsPerReceipt == 50)
        #expect(ReceiptLimits.maximumParticipantsPerReceipt == 30)
        #expect(ReceiptLimits.maximumAbsoluteTotalMinorUnits == 100_000_000)
        #expect(ReceiptLimits.minimumShareWeight == 1)
        #expect(ReceiptLimits.maximumShareWeight == 1_000)
        #expect(ReceiptLimits.minimumShareWeight < ReceiptLimits.maximumShareWeight)
    }

    @Test("Every MVP currency uses exactly two decimal places")
    func currenciesAreTwoDecimalOnly() {
        #expect(Set(SupportedCurrency.allCases.map(\.rawValue)) == ["USD", "EUR", "GBP"])
        for currency in SupportedCurrency.allCases {
            #expect(currency.minorUnitsExponent == 2)
        }
    }

    @Test("Duplicate display names do not collapse identity")
    func duplicateNamesRetainDistinctIdentity() {
        let first = ParticipantIdentity(id: UUID(), displayName: "Friend")
        let second = ParticipantIdentity(id: UUID(), displayName: "Friend")

        #expect(first.displayName == second.displayName)
        #expect(first.id != second.id)
        #expect(first != second)
    }

    @Test("Editing a display name does not change identity")
    func editableNameIsNotIdentity() {
        let id = UUID()
        let before = ParticipantIdentity(id: id, displayName: "Before")
        let after = ParticipantIdentity(id: id, displayName: "After")

        #expect(before == after)
        #expect(before.hashValue == after.hashValue)
    }

    @Test("The allocation vocabulary has exactly the planned two bases")
    func allocationVocabularyIsBounded() {
        #expect(Set(AllocationBasis.allCases) == [.equal, .weighted])
    }
}
