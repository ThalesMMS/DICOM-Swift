//
//  DicomPixelObjectSupport.swift
//  DicomCore
//
//  Non-classic pixel object policy (issue #1238): one support matrix
//  declares how each pixel-carrying object family is consumed — classic
//  integer images feed display/volume pipelines, Segmentation produces
//  labelmaps, RT Dose produces a scaled dose grid, Parametric Map
//  produces real-world-mapped scalar volumes, and bare Float/Double
//  Float Pixel Data outside those IODs is typed out of scope. One typed
//  entry point classifies an object and extracts its payload, rejecting
//  unsupported shapes with stable errors that name the SOP Class, pixel
//  data element type, transfer syntax, and missing metadata.
//

import Foundation

/// Pixel-carrying object families distinguished by payload semantics.
public enum DicomPixelObjectFamily: String, CaseIterable, Sendable {
    /// Classic integer Pixel Data (7FE0,0010) images (CT/MR/SC/...).
    case classicImage = "classic-image"
    /// Segmentation Storage labelmaps (binary or fractional).
    case segmentation
    /// RT Dose grids scaled by Dose Grid Scaling.
    case rtDose = "rt-dose"
    /// Parametric Map with Float/Double Float Pixel Data and
    /// Real World Value Mapping.
    case parametricMap = "parametric-map"
    /// Float Pixel Data (7FE0,0008) outside the Parametric Map IOD.
    case floatImage = "float-pixel-data"
    /// Double Float Pixel Data (7FE0,0009) outside the Parametric Map IOD.
    case doubleFloatImage = "double-float-pixel-data"
}

/// How a family's payload is meant to be consumed downstream.
public enum DicomPixelObjectRole: String, Sendable {
    case imageDisplayInput = "image-display-input"
    case volumeInput = "volume-input"
    case overlayOrSegmentation = "overlay-or-segmentation"
    case doseGrid = "dose-grid"
    case outOfScope = "out-of-scope"
}

/// Pixel data element carried by an object.
public enum DicomPixelElementType: String, Sendable {
    case integer = "(7FE0,0010) Pixel Data"
    case float = "(7FE0,0008) Float Pixel Data"
    case doubleFloat = "(7FE0,0009) Double Float Pixel Data"
    case none = "no pixel data element"
}

/// One support matrix row.
public struct DicomPixelObjectSupport: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        /// A typed payload extractor exists.
        case typedPayload = "typed-payload"
        /// Consumed by the classic image/volume pipelines.
        case classicPipelines = "classic-pipelines"
        /// Rejected with stable typed errors.
        case unsupported
    }

    public let family: DicomPixelObjectFamily
    public let role: DicomPixelObjectRole
    public let status: Status
    public let diagnostic: String
}

/// The declared support matrix for pixel-carrying object families.
public enum DicomPixelObjectSupportMatrix {
    public static let standard: [DicomPixelObjectSupport] = [
        DicomPixelObjectSupport(
            family: .classicImage,
            role: .imageDisplayInput,
            status: .classicPipelines,
            diagnostic: "Classic integer Pixel Data feeds DicomDecodedFrameReader for frames, "
                + "displayRGBPixelBuffer for display, and DicomSeriesLoader for volumes."
        ),
        DicomPixelObjectSupport(
            family: .segmentation,
            role: .overlayOrSegmentation,
            status: .typedPayload,
            diagnostic: "Segmentation Storage extracts DicomSegmentation: segments with labels, "
                + "binary/fractional pixel payloads, and per-segment labelmaps."
        ),
        DicomPixelObjectSupport(
            family: .rtDose,
            role: .doseGrid,
            status: .typedPayload,
            diagnostic: "RT Dose extracts DicomRTDoseVolume: stored grid values scaled by "
                + "Dose Grid Scaling with units, grid frame offsets, and geometry."
        ),
        DicomPixelObjectSupport(
            family: .parametricMap,
            role: .volumeInput,
            status: .typedPayload,
            diagnostic: "Parametric Map extracts DicomParametricMap: Float/Double Float scalar "
                + "volumes with Real World Value Mapping and quantity definitions."
        ),
        DicomPixelObjectSupport(
            family: .floatImage,
            role: .outOfScope,
            status: .unsupported,
            diagnostic: "Float Pixel Data outside the Parametric Map IOD has no defined "
                + "consumer; it is rejected with a typed error."
        ),
        DicomPixelObjectSupport(
            family: .doubleFloatImage,
            role: .outOfScope,
            status: .unsupported,
            diagnostic: "Double Float Pixel Data outside the Parametric Map IOD has no defined "
                + "consumer; it is rejected with a typed error."
        )
    ]

    public static func support(for family: DicomPixelObjectFamily) -> DicomPixelObjectSupport {
        standard.first { $0.family == family }
            ?? DicomPixelObjectSupport(
                family: family,
                role: .outOfScope,
                status: .unsupported,
                diagnostic: "\(family.rawValue) is not in the declared pixel object matrix."
            )
    }
}

