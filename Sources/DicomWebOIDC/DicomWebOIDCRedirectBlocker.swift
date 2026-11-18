//
//  DicomWebOIDCRedirectBlocker.swift
//  DicomWebOIDC
//
//  Refuses every redirect of the identity provider's endpoints, so a token request never follows a
//  server elsewhere.
//
//  Thales Matheus Mendonça Santos — October 2026
//

import Foundation

/// Refuses every redirect of the identity provider's endpoints, so a token request never follows a server elsewhere.
final class DicomWebOIDCRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
