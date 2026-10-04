import Foundation

/// A transport that sends `DicomWebHTTPRequest.streamedBody`, reading it again from the start whenever the body must
/// be sent again. `DicomWebClient` hands a STOW-RS body to such a transport as it is, straight from the stored files;
/// for any other transport it first writes the body to a temporary file and sends that file as `bodyFileURL`.
public protocol DicomWebStreamedBodyTransport: DicomWebHTTPTransport {}
