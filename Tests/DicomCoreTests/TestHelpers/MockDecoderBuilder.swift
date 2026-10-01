import Foundation
import simd
@testable import DicomCore
import DicomTestSupport

enum MockDecoderBuilder {
    static var axialOrientation: (row: SIMD3<Double>, column: SIMD3<Double>) {
        (
            row: SIMD3<Double>(1, 0, 0),
            column: SIMD3<Double>(0, 1, 0)
        )
    }

    /// Create a preconfigured MockDicomDecoder with the given image geometry, DICOM tags, and optional pixel data.
    /// - Parameters:
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - bitDepth: Bit depth per sample; used together with `samplesPerPixel` to determine whether pixel buffers are populated.
    ///   - samplesPerPixel: Number of samples per pixel (e.g., 1 = grayscale, 3 = RGB-like).
    ///   - pixelValue: Value used to fill generated pixel buffers when `loadSucceeded` is true.
    ///   - pixelSpacing: Pixel spacing as (width, height, depth) written into PixelSpacing tags and pixel spacing properties.
    ///   - position: Image position (ImagePositionPatient) written into the corresponding tag and property.
    ///   - orientation: Tuple of row and column orientation vectors written into ImageOrientationPatient and assigned to the decoder.
    ///   - seriesDescription: Value for the SeriesDescription DICOM tag.
    ///   - loadSucceeded: If `true`, sets `dicomFound` and `dicomFileReadSuccess` and populates pixel buffers for supported formats; if `false`, tags are set but no pixel buffers are created.
    /// - Returns: A MockDicomDecoder configured with the provided attributes. If `loadSucceeded` is true, pixel buffers are populated for these supported combinations: 8-bit grayscale (samplesPerPixel = 1, bitDepth = 8), 16-bit grayscale (samplesPerPixel = 1, bitDepth = 16), and 24-bit RGB-like (samplesPerPixel = 3, any bitDepth).
    static func makeDecoder(
        width: Int = 512,
        height: Int = 512,
        bitDepth: Int = 16,
        samplesPerPixel: Int = 1,
        pixelValue: UInt16 = 100,
        pixelSpacing: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        position: SIMD3<Double> = .zero,
        orientation: (row: SIMD3<Double>, column: SIMD3<Double>) = axialOrientation,
        seriesDescription: String = "Test Series",
        modality: String = "CT",
        loadSucceeded: Bool = true
    ) -> MockDicomDecoder {
        let mock = MockDicomDecoder()
        let bitFields: (allocated: Int, stored: Int, highBit: Int)
        if samplesPerPixel == 3 {
            bitFields = (8, 8, 7)
        } else if bitDepth == 12 {
            bitFields = (16, 12, 11)
        } else {
            bitFields = (bitDepth, bitDepth, max(0, bitDepth - 1))
        }

        mock.width = width
        mock.height = height
        mock.bitDepth = bitFields.allocated
        mock.samplesPerPixel = samplesPerPixel
        mock.pixelWidth = pixelSpacing.x
        mock.pixelHeight = pixelSpacing.y
        mock.pixelDepth = pixelSpacing.z
        mock.imagePosition = position
        mock.imageOrientation = orientation
        mock.dicomFound = loadSucceeded
        mock.mockFileReadSucceeded = loadSucceeded

        mock.setTag(DicomTag.rows.rawValue, value: "\(height)")
        mock.setTag(DicomTag.columns.rawValue, value: "\(width)")
        mock.setTag(DicomTag.bitsAllocated.rawValue, value: "\(bitFields.allocated)")
        mock.setTag(DicomTag.bitsStored.rawValue, value: "\(bitFields.stored)")
        mock.setTag(DicomTag.highBit.rawValue, value: "\(bitFields.highBit)")
        mock.setTag(DicomTag.samplesPerPixel.rawValue, value: "\(samplesPerPixel)")
        mock.setTag(DicomTag.pixelRepresentation.rawValue, value: "0")
        mock.setTag(
            DicomTag.pixelSpacing.rawValue,
            value: "\(pixelSpacing.x)\\\(pixelSpacing.y)"
        )
        mock.setTag(
            DicomTag.imagePositionPatient.rawValue,
            value: "\(position.x)\\\(position.y)\\\(position.z)"
        )
        mock.setTag(
            DicomTag.imageOrientationPatient.rawValue,
            value: "\(orientation.row.x)\\\(orientation.row.y)\\\(orientation.row.z)\\\(orientation.column.x)\\\(orientation.column.y)\\\(orientation.column.z)"
        )
        mock.setTag(DicomTag.rescaleIntercept.rawValue, value: "0")
        mock.setTag(DicomTag.rescaleSlope.rawValue, value: "1")
        mock.setTag(DicomTag.seriesDescription.rawValue, value: seriesDescription)
        mock.setTag(DicomTag.modality.rawValue, value: modality)

        guard loadSucceeded else {
            return mock
        }

        let pixelCount = max(0, width * height)
        switch (samplesPerPixel, bitFields.allocated) {
        case (1, 8):
            let value = UInt8(clamping: Int(pixelValue))
            mock.setPixels8([UInt8](repeating: value, count: pixelCount))
        case (1, 16):
            mock.setPixels16([UInt16](repeating: pixelValue, count: pixelCount))
        case (1, 32):
            mock.setStoredPixelValues([Int](repeating: Int(pixelValue), count: pixelCount))
        case (3, 8):
            let value = UInt8(clamping: Int(pixelValue))
            mock.setPixels24([UInt8](repeating: value, count: pixelCount * 3))
        default:
            break
        }

        return mock
    }

