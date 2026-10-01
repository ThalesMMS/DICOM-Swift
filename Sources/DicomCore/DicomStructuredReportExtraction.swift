import Foundation

enum DicomSRExtraction {
    static func measurements(in item: DicomSRContentItem) -> [DicomSRMeasurement] {
        analyze(item, includeCADFindings: false).measurements
    }

    static func cadFindings(in item: DicomSRContentItem) -> [DicomSRCADFinding] {
        analyze(item, includeCADFindings: true).cadFindings
    }

    private static func analyze(
        _ root: DicomSRContentItem,
        includeCADFindings: Bool
    ) -> Analysis {
        var measurementAccumulators: [MeasurementAccumulator] = []
        var measurementResults: [DicomSRMeasurement?] = []
        var activeMeasurements: [Int] = []
        var regionAccumulators: [RegionAccumulator] = []
        var regionResults: [DicomSRGraphicRegion?] = []
        var activeRegions: [Int] = []
        var cadAccumulators: [CADAccumulator] = []
        var cadResults: [DicomSRCADFinding?] = []
        var activeCADFindings: [Int] = []
        // The identities of the enclosing groups; a measurement without its own takes the nearest one.
        var groupIdentities: [(id: String?, uid: String?)] = []
        var pending = [TraversalEvent.enter(root)]

        while let event = pending.popLast() {
            switch event {
            case .enter(let item):
                var measurementIndex: Int?
                if item.valueType == "NUM", let value = item.numericValue {
                    let index = measurementAccumulators.count
                    measurementIndex = index
                    measurementAccumulators.append(MeasurementAccumulator(
                        item: item,
                        value: value,
                        resultIndex: measurementResults.count,
                        groupIdentity: groupIdentities.last
                    ))
                    measurementResults.append(nil)
                    activeMeasurements.append(index)
                }

                var cadIndex: Int?
                if includeCADFindings, item.valueType == "CONTAINER", isCADFinding(item) {
                    let index = cadAccumulators.count
                    cadIndex = index
                    cadAccumulators.append(CADAccumulator(
                        item: item,
                        measurementStartIndex: measurementResults.count,
                        resultIndex: cadResults.count
                    ))
                    cadResults.append(nil)
                    activeCADFindings.append(index)
                }

                var regionIndex: Int?
                if item.valueType == "SCOORD",
                   let graphicType = item.graphicType,
                   !item.graphicData.isEmpty {
                    let index = regionAccumulators.count
                    regionIndex = index
                    regionAccumulators.append(RegionAccumulator(
                        graphicType: graphicType,
                        graphicData: item.graphicData,
                        resultIndex: regionResults.count
                    ))
                    regionResults.append(nil)
                    activeRegions.append(index)
                    for index in activeMeasurements
                    where measurementAccumulators[index].roiRegionIndex == nil {
                        measurementAccumulators[index].roiRegionIndex = regionIndex
                    }
                }

                for reference in item.referencedSOPs {
                    let identity = DicomSourceImageReferenceIdentity(reference)
                    for index in activeMeasurements
                    where measurementAccumulators[index].seenReferences.insert(identity).inserted {
                        measurementAccumulators[index].sourceImageReferences.append(reference)
                    }
                    for index in activeRegions
                    where regionAccumulators[index].seenReferences.insert(identity).inserted {
                        regionAccumulators[index].sourceImageReferences.append(reference)
                    }
                    for index in activeCADFindings
                    where cadAccumulators[index].seenReferences.insert(identity).inserted {
                        cadAccumulators[index].sourceImageReferences.append(reference)
                    }
                }

                let groupID = item.valueType == "CONTAINER" ? item.statedTrackingID : nil
                let groupUID = item.valueType == "CONTAINER" ? item.statedTrackingUID : nil
                let entersGroup = groupID != nil || groupUID != nil
                if entersGroup { groupIdentities.append((groupID, groupUID)) }

                pending.append(.exit(ExitState(
                    measurementIndex: measurementIndex,
                    regionIndex: regionIndex,
                    cadIndex: cadIndex,
                    leavesGroup: entersGroup
                )))
                pending.append(contentsOf: item.children.reversed().map(TraversalEvent.enter))

            case .exit(let state):
                if state.leavesGroup { _ = groupIdentities.popLast() }
                if let regionIndex = state.regionIndex {
                    let accumulator = regionAccumulators[regionIndex]
                    regionResults[accumulator.resultIndex] = DicomSRGraphicRegion(
                        graphicType: accumulator.graphicType,
                        graphicData: accumulator.graphicData,
                        sourceImageReferences: accumulator.sourceImageReferences
                    )
                    _ = activeRegions.popLast()
                }
                if let measurementIndex = state.measurementIndex {
                    let accumulator = measurementAccumulators[measurementIndex]
                    measurementResults[accumulator.resultIndex] = DicomSRMeasurement(
                        name: accumulator.item.conceptName,
                        value: accumulator.value,
                        units: accumulator.item.measurementUnits,
                        trackingID: accumulator.item.trackingID ?? accumulator.groupIdentity?.id,
                        trackingUID: accumulator.item.trackingUID ?? accumulator.groupIdentity?.uid,
                        sourceImageReferences: accumulator.sourceImageReferences,
                        roi: accumulator.roiRegionIndex.flatMap { regionResults[$0] }
                    )
                    _ = activeMeasurements.popLast()
                }
                if let cadIndex = state.cadIndex {
                    let accumulator = cadAccumulators[cadIndex]
                    cadResults[accumulator.resultIndex] = DicomSRCADFinding(
                        title: accumulator.item.conceptName,
                        trackingID: accumulator.item.statedTrackingID,
                        trackingUID: accumulator.item.statedTrackingUID,
                        sourceImageReferences: accumulator.sourceImageReferences,
                        measurements: measurementResults[accumulator.measurementStartIndex...].compactMap { $0 },
                        contentItem: accumulator.item
                    )
                    _ = activeCADFindings.popLast()
                }
            }
        }

        return Analysis(
            measurements: measurementResults.compactMap { $0 },
            cadFindings: cadResults.compactMap { $0 }
        )
    }

