//
//  NvmmTests
//  MessagePackTests.swift
//
//  Covers every MessagePack format branch for both packing (exact bytes) and
//  unpacking (whole buffer and fragmented one byte at a time), plus one-shot
//  integer decoding, RPC framing, and value independence.
//

import XCTest
@testable import Nvmm

final class MessagePackTests: XCTestCase {

    // MARK: Helpers

    private func aBytes(_ count: Int) -> [UInt8] {
        Array(repeating: UInt8(ascii: "a"), count: count)
    }

    /// Asserts the buffer unpacks to `expected`, both whole and fed one byte at
    /// a time (where each incomplete prefix must yield nil).
    private func assertUnpacks(_ packed: [UInt8], to expected: MPValue,
                               file: StaticString = #filePath, line: UInt = #line) {
        var whole = MessagePackUnpacker()
        whole.feed(packed)
        XCTAssertEqual(whole.unpack(), expected, file: file, line: line)
        XCTAssertNil(whole.unpack(), file: file, line: line)

        guard packed.count > 1 else { return }
        var frag = MessagePackUnpacker()
        for byte in packed.dropLast() {
            frag.feed(CollectionOfOne(byte))
            XCTAssertNil(frag.unpack(), file: file, line: line)
        }
        frag.feed(CollectionOfOne(packed[packed.count - 1]))
        XCTAssertEqual(frag.unpack(), expected, file: file, line: line)
        XCTAssertNil(frag.unpack(), file: file, line: line)
    }

    private func assertPacks(_ expected: [UInt8],
                             file: StaticString = #filePath, line: UInt = #line,
                             _ build: (inout MessagePackWriter) -> Void) {
        var writer = MessagePackWriter()
        build(&writer)
        XCTAssertEqual(writer.bytes, expected, file: file, line: line)
    }

    // MARK: Integer round trip

    func testIntegerReinterpretation() {
        XCTAssertEqual(MPInteger(UInt8.max).value(as: UInt8.self), UInt8.max)
        XCTAssertEqual(MPInteger(UInt16.max).value(as: UInt16.self), UInt16.max)
        XCTAssertEqual(MPInteger(UInt32.max).value(as: UInt32.self), UInt32.max)
        XCTAssertEqual(MPInteger(UInt64.max).unsigned, UInt64.max)

        XCTAssertEqual(MPInteger(Int8.min).value(as: Int8.self), Int8.min)
        XCTAssertEqual(MPInteger(Int16.min).value(as: Int16.self), Int16.min)
        XCTAssertEqual(MPInteger(Int32.min).value(as: Int32.self), Int32.min)
        XCTAssertEqual(MPInteger(Int64.min).signed, Int64.min)

        // Sign is not part of the wire type: -1 and UInt64.max share bits.
        XCTAssertEqual(MPInteger(Int64(-1)), MPInteger(UInt64.max))
    }

    // MARK: Unpack scalars

    func testUnpackInvalid() { assertUnpacks([0xc1], to: .invalid) }
    func testUnpackNull() { assertUnpacks([0xc0], to: .null) }
    func testUnpackBoolTrue() { assertUnpacks([0xc3], to: .bool(true)) }
    func testUnpackBoolFalse() { assertUnpacks([0xc2], to: .bool(false)) }

