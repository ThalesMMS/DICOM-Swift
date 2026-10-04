import Foundation

/// Reads the segments of a `DicomWebHTTPRequestBody` one after the other, opening each file only when the stream
/// reaches it, so the body is never held whole. URLSession reads it synchronously from its own thread.
///
/// CFNetwork schedules a request body stream through private CFReadStream hooks that a Foundation subclass does not
/// implement. The three `_…CFRunLoop`/`_setCFClientFlags` methods answer them: no run-loop scheduling and no client
/// callbacks, so CFNetwork reads the stream directly, as it does for any stream that is always readable.
final class DicomWebSegmentedInputStream: InputStream {
    private let segments: [DicomWebHTTPRequestBody.Segment]
    private var index = 0
    private var offset = 0
    private var handle: FileHandle?
    private var status: Stream.Status = .notOpen
    private var failure: Error?
    private weak var streamDelegate: StreamDelegate?

    init(segments: [DicomWebHTTPRequestBody.Segment]) {
        self.segments = segments
        super.init(data: Data())
    }

    override var streamStatus: Stream.Status { status }
    override var streamError: Error? { failure }
    override var hasBytesAvailable: Bool { status == .open }

    override var delegate: StreamDelegate? {
        get { streamDelegate }
        set { streamDelegate = newValue }
    }

    override func open() {
        if status == .notOpen { status = .open }
    }

    override func close() {
        try? handle?.close()
        handle = nil
        status = .closed
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength length: Int) -> Int {
        guard status == .open else { return status == .atEnd ? 0 : -1 }
        var written = 0
        while written < length, index < segments.count {
            switch segments[index] {
            case .data(let data):
                let count = min(length - written, data.count - offset)
                let start = data.index(data.startIndex, offsetBy: offset)
                data.copyBytes(to: buffer + written, from: start..<data.index(start, offsetBy: count))
                written += count
                offset += count
                if offset == data.count { advance() }
            case .file(let url, let fileLength):
                guard offset < fileLength else {
                    advance()
                    continue
                }
                do {
                    if handle == nil { handle = try FileHandle(forReadingFrom: url) }
                } catch {
                    return fail(error)
                }
                let count = Darwin.read(handle!.fileDescriptor, buffer + written, min(length - written, fileLength - offset))
                guard count > 0 else {
                    // A file that ends before its declared length would leave the Content-Length unmet.
                    return fail(count < 0 ? POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                                          : CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]))
                }
                written += count
                offset += count
                if offset == fileLength { advance() }
            }
        }
        if written == 0 { status = .atEnd }
        return written
    }

    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                            length: UnsafeMutablePointer<Int>) -> Bool { false }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }

    @objc(_scheduleInCFRunLoop:forMode:)
    func scheduleInCFRunLoop(_ runLoop: CFRunLoop?, forMode mode: CFRunLoopMode?) {}

    @objc(_unscheduleFromCFRunLoop:forMode:)
    func unscheduleFromCFRunLoop(_ runLoop: CFRunLoop?, forMode mode: CFRunLoopMode?) {}

    @objc(_setCFClientFlags:callback:context:)
    func setCFClientFlags(_ flags: CFOptionFlags, callback: CFReadStreamClientCallBack?,
                          context: UnsafeMutablePointer<CFStreamClientContext>?) -> Bool { false }

    private func advance() {
        try? handle?.close()
        handle = nil
        index += 1
        offset = 0
    }

    private func fail(_ error: Error) -> Int {
        failure = error
        status = .error
        return -1
    }
}
