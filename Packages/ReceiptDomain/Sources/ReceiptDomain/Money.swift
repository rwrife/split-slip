import Foundation

/// All ways strict money or structure validation can refuse input.
/// Every case is explicit — nothing is silently clamped, rounded or defaulted.
public enum MoneyParseError: Error, Hashable, Sendable {
    case empty
    case whitespaceOnly
    case emptyIntegerPart
    case emptyFractionPart
    case multipleSigns
    case leadingPlus
    case leadingZeros
    case decimalPointCount(Int)
    case groupingCharacterRejected
    case nonDigitCharacter(Character)
    case fractionTooLong(maximumDigits: Int)
    case overflow
    case exceedsReceiptTotalBound(minorUnitsMagnitude: Int64)
}

/// A signed amount in integer minor units (cents). The accepted magnitude is
/// bounded to `ReceiptLimits.maximumAbsoluteTotalMinorUnits`; every arithmetic
/// helper uses checked operations and refuses overflow instead of wrapping.
public struct MinorAmount: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let minorUnits: Int64

    /// Accepts any representable value so allocation outputs can be constructed
    /// directly; user-entered amounts should come through
    /// `MinorAmount(parsing:currency:)` and then `validated()`.
    public init(minorUnits: Int64) {
        self.minorUnits = minorUnits
    }

    public static let zero = MinorAmount(minorUnits: 0)

    public var isNegative: Bool { minorUnits < 0 }
    public var magnitude: Int64 { abs(minorUnits) }

    /// Strict decimal-string parse into minor units. Accepted grammar:
    /// an optional single leading `-`, an integer part of `0` or a
    /// non-zero-leading digit run, and an optional fraction of one or two
    /// digits (currency exponent 2).
    ///
    /// Rejected explicitly: whitespace anywhere, `+` signs, signs anywhere
    /// other than the front, leading zeros, grouping separators (`,` `'` `_`
    /// and non-breaking space), bare `.`/`-`, empty integer or fraction parts,
    /// three-plus-digit fractions (no silent truncation or rounding), any
    /// non-digit, UInt64/Int64 overflow, and values beyond the receipt bound.
    public init(parsing raw: String, currency: SupportedCurrency = .usd) throws {
        precondition(currency.minorUnitsExponent == 2, "MVP currencies all use exponent 2")
        guard !raw.isEmpty else { throw MoneyParseError.empty }
        for scalar in raw.unicodeScalars where CharacterSet.whitespacesAndNewlines.contains(scalar) {
            throw MoneyParseError.whitespaceOnly
        }
        var characters = Array(raw)

        var negative = false
        if characters.first == "-" {
            negative = true
            characters.removeFirst()
        } else if characters.first == "+" {
            throw MoneyParseError.leadingPlus
        }
        if characters.contains("-") {
            throw MoneyParseError.multipleSigns
        }
        guard !characters.isEmpty else {
            throw negative ? MoneyParseError.emptyIntegerPart : MoneyParseError.emptyFractionPart
        }

        let parts = characters.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw MoneyParseError.decimalPointCount(parts.count) }
        let integerPart = Array(parts[0])
        let fractionPart: [Character] = parts.count == 2 ? Array(parts[1]) : []
        if parts.count == 2 && integerPart.isEmpty { throw MoneyParseError.emptyIntegerPart }
        if parts.count == 2 && fractionPart.isEmpty { throw MoneyParseError.emptyFractionPart }
        if integerPart.count > 1 && integerPart[0] == "0" { throw MoneyParseError.leadingZeros }

        for character in integerPart + fractionPart {
            switch character {
            case ",", "'", "_":
                throw MoneyParseError.groupingCharacterRejected
            default:
                guard character.isASCII && character.isNumber else {
                    throw MoneyParseError.nonDigitCharacter(character)
                }
            }
        }
        guard fractionPart.count <= 2 else {
            throw MoneyParseError.fractionTooLong(maximumDigits: 2)
        }

        // Accumulate the magnitude in minor units using checked operations.
        var magnitude: UInt64 = 0
        for character in integerPart {
            let digit = UInt64(character.asciiValue! - UInt8(ascii: "0"))
            let scaled = magnitude.multipliedReportingOverflow(by: 10)
            if scaled.overflow { throw MoneyParseError.overflow }
            let summed = scaled.partialValue.addingReportingOverflow(digit)
            if summed.overflow { throw MoneyParseError.overflow }
            magnitude = summed.partialValue
        }
        let scaledMagnitude = magnitude.multipliedReportingOverflow(by: 100)
        if scaledMagnitude.overflow { throw MoneyParseError.overflow }
        magnitude = scaledMagnitude.partialValue
        for (index, character) in fractionPart.enumerated() {
            // First fraction digit is the tens place in minor units (dimes),
            // second is the ones place (pennies): ".5" -> 50, ".53" -> 53.
            let place: UInt64 = index == 0 ? 10 : 1
            let digit = UInt64(character.asciiValue! - UInt8(ascii: "0")) * place
            let summed = magnitude.addingReportingOverflow(digit)
            if summed.overflow { throw MoneyParseError.overflow }
            magnitude = summed.partialValue
        }

        guard magnitude <= UInt64(ReceiptLimits.maximumAbsoluteTotalMinorUnits) else {
            throw MoneyParseError.exceedsReceiptTotalBound(
                minorUnitsMagnitude: ReceiptLimits.maximumAbsoluteTotalMinorUnits)
        }
        self.init(minorUnits: negative ? -Int64(magnitude) : Int64(magnitude))
    }

    /// Confirms the value sits inside the published receipt-total bound.
    public func validated() throws -> MinorAmount {
        guard magnitude <= ReceiptLimits.maximumAbsoluteTotalMinorUnits else {
            throw MoneyParseError.exceedsReceiptTotalBound(minorUnitsMagnitude: magnitude)
        }
        return self
    }

    // MARK: - Checked arithmetic

    public func adding(_ other: MinorAmount) throws -> MinorAmount {
        let result = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw MoneyParseError.overflow }
        return MinorAmount(minorUnits: result.partialValue)
    }

    public func subtracting(_ other: MinorAmount) throws -> MinorAmount {
        let result = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw MoneyParseError.overflow }
        return MinorAmount(minorUnits: result.partialValue)
    }

    public func multiplied(by factor: Int64) throws -> MinorAmount {
        let result = minorUnits.multipliedReportingOverflow(by: factor)
        guard !result.overflow else { throw MoneyParseError.overflow }
        return MinorAmount(minorUnits: result.partialValue)
    }

    public static func sum(_ amounts: [MinorAmount]) throws -> MinorAmount {
        var total: Int64 = 0
        for amount in amounts {
            let result = total.addingReportingOverflow(amount.minorUnits)
            guard !result.overflow else { throw MoneyParseError.overflow }
            total = result.partialValue
        }
        return MinorAmount(minorUnits: total)
    }

    public static func < (lhs: MinorAmount, rhs: MinorAmount) -> Bool {
        lhs.minorUnits < rhs.minorUnits
    }

    public var description: String {
        let sign = minorUnits < 0 ? "-" : ""
        let magnitude = abs(minorUnits)
        return String(format: "%@%lld.%02lld", sign, magnitude / 100, magnitude % 100)
    }
}
