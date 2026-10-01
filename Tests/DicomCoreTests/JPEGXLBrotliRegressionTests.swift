import Foundation
import XCTest
@testable import DicomJPEGXL

final class JPEGXLBrotliRegressionTests: XCTestCase {
    func test_dictionaryWordBeyondTheData_returnsAnEmptyBody() {
        let end = BrotliStaticDictionary.data.count
        for offset in [end, end + 1] {
            XCTAssertEqual(BrotliStaticDictionary.transformWord(wordOffset: offset, length: 4, transformIdx: 0), [])
        }
    }

    func test_emptyFinalMetadataBlock_matchesTheReferenceDecoder() throws {
        // WBITS=16, ISLAST=1, ISLASTEMPTY=0, MNIBBLES=0, MSKIPBYTES=0.
        // Reference Brotli (Node zlib.brotliDecompressSync) accepts this stream.
        XCTAssertEqual(try BrotliDecoder.decode(Data([0x1A])), Data())
    }
    func test_metadata_isSkippedBetweenUncompressedBlocks() throws {
        var writer = BitWriter()
        writer.writeBit(false) // WBITS = 16
        appendMetadata([], to: &writer)
        appendUncompressed([65, 66], to: &writer)
        appendMetadata([97, 98, 99], to: &writer)
        appendUncompressed([67], to: &writer)
        writer.writeBit(true)
        writer.writeBit(true) // ISLASTEMPTY
        let bytes = writer.finishToData()
        let slice = (Data([255]) + bytes).dropFirst()
        XCTAssertEqual(try BrotliDecoder.decode(slice), Data([65, 66, 67]))
    }

    func test_metadata_rejectsNonzeroPaddingAndNoncanonicalLength() {
        for noncanonical in [false, true] {
            var writer = BitWriter()
            writer.writeBit(false) // ISLAST
            writer.write(bits: 2, value: 3)
            writer.writeBit(false) // reserved
            writer.write(bits: 2, value: noncanonical ? 2 : 0)
            if noncanonical { writer.write(bits: 16, value: 0) }
            else { writer.write(bits: 2, value: 3) }
            var reader = BitReader(writer.finishToData())
            XCTAssertThrowsError(try BrotliMetaBlockReader.readMetaBlockHeader(from: &reader))
        }
    }

    func test_literalContextMap_isRefusedBeforeReadingDistanceTreeCount() {
        var writer = BitWriter()
        writer.write(bits: 11, value: 0) // three block types, NPOSTFIX, NDIRECT, context mode
        writer.writeBit(true)
        writer.write(bits: 3, value: 0) // NTREESL = 2
        let mapStart = writer.bitCount
        writer.write(bits: 8, value: 255) // CMAPL, not NTREESD
        var reader = BitReader(writer.finishToData())
        XCTAssertThrowsError(try BrotliCompressedMetaBlockHeader.read(from: &reader)) { error in
            guard case BrotliError.notImplemented = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(reader.position, mapStart)
    }

    private func appendMetadata(_ bytes: [UInt8], to writer: inout BitWriter) {
        writer.writeBit(false)
        writer.write(bits: 2, value: 3)
        writer.writeBit(false)
        writer.write(bits: 2, value: bytes.isEmpty ? 0 : 1)
        if !bytes.isEmpty { writer.write(bits: 8, value: UInt32(bytes.count - 1)) }
        writer.alignToByte()
        for byte in bytes { writer.write(bits: 8, value: UInt32(byte)) }
    }

    private func appendUncompressed(_ bytes: [UInt8], to writer: inout BitWriter) {
        writer.writeBit(false)
        writer.write(bits: 2, value: 0)
        writer.write(bits: 16, value: UInt32(bytes.count - 1))
        writer.writeBit(true)
        writer.alignToByte()
        for byte in bytes { writer.write(bits: 8, value: UInt32(byte)) }
    }
}
