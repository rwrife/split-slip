import Foundation
import ReceiptDomain

/// Human-readable wording for every domain refusal, so the UI never invents
/// its own interpretation of an error and tests can pin the exact copy.
public enum DomainMessages {
    public static func moneyParse(_ error: MoneyParseError) -> String {
        switch error {
        case .empty:
            return "Enter an amount."
        case .whitespaceOnly:
            return "Amounts cannot contain spaces."
        case .emptyIntegerPart:
            return "Amount needs digits before the decimal point."
        case .emptyFractionPart:
            return "Amount ends with an empty fraction (write 1.50, not 1.)."
        case .multipleSigns:
            return "Amount may only have one minus sign, at the front."
        case .leadingPlus:
            return "Amounts cannot start with +."
        case .leadingZeros:
            return "Amount cannot have leading zeros (write 5.00, not 05.00)."
        case .decimalPointCount:
            return "Amount may contain at most one decimal point."
        case .groupingCharacterRejected:
            return "Amounts cannot use separators like commas (write 1000.00, not 1,000.00)."
        case let .nonDigitCharacter(character):
            return "Amount contains an unsupported character “\(character)”."
        case let .fractionTooLong(maximumDigits):
            return "Amounts support at most \(maximumDigits) decimal places."
        case .overflow:
            return "That amount is too large to compute safely."
        case let .exceedsReceiptTotalBound(minorUnitsMagnitude):
            return "Amount exceeds the \(minorUnitsMagnitude) minor-unit receipt bound."
        }
    }

    public static func receiptValidation(_ error: ReceiptValidationError) -> String {
        switch error {
        case let .tooManyLines(count):
            return "Too many lines (\(count), limit \(ReceiptLimits.maximumLinesPerReceipt))."
        case let .tooManyAdjustments(count):
            return "Too many adjustments (\(count), limit \(ReceiptLimits.maximumAdjustmentsPerReceipt))."
        case let .tooManyParticipants(count):
            return "Too many participants (\(count), limit \(ReceiptLimits.maximumParticipantsPerReceipt))."
        case let .duplicateParticipant(id):
            return "Duplicate participant (\(id))."
        case .emptyReceipt:
            return "Add at least one line or adjustment."
        case .emptyLineLabel:
            return "Every line needs a label."
        case .lineAmountNegative:
            return "Line amounts cannot be negative; use an adjustment for discounts."
        case .adjustmentAmountZero:
            return "Adjustment amounts cannot be zero."
        case let .unknownAllocationParticipant(id):
            return "An allocation references an unknown person (\(id))."
        case let .weightOutOfRange(participant: _, weight: weight):
            return "Weights must be between \(ReceiptLimits.minimumShareWeight) and \(ReceiptLimits.maximumShareWeight) (got \(weight))."
        case let .totalOutOfBounds(minorUnitsMagnitude: magnitude):
            return "Receipt total exceeds the bound (\(magnitude) minor units)."
        }
    }

    public static func reconciliation(_ problem: ReconciliationProblem) -> String {
        switch problem {
        case let .totalMismatch(difference: difference):
            return difference.minorUnits > 0
                ? "Rows are \(difference) short of the entered receipt total."
                : "Rows exceed the entered receipt total by \(MinorAmount(minorUnits: -difference.minorUnits))."
        case .unassignedRow:
            return "Some rows have no recipients yet and stay unresolved."
        case .noParticipants:
            return "Add at least one participant."
        case let .negativeParticipantTotal(participant: participant, minorUnits: minorUnits):
            return "\(participant.displayName) would owe \(MinorAmount(minorUnits: minorUnits)) — person totals must not be negative."
        case let .personTotalsDisagree(expectedTotal: expectedTotal, personSum: personSum):
            return "Person totals (\(personSum)) disagree with the receipt total (\(expectedTotal))."
        }
    }

    public static func finalization(_ error: FinalizationError) -> String {
        switch error {
        case let .invalidStructure(inner):
            return receiptValidation(inner)
        case let .reconciliation(inner):
            return reconciliation(inner)
        case let .money(inner):
            return moneyParse(inner)
        case let .allocation(inner):
            return allocation(inner)
        }
    }

    public static func allocation(_ error: AllocationError) -> String {
        switch error {
        case .noRecipients:
            return "Pick at least one person for this row."
        case .unknownRecipient:
            return "An allocation references an unknown person."
        case .weightOutOfRange:
            return "Weights must be between \(ReceiptLimits.minimumShareWeight) and \(ReceiptLimits.maximumShareWeight)."
        case .sumWeightOutOfRange:
            return "Combined weights are too large."
        case .amountOutOfBounds:
            return "Amount is outside the receipt bound."
        case .productOverflow:
            return "Amount × weight is too large to compute safely."
        case .residualLargerThanRecipients:
            return "Rounding residual exceeded the recipient count."
        }
    }

    public static func store(_ error: StoreFailure) -> String {
        switch error {
        case let .encodingFailed(detail):
            return "Could not save: encoding failed (\(detail))."
        case let .decodingFailed(detail):
            return "Stored data could not be read (\(detail))."
        case let .versionMismatch(version):
            return "Stored data uses an unsupported version (\(version))."
        case let .writeFailed(detail):
            return "Could not save: write failed (\(detail)). Previous data is unchanged."
        case let .missingDraft(id):
            return "Draft \(id) no longer exists."
        case let .missingSnapshot(id):
            return "Finalized receipt \(id) no longer exists."
        case let .duplicateIdentity(detail):
            return "Duplicate record: \(detail)."
        }
    }

    public static func referenceImage(_ error: ReferenceImageError) -> String {
        switch error {
        case .noData:
            return "That image could not be read. Nothing was changed."
        case let .tooLarge(byteCount):
            return "That image is too large (\(byteCount) bytes; limit \(ReferenceImageLimits.maximumEncodedBytes)). Nothing was changed."
        case let .storageFailed(detail):
            return "The image could not be stored (\(detail)). The previous reference is unchanged."
        case let .unsupportedFormat(format):
            return "Images of type “\(format)” cannot be safely stripped of metadata. Use a photo or JPEG/PNG screenshot."
        case .failedVerification:
            return "That image looks corrupt or malformed. Nothing was changed."
        }
    }
}
