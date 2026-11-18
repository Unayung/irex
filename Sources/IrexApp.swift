import SwiftUI

@main
struct IrexApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct Pane: Identifiable {
        let id: String
        let sessionId: String
        let sessionLabel: String
        let title: String
        let status: String
        let detail: String   // what the agent says it's doing
        let since: Date?     // when its status last changed
    }
    struct Tab: Identifiable { let id: String; let label: String; let panes: [Pane] }
    struct Session: Identifiable { let id: String; let label: String; let host: String?; let tabs: [Tab] }
    struct HostState: Identifiable { let id: String; let label: String; let state: String }

    /// Hosts in order: the server you connect to ("local"), then the ones its `rex hosts` lists.
    @Published private var hostOrder: [String] = []
    @Published private var hostLabels: [String: String] = [:]
    @Published private var hostSessions: [String: [(id: String, label: String)]] = [:]
    @Published private var hostProblems: [String: String] = [:]
    @Published private var views: [String: [String: Any]] = [:]     // session.view by session ID
    @Published private var titles: [String: String] = [:]           // block ID → title the program set
    @Published private var statuses: [String: String] = [:]         // block ID → working / blocked / done
    @Published private var details: [String: String] = [:]          // block ID → the status's message
    @Published private var since: [String: Date] = [:]              // block ID → when the status changed
    @Published var status = ""
    @Published var connected = false
    @Published var connecting = false
    @Published var stream: BlockStream?
    @Published var openPaneId: String?
    private var controls: [String: RexControl] = [:]
    private var sessionHost: [String: String] = [:]
    private var clickedAt: [String: Date] = [:]    // block ID → when irex last clicked in it
    /// A pane a notification or the Live Activity asked for, opened as soon as its session's
    /// view arrives: on a cold start that's after connecting, listing, and fetching views.
    private var wanted: (block: String, at: Date)?

    /// Sessions, their tabs, and each tab's panes, host by host in the server's order.
    var sessions: [Session] {
        hostOrder.flatMap { host in
            (hostSessions[host] ?? []).map { s in
                let windows = views[s.id]?["windows"] as? [[String: Any]] ?? []
                return Session(id: s.id, label: s.label, host: host == "local" ? nil : hostLabels[host], tabs: windows.map { w in
                    let blocks = (w["layers"] as? [[String: Any]] ?? []).flatMap { $0["blocks"] as? [[String: Any]] ?? [] }
                    return Tab(id: w["window_id"] as? String ?? "", label: w["label"] as? String ?? "", panes: blocks.compactMap { b in
                        guard let id = b["block_id"] as? String else { return nil }
                        let title = titles[id].flatMap { $0.isEmpty ? nil : $0 } ?? b["label"] as? String ?? "Pane"
                        return Pane(id: id, sessionId: s.id, sessionLabel: s.label, title: title, status: statuses[id] ?? "",
                                    detail: details[id] ?? "", since: since[id])
                    })
                })
            }
        }
    }

    var hosts: [HostState] {
        hostOrder.map { key in
            let state = hostProblems[key] ?? (controls[key] != nil && hostSessions[key] != nil ? "Connected" : "Connecting…")
            return HostState(id: key, label: key == "local" ? "This server" : hostLabels[key] ?? key, state: state)
        }
    }

    /// "1 needs you · 3 working", or how many panes there are when nothing's going on.
    var summary: String {
        let muted = Push.shared.muted
        let panes = sessions.filter { !muted.contains($0.id) }.flatMap(\.tabs).flatMap(\.panes).filter { !muted.contains($0.id) }
        let blocked = panes.filter { $0.status == "blocked" }.count, working = panes.filter { $0.status == "working" }.count
        let parts = (blocked > 0 ? ["\(blocked) need\(blocked == 1 ? "s" : "") you"] : []) + (working > 0 ? ["\(working) working"] : [])
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return panes.isEmpty ? "" : "\(panes.count) pane\(panes.count == 1 ? "" : "s")"
    }

    func pane(_ id: String) -> Pane? {
        sessions.lazy.flatMap(\.tabs).flatMap(\.panes).first { $0.id == id }
    }

    private func control(for sessionId: String) -> RexControl? { sessionHost[sessionId].flatMap { controls[$0] } }

    // MARK: connecting

    func connect(_ address: String) async {
        disconnect()
        guard let ep = RexEndpoint(address) else { status = "That isn't a server address."; return }
        status = ""
        connecting = true
        hostOrder = ["local"]
        let ok = await connectHost("local", endpoint: ep)
        connecting = false
        guard ok else { return }
        connected = true
        await refreshHosts()
        #if DEBUG
        // `-openPane <title>` at launch opens the first pane whose title has it, for simulator checks.
        if let want = UserDefaults.standard.string(forKey: "openPane") {
            try? await Task.sleep(for: .seconds(2))
            if let p = sessions.flatMap(\.tabs).flatMap(\.panes).first(where: { $0.title.contains(want) }) { await open(p) }
        }
        #endif
    }

    /// Connects one host and lists its sessions. The first host's failure is the app's; others just mark their row.
    @discardableResult
    private func connectHost(_ key: String, endpoint: RexEndpoint) async -> Bool {
        let c = RexControl(endpoint: endpoint)
        c.onClose = { [weak self] reason in self?.hostClosed(key, reason) }
        c.onEvent = { [weak self] type, payload in self?.handle(key, type, payload) }
        controls[key] = c
        hostProblems[key] = nil
        do {
            try await c.connect()
            // "all" brings every session's block events too: titles and statuses for the list.
            let r = try await c.call("session.attach_all", ["event_scope": "all"])
            guard controls[key] === c else { return false }
            setSessions(key, r)
            return true
        } catch {
            // A newer connect() cancels this one (-999); don't let it overwrite that attempt's state.
            guard controls[key] === c else { return false }
            controls[key] = nil
            if key == "local" { status = "\(error)" } else { hostProblems[key] = "\(error)" }
            return false
        }
    }

    private func hostClosed(_ key: String, _ reason: String) {
        controls[key] = nil
        if let open = stream?.sessionId, sessionHost[open] == key { closePane() }
        if key == "local" {
            // Without the first server there's no host list either; start over on the next connect.
            status = "Disconnected: \(reason)"
            disconnect()
        } else {
            hostSessions[key] = nil
            hostProblems[key] = "Disconnected"
        }
    }

    /// The other hosts the server knows (`rex hosts`), each on a connection of its own.
    func refreshHosts() async {
        guard let c = controls["local"], let r = try? await c.call("hosts.list") else { return }
        var listed: [String] = []
        for h in r["hosts"] as? [[String: Any]] ?? [] {
            guard let key = h["id"] as? String, let address = (h["endpoints"] as? [String])?.first,
                  let ep = RexEndpoint(address) else { continue }
            listed.append(key)
            hostLabels[key] = h["label"] as? String ?? key
            if controls[key] == nil { Task { await connectHost(key, endpoint: ep) } }
        }
        for key in hostOrder where key != "local" && !listed.contains(key) {
            controls[key]?.onClose = nil; controls[key]?.close(); controls[key] = nil; hostSessions[key] = nil
        }
        hostOrder = ["local"] + listed
    }

    func disconnect() {
        closePane()
        // Reconnecting on the way to a pane keeps you on its screen.
        if let w = wanted { openPaneId = w.block }
        for c in controls.values { c.onClose = nil; c.close() }
        controls = [:]
        connected = false
        hostOrder = []; hostSessions = [:]; hostProblems = [:]; views = [:]; sessionHost = [:]
    }

    var isIdle: Bool { controls["local"] == nil }

    func refresh() async {
        for key in hostOrder {
            if let c = controls[key], let r = try? await c.call("session.list") { setSessions(key, r) }
        }
        await refreshHosts()
    }

    // MARK: events

    private func handle(_ host: String, _ type: String, _ payload: [String: Any]) {
        switch type {
        case "session_created", "session_destroyed", "session_moved":
            Task { if let c = controls[host], let r = try? await c.call("session.list") { setSessions(host, r) } }
        case "session_event":
            let sessionId = payload["session_id"] as? String ?? ""
            let inner = payload["event"] as? [String: Any] ?? [:]
            switch inner["type"] as? String {
            case "session_label_changed":
                Task { if let c = controls[host], let r = try? await c.call("session.list") { setSessions(host, r) } }
            case "session_view_changed": Task { await fetchView(sessionId) }
            case "block_event":
                let block = inner["payload"] as? [String: Any] ?? [:]
                guard let blockId = block["block_id"] as? String else { return }
                let p = block["payload"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "title_changed": titles[blockId] = p["title"] as? String ?? ""
                case "program_status_changed": record(blockId, p["record"] as? [String: Any])
                case "program_status_removed": record(blockId, nil)
                case "url_clicked":
                    // Every client attached to the pane hears of a click; open only links irex just clicked.
                    guard let at = clickedAt.removeValue(forKey: blockId), Date.now.timeIntervalSince(at) < 3,
                          let url = URL(string: p["url"] as? String ?? ""), ["http", "https", "mailto"].contains(url.scheme) else { return }
                    UIApplication.shared.open(url)
                default: break
                }
            default: break
            }
        default: break
        }
    }

    /// A program status record (OSC 7501): its state, message, and when it was reported.
    private func record(_ block: String, _ r: [String: Any]?) {
        statuses[block] = r?["state"] as? String
        // Without a message, say what kind of wait it is, such as asking for permission.
        let kind = (r?["kind"] as? String).map { "Asking for \($0)" }
        details[block] = (r?["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (r?["state"] as? String == "blocked" ? kind : nil)
        since[block] = (r?["updated_at"] as? String).flatMap(Self.parseDate) ?? (r == nil ? nil : .now)
    }

    /// RFC 3339 with up to nanoseconds, which ISO8601DateFormatter can't read: drop the fraction.
    static func parseDate(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private func setSessions(_ host: String, _ r: [String: Any]) {
        let list: [(id: String, label: String)] = (r["sessions"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["session_id"] as? String else { return nil }
            return (id, $0["label"] as? String ?? id)
        }
        let gone = Set((hostSessions[host] ?? []).map(\.id)).subtracting(list.map(\.id))
        hostSessions[host] = list
        for id in gone { views[id] = nil; sessionHost[id] = nil }
        if let open = stream?.sessionId, gone.contains(open) { closePane() }
        for s in list { sessionHost[s.id] = host; Task { await fetchView(s.id) } }
    }

    private func fetchView(_ sessionId: String) async {
        guard let c = control(for: sessionId), let view = try? await c.call("session.view", ["session_id": sessionId]),
              control(for: sessionId) === c else { return }
        // Views can arrive out of order; keep the newest.
        if let old = views[sessionId]?["revision"] as? Int, let new = view["revision"] as? Int, new < old { return }
        views[sessionId] = view
        openWanted()
        for w in view["windows"] as? [[String: Any]] ?? [] {
            for l in w["layers"] as? [[String: Any]] ?? [] {
                for b in l["blocks"] as? [[String: Any]] ?? [] {
                    guard let id = b["block_id"] as? String, titles[id] == nil else { continue }
                    titles[id] = ""   // asked; block events keep it current from here
                    let target: [String: Any] = ["session_id": sessionId, "block_id": id, "args": [String: Any]()]
                    Task {
                        if let t = try? await c.call("com.superlogical.terminal.title", target)["title"] as? String, !t.isEmpty { titles[id] = t }
                        // A status set before irex connected only comes from here.
                        if let r = try? await c.call("com.superlogical.terminal.program_status", target),
                           let first = (r["records"] as? [[String: Any]])?.first { record(id, first) }
                    }
                }
            }
        }
    }

    // MARK: panes

    func open(_ p: Pane) async {
        guard let c = control(for: p.sessionId), stream?.blockId != p.id else { return }
        stream?.stop(); stream = nil
        openPaneId = p.id   // right away, so the iPhone pushes the terminal without waiting for the server
        do {
            try await c.call("session.attach", ["session_id": p.sessionId])
            guard openPaneId == p.id else { return }
            let bs = BlockStream(control: c, sessionId: p.sessionId, blockId: p.id, terminal: TerminalModel())
            bs.fitOnOpen = UserDefaults.standard.object(forKey: "fitOnOpen") as? Bool ?? true
            bs.onEnded = { [weak self] reason in self?.status = "Stream ended: \(reason)" }
            stream = bs
            status = ""
        } catch {
            status = "\(error)"
        }
    }

    /// The pane before (-1) or after (+1) the open one, through the session's tabs in order.
    func neighbor(_ delta: Int) -> (pane: Pane, position: Int, count: Int)? {
        guard let s = stream, let session = sessions.first(where: { $0.id == s.sessionId }) else { return nil }
        let panes = session.tabs.flatMap(\.panes)
        guard let i = panes.firstIndex(where: { $0.id == s.blockId }), panes.indices.contains(i + delta) else { return nil }
        return (panes[i + delta], i + delta + 1, panes.count)
    }

    func openNeighbor(_ delta: Int) {
        guard let n = neighbor(delta) else { return }
        Task { await open(n.pane) }
    }


    func clicked(_ blockId: String) { clickedAt[blockId] = .now }

    /// Goes to the pane's screen right away, the terminal showing once the pane is known.
    func openWhenListed(_ block: String) {
        wanted = (block, .now)
        if stream?.blockId != block { stream?.stop(); stream = nil }
        openPaneId = block   // the iPhone pushes the pane's screen now, not after connecting
        openWanted()
        Task {
            try? await Task.sleep(for: .seconds(30))
            guard wanted?.block == block else { return }
            wanted = nil
            if stream == nil && openPaneId == block { openPaneId = nil; status = "That pane is no longer there." }
        }
    }

    /// The pane irex is waiting to open, if any.
    var opening: Bool { wanted != nil && stream == nil }

    private func openWanted() {
        guard let w = wanted else { return }
        // A pane that never shows up (closed meanwhile) shouldn't open by surprise later.
        guard Date.now.timeIntervalSince(w.at) < 30 else { return }
        guard let p = pane(w.block) else { return }
        wanted = nil
        Task { await open(p) }
    }

    /// A stream that only watches a pane, for previews; the caller stops it.
    func watch(_ p: Pane) -> BlockStream? {
        guard let c = control(for: p.sessionId) else { return nil }
        let bs = BlockStream(control: c, sessionId: p.sessionId, blockId: p.id, terminal: TerminalModel())
        Task { _ = try? await c.call("session.attach", ["session_id": p.sessionId]); await bs.start() }
        return bs
    }

    /// A new session with one shell in it, on the server you connected to, opened right away.
    func newSession() async {
        guard let c = controls["local"] else { return }
        do {
            let r = try await c.call("session.create", ["initial_windows": [["layout": ["block": ["flavor": "com.superlogical.terminal.shell"]]]]])
            guard let id = r["session_id"] as? String else { return }
            if let l = try? await c.call("session.list") { setSessions("local", l) }
            await fetchView(id)
            if let p = sessions.first(where: { $0.id == id })?.tabs.first?.panes.first { await open(p) }
        } catch {
            status = "\(error)"
        }
    }

    /// Stops streaming, which gives the pane's size back to the other clients.
    func closePane() {
        stream?.stop(); stream = nil
        openPaneId = nil
    }
}

struct ContentView: View {
    @StateObject private var app = AppModel()
    @ObservedObject private var push = Push.shared
    @AppStorage("server") private var server = ""
    @AppStorage("fontSize") private var fontSize = 14.0
    @AppStorage("keepAwake") private var keepAwake = true
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.sidebar   // iPhone: the list, or the pane
    @State private var settingsShown = false
    @State private var replyTo: AppModel.Pane?
    @State private var composing = false
    @State private var swipeDX: CGFloat = 0        // how far the terminal follows a sideways swipe
    @State private var swipeArmed = false          // past the point where letting go switches panes

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // Who's waiting on you comes first, wherever their sessions are.
                    let waiting = app.sessions.filter { !push.muted.contains($0.id) }.flatMap(\.tabs).flatMap(\.panes)
                        .filter { $0.status == "blocked" && !push.muted.contains($0.id) }
                    if !waiting.isEmpty {
                        Text("Needs you").font(.footnote.weight(.semibold)).foregroundStyle(.red).textCase(.uppercase)
                            .padding(.leading, 4)
                        ForEach(waiting) { p in
                            NeedsYouCard(pane: p, onReply: { replyTo = p }, onOpen: { Task { await app.open(p) } })
                        }
                        Text("Sessions").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            .padding(.leading, 4).padding(.top, 6)
                    }
                    ForEach(app.sessions) { s in
                        SessionCard(session: s, mutedIDs: push.muted, openPaneId: app.openPaneId,
                                    onOpen: { p in Task { await app.open(p) } },
                                    onMute: { id, on in push.setMuted(id, on) })
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .animation(.default, value: app.sessions.flatMap(\.tabs).flatMap(\.panes).map(\.status))
            }
            .background(Color(.systemGroupedBackground))
            .overlay {
                if app.connecting && app.sessions.isEmpty {
                    ProgressView("Connecting…")
                } else if app.sessions.isEmpty {
                    ContentUnavailableView {
                        Label(app.connected ? "No sessions" : "Not connected", systemImage: app.connected ? "terminal" : "network.slash")
                    } description: {
                        Text(app.connected ? "Start one with rex new on the server." : app.status)
                    } actions: {
                        if !app.connected { Button("Settings") { settingsShown = true } }
                    }
                }
            }
            .refreshable { await app.refresh() }
            .navigationTitle("irex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .heavy)).foregroundStyle(.tint)
                            Text("irex").font(.system(.headline, design: .monospaced))
                        }
                        if !app.summary.isEmpty {
                            Text(app.summary).font(.caption2).foregroundStyle(.secondary).contentTransition(.numericText())
                        }
                    }
                    .animation(.default, value: app.summary)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { settingsShown = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await app.newSession() } } label: { Image(systemName: "plus") }
                        .disabled(!app.connected)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let s = app.stream {
                    PaneHeader(stream: s, pane: app.pane(s.blockId), compact: sizeClass == .compact,
                               onBack: { if sizeClass == .compact { app.closePane() } else { columns = columns == .detailOnly ? .all : .detailOnly } },
                               onCompose: { composing = true })
                    TerminalRepresentable(stream: s, fontSize: fontSize, focusOnOpen: sizeClass != .compact,
                                          onEdgeSwipe: { if sizeClass == .compact { app.closePane() } else { columns = .all } },
                                          onEdgeHover: { _ in },
                                          onCompose: { composing = true },
                                          onPaneSwipe: { paneSwipe($0) },
                                          onFontSizeChange: { fontSize = $0 },
                                          onCellTap: { col, row in app.clicked(s.blockId); s.click(column: col, row: row) })
                        .id(s.blockId)
                        .offset(x: swipeDX)
                        .background(Color(.systemGroupedBackground))
                        .overlay(alignment: swipeDX < 0 ? .trailing : .leading) {
                            if swipeDX != 0 {
                                SwipePreview(target: app.neighbor(swipeDX < 0 ? 1 : -1), forward: swipeDX < 0,
                                             armed: swipeArmed, progress: min(1, abs(swipeDX) / Self.swipeThreshold))
                                    .padding(.horizontal, 12)
                                    // Comes in from the edge with the finger, settled by the threshold.
                                    .offset(x: (swipeDX < 0 ? 1 : -1) * max(0, 174 - abs(swipeDX) * 1.9))
                            }
                        }
                        .clipped()
                } else if app.opening {
                    Spacer(); ProgressView("Opening…"); Spacer()
                } else {
                    ContentUnavailableView(app.sessions.isEmpty ? "Not connected" : "Pick a pane",
                                           systemImage: app.sessions.isEmpty ? "network.slash" : "terminal",
                                           description: Text(app.sessions.isEmpty ? "Connect to a Rex server in Settings." : "Choose one from the list."))
                }
                if !app.status.isEmpty {
                    Text(app.status).font(.footnote).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $replyTo) { p in
            QuickReplyView(app: app, pane: p, onOpen: { replyTo = nil; Task { await app.open(p) } })
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $composing) {
            if let s = app.stream { ComposeView(stream: s).presentationDetents([.medium, .large]) }
        }
        .sheet(isPresented: $settingsShown) { SettingsView(app: app, server: $server, fontSize: $fontSize, keepAwake: $keepAwake) }
        // Watching an agent work shouldn't lock the phone.
        .onChange(of: keepAwake && app.stream != nil, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        // First launch: nothing to connect to yet, so ask for the server.
        .task {
            #if DEBUG
            // `-openBlock <ID>` at launch takes the path a tapped notification takes, before connecting.
            if let id = UserDefaults.standard.string(forKey: "openBlock") { push.pendingBlock = id }
            #endif
            if server.isEmpty { settingsShown = true; return }
            #if DEBUG
            let review = UserDefaults.standard.bool(forKey: "noPush")   // simulator review: no permission prompt
            #else
            let review = false
            #endif
            if !review { push.start(server: server) }
            await app.connect(server)
            #if DEBUG
            // Screens for simulator review: `-showSettings YES`, `-showReply <pane title>`.
            if UserDefaults.standard.bool(forKey: "showSettings") { settingsShown = true }
            // `-swipeDX <points>` (or `-swipeLeft <points>`) holds a sideways swipe that far, to look at its preview.
            let hold = UserDefaults.standard.double(forKey: "swipeDX") - UserDefaults.standard.double(forKey: "swipeLeft")
            if hold != 0 {
                try? await Task.sleep(for: .seconds(5))
                paneSwipe(.moved(hold))
            }
            if let want = UserDefaults.standard.string(forKey: "showReply") {
                try? await Task.sleep(for: .seconds(3))
                replyTo = app.sessions.flatMap(\.tabs).flatMap(\.panes).first { $0.title.contains(want) }
            }
            #endif
        }
        .onChange(of: server) { _, s in if !s.isEmpty { push.start(server: s) } }
        // A notification or the Live Activity asked for a pane: open it once the list has it.
        .onOpenURL { push.open($0) }
        .onChange(of: push.pendingBlock, initial: true) { _, id in
            guard let id else { return }
            push.pendingBlock = nil
            // Close whatever sheet is up, so the pane itself is what you see.
            replyTo = nil; composing = false; settingsShown = false
            // Straight to the pane: no slide in from the list.
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { app.openWhenListed(id) }
        }
        // A pane a swipe opened comes in from the side the swipe pointed to.
        .onChange(of: app.stream?.blockId) { _, _ in
            guard swipeDX != 0 else { return }
            swipeDX = -swipeDX * 0.35
            withAnimation(.spring(duration: 0.32)) { swipeDX = 0 }
        }
        .onChange(of: app.openPaneId) { _, id in
            push.showing = id
            compactColumn = id == nil ? .sidebar : .detail
        }
        .onChange(of: phase) { _, p in
            guard p == .active else { return }
            // iOS drops sockets in the background; come back connected.
            if app.isIdle {
                if !server.isEmpty { Task { await app.connect(server) } }
            } else {
                Task { await app.refreshHosts() }
                if let s = app.stream { Task { await s.claim(.sceneActive) } }
            }
            push.loadMutes()
        }
    }
}


struct SettingsView: View {
    @ObservedObject var app: AppModel
    @Binding var server: String
    @Binding var fontSize: Double
    @Binding var keepAwake: Bool
    @AppStorage("fitOnOpen") private var fitOnOpen = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("host:port", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onSubmit { Task { await app.connect(server) } }
                    LabeledContent("Status", value: app.connecting ? "Connecting…" : app.connected ? "Connected" : app.status.isEmpty ? "Not connected" : app.status)
                    Button(app.connected ? "Reconnect" : "Connect") { Task { await app.connect(server) } }
                    if app.connected { Button("Disconnect", role: .destructive) { app.disconnect() } }
                } header: {
                    Text("Server")
                } footer: {
                    Text("A Rex server, such as host.tailnet.ts.net:7297. Put account@ in front to connect as another account.")
                }
                Section {
                    LabeledContent("Status", value: Push.shared.state)
                    Button("Send a test notification") { Push.shared.test() }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("They come from irex-push on the server's machine: when an agent needs you or finishes, and a Live Activity with every agent on the lock screen and in the Dynamic Island.")
                }
                if app.hosts.count > 1 {
                    Section {
                        ForEach(app.hosts) { h in LabeledContent(h.label, value: h.state) }
                    } header: {
                        Text("Hosts")
                    } footer: {
                        Text("The other hosts come from the server's `rex hosts` list.")
                    }
                }
                Section {
                    Stepper("Text size \(Int(fontSize))", value: $fontSize, in: 9...24)
                    Toggle("Fit panes to this screen", isOn: $fitOnOpen)
                    Toggle("Keep screen on", isOn: $keepAwake)
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Fitting resizes a pane you open to this screen, and other clients see it at that size. Off, irex shows the pane at its own size until you type or tap Fit. Either way, the screen stays on while a pane is open if you keep it on.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension ContentView {
    static let swipeThreshold: CGFloat = 90

    /// Follows a sideways swipe: the terminal moves with the finger, a card shows where letting go
    /// leads, and past the threshold it lights up, with a tap, before anything switches.
    func paneSwipe(_ e: TerminalView.PaneSwipe) {
        switch e {
        case .moved(let dx):
            let target = app.neighbor(dx < 0 ? 1 : -1)
            swipeDX = target == nil ? dx * 0.25 : dx      // resists at the first and last pane
            let armed = target != nil && abs(dx) > Self.swipeThreshold
            if armed != swipeArmed {
                swipeArmed = armed
                UISelectionFeedbackGenerator().selectionChanged()
            }
        case .ended(let dx, let velocity):
            let delta = dx < 0 ? 1 : -1
            let flick = abs(velocity) > 900 && abs(dx) > 30 && (velocity < 0) == (dx < 0)
            swipeArmed = false
            if app.neighbor(delta) != nil && (abs(dx) > Self.swipeThreshold || flick) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                let width = UIScreen.main.bounds.width
                withAnimation(.easeIn(duration: 0.15)) { swipeDX = dx < 0 ? -width : width }
                Task { try? await Task.sleep(for: .milliseconds(150)); app.openNeighbor(delta) }
            } else {
                withAnimation(.spring(duration: 0.3)) { swipeDX = 0 }
            }
        case .cancelled:
            swipeArmed = false
            withAnimation(.spring(duration: 0.3)) { swipeDX = 0 }
        }
    }
}

struct TerminalRepresentable: UIViewRepresentable {
    let stream: BlockStream
    let fontSize: Double
    let focusOnOpen: Bool
    let onEdgeSwipe: () -> Void
    let onEdgeHover: (CGFloat?) -> Void
    let onCompose: () -> Void
    let onPaneSwipe: (TerminalView.PaneSwipe) -> Void
    let onFontSizeChange: (Double) -> Void
    let onCellTap: (Int, Int) -> Void

    func makeUIView(context: Context) -> TerminalView {
        let v = TerminalView(model: stream.terminal)
        v.setFont(size: fontSize)
        v.onInput = { stream.send($0) }
        v.onGridSize = { stream.requestSize(cols: $0, rows: $1) }
        v.onActivate = { trigger in Task { await stream.claim(trigger) } }
        v.onEdgeSwipe = onEdgeSwipe
        v.onEdgeHover = onEdgeHover
        v.onCompose = onCompose
        v.onPaneSwipe = onPaneSwipe
        v.onFontSizeChange = { onFontSizeChange(Double($0)) }
        v.onCellTap = onCellTap
        Task {
            await stream.start()
            // iPad: ready for a hardware keyboard. iPhone: watch first; tap to bring up the keyboard.
            if focusOnOpen { v.becomeFirstResponder() }
        }
        return v
    }

    func updateUIView(_ v: TerminalView, context: Context) {
        if v.fontSize != fontSize { v.setFont(size: fontSize) }
    }

    static func dismantleUIView(_ v: TerminalView, coordinator: ()) {}
}



/// The last lines of a watched pane, kept current as it draws.
@MainActor
final class PanePreview: ObservableObject {
    @Published var lines: [String] = []
    private(set) var stream: BlockStream?

    func start(_ s: BlockStream?) {
        stream = s
        s?.terminal.onChange = { [weak self] in self?.lines = s?.terminal.lastLines(40) ?? [] }
    }

    func stop() { stream?.stop(); stream = nil }
}

/// A longer message than the terminal line is good for, with dictation, sent as one paste.
struct ComposeView: View {
    let stream: BlockStream
    @AppStorage("composeEnter") private var pressEnter = true
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $text).frame(minHeight: 160).focused($focused)
                Toggle("Press Enter after sending", isOn: $pressEnter)
            }
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { stream.sendText(text, enter: pressEnter); dismiss() }
                        .disabled(text.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
