import Foundation

enum DicomAttributeConstraintValidator {
    static func validate(_ constraint: DicomAttributeRule.Constraint, element: DicomDataElement,
                         dataSet: DicomDataSet) -> (code: DicomValidationReport.Code, severity: DicomValidationReport.Severity)? {
        if case .exactlyOnePresent(let tags) = constraint {
            return tags.filter(dataSet.contains).count == 1 ? nil : (.exclusiveAttributeChoiceInvalid, .error)
        }
        if case .forbiddenWhen(let condition) = constraint {
            switch condition.evaluate(in: dataSet) {
            case .satisfied: return (.conditionalAttributeForbidden, .error)
            case .unsatisfied: return nil
            case .undetermined: return (.conditionUndetermined, .limitation)
            }
        }
        if case .requiredCondition(let condition) = constraint {
            switch condition.evaluate(in: dataSet) {
            case .satisfied: return nil
            case .unsatisfied: return (.attributeValueContradiction, .error)
            case .undetermined: return (.conditionUndetermined, .limitation)
            }
        }
        if element.vr == .UN { return (.valueUnavailable, .limitation) }
        if case .valueCount(let range) = constraint {
            return range.contains(element.vm.count) ? nil : (.invalidMultiplicity, .error)
        }
        if case .evenValueCount = constraint {
            return element.vm.count.isMultiple(of: 2) ? nil : (.invalidMultiplicity, .error)
        }
        if case .itemCount(let range) = constraint {
            guard element.vr == .SQ else { return (.sequenceExpected, .error) }
            if case .empty = element.value { return range.contains(0) ? nil : (.sequenceItemCountInvalid, .error) }
            guard case .sequence(let items) = element.value else { return (.sequenceExpected, .error) }
            return range.contains(items.count) ? nil : (.sequenceItemCountInvalid, .error)
        }
        if case .personIdentificationNames(let tag, let whenMultiple) = constraint {
            guard element.vr == .SQ else { return (.sequenceExpected, .error) }
            guard case .sequence(let items) = element.value, !items.isEmpty,
                  !whenMultiple || items.count > 1, let names = dataSet[tag] else { return nil }
            guard names.vr == .PN, case .strings(let values) = names.value,
                  !values.allSatisfy({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " ^=\\")).isEmpty }) else {
                return (.valueUnavailable, .limitation)
            }
            return items.count == values.count ? (.conditionUndetermined, .limitation) : (.attributeValueContradiction, .error)
        }
        if case .empty = element.value { return nil }
        if element.value.vm.count == 0 { return nil }
        if case .strings(let values) = element.value,
           values.allSatisfy({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty }) { return nil }
        switch constraint {
        case .strings(let allowed):
            guard case .strings(let values) = element.value else { return (.valueUnavailable, .limitation) }
            let populated = values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }.filter { !$0.isEmpty }
            return populated.allSatisfy(allowed.contains) ? nil : (.attributeValueNotAllowed, .error)
        case .forbiddenStringCombination(let combination):
            guard case .strings(let values) = element.value else { return (.valueUnavailable, .limitation) }
            let present = Set(values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) })
            return !combination.isEmpty && combination.isSubset(of: present) ? (.attributeValueContradiction, .error) : nil
        case .integerRange(let range):
            guard let values = integers(element) else { return (.valueUnavailable, .limitation) }
            return values.allSatisfy(range.contains) ? nil : (.attributeValueNotAllowed, .error)
        case .integers(let allowed):
            guard let values = integers(element) else { return (.valueUnavailable, .limitation) }
            return values.allSatisfy(allowed.contains) ? nil : (.attributeValueNotAllowed, .error)
        case .integerLessThanOrEqualAttribute(let tag):
            guard let values = integers(element), values.count == 1,
                  let other = dataSet[tag], let reference = integers(other), reference.count == 1 else {
                return (.valueUnavailable, .limitation)
            }
            return values[0] <= reference[0] ? nil : (.attributeValueContradiction, .error)
        case .integerEqualsAttribute(let tag, let offset):
            guard let values = integers(element), values.count == 1,
                  let other = dataSet[tag], let reference = integers(other), reference.count == 1 else {
                return (.valueUnavailable, .limitation)
            }
            let expected = reference[0].addingReportingOverflow(offset)
            guard !expected.overflow else { return (.attributeValueContradiction, .error) }
            return values[0] == expected.partialValue ? nil : (.attributeValueContradiction, .error)
        case .itemCount, .valueCount, .evenValueCount:
            return nil
        case .exactlyOnePresent, .forbiddenWhen, .requiredCondition, .personIdentificationNames:
            return nil
        case .unformattedText:
            guard case .strings(let values) = element.value else { return (.valueUnavailable, .limitation) }
            for value in values {
                var carriageReturn = false
                for scalar in value.unicodeScalars {
                    let code = scalar.value
                    if (code < 0x20 && code != 10 && code != 13) || (0x7F...0x9F).contains(code) ||
                        (code == 10 && !carriageReturn) || (carriageReturn && code != 10) {
                        return (.attributeValueNotAllowed, .error)
                    }
                    carriageReturn = code == 13
                }
                if carriageReturn { return (.attributeValueNotAllowed, .error) }
            }
            return nil
        case .dicomTemplateIdentifier:
            guard let resource = dataSet[0x00080105], resource.vr == .CS, case .strings(let names) = resource.value,
                  names.count == 1, names[0].utf8.count <= 16 else { return (.valueUnavailable, .limitation) }
            let name = names[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            guard !name.isEmpty else { return (.valueUnavailable, .limitation) }
            if name != "DCMR" { return nil } // Private mapping resources define their own identifiers.
            guard case .strings(let values) = element.value, values.count == 1 else { return (.valueUnavailable, .limitation) }
            let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            return value.utf8.first.map { (49...57).contains($0) } == true && value.utf8.allSatisfy { (48...57).contains($0) } ?
                nil : (.attributeValueNotAllowed, .error)
        case .spatialCoordinateValues(let kind):
            return DicomSpatialCoordinateValueValidator.validate(element, dataSet: dataSet, kind: kind)
        case .temporalCoordinateValues:
            return DicomTemporalCoordinateValueValidator.validate(element, dataSet: dataSet)
        case .codeValueEncoding(let encoding):
            return DicomCodeValueEncodingValidator.validate(element, encoding: encoding)
        }
    }

    private static func integers(_ element: DicomDataElement) -> [Int]? {
        guard [.US, .SS, .UL, .SL, .UV, .SV, .IS].contains(element.vr) else { return nil }
        let values = element.intValues
        return values.count == element.vm.count ? values : nil
    }
}