/// Typed payload extracted from a pixel-carrying object.
public enum DicomTypedPixelPayload {
    /// Classic image: consume through `DicomDecodedFrameReader`.
    case classicImage(DicomDecodedFrameReader)
    case segmentation(DicomSegmentation)
    case rtDose(DicomRTDoseVolume)
    case parametricMap(DicomParametricMap)
}

/// Stable rejection error naming the object's identity and the gap.
public struct DicomPixelObjectError: Error, Equatable, LocalizedError, Sendable {
    public let sopClassUID: String
    public let pixelElement: DicomPixelElementType
    public let transferSyntaxUID: String
    public let reason: String

    public var errorDescription: String? {
        "Unsupported pixel object: SOP Class \(sopClassUID), \(pixelElement.rawValue), "
            + "transfer syntax \(transferSyntaxUID). \(reason)"
    }
}

public enum DicomPixelObjectClassifier {
    /// Classified identity of one pixel-carrying object.
    public struct Classification: Equatable, Sendable {
        public let family: DicomPixelObjectFamily
        public let sopClassUID: String
        public let transferSyntaxUID: String
        public let pixelElement: DicomPixelElementType
    }

    /// Classifies the object family from SOP Class and pixel element type.
    public static func classify(_ decoder: DCMDecoder) -> Classification {
        let sopClassUID = decoder.info(for: .sopClassUID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transferSyntaxUID = decoder.info(for: .transferSyntaxUID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pixelElement = pixelElementType(of: decoder)

        let family: DicomPixelObjectFamily
        switch sopClassUID {
        case DicomSegmentationBuilder.segmentationStorageSOPClassUID:
            family = .segmentation
        case DicomRTDoseVolume.storageSOPClassUID:
            family = .rtDose
        case DicomParametricMap.storageSOPClassUID:
            family = .parametricMap
        default:
            switch pixelElement {
            case .float:
                family = .floatImage
            case .doubleFloat:
                family = .doubleFloatImage
            case .integer, .none:
                family = .classicImage
            }
        }
        return Classification(
            family: family,
            sopClassUID: sopClassUID.isEmpty ? "<unknown>" : sopClassUID,
            transferSyntaxUID: transferSyntaxUID.isEmpty
                ? DicomTransferSyntax.explicitVRLittleEndian.rawValue
                : transferSyntaxUID,
            pixelElement: pixelElement
        )
    }

    /// Extracts the typed payload for a supported object, or throws a
    /// stable `DicomPixelObjectError`.
    public static func typedPayload(from decoder: DCMDecoder) throws -> DicomTypedPixelPayload {
        let classification = classify(decoder)

        func rejection(_ reason: String) -> DicomPixelObjectError {
            DicomPixelObjectError(
                sopClassUID: classification.sopClassUID,
                pixelElement: classification.pixelElement,
                transferSyntaxUID: classification.transferSyntaxUID,
                reason: reason
            )
        }

        switch classification.family {
        case .segmentation:
            guard let segmentation = decoder.segmentation else {
                throw rejection("Segmentation Storage requires the Segment Sequence and a decodable pixel payload.")
            }
            return .segmentation(segmentation)
        case .rtDose:
            guard let dose = decoder.rtDose else {
                throw rejection("RT Dose requires Dose Grid Scaling, grid geometry, and integer Pixel Data.")
            }
            guard !decoder.info(for: .doseGridScaling).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw rejection("RT Dose requires Dose Grid Scaling (3004,000E); the element is absent.")
            }
            guard !dose.gridFrameOffsetVector.isEmpty || dose.frames == 1 else {
                throw rejection("RT Dose multiframe grids require Grid Frame Offset Vector (3004,000C).")
            }
            return .rtDose(dose)
        case .parametricMap:
            do {
                return .parametricMap(try decoder.decodeParametricMap())
            } catch let error as DicomParametricMapDecodeError {
                // Carry the typed object-level reason (dimensions, payload,
                // missing/ambiguous mapping, all pixels invalid) instead of
                // one generic message; recoverable per-pixel problems never
                // reach this path (issue #1875).
                throw rejection("Parametric Map rejected [\(error.reason.code)]: \(error.reason.message)")
            }
        case .classicImage:
            guard classification.pixelElement == .integer else {
                throw rejection("The object carries no Pixel Data element to decode.")
            }
            return .classicImage(DicomDecodedFrameReader(decoder: decoder))
        case .floatImage, .doubleFloatImage:
            throw rejection(DicomPixelObjectSupportMatrix.support(for: classification.family).diagnostic)
        }
    }

    private static func pixelElementType(of decoder: DCMDecoder) -> DicomPixelElementType {
        if decoder.hasTagMetadata(DicomTag.floatPixelData.rawValue) {
            return .float
        }
        if decoder.hasTagMetadata(DicomTag.doubleFloatPixelData.rawValue) {
            return .doubleFloat
        }
        if decoder.hasTagMetadata(DicomTag.pixelData.rawValue) || decoder.offset > 0 {
            return .integer
        }
        return .none
    }
}

extension DCMDecoder {
    func hasTagMetadata(_ tag: Int) -> Bool {
        synchronized {
            tagMetadataCache[tag] != nil
        }
    }
}
