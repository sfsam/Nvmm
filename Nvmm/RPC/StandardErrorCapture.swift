//
//  Nvmm
//  StandardErrorCapture.swift
//
//  Bounded asynchronous capture for a spawned Neovim's standard error.
//

import Foundation
import os

nonisolated final class StandardErrorCapture: @unchecked Sendable {
    struct Output: Sendable, Equatable {
        var text: String
        var isTruncated: Bool
    }

    typealias Handler = @Sendable (Output) -> Void

    private let handle: FileHandle
    private let maximumBytes: Int
    private let handler: Handler
    private let lock = NSLock()
    private var data = Data()
    private var isTruncated = false
    private var isFinished = false

    init(fileDescriptor: Int32,
         maximumBytes: Int = 65_536,
         handler: @escaping Handler = StandardErrorCapture.log
    ) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
        self.handler = handler
        handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
    }

    deinit {
        finish()
    }

    static func log(_ output: Output) {
        if !output.text.isEmpty {
            Log.rpc.error("Neovim stderr: \(output.text)")
        }
        if output.isTruncated {
            Log.rpc.error("Further Neovim stderr output was discarded")
        }
    }

    private func consume(_ input: Data) {
        guard !input.isEmpty else {
            finish()
            return
        }

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        let remaining = maximumBytes - data.count
        if remaining > 0 {
            data.append(input.prefix(remaining))
        }
        if input.count > remaining {
            isTruncated = true
        }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        var text = String(decoding: data, as: UTF8.self)
        while text.last == "\n" || text.last == "\r" {
            text.removeLast()
        }
        let output = Output(text: text, isTruncated: isTruncated)
        lock.unlock()

        handle.readabilityHandler = nil
        try? handle.close()
        if !output.text.isEmpty || output.isTruncated {
            handler(output)
        }
    }
}
