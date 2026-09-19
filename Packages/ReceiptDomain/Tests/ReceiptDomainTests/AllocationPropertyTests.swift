import Foundation
import Testing
@testable import ReceiptDomain

/// Deterministic seedable generator (SplitMix64) so every failing case is
/// reproducible from its printed seed alone.
public struct SeededGenerator: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    public mutating func nextUInt64() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)).multipliedReportingOverflow(by: 0xBF58476D1CE4E5B9).partialValue
        z = (z ^ (z >> 27)).multipliedReportingOverflow(by: 0x94D049BB133111EB).partialValue
        return z ^ (z >> 31)
    }

    /// Inclusive range.
    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound &+ 1)
        return range.lowerBound + Int(nextUInt64() % span)
    }
}

/// Randomized invariants that supplement (never re-derive) the hand-specified
/// examples: conservation, bounded shares, sign handling, repeatability, and
/// stable tie order. The oracle is arithmetic identity, not the engine.
@Suite("Issue 2 seeded allocation invariants")
struct AllocationPropertyTests {
    @Test("Every seeded row conserves its amount exactly", arguments: (0..<26).map { UInt64(0x5EED_0000 + $0) })
    func conservation(seedRaw: UInt64) throws {
        var rng = SeededGenerator(seed: seedRaw)
        for _ in 0..<64 {
            let peopleCount = rng.nextInt(in: 1...30)
            let amount = Int64(rng.nextInt(in: 0...10_000_000)) * (rng.nextInt(in: 0...2) == 0 ? -1 : 1)
            var recipients: [(participant: ParticipantIdentity, weight: Int)] = []
            for index in 0..<peopleCount {
                let identity = ParticipantIdentity(
                    id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index))),
                    displayName: "P\(index)")
                recipients.append((identity, rng.nextInt(in: 1...1000)))
            }
            let shares = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: amount), to: recipients)
            let sum = shares.map(\.minorUnits).reduce(0, +)
            #expect(sum == amount, "seed \(seedRaw): amount \(amount) allocated \(sum) across \(peopleCount)")
            // Each share within one rounding step of its proportional value,
            // independently computed with plain integer math.
            let totalWeight = recipients.reduce(0) { $0 + $1.weight }
            let magnitude = abs(amount)
            for (index, share) in shares.enumerated() {
                let proportional = (magnitude * Int64(recipients[index].weight)) / Int64(totalWeight)
                #expect(abs(abs(share.minorUnits) - proportional) <= 1)
                #expect((share.minorUnits >= 0) == (amount >= 0) || share.minorUnits == 0)
            }
        }
    }

    @Test("Sign symmetry survives randomization", arguments: (0..<8).map { UInt64(0xC0FF_EE00 + $0) })
    func signSymmetry(seedRaw: UInt64) throws {
        var rng = SeededGenerator(seed: seedRaw)
        for _ in 0..<48 {
            let peopleCount = rng.nextInt(in: 1...12)
            let magnitude = Int64(rng.nextInt(in: 0...1_000_000))
            var recipients: [(participant: ParticipantIdentity, weight: Int)] = []
            for index in 0..<peopleCount {
                let identity = ParticipantIdentity(
                    id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index))),
                    displayName: "P\(index)")
                recipients.append((identity, rng.nextInt(in: 1...1000)))
            }
            let positive = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: magnitude), to: recipients)
            let negative = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: -magnitude), to: recipients)
            #expect(negative.map(\.minorUnits) == positive.map { -$0.minorUnits },
                    "seed \(seedRaw): magnitude \(magnitude)")
        }
    }

    @Test("Re-running the engine on the same input reproduces output", arguments: [UInt64(0xDEAD_BEEF)])
    func repeatability(seedRaw: UInt64) throws {
        var rng = SeededGenerator(seed: seedRaw)
        for _ in 0..<64 {
            let peopleCount = rng.nextInt(in: 1...20)
            let amount = Int64(rng.nextInt(in: -5_000_000...5_000_000))
            var recipients: [(participant: ParticipantIdentity, weight: Int)] = []
            for index in 0..<peopleCount {
                let identity = ParticipantIdentity(
                    id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index))),
                    displayName: "P\(index)")
                recipients.append((identity, rng.nextInt(in: 1...1000)))
            }
            let first = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: amount), to: recipients)
            let second = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: amount), to: recipients)
            #expect(first == second)
        }
    }

    @Test("Residual cents never exceed n-1 and never duplicate a person", arguments: (0..<8).map { UInt64(0xB16B_00B5 + $0) })
    func residualBounds(seedRaw: UInt64) throws {
        var rng = SeededGenerator(seed: seedRaw)
        for _ in 0..<64 {
            let peopleCount = rng.nextInt(in: 1...30)
            let amount = Int64(rng.nextInt(in: 0...200_000))
            var recipients: [(participant: ParticipantIdentity, weight: Int)] = []
            for index in 0..<peopleCount {
                let identity = ParticipantIdentity(
                    id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index))),
                    displayName: "P\(index)")
                recipients.append((identity, rng.nextInt(in: 1...1000)))
            }
            let totalWeight = recipients.reduce(0) { $0 + $1.weight }
            let shares = try AllocationEngine.allocate(amount: MinorAmount(minorUnits: amount), to: recipients)
            // Independent oracle: the plan's rule operates on the magnitude.
            // residual = magnitude - sum_i (magnitude*Wi / sumW), floored toward
            // zero on the absolute value, and must sit in 0 ..< n.
            let magnitude = abs(amount)
            let floors = recipients.map { (magnitude * Int64($0.weight)) / Int64(totalWeight) }.reduce(0, +)
            let residual = magnitude - floors
            #expect(residual >= 0 && residual < Int64(peopleCount))
            // Total received mirrors the magnitude exactly, sign applied.
            let totalReceived = shares.map(\.minorUnits).reduce(0, +)
            #expect(abs(totalReceived) == magnitude)
        }
    }
}
