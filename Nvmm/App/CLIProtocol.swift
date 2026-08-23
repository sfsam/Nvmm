//
//  Nvmm
//  CLIProtocol.swift
//
//  The vocabulary the app and the nvmm helper share: the control request and
//  response values, the protocol's limits, where its socket lives, and the
//  pure parser for the helper's command line.
//
//  This file is compiled into both targets. Each end could declare its own
//  copy, but then the request the helper builds and the request the app
//  decodes would be two definitions free to drift, and a drift would surface
//  only as a rejected request in the field.
//
//  The protocol is deliberately unrelated to Neovim's MessagePack-RPC: a
//  different peer, lifecycle, and trust boundary. JSON keeps the helper
//  independent of the app's RPC implementation.
//

import Darwin
import Foundation

nonisolated enum CLIProtocol {
    static let version = 1
    static let maximumRequestBytes = 256 << 10
    static let maximumResponseBytes = 4 << 10

#if DEBUG
    static let channel = "debug"
#else
    static let channel = "stable"
#endif

    /// The directory holding the control socket: a private subdirectory of
    /// the per-user temporary directory, which the system already creates
    /// owned by the user with no group or other access.
    ///
    /// `/tmp` is the fallback rather than the default because it is
    /// world-writable: another user can pre-create the subdirectory there and
    /// deny the app its endpoint. `prepareDirectory` refuses to use a
    /// directory it does not own either way, so that is a denial rather than
    /// an exposure — but the per-user directory does not allow even that.
    ///
    /// The name is not the app's bundle identifier: macOS creates a directory
    /// of that name in the same place, owned by the system at mode `0755`,
    /// which the ownership and permission checks rightly refuse to adopt.
    static func endpointDirectory(uid: uid_t = geteuid()) -> String {
        guard let temporary = userTemporaryDirectory() else {
            return "/tmp/nvmm-control-\(uid)"
        }
        return (temporary as NSString)
            .appendingPathComponent("nvmm-control")
    }

    static func endpointPath(uid: uid_t = geteuid(),
                             channel: String = channel) -> String {
        endpointDirectory(uid: uid) + "/control-\(channel).sock"
    }

    /// The per-user temporary directory, asked of the system directly rather
    /// than read from `TMPDIR`. The app and the helper must agree on this
    /// path, and their environments do not: a shell can export `TMPDIR`,
    /// while an app launched from the Finder inherits none.
    private static func userTemporaryDirectory() -> String? {
        let capacity = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard capacity > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: capacity)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, capacity) == capacity
        else { return nil }
        return buffer.withUnsafeBufferPointer {
            String(validatingCString: $0.baseAddress!)
        }
    }

    static let unixPathCapacity =
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
}

nonisolated enum CLIEndpoint {
    static func prepareDirectory(
        _ path: String = CLIProtocol.endpointDirectory()
    ) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT, mkdir(path, S_IRWXU) == 0 else {
                throw CLIError.system(errno)
            }
            guard lstat(path, &info) == 0 else {
                throw CLIError.system(errno)
            }
        }
        let permissions = info.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), permissions == S_IRWXU else {
            throw CLIError("The control socket directory has unsafe "
                           + "ownership or permissions.")
        }
    }

    static func connect(
        to path: String = CLIProtocol.endpointPath()
    ) -> (fd: Int32, error: Int32) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor != -1 else { return (-1, errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe,
                       socklen_t(MemoryLayout<Int32>.size))
        do {
            let result = try withAddress(path) {
                Darwin.connect(descriptor, $0,
                               socklen_t(MemoryLayout<sockaddr_un>.size))
            }
            guard result == 0 else { throw CLIError.system(errno) }
            return (descriptor, 0)
        } catch {
            close(descriptor)
            return (-1, (error as? CLIError)?.code ?? EINVAL)
        }
    }

    static func withAddress<T>(
        _ path: String, _ body: (UnsafePointer<sockaddr>) -> T
    ) throws -> T {
        let bytes = Array(path.utf8)
        guard bytes.count < CLIProtocol.unixPathCapacity else {
            throw CLIError.system(ENAMETOOLONG)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(bytes.count + 1)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
        }
    }
}

/// A failure to report to a person: a sentence, and the `errno` it came from
/// when there was one.
///
/// The endpoint, the listener, and the helper's own I/O all fail this way —
/// their callers print the message or map the code, and none of them branch
/// on which failure it was. `CLIProtocolError` and `CLIArgumentError` stay
/// enumerated because their cases are matched, not just displayed.
nonisolated struct CLIError: Error, Sendable, Equatable {
    let message: String
    let code: Int32?

    init(_ message: String, code: Int32? = nil) {
        self.message = message
        self.code = code
    }

    static func system(_ code: Int32) -> CLIError {
        CLIError(String(cString: strerror(code)), code: code)
    }
}

