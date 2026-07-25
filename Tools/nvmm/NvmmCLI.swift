//
//  nvmm
//  NvmmCLI.swift
//
//  The nvmm command-line helper, bundled at Contents/bin/nvmm.
//
//  It parses its command line, connects to the app's control socket —
//  launching the app that contains it when nothing is listening — writes one
//  request, and reads the reply. It holds no editor state: which window opens
//  is the app's decision, and the helper reports only what it is told.
//
//  Exit status is 2 for a usage error, 1 for a launch, transport, or app-side
//  failure, and 0 once the request is accepted — or, with --wait, once the
//  window closes.
//

import AppKit
import Darwin
import Foundation

private let usage = """
Usage:
  nvmm [options] [file ...]

Options:
  +                 Start at end of file
  +<lnum>           Start at line <lnum>
  +/<pattern>       Start at the first line containing <pattern>
  +<cmd>, -c <cmd>  Execute <cmd> after loading the first file
  -d                Diff mode
  -f, --wait        Foreground mode - wait until the window is closed
  -h, --help        Print this help message
  -N                Open a new Nvmm window
  -o                Open one horizontal window per file
  -O                Open one vertical window per file
  -p                Open one tab page per file
  -R                Read-only mode
  --clean           Factory defaults - no user config or plugins
"""

private struct CLIClient {
    let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func send(_ request: CLIRequest) throws {
        var data = try JSONEncoder().encode(request)
        data.append(0x0a)
        guard data.count <= CLIProtocol.maximumRequestBytes else {
            throw CLIError("Request is too large.")
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor,
                                         bytes.baseAddress! + offset,
                                         bytes.count - offset)
                if count == -1 {
                    if errno == EINTR { continue }
                    throw CLIError(String(cString: strerror(errno)))
                }
                offset += count
            }
        }
    }

    func readResponse(waitForever: Bool) throws -> CLIResponse {
        var timeout = waitForever
            ? timeval(tv_sec: 0, tv_usec: 0)
            : timeval(tv_sec: 10, tv_usec: 0)
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw CLIError(String(cString: strerror(errno)))
        }

        var data = Data()
        while data.count <= CLIProtocol.maximumResponseBytes {
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 {
                throw CLIError("Nvmm closed the control connection.")
            }
            if count == -1 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError("Timed out waiting for Nvmm.")
                }
                throw CLIError(String(cString: strerror(errno)))
            }
            if byte == 0x0a {
                let response = try JSONDecoder().decode(CLIResponse.self,
                                                        from: data)
                guard response.version == CLIProtocol.version else {
                    throw CLIError(
                        "Nvmm uses an incompatible control protocol.")
                }
                return response
            }
            data.append(byte)
        }
        throw CLIError("Nvmm sent an oversized response.")
    }
}

@main
private struct NvmmCLI {
    static func main() async {
        do {
            let values = try commandLineArguments()
            let parsed = try CLIArguments.parse(values)
            if parsed.showHelp {
                print(usage)
                return
            }
            let directory = try workingDirectory()
            let request = CLIRequest(
                arguments: parsed.arguments, files: parsed.files,
                workingDirectory: directory,
                forceNewWindow: parsed.forceNewWindow, wait: parsed.wait)
            try request.validate()
            try CLIEndpoint.prepareDirectory()

            let descriptor = try await connectOrLaunch()
            defer { close(descriptor) }
            let client = CLIClient(descriptor: descriptor)
            try client.send(request)
            let accepted = try client.readResponse(waitForever: false)
            try check(accepted, expected: .accepted)
            if request.wait {
                let closed = try client.readResponse(waitForever: true)
                try check(closed, expected: .closed)
            }
        } catch let error as CLIArgumentError {
            fail(error.message, status: 2)
        } catch let error as CLIProtocolError {
            fail(error.message, status: 1)
        } catch let error as CLIError {
            fail(error.message, status: 1)
        } catch {
            fail(error.localizedDescription, status: 1)
        }
    }

    private static func check(_ response: CLIResponse,
                              expected: CLIResponse.Status) throws {
        if response.status == .error {
            throw CLIError(response.message ?? "Nvmm rejected the request.")
        }
        guard response.status == expected else {
            throw CLIError("Nvmm sent an unexpected response.")
        }
    }

    private static func connectOrLaunch() async throws -> Int32 {
        let first = CLIEndpoint.connect()
        if first.error == 0 { return first.fd }
        guard first.error == ENOENT || first.error == ECONNREFUSED else {
            throw CLIError(String(cString: strerror(first.error)))
        }

        let appURL = try containingApplication()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--nvmm-client"]
        // Keep the process identifier of the instance that was opened — the
        // one launched, or the running one this activated. Asking later
        // whether that process is alive is evidence about the app the request
        // was meant for, which a search by bundle identifier is not: Debug and
        // Release builds share one, and either may be running.
        let pid = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<pid_t, Error>) in
            NSWorkspace.shared.openApplication(
                at: appURL, configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(
                        returning: application.processIdentifier)
                } else {
                    continuation.resume(
                        throwing: CLIError("Failed to launch Nvmm."))
                }
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var lastError = first.error
        while clock.now < deadline {
            let attempt = CLIEndpoint.connect()
            if attempt.error == 0 { return attempt.fd }
            lastError = attempt.error
            if lastError != ENOENT && lastError != ECONNREFUSED {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if lastError == ENOENT || lastError == ECONNREFUSED {
            throw CLIError(NSRunningApplication(processIdentifier: pid) == nil
                ? "Nvmm quit before it could accept the request."
                : "Nvmm is running but is not accepting command-line requests.")
        }
        throw CLIError(String(cString: strerror(lastError)))
    }

    private static func containingApplication() throws -> URL {
        var capacity: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &capacity)
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        guard _NSGetExecutablePath(&buffer, &capacity) == 0,
              let path = buffer.withUnsafeBufferPointer({
                  String(validatingCString: $0.baseAddress!)
              }) else {
            throw CLIError("Could not locate the nvmm executable.")
        }
        let executable = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
        let app = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // The walk identifies the app; this only rejects a walk that landed
        // somewhere that is not an application at all — the usual cause being
        // a copy of this executable rather than a symlink to it. Whether that
        // application is Nvmm is not asserted: the helper cannot know its own
        // bundle identifier without hardcoding one, and a stale constant would
        // refuse to launch the very app that ships it.
        guard app.pathExtension == "app",
              let bundle = Bundle(url: app), bundle.executableURL != nil else {
            throw CLIError(
                "The nvmm executable is not inside an application bundle.")
        }
        return app
    }

    private static func commandLineArguments() throws -> [String] {
        var result: [String] = []
        for index in 1..<Int(CommandLine.argc) {
            guard let pointer = CommandLine.unsafeArgv[index],
                  let value = String(validatingCString: pointer) else {
                throw CLIError("An argument is not valid UTF-8.")
            }
            result.append(value)
        }
        return result
    }

    private static func workingDirectory() throws -> String {
        guard let pointer = getcwd(nil, 0) else {
            throw CLIError(String(cString: strerror(errno)))
        }
        defer { free(pointer) }
        guard let value = String(validatingCString: pointer) else {
            throw CLIError("The working directory is not valid UTF-8.")
        }
        return value
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("nvmm: \(message)\n".utf8))
        exit(status)
    }
}
