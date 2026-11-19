import CryptoKit
import UIKit

/// What just happened that might justify taking ownership of a block.
/// Owning a block makes the server size the pty (and pick colors) for *this* client,
/// which reflows the same pane on the Mac app or orex.
enum ClaimTrigger {
    case streamStart     // the pane just opened its data stream
    case sceneActive     // irex came back to the foreground (app switch, unlock, Stage Manager focus)
    case userTouch       // the user tapped the pane
    case keyboardInput   // the user typed into the pane
    case explicit        // the user asked to fit the pane to this screen
}

/// One block's terminal stream: `data.connect` ticket → `/api/data` → snapshot → live VT.
/// Input goes over the control socket (`terminal.write`), one request at a time.
@MainActor
final class BlockStream: ObservableObject {
    let sessionId: String
    let blockId: String
    let terminal: TerminalModel
    /// Why the stream stopped by itself, if it did; `exited` when the program in the pane ended.
    @Published private(set) var ended: String?
    @Published private(set) var exited = false
    /// The pane's theme background, to fill the screen's edges beside the grid.
    @Published private(set) var background = UIColor.black
    /// Whether irex sizes this pane. Until it does, the pane keeps the owner's size and irex
    /// shows it scaled down, so watching from a phone doesn't reflow it on the Mac.
    @Published private(set) var owning = false
    /// How an attachment is going: "Uploading photo.jpg…", "Attached photo.jpg", or what went wrong.
    @Published private(set) var uploadNote: String?
    @Published private(set) var uploadFailed = false
    /// Take the pane as soon as it opens and when irex comes back, instead of watching first.
    var fitOnOpen = false

    private let control: RexControl
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var started = false

    private enum Phase { case handshake, snapshot, live }
    private var phase = Phase.handshake
    private var marker = Data()
    private var buffer = Data()

    private var unsent = Data()
    private var writing = false
    private var wantedSize: (cols: Int, rows: Int)?
    private var resizeTask: Task<Void, Never>?
    private var sizedAt = Date.distantPast   // when irex last took the pane or asked for a size

    init(control: RexControl, sessionId: String, blockId: String, terminal: TerminalModel) {
        self.control = control; self.sessionId = sessionId; self.blockId = blockId; self.terminal = terminal
        background = terminal.background
    }

    func start() async {
        // A stream handed over from a preview is going already.
        guard !started else { return }
        started = true
        do {
            let r = try await control.call("data.connect", ["session_id": sessionId, "block_id": blockId,
                                                           "data_ref_id": "terminal", "subprotocol": "rex.data.terminal.v1"])
            guard let ticket = (r["ticket"] as? String).flatMap(Self.base64url), ticket.count == 16 else {
                throw RexError(description: "bad data ticket")
            }
            let ep = control.endpoint
            let t = session.webSocketTask(with: ep.socketURL("/api/data"), protocols: ep.protocols("rex.data.terminal.v1"))
            task = t
            t.resume()
            try await t.send(.data(Data([0x01]) + ticket))
            receiveLoop(t)
            await claim(.streamStart)
        } catch {
            end(describe(error))
        }
    }

    func stop() {
        resizeTask?.cancel()
        let (s, b) = (sessionId, blockId)
        if owning { Task { [control] in _ = try? await control.call("session.disown_block", ["session_id": s, "block_ids": [b]]) } }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    // MARK: ownership

    /// Decides whether `trigger` should take this block away from whichever client owns it now.
    func shouldClaim(_ trigger: ClaimTrigger) -> Bool {
        // With fitOnOpen, the device you're holding sizes the pane, as in orex. Without it, irex
        // watches first: typing into the pane, or asking, takes it.
        switch trigger {
        case .keyboardInput, .explicit: return !owning
        case .streamStart: return fitOnOpen
        case .sceneActive: return owning || fitOnOpen
        case .userTouch: return false
        }
    }

    func claim(_ trigger: ClaimTrigger) async {
        guard shouldClaim(trigger) else { return }
        owning = true
        sizedAt = .now
        _ = try? await control.call("session.own_block", ["session_id": sessionId, "block_ids": [blockId], "mode": "take"])
        // Another client may have changed the size while it owned the block.
        if wantedSize != nil { sendSize() }
    }

    // MARK: size and input

    /// The pane's grid changed. Debounced 120 ms like orex; the emulator itself only
    /// resizes when the server answers with an in-band `resize`.
    func requestSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        wantedSize = (cols, rows)
        resizeTask?.cancel()
        guard owning else { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled { self?.sendSize() }
        }
    }

    private func sendSize() {
        guard let s = wantedSize else { return }
        sizedAt = .now
        Task { _ = try? await control.call("com.superlogical.terminal.resize",
                                           ["session_id": sessionId, "block_id": blockId, "args": ["columns": s.cols, "rows": s.rows]]) }
    }

