import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif

#if canImport(Network)
enum DicomTLSRole: Sendable {
    case client
    case server
}

struct DicomPreparedNetworkParameters {
    let parameters: NWParameters
    let tlsContext: DicomAppliedTLSContext?
}

final class DicomAppliedTLSContext {
    let role: DicomTLSRole
    let serverName: String?
    let hasLocalIdentity: Bool
    let trustedCertificateCount: Int
    let securityProfile: DicomTLSSecurityProfile
    let minimumProtocolVersionName: String?
    let peerAuthenticationRequired: Bool

    #if canImport(Security)
    private let protocolIdentity: sec_identity_t?
    #endif

    #if canImport(Security)
    init(role: DicomTLSRole,
         serverName: String?,
         hasLocalIdentity: Bool,
         trustedCertificateCount: Int,
         securityProfile: DicomTLSSecurityProfile,
         minimumProtocolVersionName: String?,
         peerAuthenticationRequired: Bool,
         protocolIdentity: sec_identity_t? = nil) {
        self.role = role
        self.serverName = serverName
        self.hasLocalIdentity = hasLocalIdentity
        self.trustedCertificateCount = trustedCertificateCount
        self.securityProfile = securityProfile
        self.minimumProtocolVersionName = minimumProtocolVersionName
        self.peerAuthenticationRequired = peerAuthenticationRequired
        self.protocolIdentity = protocolIdentity
    }
    #else
    init(role: DicomTLSRole,
         serverName: String?,
         hasLocalIdentity: Bool,
         trustedCertificateCount: Int,
         securityProfile: DicomTLSSecurityProfile,
         minimumProtocolVersionName: String?,
         peerAuthenticationRequired: Bool) {
        self.role = role
        self.serverName = serverName
        self.hasLocalIdentity = hasLocalIdentity
        self.trustedCertificateCount = trustedCertificateCount
        self.securityProfile = securityProfile
        self.minimumProtocolVersionName = minimumProtocolVersionName
        self.peerAuthenticationRequired = peerAuthenticationRequired
    }
    #endif
}

enum DicomTLSOptionsFactory {
    static func preparedParameters(for tls: DicomTLSConfiguration, role: DicomTLSRole) throws -> DicomPreparedNetworkParameters {
        switch tls.mode {
        case .disabled:
            return DicomPreparedNetworkParameters(parameters: .tcp, tlsContext: nil)
        case .enabled:
            let prepared = try preparedTLSOptions(for: tls, role: role)
            return DicomPreparedNetworkParameters(
                parameters: NWParameters(tls: prepared.options, tcp: NWProtocolTCP.Options()),
                tlsContext: prepared.context
            )
        }
    }

    static func minimumTLSProtocolVersionName(for profile: DicomTLSSecurityProfile) -> String? {
        switch profile {
        case .none:
            return nil
        case .bcp195RFC8996:
            return "TLSv1.2"
        }
    }

