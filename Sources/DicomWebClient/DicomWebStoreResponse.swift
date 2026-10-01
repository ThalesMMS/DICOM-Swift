import Foundation
import DicomData

public struct DicomWebStoreResponse: Equatable, Sendable {
    public enum Outcome: String, Sendable { case accepted, warning, failed, unknown }
    public struct Instance: Equatable, Sendable {
        public let sopClassUID: String?
        public let sopInstanceUID: String?
        public let retrieveURL: String?
        public let warningReason: Int?
        public let failureReason: Int?
        public let outcome: Outcome
    }
    public let retrieveURL: String?
    public let instances: [Instance]
    public let otherFailureReasons: [Int]
    /// Warning outcomes also identify successfully stored SOP Instances (Annex I).
    public var acceptedInstanceCount: Int { instances.filter { $0.outcome == .accepted || $0.outcome == .warning }.count }

    public static func decode(_ data: Data, contentType: String?) throws -> Self {
        if data.isEmpty { return .init(retrieveURL: nil, instances: [], otherFailureReasons: []) }
        // Compatibility with the pre-Annex-I in-memory helper. Identifiers are retained as unknown,
        // and its submitted-count field never establishes successful storage.
        if contentType?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let identifiers = object["sopInstanceUIDs"] as? [String] {
            return .init(retrieveURL: nil, instances: identifiers.map {
                .init(sopClassUID: nil, sopInstanceUID: $0, retrieveURL: nil,
                      warningReason: nil, failureReason: nil, outcome: .unknown)
            }, otherFailureReasons: [])
        }
        let dataSets: [DicomDataSet]
        if contentType?.lowercased().contains("xml") == true {
            dataSets = [try DicomNativeXMLCodec.decode(data).dataSet]
        } else {
            dataSets = try DicomJSONCodec.decode(data).map(\.dataSet)
        }
        var instances: [Instance] = []
        var other: [Int] = []
        for set in dataSets {
            for tag in [0x00081199, 0x00081198] {
                for item in set.sequenceItems(for: tag) {
                    let entry = item.dataSet
                    let warning = entry.int(for: 0x00081196)
                    let failure = entry.int(for: 0x00081197)
                    let uid = entry.string(for: 0x00081155)
                    let outcome: Outcome = uid == nil ? .unknown : tag == 0x00081198 ? .failed : warning != nil ? .warning : .accepted
                    instances.append(.init(sopClassUID: entry.string(for: 0x00081150), sopInstanceUID: uid,
                                           retrieveURL: entry.string(for: 0x00081190), warningReason: warning,
                                           failureReason: failure, outcome: outcome))
                }
            }
            other += set.sequenceItems(for: 0x0008119A).compactMap { $0.dataSet.int(for: 0x00081197) }
        }
        return .init(retrieveURL: dataSets.first?.string(for: 0x00081190), instances: instances, otherFailureReasons: other)
    }
}
