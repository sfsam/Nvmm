//
//  Nvmm
//  Logging.swift
//
//  Unified logging categories shared across the application.
//

import os

nonisolated enum Log {
    private static let subsystem = "com.mowglii.Nvmm"

    static let app = Logger(subsystem: subsystem, category: "application")
    static let control = Logger(subsystem: subsystem, category: "control")
    static let rendering = Logger(subsystem: subsystem, category: "rendering")
    static let rpc = Logger(subsystem: subsystem, category: "rpc")
    static let textInput = Logger(subsystem: subsystem, category: "text-input")
}
