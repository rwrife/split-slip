import Foundation
import Testing
@testable import ReceiptDomain

/// Independently specified examples from issue #2 acceptance criteria.
/// No production formula is reused as an oracle.
@Suite("Issue 2 money parsing")
struct MoneyParsingTests {
    @Test("Plain and dimes-place decimals parse exactly")
    func happyPaths() throws {
        #expect(try MinorAmount(parsing: "1.00").minorUnits == 100)
        #expect(try MinorAmount(parsing: "0.01").minorUnits == 1)
        #expect(try MinorAmount(parsing: "0.5").minorUnits == 50)
        #expect(try MinorAmount(parsing: "12.34").minorUnits == 1234)
        #expect(try MinorAmount(parsing: "-12.34").minorUnits == -1234)
        #expect(try MinorAmount(parsing: "0").minorUnits == 0)
        #expect(try MinorAmount(parsing: "0.00").minorUnits == 0)
        #expect(try MinorAmount(parsing: "1000000.00").minorUnits == ReceiptLimits.maximumAbsoluteTotalMinorUnits)
    }

    @Test("Malformed input is refused, never coerced")
    func malformed() {
        let rejected: [String] = [
            "", " ", "\u{00A0}", ".", "-", "-.", "+1.00", "1.2.3", "01.00", "00",
            "1,000.00", "1'000", "1_0", "1.234", ".5x", "1.2a", "١٢٣", "1e2",
            "1..0", "1.-2", "12.", "Inf", "NaN", "1 000",
        ]
        for raw in rejected {
            #expect(throws: (any Error).self) {
                _ = try MinorAmount(parsing: raw)
            }
        }
    }

    @Test("Grouping separators are their own rejection class")
    func groupingRejectedExplicitly() {
        #expect(throws: MoneyParseError.groupingCharacterRejected) {
            _ = try MinorAmount(parsing: "1,00.00")
        }
    }

    @Test("Extra precision is rejected, never truncated or rounded")
    func extraPrecision() {
        #expect(throws: MoneyParseError.fractionTooLong(maximumDigits: 2)) {
            _ = try MinorAmount(parsing: "0.001")
        }
    }

    @Test("Digit-run overflow and bound violations both refuse")
    func overflowAndBounds() {
        // 20 digits overflows the checked magnitude accumulator.
        #expect(throws: MoneyParseError.overflow) {
            _ = try MinorAmount(parsing: "99999999999999999999.00")
        }
        // Within Int64 range but above the published receipt bound.
        #expect(throws: MoneyParseError.exceedsReceiptTotalBound(minorUnitsMagnitude: ReceiptLimits.maximumAbsoluteTotalMinorUnits)) {
            _ = try MinorAmount(parsing: "1000000.01")
        }
    }

    @Test("Checked arithmetic refuses overflow instead of wrapping")
    func checkedArithmetic() {
        let big = MinorAmount(minorUnits: Int64.max)
        let one = MinorAmount(minorUnits: 1)
        #expect(throws: MoneyParseError.overflow) { try big.adding(one) }
        #expect(throws: MoneyParseError.overflow) { try big.multiplied(by: 2) }
        #expect(throws: MoneyParseError.overflow) { try MinorAmount.sum([big, one]) }
        let negativeBig = MinorAmount(minorUnits: Int64.min)
        #expect(throws: MoneyParseError.overflow) { try negativeBig.subtracting(one) }
    }

    @Test("validated() rejects magnitudes beyond the receipt bound")
    func validatedBound() {
        let over = MinorAmount(minorUnits: ReceiptLimits.maximumAbsoluteTotalMinorUnits + 1)
        #expect(throws: MoneyParseError.exceedsReceiptTotalBound(minorUnitsMagnitude: ReceiptLimits.maximumAbsoluteTotalMinorUnits + 1)) {
            try over.validated()
        }
        #expect((try? MinorAmount(minorUnits: -50).validated()) != nil)
    }
}

