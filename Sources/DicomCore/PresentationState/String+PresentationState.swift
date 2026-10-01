import Foundation

internal extension String {
    var dicomGSPSTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomGSPSNonEmptyValue: String? {
        let trimmed = dicomGSPSTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }

    var dicomGSPSLayerName: String {
        let allowed = dicomGSPSTrimmedValue
            .uppercased()
            .map { character in
                character.isLetter || character.isNumber || character == "_" ? character : "_"
            }
        let value = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.isEmpty ? "AI" : String(value.prefix(16))
    }
}
