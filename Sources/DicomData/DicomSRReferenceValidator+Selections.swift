import Foundation

extension DicomSRReferenceValidator.State {
    /// Explicit selectors only. Conditional selector presence and full target IOD/payload geometry are separate rules.
    mutating func validateSelections(_ reference: DicomSRReferenceValidator.Reference, target: DicomDataSet?) {
        let dataSet = reference.selection
        if dataSet.contains(0x00081160), let frames = selectionValues(dataSet, tag: 0x00081160, vr: .IS, path: reference.path) {
            let path = reference.path + [.tag(0x00081160)]
            if frames.contains(where: { $0 < 1 }) { record(.referenceSelectionInvalid, path: path) }
            if let target, let count = targetCount(target, tag: 0x00280008, vr: .IS, path: path) {
                for frame in frames where frame > count {
                    guard visit(path, depth: 0) else { return }
                    record(.referenceSelectionOutOfRange, path: path + [.frame(frame - 1)])
                }
            }
        }
        if dataSet.contains(0x0062000B), let segments = selectionValues(dataSet, tag: 0x0062000B, vr: .US, path: reference.path) {
            let path = reference.path + [.tag(0x0062000B)]
            if segments.contains(where: { $0 < 1 }) { record(.referenceSelectionInvalid, path: path) }
            if let target { validateSegments(segments, target: target, path: path) }
        }
        if dataSet.contains(0x0040A0B0), let channels = selectionValues(dataSet, tag: 0x0040A0B0, vr: .US, path: reference.path) {
            let path = reference.path + [.tag(0x0040A0B0)]
            guard channels.count.isMultiple(of: 2) else { record(.invalidMultiplicity, path: path); return }
            let groups = target.flatMap { selectionItems($0, tag: 0x54000100, path: path) }
            for index in stride(from: 0, to: channels.count, by: 2) {
                guard visit(path, depth: 0) else { return }
                let group = channels[index], channel = channels[index + 1]
                guard group > 0, channel >= 0 else { record(.referenceSelectionInvalid, path: path); continue }
                guard let groups else { continue }
                guard group <= groups.count else { record(.referenceSelectionOutOfRange, path: path); continue }
                let multiplex = groups[group - 1].dataSet
                guard let definitions = selectionItems(multiplex, tag: 0x003A0200, path: path),
                      let count = targetCount(multiplex, tag: 0x003A0005, vr: .US, path: path) else { continue }
                guard definitions.count == count else { record(.referenceTargetGeometryInvalid, path: path); continue }
                // Channel zero denotes all channels of this particular multiplex group (C.18.5.1.1).
                if channel > count { record(.referenceSelectionOutOfRange, path: path) }
            }
        }
    }

    private mutating func selectionValues(_ dataSet: DicomDataSet, tag: Int, vr: DicomVR,
                                          path: [DicomValidationReport.PathComponent]) -> [Int]? {
        let location = path + [.tag(tag)]
        guard let element = dataSet[tag], element.vr != .UN else {
            record(.valueUnavailable, severity: .limitation, path: location)
            return nil
        }
        guard element.vr == vr else { record(.incompatibleVR, path: location); return nil }
        var result: [Int] = []
        switch element.value {
        case .strings(let values) where vr == .IS:
            for value in values {
                guard visit(location, depth: 0) else { return nil }
                guard value.utf8.count <= 12, let number = Int(value.trimmingCharacters(in: .whitespaces)),
                      (try? DicomTextValueValidator.validate(value, vr: .IS, characterSet: .defaultCharacterSet,
                          purpose: .instance, includesPadding: false)) != nil else {
                    record(.referenceSelectionInvalid, path: location)
                    return nil
                }
                result.append(number)
            }
        case .unsignedIntegers(let values) where vr == .US:
            for value in values {
                guard visit(location, depth: 0) else { return nil }
                guard value <= UInt(UInt16.max) else { record(.referenceSelectionInvalid, path: location); return nil }
                result.append(Int(value))
            }
        case .signedIntegers(let values) where vr == .US:
            for value in values {
                guard visit(location, depth: 0) else { return nil }
                guard (0...Int(UInt16.max)).contains(value) else { record(.referenceSelectionInvalid, path: location); return nil }
                result.append(value)
            }
        case .empty: break
        default:
            record(.valueUnavailable, severity: .limitation, path: location)
            return nil
        }
        guard !result.isEmpty else { record(.referenceSelectionInvalid, path: location); return nil }
        return result
    }

    private mutating func targetCount(_ dataSet: DicomDataSet, tag: Int, vr: DicomVR,
                                     path: [DicomValidationReport.PathComponent]) -> Int? {
        guard visit(path, depth: 0) else { return nil }
        guard let element = dataSet[tag], element.vr == vr else {
            record(.valueUnavailable, severity: .limitation, path: path)
            return nil
        }
        if case .bytes = element.value {
            record(.valueUnavailable, severity: .limitation, path: path)
            return nil
        }
        guard let count = knownCount(element, vr: vr) else { record(.referenceTargetGeometryInvalid, path: path); return nil }
        return count
    }

    private mutating func selectionItems(_ dataSet: DicomDataSet, tag: Int,
                                        path: [DicomValidationReport.PathComponent]) -> [DicomSequenceItem]? {
        guard visit(path, depth: 0) else { return nil }
        guard let element = dataSet[tag], element.vr == .SQ else {
            record(.valueUnavailable, severity: .limitation, path: path)
            return nil
        }
        if case .empty = element.value { return [] }
        guard case .sequence(let items) = element.value else {
            record(.valueUnavailable, severity: .limitation, path: path)
            return nil
        }
        return items
    }

    private mutating func validateSegments(_ segments: [Int], target: DicomDataSet,
                                          path: [DicomValidationReport.PathComponent]) {
        guard let items = selectionItems(target, tag: 0x00620002, path: path) else { return }
        var known: Set<Int> = []
        var complete = true
        for item in items {
            guard let number = targetCount(item.dataSet, tag: 0x00620004, vr: .US, path: path) else {
                complete = false
                if stopped { return }
                continue
            }
            if !known.insert(number).inserted { record(.referenceTargetGeometryInvalid, path: path) }
        }
        for segment in segments where segment > 0 && !known.contains(segment) && complete {
            guard visit(path, depth: 0) else { return }
            record(.referenceSelectionOutOfRange, path: path)
        }
    }
}