    private static func isCADFinding(_ item: DicomSRContentItem) -> Bool {
        let haystack = [
            item.conceptName?.codeMeaning,
            item.conceptName?.codeValue,
            item.statedTrackingID
        ].compactMap { $0?.uppercased() }.joined(separator: " ")
        return haystack.contains("CAD") || haystack.contains("FINDING")
    }

    private struct Analysis {
        let measurements: [DicomSRMeasurement]
        let cadFindings: [DicomSRCADFinding]
    }

    private struct MeasurementAccumulator {
        let item: DicomSRContentItem
        let value: Double
        let resultIndex: Int
        let groupIdentity: (id: String?, uid: String?)?
        var sourceImageReferences: [DicomSourceImageReference] = []
        var seenReferences = Set<DicomSourceImageReferenceIdentity>()
        var roiRegionIndex: Int?
    }

    private struct RegionAccumulator {
        let graphicType: String
        let graphicData: [Double]
        let resultIndex: Int
        var sourceImageReferences: [DicomSourceImageReference] = []
        var seenReferences = Set<DicomSourceImageReferenceIdentity>()
    }

    private struct CADAccumulator {
        let item: DicomSRContentItem
        let measurementStartIndex: Int
        let resultIndex: Int
        var sourceImageReferences: [DicomSourceImageReference] = []
        var seenReferences = Set<DicomSourceImageReferenceIdentity>()
    }

    private struct ExitState {
        let measurementIndex: Int?
        let regionIndex: Int?
        let cadIndex: Int?
        let leavesGroup: Bool
    }

    private enum TraversalEvent {
        case enter(DicomSRContentItem)
        case exit(ExitState)
    }
}
