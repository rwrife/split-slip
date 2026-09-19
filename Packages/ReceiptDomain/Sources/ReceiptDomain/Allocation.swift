import Foundation

/// Every reason allocation can refuse to run. Allocation never guesses:
/// no recipients, unknown people, zero weights or out-of-bound weights all
/// produce an explicit error rather than a silent default.
public enum AllocationError: Error, Hashable, Sendable {
    case noRecipients
    case unknownRecipient(ParticipantIdentity)
    case weightOutOfRange(participant: ParticipantIdentity, weight: Int)
    case sumWeightOutOfRange(totalWeight: Int)
    case amountOutOfBounds(minorUnitsMagnitude: Int64)
    case productOverflow(amount: MinorAmount, weight: Int)
    case residualLargerThanRecipients
}

/// One visible share produced by an allocation: who gets how many minor
/// units and how large their fractional remainder was before rounding.
/// `remainder` is in range `0 ..< sum(weights)` and makes the extra-cent
/// decision inspectable beside its reason.
public struct AllocatedShare: Hashable, Sendable, Codable {
    public let participant: ParticipantIdentity
    public let weight: Int
    public let minorUnits: Int64
    public let remainder: Int

    public init(participant: ParticipantIdentity, weight: Int, minorUnits: Int64, remainder: Int) {
        self.participant = participant
        self.weight = weight
        self.minorUnits = minorUnits
        self.remainder = remainder
    }
}

/// Largest-remainder allocation over positive integer weights.
///
/// For an amount A (any sign) and recipients R1..Rn with weights W1..Wn
/// (each 1...1000, sum bounded to Int32 range):
///   base_i        = (|A| * Wi) / sum(W)          (integer floor)
///   remainder_i   = (|A| * Wi) mod sum(W)
///   residual      = |A| - sum(base)              (always 0 ..< n)
/// Residual cents go one each to the largest remainders; ties are broken by
/// the recipient order supplied here, which callers keep in the draft's
/// stable participant order so results repeat across restarts and visible
/// reordering changes tie priority deterministically.
/// Finally each share is negated when A was negative — sign-symmetric:
/// splitting -3¢ three ways yields -1¢/-1¢/-1¢ exactly as +3¢ yields 1/1/1.
public enum AllocationEngine {
    public static func allocate(
        amount: MinorAmount,
        to recipients: [(participant: ParticipantIdentity, weight: Int)]
    ) throws -> [AllocatedShare] {
        guard !recipients.isEmpty else { throw AllocationError.noRecipients }
        guard amount.magnitude <= ReceiptLimits.maximumAbsoluteTotalMinorUnits else {
            throw AllocationError.amountOutOfBounds(minorUnitsMagnitude: amount.magnitude)
        }

        var sumWeight = 0
        for entry in recipients {
            guard (ReceiptLimits.minimumShareWeight...ReceiptLimits.maximumShareWeight).contains(entry.weight) else {
                throw AllocationError.weightOutOfRange(participant: entry.participant, weight: entry.weight)
            }
            let added = sumWeight.addingReportingOverflow(entry.weight)
            guard !added.overflow, added.partialValue <= Int(Int32.max) else {
                throw AllocationError.sumWeightOutOfRange(totalWeight: sumWeight &+ entry.weight)
            }
            sumWeight = added.partialValue
        }

        let magnitude = amount.magnitude
        var bases = [Int64]()
        bases.reserveCapacity(recipients.count)
        var remainders = [Int]()
        remainders.reserveCapacity(recipients.count)
        for entry in recipients {
            let product = magnitude.multipliedReportingOverflow(by: Int64(entry.weight))
            guard !product.overflow else {
                throw AllocationError.productOverflow(amount: amount, weight: entry.weight)
            }
            bases.append(product.partialValue / Int64(sumWeight))
            remainders.append(Int(product.partialValue % Int64(sumWeight)))
        }

        var baseSum: Int64 = 0
        for base in bases {
            let summed = baseSum.addingReportingOverflow(base)
            guard !summed.overflow else { throw AllocationError.productOverflow(amount: amount, weight: 1) }
            baseSum = summed.partialValue
        }
        let residual = magnitude - baseSum
        guard residual >= 0, residual < Int64(recipients.count) else {
            throw AllocationError.residualLargerThanRecipients
        }

        // Award residual cents: strictly-largest remainders first, ties
        // resolved by supplied (stable) order. `enumerated` + `id:` keeps the
        // sort deterministic, and Swift's sort is stable anyway.
        var extra = [Int](repeating: 0, count: recipients.count)
        if residual > 0 {
            let winners = recipients.indices.sorted { lhs, rhs in
                if remainders[lhs] != remainders[rhs] {
                    return remainders[lhs] > remainders[rhs]
                }
                return lhs < rhs
            }
            for index in winners.prefix(Int(residual)) {
                extra[index] = 1
            }
        }

        let shares = recipients.enumerated().map { index, entry in
            var units = bases[index] + Int64(extra[index])
            if amount.isNegative { units = -units }
            return AllocatedShare(
                participant: entry.participant,
                weight: entry.weight,
                minorUnits: units,
                remainder: remainders[index]
            )
        }
        return shares
    }

    /// Convenience: equal split (weight 1 each) over an ordered participant list.
    public static func allocateEqually(
        amount: MinorAmount,
        to participants: [ParticipantIdentity]
    ) throws -> [AllocatedShare] {
        try allocate(amount: amount, to: participants.map { ($0, 1) })
    }
}
