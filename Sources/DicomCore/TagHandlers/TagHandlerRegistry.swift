//
//  TagHandlerRegistry.swift
//
//  Registry that maps DICOM tag IDs to their corresponding
//  TagHandler implementations.  This class replaces the monolithic
//  switch statement in readFileInfo() with a lookup-based dispatch
//  system, making it easy to add new tag handlers without modifying
//  the core parsing logic.
//
//  Architecture:
//
//  The registry maintains a dictionary mapping tag IDs (Int) to
//  TagHandler instances.  During file parsing, the decoder calls
//  getHandler(for:) to retrieve the appropriate handler for each
//  tag.  If a handler is registered, it processes the tag and
//  updates decoder state.  If no handler is found, the tag is
//  treated as metadata-only and parsed lazily on first access.
//
//  Adding New Handlers:
//
//  To add support for a new DICOM tag:
//  1. Create a handler class conforming to TagHandler protocol
//  2. Add it to the registry in registerHandlers() method
//  3. Map the tag ID(s) to the handler instance
//
//  Thread Safety:
//
//  The registry is thread-safe for concurrent reads after
//  initialization.  All handlers are registered during init() and
//  the handler dictionary is never modified afterward.  Multiple
//  threads can safely call getHandler(for:) concurrently.
//
//  Performance:
//
//  Handler lookup is O(1) via dictionary access.  Handlers are
//  reused across tags (e.g., ImageDimensionTagHandler handles
//  three tags), minimizing memory overhead.  The registry
//  allocates approximately 50 bytes per registered tag mapping.
//

import Foundation

/// Backward compatibility alias to centralized DICOM tag constants.
private typealias Tag = DicomTag

/// Registry that maps DICOM tag IDs to TagHandler implementations.
/// Provides lookup-based dispatch for tag processing, replacing the
/// monolithic switch statement with a composable, extensible system.
///
/// **Usage Pattern:**
///
///     let registry = TagHandlerRegistry()
///     if let handler = registry.getHandler(for: tagId) {
///         let shouldContinue = handler.handle(...)
///     } else {
///         // Tag not registered - defer to lazy parsing
///     }
///
/// **Registered Handlers:**
///
/// - TransferSyntaxTagHandler: Transfer Syntax UID (0002,0010)
/// - SpecificCharacterSetTagHandler: Specific Character Set (0008,0005)
/// - ImageDimensionTagHandler: Rows, Columns, Bits Allocated
/// - PixelInterpretationTagHandler: Samples per Pixel, Photometric Interpretation, Pixel Representation, Planar Configuration
/// - WindowingTagHandler: Window Center, Window Width
/// - GeometryTagHandler: Image Orientation (Patient), Image Position (Patient)
/// - SpatialCalibrationTagHandler: Pixel Spacing, Slice Thickness, Spacing Between Slices
/// - RescaleTagHandler: Rescale Intercept, Rescale Slope
/// - PaletteTagHandler: Red/Green/Blue Palette Color Lookup Tables
/// - PixelDataTagHandler: Pixel Data (7FE0,0010)
/// - ModalityTagHandler: Modality, Number of Frames
///
/// All other tags are handled via lazy parsing (parseTagOnDemand).
internal final class TagHandlerRegistry {

    // MARK: - Properties

    /// Dictionary mapping tag IDs to handler instances.
    /// Populated during initialization and never modified afterward.
    private let handlers: [Int: TagHandler]

    // MARK: - Initialization

