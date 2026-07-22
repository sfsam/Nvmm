//
//  Nvmm
//  Settings.swift
//
//  User defaults the app reads. Nothing in the app writes them yet, so they
//  are set with `defaults write`; naming them in one place keeps the keys off
//  the call sites that read them.
//

import Foundation

/// The app's user defaults.
enum Settings {
    /// Whether a document opens as a buffer in the current tab page rather
    /// than in a new tab page. Applies to Finder and drag-and-drop opens, the
    /// Open panel, and New.
    static let openFilesInBuffersKey = "NVOpenFilesInBuffersInsteadOfTabs"

    static var openFilesInBuffers: Bool {
        UserDefaults.standard.bool(forKey: openFilesInBuffersKey)
    }
}
