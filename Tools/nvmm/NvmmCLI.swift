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
  -o                Open one horizontal window per file
  -O                Open one vertical window per file
  -p                Open one tabpage per file
  -R                Read-only mode
  --clean           Factory defaults - no user config or plugins
  --reuse           Reuse the best existing Nvmm window
                    Cannot be combined with +cmd, -c, -d, -o, -O,
                    -p, -R, --clean, or -f/--wait
"""

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
            var request = CLIRequest(
                arguments: parsed.arguments, files: parsed.files,
                workingDirectory: directory,
                forceNewWindow: parsed.needsNewWindow, wait: parsed.wait)
            request.environment = ProcessInfo.processInfo.environment
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