    /// Creates a new registry and registers all tag handlers.
    /// Handler instances are shared across multiple tags where
    /// appropriate (e.g., ImageDimensionTagHandler handles three tags).
    init() {
        var registry: [Int: TagHandler] = [:]

        // Register Transfer Syntax handler
        let transferSyntaxHandler = TransferSyntaxTagHandler()
        registry[Tag.transferSyntaxUID.rawValue] = transferSyntaxHandler

        // Register Specific Character Set handler
        let specificCharacterSetHandler = SpecificCharacterSetTagHandler()
        registry[Tag.specificCharacterSet.rawValue] = specificCharacterSetHandler

        // Register Image Dimension handler
        let imageDimensionHandler = ImageDimensionTagHandler()
        registry[Tag.rows.rawValue] = imageDimensionHandler
        registry[Tag.columns.rawValue] = imageDimensionHandler
        registry[Tag.bitsAllocated.rawValue] = imageDimensionHandler

        // Register Pixel Interpretation handler
        let pixelInterpretationHandler = PixelInterpretationTagHandler()
        registry[Tag.samplesPerPixel.rawValue] = pixelInterpretationHandler
        registry[Tag.photometricInterpretation.rawValue] = pixelInterpretationHandler
        registry[Tag.pixelRepresentation.rawValue] = pixelInterpretationHandler
        registry[Tag.planarConfiguration.rawValue] = pixelInterpretationHandler

        // Register Windowing handler
        let windowingHandler = WindowingTagHandler()
        registry[Tag.windowCenter.rawValue] = windowingHandler
        registry[Tag.windowWidth.rawValue] = windowingHandler

        // Register Geometry handler
        let geometryHandler = GeometryTagHandler()
        registry[Tag.imageOrientationPatient.rawValue] = geometryHandler
        registry[Tag.imagePositionPatient.rawValue] = geometryHandler

        // Register Spatial Calibration handler
        let spatialCalibrationHandler = SpatialCalibrationTagHandler()
        registry[Tag.pixelSpacing.rawValue] = spatialCalibrationHandler
        registry[Tag.sliceThickness.rawValue] = spatialCalibrationHandler
        registry[Tag.sliceSpacing.rawValue] = spatialCalibrationHandler

        // Register Rescale handler
        let rescaleHandler = RescaleTagHandler()
        registry[Tag.rescaleIntercept.rawValue] = rescaleHandler
        registry[Tag.rescaleSlope.rawValue] = rescaleHandler

        // Register Palette handler
        let paletteHandler = PaletteTagHandler()
        registry[Tag.redPaletteDescriptor.rawValue] = paletteHandler
        registry[Tag.greenPaletteDescriptor.rawValue] = paletteHandler
        registry[Tag.bluePaletteDescriptor.rawValue] = paletteHandler
        registry[Tag.redPalette.rawValue] = paletteHandler
        registry[Tag.greenPalette.rawValue] = paletteHandler
        registry[Tag.bluePalette.rawValue] = paletteHandler
        registry[Tag.segmentedRedPalette.rawValue] = paletteHandler
        registry[Tag.segmentedGreenPalette.rawValue] = paletteHandler
        registry[Tag.segmentedBluePalette.rawValue] = paletteHandler

        // Register Pixel Data handler
        let pixelDataHandler = PixelDataTagHandler()
        registry[Tag.pixelData.rawValue] = pixelDataHandler

        // Register Modality handler
        let modalityHandler = ModalityTagHandler()
        registry[Tag.modality.rawValue] = modalityHandler
        registry[Tag.numberOfFrames.rawValue] = modalityHandler

        // Store the registry
        self.handlers = registry
    }

    // MARK: - Public Interface

    /// Retrieves the appropriate handler for a DICOM tag.
    ///
    /// - Parameter tag: The DICOM tag ID (e.g., 0x00280010 for Rows)
    ///
    /// - Returns: The TagHandler instance responsible for processing
    ///            this tag, or `nil` if the tag should be handled via
    ///            lazy parsing (metadata-only tags like PatientName,
    ///            StudyDate, etc.).
    ///
    /// **Performance:** O(1) dictionary lookup, typically <50ns on
    /// modern hardware.
    ///
    /// **Thread Safety:** Safe to call from multiple threads
    /// concurrently.  The handler dictionary is immutable after
    /// initialization.
    func getHandler(for tag: Int) -> TagHandler? {
        return handlers[tag]
    }
}
