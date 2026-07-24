//
//  Nvmm
//  MessagePack.swift
//
//  MessagePack serialization for the Neovim RPC transport.
//
//    MPValue               a decoded MessagePack value (the control-path model)
//    MessagePackWriter     serializes values into a byte stream
//    MessagePackUnpacker   deserializes a byte stream, one value at a time,
//                          tolerating fragmentation across feeds
//    unpackInteger         one-shot decode of a lone integer
//
//  Because Swift arrays and strings are owned copy-on-write value types, MPValue
//  is inherently Sendable and owns its storage: decoded values can cross actors
//  and outlive the buffer they were decoded from, needing no arena.
//
//  TODO: add a zero-copy reader for the redraw hot path (grid_line).
//
//  These types are nonisolated so the RPC actor can use them off the main actor,
//  despite the project's MainActor-by-default isolation.
//

import Foundation

// MARK: - Integer

/// A MessagePack integer.
///
/// MessagePack does not distinguish signed from unsigned on the wire beyond the
/// format byte, so sign information is not retained after decoding. The 64-bit
/// payload is stored raw and reinterpreted as signed or unsigned on demand.
/// Equality compares the raw bits, so `MPInteger(-1) == MPInteger(UInt64.max)`.
nonisolated struct MPInteger: Hashable, Sendable {
    /// The raw 64-bit payload.
    var bits: UInt64

    init(_ value: UInt64) { bits = value }
    init(_ value: Int64) { bits = UInt64(bitPattern: value) }

    /// Stores any fixed-width integer, sign-extending signed values.
    init<T: FixedWidthInteger>(_ value: T) {
        bits = T.isSigned ? UInt64(bitPattern: Int64(value)) : UInt64(value)
    }

    /// The value interpreted as an unsigned 64-bit integer.
    var unsigned: UInt64 { bits }

    /// The value interpreted as a signed 64-bit integer.
    var signed: Int64 { Int64(bitPattern: bits) }

    /// The value truncated to another integer type, respecting its signedness.
    func value<T: FixedWidthInteger>(as _: T.Type = T.self) -> T {
        T.isSigned ? T(truncatingIfNeeded: signed) : T(truncatingIfNeeded: bits)
    }
}

nonisolated extension MPInteger: ExpressibleByIntegerLiteral {
    nonisolated init(integerLiteral value: Int64) { self.init(value) }
}

// MARK: - Value

/// A decoded MessagePack value.
nonisolated enum MPValue: Sendable {
    case invalid
    case null
    case bool(Bool)
    case int(MPInteger)
    case double(Double)
    case string(String)
    case binary([UInt8])
    case ext(type: Int8, payload: [UInt8])
    case array([MPValue])
    case map([(MPValue, MPValue)])
}

