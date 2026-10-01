import XCTest
@testable import DicomCore

final class DicomPixelDataDescriptorTests: XCTestCase {
    func test_overflowingSampleWidth_rejectsLayoutWithoutTrapping() {
        XCTAssertNil(DicomPixelDataDescriptor(
            rows: 1, columns: 1, numberOfFrames: 1,
            bitsAllocated: Int.max, bitsStored: 1, highBit: 0,
            pixelRepresentation: 0, samplesPerPixel: 1, planarConfiguration: nil,
            photometricInterpretation: "MONOCHROME2", pixelDataOffset: 0
        ))
    }

    func test_overflowingAbsoluteBitRange_rejectsLayoutBeforeFrameAllocation() {
        for offset in [Int.max, Int.max / 8] {
            XCTAssertNil(DicomPixelDataDescriptor(
                rows: 1, columns: 1, numberOfFrames: 2,
                bitsAllocated: 8, bitsStored: 8, highBit: 7,
                pixelRepresentation: 0, samplesPerPixel: 1, planarConfiguration: nil,
                photometricInterpretation: "MONOCHROME2", pixelDataOffset: offset
            ))
        }
    }

    func test_nonByteAlignedSingleBitFrames_trackBitGranularBoundaries() throws {
        let descriptor = try XCTUnwrap(DicomPixelDataDescriptor(
            rows: 1,
            columns: 3,
            numberOfFrames: 2,
            bitsAllocated: 1,
            bitsStored: 1,
            highBit: 0,
            pixelRepresentation: 0,
            samplesPerPixel: 1,
            planarConfiguration: nil,
            photometricInterpretation: "MONOCHROME2",
            pixelDataOffset: 100
        ))

        XCTAssertEqual(descriptor.bitsPerFrame, 3)
        XCTAssertEqual(descriptor.totalPixelBytes, 1)
        XCTAssertEqual(descriptor.frameBitOffsets, [800, 803])
        XCTAssertEqual(descriptor.frameOffsets, [100, 100])
        XCTAssertEqual(descriptor.bitRange(forFrame: 0), 800..<803)
        XCTAssertEqual(descriptor.bitRange(forFrame: 1), 803..<806)
        XCTAssertEqual(descriptor.byteRange(forFrame: 0), 100..<101)
        XCTAssertEqual(descriptor.byteRange(forFrame: 1), 100..<101)
    }

