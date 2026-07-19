//
//  Nvmm
//  RPCTypes.swift
//
//  Value types exchanged with the NeovimProcess actor: the outcome of a request,
//  transport failures, an inbound notification, and a spawn/connect error.
//
//  All are Sendable so they can cross from the process actor to any caller, and
//  nonisolated so they are usable off the main actor.
//

import Foundation

/// A completed RPC response. `error` is `.null` on success; otherwise it carries
/// Neovim's error value and `result` is meaningless.
nonisolated struct RPCResponse: Sendable, Equatable {
    var error: MPValue
    var result: MPValue

    /// True when Neovim reported an error for the request.
    var isError: Bool { !error.isNull }
}

/// A transport-level failure that ends the RPC connection.
nonisolated enum RPCTransportError: Error, Sendable, Equatable {
    /// The peer closed the connection, or the client disconnected.
    case connectionClosed
    /// A read from the transport failed with the given errno.
    case readFailed(errno: Int32)
    /// A write to the transport failed with the given errno.
    case writeFailed(errno: Int32)
}

/// An error thrown by an asynchronous `request`.
nonisolated enum RPCError: Error, Sendable {
    /// The request deadline elapsed before a response arrived.
    case timedOut
    /// The connection failed; the request will never be answered.
    case transport(RPCTransportError)
}

/// The outcome of a synchronous `requestSync`. Unlike `request`, no case is
/// thrown; the caller inspects it.
nonisolated enum RPCSyncResult: Sendable {
    /// Neovim replied; inspect `error` and `result`.
    case response(RPCResponse)
    /// The request deadline elapsed before a response arrived.
    case timedOut
    /// The connection failed before a response arrived.
    case transport(RPCTransportError)
}

/// An inbound MessagePack-RPC notification: a method name and its arguments.
nonisolated struct RPCNotification: Sendable, Equatable {
    var method: String
    var arguments: [MPValue]
}

/// A failure to spawn a child process or connect a socket. `code` is an errno.
nonisolated struct NeovimSpawnError: Error, Sendable {
    /// The errno reported by the failing operation.
    var code: Int32
    /// The operation that failed: "pipe", "spawn", or "connect".
    var operation: String
    /// A human-readable description of `code`.
    var message: String { String(cString: strerror(code)) }
}
