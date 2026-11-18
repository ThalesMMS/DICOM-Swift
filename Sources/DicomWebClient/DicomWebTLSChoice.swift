//
//  DicomWebTLSChoice.swift
//  DicomWebClient
//
//  The TLS choices of an origin policy that decide which connections a request may share.
//
//  Thales Matheus Mendonça Santos — October 2026
//

import Foundation

/// The TLS choices of an origin policy that decide which connections a request may share.
struct DicomWebTLSChoice: Hashable, Sendable {
    var serverTrust: DicomWebServerTrust
    var clientIdentity: DicomWebClientIdentity?
}
