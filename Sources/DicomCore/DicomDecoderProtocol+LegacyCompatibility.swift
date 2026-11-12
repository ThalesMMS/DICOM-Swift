//
//  DicomDecoderProtocol+LegacyCompatibility.swift
//  DicomCore
//
//  Adds legacy compatibility support to DicomDecoderProtocol.
//
//  Thales Matheus Mendonça Santos — June 2026
//

// MARK: - Legacy Decoder Compatibility

extension DicomDecoderProtocol {
    /// Sets the DICOM filename on the underlying decoder when the concrete instance is a `DCMDecoder`; no action is performed otherwise.
    /// - Parameter filename: The DICOM filename (path or name) to assign to the underlying decoder.
    @available(*, deprecated, message: "Use throwing initializers instead of setDicomFilename(_:).")
    func setDicomFilename(_ filename: String) {
        (self as? DCMDecoder)?.setDicomFilename(filename)
    }

    @available(*, deprecated, message: "Use throwing initializers/error handling instead of dicomFileReadSuccess.")
    var dicomFileReadSuccess: Bool {
        if let decoder = self as? DCMDecoder {
            return decoder.dicomFileReadSuccess
        }
        return isValid()
    }
}
