//
//  DicomLDAPIdentity.swift
//  DicomCore
//
//  Only the authentication service produces this identity after a successful, nonempty user bind.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

/// Only the authentication service produces this identity after a successful, nonempty user bind.
public struct DicomLDAPIdentity: Equatable, Sendable {
    public let distinguishedName: String
    public let username: String
    public let groups: Set<String>
}
