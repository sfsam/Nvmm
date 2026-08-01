//
//  Nvmm
//  UIAttach.swift
//
//  UI attachment: the options a UI requests, and validation of Neovim's API
//  metadata before attaching.
//
//  Before calling `nvim_ui_attach`, the client fetches `nvim_get_api_info` and
//  checks that Neovim is new enough, exposes the API methods the client depends
//  on, and supports the requested UI capabilities. `validateAPIMetadata`
//  performs those checks; the transport drives the request sequence (see
//  NeovimProcess).
//

import Foundation

/// The external UI capabilities a client can request. See `:help ui-ext-options`.
nonisolated struct UIOptions: Sendable, Equatable {
    var extCmdline = false
    var extHlstate = false
    var extLinegrid = false
    var extMessages = false
    var extMultigrid = false
    var extPopupmenu = false
    var extTabline = false
    var extTermcolors = false

    init() {}
}

/// A Neovim API version triple.
nonisolated struct APIVersion: Sendable, Equatable, Comparable {
    var major: UInt64 = 0
    var minor: UInt64 = 0
    var patch: UInt64 = 0

    /// The oldest Neovim this client supports, and the only place that floor is
    /// written down: `UIAttachResult.requiredVersion` defaults to it, and the
    /// version gate both compares against it and builds its diagnostic from it.
    static let minimumSupported = APIVersion(major: 0, minor: 12, patch: 0)

    /// Ordered as a triple, so 0.11 precedes 0.12 and any 1.x follows it.
    static func < (lhs: APIVersion, rhs: APIVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The version as Neovim names its releases, dropping a zero patch.
    var displayName: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }
}

/// The outcome category of a UI attachment attempt.
nonisolated enum UIAttachStatus: Sendable, Equatable {
    case success          // Attachment and required Lua setup completed.
    case incompatible     // Version, metadata, method, or capability mismatch.
    case rpcError         // Neovim rejected a setup request; inspect rpcError.
    case timedOut         // The shared setup deadline expired.
    case transportError   // The connection failed; inspect transport fields.
}

/// The result of a UI attachment attempt, with diagnostics for the failure cases.
nonisolated struct UIAttachResult: Sendable {
    var status: UIAttachStatus = .success
    /// A diagnostic suitable for logs or a user-visible startup error.
    var message = ""
    /// The minimum supported Neovim version; always populated.
    var requiredVersion = APIVersion.minimumSupported
    /// The detected version, populated once valid metadata has been parsed.
    var detectedVersion = APIVersion()
    /// Neovim's error value when `status` is `.rpcError`.
    var rpcError: MPValue?
    /// The transport failure when `status` is `.transportError`.
    var transportError: RPCTransportError?
    /// An errno for a transport failure when available.
    var systemError: Int32 = 0
}

/// The capabilities parsed from Neovim's API metadata.
nonisolated struct APICapabilities: Sendable, Equatable {
    var version = APIVersion()
    var functions: [String] = []
    var uiOptions: [String] = []
}

/// The API methods this client depends on and requires Neovim to expose.
private nonisolated let requiredAPIFunctions = [
    "nvim_set_client_info", "nvim_ui_attach", "nvim_exec_lua", "nvim_call_function"
]

/// Parses `nvim_get_api_info` metadata into `APICapabilities`.
///
/// The metadata is the two-element result `[channel_id, info_map]`; capabilities
/// come from the map. Returns nil if the structure or required fields are missing.
nonisolated func parseAPICapabilities(_ metadata: MPValue) -> APICapabilities? {
    guard case .array(let result) = metadata, result.count >= 2,
          case .map = result[1],
          let versionValue = result[1].mapValue(for: .string("version")),
          case .map = versionValue,
          let functionsValue = result[1].mapValue(for: .string("functions")),
          case .array(let functions) = functionsValue,
          let optionsValue = result[1].mapValue(for: .string("ui_options")),
          case .array(let options) = optionsValue else { return nil }

    guard let major = versionValue.mapValue(for: .string("major"))?.integer?.unsigned,
          let minor = versionValue.mapValue(for: .string("minor"))?.integer?.unsigned,
          let patch = versionValue.mapValue(for: .string("patch"))?.integer?.unsigned
    else { return nil }

    var capabilities = APICapabilities()
    capabilities.version = APIVersion(major: major, minor: minor, patch: patch)
    for entry in functions {
        if case .map = entry, let name = entry.mapValue(for: .string("name"))?.stringValue {
            capabilities.functions.append(name)
        }
    }
    for entry in options {
        if let name = entry.stringValue { capabilities.uiOptions.append(name) }
    }
    return capabilities
}

/// Validates API metadata against this client's requirements.
///
/// Returns a result whose status is `.success` when Neovim is compatible, or
/// `.incompatible` with a message otherwise. The parsed capabilities are returned
/// alongside so the caller can attach with only the options Neovim supports.
nonisolated func validateAPIMetadata(_ metadata: MPValue,
                                     requested: UIOptions)
    -> (result: UIAttachResult, capabilities: APICapabilities) {
    guard let capabilities = parseAPICapabilities(metadata) else {
        var failure = UIAttachResult()
        failure.status = .incompatible
        failure.message = "Neovim returned invalid API metadata"
        return (failure, APICapabilities())
    }

    var result = UIAttachResult()
    result.detectedVersion = capabilities.version

    // A version at or past the floor still must advertise every required
    // function and capability checked below.
    if capabilities.version < result.requiredVersion {
        result.status = .incompatible
        result.message =
            "Neovim \(result.requiredVersion.displayName) or newer is required"
        return (result, capabilities)
    }

    for name in requiredAPIFunctions where !capabilities.functions.contains(name) {
        result.status = .incompatible
        result.message = "Required Neovim API method is unavailable: \(name)"
        return (result, capabilities)
    }

    if !capabilities.uiOptions.contains("ext_linegrid") {
        result.status = .incompatible
        result.message = "Neovim does not support the ext_linegrid UI protocol"
        return (result, capabilities)
    }

    for (name, wanted) in requestedOptionList(requested) where wanted {
        if !capabilities.uiOptions.contains(name) {
            result.status = .incompatible
            result.message = "Requested UI option is unavailable: \(name)"
            return (result, capabilities)
        }
    }

    return (result, capabilities)
}

/// The requested UI options as (name, value) pairs, in wire order.
nonisolated func requestedOptionList(_ options: UIOptions) -> [(String, Bool)] {
    [("ext_cmdline", options.extCmdline),
     ("ext_hlstate", options.extHlstate),
     ("ext_linegrid", options.extLinegrid),
     ("ext_messages", options.extMessages),
     ("ext_multigrid", options.extMultigrid),
     ("ext_popupmenu", options.extPopupmenu),
     ("ext_tabline", options.extTabline),
     ("ext_termcolors", options.extTermcolors)]
}