@Suite("Issue 2 allocation")
struct AllocationTests {
    /// Deterministic identities so tests repeat across runs and platforms.
    private func person(_ name: String, _ seed: UInt8) -> ParticipantIdentity {
        ParticipantIdentity(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, seed)),
            displayName: name)
    }

    @Test("1 cent split three ways: one person gets it, first in order wins the tie")
    func oneCentThreePeople() throws {
        let a = person("Ann", 1), b = person("Bob", 2), c = person("Cee", 3)
        let shares = try AllocationEngine.allocateEqually(amount: MinorAmount(minorUnits: 1), to: [a, b, c])
        #expect(shares.map(\.minorUnits) == [1, 0, 0])
        #expect(shares.map(\.remainder) == [1, 1, 1])  // tied remainders visible
        #expect(shares.map(\.minorUnits).reduce(0, +) == 1)
    }

    @Test("Reordering participants visibly changes who gets the extra cent")
    func reorderChangesTiePriority() throws {
        let a = person("Ann", 1), b = person("Bob", 2), c = person("Cee", 3)
        let first = try AllocationEngine.allocateEqually(amount: MinorAmount(minorUnits: 1), to: [a, b, c])
        let rotated = try AllocationEngine.allocateEqually(amount: MinorAmount(minorUnits: 1), to: [c, a, b])
        #expect(first[0].participant == a && first[0].minorUnits == 1)
        #expect(rotated[0].participant == c && rotated[0].minorUnits == 1)
    }

    @Test("1:2 weighted split of 10 cents is exact and proportional")
    func oneTwoWeights() throws {
        let a = person("Ann", 1), b = person("Bob", 2)
        let shares = try AllocationEngine.allocate(
            amount: MinorAmount(minorUnits: 10),
            to: [(a, 1), (b, 2)])
        // 10*1/3 = 3 r 1 ; 10*2/3 = 6 r 2 -> residual cent to the larger
        // remainder (b): 3 + 7 = 10.
        #expect(shares.map(\.minorUnits) == [3, 7])
        #expect(shares.map(\.minorUnits).reduce(0, +) == 10)
    }

    @Test("Tied remainders fall to stored order, not weight order")
    func tieUsesStoredOrder() throws {
        // 2 cents, weights 1:1:2 (sum 4): bases 0,0,1 remainders 2,2,0.
        // One residual cent; the two tied r=2 people split decision by order.
        let a = person("Ann", 1), b = person("Bob", 2), c = person("Cee", 3)
        let shares = try AllocationEngine.allocate(
            amount: MinorAmount(minorUnits: 2),
            to: [(a, 1), (b, 1), (c, 2)])
        #expect(shares.map(\.minorUnits) == [1, 0, 1])
    }

    @Test("Negative adjustments are sign-symmetric with positive ones")
    func signSymmetry() throws {
        let a = person("Ann", 1), b = person("Bob", 2), c = person("Cee", 3)
        let positive = try AllocationEngine.allocateEqually(amount: MinorAmount(minorUnits: 4), to: [a, b, c])
        let negative = try AllocationEngine.allocateEqually(amount: MinorAmount(minorUnits: -4), to: [a, b, c])
        #expect(positive.map(\.minorUnits) == [2, 1, 1])
        #expect(negative.map(\.minorUnits) == [-2, -1, -1])
        #expect(negative.map(\.minorUnits).reduce(0, +) == -4)

        let charge = try AllocationEngine.allocateEqually(amount: MinorAmount(minorUnits: 1), to: [a, b, c])
        let discount = try AllocationEngine.allocateEqually(amount: MinorAmount(minorUnits: -1), to: [a, b, c])
        #expect(discount.map(\.minorUnits) == charge.map { -$0.minorUnits })
    }

    @Test("Zero amount allocates zero everywhere and conserves")
    func zeroAmount() throws {
        let a = person("Ann", 1), b = person("Bob", 2)
        let shares = try AllocationEngine.allocate(amount: .zero, to: [(a, 7), (b, 3)])
        #expect(shares.map(\.minorUnits) == [0, 0])
    }

    @Test("Maximum bounded magnitude allocates with exact conservation")
    func maxAmount() throws {
        let people = (0..<30).map { person("P\($0)", UInt8($0 + 10)) }
        let weights = [Int](repeating: ReceiptLimits.maximumShareWeight, count: 30)
        let shares = try AllocationEngine.allocate(
            amount: MinorAmount(minorUnits: ReceiptLimits.maximumAbsoluteTotalMinorUnits),
            to: zip(people, weights).map { ($0, $1) })
        #expect(shares.map(\.minorUnits).reduce(0, +) == ReceiptLimits.maximumAbsoluteTotalMinorUnits)
        for share in shares {
            #expect(share.minorUnits >= 0)
        }
    }

    @Test("No recipients is unresolved, never an even split of nobody")
    func noRecipients() {
        #expect(throws: AllocationError.noRecipients) {
            _ = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: 100), to: [])
        }
        #expect(throws: AllocationError.noRecipients) {
            _ = try AllocationEngine.allocateEqually(amount: MinorAmount(minorUnits: 100), to: [])
        }
    }

    @Test("Weights outside 1...1000 are refused")
    func weightBounds() {
        let a = person("Ann", 1)
        #expect(throws: AllocationError.weightOutOfRange(participant: a, weight: 0)) {
            _ = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: 10), to: [(a, 0)])
        }
        #expect(throws: AllocationError.weightOutOfRange(participant: a, weight: -3)) {
            _ = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: 10), to: [(a, -3)])
        }
        #expect(throws: AllocationError.weightOutOfRange(participant: a, weight: 1001)) {
            _ = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: 10), to: [(a, 1001)])
        }
    }

    @Test("Allocation is deterministic: same input, same output")
    func repeatability() throws {
        let a = person("Ann", 1), b = person("Bob", 2), c = person("Cee", 3)
        let first = try AllocationEngine.allocate(
            amount: MinorAmount(minorUnits: -12345),
            to: [(a, 5), (b, 17), (c, 3)])
        let second = try AllocationEngine.allocate(
            amount: MinorAmount(minorUnits: -12345),
            to: [(a, 5), (b, 17), (c, 3)])
        #expect(first == second)
    }
}