nonisolated struct CLIRequest: Codable, Sendable, Equatable {
    var version = CLIProtocol.version
    var arguments: [String]
    var files: [String]
    var workingDirectory: String
    var forceNewWindow: Bool
    var wait: Bool

    func validate() throws {
        guard version == CLIProtocol.version else {
            throw CLIProtocolError.incompatibleVersion
        }
        guard workingDirectory.hasPrefix("/") else {
            throw CLIProtocolError.invalidWorkingDirectory
        }
        try CLIArguments.validateForwarded(arguments)
    }

    var needsNewWindow: Bool {
        forceNewWindow || wait || !arguments.isEmpty
    }

    var absoluteFiles: [String] {
        files.map {
            let path = $0.hasPrefix("/")
                ? $0
                : (workingDirectory as NSString).appendingPathComponent($0)
            return (path as NSString).standardizingPath
        }
    }
}

nonisolated struct CLIResponse: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case accepted, closed, error
    }

    var version = CLIProtocol.version
    var status: Status
    var message: String?

    static let accepted = CLIResponse(status: .accepted, message: nil)
    static let closed = CLIResponse(status: .closed, message: nil)

    static func error(_ message: String) -> CLIResponse {
        CLIResponse(status: .error, message: message)
    }
}

nonisolated enum CLIProtocolError: Error, Sendable, Equatable {
    case incompatibleVersion
    case invalidWorkingDirectory
    case invalidForwardedArguments

    var message: String {
        switch self {
        case .incompatibleVersion:
            "Incompatible control protocol version."
        case .invalidWorkingDirectory:
            "The working directory must be an absolute path."
        case .invalidForwardedArguments:
            "The request contains an unsupported Neovim argument."
        }
    }
}

nonisolated struct CLIArguments: Sendable, Equatable {
    var arguments: [String] = []
    var files: [String] = []
    var forceNewWindow = false
    var wait = false
    var showHelp = false

    var needsNewWindow: Bool {
        forceNewWindow || wait || !arguments.isEmpty
    }

    static func parse(_ values: [String]) throws -> CLIArguments {
        var result = CLIArguments()
        var index = 0
        var options = true
        while index < values.count {
            let value = values[index]
            if options && value == "--" {
                options = false
            } else if options && value.hasPrefix("+") {
                result.arguments.append(value)
            } else if options && value.hasPrefix("--") {
                switch value {
                case "--wait": result.wait = true
                case "--help": result.showHelp = true
                case "--clean": result.arguments.append(value)
                default: throw CLIArgumentError.unknownOption(value)
                }
            } else if options && value.hasPrefix("-") && value != "-" {
                try parseShort(value, values: values, index: &index,
                               result: &result)
            } else {
                result.files.append(value)
            }
            index += 1
        }
        return result
    }

    private static func parseShort(
        _ value: String, values: [String], index: inout Int,
        result: inout CLIArguments
    ) throws {
        let characters = Array(value.dropFirst())
        for (offset, option) in characters.enumerated() {
            switch option {
            case "d", "o", "O", "p", "R":
                result.arguments.append("-\(option)")
            case "N": result.forceNewWindow = true
            case "f": result.wait = true
            case "h": result.showHelp = true
            case "c":
                result.arguments.append("-c")
                let attached = String(characters.dropFirst(offset + 1))
                if !attached.isEmpty {
                    result.arguments.append(attached)
                } else {
                    guard index + 1 < values.count else {
                        throw CLIArgumentError.missingValue("-c")
                    }
                    index += 1
                    result.arguments.append(values[index])
                }
                return
            default:
                throw CLIArgumentError.unknownOption("-\(option)")
            }
        }
    }

    /// A forwarded argument list is valid exactly when parsing it yields
    /// nothing but those same arguments: no file, and no option the helper
    /// was supposed to consume itself. Asking the parser is what keeps the
    /// two from drifting — the set of forwardable options is never written
    /// down a second time.
    static func validateForwarded(_ values: [String]) throws {
        guard let parsed = try? parse(values),
              parsed == CLIArguments(arguments: values) else {
            throw CLIProtocolError.invalidForwardedArguments
        }
    }
}

nonisolated enum CLIArgumentError: Error, Sendable, Equatable {
    case unknownOption(String)
    case missingValue(String)

    var message: String {
        switch self {
        case .unknownOption(let option): "Unknown option: \(option)"
        case .missingValue(let option):
            "Option \(option) requires an argument."
        }
    }
}
