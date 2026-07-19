import Foundation

final class DicomRetrievedDataSetCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDataSet: DicomDataSet?
    private var didParse: Bool

    init(dataSet: DicomDataSet?) {
        storedDataSet = dataSet
        didParse = dataSet != nil
    }

    func value(data: Data, transferSyntax: DicomTransferSyntax) -> DicomDataSet? {
        lock.lock()
        defer { lock.unlock() }
        if !didParse {
            storedDataSet = try? DicomDataSetParser.dataSet(from: data, transferSyntax: transferSyntax)
            didParse = true
        }
        return storedDataSet
    }

    func set(_ dataSet: DicomDataSet?) {
        lock.lock()
        storedDataSet = dataSet
        didParse = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storedDataSet = nil
        didParse = false
        lock.unlock()
    }
}
