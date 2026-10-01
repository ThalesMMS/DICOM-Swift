import Foundation
import DicomData

public struct DicomCodedConcept: Equatable, Hashable, Sendable {
    public let codeValue: String
    public let codingSchemeDesignator: String
    public let codeMeaning: String?
    public let codingSchemeVersion: String?

    public init(codeValue: String, codingSchemeDesignator: String, codeMeaning: String? = nil, codingSchemeVersion: String? = nil) {
        self.codeValue = codeValue.dicomNonEmptyValue ?? codeValue
        self.codingSchemeDesignator = codingSchemeDesignator.dicomNonEmptyValue ?? codingSchemeDesignator
        self.codingSchemeVersion = codingSchemeVersion
        self.codeMeaning = codeMeaning?.dicomNonEmptyValue
    }

    package init?(dataSet: DicomDataSet) {
        guard let codeValue = dataSet.string(for: .codeValue)?.dicomNonEmptyValue,
              let codingScheme = dataSet.string(for: .codingSchemeDesignator)?.dicomNonEmptyValue else {
            return nil
        }
        self.init(
            codeValue: codeValue,
            codingSchemeDesignator: codingScheme,
            codeMeaning: dataSet.string(for: .codeMeaning),
            codingSchemeVersion: dataSet.string(for: 0x00080103)
        )
    }
}

private extension String {
    var dicomNonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}
