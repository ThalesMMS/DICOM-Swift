import DicomCore
import Foundation

func decodeFirstFrame(_ data: Data) async throws -> DicomCodecArtifactResult {
    try await DicomCodecWorkflowEngine().decode(data, frameIndexes: [0])
}
