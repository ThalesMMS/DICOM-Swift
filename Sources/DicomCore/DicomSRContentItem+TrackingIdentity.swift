import Foundation

extension DicomSRContentItem {
    /// The tracking identifier the item states: its own Tracking ID, or, for a measurement group (TID 1410,
    /// 1411, 1501), the TEXT 112039 *Tracking Identifier* item it holds — the way SR carries it.
    public var statedTrackingID: String? {
        trackingID ?? trackingChild(codeValue: "112039", valueType: "TEXT")?.textValue
    }

    /// The tracking UID the item states: its own Tracking UID, or the UIDREF 112040 *Tracking Unique
    /// Identifier* item a measurement group holds.
    public var statedTrackingUID: String? {
        trackingUID ?? trackingChild(codeValue: "112040", valueType: "UIDREF")?.uidValue
    }

    private func trackingChild(codeValue: String, valueType: String) -> DicomSRContentItem? {
        guard self.valueType == "CONTAINER" else { return nil }
        return children.first {
            $0.valueType == valueType && $0.conceptName?.codeValue == codeValue
                && $0.conceptName?.codingSchemeDesignator == "DCM"
        }
    }
}
