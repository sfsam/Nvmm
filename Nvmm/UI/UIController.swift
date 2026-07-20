//
//  Nvmm
//  UIController.swift
//
//  Translates Neovim redraw notifications into grids.
//
//  The controller owns the highlight table, the mode table, and the single grid
//  it writes to as events arrive. Every event batch ends (from Neovim) with
//  `flush`, at which point the controller bumps the draw tick and publishes an
//  immutable copy of the grid. `redraw` returns those flushed snapshots so the
//  transport can hand them to the renderer.
//
//  Neovim remains authoritative: the controller only mirrors the wire protocol.
//  Unsupported grids (ext_multigrid is not requested) and malformed tuples are
//  dropped defensively rather than trusted.
//

import Foundation

/// A pending reconnection Neovim asked the UI to perform.
nonisolated struct UIHandoff: Sendable, Equatable {
    enum Kind: Sendable { case restart, connect }
    var kind: Kind
    var address: String
}

/// True when a handoff connection error means Neovim abandoned the successor
/// socket rather than failing to open a server. A `:restart` that fails can leave
/// its UI event pending after Neovim removes the temporary socket; the resulting
/// `ENOENT` is cancellation of the handoff, not a user-visible error.
nonisolated func handoffConnectionErrorIsStale(_ kind: UIHandoff.Kind,
                                               _ error: Int32) -> Bool {
    kind == .restart && error == ENOENT
}

