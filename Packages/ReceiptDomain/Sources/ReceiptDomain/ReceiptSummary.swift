import Foundation

/// Reviewed exports deliberately contain no UUIDs, source photos, or payment links.
public enum ReceiptSummary {
    public enum Format: String, CaseIterable, Sendable { case text = "Text", csv = "CSV" }

    public static func render(_ snapshot: FinalizedReceiptSnapshot, personID: UUID? = nil,
                              format: Format = .text) -> String {
        let people = snapshot.personShares.filter { personID == nil || $0.participant.id == personID }
        let currency = snapshot.currency.rawValue
        let rows = snapshot.lines.map { ($0.id, $0.label) } + snapshot.adjustments.map { ($0.id, $0.label) }
        switch format {
        case .text:
            var output = ["Split Slip · Reviewed split", "Currency: \(currency)", ""]
            for person in people {
                output.append("\(textLabel(person.participant.displayName)): \(amount(person.totalMinorUnits)) \(currency)")
                for (id, label) in rows {
                    if let share = person.rowShares[id] { output.append("  \(textLabel(label)): \(amount(share))") }
                }
                output.append("")
            }
            let total = people.reduce(Int64(0)) { $0 + $1.totalMinorUnits }
            output.append("\(personID == nil ? "Receipt total" : "Selected person total"): \(amount(total)) \(currency)")
            output.append(snapshot.receiptSplit == nil
                ? "Includes allocated fees, discounts, and rounding cents. Please review before settling up."
                : "Whole-receipt split: fixed amounts first, then equal shares of the remainder. Includes fees, discounts, and rounding cents.")
            return output.joined(separator: "\n")
        case .csv:
            var output = [["Person", "Item", "Amount", "Currency"].map(cell).joined(separator: ",")]
            for person in people {
                for (id, label) in rows {
                    if let share = person.rowShares[id] {
                        output.append([cell(person.participant.displayName), cell(label), amount(share), cell(currency)].joined(separator: ","))
                    }
                }
                output.append([cell(person.participant.displayName), cell("Person total"), amount(person.totalMinorUnits), cell(currency)].joined(separator: ","))
            }
            if personID == nil {
                output.append([cell(""), cell("Receipt total"), amount(snapshot.expectedTotal.minorUnits), cell(currency)].joined(separator: ","))
            }
            return output.joined(separator: "\r\n") + "\r\n"
        }
    }

    private static func amount(_ value: Int64) -> String { MinorAmount(minorUnits: value).description }

    // One physical line per user label; pasted control characters cannot spoof totals.
    private static func textLabel(_ value: String) -> String {
        value.components(separatedBy: .newlines.union(.controlCharacters))
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Quote every text cell; neutralize formulas behind whitespace, controls, or invisible format scalars.
    static func cell(_ value: String) -> String {
        let prefix = value.unicodeScalars.drop {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                || $0.properties.generalCategory == .format
        }
        let dangerous = prefix.first.map { "=+-@".unicodeScalars.contains($0) } ?? false
        let protected = dangerous || value.first == "\t" || value.first == "\r" || value.first == "\n" ? "'" + value : value
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
