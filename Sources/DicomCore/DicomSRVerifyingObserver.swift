//
//  DicomSRVerifyingObserver.swift
//  DicomCore
//
//  One item of an SR document's Verifying Observer Sequence (issue #2823).
//

import Foundation

/// Who verified an SR document and when (PS3.3 C.17.2, Verifying Observer Sequence (0040,A073)); written only
/// with a Verification Flag of VERIFIED.
public struct DicomSRVerifyingObserver: Equatable, Hashable, Sendable {
    /// Verifying Observer Name (0040,A075), a PN.
    public let name: String
    /// Verifying Organization (0040,A027).
    public let organization: String
    /// Verification DateTime (0040,A030), a DT.
    public let dateTime: String

    public init(name: String, organization: String, dateTime: String) {
        self.name = name
        self.organization = organization
        self.dateTime = dateTime
    }
}
