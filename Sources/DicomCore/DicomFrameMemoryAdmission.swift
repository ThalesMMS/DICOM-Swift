/// Host admission for the existing conservative source-session working set.
/// These capacities bound planned work; they are not RSS measurements.
public struct DicomFrameMemoryAdmission: Sendable {
    public struct Request: Sendable {
        public let compressedCapacity: Int
        public let pixelCapacity: Int
        public let scratchCapacity: Int
    }

    public let reserve: @Sendable (Request) async throws -> any DicomFrameMemoryReservation

    public init(reserve: @escaping @Sendable (Request) async throws -> any DicomFrameMemoryReservation) {
        self.reserve = reserve
    }
}