    func testUnpackUnsignedIntegers() {
        assertUnpacks([0x00], to: .int(0))
        assertUnpacks([0x7f], to: .int(127))
        assertUnpacks([0xcc, 0x80], to: .int(128))
        assertUnpacks([0xcd, 0x01, 0x00], to: .int(256))
        assertUnpacks([0xce, 0x00, 0x01, 0x00, 0x00], to: .int(65536))
        assertUnpacks([0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
                      to: .int(4_294_967_296))
    }

    func testUnpackNegativeIntegers() {
        assertUnpacks([0xff], to: .int(-1))
        assertUnpacks([0xe0], to: .int(-32))
        assertUnpacks([0xd0, 0x80], to: .int(-128))
        assertUnpacks([0xd1, 0x80, 0x00], to: .int(-32768))
        assertUnpacks([0xd2, 0x80, 0x00, 0x00, 0x00], to: .int(-2_147_483_648))
        assertUnpacks([0xd3, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00],
                      to: .int(-4_294_967_296))
    }

    func testUnpackFloats() {
        assertUnpacks([0xcb, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], to: .double(0.0))
        assertUnpacks([0xcb, 0xff, 0xef, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
                      to: .double(-Double.greatestFiniteMagnitude))
        assertUnpacks([0xcb, 0x7f, 0xef, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
                      to: .double(Double.greatestFiniteMagnitude))
        assertUnpacks([0xcb, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
                      to: .double(2.2250738585072014e-308))
    }

    func testUnpackFloat32() {
        // 1.0f == 0x3f800000
        assertUnpacks([0xca, 0x3f, 0x80, 0x00, 0x00], to: .double(1.0))
    }

    func testVariableExtensionHeaderWaitsForTypeByte() {
        let cases: [([UInt8], [UInt8])] = [
            ([0xc7, 0x01], [0xfe, 0xaa]),
            ([0xc8, 0x00, 0x01], [0xfe, 0xaa]),
            ([0xc9, 0x00, 0x00, 0x00, 0x01], [0xfe, 0xaa]),
        ]

        for (lengthHeader, remainder) in cases {
            var unpacker = MessagePackUnpacker()
            unpacker.feed(lengthHeader)
            XCTAssertNil(unpacker.unpack())
            XCTAssertFalse(unpacker.failed)

            unpacker.feed(remainder)
            XCTAssertEqual(unpacker.unpack(),
                           .ext(type: -2, payload: [0xaa]))
            XCTAssertFalse(unpacker.failed)
        }
    }

    // MARK: Unpack strings

    func testUnpackStrings() {
        assertUnpacks([0xa0], to: .string(""))
        assertUnpacks([0xa1, 0x61], to: .string("a"))
        assertUnpacks([0xbf] + aBytes(31), to: .string(String(repeating: "a", count: 31)))
        assertUnpacks([0xd9, 0x04] + Array("test".utf8), to: .string("test"))
        assertUnpacks([0xda, 0x00, 0x04] + Array("test".utf8), to: .string("test"))
        assertUnpacks([0xdb, 0x00, 0x00, 0x00, 0x04] + Array("test".utf8), to: .string("test"))
    }

    // MARK: Unpack arrays

    func testUnpackArrays() {
        assertUnpacks([0x90], to: .array([]))
        assertUnpacks([0x91, 0x00], to: .array([.int(0)]))
        assertUnpacks([0x9f] + (0..<15).map { UInt8($0) },
                      to: .array((0..<15).map { .int(MPInteger(Int64($0))) }))
        assertUnpacks([0xdc, 0x00, 0x04, 0x00, 0x01, 0x02, 0x03],
                      to: .array([.int(0), .int(1), .int(2), .int(3)]))
        assertUnpacks([0xdd, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01, 0x02, 0x03],
                      to: .array([.int(0), .int(1), .int(2), .int(3)]))
    }

    func testUnpackArrayRecursive() {
        assertUnpacks([0x91, 0x91, 0x91, 0x91, 0x90],
                      to: .array([.array([.array([.array([.array([])])])])]))
    }

    func testUnpackArrayHeterogeneous() {
        assertUnpacks([0x93, 0x7b, 0xa4] + Array("test".utf8) + [0xc3],
                      to: .array([.int(123), .string("test"), .bool(true)]))
    }

    // MARK: Unpack maps

    func testUnpackMaps() {
        assertUnpacks([0x80], to: .map([]))
        assertUnpacks([0x81, 0xa1, 0x30, 0x00], to: .map([(.string("0"), .int(0))]))
        assertUnpacks([0xde, 0x00, 0x03, 0xa1, 0x30, 0x00, 0xa1, 0x31, 0x01, 0xa1, 0x32, 0x02],
                      to: .map([(.string("0"), .int(0)),
                                (.string("1"), .int(1)),
                                (.string("2"), .int(2))]))
        assertUnpacks([0xdf, 0x00, 0x00, 0x00, 0x03, 0xa1, 0x30, 0x00, 0xa1, 0x31, 0x01, 0xa1, 0x32, 0x02],
                      to: .map([(.string("0"), .int(0)),
                                (.string("1"), .int(1)),
                                (.string("2"), .int(2))]))
    }

    // MARK: Unpack streaming multiple

    func testUnpackMultipleValuesInOneFeed() {
        var unpacker = MessagePackUnpacker()
        unpacker.feed([0xc0, 0xc3, 0x2a]) // null, true, 42
        XCTAssertEqual(unpacker.unpack(), .null)
        XCTAssertEqual(unpacker.unpack(), .bool(true))
        XCTAssertEqual(unpacker.unpack(), .int(42))
        XCTAssertNil(unpacker.unpack())
    }

    // MARK: Pack scalars

    func testPackScalars() {
        assertPacks([0xc0]) { $0.packNil() }
        assertPacks([0xc3]) { $0.packBool(true) }
        assertPacks([0xc2]) { $0.packBool(false) }
    }

    func testPackUnsignedIntegers() {
        assertPacks([0x00]) { $0.packUInt64(0) }
        assertPacks([0x01]) { $0.packUInt64(1) }
        assertPacks([0x7f]) { $0.packUInt64(127) }
        assertPacks([0xcc, 0x80]) { $0.packUInt64(128) }
        assertPacks([0xcc, 0xff]) { $0.packUInt64(255) }
        assertPacks([0xcd, 0x01, 0x00]) { $0.packUInt64(256) }
        assertPacks([0xcd, 0xff, 0xff]) { $0.packUInt64(65535) }
        assertPacks([0xce, 0x00, 0x01, 0x00, 0x00]) { $0.packUInt64(65536) }
        assertPacks([0xce, 0xff, 0xff, 0xff, 0xff]) { $0.packUInt64(4_294_967_295) }
        assertPacks([0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]) { $0.packUInt64(4_294_967_296) }
        assertPacks([0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]) { $0.packUInt64(UInt64.max) }
    }

    func testPackSignedIntegers() {
        assertPacks([0x00]) { $0.packInt64(0) }
        assertPacks([0x01]) { $0.packInt64(1) }
        assertPacks([0xff]) { $0.packInt64(-1) }
        assertPacks([0xe0]) { $0.packInt64(-32) }
        assertPacks([0xd0, 0xdf]) { $0.packInt64(-33) }
        assertPacks([0xd0, 0x80]) { $0.packInt64(-128) }
        assertPacks([0xd1, 0xff, 0x7f]) { $0.packInt64(-129) }
        assertPacks([0xd1, 0x80, 0x00]) { $0.packInt64(-32768) }
        assertPacks([0xd2, 0xff, 0xff, 0x7f, 0xff]) { $0.packInt64(-32769) }
        assertPacks([0xd2, 0x80, 0x00, 0x00, 0x00]) { $0.packInt64(-2_147_483_648) }
        assertPacks([0xd3, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff]) { $0.packInt64(-2_147_483_649) }
        assertPacks([0xd3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) { $0.packInt64(Int64.min) }
    }

    func testPackFloats() {
        assertPacks([0xcb, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) { $0.packDouble(0.0) }
        assertPacks([0xcb, 0xff, 0xef, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]) {
            $0.packDouble(-Double.greatestFiniteMagnitude)
        }
        assertPacks([0xcb, 0x7f, 0xef, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]) {
            $0.packDouble(Double.greatestFiniteMagnitude)
        }
    }

    // MARK: Pack strings

    func testPackStrings() {
        assertPacks([0xa4] + Array("test".utf8)) { $0.packString("test") }
        assertPacks([0xa0]) { $0.packString("") }
        assertPacks([0xa1] + aBytes(1)) { $0.packString(String(repeating: "a", count: 1)) }
        assertPacks([0xbf] + aBytes(31)) { $0.packString(String(repeating: "a", count: 31)) }
        assertPacks([0xd9, 0x20] + aBytes(32)) { $0.packString(String(repeating: "a", count: 32)) }
        assertPacks([0xd9, 0xff] + aBytes(255)) { $0.packString(String(repeating: "a", count: 255)) }
        assertPacks([0xda, 0x01, 0x00] + aBytes(256)) { $0.packString(String(repeating: "a", count: 256)) }
        assertPacks([0xda, 0xff, 0xff] + aBytes(65535)) { $0.packString(String(repeating: "a", count: 65535)) }
        assertPacks([0xdb, 0x00, 0x01, 0x00, 0x00] + aBytes(65536)) {
            $0.packString(String(repeating: "a", count: 65536))
        }
    }

    // MARK: Pack array / map headers

    func testPackArrayHeaders() {
        assertPacks([0x90]) { $0.startArray(0) }
        assertPacks([0x91]) { $0.startArray(1) }
        assertPacks([0x9f]) { $0.startArray(15) }
        assertPacks([0xdc, 0x01, 0x00]) { $0.startArray(256) }
        assertPacks([0xdc, 0xff, 0xff]) { $0.startArray(65535) }
        assertPacks([0xdd, 0x00, 0x01, 0x00, 0x00]) { $0.startArray(65536) }
        assertPacks([0xdd, 0xff, 0xff, 0xff, 0xff]) { $0.startArray(4_294_967_295) }
    }

    func testPackMapHeaders() {
        assertPacks([0x80]) { $0.startMap(0) }
        assertPacks([0x81]) { $0.startMap(1) }
        assertPacks([0x8f]) { $0.startMap(15) }
        assertPacks([0xde, 0x01, 0x00]) { $0.startMap(256) }
        assertPacks([0xde, 0xff, 0xff]) { $0.startMap(65535) }
        assertPacks([0xdf, 0x00, 0x01, 0x00, 0x00]) { $0.startMap(65536) }
        assertPacks([0xdf, 0xff, 0xff, 0xff, 0xff]) { $0.startMap(4_294_967_295) }
    }

    func testPackArrayRecursive() {
        assertPacks([0x91, 0x91, 0x91, 0x91, 0x90]) {
            $0.startArray(1); $0.startArray(1); $0.startArray(1); $0.startArray(1); $0.startArray(0)
        }
    }

    func testPackValueTree() {
        assertPacks([0x93, 0x7b, 0xa4] + Array("test".utf8) + [0xc3]) {
            $0.pack(.array([.int(123), .string("test"), .bool(true)]))
        }
        assertPacks([0x83, 0xa1, 0x30, 0x00, 0xa1, 0x31, 0x01, 0xa1, 0x32, 0x02]) {
            $0.pack(.map([(.string("0"), .int(0)),
                          (.string("1"), .int(1)),
                          (.string("2"), .int(2))]))
        }
    }

    // MARK: One-shot integer

    func testUnpackIntegerOneShot() {
        func check(_ packed: [UInt8], _ expected: MPInteger,
                   file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(unpackInteger(packed), expected, file: file, line: line)
            XCTAssertNil(unpackInteger(Array(packed.dropLast())), file: file, line: line)
            XCTAssertNil(unpackInteger(packed + [0x00]), file: file, line: line)
        }
        check([0x00], MPInteger(0))
        check([0x7f], MPInteger(127))
        check([0xcc, 0x80], MPInteger(128))
        check([0xcd, 0x01, 0x00], MPInteger(256))
        check([0xce, 0x00, 0x01, 0x00, 0x00], MPInteger(65536))
        check([0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00], MPInteger(4_294_967_296))
        check([0xff], MPInteger(-1))
        check([0xe0], MPInteger(-32))
        check([0xd0, 0x80], MPInteger(-128))
        check([0xd1, 0x80, 0x00], MPInteger(-32768))
        check([0xd2, 0x80, 0x00, 0x00, 0x00], MPInteger(-2_147_483_648))
        check([0xd3, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00], MPInteger(-4_294_967_296))
    }

    func testUnpackIntegerRejectsNonIntegers() {
        XCTAssertNil(unpackInteger([]))
        XCTAssertNil(unpackInteger([0xc0]))          // null
        XCTAssertNil(unpackInteger([0xa1, 0x61]))    // string
    }

    // MARK: RPC framing

    func testEncodeNotification() {
        var writer = MessagePackWriter()
        writer.encodeNotification(method: "redraw", arguments: [.int(1), .string("x")])
        var unpacker = MessagePackUnpacker()
        unpacker.feed(writer.bytes)
        XCTAssertEqual(unpacker.unpack(),
                       .array([.int(2), .string("redraw"), .array([.int(1), .string("x")])]))
        XCTAssertNil(unpacker.unpack())
    }

    func testEncodeRequest() {
        var writer = MessagePackWriter()
        writer.encodeRequest(id: 7, method: "nvim_eval", arguments: [.string("1+1")])
        var unpacker = MessagePackUnpacker()
        unpacker.feed(writer.bytes)
        XCTAssertEqual(unpacker.unpack(),
                       .array([.int(0), .int(7), .string("nvim_eval"), .array([.string("1+1")])]))
    }

    func testEncodeResponse() {
        var writer = MessagePackWriter()
        writer.encodeResponse(id: 7, error: .null, result: .int(2))
        var unpacker = MessagePackUnpacker()
        unpacker.feed(writer.bytes)
        XCTAssertEqual(unpacker.unpack(), .array([.int(1), .int(7), .null, .int(2)]))
    }

    func testRedrawEventsStreamWithoutRetainingTheBatch() {
        let events: [MPValue] = [
            .array([.string("busy_start"), .array([])]),
            .array([.string("flush"), .array([])]),
        ]
        var writer = MessagePackWriter()
        writer.encodeNotification(method: "redraw", arguments: events)

        var received: [MPValue] = []
        var unpacker = MessagePackUnpacker()
        var message: MPValue?
        for byte in writer.bytes {
            unpacker.feed(CollectionOfOne(byte))
            if let value = unpacker.unpack(redrawItem: {
                if case .event(let event) = $0 { received.append(event) }
            }) {
                message = value
            }
        }

        XCTAssertEqual(received, events)
        XCTAssertEqual(message, .array([.int(2), .string("redraw"), .array([])]))
    }

    func testMalformedRedrawEnvelopeDoesNotStreamEvents() {
        let event = MPValue.array([.string("flush"), .array([])])
        var writer = MessagePackWriter()
        writer.startArray(4)
        writer.packUInt64(2)
        writer.packString("redraw")
        writer.pack(.array([event]))
        writer.packNil()

        var streamedCount = 0
        var unpacker = MessagePackUnpacker()
        unpacker.feed(writer.bytes)
        let message = unpacker.unpack(redrawItem: { _ in streamedCount += 1 })

        XCTAssertEqual(streamedCount, 0)
        XCTAssertEqual(
            message,
            .array([.int(2), .string("redraw"), .array([event]), .null]))
    }

    func testOrdinaryUnpackRetainsRedrawEvents() {
        let event = MPValue.array([.string("flush"), .array([])])
        var writer = MessagePackWriter()
        writer.encodeNotification(method: "redraw", arguments: [event])

        var unpacker = MessagePackUnpacker()
        unpacker.feed(writer.bytes)
        XCTAssertEqual(unpacker.unpack(),
                       .array([.int(2), .string("redraw"), .array([event])]))
    }

    func testGridLineStreamsCellsWithoutBuildingAnEvent() {
        let cells: [MPValue] = [
            .array([.string("a"), .int(0)]),
            .array([.string("b")]),
        ]
        let event: MPValue = .array([
            .string("grid_line"),
            .array([.int(1), .int(2), .int(3), .array(cells), .bool(false)]),
        ])
        var writer = MessagePackWriter()
        writer.encodeNotification(method: "redraw", arguments: [event])

        var starts: [[MPValue]] = []
        var receivedCells: [MPValue] = []
        var ends: [MPValue] = []
        var genericEvents: [MPValue] = []
        var unpacker = MessagePackUnpacker()
        for byte in writer.bytes {
            unpacker.feed(CollectionOfOne(byte))
            _ = unpacker.unpack(redrawItem: {
                switch $0 {
                case .event(let value): genericEvents.append(value)
                case .gridLineStart(let prefix): starts.append(prefix)
                case .gridLineCell(let cell): receivedCells.append(cell)
                case .gridLineEnd(let wrap): ends.append(wrap)
                }
            })
        }

        XCTAssertEqual(starts, [[.int(1), .int(2), .int(3)]])
        XCTAssertEqual(receivedCells, cells)
        XCTAssertEqual(ends, [.bool(false)])
        XCTAssertTrue(genericEvents.isEmpty)
        XCTAssertFalse(unpacker.failed)
    }

    func testGridLineCellTextLimitFailsBeforeRetainingTheCell() {
        let text = String(repeating: "x", count: 25)
        let event: MPValue = .array([
            .string("grid_line"),
            .array([.int(1), .int(0), .int(0),
                    .array([.array([.string(text), .int(0)])]),
                    .bool(false)]),
        ])
        var writer = MessagePackWriter()
        writer.encodeNotification(method: "redraw", arguments: [event])

        var unpacker = MessagePackUnpacker()
        unpacker.feed(writer.bytes)
        XCTAssertNil(unpacker.unpack(redrawItem: { _ in }))
        XCTAssertTrue(unpacker.failed)
    }

    // MARK: Value independence

    func testDecodedValuesAreIndependent() {
        // Swift value semantics: a decoded tree owns its storage and is
        // unaffected by later mutation of the source buffer.
        var buffer: [UInt8] = [0x81, 0xa5] + Array("items".utf8) +
            [0x92, 0xa5] + Array("value".utf8) + [0xd0, 0xd6] // -42
        var unpacker = MessagePackUnpacker()
        unpacker.feed(buffer)
        let decoded = unpacker.unpack()
        buffer.replaceSubrange(buffer.indices, with: repeatElement(0xff, count: buffer.count))

        XCTAssertEqual(decoded,
                       .map([(.string("items"), .array([.string("value"), .int(-42)]))]))
    }

    // MARK: Resource limits

    func testOversizedArrayHeaderFailsWithoutItsPayload() {
        // array32 claiming 0xFFFFFFFF elements, header only.
        var unpacker = MessagePackUnpacker()
        unpacker.feed([0xdd, 0xff, 0xff, 0xff, 0xff])
        XCTAssertNil(unpacker.unpack())
        XCTAssertTrue(unpacker.failed)
    }

    func testOversizedMapHeaderFails() {
        var unpacker = MessagePackUnpacker()
        unpacker.feed([0xdf, 0xff, 0xff, 0xff, 0xff]) // map32, count 0xFFFFFFFF
        XCTAssertNil(unpacker.unpack())
        XCTAssertTrue(unpacker.failed)
    }

    func testDeeplyNestedValueFails() {
        // Nesting past the depth limit fails while descending, before it could
        // run out of bytes, so the many fixarray headers alone are enough.
        var unpacker = MessagePackUnpacker()
        unpacker.feed(Array(repeating: 0x91, count: 200)) // fixarray(1) x 200
        XCTAssertNil(unpacker.unpack())
        XCTAssertTrue(unpacker.failed)
    }

    func testDecoderIsTerminalAfterFailure() {
        var unpacker = MessagePackUnpacker()
        unpacker.feed([0xdd, 0xff, 0xff, 0xff, 0xff])
        XCTAssertNil(unpacker.unpack())
        XCTAssertTrue(unpacker.failed)

        // A perfectly valid value fed afterward is not decoded: a rejected
        // value leaves the stream unsynchronizable.
        unpacker.feed([0xc0]) // null
        XCTAssertNil(unpacker.unpack())
        XCTAssertTrue(unpacker.failed)
    }

    func testLargeButValidArrayHeaderWaitsForDataInsteadOfFailing() {
        // A count within the limit but with no elements yet is incomplete, not
        // a violation: it must not reserve for the claim, fail, or lose data.
        var unpacker = MessagePackUnpacker()
        unpacker.feed([0xdc, 0x03, 0xe8]) // array16, count 1000, no elements
        XCTAssertNil(unpacker.unpack())
        XCTAssertFalse(unpacker.failed)

        unpacker.feed(Array(repeating: 0xc0, count: 1000)) // 1000 nulls
        guard case .array(let values)? = unpacker.unpack() else {
            return XCTFail("expected the completed array")
        }
        XCTAssertEqual(values.count, 1000)
        XCTAssertFalse(unpacker.failed)
    }

    func testDeclaredStringAboveByteLimitFailsAtItsHeader() {
        var limits = RPCResourceLimits.production
        limits.maximumStringBytes = 3
        var unpacker = MessagePackUnpacker(limits: limits)
        unpacker.feed([0xd9, 0x04])

        XCTAssertNil(unpacker.unpack())
        XCTAssertTrue(unpacker.failed)
    }

    func testWholeValueByteLimitIncludesFragmentedContainers() {
        var limits = RPCResourceLimits.production
        limits.maximumValueBytes = 4
        var unpacker = MessagePackUnpacker(limits: limits)

        for byte in [UInt8(0x95), 0xc0, 0xc0, 0xc0, 0xc0, 0xc0] {
            unpacker.feed(CollectionOfOne(byte))
            _ = unpacker.unpack()
        }
        XCTAssertTrue(unpacker.failed)
    }
}