nonisolated extension MPValue {
    var isNull: Bool { if case .null = self { true } else { false } }

    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var integer: MPInteger? { if case .int(let value) = self { value } else { nil } }
    var doubleValue: Double? { if case .double(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var binaryValue: [UInt8]? { if case .binary(let value) = self { value } else { nil } }
    var arrayValue: [MPValue]? { if case .array(let value) = self { value } else { nil } }
    var mapValue: [(MPValue, MPValue)]? { if case .map(let value) = self { value } else { nil } }

    /// Looks up a value by key in a map value, using a linear search.
    func mapValue(for key: MPValue) -> MPValue? {
        guard case .map(let pairs) = self else { return nil }
        for (candidate, value) in pairs where candidate == key { return value }
        return nil
    }
}

nonisolated extension MPValue: Equatable {
    nonisolated static func == (lhs: MPValue, rhs: MPValue) -> Bool {
        switch (lhs, rhs) {
        case (.invalid, .invalid), (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.binary(a), .binary(b)): return a == b
        case let (.ext(ta, pa), .ext(tb, pb)): return ta == tb && pa == pb
        case let (.array(a), .array(b)): return a == b
        case let (.map(a), .map(b)):
            return a.count == b.count &&
                zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

nonisolated extension MPValue: ExpressibleByBooleanLiteral {
    nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
}

nonisolated extension MPValue: ExpressibleByIntegerLiteral {
    nonisolated init(integerLiteral value: Int64) { self = .int(MPInteger(value)) }
}

nonisolated extension MPValue: ExpressibleByFloatLiteral {
    nonisolated init(floatLiteral value: Double) { self = .double(value) }
}

nonisolated extension MPValue: ExpressibleByStringLiteral {
    nonisolated init(stringLiteral value: String) { self = .string(value) }
}

nonisolated extension MPValue: ExpressibleByArrayLiteral {
    nonisolated init(arrayLiteral elements: MPValue...) { self = .array(elements) }
}

// MARK: - Writer

/// Serializes values into a MessagePack byte stream.
///
/// Integers and array/map/string headers use the smallest format that fits;
/// floats are always packed as 64-bit. Signed integers that fit an unsigned
/// encoding are packed unsigned.
nonisolated struct MessagePackWriter {
    /// The accumulated byte stream.
    private(set) var bytes: [UInt8] = []

    init() {}

    init(reservingCapacity capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    /// Removes all packed bytes.
    mutating func clear() { bytes.removeAll(keepingCapacity: true) }

    private mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func packNil() { bytes.append(0xc0) }

    mutating func packBool(_ value: Bool) { bytes.append(value ? 0xc3 : 0xc2) }

    mutating func packUInt64(_ value: UInt64) {
        if value < 0x80 {
            bytes.append(UInt8(value))
        } else if value <= UInt64(UInt8.max) {
            bytes.append(0xcc)
            bytes.append(UInt8(value))
        } else if value <= UInt64(UInt16.max) {
            bytes.append(0xcd)
            appendBigEndian(UInt16(value))
        } else if value <= UInt64(UInt32.max) {
            bytes.append(0xce)
            appendBigEndian(UInt32(value))
        } else {
            bytes.append(0xcf)
            appendBigEndian(value)
        }
    }

    mutating func packInt64(_ value: Int64) {
        if value >= 0 {
            packUInt64(UInt64(value))
        } else if value >= -32 {
            bytes.append(UInt8(bitPattern: Int8(value)))
        } else if value >= Int64(Int8.min) {
            bytes.append(0xd0)
            bytes.append(UInt8(bitPattern: Int8(value)))
        } else if value >= Int64(Int16.min) {
            bytes.append(0xd1)
            appendBigEndian(UInt16(bitPattern: Int16(value)))
        } else if value >= Int64(Int32.min) {
            bytes.append(0xd2)
            appendBigEndian(UInt32(bitPattern: Int32(value)))
        } else {
            bytes.append(0xd3)
            appendBigEndian(UInt64(bitPattern: value))
        }
    }

    mutating func packDouble(_ value: Double) {
        bytes.append(0xcb)
        appendBigEndian(value.bitPattern)
    }

    mutating func packString(_ value: String) {
        let utf8 = Array(value.utf8)
        let count = utf8.count
        if count <= 31 {
            bytes.append(0xa0 | UInt8(count))
        } else if count <= Int(UInt8.max) {
            bytes.append(0xd9)
            bytes.append(UInt8(count))
        } else if count <= Int(UInt16.max) {
            bytes.append(0xda)
            appendBigEndian(UInt16(count))
        } else {
            bytes.append(0xdb)
            appendBigEndian(UInt32(count))
        }
        bytes.append(contentsOf: utf8)
    }

    mutating func packBinary(_ value: [UInt8]) {
        let count = value.count
        if count <= Int(UInt8.max) {
            bytes.append(0xc4)
            bytes.append(UInt8(count))
        } else if count <= Int(UInt16.max) {
            bytes.append(0xc5)
            appendBigEndian(UInt16(count))
        } else {
            bytes.append(0xc6)
            appendBigEndian(UInt32(count))
        }
        bytes.append(contentsOf: value)
    }

    mutating func packExtension(type: Int8, payload: [UInt8]) {
        switch payload.count {
        case 1: bytes.append(0xd4)
        case 2: bytes.append(0xd5)
        case 4: bytes.append(0xd6)
        case 8: bytes.append(0xd7)
        case 16: bytes.append(0xd8)
        default:
            let count = payload.count
            if count <= Int(UInt8.max) {
                bytes.append(0xc7)
                bytes.append(UInt8(count))
            } else if count <= Int(UInt16.max) {
                bytes.append(0xc8)
                appendBigEndian(UInt16(count))
            } else {
                bytes.append(0xc9)
                appendBigEndian(UInt32(count))
            }
        }
        bytes.append(UInt8(bitPattern: type))
        bytes.append(contentsOf: payload)
    }

    /// Writes an array header. Must be followed by `count` packed values.
    mutating func startArray(_ count: UInt32) {
        if count <= 15 {
            bytes.append(0x90 | UInt8(count))
        } else if count <= UInt32(UInt16.max) {
            bytes.append(0xdc)
            appendBigEndian(UInt16(count))
        } else {
            bytes.append(0xdd)
            appendBigEndian(count)
        }
    }

    /// Writes a map header. Must be followed by `count` packed key/value pairs.
    mutating func startMap(_ count: UInt32) {
        if count <= 15 {
            bytes.append(0x80 | UInt8(count))
        } else if count <= UInt32(UInt16.max) {
            bytes.append(0xde)
            appendBigEndian(UInt16(count))
        } else {
            bytes.append(0xdf)
            appendBigEndian(count)
        }
    }

    /// Packs a decoded value, choosing the smallest suitable format.
    mutating func pack(_ value: MPValue) {
        switch value {
        case .invalid: bytes.append(0xc1)
        case .null: packNil()
        case .bool(let value): packBool(value)
        case .int(let value):
            let signed = value.signed
            if signed < 0 { packInt64(signed) } else { packUInt64(value.unsigned) }
        case .double(let value): packDouble(value)
        case .string(let value): packString(value)
        case .binary(let value): packBinary(value)
        case .ext(let type, let payload): packExtension(type: type, payload: payload)
        case .array(let values):
            startArray(UInt32(values.count))
            for value in values { pack(value) }
        case .map(let pairs):
            startMap(UInt32(pairs.count))
            for (key, value) in pairs { pack(key); pack(value) }
        }
    }
}

// MARK: - RPC framing

nonisolated extension MessagePackWriter {
    /// Appends one MessagePack-RPC notification: `[2, method, arguments]`.
    mutating func encodeNotification(method: String, arguments: [MPValue]) {
        startArray(3)
        packUInt64(2)
        packString(method)
        startArray(UInt32(arguments.count))
        for argument in arguments { pack(argument) }
    }

    /// Appends one MessagePack-RPC request: `[0, id, method, arguments]`.
    mutating func encodeRequest(id: UInt64, method: String, arguments: [MPValue]) {
        startArray(4)
        packUInt64(0)
        packUInt64(id)
        packString(method)
        startArray(UInt32(arguments.count))
        for argument in arguments { pack(argument) }
    }

    /// Appends one MessagePack-RPC response: `[1, id, error, result]`.
    mutating func encodeResponse(id: UInt64, error: MPValue, result: MPValue) {
        startArray(4)
        packUInt64(1)
        packUInt64(id)
        pack(error)
        pack(result)
    }
}

// MARK: - Unpacker

/// Deserializes a MessagePack byte stream into `MPValue`s, one at a time.
///
/// Bytes are fed in (possibly fragmented) with `feed`, then drained with
/// repeated `unpack` calls until it returns nil. `unpack` commits its cursor
/// only when a complete value is parsed, so a partial value at the end of the
/// buffer is retained and completed by a later feed.
nonisolated struct MessagePackUnpacker {
    private var storage: [UInt8] = []
    private var offset = 0

    // Product safety limits on one decoded value. These are not MessagePack or
    // Neovim protocol limits; they cap what a single malformed value can make
    // the decoder allocate. A violation sets `failed` and is not retryable,
    // because MessagePack gives no way to resynchronize past a rejected value.
    private static let maxDepth = 128
    private static let maxCollectionCount = 1 << 20

    /// Set once a limit above is exceeded. The caller stops decoding and closes
    /// the connection. This is distinct from the nil `unpack` returns for an
    /// incomplete buffer, which is retried once more bytes arrive.
    private(set) var failed = false

    init() {}

    /// Appends bytes to the input buffer.
    mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        storage.append(contentsOf: bytes)
    }

    /// Appends raw bytes to the input buffer.
    mutating func feed(_ buffer: UnsafeRawBufferPointer) {
        storage.append(contentsOf: buffer)
    }

    /// Unpacks the next complete value, or nil if the buffer is exhausted or
    /// holds only a partial value.
    mutating func unpack() -> MPValue? {
        guard !failed else { return nil }
        var cursor = offset
        guard let value = parse(&cursor, depth: 0) else { return nil }
        offset = cursor
        if offset == storage.count {
            storage.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 4096 {
            storage.removeFirst(offset)
            offset = 0
        }
        return value
    }

    // MARK: Parsing

    // Each reader returns nil when the buffer lacks the requested bytes. That
    // nil propagates up through `parse` to `unpack`, which then leaves the
    // buffer untouched for a later feed to complete.

    private func readByte(_ cursor: inout Int) -> UInt8? {
        guard cursor < storage.count else { return nil }
        defer { cursor += 1 }
        return storage[cursor]
    }

    private func readUInt16(_ cursor: inout Int) -> UInt16? {
        guard cursor + 2 <= storage.count else { return nil }
        let value = UInt16(storage[cursor]) << 8 | UInt16(storage[cursor + 1])
        cursor += 2
        return value
    }

    private func readUInt32(_ cursor: inout Int) -> UInt32? {
        guard cursor + 4 <= storage.count else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 { value = value << 8 | UInt32(storage[cursor + i]) }
        cursor += 4
        return value
    }

    private func readUInt64(_ cursor: inout Int) -> UInt64? {
        guard cursor + 8 <= storage.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value = value << 8 | UInt64(storage[cursor + i]) }
        cursor += 8
        return value
    }

    private func readBytes(_ cursor: inout Int, _ count: Int) -> ArraySlice<UInt8>? {
        guard cursor + count <= storage.count else { return nil }
        defer { cursor += count }
        return storage[cursor..<cursor + count]
    }

    private mutating func parse(_ cursor: inout Int, depth: Int) -> MPValue? {
        if depth > Self.maxDepth {
            failed = true
            return nil
        }
        guard let byte = readByte(&cursor) else { return nil }

        switch byte {
        case 0x00...0x7f:
            return .int(MPInteger(UInt64(byte)))
        case 0xe0...0xff:
            return .int(MPInteger(Int64(Int8(bitPattern: byte))))
        case 0x80...0x8f:
            return parseMap(&cursor, count: Int(byte & 0x0f), depth: depth)
        case 0x90...0x9f:
            return parseArray(&cursor, count: Int(byte & 0x0f), depth: depth)
        case 0xa0...0xbf:
            return parseString(&cursor, count: Int(byte & 0x1f))
        case 0xc0:
            return .null
        case 0xc1:
            return .invalid
        case 0xc2:
            return .bool(false)
        case 0xc3:
            return .bool(true)
        case 0xc4:
            guard let count = readByte(&cursor) else { return nil }
            return parseBinary(&cursor, count: Int(count))
        case 0xc5:
            guard let count = readUInt16(&cursor) else { return nil }
            return parseBinary(&cursor, count: Int(count))
        case 0xc6:
            guard let count = readUInt32(&cursor) else { return nil }
            return parseBinary(&cursor, count: Int(count))
        case 0xc7:
            guard let count = readByte(&cursor) else { return nil }
            return parseExtension(&cursor, count: Int(count))
        case 0xc8:
            guard let count = readUInt16(&cursor) else { return nil }
            return parseExtension(&cursor, count: Int(count))
        case 0xc9:
            guard let count = readUInt32(&cursor) else { return nil }
            return parseExtension(&cursor, count: Int(count))
        case 0xca:
            guard let raw = readUInt32(&cursor) else { return nil }
            return .double(Double(Float(bitPattern: raw)))
        case 0xcb:
            guard let raw = readUInt64(&cursor) else { return nil }
            return .double(Double(bitPattern: raw))
        case 0xcc:
            guard let raw = readByte(&cursor) else { return nil }
            return .int(MPInteger(UInt64(raw)))
        case 0xcd:
            guard let raw = readUInt16(&cursor) else { return nil }
            return .int(MPInteger(UInt64(raw)))
        case 0xce:
            guard let raw = readUInt32(&cursor) else { return nil }
            return .int(MPInteger(UInt64(raw)))
        case 0xcf:
            guard let raw = readUInt64(&cursor) else { return nil }
            return .int(MPInteger(raw))
        case 0xd0:
            guard let raw = readByte(&cursor) else { return nil }
            return .int(MPInteger(Int64(Int8(bitPattern: raw))))
        case 0xd1:
            guard let raw = readUInt16(&cursor) else { return nil }
            return .int(MPInteger(Int64(Int16(bitPattern: raw))))
        case 0xd2:
            guard let raw = readUInt32(&cursor) else { return nil }
            return .int(MPInteger(Int64(Int32(bitPattern: raw))))
        case 0xd3:
            guard let raw = readUInt64(&cursor) else { return nil }
            return .int(MPInteger(Int64(bitPattern: raw)))
        case 0xd4:
            return parseExtension(&cursor, count: 1)
        case 0xd5:
            return parseExtension(&cursor, count: 2)
        case 0xd6:
            return parseExtension(&cursor, count: 4)
        case 0xd7:
            return parseExtension(&cursor, count: 8)
        case 0xd8:
            return parseExtension(&cursor, count: 16)
        case 0xd9:
            guard let count = readByte(&cursor) else { return nil }
            return parseString(&cursor, count: Int(count))
        case 0xda:
            guard let count = readUInt16(&cursor) else { return nil }
            return parseString(&cursor, count: Int(count))
        case 0xdb:
            guard let count = readUInt32(&cursor) else { return nil }
            return parseString(&cursor, count: Int(count))
        case 0xdc:
            guard let count = readUInt16(&cursor) else { return nil }
            return parseArray(&cursor, count: Int(count), depth: depth)
        case 0xdd:
            guard let count = readUInt32(&cursor) else { return nil }
            return parseArray(&cursor, count: Int(count), depth: depth)
        case 0xde:
            guard let count = readUInt16(&cursor) else { return nil }
            return parseMap(&cursor, count: Int(count), depth: depth)
        case 0xdf:
            guard let count = readUInt32(&cursor) else { return nil }
            return parseMap(&cursor, count: Int(count), depth: depth)
        default:
            return nil // Unreachable: every byte value is handled above.
        }
    }

    private func parseString(_ cursor: inout Int, count: Int) -> MPValue? {
        guard let slice = readBytes(&cursor, count) else { return nil }
        return .string(String(decoding: slice, as: UTF8.self))
    }

    private func parseBinary(_ cursor: inout Int, count: Int) -> MPValue? {
        guard let slice = readBytes(&cursor, count) else { return nil }
        return .binary(Array(slice))
    }

    private func parseExtension(_ cursor: inout Int, count: Int) -> MPValue? {
        guard let type = readByte(&cursor),
              let slice = readBytes(&cursor, count)
        else { return nil }
        return .ext(type: Int8(bitPattern: type), payload: Array(slice))
    }

    private mutating func parseArray(_ cursor: inout Int, count: Int,
                                     depth: Int) -> MPValue? {
        if count > Self.maxCollectionCount {
            failed = true
            return nil
        }
        var values: [MPValue] = []
        // Reserve only what the buffered bytes could hold: each element is at
        // least one byte, so a header claiming more than remains is incomplete,
        // not a reason to allocate for the claim.
        values.reserveCapacity(min(count, storage.count - cursor))
        for _ in 0..<count {
            guard let value = parse(&cursor, depth: depth + 1) else {
                return nil
            }
            values.append(value)
        }
        return .array(values)
    }

    private mutating func parseMap(_ cursor: inout Int, count: Int,
                                   depth: Int) -> MPValue? {
        if count > Self.maxCollectionCount {
            failed = true
            return nil
        }
        var pairs: [(MPValue, MPValue)] = []
        // Each pair is at least two bytes; reserve no more than remains.
        pairs.reserveCapacity(min(count, (storage.count - cursor) / 2))
        for _ in 0..<count {
            guard let key = parse(&cursor, depth: depth + 1),
                  let value = parse(&cursor, depth: depth + 1) else {
                return nil
            }
            pairs.append((key, value))
        }
        return .map(pairs)
    }
}

// MARK: - One-shot integer

/// Decodes a byte buffer that holds exactly one MessagePack integer.
///
/// Returns nil if the buffer is empty, does not begin with an integer format,
/// or contains any bytes beyond the single integer (excess bytes are an error).
nonisolated func unpackInteger(_ bytes: [UInt8]) -> MPInteger? {
    guard let first = bytes.first else { return nil }

    func bigEndian(_ start: Int, _ count: Int) -> UInt64? {
        guard bytes.count == start + count else { return nil }
        var value: UInt64 = 0
        for i in 0..<count { value = value << 8 | UInt64(bytes[start + i]) }
        return value
    }

    switch first {
    case 0x00...0x7f:
        return bytes.count == 1 ? MPInteger(UInt64(first)) : nil
    case 0xe0...0xff:
        return bytes.count == 1 ? MPInteger(Int64(Int8(bitPattern: first))) : nil
    case 0xcc:
        return bigEndian(1, 1).map { MPInteger($0) }
    case 0xcd:
        return bigEndian(1, 2).map { MPInteger($0) }
    case 0xce:
        return bigEndian(1, 4).map { MPInteger($0) }
    case 0xcf:
        return bigEndian(1, 8).map { MPInteger($0) }
    case 0xd0:
        return bigEndian(1, 1).map { MPInteger(Int64(Int8(bitPattern: UInt8($0)))) }
    case 0xd1:
        return bigEndian(1, 2).map { MPInteger(Int64(Int16(bitPattern: UInt16($0)))) }
    case 0xd2:
        return bigEndian(1, 4).map { MPInteger(Int64(Int32(bitPattern: UInt32($0)))) }
    case 0xd3:
        return bigEndian(1, 8).map { MPInteger(Int64(bitPattern: $0)) }
    default:
        return nil
    }
}