    /// Block methods run concurrently on the server, so a second in-flight write could overtake
    /// the first. Batch keystrokes and keep exactly one write in flight.
    func send(_ bytes: Data) {
        unsent.append(bytes)
        flush()
    }

    /// Text as a paste (bracketed when the program asks), then Enter if `enter`.
    func sendText(_ text: String, enter: Bool) {
        send(terminal.encodePaste(text))
        if enter { send(terminal.enterKey) }
    }

    /// The note over the terminal, for files coming the other way too.
    func noteFile(_ note: String?, failed: Bool) { uploadNote = note; uploadFailed = failed }

    /// A file to hand to the pane's program: Rex puts it on the pane's machine and types its path.
    struct Attachment { let name: String; let data: Data }

    func attach(_ files: [Attachment]) async {
        guard !files.isEmpty else { return }
        let what = files.count == 1 ? files[0].name : "\(files.count) files"
        uploadNote = "Uploading \(what)…"
        uploadFailed = false
        let batch = UUID().uuidString.lowercased()
        var problem: String?
        for (i, f) in files.enumerated() {
            do { try await upload(f, batch: batch, index: i, count: files.count) } catch {
                problem = "\(f.name) couldn't be attached: \(describe(error))"
            }
        }
        uploadFailed = problem != nil
        let note = problem ?? "Attached \(what)"
        uploadNote = note
        try? await Task.sleep(for: .seconds(problem == nil ? 2.5 : 5))
        if uploadNote == note { uploadNote = nil }
    }

    /// The same handshake as the terminal stream, on `rex.data.bytes.v1`: then the file, then an
    /// empty message to say it's all there, and the server closes with 1000 once it has typed the path.
    private func upload(_ f: Attachment, batch: String, index: Int, count: Int) async throws {
        let args: [String: Any] = ["ref": "upload:" + UUID().uuidString.lowercased(), "name": f.name, "size": f.data.count,
                                   "batch": batch, "index": index, "count": count]
        let r = try await control.call("com.superlogical.terminal.upload_begin", ["session_id": sessionId, "block_id": blockId, "args": args])
        guard let ticket = (r["ticket"] as? String).flatMap(Self.base64url), ticket.count == 16 else {
            throw RexError(description: "no upload ticket")
        }
        let ep = control.endpoint
        let t = session.webSocketTask(with: ep.socketURL("/api/data"), protocols: ep.protocols("rex.data.bytes.v1"))
        t.resume()
        defer { t.cancel(with: .normalClosure, reason: nil) }
        try await t.send(.data(Data([0x01]) + ticket))
        guard case .data(let welcome) = try await t.receive(), welcome.first == 0x81 else {
            throw RexError(description: "the server refused it")
        }
        var offset = 0
        while offset < f.data.count {
            let end = min(offset + 64 * 1024, f.data.count)
            try await t.send(.data(f.data.subdata(in: offset..<end)))
            offset = end
        }
        try await t.send(.data(Data()))
        // Read until the server closes; how it closes says whether the file arrived.
        while (try? await t.receive()) != nil {}
        guard t.closeCode == .normalClosure else { throw RexError(description: "it didn't finish (\(t.closeCode.rawValue))") }
    }