/// Applies Neovim UI redraw events, producing grid snapshots on flush.
nonisolated final class UIController {
    // Highlight state.
    private var hlTable: [CellAttributes] = [.defaultGroup]
    private var modeTable: [ModeState] = []
    private var hlGroupTypes: [UInt8] = []                 // hlid -> HLGroup bits
    private var hlGroupMappings: [String: (id: Int, type: HLGroup)] = [:]

    // The grid being written to, and the most recent flushed snapshot.
    private var writing = Grid()
    private(set) var globalGrid = Grid()

    // Scalar option/state snapshots.
    private(set) var defaultBackgroundRGB: UInt32 = 0
    private(set) var mousemoveevent = false
    private(set) var ambiguousWidthDouble = false
    private(set) var emojiWidthDouble = true
    private(set) var modified = false
    private(set) var title = "NVIM"
    private(set) var guifont = ""
    private(set) var uiOptions = UIOptions()
    private(set) var viewport = ViewportState()
    private(set) var handoff: UIHandoff?

    // Progress tracking, keyed by task id, most-recent-known percentage wins.
    private struct ProgressEntry { var percent: Int?; var sequence: UInt64 }
    private var progressEntries: [String: ProgressEntry] = [:]
    private var progressSequence: UInt64 = 0

    init() {}

    /// True once at least one flush has produced a drawable grid.
    var isDrawable: Bool { globalGrid.tick > 0 }

    /// The default background color, tagged as a default color.
    var defaultBackgroundColor: RGBColor {
        RGBColor(neovim: defaultBackgroundRGB, default: ())
    }

    // MARK: Redraw entry point

    /// Applies a batch of redraw events. Returns the grid snapshots flushed while
    /// applying them (usually zero or one).
    func redraw(_ events: [MPValue]) -> [Grid] {
        var flushed: [Grid] = []
        for event in events { apply(event, &flushed) }
        return flushed
    }

    private func apply(_ event: MPValue, _ flushed: inout [Grid]) {
        guard case .array(let fields) = event,
              let name = fields.first?.stringValue else { return }
        let args = fields.dropFirst()

        switch name {
        case "grid_line": forEachTuple(args, gridLine)
        case "grid_resize": forEachTuple(args, gridResize)
        case "grid_scroll": forEachTuple(args, gridScroll)
        case "grid_clear": forEachTuple(args, gridClear)
        case "grid_cursor_goto": forEachTuple(args, gridCursorGoto)
        case "flush":
            for tuple in args where tuple.arrayValue != nil { flushed.append(flush()) }
        case "hl_attr_define": forEachTuple(args, hlAttrDefine)
        case "hl_group_set": forEachTuple(args, hlGroupSet)
        case "default_colors_set": forEachTuple(args, defaultColorsSet)
        case "mode_info_set": forEachTuple(args, modeInfoSet)
        case "mode_change": forEachTuple(args, modeChange)
        case "win_viewport": forEachTuple(args, winViewport)
        case "set_title": forEachTuple(args, setTitle)
        case "busy_start": writing.cursorHidden = true
        case "busy_stop": writing.cursorHidden = false
        case "option_set": forEachTuple(args, setOption)
        case "restart": applyHandoff(args, .restart)
        case "connect": applyHandoff(args, .connect)
        default: break // mouse_on / mouse_off / set_icon / unknown: ignored.
        }
    }

    /// Invokes `body` once per argument tuple, skipping non-array tuples.
    private func forEachTuple(_ args: ArraySlice<MPValue>, _ body: ([MPValue]) -> Void) {
        for tuple in args {
            guard case .array(let fields) = tuple else { continue }
            body(fields)
        }
    }

    // MARK: Grid geometry

    /// Returns true if `index` names the single supported grid. ext_multigrid is
    /// not requested, so only grid 1 is written.
    private func isMainGrid(_ index: MPValue) -> Bool {
        index.integer?.unsigned == 1
    }

    private func gridResize(_ tuple: [MPValue]) {
        guard tuple.count >= 3, isMainGrid(tuple[0]),
              let width = asInt(tuple[1]), let height = asInt(tuple[2]) else { return }
        writing.resize(width: width, height: height)
    }

    private func gridClear(_ tuple: [MPValue]) {
        guard tuple.count >= 1, isMainGrid(tuple[0]) else { return }
        var attrs = CellAttributes()
        attrs.background = hlTable[0].background
        let empty = Cell(text: "", attrs: attrs)
        for index in writing.cells.indices { writing.cells[index] = empty }
    }

    private func gridCursorGoto(_ tuple: [MPValue]) {
        guard tuple.count >= 3, isMainGrid(tuple[0]),
              let row = asInt(tuple[1]), let col = asInt(tuple[2]) else { return }
        guard row < writing.height, col < writing.width else { return }
        writing.cursorRow = row
        writing.cursorCol = col
    }

    private func gridScroll(_ tuple: [MPValue]) {
        guard tuple.count >= 6, let top = asInt(tuple[1]), let bottom = asInt(tuple[2]),
              let left = asInt(tuple[3]), let right = asInt(tuple[4]),
              let rows = asInt(tuple[5]) else { return }
        guard bottom >= top, right >= left else { return }
        guard isMainGrid(tuple[0]) else { return }
        guard bottom <= writing.height, right <= writing.width else { return }

        let width = writing.width
        let spanWidth = right - left
        let height = bottom - top
        let rowStride: Int
        let firstRow: Int
        let count: Int
        if rows >= 0 {
            firstRow = top
            rowStride = 1
            count = height - rows
        } else {
            firstRow = bottom - 1
            rowStride = -1
            count = height + rows
        }

        // Copy `count` rows, each shifted by `rows`, in the direction that avoids
        // clobbering not-yet-copied source rows.
        for step in 0..<max(count, 0) {
            let destRow = firstRow + step * rowStride
            let srcRow = destRow + rows
            let destStart = destRow * width + left
            let srcStart = srcRow * width + left
            let chunk = Array(writing.cells[srcStart..<srcStart + spanWidth])
            writing.cells.replaceSubrange(destStart..<destStart + spanWidth, with: chunk)
        }
    }

    // MARK: Grid line

    private func gridLine(_ tuple: [MPValue]) {
        guard tuple.count >= 4, isMainGrid(tuple[0]),
              let row = asInt(tuple[1]), let col = asInt(tuple[2]),
              case .array(let updates) = tuple[3] else { return }
        guard row < writing.height, col < writing.width else { return }

        let rowBegin = row * writing.width
        var index = rowBegin + col
        var remaining = writing.width - col

        // Highlight id and attributes carry across cells: a bare-text cell inherits
        // the previous cell's highlight.
        var hlid = 0
        var hlattr: CellAttributes?

        for object in updates {
            guard case .array(let cellFields) = object,
                  let text = cellFields.first?.stringValue else { return }

            var repeatCount = 1
            switch cellFields.count {
            case 1:
                break // text only; hlid and hlattr inherited.
            case 2:
                guard let id = asInt(cellFields[1]) else { return }
                hlid = id
                hlattr = hlEntry(id)
            case 3:
                guard let id = asInt(cellFields[1]),
                      let count = asInt(cellFields[2]) else { return }
                hlid = id
                hlattr = hlEntry(id)
                repeatCount = count
            default:
                return
            }

            // The first cell of a line must establish a highlight.
            guard let attr = hlattr else { return }
            guard repeatCount <= remaining else { return }

            let pointerStyle: UInt8 = hlid >= 0 && hlid < hlGroupTypes.count
                ? hlGroupTypes[hlid] : 0

            if text.isEmpty {
                // The right half of a double-width character. Be defensive about a
                // stray empty leading cell.
                if index == rowBegin { return }
                writing.cells[index - 1].addDoubleWidth()
                var right = Cell()
                right.setAttributes(writing.cells[index - 1].attributes)
                right.pointerStyle = pointerStyle
                writing.cells[index] = right
                index += 1
                remaining -= 1
            } else if repeatCount > 0 {
                let updated = Cell(text: text, attrs: attr, pointerStyle: pointerStyle)
                for offset in 0..<repeatCount { writing.cells[index + offset] = updated }
                index += repeatCount
                remaining -= repeatCount
            }
        }
    }

    // MARK: Highlights

    private func hlEntry(_ hlid: Int) -> CellAttributes {
        hlid >= 0 && hlid < hlTable.count ? hlTable[hlid] : hlTable[0]
    }

    /// Creates or replaces the highlight entry for `hlid`, filling any gap below it
    /// with default-group copies. Returns the entry's index.
    private func hlNewEntry(_ hlid: Int) -> Int {
        let size = hlTable.count
        if hlid == size {
            hlTable.append(hlTable[0])
        } else if hlid < size {
            hlTable[hlid] = hlTable[0]
        } else {
            hlTable.append(contentsOf: Array(repeating: hlTable[0], count: hlid + 1 - size))
        }
        return hlid
    }

    private func hlAttrDefine(_ tuple: [MPValue]) {
        guard tuple.count >= 2, let hlid = asInt(tuple[0]), hlid >= 0,
              case .map(let definition) = tuple[1] else { return }

        let index = hlNewEntry(hlid)
        var attrs = hlTable[index]

        for (key, value) in definition {
            guard let name = key.stringValue else { continue }
            switch name {
            case "foreground": setColor(&attrs.foreground, value)
            case "background": setColor(&attrs.background, value)
            case "special":
                setColor(&attrs.special, value)
                attrs.flags.insert(.specialColor)
            case "underline": setFlag(&attrs.flags, .underline, value)
            case "underdouble": setFlag(&attrs.flags, .underdouble, value)
            case "underdotted": setFlag(&attrs.flags, .underdotted, value)
            case "underdashed": setFlag(&attrs.flags, .underdashed, value)
            case "bold": setFlag(&attrs.flags, .bold, value)
            case "italic": setFlag(&attrs.flags, .italic, value)
            case "strikethrough": setFlag(&attrs.flags, .strikethrough, value)
            case "undercurl": setFlag(&attrs.flags, .undercurl, value)
            case "overline": setFlag(&attrs.flags, .overline, value)
            case "dim": setFlag(&attrs.flags, .dim, value)
            case "reverse": setFlag(&attrs.flags, .reverse, value)
            case "nocombine": setFlag(&attrs.flags, .nocombine, value)
            case "blend":
                if let raw = value.integer?.unsigned { attrs.blend = UInt8(min(raw, 100)) }
            default: break
            }
        }

        if attrs.flags.contains(.reverse) {
            swap(&attrs.background, &attrs.foreground)
        }
        adjustDefaultColors(&attrs, against: hlTable[0])
        hlTable[index] = attrs
    }

    private func setColor(_ color: inout RGBColor, _ value: MPValue) {
        guard let rgb = value.integer?.value(as: UInt32.self) else { return }
        color = RGBColor(neovim: rgb)
    }

    private func setFlag(_ flags: inout CellFlags, _ flag: CellFlags, _ value: MPValue) {
        // Neovim sends these as `true` when present; treat any non-boolean payload
        // as enabling, so older or malformed payloads still turn the flag on.
        if value.boolValue ?? true { flags.insert(flag) } else { flags.remove(flag) }
    }

    private func hlGroupSet(_ tuple: [MPValue]) {
        guard tuple.count >= 2, let name = tuple[0].stringValue,
              let id = asInt(tuple[1]) else { return }

        let type: HLGroup
        if name.hasPrefix("StatusLine") {
            type = .statusLine
        } else if name == "WinSeparator" || name == "VertSplit" {
            type = .separator
        } else if name.hasPrefix("TabLine") {
            type = .tabline
        } else {
            return
        }

        let previousID = hlGroupMappings[name]?.id ?? id
        hlGroupMappings[name] = (id, type)

        let maxID = max(id, previousID)
        if maxID >= hlGroupTypes.count {
            hlGroupTypes.append(contentsOf:
                Array(repeating: 0, count: maxID + 1 - hlGroupTypes.count))
        }

        // Groups can share an attribute id, so recompute the combined bits for both
        // the id this group moved from and the id it moved to.
        recomputeGroupType(previousID)
        if id != previousID { recomputeGroupType(id) }
    }

    private func recomputeGroupType(_ changedID: Int) {
        guard changedID >= 0, changedID < hlGroupTypes.count else { return }
        var combined: HLGroup = []
        for (_, mapping) in hlGroupMappings where mapping.id == changedID {
            combined.insert(mapping.type)
        }
        hlGroupTypes[changedID] = combined.rawValue
    }

    private func defaultColorsSet(_ tuple: [MPValue]) {
        guard tuple.count >= 3, let fg = tuple[0].integer?.value(as: UInt32.self),
              let bg = tuple[1].integer?.value(as: UInt32.self),
              let sp = tuple[2].integer?.value(as: UInt32.self) else { return }

        defaultBackgroundRGB = bg

        var def = CellAttributes()
        def.foreground = RGBColor(neovim: fg, default: ())
        def.background = RGBColor(neovim: bg, default: ())
        def.special = RGBColor(neovim: sp, default: ())
        hlTable[0] = def

        for index in hlTable.indices { adjustDefaultColors(&hlTable[index], against: def) }
        for index in writing.cells.indices { writing.cells[index].adjustDefaults(def) }
    }

    // MARK: Modes

    private func modeInfoSet(_ tuple: [MPValue]) {
        guard tuple.count >= 2, case .array(let propertyMaps) = tuple[1] else { return }
        let currentShortname = writing.modeState.cursor.shortname
        modeTable.removeAll(keepingCapacity: true)
        modeTable.reserveCapacity(propertyMaps.count)

        for object in propertyMaps {
            guard case .map(let map) = object else { continue }
            let state = modeState(from: map)
            if state.cursor.shortname == currentShortname { writing.modeState = state }
            modeTable.append(state)
        }
    }

    private func modeState(from map: [(MPValue, MPValue)]) -> ModeState {
        var state = ModeState()
        var attrs = CursorAttributes()
        var semantic: UIMode?
        var shortnameSemantic: UIMode?

        for (key, value) in map {
            guard let name = key.stringValue else { continue }
            switch name {
            case "cell_percentage":
                if let v = value.integer?.value(as: UInt16.self) { attrs.percentage = v }
            case "blinkwait":
                if let v = value.integer?.value(as: UInt16.self) { attrs.blinkwait = v }
            case "blinkon":
                if let v = value.integer?.value(as: UInt16.self) { attrs.blinkon = v }
            case "blinkoff":
                if let v = value.integer?.value(as: UInt16.self) { attrs.blinkoff = v }
            case "cursor_shape":
                if let shape = value.stringValue { attrs.shape = cursorShape(shape) }
            case "attr_id":
                if let id = asInt(value) { setCursorColors(&attrs, hlid: id) }
            case "short_name":
                if let shortname = value.stringValue {
                    shortnameSemantic = classifyUIModeShortname(shortname)
                    attrs.shortname = CursorAttributes.encodeShortname(shortname)
                }
            case "name":
                if let modeName = value.stringValue {
                    semantic = classifyUIModeName(modeName)
                }
            default: break
            }
        }

        if semantic == nil, let fallback = shortnameSemantic { semantic = fallback }
        if attrs.blinkwait != 0, attrs.blinkoff != 0, attrs.blinkon != 0 { attrs.blinks = true }

        state.semantic = semantic ?? .other
        state.cursor = attrs
        return state
    }

    private func cursorShape(_ name: String) -> CursorShape {
        switch name {
        case "block": return .block
        case "vertical": return .vertical
        case "horizontal": return .horizontal
        default: return .block
        }
    }

    private func setCursorColors(_ attrs: inout CursorAttributes, hlid: Int) {
        let entry = hlEntry(hlid)
        attrs.special = entry.special
        if hlid != 0 {
            attrs.foreground = entry.foreground
            attrs.background = entry.background
        } else {
            // The default highlight swaps foreground and background for cursor
            // visibility. Rebuild the colors without the default flag so the cursor
            // constructor does not swap them a second time.
            let fg = entry.foreground, bg = entry.background
            attrs.foreground = RGBColor(red: bg.red, green: bg.green, blue: bg.blue)
            attrs.background = RGBColor(red: fg.red, green: fg.green, blue: fg.blue)
        }
    }

    private func modeChange(_ tuple: [MPValue]) {
        guard tuple.count >= 2, let index = asInt(tuple[1]),
              index >= 0, index < modeTable.count else { return }
        writing.modeState = modeTable[index]
    }

    // MARK: Options, title, viewport, handoff

    private func setTitle(_ tuple: [MPValue]) {
        guard let value = tuple.first?.stringValue else { return }
        title = value
    }

    private func winViewport(_ tuple: [MPValue]) {
        guard tuple.count >= 7, let topline = asInt(tuple[2]),
              let botline = asInt(tuple[3]), let lineCount = asInt(tuple[6]) else { return }
        viewport.topline = topline
        viewport.botline = botline
        viewport.lineCount = lineCount
    }

    private func setOption(_ tuple: [MPValue]) {
        guard tuple.count >= 2, let name = tuple[0].stringValue else { return }
        let value = tuple[1]
        switch name {
        case "guifont":
            if let font = value.stringValue { guifont = font }
        case "mousemoveevent":
            if let on = value.boolValue { mousemoveevent = on }
        case "ambiwidth":
            if let width = value.stringValue { ambiguousWidthDouble = width == "double" }
        case "emoji":
            if let on = value.boolValue { emojiWidthDouble = on }
        case "ext_cmdline": if let on = value.boolValue { uiOptions.extCmdline = on }
        case "ext_hlstate": if let on = value.boolValue { uiOptions.extHlstate = on }
        case "ext_linegrid": if let on = value.boolValue { uiOptions.extLinegrid = on }
        case "ext_messages": if let on = value.boolValue { uiOptions.extMessages = on }
        case "ext_multigrid": if let on = value.boolValue { uiOptions.extMultigrid = on }
        case "ext_popupmenu": if let on = value.boolValue { uiOptions.extPopupmenu = on }
        case "ext_tabline": if let on = value.boolValue { uiOptions.extTabline = on }
        case "ext_termcolors": if let on = value.boolValue { uiOptions.extTermcolors = on }
        default: break
        }
    }

    private func applyHandoff(_ args: ArraySlice<MPValue>, _ kind: UIHandoff.Kind) {
        // Neovim sends ["restart", address] with a bare string argument before the
        // old channel closes; also accept the normal tuple form.
        if args.count == 1, let address = args.first?.stringValue {
            handoff = UIHandoff(kind: kind, address: address)
            return
        }
        forEachTuple(args) { tuple in
            if let address = tuple.first?.stringValue {
                self.handoff = UIHandoff(kind: kind, address: address)
            }
        }
    }

    // MARK: Flush

    private func flush() -> Grid {
        writing.drawTick += 1
        writing.title = title
        writing.defaultBackground = defaultBackgroundColor
        globalGrid = writing
        return globalGrid
    }

    // MARK: Progress (a separate rpcnotify channel, not a redraw event)

    /// Applies one `Progress` autocmd event. Returns the completed percentage when
    /// a task finished with a known percentage, otherwise nil.
    @discardableResult
    func progress(_ event: [(MPValue, MPValue)]) -> Int? {
        func field(_ key: String) -> MPValue? {
            for (name, value) in event where name.stringValue == key { return value }
            return nil
        }

        guard let id = field("id"), let statusValue = field("status"),
              let status = statusValue.stringValue else { return nil }

        let key: String
        if let signed = id.integer?.signed {
            key = "i:\(signed)"
        } else if let string = id.stringValue {
            key = "s:\(string)"
        } else {
            return nil
        }

        func clampedPercent() -> Int? {
            guard let raw = field("percent")?.integer?.signed else { return nil }
            return Int(min(max(raw, 0), 100))
        }

        switch status {
        case "success", "failed", "cancel":
            let completed = clampedPercent()
            progressEntries.removeValue(forKey: key)
            return completed
        case "running":
            let percent = clampedPercent()
            if percent == 100 {
                progressEntries.removeValue(forKey: key)
                return 100
            }
            progressSequence += 1
            progressEntries[key] = ProgressEntry(percent: percent, sequence: progressSequence)
            return nil
        default:
            return nil
        }
    }

    /// The most recently updated known progress percentage, if any is active.
    var progressPercent: Int? {
        var percent: Int?
        var newest: UInt64 = 0
        for (_, entry) in progressEntries {
            if let value = entry.percent, entry.sequence > newest {
                percent = value
                newest = entry.sequence
            }
        }
        return percent
    }

    /// Updates the current buffer's modified state.
    func setModified(_ value: Bool) { modified = value }
}

/// Extracts a signed `Int` from a MessagePack integer, or nil for non-integers.
private nonisolated func asInt(_ value: MPValue) -> Int? {
    value.integer.map { Int(truncatingIfNeeded: $0.signed) }
}
