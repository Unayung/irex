import UIKit
import GhosttyVt

/// One drawable cell, already color-resolved by libghostty.
struct Cell {
    var x: Int
    var width: Int
    var text: String
    var fg: UIColor
    var bg: UIColor?
    var bold, italic, faint, underline, strike: Bool
}

struct Frame {
    var rows: [[Cell]] = []
    var background = UIColor.black
    var foreground = UIColor.white
    var cursorColor = UIColor.white
    var cursor: (x: Int, y: Int, width: Int)?
    var cursorStyle = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
}

/// A local mirror of a Rex block's terminal. It never answers the program (no WRITE_PTY callback):
/// the server's terminal does that. Everything here runs on the main actor; libghostty has no locking.
@MainActor
final class TerminalModel {
    var onChange: (() -> Void)?
    private(set) var cellPx: (w: UInt32, h: UInt32) = (8, 16)

    private var term: GhosttyTerminal?
    private var render: GhosttyRenderState?
    private var rowIter: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var encoder: GhosttyKeyEncoder?
    private var keyEvent: GhosttyKeyEvent?
    private var mouseEncoder: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?
    private var builtinFg = GhosttyColorRgb(r: 255, g: 255, b: 255)
    private var builtinBg = GhosttyColorRgb(r: 0, g: 0, b: 0)

