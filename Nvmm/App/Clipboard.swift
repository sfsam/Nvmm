//
//  Nvmm
//  Clipboard.swift
//
//  Bridges Neovim's `+`/`*` registers to the system pasteboard.
//
//  Neovim's `g:clipboard` provider is pointed at this UI (see
//  `NeovimProcess.installClipboardProvider`), so a yank or put on the clipboard
//  registers arrives as an inbound `clipboard_get`/`clipboard_set` RPC request.
//  These answer them against `NSPasteboard`. The Vim register type (charwise,
//  linewise, or blockwise) is preserved in a private pasteboard type so a
//  yank-then-put round-trip keeps its shape; text copied by other apps pastes
//  as an unknown type, which Neovim treats as charwise.
//

import AppKit

@MainActor enum Clipboard {
    // Shared with Vim and MacVim to preserve copy-paste compatibility across
    // apps. Do not change.
    private static let vimType = NSPasteboard.PasteboardType("VimPboardType")

    /// A Vim register type, stored in the private pasteboard type as the same
    /// integer Vim uses, so the two interoperate.
    private enum RegisterType: Int {
        case character = 0
        case line = 1
        case block = 2
        case unknown = -1

        /// Parses the regtype string Neovim passes to `clipboard_set`.
        init(regtype: String) {
            switch regtype.first {
            case "c", "v": self = .character
            case "l", "V": self = .line
            case "b", "\u{16}": self = .block  // CTRL-V
            default: self = .unknown
            }
        }

        /// The single-character regtype `clipboard_get` reports to Neovim.
        var regtype: String {
            switch self {
            case .character: return "c"
            case .line: return "l"
            case .block: return "b"
            case .unknown: return ""
            }
        }
    }

    /// Reads the pasteboard as Neovim's `[lines, regtype]` pair. Prefers the
    /// private Vim type (which carries the register type); otherwise falls back
    /// to plain text as an unknown type. An empty pasteboard reads as no lines.
    static func get(_ arguments: [MPValue]) -> RequestOutcome {
        get(arguments, pasteboard: .general)
    }

    /// Writes `[lines, regtype]` to the general pasteboard. See `set(_:on:)`.
    static func set(_ arguments: [MPValue]) -> RequestOutcome {
        set(arguments, pasteboard: .general)
    }

    /// Reads `pasteboard` as Neovim's `[lines, regtype]` pair. Exposed for
    /// tests with a named pasteboard; production uses `get(_:)` on the general
    /// one.
    static func get(_ arguments: [MPValue],
                    pasteboard: NSPasteboard) -> RequestOutcome {
        if let plist = pasteboard.propertyList(forType: vimType) as? [Any],
           plist.count == 2,
           let number = plist[0] as? NSNumber,
           let text = plist[1] as? String {
            let regtype = RegisterType(rawValue: number.intValue) ?? .unknown
            return clipboardData(text: text, regtype: regtype)
        }

        guard let text = pasteboard.string(forType: .string) else {
            return .result(.array([.array([]), .string("")]))
        }
        return clipboardData(text: text, regtype: .unknown)
    }

    /// Writes `[lines, regtype]` to `pasteboard`, storing the register type in
    /// the private Vim type and the joined text as plain string for other apps.
    /// Exposed for tests with a named pasteboard; production uses `set(_:)`.
    static func set(_ arguments: [MPValue],
                    pasteboard: NSPasteboard) -> RequestOutcome {
        guard arguments.count == 2 else {
            return .error("clipboard_set expects lines and register type")
        }
        guard let lineValues = arguments[0].arrayValue else {
            return .error("clipboard_set lines must be an array")
        }
        guard let regtypeString = arguments[1].stringValue else {
            return .error("clipboard_set register type must be a string")
        }

        var lines: [String] = []
        lines.reserveCapacity(lineValues.count)
        for value in lineValues {
            guard let line = value.stringValue else {
                return .error("clipboard_set lines must all be strings")
            }
            lines.append(line)
        }

        let text = lines.joined(separator: "\n")
        let regtype = RegisterType(regtype: regtypeString)
        pasteboard.declareTypes([vimType, .string], owner: nil)
        pasteboard.setPropertyList([regtype.rawValue, text], forType: vimType)
        pasteboard.setString(text, forType: .string)
        return .result(.null)
    }

    /// What the pasteboard holds for a native paste (Cmd-V). Drives whether
    /// paste reads Neovim's `+` register (to preserve the register type) or
    /// pastes plain text directly.
    enum PasteContent: Equatable {
        /// Nothing pasteable.
        case none
        /// Plain text from another app; paste it as-is.
        case plainText(String)
        /// A value yanked in Nvmm carrying a valid Vim register type; paste it
        /// through the `+` register so charwise/linewise/blockwise is kept.
        case vimRegister
    }

    /// Classifies the general pasteboard for a native paste. See `PasteContent`.
    static func contentForPaste() -> PasteContent {
        contentForPaste(pasteboard: .general)
    }

    /// Classifies `pasteboard` for a native paste. Exposed for tests.
    static func contentForPaste(pasteboard: NSPasteboard) -> PasteContent {
        if let plist = pasteboard.propertyList(forType: vimType) as? [Any],
           plist.count == 2,
           let number = plist[0] as? NSNumber,
           plist[1] is String,
           [RegisterType.character, .line, .block]
               .contains(where: { $0.rawValue == number.intValue }) {
            return .vimRegister
        }
        if let text = pasteboard.string(forType: .string) {
            return .plainText(text)
        }
        return .none
    }

    /// Splits pasteboard text into Neovim's line list and pairs it with the
    /// register type, matching how Vim stores a yanked register.
    private static func clipboardData(text: String,
                                      regtype: RegisterType) -> RequestOutcome {
        let lines = text.components(separatedBy: .newlines).map(MPValue.string)
        return .result(.array([.array(lines), .string(regtype.regtype)]))
    }
}