    func testSingleFrame16BitUnsignedDescriptorAndFrameAccess() throws {
        let pixelBytes = littleEndianBytes(values: [UInt16(1), UInt16(2), UInt16(3), UInt16(4)])
        let url = try makeTemporaryDICOM(
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15,
            pixelRepresentation: 0,
            samplesPerPixel: 1,
            width: 2,
            height: 2,
            numberOfFrames: 1,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let descriptor = try XCTUnwrap(decoder.pixelDataDescriptor)

        XCTAssertTrue(decoder.pixelsNotLoaded)
        XCTAssertEqual(descriptor.rows, 2)
        XCTAssertEqual(descriptor.columns, 2)
        XCTAssertEqual(descriptor.numberOfFrames, 1)
        XCTAssertEqual(descriptor.bitsAllocated, 16)
        XCTAssertEqual(descriptor.bitsStored, 16)
        XCTAssertEqual(descriptor.highBit, 15)
        XCTAssertEqual(descriptor.pixelRepresentation, 0)
        XCTAssertEqual(descriptor.samplesPerPixel, 1)
        XCTAssertNil(descriptor.planarConfiguration)
        XCTAssertEqual(descriptor.photometricInterpretation, "MONOCHROME2")
        XCTAssertEqual(descriptor.bytesPerSample, 2)
        XCTAssertEqual(descriptor.bytesPerFrame, pixelBytes.count)
        XCTAssertEqual(descriptor.totalPixelBytes, pixelBytes.count)
        XCTAssertEqual(descriptor.frameOffsets, [descriptor.pixelDataOffset])

        let frame = try XCTUnwrap(decoder.getFrame(0))
        XCTAssertEqual(frame.index, 0)
        XCTAssertEqual(frame.data, Data(pixelBytes))
        XCTAssertEqual(frame.byteRange, descriptor.byteRange(forFrame: 0))
        XCTAssertTrue(decoder.pixelsNotLoaded)
    }

    func testMultiFrame8BitUnsignedFrameRangeAccess() throws {
        let pixelBytes = Array(UInt8(0)..<UInt8(12))
        let url = try makeTemporaryDICOM(
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7,
            pixelRepresentation: 0,
            samplesPerPixel: 1,
            width: 2,
            height: 2,
            numberOfFrames: 3,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let descriptor = try XCTUnwrap(decoder.pixelDataDescriptor)

        XCTAssertEqual(descriptor.numberOfFrames, 3)
        XCTAssertEqual(descriptor.bytesPerSample, 1)
        XCTAssertEqual(descriptor.bytesPerFrame, 4)
        XCTAssertEqual(descriptor.totalPixelBytes, 12)
        XCTAssertEqual(descriptor.frameOffsets, [
            descriptor.pixelDataOffset,
            descriptor.pixelDataOffset + 4,
            descriptor.pixelDataOffset + 8
        ])
        XCTAssertEqual(decoder.getFrame(1)?.data, Data([4, 5, 6, 7]))

        let frames = try XCTUnwrap(decoder.getFrames(1..<3))
        XCTAssertEqual(frames.map(\.index), [1, 2])
        XCTAssertEqual(frames.map(\.data), [Data([4, 5, 6, 7]), Data([8, 9, 10, 11])])

        let allFrames = try XCTUnwrap(decoder.getAllFrames())
        XCTAssertEqual(allFrames.map(\.index), [0, 1, 2])
        XCTAssertEqual(allFrames.map(\.data), [
            Data([0, 1, 2, 3]),
            Data([4, 5, 6, 7]),
            Data([8, 9, 10, 11])
        ])
        XCTAssertTrue(decoder.pixelsNotLoaded)
    }

    func testMultiFrame16BitSignedDescriptor() throws {
        let pixelBytes = littleEndianBytes(values: [Int16(-1), Int16(2), Int16(-3), Int16(4)])
        let url = try makeTemporaryDICOM(
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15,
            pixelRepresentation: 1,
            samplesPerPixel: 1,
            width: 2,
            height: 1,
            numberOfFrames: 2,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let descriptor = try XCTUnwrap(decoder.pixelDataDescriptor)

        XCTAssertTrue(descriptor.isSigned)
        XCTAssertEqual(descriptor.numberOfFrames, 2)
        XCTAssertEqual(descriptor.bytesPerFrame, 4)
        XCTAssertEqual(decoder.getFrame(0)?.data, Data(littleEndianBytes(values: [Int16(-1), Int16(2)])))
        XCTAssertEqual(decoder.getFrame(1)?.data, Data(littleEndianBytes(values: [Int16(-3), Int16(4)])))
    }

    func testSingleFrame8BitSignedDescriptor() throws {
        let pixelBytes: [UInt8] = [0x80, 0x7F]
        let url = try makeTemporaryDICOM(
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7,
            pixelRepresentation: 1,
            samplesPerPixel: 1,
            width: 2,
            height: 1,
            numberOfFrames: 1,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let descriptor = try XCTUnwrap(decoder.pixelDataDescriptor)

        XCTAssertTrue(descriptor.isSigned)
        XCTAssertEqual(descriptor.bytesPerFrame, 2)
        XCTAssertEqual(decoder.getFrame(0)?.data, Data(pixelBytes))
    }

    func testFrameAccessRejectsInvalidRanges() throws {
        let url = try makeTemporaryDICOM(
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7,
            pixelRepresentation: 0,
            samplesPerPixel: 1,
            width: 2,
            height: 2,
            numberOfFrames: 2,
            pixelBytes: Array(UInt8(0)..<UInt8(8))
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertNil(decoder.getFrame(-1))
        XCTAssertNil(decoder.getFrame(2))
        XCTAssertNil(decoder.getFrames(1..<1))
        XCTAssertNil(decoder.getFrames(0..<3))
    }

    func testDescriptorRejectsTruncatedMultiframePayload() throws {
        let url = try makeTemporaryDICOM(
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15,
            pixelRepresentation: 0,
            samplesPerPixel: 1,
            width: 2,
            height: 2,
            numberOfFrames: 2,
            pixelBytes: littleEndianBytes(values: [UInt16(1), UInt16(2), UInt16(3), UInt16(4)])
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertNil(decoder.pixelDataDescriptor)
        XCTAssertNil(decoder.getFrame(0))
    }

    private func makeTemporaryDICOM(
        bitsAllocated: UInt16,
        bitsStored: UInt16,
        highBit: UInt16,
        pixelRepresentation: UInt16,
        samplesPerPixel: UInt16,
        width: UInt16,
        height: UInt16,
        numberOfFrames: Int,
        pixelBytes: [UInt8]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixel_descriptor_\(UUID().uuidString).dcm")
        var data = Data()
        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        appendUS(&data, group: 0x0028, element: 0x0010, value: height)
        appendUS(&data, group: 0x0028, element: 0x0011, value: width)
        appendUS(&data, group: 0x0028, element: 0x0002, value: samplesPerPixel)
        appendCS(&data, group: 0x0028, element: 0x0004, value: samplesPerPixel == 3 ? "RGB" : "MONOCHROME2")
        if numberOfFrames > 1 {
            appendIS(&data, group: 0x0028, element: 0x0008, value: String(numberOfFrames))
        }
        appendUS(&data, group: 0x0028, element: 0x0100, value: bitsAllocated)
        appendUS(&data, group: 0x0028, element: 0x0101, value: bitsStored)
        appendUS(&data, group: 0x0028, element: 0x0102, value: highBit)
        appendUS(&data, group: 0x0028, element: 0x0103, value: pixelRepresentation)

        data.append(contentsOf: [0xE0, 0x7F, 0x10, 0x00])
        data.append(contentsOf: bitsAllocated == 8 ? Array("OB".utf8) : Array("OW".utf8))
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: withUnsafeBytes(of: UInt32(pixelBytes.count).littleEndian) { Array($0) })
        data.append(contentsOf: pixelBytes)

        try data.write(to: url)
        return url
    }

    private func appendUS(_ data: inout Data, group: UInt16, element: UInt16, value: UInt16) {
        data.append(contentsOf: withUnsafeBytes(of: group.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: element.littleEndian) { Array($0) })
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private func appendCS(_ data: inout Data, group: UInt16, element: UInt16, value: String) {
        appendString(data: &data, group: group, element: element, vr: "CS", value: value)
    }

    private func appendIS(_ data: inout Data, group: UInt16, element: UInt16, value: String) {
        appendString(data: &data, group: group, element: element, vr: "IS", value: value)
    }

    private func appendString(data: inout Data, group: UInt16, element: UInt16, vr: String, value: String) {
        var bytes = Array(value.utf8)
        if bytes.count % 2 != 0 {
            bytes.append(0x20)
        }
        data.append(contentsOf: withUnsafeBytes(of: group.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: element.littleEndian) { Array($0) })
        data.append(contentsOf: vr.utf8)
        data.append(UInt8(bytes.count & 0xFF))
        data.append(UInt8((bytes.count >> 8) & 0xFF))
        data.append(contentsOf: bytes)
    }

    private func littleEndianBytes(values: [UInt16]) -> [UInt8] {
        values.flatMap { value in
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
    }

    private func littleEndianBytes(values: [Int16]) -> [UInt8] {
        values.flatMap { value in
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
    }
}
