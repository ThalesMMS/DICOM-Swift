//
//  DicomWebServerNativeTranscoding.swift
//  DicomCore
//
//  Serves stored instances as Explicit VR Little Endian when the stored
//  syntax cannot go out as it is: Implicit VR Little Endian and Explicit VR
//  Big Endian are not DICOMweb transfer syntaxes (PS3.18 8.6.2.1), and a
//  client that names no syntax asks for Explicit VR Little Endian. Native
//  syntaxes are rewritten; compressed ones are decoded frame by frame
//  through DicomTranscoder. Nothing is ever compressed here.
//

import Foundation

public struct DicomWebServerNativeTranscoding: DicomWebServerTranscoding {
    public init() {}

    public var transferSyntaxUIDs: [String] { [DicomTransferSyntax.explicitVRLittleEndian.rawValue] }

    public func canTranscode(from storedSyntaxUID: String, to requestedSyntaxUID: String) -> Bool {
        guard requestedSyntaxUID == DicomTransferSyntax.explicitVRLittleEndian.rawValue,
              let source = DicomTransferSyntax(rawValue: storedSyntaxUID) else { return false }
        let plan = DicomTransferSyntaxRegistry.standard.transcodePlan(from: source, to: .explicitVRLittleEndian)
        switch plan.route {
        case .passThrough, .rewriteNative: return plan.canTranscode
        // A best-effort decoder (CharLS, OpenJPEG) is tried: an object it cannot
        // decode fails when it is sent, instead of every such object being refused.
        case .decompress: return plan.status != .unsupported
        default: return false
        }
    }

    public func transcode(_ instance: DicomWebStoredInstance, to transferSyntaxUID: String) async throws -> Data {
        guard let destination = DicomTransferSyntax(rawValue: transferSyntaxUID),
              canTranscode(from: instance.transferSyntax.rawValue, to: transferSyntaxUID) else {
            throw DicomTranscoder.TranscodeError.routeUnsupported(sourceUID: instance.transferSyntax.rawValue,
                destinationUID: transferSyntaxUID, diagnostics: ["Only Explicit VR Little Endian is served by transcoding."])
        }
        return try DicomTranscoder().transcode(instance.part10Data, to: destination)
    }
}
