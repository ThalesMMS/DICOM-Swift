import Foundation

/// Video IOD content constraints, PS3.3 A.32.5/6/7 and C.7.6.5/6.
enum DicomVideoModules {
    static func validate(_ data: DicomDataSet, profile: DicomEnhancedImageModules.Profile,
                         conditions: DicomCompositeImageModules.Conditions,
                         state: inout DicomEnhancedImageModules.State) {
        if data.contains(0x00081164) {
            state.evaluate(DicomFunctionalGroupsModule.frameExtractionRules(), on: data, path: [])
        } else {
            state.evaluate([.init(tag: 0x00081164, requirement: .type1C,
                                  condition: .known(conditions.frameLevelRetrieveResponse))], on: data, path: [])
        }
        // Declared Specimen content is validated by the shared helper. Its absence is not proof that
        // the subject is not a specimen; an explicit external fact resolves that condition.
        if !DicomSpecimenModule.applies(to: data) {
            state.evaluate([.init(tag: 0x00400560, requirement: .type1C,
                                  condition: .known(conditions.imagingSubjectIsSpecimen))], on: data, path: [])
        }
        let modality = profile == .videoEndoscopic ? "ES" : profile == .videoMicroscopic ? "GM" : "XC"
        state.evaluate([.init(tag: 0x00080060, requirement: .type1, constraints: [.strings([modality])]),
                        .init(tag: 0x00282110, requirement: .type1, constraints: [.strings(["01"])]),
                        .init(tag: 0x00282114, requirement: .type1)], on: data, path: [])
        if data.contains(0x00280034) {
            let ratio = data.ints(for: 0x00280034)
            if ratio.count != 2 || ratio.contains(where: { $0 <= 0 }) {
                state.record(.attributeValueContradiction, path: [.tag(0x00280034)])
            }
        }
        let count = data.int(for: 0x00280008) ?? 0
        if count < 1 { state.record(.attributeValueContradiction, path: [.tag(0x00280008)]) }
        let pointers = data.ints(for: 0x00280009)
        if pointers.isEmpty || pointers.contains(where: { ![0x00181063, 0x00181065].contains($0) }) {
            state.record(.attributeValueContradiction, path: [.tag(0x00280009)])
        }
        for tag in pointers where [0x00181063, 0x00181065].contains(tag) {
            if !data.contains(tag) { state.record(.requiredAttributeMissing, path: [.tag(tag)], requirement: .type1C) }
        }
        if data.contains(0x00181065) {
            let vector = data.floats(for: 0x00181065)
            if vector.count != count || vector.first != 0 || !vector.dropFirst().allSatisfy({ $0.isFinite && $0 > 0 }) {
                state.record(.attributeValueContradiction, path: [.tag(0x00181065)])
            }
        }
        if let time = data.float(for: 0x00181063), !time.isFinite || time < 0 || (count > 1 && time == 0) {
            state.record(.attributeValueContradiction, path: [.tag(0x00181063)])
        }
        // Overlay Plane, Modality LUT, VOI LUT, and the retired Curve module are forbidden.
        for element in data.elements {
            let group = element.tag >> 16
            if (0x6000...0x601E).contains(group) || (0x5000...0x501E).contains(group) ||
                [0x00700001, 0x00283000, 0x00283010, 0x00281050, 0x00281051, 0x00281052, 0x00281053].contains(element.tag) {
                state.record(.conditionalAttributeForbidden, path: [.tag(element.tag)])
            }
        }
        for tag in [0x00082142, 0x00082143] {
            if let trim = data.int(for: tag), trim < 1 || trim > count {
                state.record(.attributeValueContradiction, path: [.tag(tag)])
            }
        }
        if let start = data.int(for: 0x00082142), let stop = data.int(for: 0x00082143), start > stop {
            state.record(.attributeValueContradiction, path: [.tag(0x00082143)])
        }
    }
}
