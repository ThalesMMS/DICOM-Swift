//
//  DicomJ2KSwiftBackendError.swift
//  DicomCore
//

import Foundation

enum DicomJ2KSwiftBackendError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedShape(transferSyntaxUID: String, reason: String)
    case metadataMismatch(transferSyntaxUID: String, reason: String)
    case codecVersionMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShape(let uid, let reason):
            return "J2KSwift cannot process transfer syntax \(uid) for this pixel shape: \(reason)"
        case .metadataMismatch(let uid, let reason):
            return "J2KSwift output for transfer syntax \(uid) does not match the DICOM descriptor: \(reason)"
        case .codecVersionMismatch(let expected, let actual):
            return "J2KSwift codec version mismatch: expected \(expected), linked \(actual)"
        }
    }
}
