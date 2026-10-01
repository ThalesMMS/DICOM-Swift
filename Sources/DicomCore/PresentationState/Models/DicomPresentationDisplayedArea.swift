import Foundation

public struct DicomPresentationDisplayedArea: Equatable, Sendable {
    public let referencedImages: [DicomPresentationReferencedImage]
    public let topLeft: SIMD2<Int32>
    public let bottomRight: SIMD2<Int32>
    public let presentationSizeMode: String
    public let pixelOriginInterpretation: String?
    public let presentationPixelSpacing: [Double]
    public let presentationPixelAspectRatio: [Int]
    public let presentationPixelMagnificationRatio: Double?

    public init(
        referencedImages: [DicomPresentationReferencedImage] = [],
        topLeft: SIMD2<Int32> = SIMD2<Int32>(1, 1),
        bottomRight: SIMD2<Int32>,
        presentationSizeMode: String = "SCALE TO FIT",
        pixelOriginInterpretation: String? = nil,
        presentationPixelSpacing: [Double] = [],
        presentationPixelAspectRatio: [Int] = [],
        presentationPixelMagnificationRatio: Double? = nil
    ) {
        self.referencedImages = referencedImages
        self.topLeft = topLeft
        self.bottomRight = bottomRight
        self.presentationSizeMode = presentationSizeMode.dicomGSPSNonEmptyValue?.uppercased() ?? "SCALE TO FIT"
        self.pixelOriginInterpretation = pixelOriginInterpretation?.dicomGSPSNonEmptyValue?.uppercased()
        self.presentationPixelSpacing = Array(presentationPixelSpacing.prefix(2))
        self.presentationPixelAspectRatio = Array(presentationPixelAspectRatio.prefix(2))
        self.presentationPixelMagnificationRatio = presentationPixelMagnificationRatio
    }
}