    private static func preparedTLSOptions(
        for tls: DicomTLSConfiguration,
        role: DicomTLSRole
    ) throws -> (options: NWProtocolTLS.Options, context: DicomAppliedTLSContext) {
        #if canImport(Security)
        let options = NWProtocolTLS.Options()
        if role == .client, let serverName = tls.serverName {
            serverName.withCString {
                sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, $0)
            }
        }
        if let version = minimumTLSProtocolVersion(for: tls.securityProfile) {
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, version)
        }
        let trustedCertificates = try trustAnchors(from: tls.material)
        let verifiesPeer: Bool
        let peerAuthenticationRequired: Bool
        switch (role, tls.clientCertificatePolicy) {
        case (.client, _):
            verifiesPeer = !trustedCertificates.isEmpty
            peerAuthenticationRequired = true
        case (.server, nil):
            verifiesPeer = !trustedCertificates.isEmpty
            peerAuthenticationRequired = !trustedCertificates.isEmpty
        case (.server, .notRequested?):
            verifiesPeer = false
            peerAuthenticationRequired = false
        case (.server, .required?):
            // A server that verifies callers needs something to verify them
            // against; without anchors it would accept any certificate.
            guard !trustedCertificates.isEmpty else {
                throw DicomNetworkError.tlsConfigurationInvalid(
                    "Verifying callers' certificates needs a trust store of the certificates to accept."
                )
            }
            verifiesPeer = true
            peerAuthenticationRequired = true
        }
        sec_protocol_options_set_peer_authentication_required(
            options.securityProtocolOptions,
            peerAuthenticationRequired
        )

        let localIdentity = try localIdentityIfNeeded(from: tls.material)
        var protocolIdentity: sec_identity_t?
        if let identity = localIdentity.identity {
            if localIdentity.certificates.isEmpty {
                protocolIdentity = sec_identity_create(identity)
            } else {
                protocolIdentity = sec_identity_create_with_certificates(identity, localIdentity.certificates as CFArray)
            }
            guard let protocolIdentity else {
                throw DicomNetworkError.tlsConfigurationInvalid("Unable to create protocol TLS identity.")
            }
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, protocolIdentity)
        }


        if verifiesPeer {
            let queue = DispatchQueue(label: "DicomTLSOptionsFactory.trust")
            let serverName = tls.serverName
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let anchors = trustedCertificates as CFArray
                let setAnchorsStatus = SecTrustSetAnchorCertificates(trust, anchors)
                let setOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
                let policy = role == .client
                    ? SecPolicyCreateSSL(true, serverName as CFString?)
                    : SecPolicyCreateSSL(false, nil)
                let setPolicyStatus = SecTrustSetPolicies(trust, policy)
                guard setAnchorsStatus == errSecSuccess,
                      setOnlyStatus == errSecSuccess,
                      setPolicyStatus == errSecSuccess else {
                    complete(false)
                    return
                }
                var error: CFError?
                complete(SecTrustEvaluateWithError(trust, &error))
            }, queue)
        }

        let context = DicomAppliedTLSContext(
            role: role,
            serverName: tls.serverName,
            hasLocalIdentity: localIdentity.identity != nil,
            trustedCertificateCount: trustedCertificates.count,
            securityProfile: tls.securityProfile,
            minimumProtocolVersionName: minimumTLSProtocolVersionName(for: tls.securityProfile),
            peerAuthenticationRequired: peerAuthenticationRequired,
            protocolIdentity: protocolIdentity
        )

        return (options, context)
        #else
        throw DicomNetworkError.tlsConfigurationInvalid(
            "Security.framework is not available for TLS configuration."
        )
        #endif
    }

    #if canImport(Security)
    private static func minimumTLSProtocolVersion(for profile: DicomTLSSecurityProfile) -> tls_protocol_version_t? {
        switch profile {
        case .none:
            return nil
        case .bcp195RFC8996:
            return .TLSv12
        }
    }

    private static func trustAnchors(from material: DicomTLSMaterial?) throws -> [SecCertificate] {
        guard let material else { return [] }
        let paths = ([material.trustStorePath] + material.trustedCertificatePaths)
            .compactMap { $0 }
        var anchors: [SecCertificate] = []
        for path in paths {
            anchors.append(contentsOf: try certificates(at: path, purpose: "TLS trust store"))
        }
        return anchors
    }

    private static func certificates(at path: String, purpose: String) throws -> [SecCertificate] {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw DicomNetworkError.tlsConfigurationInvalid("\(purpose) is not readable: \(path)")
        }
        guard !data.isEmpty else {
            throw DicomNetworkError.tlsConfigurationInvalid("\(purpose) is empty: \(path)")
        }
        let derBlobs = try certificateDERBlobs(from: data, path: path)
        let certificates = derBlobs.compactMap {
            SecCertificateCreateWithData(nil, $0 as CFData)
        }
        guard certificates.count == derBlobs.count, !certificates.isEmpty else {
            throw DicomNetworkError.tlsConfigurationInvalid("\(purpose) does not contain a valid certificate: \(path)")
        }
        return certificates
    }

    private static func certificateDERBlobs(from data: Data, path: String) throws -> [Data] {
        guard let pem = String(data: data, encoding: .utf8),
              pem.contains("-----BEGIN CERTIFICATE-----") else {
            return [data]
        }
        var blobs: [Data] = []
        var searchStart = pem.startIndex
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        while let begin = pem.range(of: beginMarker, range: searchStart..<pem.endIndex),
              let end = pem.range(of: endMarker, range: begin.upperBound..<pem.endIndex) {
            let encoded = pem[begin.upperBound..<end.lowerBound]
                .filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: String(encoded)) else {
                throw DicomNetworkError.tlsConfigurationInvalid("Invalid PEM certificate block: \(path)")
            }
            blobs.append(der)
            searchStart = end.upperBound
        }
        guard !blobs.isEmpty else {
            throw DicomNetworkError.tlsConfigurationInvalid("No PEM certificates found: \(path)")
        }
        return blobs
    }
    #endif

    #if canImport(Security)
    private static func localIdentityIfNeeded(
        from material: DicomTLSMaterial?
    ) throws -> (identity: SecIdentity?, certificates: [SecCertificate]) {
        guard let material else { return (nil, []) }
        if let data = material.pkcs12Data {
            var items: CFArray?
            let options: [String: Any] = [
                kSecImportExportPassphrase as String: material.pkcs12Password ?? "",
                kSecImportToMemoryOnly as String: true
            ]
            let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
            guard status == errSecSuccess,
                  let imported = items as? [[String: Any]],
                  let first = imported.first,
                  let value = first[kSecImportItemIdentity as String],
                  CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
                throw DicomNetworkError.tlsConfigurationInvalid("PKCS#12 identity import failed (\(status)).")
            }
            let identity = value as! SecIdentity
            let chain = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []
            return (identity, Array(chain.dropFirst()))
        }
        #if os(macOS)
        return try separateLocalIdentityIfNeeded(from: material)
        #else
        if material.certificatePath != nil || material.privateKeyPath != nil || material.privateKeyData != nil {
            throw DicomNetworkError.tlsConfigurationInvalid("Use PKCS#12 identity material on this platform.")
        }
        return (nil, [])
        #endif
    }
    #endif

    #if canImport(Security) && os(macOS)
    private static func separateLocalIdentityIfNeeded(
        from material: DicomTLSMaterial?
    ) throws -> (identity: SecIdentity?, certificates: [SecCertificate]) {
        guard let material else { return (nil, []) }
        let hasCertificate = material.certificatePath != nil
        let hasPrivateKey = material.privateKeyPath != nil || material.privateKeyData != nil
        guard hasCertificate || hasPrivateKey else { return (nil, []) }
        guard let certificatePath = material.certificatePath else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS certificate path is missing.")
        }
        guard hasPrivateKey else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS private key path is missing.")
        }
        let certificates = try certificates(at: certificatePath, purpose: "TLS certificate")
        guard let certificate = certificates.first else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS certificate import did not produce a certificate: \(certificatePath)")
        }
        let privateKey: SecKey
        if let privateKeyData = material.privateKeyData {
            privateKey = try importPrivateKey(data: privateKeyData, fileName: "private-key.pem")
        } else if let privateKeyPath = material.privateKeyPath {
            let privateKeyData: Data
            do {
                privateKeyData = try Data(contentsOf: URL(fileURLWithPath: privateKeyPath))
            } catch {
                throw DicomNetworkError.tlsConfigurationInvalid("TLS private key is not readable: \(privateKeyPath)")
            }
            privateKey = try importPrivateKey(
                data: privateKeyData,
                fileName: (privateKeyPath as NSString).lastPathComponent,
                path: privateKeyPath
            )
        } else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS private key path is missing.")
        }
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw DicomNetworkError.tlsConfigurationInvalid(
                "TLS private key does not match certificate or identity could not be created."
            )
        }
        return (identity, Array(certificates.dropFirst()))
    }

    private static func importPrivateKey(data: Data, fileName: String, path: String? = nil) throws -> SecKey {
        guard !data.isEmpty else {
            let reason = path.map { "TLS private key is empty: \($0)" }
                ?? "TLS private key data is empty."
            throw DicomNetworkError.tlsConfigurationInvalid(reason)
        }
        var format = SecExternalFormat.formatUnknown
        var itemType = SecExternalItemType.itemTypeUnknown
        var items: CFArray?
        var keyParameters = SecItemImportExportKeyParameters(
            version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION),
            flags: SecKeyImportExportFlags(),
            passphrase: nil,
            alertTitle: nil,
            alertPrompt: nil,
            accessRef: nil,
            keyUsage: nil,
            keyAttributes: nil
        )
        let status = withUnsafePointer(to: &keyParameters) {
            SecItemImport(
                data as CFData,
                fileName as CFString,
                &format,
                &itemType,
                SecItemImportExportFlags(),
                $0,
                nil,
                &items
            )
        }
        guard status == errSecSuccess, let items else {
            let reason = path.map { "TLS private key import failed: \($0)" }
                ?? "TLS private key data import failed."
            throw DicomNetworkError.tlsConfigurationInvalid(reason)
        }
        for item in items as [AnyObject] where CFGetTypeID(item) == SecKeyGetTypeID() {
            return unsafeDowncast(item, to: SecKey.self)
        }
        let reason = path.map { "TLS private key import did not produce a key: \($0)" }
            ?? "TLS private key data did not produce a key."
        throw DicomNetworkError.tlsConfigurationInvalid(reason)
    }
    #endif
}
#endif

#if canImport(Network)
/// Public Network.framework facade; policy and identity handling remain in the shared factory.
public enum DicomTLSNetworkParameters {
    public static func client(_ configuration: DicomTLSConfiguration, serverName: String?) throws -> NWParameters {
        var configuration = configuration
        if let serverName { configuration.serverName = serverName }
        return try DicomTLSOptionsFactory.preparedParameters(for: configuration, role: .client).parameters
    }

    public static func server(_ configuration: DicomTLSConfiguration) throws -> NWParameters {
        try DicomTLSOptionsFactory.preparedParameters(for: configuration, role: .server).parameters
    }
}
#endif