    /// Creates a closure that constructs a configured `DicomDecoderProtocol` for a given file path.
    ///
    /// - Parameters:
    ///   - positionProvider: Optional closure that maps the provided path to an image origin; when non-nil its result overrides the `position` argument for the produced decoder.
    ///   - sizeProvider: Optional closure that maps the provided path to `(width, height)`; when non-nil its result overrides the `width` and `height` arguments for the produced decoder.
    /// - Returns: A closure that accepts a file path and returns a `DicomDecoderProtocol` configured with the builder's fixed parameters, using `sizeProvider` and `positionProvider` when provided.
    static func makePathFactory(
        width: Int = 512,
        height: Int = 512,
        bitDepth: Int = 16,
        samplesPerPixel: Int = 1,
        pixelValue: UInt16 = 100,
        pixelSpacing: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        position: SIMD3<Double> = .zero,
        orientation: (row: SIMD3<Double>, column: SIMD3<Double>) = axialOrientation,
        seriesDescription: String = "Test Series",
        modality: String = "CT",
        positionProvider: (@Sendable (String) -> SIMD3<Double>)? = nil,
        sizeProvider: (@Sendable (String) -> (width: Int, height: Int))? = nil
    ) -> @Sendable (String) throws -> DicomDecoderProtocol {
        { path in
            let size = sizeProvider?(path) ?? (width: width, height: height)
            return makeDecoder(
                width: size.width,
                height: size.height,
                bitDepth: bitDepth,
                samplesPerPixel: samplesPerPixel,
                pixelValue: pixelValue,
                pixelSpacing: pixelSpacing,
                position: positionProvider?(path) ?? position,
                orientation: orientation,
                seriesDescription: seriesDescription,
                modality: modality
            )
        }
    }