    /// A file from the pane's machine, kept in Caches; `path` may be relative to where the pane's
    /// program runs, as agents print them. An unchanged file isn't fetched again.
    func download(_ path: String) async throws -> URL {
        let key = "\(blockId)|\(path)"
        // One folder per pane and path, so two files with the same name don't overwrite each other.
        let folder = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = URL.cachesDirectory.appending(path: "downloads/\(folder)")
        let file = dir.appending(path: (path as NSString).lastPathComponent)
        var args: [String: Any] = ["ref": "download:" + UUID().uuidString.lowercased(), "path": path]
        let known = UserDefaults.standard.dictionary(forKey: "downloadVersions") as? [String: String] ?? [:]
        if let v = known[key], FileManager.default.fileExists(atPath: file.path) { args["if_none_match"] = v }
        let r = try await control.call("com.superlogical.terminal.download_begin", ["session_id": sessionId, "block_id": blockId, "args": args])
        if r["not_modified"] as? Bool == true { return file }
        let version = r["version"] as? String
        guard let ticket = (r["ticket"] as? String).flatMap(Self.base64url), ticket.count == 16 else {
            throw RexError(description: "no download ticket")
        }
        let ep = control.endpoint
        let t = session.webSocketTask(with: ep.socketURL("/api/data"), protocols: ep.protocols("rex.data.bytes.v1"))
        t.maximumMessageSize = 1 << 20
        t.resume()
        defer { t.cancel(with: .normalClosure, reason: nil) }
        try await t.send(.data(Data([0x01]) + ticket))
        guard case .data(let welcome) = try await t.receive(), welcome.first == 0x81 else {
            throw RexError(description: "the server refused it")
        }
        // ponytail: the whole file in memory; agents' screenshots and notes are small. Stream to disk if that changes.
        var bytes = Data()
        while true {
            guard let m = try? await t.receive() else {
                guard t.closeCode == .normalClosure else { throw RexError(description: "it stopped partway (\(t.closeCode.rawValue))") }
                break
            }
            guard case .data(let d) = m else { continue }
            if d.isEmpty { break }   // the end, if the server marks it as uploads are marked
            bytes.append(d)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
        var versions = known
        versions[key] = version   // nil when the server can't vouch for it: not cached
        UserDefaults.standard.set(versions, forKey: "downloadVersions")
        return file
    }

    /// A left click at a cell of the server's screen. A link (OSC 8) there comes back as a
    /// `url_clicked` block event.
    func click(column: Int, row: Int) {
        for action in ["press", "release"] {
            Task { _ = try? await control.call("block.event", ["session_id": sessionId, "block_id": blockId,
                "event": ["type": "mouse", "payload": ["action": action, "button": "left", "mods": "", "x": column, "y": row]]]) }
        }
    }

    private func flush() {
        guard !writing, !unsent.isEmpty else { return }
        writing = true
        let text = String(decoding: unsent, as: UTF8.self)
        unsent.removeAll()
        Task {
            _ = try? await control.call("com.superlogical.terminal.write",
                                        ["session_id": sessionId, "block_id": blockId, "args": ["data": text]])
            writing = false
            flush()
        }
    }

    // MARK: data stream

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, t === self.task else { return }
                switch result {
                case .failure(let e):
                    let reason = t.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    self.end("\(t.closeCode.rawValue) \(reason.isEmpty ? e.localizedDescription : reason)")
                case .success(.data(let d)):
                    self.onBinary(d); self.receiveLoop(t)
                case .success:
                    self.receiveLoop(t)
                }
            }
        }
    }

    private func onBinary(_ bytes: Data) {
        if phase == .handshake {
            let b = [UInt8](bytes)
            guard b.count == 32, b[0] == 0x81 else {
                return end(String(format: "data handshake rejected, reason 0x%02x", b.count > 1 ? b[1] : 0))
            }
            let nonce = b[24..<32].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            marker = Data([0x1B, 0x5F]) + Data("rex1;\(nonce);".utf8)
            phase = .snapshot
            return
        }
        buffer.append(bytes)
        if phase == .snapshot {
            guard let r = buffer.range(of: marker) else { return }
            guard terminal.restoreSnapshot(buffer[buffer.startIndex..<r.lowerBound]) else {
                return end("could not read the terminal snapshot")
            }
            buffer = Data(buffer[r.lowerBound...])
            phase = .live
        }
        handleLive()
    }

    private func handleLive() {
        while true {
            guard let s = buffer.range(of: marker) else {
                // Keep a trailing partial marker for the next message.
                var keep = min(marker.count - 1, buffer.count)
                while keep > 0 && !marker.starts(with: buffer.suffix(keep)) { keep -= 1 }
                terminal.feed(buffer.dropLast(keep))
                buffer = Data(buffer.suffix(keep))
                return
            }
            if s.lowerBound > buffer.startIndex { terminal.feed(buffer[buffer.startIndex..<s.lowerBound]) }
            guard let e = buffer.range(of: Data([0x1B, 0x5C]), in: s.upperBound..<buffer.endIndex) else {
                buffer = Data(buffer[s.lowerBound...])
                return
            }
            if let msg = (try? JSONSerialization.jsonObject(with: buffer[s.upperBound..<e.lowerBound])) as? [String: Any] {
                handleRexMessage(msg)
            }
            buffer = Data(buffer[e.upperBound...])
        }
    }

    private func handleRexMessage(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "resize":
            if let c = m["cols"] as? Int, let r = m["rows"] as? Int {
                terminal.resizeGrid(cols: c, rows: r)
                // A size irex didn't ask for means another client took the pane.
                // Sizes from just before irex's own request can still be on the way, so wait them out.
                if owning, let w = wantedSize, (w.cols, w.rows) != (c, r), Date.now.timeIntervalSince(sizedAt) > 1.5 { owning = false }
            }
        case "theme":
            terminal.setTheme(m)
            background = terminal.background
        case "child_exited":
            exited = true
            end(m["exit_code"].map { "exit code \($0)" } ?? "")
        default: break
        }
    }

    private func end(_ reason: String) {
        task = nil
        ended = reason
    }

    static func base64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}
