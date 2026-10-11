import Foundation

/// Priority (0000,0700) of a C-FIND, C-MOVE, C-GET or C-STORE request (PS3.7 Annex E): a hint the performing
/// DIMSE-service-user may use to order work.
public enum DicomDIMSEPriority: UInt16, CaseIterable, Sendable {
    case medium = 0x0000
    case high = 0x0001
    case low = 0x0002
}
