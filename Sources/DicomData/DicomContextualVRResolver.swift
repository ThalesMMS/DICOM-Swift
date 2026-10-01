import Foundation

/// Resolves values after their containing dataset is complete. The byte records
/// retain exact source offsets and item paths; private reservations stay parser-local.
package enum DicomContextualVRResolver {
    struct PendingValue {
        let bytes: Data
        let vr: DicomVR
        let explicitVR: Bool
        let littleEndian: Bool
        let offset: Int
    }

    // Standard US/SS entries, matched against the pinned independent dictionary.
    static let signedPixelTags: Set<Int> = [
        0x00189810, 0x00221452, 0x00280071, 0x00280104, 0x00280105, 0x00280106, 0x00280107,
        0x00280108, 0x00280109, 0x00280110, 0x00280111, 0x00280120, 0x00280121,
        0x00409211, 0x00409216, 0x00603004, 0x00603006
    ]
    static let lutDescriptorTags: Set<Int> = [
        0x00281100, 0x00281101, 0x00281102, 0x00281103, 0x00283002
    ]
    // The retired VM-4 Large Palette definitions do not establish the current
    // three-word descriptor sign rule. Their implicit interpretation is unqualified.
    static let retiredLargeDescriptorTags: Set<Int> = [0x00281111, 0x00281112, 0x00281113]
    static let waveformTags: Set<Int> = [0x54000110, 0x54000112, 0x5400100A, 0x54001010]

    package static func needsContext(_ tag: Int) -> Bool {
        signedPixelTags.contains(tag) || lutDescriptorTags.contains(tag) || waveformTags.contains(tag)
            || retiredLargeDescriptorTags.contains(tag)
    }

    /// Adapts a legacy decoder's bounded value slice to the same contextual rules.
    package static func resolveLegacyElement(_ element: DicomDataElement, bytes: Data,
                                              explicitVR: Bool, littleEndian: Bool,
                                              context: DicomPixelValueContext) -> DicomDataElement {
        guard needsContext(element.tag), !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return element }
        var state = DicomDataSetParseState(limits: .default, resolvesContext: true)
        state.contextualValues[[element.tag]] = .init(bytes: bytes, vr: element.vr,
            explicitVR: explicitVR, littleEndian: littleEndian, offset: 0)
        guard let resolved = try? resolve(.init(elements: [element]), inheritedContext: context, state: &state)[element.tag] else {
            return element
        }
        return .init(tag: element.tag, vr: resolved.vr, value: resolved.value, name: element.name)
    }

    static func resolve(_ source: DicomDataSet, path: [Int] = [], inheritedContext: DicomPixelValueContext = .init(),
                        state: inout DicomDataSetParseState) throws -> DicomDataSet {
        var result = source
        let context = DicomPixelValueContext(source, inheriting: inheritedContext)
        for element in source.elements {
            try Task.checkCancellation()
            let key = path + [element.tag]
            if case .sequence(let items) = element.value {
                var resolved: [DicomSequenceItem] = []
                for (index, item) in items.enumerated() {
                    resolved.append(.init(dataSet: try resolve(item.dataSet, path: key + [index],
                        inheritedContext: context, state: &state)))
                }
                result.set(.init(tag: element.tag, vr: element.vr, value: .sequence(resolved)))
                continue
            }
            guard let pending = state.contextualValues[key] else { continue }
            // An explicit UN or a value already rejected by validation remains opaque.
            if pending.explicitVR && pending.vr == .UN || state.mode != nil && element.vr == .UN { continue }
            if state.mode != nil, !pending.explicitVR, retiredLargeDescriptorTags.contains(element.tag) {
                try state.diagnose(.ambiguousVR, tag: element.tag, offset: pending.offset, path: key)
                result.set(.init(tag: element.tag, vr: .UN, value: .bytes(pending.bytes)))
                continue
            }
            let isVOIDescriptor = element.tag == 0x00283002 && path.dropLast().last == 0x00283010
            let isWaveform = waveformTags.contains(element.tag)
            let expected = isWaveform ? context.waveformVR(explicitVR: pending.explicitVR)
                : (isVOIDescriptor ? context.voiInputVR : context.storedValueVR)
            let allowed: [DicomVR] = isWaveform ? [.OB, .OW] : [.US, .SS]
            if state.mode != nil, pending.explicitVR, !allowed.contains(pending.vr) {
                try state.diagnose(.incompatibleVR, tag: element.tag, offset: pending.offset, path: key)
                result.set(.init(tag: element.tag, vr: .UN, value: .bytes(pending.bytes)))
                continue
            }
            let vr: DicomVR
            if pending.explicitVR {
                // The explicit descriptor of an external referenced image remains
                // authoritative when that image's context is unavailable here.
                if state.mode != nil, signedPixelTags.contains(element.tag) || isVOIDescriptor || isWaveform,
                   let expected, pending.vr != expected {
                    try state.diagnose(.incompatibleVR, tag: element.tag, offset: pending.offset, path: key)
                    result.set(.init(tag: element.tag, vr: .UN, value: .bytes(pending.bytes)))
                    continue
                }
                vr = pending.vr
            } else if let expected {
                vr = expected
            } else if state.mode == nil {
                vr = pending.vr == .SS ? .SS : .US
            } else {
                try state.diagnose(.ambiguousVR, tag: element.tag, offset: pending.offset, path: key)
                result.set(.init(tag: element.tag, vr: .UN, value: .bytes(pending.bytes)))
                continue
            }
            let value: DicomDataValue
            if vr == .SS, lutDescriptorTags.contains(element.tag), pending.bytes.count == 6 {
                let words = pending.bytes.dicomIntegerValues(as: UInt16.self, littleEndian: pending.littleEndian)
                value = .signedIntegers([Int(words[0]), Int(Int16(bitPattern: words[1])), Int(words[2])])
            } else {
                guard let decoded = DicomDataValueDecoder.binaryValue(for: vr, data: pending.bytes,
                                                                      littleEndian: pending.littleEndian) else { continue }
                value = decoded
            }
            result.set(.init(tag: element.tag, vr: vr, value: value))
        }
        return result
    }

    static func validateWrittenElement(_ element: DicomDataElement, bytes: Data,
                                       explicitVR: Bool, littleEndian: Bool,
                                       context: DicomPixelValueContext, path: [Int]) throws {
        var state = DicomDataSetParseState(limits: .default, mode: .strict, resolvesContext: true)
        state.contextualValues[path + [element.tag]] = .init(bytes: bytes, vr: element.vr,
            explicitVR: explicitVR, littleEndian: littleEndian, offset: 0)
        let resolved: DicomDataSet
        do {
            resolved = try resolve(.init(elements: [element]), path: path, inheritedContext: context, state: &state)
        } catch {
            throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr,
                reason: "Context cannot establish a compatible value representation")
        }
        guard resolved[element.tag]?.vr == element.vr || (!explicitVR && waveformTags.contains(element.tag)) else {
            throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr,
                reason: "Implicit encoding would change the contextual value representation")
        }
    }
}
