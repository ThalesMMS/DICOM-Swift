/// A route whose metadata and encoding intent have been qualified without decoding frames.
enum DicomTranscodeExecutionRoute {
    case carryDataset(DicomCompressedFrameDescriptor?)
    case decompress
    case jpegLS(DicomCompressedFrameDescriptor)
    case jpeg2000(DicomCompressedFrameDescriptor)
    /// JPEG 2000 Part 2 Multi-component: the frames become the components of collection codestreams (#2331).
    case jpeg2000Part2(DicomCompressedFrameDescriptor)
    case jpegXL(DicomCompressedFrameDescriptor)
    case jpegRecompression(DicomCompressedFrameDescriptor)
    case jpegReconstruction(DicomCompressedFrameDescriptor)
    case rle(DicomCompressedFrameDescriptor)
    case deflatedFrames(DicomCompressedFrameDescriptor)
    case jpeg(DicomCompressedFrameDescriptor)

    var outputDescriptor: DicomCompressedFrameDescriptor? {
        switch self {
        case .carryDataset(let descriptor): return descriptor
        case .decompress: return nil
        case .jpegLS(let descriptor), .jpeg2000(let descriptor), .jpeg2000Part2(let descriptor), .jpegXL(let descriptor),
             .jpegRecompression(let descriptor), .jpegReconstruction(let descriptor), .rle(let descriptor),
             .deflatedFrames(let descriptor), .jpeg(let descriptor): return descriptor
        }
    }

    var requiresDecodedSource: Bool {
        switch self {
        case .carryDataset, .jpegRecompression, .jpegReconstruction: return false
        case .decompress, .jpegLS, .jpeg2000, .jpeg2000Part2, .jpegXL, .rle, .deflatedFrames, .jpeg: return true
        }
    }
}
