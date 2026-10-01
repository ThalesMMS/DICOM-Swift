import Foundation

/// Identity of every SOP Instance reference of an object against supplied targets: each item that
/// carries a Referenced SOP Instance UID is looked up, the referenced SOP Class must match the target
/// and referenced frame numbers must lie within the target's frames. Unsupplied targets stay limitations: one per
/// reference missing from the supplied targets, or one for the whole object (empty path) when none was supplied.
enum DicomReferenceTargetWalk {
    static func validate(_ dataSet: DicomDataSet, targets: [String: DicomDataSet], state: inout DicomEnhancedImageModules.State) {
        let trimmed = DicomEnhancedImageTableRules.Context.trimmed
        state.report = state.report.merging(.init(evaluatedLayers: [.references]))
        var unsuppliedRecorded = false
        func walk(_ item: DicomDataSet, path: [DicomValidationReport.PathComponent], depth: Int) {
            guard depth < 12, !state.stopped else { return }
            if let instance = trimmed(item[0x00081155], 0) {
                if let target = targets[instance] {
                    if let declared = trimmed(item[0x00081150], 0), let actual = trimmed(target[0x00080016], 0), declared != actual {
                        state.merge([.init(code: .referenceIdentityContradiction, severity: .error, layer: .references, path: path + [.tag(0x00081150)])])
                    }
                    if let frames = item[0x00081160], case .strings(let values) = frames.value {
                        let count = target[0x00280008].flatMap { $0.intValue } ?? 1
                        let numbers = values.compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: " "))) }
                        if numbers.contains(where: { $0 < 1 || $0 > count }) {
                            state.merge([.init(code: .referenceSelectionOutOfRange, severity: .error, layer: .references, path: path + [.tag(0x00081160)])])
                        }
                    }
                } else if !targets.isEmpty {
                    state.merge([.init(code: .referenceTargetUnavailable, severity: .limitation, layer: .references, path: path + [.tag(0x00081155)])])
                } else if !unsuppliedRecorded {
                    state.merge([.init(code: .referenceTargetUnavailable, severity: .limitation, layer: .references)])
                    unsuppliedRecorded = true
                }
            }
            for element in item.elements where element.vr == .SQ {
                for (index, child) in element.sequenceItems.enumerated() {
                    walk(child.dataSet, path: path + [.tag(element.tag), .item(index)], depth: depth + 1)
                }
            }
        }
        walk(dataSet, path: [], depth: 0)
    }
}