    init() {
        ghostty_terminal_new(nil, &term, 80, 24)
        ghostty_render_state_new(nil, &render)
        ghostty_render_state_row_iterator_new(nil, &rowIter)
        ghostty_render_state_row_cells_new(nil, &rowCells)
        ghostty_key_encoder_new(nil, &encoder)
        ghostty_key_event_new(nil, &keyEvent)
        ghostty_mouse_encoder_new(nil, &mouseEncoder)
        ghostty_mouse_event_new(nil, &mouseEvent)
        ghostty_render_state_update(render, term)
        var c = GhosttyRenderStateColors(); c.size = MemoryLayout<GhosttyRenderStateColors>.size
        if ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLORS, &c) == GHOSTTY_SUCCESS {
            builtinFg = c.foreground; builtinBg = c.background
        }
    }

    deinit {
        // ponytail: deinit isn't main-actor isolated in Swift 5 mode, but nothing else can touch these now.
        ghostty_key_event_free(keyEvent); ghostty_key_encoder_free(encoder)
        ghostty_mouse_event_free(mouseEvent); ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_render_state_row_cells_free(rowCells); ghostty_render_state_row_iterator_free(rowIter)
        ghostty_render_state_free(render); ghostty_terminal_free(term)
    }

    // MARK: stream input

    func restoreSnapshot(_ data: Data) -> Bool {
        let bytes = [UInt8](data)   // decoder doesn't copy; keep alive until free
        return bytes.withUnsafeBufferPointer { buf -> Bool in
            var dec: GhosttySnapshotDecoder?
            guard ghostty_snapshot_decoder_new_buf(nil, &dec, buf.baseAddress, buf.count) == GHOSTTY_SUCCESS else { return false }
            defer { ghostty_snapshot_decoder_free(dec) }
            var restored: GhosttyTerminal?
            var r = ghostty_snapshot_decoder_ready(dec, &restored)
            if r == GHOSTTY_SUCCESS {
                repeat { r = ghostty_snapshot_decoder_next(dec) } while r == GHOSTTY_SUCCESS
            }
            var end = 0
            guard r == GHOSTTY_NO_VALUE,
                  ghostty_snapshot_decoder_get(dec, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &end) == GHOSTTY_SUCCESS,
                  let restored else {
                if let restored { ghostty_terminal_free(restored) }
                return false
            }
            // The render state caches rows of one terminal, so it is replaced together with it.
            var newRender: GhosttyRenderState?
            ghostty_render_state_new(nil, &newRender)
            ghostty_render_state_free(render); ghostty_terminal_free(term)
            render = newRender; term = restored
            if end < buf.count { ghostty_terminal_vt_write(term, buf.baseAddress! + end, buf.count - end) }
            onChange?()
            return true
        }
    }

    func feed<D: DataProtocol>(_ data: D) {
        guard !data.isEmpty else { return }
        let bytes = [UInt8](data)
        ghostty_terminal_vt_write(term, bytes, bytes.count)
        onChange?()
    }

    func resizeGrid(cols: Int, rows: Int) {
        guard (1...65535).contains(cols), (1...65535).contains(rows) else { return }
        ghostty_terminal_resize(term, UInt16(cols), UInt16(rows), cellPx.w, cellPx.h)
        onChange?()
    }

    func setCellSize(width: CGFloat, height: CGFloat) {
        cellPx = (UInt32(width.rounded(.up)), UInt32(height.rounded(.up)))
    }

    /// Rex's in-band `theme`: foreground/background/cursor ("RRGGBB" or "#RRGGBB"), palette ["i=RRGGBB"].
    func setTheme(_ m: [String: Any]) {
        func parse(_ key: String) -> GhosttyColorRgb? {
            guard let s = m[key] as? String else { return nil }
            var rgb = GhosttyColorRgb()
            return ghostty_color_parse(s, s.utf8.count, &rgb) == GHOSTTY_SUCCESS ? rgb : nil
        }
        // Render state honours fg/bg only while both are set, so fall back to built-ins instead of clearing.
        var fg = parse("foreground") ?? builtinFg, bg = parse("background") ?? builtinBg
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if var cur = parse("cursor") { ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cur) }
        else { ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil) }
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        ghostty_color_palette_default(&palette)
        var changed = false
        for e in m["palette"] as? [String] ?? [] {
            var idx: UInt8 = 0, rgb = GhosttyColorRgb()
            if ghostty_color_parse_palette_entry(e, e.utf8.count, &idx, &rgb) == GHOSTTY_SUCCESS { palette[Int(idx)] = rgb; changed = true }
        }
        if changed { ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette) }
        else { ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, nil) }
        onChange?()
    }

    // MARK: user input → bytes

    /// Encodes one key through libghostty (honours cursor-key mode, Kitty flags, …).
    /// `text` must already exclude control characters and the U+F700 function-key range.
    func encodeKey(action: GhosttyKeyAction, key: GhosttyKey, mods: GhosttyMods, text: String, unshifted: UInt32) -> Data {
        ghostty_key_event_set_action(keyEvent, action)
        ghostty_key_event_set_key(keyEvent, key)
        ghostty_key_event_set_mods(keyEvent, mods)
        ghostty_key_event_set_consumed_mods(keyEvent, text.isEmpty ? 0 : mods & GhosttyMods(GHOSTTY_MODS_SHIFT))
        ghostty_key_event_set_composing(keyEvent, false)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, unshifted)
        ghostty_key_encoder_setopt_from_terminal(encoder, term)
        var utf8 = Array(text.utf8)
        return utf8.withUnsafeMutableBufferPointer { u -> Data in
            u.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(u.count, 1)) {
                ghostty_key_event_set_utf8(keyEvent, u.isEmpty ? nil : $0, u.count)
            }
            var out = [CChar](repeating: 0, count: 128), len = 0
            var r = ghostty_key_encoder_encode(encoder, keyEvent, &out, out.count, &len)
            if r == GHOSTTY_OUT_OF_SPACE {
                out = [CChar](repeating: 0, count: len)
                r = ghostty_key_encoder_encode(encoder, keyEvent, &out, out.count, &len)
            }
            ghostty_key_event_set_utf8(keyEvent, nil, 0)
            return r == GHOSTTY_SUCCESS ? Data(bytes: out, count: len) : Data()
        }
    }

    func encodePaste(_ s: String) -> Data {
        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2004, false), value: false)
        let bracketed = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS && mode.value
        var input = Array(s.utf8CString.dropLast())   // encoder rewrites control bytes in place
        var out = [CChar](repeating: 0, count: input.count + 16), written = 0
        guard ghostty_paste_encode(&input, input.count, bracketed, &out, out.count, &written) == GHOSTTY_SUCCESS else { return Data() }
        return Data(bytes: out, count: written)
    }

    func scrollToBottom() {
        var atBottom = true
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &atBottom)
        guard !atBottom else { return }
        var s = GhosttyTerminalScrollViewport(); s.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(term, s); onChange?()
    }

    /// Scrolls `lines` toward older output (negative: newer), the way orex handles a wheel. A program
    /// that tracks the mouse gets wheel presses (buttons 4/5), a full-screen one under alt-scroll gets
    /// arrow keys, and anything else moves the local viewport. Returns the bytes for the program.
    func wheel(lines: Int, at p: CGPoint, view: CGSize, cell: CGSize) -> Data {
        guard lines != 0 else { return Data() }
        let n = abs(lines)
        var tracking = false
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        if tracking {
            ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, term)
            var size = GhosttyMouseEncoderSize(); size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
            size.screen_width = UInt32(max(1, view.width)); size.screen_height = UInt32(max(1, view.height))
            size.cell_width = UInt32(max(1, cell.width)); size.cell_height = UInt32(max(1, cell.height))
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
            ghostty_mouse_event_set_action(mouseEvent, GHOSTTY_MOUSE_ACTION_PRESS)
            ghostty_mouse_event_set_button(mouseEvent, lines > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE)
            ghostty_mouse_event_set_mods(mouseEvent, 0)
            ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(p.x), y: Float(p.y)))
            var buf = [CChar](repeating: 0, count: 64), len = 0
            guard ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &buf, buf.count, &len) == GHOSTTY_SUCCESS else { return Data() }
            return Data(repeatElement(buf.prefix(len).map { UInt8(bitPattern: $0) }, count: n).joined())
        }
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        var altScroll = GhosttyTerminalModeConfig(mode: ghostty_mode_new(1007, false), value: false)
        if screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE,
           ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &altScroll) == GHOSTTY_SUCCESS, altScroll.value {
            let arrow = encodeKey(action: GHOSTTY_KEY_ACTION_PRESS, key: lines > 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN,
                                  mods: 0, text: "", unshifted: 0)
            return Data(repeatElement(arrow, count: n).joined())
        }
        scroll(lines: -lines)
        return Data()
    }

    func scroll(lines: Int) {
        var s = GhosttyTerminalScrollViewport(); s.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA; s.value.delta = lines
        ghostty_terminal_scroll_viewport(term, s); onChange?()
    }

    // MARK: render

    func frame() -> Frame {
        var f = Frame()
        guard ghostty_render_state_update(render, term) == GHOSTTY_SUCCESS else { return f }
        var colors = GhosttyRenderStateColors(); colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        var cur = GhosttyRenderStateCursor(); cur.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cur)
        f.background = colors.background.ui; f.foreground = colors.foreground.ui
        f.cursorColor = colors.cursor_has_value ? colors.cursor.ui : f.foreground
        f.cursorStyle = cur.visual_style
        let cursorX = cur.visible && cur.viewport_has_value ? Int(cur.viewport_x) - (cur.wide_tail ? 1 : 0) : -1

        var grapheme = [UInt8](repeating: 0, count: 64)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIter)
        var y = 0
        while ghostty_render_state_row_iterator_next(rowIter) {
            ghostty_render_state_row_get(rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)
            var line: [Cell] = []
            var x = 0
            while ghostty_render_state_row_cells_next(rowCells) {
                defer { x += 1 }
                var raw: GhosttyCell = 0
                ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
                var wide = GHOSTTY_CELL_WIDE_NARROW
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }
                var style = GhosttyStyle(); style.size = MemoryLayout<GhosttyStyle>.size
                ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                let text = readGrapheme(&grapheme)
                var fg = colors.foreground, bg = colors.background
                if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) != GHOSTTY_SUCCESS { fg = colors.foreground }
                var hasBg = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS
                if style.inverse { swap(&fg, &bg); if !hasBg { bg = colors.background }; hasBg = true
                    if bg.r == fg.r && bg.g == fg.g && bg.b == fg.b { fg = colors.background } }
                line.append(Cell(x: x, width: wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1,
                                 text: style.invisible ? "" : text, fg: fg.ui, bg: hasBg ? bg.ui : nil,
                                 bold: style.bold, italic: style.italic, faint: style.faint,
                                 underline: style.underline != 0, strike: style.strikethrough))
            }
            if cursorX >= 0 && y == Int(cur.viewport_y) {
                f.cursor = (cursorX, y, line.first { $0.x == cursorX }?.width ?? 1)
            }
            f.rows.append(line)
            y += 1
        }
        ghostty_render_state_clean(render)
        return f
    }

    private func readGrapheme(_ buf: inout [UInt8]) -> String {
        for _ in 0..<2 {
            let r = buf.withUnsafeMutableBufferPointer { p -> (GhosttyResult, Int) in
                var b = GhosttyBuffer(ptr: p.baseAddress, cap: p.count, len: 0)
                let r = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &b)
                return (r, b.len)
            }
            if r.0 == GHOSTTY_SUCCESS { return String(decoding: buf[0..<r.1], as: UTF8.self) }
            if r.0 == GHOSTTY_OUT_OF_SPACE { buf = [UInt8](repeating: 0, count: r.1); continue }
            return ""
        }
        return ""
    }
}

extension GhosttyColorRgb {
    var ui: UIColor { UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
}
