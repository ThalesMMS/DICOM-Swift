import Foundation

/// Synchronous DIMSE SCU implementation.
///
/// Network I/O, retry backoff, and bandwidth pacing block the calling thread. Callers that bridge
/// this API to Swift concurrency must run it on a dedicated blocking executor rather than a
/// cooperative executor thread.
public struct DicomDIMSEServiceSCU {
    public var configuration: DicomDIMSEConnectionConfiguration
    public var auditLogger: DicomNetworkAuditLogging?
    let circuitBreaker: DicomNetworkCircuitBreaker?
    let transportFactory: (() throws -> DicomAssociationTransport)?
    let operationHandle: DicomDIMSEOperationHandle?
    let associationPool: DicomDIMSEAssociationPool?

    public init(configuration: DicomDIMSEConnectionConfiguration,
                auditLogger: DicomNetworkAuditLogging? = nil,
                circuitBreaker: DicomNetworkCircuitBreaker? = nil,
                operationHandle: DicomDIMSEOperationHandle? = nil) {
        self.init(configuration: configuration,
                  auditLogger: auditLogger,
                  circuitBreaker: circuitBreaker,
                  operationHandle: operationHandle,
                  transportFactory: nil,
                  associationPool: nil)
    }

    init(configuration: DicomDIMSEConnectionConfiguration,
         auditLogger: DicomNetworkAuditLogging? = nil,
         circuitBreaker: DicomNetworkCircuitBreaker? = nil,
         operationHandle: DicomDIMSEOperationHandle? = nil,
         transportFactory: (() throws -> DicomAssociationTransport)? = nil,
         associationPool: DicomDIMSEAssociationPool? = nil) {
        self.configuration = configuration
        self.auditLogger = auditLogger
        self.transportFactory = transportFactory
        self.operationHandle = operationHandle
        self.associationPool = associationPool
        if let circuitBreaker {
            self.circuitBreaker = circuitBreaker
        } else if let policy = configuration.circuitBreakerPolicy {
            self.circuitBreaker = DicomNetworkCircuitBreaker(policy: policy)
        } else {
            self.circuitBreaker = nil
        }
    }

    func replacingRuntimeDependencies(
        auditLogger: DicomNetworkAuditLogging?,
        circuitBreaker: DicomNetworkCircuitBreaker?,
        operationHandle: DicomDIMSEOperationHandle?
    ) -> DicomDIMSEServiceSCU {
        DicomDIMSEServiceSCU(
            configuration: configuration,
            auditLogger: auditLogger,
            circuitBreaker: circuitBreaker,
            operationHandle: operationHandle,
            transportFactory: transportFactory,
            associationPool: associationPool
        )
    }
}
