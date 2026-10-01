import DicomCore
import Foundation

func decodeWithTypedErrors(_ data: Data) async {
    do {
        let result = try await DicomCodecWorkflowEngine().decode(data, frameIndexes: [0])
        print("Decoded \(result.data.count) bytes.")
    } catch let error as DicomCodecWorkflowError {
        switch error.category {
        case .invalidInput, .corruptFrame, .validation:
            print("The input was rejected: \(error.localizedDescription)")
        case .unsupported, .backendUnavailable:
            print("The requested capability is unavailable: \(error.localizedDescription)")
        }
    } catch {
        print("Unexpected failure: \(error.localizedDescription)")
    }
}
