/// UID identity and reference values found in a Part 10 dataset.
public struct DicomPart10UIDInspection: Equatable, Sendable {
    /// Top-level Study Instance UID, when present.
    public let studyInstanceUID: String?
    /// Top-level Series Instance UID, when present.
    public let seriesInstanceUID: String?
    /// Top-level SOP Instance UID, when present.
    public let sopInstanceUID: String?
    /// Top-level Frame of Reference UID values owned by the instance.
    public let frameOfReferenceUIDs: Set<String>
    /// Every UI value in the dataset, including nested sequence items.
    public let allUIDValues: Set<String>

    /// Creates an immutable UID inspection snapshot.
    public init(
        studyInstanceUID: String?,
        seriesInstanceUID: String?,
        sopInstanceUID: String?,
        frameOfReferenceUIDs: Set<String>,
        allUIDValues: Set<String>
    ) {
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopInstanceUID = sopInstanceUID
        self.frameOfReferenceUIDs = frameOfReferenceUIDs
        self.allUIDValues = allUIDValues
    }
}
