import UIKit
import GhosttyVt

/// Draws a TerminalModel and turns keyboard input into terminal bytes.
/// Printable text arrives through UIKeyInput.insertText (so the software keyboard and IME work);
/// special keys and Ctrl/Option chords are caught in pressesBegan and go through libghostty's encoder.
final class TerminalView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    let model: TerminalModel
    var onInput: ((Data) -> Void)?
    var onGridSize: ((Int, Int) -> Void)?
    var onActivate: ((ClaimTrigger) -> Void)?
    var onEdgeSwipe: (() -> Void)?
    var onEdgeHover: ((CGFloat?) -> Void)?
    var onCompose: (() -> Void)?
    var onSwipePane: ((Int) -> Void)?            // +1 next pane, -1 previous
    var onFontSizeChange: ((CGFloat) -> Void)?
    var onCellTap: ((Int, Int) -> Void)?         // column, row of the server's screen
    let interactive: Bool                        // false: a preview that only draws

    private var font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private(set) var fontSize: CGFloat = 14
    private var fonts: [UIFont] = []     // regular, bold, italic, bold-italic
    private var cw: CGFloat = 8, ch: CGFloat = 16, baseline: CGFloat = 12
    private var grid = (cols: 0, rows: 0)
    private var repeatTimer: Timer?
    private var panRemainder: CGFloat = 0
    private var ctrlArmed = false { didSet { ctrlButton?.isSelected = ctrlArmed } }
    private weak var ctrlButton: UIButton?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private lazy var keyBar = makeKeyBar()
    private var scale: CGFloat = 1               // < 1 while showing another client's larger grid
    private var selection: (a: (x: Int, y: Int), b: (x: Int, y: Int))?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var pinchBase: CGFloat = 14
    private weak var scrollPan: UIPanGestureRecognizer?
    private weak var panePan: UIPanGestureRecognizer?

    init(model: TerminalModel, interactive: Bool = true) {
        self.model = model
        self.interactive = interactive
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
        setFont(size: 14)
        model.onChange = { [weak self] in self?.setNeedsDisplay() }
        guard interactive else { isUserInteractionEnabled = false; return }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        // Up and down scrolls; sideways moves to the next or previous pane.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.allowedScrollTypesMask = .continuous   // trackpad two-finger scroll
        pan.delegate = self
        addGestureRecognizer(pan)
        scrollPan = pan
        let sideways = UIPanGestureRecognizer(target: self, action: #selector(swiped))
        sideways.delegate = self
        addGestureRecognizer(sideways)
        panePan = sideways
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped))
        edge.edges = .left
        addGestureRecognizer(edge)
        pan.require(toFail: edge)        // a swipe from the left edge goes back (iPhone) or opens the sidebar (iPad)
        sideways.require(toFail: edge)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        press.minimumPressDuration = 0.35
        addGestureRecognizer(press)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        addInteraction(editMenu)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setFont(size: CGFloat) {
        fontSize = size
        font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        func italic(_ f: UIFont) -> UIFont { f.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: size) } ?? f }
        fonts = [font, bold, italic(font), italic(bold)]
        let scale = window?.screen.scale ?? 2
        // Snap cells to device pixels so adjacent backgrounds have no seams.
        cw = (("M" as NSString).size(withAttributes: [.font: font]).width * scale).rounded(.up) / scale
        ch = (font.lineHeight * scale).rounded(.up) / scale
        baseline = font.ascender + (ch - font.lineHeight) / 2
        model.setCellSize(width: cw * scale, height: ch * scale)
        refit()
        setNeedsDisplay()
    }

    // The first setFont runs before there's a screen to ask; redo it at the real scale (3x on iPhone).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setFont(size: fontSize) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refit()
    }

    private func refit() {
        let cols = Int(bounds.width / cw), rows = Int(bounds.height / ch)
        guard cols > 0, rows > 0, (cols, rows) != grid else { return }
        grid = (cols, rows)
        onGridSize?(cols, rows)
    }

    // MARK: drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let f = model.frame()
        ctx.setFillColor(f.background.cgColor)
        ctx.fill(bounds)
        // Another client owns a bigger grid: show all of it, scaled down to fit.
        let cols = f.rows.map { $0.last.map { $0.x + $0.width } ?? 0 }.max() ?? 0
        scale = min(1, bounds.width / max(1, CGFloat(cols) * cw), bounds.height / max(1, CGFloat(f.rows.count) * ch))
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: scale, y: scale)
        if let (a, b) = orderedSelection() {
            ctx.setFillColor(tintColor.withAlphaComponent(0.35).cgColor)
            for y in a.y...b.y {
                let from = y == a.y ? a.x : 0, to = y == b.y ? b.x : cols - 1
                ctx.fill(CGRect(x: CGFloat(from) * cw, y: CGFloat(y) * ch, width: CGFloat(to - from + 1) * cw, height: ch))
            }
        }
        for (y, row) in f.rows.enumerated() {
            let top = CGFloat(y) * ch
            for c in row where c.bg != nil {
                ctx.setFillColor(c.bg!.cgColor)
                ctx.fill(CGRect(x: CGFloat(c.x) * cw, y: top, width: CGFloat(c.width) * cw, height: ch))
            }
            drawText(row, top: top, ctx: ctx)
        }
        if let cur = f.cursor {
            let r = CGRect(x: CGFloat(cur.x) * cw, y: CGFloat(cur.y) * ch, width: CGFloat(cur.width) * cw, height: ch)
            ctx.setFillColor(f.cursorColor.cgColor)
            ctx.setStrokeColor(f.cursorColor.cgColor)
            switch isFirstResponder ? f.cursorStyle : GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW {
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: ctx.fill(CGRect(x: r.minX, y: r.minY, width: 2, height: ch))
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: ctx.fill(CGRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2))
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5), width: 1)
            default:
                ctx.fill(r)
                if let c = f.rows[cur.y].first(where: { $0.x == cur.x }), !c.text.isEmpty {
                    draw(c.text, x: r.minX, top: r.minY, font: fonts[(c.bold ? 1 : 0) | (c.italic ? 2 : 0)], color: c.bg ?? f.background)
                }
            }
        }
    }

    /// ASCII runs are drawn as one string; everything else per cell at x*cw so fallback-font
    /// advances (CJK, emoji) can't drift off the grid.
    private func drawText(_ row: [Cell], top: CGFloat, ctx: CGContext) {
        var i = 0
        while i < row.count {
            let c = row[i]
            guard !c.text.isEmpty else { i += 1; continue }
            let fontIdx = (c.bold ? 1 : 0) | (c.italic ? 2 : 0)
            let color = c.faint ? c.fg.withAlphaComponent(0.5) : c.fg
            var text = c.text
            var j = i + 1
            if c.text.utf8.count == 1 {
                while j < row.count, row[j].x == row[j - 1].x + 1, row[j].text.utf8.count == 1,
                      row[j].fg == c.fg, row[j].bold == c.bold, row[j].italic == c.italic, row[j].faint == c.faint {
                    text += row[j].text; j += 1
                }
            }
            let x = CGFloat(c.x) * cw
            if text.contains(where: { $0 != " " }) { draw(text, x: x, top: top, font: fonts[fontIdx], color: color) }
            for k in i..<j where row[k].underline || row[k].strike {
                let cx = CGFloat(row[k].x) * cw, w = CGFloat(row[k].width) * cw
                ctx.setFillColor(color.cgColor)
                if row[k].underline { ctx.fill(CGRect(x: cx, y: top + baseline + 2, width: w, height: 1)) }
                if row[k].strike { ctx.fill(CGRect(x: cx, y: top + baseline - font.xHeight / 2, width: w, height: 1)) }
            }
            i = j
        }
    }

    private func draw(_ s: String, x: CGFloat, top: CGFloat, font: UIFont, color: UIColor) {
        (s as NSString).draw(at: CGPoint(x: x, y: top + baseline - font.ascender),
                             withAttributes: [.font: font, .foregroundColor: color, .kern: 0])
    }

    // MARK: focus and gestures

    override var canBecomeFirstResponder: Bool { interactive }

    /// The cell under a point of this view, in the server's grid.
    private func cell(at p: CGPoint) -> (x: Int, y: Int) {
        (max(0, Int(p.x / scale / cw)), max(0, Int(p.y / scale / ch)))
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer, pan === scrollPan || pan === panePan else { return super.gestureRecognizerShouldBegin(g) }
        let v = pan.velocity(in: self)
        let sideways = abs(v.x) > abs(v.y) * 1.5
        return pan === panePan ? sideways && onSwipePane != nil : !sideways || onSwipePane == nil
    }

    @objc private func swiped(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended else { return }
        let dx = g.translation(in: self).x
        if abs(dx) > 70 { haptic.impactOccurred(); onSwipePane?(dx < 0 ? 1 : -1) }
    }

    // MARK: selection

    private func orderedSelection() -> (a: (x: Int, y: Int), b: (x: Int, y: Int))? {
        guard let s = selection else { return nil }
        return (s.a.y, s.a.x) <= (s.b.y, s.b.x) ? (s.a, s.b) : (s.b, s.a)
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self), c = cell(at: p)
        switch g.state {
        case .began: selection = (c, c); haptic.impactOccurred(); setNeedsDisplay()
        case .changed: selection?.b = c; setNeedsDisplay()
        case .ended: editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: p))
        default: break
        }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() },
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.selection = nil; self?.setNeedsDisplay(); self?.paste(nil)
            },
        ])
    }

    private func copySelection() {
        let rows = model.frame().rows
        guard let (a, b) = orderedSelection(), a.y < rows.count else { return }
        var lines: [String] = []
        for y in a.y...min(b.y, rows.count - 1) {
            let from = y == a.y ? a.x : 0, to = y == b.y ? b.x : Int.max
            var line = ""
            for c in rows[y] where c.x >= from && c.x <= to { line += c.text.isEmpty ? " " : c.text }
            lines.append(String(line.reversed().drop(while: { $0 == " " }).reversed()))
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        selection = nil
        setNeedsDisplay()
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchBase = fontSize
        case .changed:
            let size = min(24, max(9, (pinchBase * g.scale).rounded()))
            if size != fontSize { setFont(size: size); onFontSizeChange?(size) }
        default: break
        }
    }

    /// Like orex: a pointer on the left 6 pt brings out the sidebar tab at its height, and moving into
    /// the text puts it away. `.ended` is ignored: the pointer may have moved onto the tab, which says so itself.
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let p = g.location(in: self)
        onEdgeHover?(p.x < 6 ? p.y : nil)
    }

    @objc private func edgeSwiped(_ g: UIScreenEdgePanGestureRecognizer) {
        if g.state == .ended, g.translation(in: self).x > 60 { onEdgeSwipe?() }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        if selection != nil { selection = nil; setNeedsDisplay(); return }
        becomeFirstResponder()
        onActivate?(.userTouch)
        // Only the live screen matches the server's coordinates, so links work at the bottom.
        if model.atBottom { let c = cell(at: g.location(in: self)); onCellTap?(c.x, c.y) }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        // Finger moves down → content moves down → older lines, like a wheel turned up.
        if g.state == .began, selection != nil { selection = nil; setNeedsDisplay() }
        panRemainder += g.translation(in: self).y
        g.setTranslation(.zero, in: self)
        let lines = Int(panRemainder / (ch * scale))
        if lines != 0 {
            panRemainder -= CGFloat(lines) * ch * scale
            let p = g.location(in: self)
            let bytes = model.wheel(lines: lines, at: CGPoint(x: p.x / scale, y: p.y / scale),
                                    view: CGSize(width: bounds.width / scale, height: bounds.height / scale), cell: CGSize(width: cw, height: ch))
            if !bytes.isEmpty { onInput?(bytes) }
        }
        if g.state == .ended { panRemainder = 0 }
    }

    // MARK: UIKeyInput (software keyboard, IME commits, plain hardware typing)

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        // Ctrl from the key bar applies to the next letter typed.
        if ctrlArmed, text.count == 1, let c = text.lowercased().unicodeScalars.first, ("a"..."z").contains(c) {
            ctrlArmed = false
            return sendKey(GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + numericCast(c.value - 97)),
                           mods: GhosttyMods(GHOSTTY_MODS_CTRL), text: "", unshifted: c.value)
        }
        ctrlArmed = false
        if text == "\n" { return sendKey(GHOSTTY_KEY_ENTER, mods: 0, text: "", unshifted: 0) }
        if text == "\t" { return sendKey(GHOSTTY_KEY_TAB, mods: 0, text: "", unshifted: 0) }
        send(Data(text.utf8))   // like orex's IME commit: raw UTF-8 to the program
    }

    func deleteBackward() { sendKey(GHOSTTY_KEY_BACKSPACE, mods: 0, text: "", unshifted: 0) }

    override func paste(_ sender: Any?) {
        if let s = UIPasteboard.general.string { model.scrollToBottom(); onInput?(model.encodePaste(s)) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) ? UIPasteboard.general.hasStrings : super.canPerformAction(action, withSender: sender)
    }

    // MARK: key bar

    /// The keys a terminal needs that the software keyboard doesn't have, above the keyboard.
    override var inputAccessoryView: UIView? { keyBar }

    private func makeKeyBar() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        bar.allowsSelfSizing = false
        let stack = UIStackView()
        stack.axis = .horizontal; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        bar.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor), scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])
        func key(_ title: String? = nil, symbol: String? = nil, repeats: Bool = false, _ action: @escaping () -> Void) -> UIButton {
            var c = UIButton.Configuration.gray()
            c.title = title
            c.image = symbol.map { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)) } ?? nil
            c.cornerStyle = .medium
            c.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var a = $0; a.font = .monospacedSystemFont(ofSize: 15, weight: .medium); return a
            }
            let b: UIButton
            if repeats {
                // Held down, it repeats like a hardware key.
                b = UIButton(configuration: c)
                b.addAction(UIAction { [weak self] _ in
                    self?.haptic.impactOccurred(); action()
                    self?.repeatTimer?.invalidate()
                    self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                        self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in action() }
                    }
                }, for: .touchDown)
                b.addAction(UIAction { [weak self] _ in self?.repeatTimer?.invalidate() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
            } else {
                b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.haptic.impactOccurred(); action() })
            }
            stack.addArrangedSubview(b)
            return b
        }
        // Weak: the bar belongs to this view, so a strong self here would keep both alive forever.
        let press: (GhosttyKey, Bool) -> Void = { [weak self] k, shift in
            guard let self else { return }
            var mods: GhosttyMods = shift ? GhosttyMods(GHOSTTY_MODS_SHIFT) : 0
            if self.ctrlArmed { mods |= GhosttyMods(GHOSTTY_MODS_CTRL); self.ctrlArmed = false }
            self.sendKey(k, mods: mods, text: "", unshifted: 0)
        }
        _ = key("esc") { press(GHOSTTY_KEY_ESCAPE, false) }
        let ctrl = key("ctrl") { [weak self] in self?.ctrlArmed.toggle() }
        // Armed ctrl reads as a filled key.
        ctrl.configurationUpdateHandler = { b in
            var c = b.configuration
            c?.baseBackgroundColor = b.isSelected ? b.tintColor : nil
            c?.baseForegroundColor = b.isSelected ? .white : nil
            b.configuration = c
        }
        ctrlButton = ctrl
        _ = key("tab") { press(GHOSTTY_KEY_TAB, false) }
        _ = key("⇧tab") { press(GHOSTTY_KEY_TAB, true) }
        _ = key(symbol: "arrow.left", repeats: true) { press(GHOSTTY_KEY_ARROW_LEFT, false) }
        _ = key(symbol: "arrow.down", repeats: true) { press(GHOSTTY_KEY_ARROW_DOWN, false) }
        _ = key(symbol: "arrow.up", repeats: true) { press(GHOSTTY_KEY_ARROW_UP, false) }
        _ = key(symbol: "arrow.right", repeats: true) { press(GHOSTTY_KEY_ARROW_RIGHT, false) }
        for ch in ["|", "~", "/", "-", "`"] { _ = key(ch) { [weak self] in self?.insertText(ch) } }
        _ = key(symbol: "square.and.pencil") { [weak self] in self?.onCompose?() }
        _ = key(symbol: "keyboard.chevron.compact.down") { [weak self] in self?.resignFirstResponder() }
        return bar
    }

    // MARK: hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for p in presses {
            guard let key = p.key, let mapped = encode(key) else { unhandled.insert(p); continue }
            send(mapped)
            startRepeat(key)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        repeatTimer?.invalidate()
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        repeatTimer?.invalidate()
        super.pressesCancelled(presses, with: event)
    }

    /// UIKit doesn't auto-repeat keys we consume in pressesBegan, so repeat them ourselves.
    private func startRepeat(_ key: UIKey) {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                if let self, let b = self.encode(key, action: GHOSTTY_KEY_ACTION_REPEAT) { self.send(b) }
            }
        }
    }

    /// Returns bytes for keys we handle here, or nil to let UIKit route the key to insertText/IME.
    private func encode(_ key: UIKey, action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS) -> Data? {
        let flags = key.modifierFlags
        // Cmd chords stay with the system (Cmd+V → paste); lone modifiers stay with UIKit's own tracking.
        if flags.contains(.command) || Self.isModifier(key.keyCode) { return nil }
        guard let (gkey, unshifted) = Self.hidToGhostty[key.keyCode] else { return nil }
        let chord = flags.contains(.control) || flags.contains(.alternate)
        if unshifted != 0 && !chord { return nil }   // plain typing: insertText keeps IME working
        var mods: GhosttyMods = 0
        if flags.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        // ponytail: Option acts as Meta (ESC-prefix), not as the macOS compose key.
        if flags.contains(.alternate) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
        var text = ""
        if unshifted != 0, !flags.contains(.control) {
            text = flags.contains(.shift) ? key.charactersIgnoringModifiers.uppercased() : key.charactersIgnoringModifiers
            if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value) }) { text = "" }
        }
        return model.encodeKey(action: action, key: gkey, mods: mods, text: text, unshifted: unshifted)
    }

    private func sendKey(_ key: GhosttyKey, mods: GhosttyMods, text: String, unshifted: UInt32) {
        send(model.encodeKey(action: GHOSTTY_KEY_ACTION_PRESS, key: key, mods: mods, text: text, unshifted: unshifted))
    }

    private func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        onActivate?(.keyboardInput)
        model.scrollToBottom()
        onInput?(bytes)
    }

    private static func isModifier(_ c: UIKeyboardHIDUsage) -> Bool { (0xE0...0xE7).contains(c.rawValue) }

    /// USB HID usage (page 7) → (GhosttyKey, unshifted US-layout codepoint).
    private static let hidToGhostty: [UIKeyboardHIDUsage: (GhosttyKey, UInt32)] = {
        func k(_ base: GhosttyKey, _ n: Int) -> GhosttyKey { GhosttyKey(rawValue: base.rawValue + numericCast(n)) }
        var m: [UIKeyboardHIDUsage: (GhosttyKey, UInt32)] = [:]
        func put(_ usage: Int, _ key: GhosttyKey, _ ch: Character? = nil) {
            m[UIKeyboardHIDUsage(rawValue: usage)!] = (key, ch.map { $0.unicodeScalars.first!.value } ?? 0)
        }
        for i in 0..<26 { put(0x04 + i, k(GHOSTTY_KEY_A, i), Character(UnicodeScalar(UInt8(97 + i)))) }
        for i in 1...9 { put(0x1D + i, k(GHOSTTY_KEY_DIGIT_0, i), Character("\(i)")) }
        put(0x27, GHOSTTY_KEY_DIGIT_0, "0")
        put(0x28, GHOSTTY_KEY_ENTER); put(0x29, GHOSTTY_KEY_ESCAPE); put(0x2A, GHOSTTY_KEY_BACKSPACE)
        put(0x2B, GHOSTTY_KEY_TAB); put(0x2C, GHOSTTY_KEY_SPACE, " ")
        put(0x2D, GHOSTTY_KEY_MINUS, "-"); put(0x2E, GHOSTTY_KEY_EQUAL, "="); put(0x2F, GHOSTTY_KEY_BRACKET_LEFT, "[")
        put(0x30, GHOSTTY_KEY_BRACKET_RIGHT, "]"); put(0x31, GHOSTTY_KEY_BACKSLASH, "\\"); put(0x33, GHOSTTY_KEY_SEMICOLON, ";")
        put(0x34, GHOSTTY_KEY_QUOTE, "'"); put(0x35, GHOSTTY_KEY_BACKQUOTE, "`"); put(0x36, GHOSTTY_KEY_COMMA, ",")
        put(0x37, GHOSTTY_KEY_PERIOD, "."); put(0x38, GHOSTTY_KEY_SLASH, "/")
        for i in 0..<12 { put(0x3A + i, k(GHOSTTY_KEY_F1, i)) }
        put(0x49, GHOSTTY_KEY_INSERT); put(0x4A, GHOSTTY_KEY_HOME); put(0x4B, GHOSTTY_KEY_PAGE_UP)
        put(0x4C, GHOSTTY_KEY_DELETE); put(0x4D, GHOSTTY_KEY_END); put(0x4E, GHOSTTY_KEY_PAGE_DOWN)
        put(0x4F, GHOSTTY_KEY_ARROW_RIGHT); put(0x50, GHOSTTY_KEY_ARROW_LEFT)
        put(0x51, GHOSTTY_KEY_ARROW_DOWN); put(0x52, GHOSTTY_KEY_ARROW_UP)
        put(0x64, GHOSTTY_KEY_INTL_BACKSLASH)
        return m
    }()
}
