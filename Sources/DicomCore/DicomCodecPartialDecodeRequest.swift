import Foundation

/// Backend-level partial request. Resolution level is absolute (zero is the smallest resolution).
public struct DicomCodecPartialDecodeRequest: Equatable, Sendable {
    public struct Region: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public let region: Region?
    public let resolutionLevel: Int?
    public let maximumQualityLayer: Int?

    public init(region: Region? = nil, resolutionLevel: Int? = nil, maximumQualityLayer: Int? = nil) {
        self.region = region
        self.resolutionLevel = resolutionLevel
        self.maximumQualityLayer = maximumQualityLayer
    }
}