    /// Create a no-argument factory that produces configured MockDicomDecoder instances.
    /// - Parameters:
    ///   - loadSucceeded: When `true`, the produced decoder includes pixel buffers; when `false`, tags are set but pixel buffers are not populated.
    ///   - positionProvider: Optional closure invoked each time the factory is called to supply the image `position`; if `nil`, the static `position` argument is used.
    /// - Returns: A closure that, when invoked, returns a `DicomDecoderProtocol` configured with the provided geometry, pixel characteristics, spacing, orientation, series description, and load behavior.
    static func makeFactory(
        width: Int = 512,
        height: Int = 512,
        bitDepth: Int = 16,
        samplesPerPixel: Int = 1,
        pixelValue: UInt16 = 100,
        pixelSpacing: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        position: SIMD3<Double> = .zero,
        orientation: (row: SIMD3<Double>, column: SIMD3<Double>) = axialOrientation,
        seriesDescription: String = "Test Series",
        modality: String = "CT",
        loadSucceeded: Bool = true,
        positionProvider: (@Sendable () -> SIMD3<Double>)? = nil
    ) -> @Sendable () -> DicomDecoderProtocol {
        {
            makeDecoder(
                width: width,
                height: height,
                bitDepth: bitDepth,
                samplesPerPixel: samplesPerPixel,
                pixelValue: pixelValue,
                pixelSpacing: pixelSpacing,
                position: positionProvider?() ?? position,
                orientation: orientation,
                seriesDescription: seriesDescription,
                modality: modality,
                loadSucceeded: loadSucceeded
            )
        }
    }

    /// Creates a factory that produces decoders whose simulated load success follows a repeating pattern.
    ///
    /// The returned closure produces a `DicomDecoderProtocol` configured with the supplied geometry, pixel settings, spacing, position, orientation, and series description. The closure advances through `successPattern` on each invocation (wrapping to the start when the end is reached) to determine whether the produced decoder should simulate a successful load. Access to the pattern and index is serialized to ensure deterministic sequencing across concurrent calls.
    /// - Parameters:
    ///   - successPattern: An array of booleans that determines per-invocation load success; `true` means the decoder will simulate a successful load, `false` means it will simulate failure. If empty, produced decoders always simulate success.
    ///   - width: Width in pixels for produced decoders.
    ///   - height: Height in pixels for produced decoders.
    ///   - bitDepth: Bit depth for pixel data.
    ///   - samplesPerPixel: Number of samples per pixel (e.g., 1 for grayscale, 3 for RGB).
    ///   - pixelValue: Repeated pixel value used when populating pixel buffers.
    ///   - pixelSpacing: Physical pixel spacing (width, height, depth).
    ///   - position: Image position in patient coordinates.
    ///   - orientation: Row/column orientation vectors.
    ///   - seriesDescription: Series description tag to assign to produced decoders.
    /// - Returns: A no-argument closure that returns a configured `DicomDecoderProtocol`. Each call produces a decoder whose load success is set to the next value from `successPattern` (cycle repeats). If `successPattern` is empty, load success is always `true`.
    static func makeSequencedFactory(
        successPattern: [Bool],
        width: Int = 512,
        height: Int = 512,
        bitDepth: Int = 16,
        samplesPerPixel: Int = 1,
        pixelValue: UInt16 = 100,
        pixelSpacing: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        position: SIMD3<Double> = .zero,
        orientation: (row: SIMD3<Double>, column: SIMD3<Double>) = axialOrientation,
        seriesDescription: String = "Test Series",
        modality: String = "CT"
    ) -> @Sendable () -> DicomDecoderProtocol {
        let index = DicomTestLockedValue(0)

        return {
            let loadSucceeded = index.withValue { index in
                guard !successPattern.isEmpty else { return true }
                let result = successPattern[index % successPattern.count]
                index += 1
                return result
            }

            return makeDecoder(
                width: width,
                height: height,
                bitDepth: bitDepth,
                samplesPerPixel: samplesPerPixel,
                pixelValue: pixelValue,
                pixelSpacing: pixelSpacing,
                position: position,
                orientation: orientation,
                seriesDescription: seriesDescription,
                modality: modality,
                loadSucceeded: loadSucceeded
            )
        }
    }
}
