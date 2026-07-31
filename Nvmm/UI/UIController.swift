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

/// What one `Progress` event means for the progress bar.
nonisolated enum ProgressOutcome: Sendable, Equatable {
    /// Nothing to show: the event named no task, or reported a status the UI
    /// does not track.
    case ignored
    /// The set of running tasks changed; the bar shows the newest known
    /// percentage among them, or hides when none is known.
    case changed
    /// A task finished at a known percentage. The bar shows it briefly, so a
    /// task that completes in one step is still seen, then falls back.
    case completed(Int)
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
    // Upper bound on distinct highlight ids. The highlight tables are dense,
    // indexed by id, so an id defines every entry below it too. Capping the id
    // keeps a sparse or malformed definition from growing the tables without
    // bound; a definition at or past the cap is dropped.
    private static let maxHighlightID = 1 << 16

    private let limits: RPCResourceLimits
    // Highlight state.
    private var hlTable: [CellAttributes] = [.defaultGroup]
    private var modeTable: [ModeState] = []
    private var hlGroupTypes: [UInt8] = []                 // hlid -> HLGroup bits
    private var hlGroupMappings: [String: (id: Int, type: HLGroup)] = [:]

    // The grid being written to, and the most recent flushed snapshot.
    private var writing = Grid()
    private(set) var globalGrid = Grid()
    private struct ActiveGridLine {
        var rowBegin: Int
        var index: Int
        var remaining: Int
        var highlightID = 0
        var attributes: CellAttributes?
    }
    private var activeGridLine: ActiveGridLine?

    // Scalar option/state snapshots.
    private(set) var defaultBackgroundRGB: UInt32 = 0
    private(set) var mousemoveevent = false
    private(set) var ambiguousWidthDouble = false
    private(set) var emojiWidthDouble = true
    private(set) var modified = false
    private(set) var title = "NVIM"
    private(set) var guifont = ""
    // Set once Neovim fires `VimEnter`; stamped onto each flushed snapshot.
    private(set) var vimentered = false
    private(set) var uiOptions = UIOptions()
    private(set) var viewport = ViewportState()
    private(set) var handoff: UIHandoff?

    // Progress tracking, keyed by task id, most-recent-known percentage wins.
    private struct ProgressEntry { var percent: Int?; var sequence: UInt64 }
    private var progressEntries: [String: ProgressEntry] = [:]
    private var progressSequence: UInt64 = 0

    init(limits: RPCResourceLimits = .production) {
        self.limits = limits
    }

    /// The default background color, tagged as a default color.
    var defaultBackgroundColor: RGBColor {
        RGBColor(neovim: defaultBackgroundRGB, default: ())
    }

    // MARK: Redraw entry point

    /// Applies a batch and retains only its newest complete snapshot.
    func redraw(_ events: [MPValue]) -> [Grid] {
        var latest: Grid?
        for event in events {
            if let flushed = applyRedrawEvent(event) { latest = flushed }
        }
        return latest.map { [$0] } ?? []
    }

    /// Applies one event from a streaming redraw notification.
    func applyRedrawEvent(_ event: MPValue) -> Grid? {
        guard case .array(let fields) = event,
              let name = fields.first?.stringValue else { return nil }
        let args = fields.dropFirst()

        switch name {
        case "grid_line": forEachTuple(args, gridLine)
        case "grid_resize": forEachTuple(args, gridResize)
        case "grid_scroll": forEachTuple(args, gridScroll)
        case "grid_clear": forEachTuple(args, gridClear)
        case "grid_cursor_goto": forEachTuple(args, gridCursorGoto)
        case "flush":
            return args.contains { $0.arrayValue != nil } ? flush() : nil
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
        return nil
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
              let width = asInt(tuple[1]), let height = asInt(tuple[2]),
              width <= limits.maximumGridWidth,
              height <= limits.maximumGridHeight else { return }
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
              let row = asIndex(tuple[1]), let col = asIndex(tuple[2]),
              row < writing.height, col < writing.width else { return }
        writing.cursorRow = row
        writing.cursorCol = col
    }

    private func gridScroll(_ tuple: [MPValue]) {
        guard tuple.count >= 6,
              let top = asIndex(tuple[1]), let bottom = asIndex(tuple[2]),
              let left = asIndex(tuple[3]), let right = asIndex(tuple[4]),
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
              case .array(let updates) = tuple[3] else { return }
        beginStreamingGridLine(Array(tuple.prefix(3)))
        for update in updates { applyStreamingGridLineCell(update) }
        endStreamingGridLine(tuple.count > 4 ? tuple[4] : .invalid)
    }

    func beginStreamingGridLine(_ prefix: [MPValue]) {
        activeGridLine = nil
        guard prefix.count == 3, isMainGrid(prefix[0]),
              let row = asIndex(prefix[1]), let col = asIndex(prefix[2])
        else { return }
        guard row < writing.height, col < writing.width else { return }

        let rowBegin = row * writing.width
        activeGridLine = ActiveGridLine(
            rowBegin: rowBegin, index: rowBegin + col,
            remaining: writing.width - col)
    }

    func applyStreamingGridLineCell(_ object: MPValue) {
        guard var line = activeGridLine,
              case .array(let fields) = object,
              let text = fields.first?.stringValue,
              text.utf8.count <= limits.maximumCellTextBytes else {
            activeGridLine = nil
            return
        }

        var repeatCount = 1
        switch fields.count {
        case 1:
            break
        case 2:
            guard let id = asInt(fields[1]) else {
                activeGridLine = nil
                return
            }
            line.highlightID = id
            line.attributes = hlEntry(id)
        case 3:
            guard let id = asInt(fields[1]),
                  let count = asInt(fields[2]) else {
                activeGridLine = nil
                return
            }
            line.highlightID = id
            line.attributes = hlEntry(id)
            repeatCount = count
        default:
            activeGridLine = nil
            return
        }

        guard let attributes = line.attributes,
              repeatCount <= line.remaining else {
            activeGridLine = nil
            return
        }
        let pointerStyle: UInt8 =
            line.highlightID >= 0 && line.highlightID < hlGroupTypes.count
            ? hlGroupTypes[line.highlightID] : 0

        if text.isEmpty {
            guard line.index != line.rowBegin else {
                activeGridLine = nil
                return
            }
            writing.cells[line.index - 1].addDoubleWidth()
            var right = Cell()
            right.setAttributes(writing.cells[line.index - 1].attributes)
            right.pointerStyle = pointerStyle
            writing.cells[line.index] = right
            line.index += 1
            line.remaining -= 1
        } else if repeatCount > 0 {
            let updated = Cell(text: text, attrs: attributes,
                               pointerStyle: pointerStyle)
            for offset in 0..<repeatCount {
                writing.cells[line.index + offset] = updated
            }
            line.index += repeatCount
            line.remaining -= repeatCount
        }
        activeGridLine = line
    }

    func endStreamingGridLine(_ wrap: MPValue) {
        activeGridLine = nil
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
        guard tuple.count >= 2, let hlid = asInt(tuple[0]),
              hlid >= 0, hlid < Self.maxHighlightID,
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
              name.utf8.count <= 128,
              let id = asInt(tuple[1]), id >= 0, id < Self.maxHighlightID
        else { return }

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

        if hlGroupMappings[name] == nil,
           hlGroupMappings.count >= limits.maximumHighlightGroupMappings {
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
            if let font = value.stringValue,
               font.utf8.count <= limits.maximumGuifontBytes {
                guifont = font
            }
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
        writing.ambiguousWidthDouble = ambiguousWidthDouble
        writing.emojiWidthDouble = emojiWidthDouble
        writing.mouseMoveEvent = mousemoveevent
        writing.guifont = guifont
        writing.viewport = viewport
        writing.startupComplete = vimentered
        globalGrid = writing
        return globalGrid
    }

    // MARK: Progress (a separate rpcnotify channel, not a redraw event)

    /// Applies one `Progress` autocmd event. Returns what the window should do
    /// about it; an event that names no task, or reports a status we do not
    /// track, changes nothing.
    @discardableResult
    func progress(_ event: [(MPValue, MPValue)]) -> ProgressOutcome {
        func field(_ key: String) -> MPValue? {
            for (name, value) in event where name.stringValue == key { return value }
            return nil
        }

        guard let id = field("id"), let statusValue = field("status"),
              let status = statusValue.stringValue else { return .ignored }

        // The id may be a number or a name, and the two namespaces are
        // separate: task 1 and task "1" are different tasks.
        let key: String
        if let signed = id.integer?.signed {
            key = "i:\(signed)"
        } else if let string = id.stringValue {
            key = "s:\(string)"
        } else {
            return .ignored
        }

        func clampedPercent() -> Int? {
            guard let raw = field("percent")?.integer?.signed else { return nil }
            return Int(min(max(raw, 0), 100))
        }

        switch status {
        case "success", "failed", "cancel":
            let completed = clampedPercent()
            progressEntries.removeValue(forKey: key)
            // A task that ends without a percentage has nothing to show for
            // itself, so the bar just falls back to whatever else is running.
            return completed.map { .completed($0) } ?? .changed
        case "running":
            let percent = clampedPercent()
            // A task at 100% is finished in all but name; treat it as one, so
            // the bar does not sit full waiting for a terminal status that
            // some tasks never send.
            if percent == 100 {
                progressEntries.removeValue(forKey: key)
                return .completed(100)
            }
            if progressEntries[key] == nil,
               progressEntries.count >= limits.maximumProgressEntries,
               let oldest = progressEntries.min(by: {
                   $0.value.sequence < $1.value.sequence
               })?.key {
                progressEntries.removeValue(forKey: oldest)
            }
            progressSequence += 1
            progressEntries[key] = ProgressEntry(percent: percent, sequence: progressSequence)
            return .changed
        default:
            return .ignored
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

    /// Records that Neovim has fired `VimEnter`, so subsequent snapshots are
    /// marked startup-complete.
    func vimenter() { vimentered = true }

    /// Updates the current buffer's modified state. Returns true when the value
    /// changed, so the caller can publish only on a transition.
    @discardableResult
    func setModified(_ value: Bool) -> Bool {
        guard value != modified else { return false }
        modified = value
        return true
    }
}

/// Extracts a signed `Int` from a MessagePack integer, or nil for non-integers.
private nonisolated func asInt(_ value: MPValue) -> Int? {
    value.integer.map { Int(truncatingIfNeeded: $0.signed) }
}

/// A grid coordinate decoded from the wire: nil unless it is a nonnegative
/// integer. Rejecting negatives here lets each handler's existing upper-bound
/// check (`< width`, `<= height`) stand in for a full range check, the way the
/// reference's unsigned `size_t` coordinates collapse negative and too-large
/// into one failure. A coordinate large enough to overflow later arithmetic is
/// caught first by that upper-bound check, before it is used.
private nonisolated func asIndex(_ value: MPValue) -> Int? {
    guard let raw = value.integer?.signed, raw >= 0 else { return nil }
    return Int(raw)
}
