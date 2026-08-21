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

/// Values emitted while a redraw notification is decoded incrementally.
nonisolated enum MessagePackRedrawItem {
    case event(MPValue)
    case gridLineStart([MPValue])
    case gridLineCell(MPValue)
    case gridLineEnd(MPValue)
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
    private let limits: RPCResourceLimits
    private var frames: [Frame] = []
    private var payload: Payload?
    private var valueBytes = 0

    private struct Frame {
        enum Kind: Equatable { case array, map }
        enum Role: Equatable {
            case normal
            case redrawArguments
            case redrawEvent
            case gridLineEvent
            case gridLineTuple
            case streamedGridLineTuple
            case gridLineCells
            case gridLineCell
        }
        var kind: Kind
        var role: Role
        var remaining: Int
        var values: [MPValue]
    }

    private struct Payload {
        enum Kind {
            case string
            case binary
            case ext(Int8)
        }
        var kind: Kind
        var remaining: Int
        // Nil discards a recoverable oversized grid-cell string.
        var bytes: [UInt8]?
    }

    /// Set once a limit above is exceeded. The caller stops decoding and closes
    /// the connection. This is distinct from the nil `unpack` returns for an
    /// incomplete buffer, which is retried once more bytes arrive.
    private(set) var failed = false

    init(limits: RPCResourceLimits = .production) {
        self.limits = limits
    }

    /// Appends bytes to the input buffer.
    mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        guard !failed else { return }
        storage.append(contentsOf: bytes)
    }

    /// Appends raw bytes to the input buffer.
    mutating func feed(_ buffer: UnsafeRawBufferPointer) {
        guard !failed else { return }
        storage.append(contentsOf: buffer)
    }

    /// Unpacks the next complete value, or nil if the buffer is exhausted or
    /// holds only a partial value.
    mutating func unpack(
        redrawItem: ((MessagePackRedrawItem) -> Void)? = nil
    ) -> MPValue? {
        guard !failed else { return nil }
        while !failed {
            if payload != nil {
                guard let value = consumePayload() else {
                    compact()
                    return nil
                }
                if let completed = accept(value, redrawItem: redrawItem) {
                    compact()
                    return completed
                }
                continue
            }

            guard let item = parseItem() else {
                compact()
                return nil
            }
            switch item {
            case .value(let value):
                if let completed = accept(value, redrawItem: redrawItem) {
                    compact()
                    return completed
                }
            case .container(let kind, let count):
                if count < 0 || count > limits.maximumCollectionCount ||
                    frames.count >= limits.maximumNestingDepth {
                    failed = true
                    break
                }
                let childCount: Int
                if kind == .map {
                    let (count, overflow) = count.multipliedReportingOverflow(by: 2)
                    if overflow {
                        failed = true
                        break
                    }
                    childCount = count
                } else {
                    childCount = count
                }
                let role = containerRole(kind: kind, redrawItem: redrawItem)
                if childCount == 0 {
                    let value: MPValue = kind == .array ? .array([]) : .map([])
                    if let completed = accept(value, redrawItem: redrawItem) {
                        compact()
                        return completed
                    }
                } else {
                    frames.append(Frame(kind: kind, role: role,
                                        remaining: childCount, values: []))
                }
            case .payload(let newPayload):
                payload = newPayload
            }
        }
        return nil
    }

    private enum Item {
        case value(MPValue)
        case container(Frame.Kind, Int)
        case payload(Payload)
    }

    private mutating func accept(
        _ newValue: MPValue,
        redrawItem: ((MessagePackRedrawItem) -> Void)?
    ) -> MPValue? {
        var value = newValue
        while let index = frames.indices.last {
            if frames[index].role == .redrawEvent,
               frames[index].values.isEmpty,
               value.stringValue == "grid_line" {
                frames[index].role = .gridLineEvent
            }

            switch frames[index].role {
            case .redrawArguments:
                if value != .invalid { redrawItem?(.event(value)) }
            case .gridLineEvent:
                if frames[index].values.isEmpty {
                    frames[index].values.append(value)
                }
            case .gridLineCells:
                redrawItem?(.gridLineCell(value))
            default:
                frames[index].values.append(value)
            }
            frames[index].remaining -= 1
            if frames[index].remaining > 0 {
                return nil
            }

            let frame = frames.removeLast()
            switch frame.kind {
            case .array:
                switch frame.role {
                case .redrawArguments:
                    value = .array([])
                case .streamedGridLineTuple:
                    redrawItem?(.gridLineEnd(frame.values.last ?? .invalid))
                    value = .invalid
                case .gridLineEvent:
                    value = .invalid
                case .gridLineCells:
                    value = .array([])
                default:
                    value = .array(frame.values)
                }
            case .map:
                var pairs: [(MPValue, MPValue)] = []
                pairs.reserveCapacity(frame.values.count / 2)
                var index = 0
                while index < frame.values.count {
                    pairs.append((frame.values[index], frame.values[index + 1]))
                    index += 2
                }
                value = .map(pairs)
            }
        }
        valueBytes = 0
        return value
    }

    private mutating func containerRole(
        kind: Frame.Kind,
        redrawItem: ((MessagePackRedrawItem) -> Void)?
    ) -> Frame.Role {
        guard kind == .array, redrawItem != nil else { return .normal }
        if frames.count == 1, frames[0].kind == .array,
           frames[0].remaining == 1,
           frames[0].values.count == 2,
           frames[0].values[0].integer?.unsigned == 2,
           frames[0].values[1].stringValue == "redraw" {
            return .redrawArguments
        }
        guard let index = frames.indices.last else { return .normal }
        switch frames[index].role {
        case .redrawArguments:
            return .redrawEvent
        case .gridLineEvent:
            return .gridLineTuple
        case .gridLineTuple where frames[index].values.count == 3:
            frames[index].role = .streamedGridLineTuple
            redrawItem?(.gridLineStart(frames[index].values))
            return .gridLineCells
        case .gridLineCells:
            return .gridLineCell
        default:
            return .normal
        }
    }

    private mutating func consumePayload() -> MPValue? {
        guard var current = payload else { return nil }
        let available = storage.count - offset
        let count = min(available, current.remaining)
        if count > 0 {
            current.bytes?.append(
                contentsOf: storage[offset..<(offset + count)])
            offset += count
            current.remaining -= count
            valueBytes += count
        }
        guard checkValueBytes() else { return nil }
        if current.remaining > 0 {
            payload = current
            return nil
        }
        payload = nil
        switch current.kind {
        case .string:
            guard let bytes = current.bytes else { return .invalid }
            return .string(String(decoding: bytes, as: UTF8.self))
        case .binary:
            guard let bytes = current.bytes else { return .invalid }
            return .binary(bytes)
        case .ext(let type):
            guard let bytes = current.bytes else { return .invalid }
            return .ext(type: type, payload: bytes)
        }
    }

    private mutating func parseItem() -> Item? {
        guard let byte = peekByte() else { return nil }
        let headerBytes = headerLength(for: byte)
        guard offset + headerBytes <= storage.count else { return nil }

        let start = offset
        offset += 1
        let item: Item?
        switch byte {
        case 0x00...0x7f:
            item = .value(.int(MPInteger(UInt64(byte))))
        case 0xe0...0xff:
            item = .value(.int(MPInteger(Int64(Int8(bitPattern: byte)))))
        case 0x80...0x8f:
            item = .container(.map, Int(byte & 0x0f))
        case 0x90...0x9f:
            item = .container(.array, Int(byte & 0x0f))
        case 0xa0...0xbf:
            item = makePayload(.string, count: Int(byte & 0x1f))
        case 0xc0:
            item = .value(.null)
        case 0xc1:
            item = .value(.invalid)
        case 0xc2:
            item = .value(.bool(false))
        case 0xc3:
            item = .value(.bool(true))
        case 0xc4:
            item = makePayload(.binary, count: Int(readUInt(1)))
        case 0xc5:
            item = makePayload(.binary, count: Int(readUInt(2)))
        case 0xc6:
            item = makePayload(.binary, count: checkedInt(readUInt(4)))
        case 0xc7:
            let count = Int(readUInt(1))
            item = makeExtension(count: count)
        case 0xc8:
            let count = Int(readUInt(2))
            item = makeExtension(count: count)
        case 0xc9:
            item = makeExtension(count: checkedInt(readUInt(4)))
        case 0xca:
            item = .value(.double(Double(Float(bitPattern: UInt32(readUInt(4))))))
        case 0xcb:
            item = .value(.double(Double(bitPattern: readUInt(8))))
        case 0xcc:
            item = .value(.int(MPInteger(readUInt(1))))
        case 0xcd:
            item = .value(.int(MPInteger(readUInt(2))))
        case 0xce:
            item = .value(.int(MPInteger(readUInt(4))))
        case 0xcf:
            item = .value(.int(MPInteger(readUInt(8))))
        case 0xd0:
            item = .value(.int(MPInteger(Int64(
                Int8(bitPattern: UInt8(readUInt(1)))))))
        case 0xd1:
            item = .value(.int(MPInteger(Int64(
                Int16(bitPattern: UInt16(readUInt(2)))))))
        case 0xd2:
            item = .value(.int(MPInteger(Int64(
                Int32(bitPattern: UInt32(readUInt(4)))))))
        case 0xd3:
            item = .value(.int(MPInteger(Int64(bitPattern: readUInt(8)))))
        case 0xd4:
            item = makeExtension(count: 1)
        case 0xd5:
            item = makeExtension(count: 2)
        case 0xd6:
            item = makeExtension(count: 4)
        case 0xd7:
            item = makeExtension(count: 8)
        case 0xd8:
            item = makeExtension(count: 16)
        case 0xd9:
            item = makePayload(.string, count: Int(readUInt(1)))
        case 0xda:
            item = makePayload(.string, count: Int(readUInt(2)))
        case 0xdb:
            item = makePayload(.string, count: checkedInt(readUInt(4)))
        case 0xdc:
            item = .container(.array, Int(readUInt(2)))
        case 0xdd:
            item = .container(.array, checkedInt(readUInt(4)))
        case 0xde:
            item = .container(.map, Int(readUInt(2)))
        case 0xdf:
            item = .container(.map, checkedInt(readUInt(4)))
        default:
            item = nil
        }
        valueBytes += offset - start
        guard checkValueBytes() else { return nil }
        return item
    }

    private func headerLength(for byte: UInt8) -> Int {
        switch byte {
        case 0xc4, 0xcc, 0xd0, 0xd9: return 2
        case 0xc5, 0xcd, 0xd1, 0xda, 0xdc, 0xde: return 3
        case 0xc6, 0xca, 0xce, 0xd2, 0xdb, 0xdd, 0xdf: return 5
        case 0xc7: return 3
        case 0xc8: return 4
        case 0xc9: return 6
        case 0xcb, 0xcf, 0xd3: return 9
        case 0xd4, 0xd5, 0xd6, 0xd7, 0xd8: return 2
        default: return 1
        }
    }

    private mutating func readUInt(_ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count {
            value = value << 8 | UInt64(storage[offset])
            offset += 1
        }
        return value
    }

    private func peekByte() -> UInt8? {
        offset < storage.count ? storage[offset] : nil
    }

    private mutating func makePayload(_ kind: Payload.Kind, count: Int) -> Item? {
        guard count >= 0 else {
            failed = true
            return nil
        }
        let isCellText: Bool
        let maximum: Int
        switch kind {
        case .string:
            isCellText = frames.last?.role == .gridLineCell &&
                frames.last?.values.isEmpty == true
            maximum = limits.maximumStringBytes
        case .binary, .ext:
            isCellText = false
            maximum = limits.maximumBinaryBytes
        }
        guard count <= maximum, valueBytes <= limits.maximumValueBytes - count
        else {
            failed = true
            return nil
        }
        if count == 0 {
            switch kind {
            case .string: return .value(.string(""))
            case .binary: return .value(.binary([]))
            case .ext(let type): return .value(.ext(type: type, payload: []))
            }
        }
        if isCellText, count > limits.maximumCellTextBytes {
            return .payload(Payload(kind: kind, remaining: count, bytes: nil))
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        return .payload(Payload(kind: kind, remaining: count, bytes: bytes))
    }

    private mutating func makeExtension(count: Int) -> Item? {
        guard count >= 0, offset < storage.count else {
            failed = count < 0
            return nil
        }
        let type = Int8(bitPattern: storage[offset])
        offset += 1
        return makePayload(.ext(type), count: count)
    }

    private mutating func checkedInt(_ value: UInt64) -> Int {
        guard value <= UInt64(Int.max) else {
            failed = true
            return -1
        }
        return Int(value)
    }

    private mutating func checkValueBytes() -> Bool {
        if valueBytes > limits.maximumValueBytes {
            failed = true
            return false
        }
        return true
    }

    private mutating func compact() {
        if offset == storage.count {
            storage.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 4096 {
            storage.removeFirst(offset)
            offset = 0
        }
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
