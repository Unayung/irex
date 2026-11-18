import SwiftUI

@main
struct IrexApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct Pane: Identifiable { let id: String; let sessionId: String; let title: String; let status: String }
    struct Tab: Identifiable { let id: String; let label: String; let panes: [Pane] }
    struct Session: Identifiable { let id: String; let label: String; let tabs: [Tab] }

    @Published private var sessionList: [(id: String, label: String)] = []
    @Published private var views: [String: [String: Any]] = [:]     // session.view by session ID
    @Published private var titles: [String: String] = [:]           // block ID → title the program set
    @Published private var statuses: [String: String] = [:]         // block ID → working / blocked / done
    @Published var status = ""
    @Published var connected = false
    @Published var connecting = false
    @Published var stream: BlockStream?
    @Published var openPaneId: String?
    private var control: RexControl?

    /// Sessions, their tabs, and each tab's panes, in the server's order.
    var sessions: [Session] {
        sessionList.map { s in
            let windows = views[s.id]?["windows"] as? [[String: Any]] ?? []
            return Session(id: s.id, label: s.label, tabs: windows.map { w in
                let blocks = (w["layers"] as? [[String: Any]] ?? []).flatMap { $0["blocks"] as? [[String: Any]] ?? [] }
                return Tab(id: w["window_id"] as? String ?? "", label: w["label"] as? String ?? "", panes: blocks.compactMap { b in
                    guard let id = b["block_id"] as? String else { return nil }
                    let title = titles[id].flatMap { $0.isEmpty ? nil : $0 } ?? b["label"] as? String ?? "Pane"
                    return Pane(id: id, sessionId: s.id, title: title, status: statuses[id] ?? "")
                })
            })
        }
    }

    /// "1 needs you · 3 working", or how many panes there are when nothing's going on.
    var summary: String {
        let panes = sessions.flatMap(\.tabs).flatMap(\.panes)
        let blocked = panes.filter { $0.status == "blocked" }.count, working = panes.filter { $0.status == "working" }.count
        let parts = (blocked > 0 ? ["\(blocked) need\(blocked == 1 ? "s" : "") you"] : []) + (working > 0 ? ["\(working) working"] : [])
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return panes.isEmpty ? "" : "\(panes.count) pane\(panes.count == 1 ? "" : "s")"
    }

    func pane(_ id: String) -> Pane? {
        sessions.lazy.flatMap(\.tabs).flatMap(\.panes).first { $0.id == id }
    }

    func connect(_ address: String) async {
        disconnect()
        guard let ep = RexEndpoint(address) else { status = "That isn't a server address."; return }
        let c = RexControl(endpoint: ep)
        c.onClose = { [weak self] reason in
            self?.status = "Disconnected: \(reason)"
            self?.connected = false; self?.stream = nil; self?.openPaneId = nil
            self?.control = nil; self?.sessionList = []
        }
        c.onEvent = { [weak self] type, payload in self?.handle(type, payload) }
        control = c
        status = ""
        connecting = true
        defer { if control === c || control == nil { connecting = false } }
        do {
            try await c.connect()
            // "all" brings every session's block events too: titles and statuses for the list.
            let r = try await c.call("session.attach_all", ["event_scope": "all"])
            connected = true
            status = ""
            setSessions(r)
        } catch {
            // A newer connect() cancels this one (-999); don't let it overwrite that attempt's status.
            if control === c { status = "\(error)"; control = nil }
        }
    }

    func disconnect() {
        closePane()
        control?.onClose = nil; control?.close(); control = nil
        connected = false
        sessionList = []; views = [:]
    }

    var isIdle: Bool { control == nil }

    func refresh() async {
        guard let c = control, let r = try? await c.call("session.list") else { return }
        setSessions(r)
    }

    private func handle(_ type: String, _ payload: [String: Any]) {
        switch type {
        case "session_created", "session_destroyed", "session_moved":
            Task { await refresh() }
        case "session_event":
            let sessionId = payload["session_id"] as? String ?? ""
            let inner = payload["event"] as? [String: Any] ?? [:]
            switch inner["type"] as? String {
            case "session_label_changed": Task { await refresh() }
            case "session_view_changed": Task { await fetchView(sessionId) }
            case "block_event":
                let block = inner["payload"] as? [String: Any] ?? [:]
                guard let blockId = block["block_id"] as? String else { return }
                let p = block["payload"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "title_changed": titles[blockId] = p["title"] as? String ?? ""
                case "program_status_changed": statuses[blockId] = (p["record"] as? [String: Any])?["state"] as? String
                case "program_status_removed": statuses[blockId] = nil
                default: break
                }
            default: break
            }
        default: break
        }
    }

    private func setSessions(_ r: [String: Any]) {
        sessionList = (r["sessions"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["session_id"] as? String else { return nil }
            return (id, $0["label"] as? String ?? id)
        }
        let ids = Set(sessionList.map(\.id))
        views = views.filter { ids.contains($0.key) }
        if let open = stream?.sessionId, !ids.contains(open) { closePane() }
        for id in ids { Task { await fetchView(id) } }
    }

    private func fetchView(_ sessionId: String) async {
        guard let c = control, let view = try? await c.call("session.view", ["session_id": sessionId]), control === c else { return }
        // Views can arrive out of order; keep the newest.
        if let old = views[sessionId]?["revision"] as? Int, let new = view["revision"] as? Int, new < old { return }
        views[sessionId] = view
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
                           let state = (r["records"] as? [[String: Any]])?.first?["state"] as? String { statuses[id] = state }
                    }
                }
            }
        }
    }

    func open(_ p: Pane) async {
        guard let c = control, stream?.blockId != p.id else { return }
        stream?.stop(); stream = nil
        openPaneId = p.id   // right away, so the iPhone pushes the terminal without waiting for the server
        do {
            try await c.call("session.attach", ["session_id": p.sessionId])
            guard openPaneId == p.id else { return }
            let bs = BlockStream(control: c, sessionId: p.sessionId, blockId: p.id, terminal: TerminalModel())
            bs.onEnded = { [weak self] reason in self?.status = "Stream ended: \(reason)" }
            stream = bs
            status = ""
        } catch {
            status = "\(error)"
        }
    }

    /// A new session with one shell in it, opened right away.
    func newSession() async {
        guard let c = control else { return }
        do {
            let r = try await c.call("session.create", ["initial_windows": [["layout": ["block": ["flavor": "com.superlogical.terminal.shell"]]]]])
            guard let id = r["session_id"] as? String else { return }
            await refresh()
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
    @AppStorage("server") private var server = ""
    @AppStorage("fontSize") private var fontSize = 14.0
    @AppStorage("keepAwake") private var keepAwake = true
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tabY: CGFloat?        // pointer height on the left edge while it's there
    @State private var tabHovered = false
    @State private var columns = NavigationSplitViewVisibility.all   // explicit, so collapsing always reads as .detailOnly
    @State private var settingsShown = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding(get: { app.openPaneId }, set: { id in
                if let id, let p = app.pane(id) { Task { await app.open(p) } } else if id == nil { app.closePane() }
            })) {
                ForEach(app.sessions) { s in
                    Section(s.label) {
                        ForEach(s.tabs) { t in
                            if s.tabs.count > 1 {
                                Label(t.label.isEmpty ? "Tab" : t.label, systemImage: "rectangle.on.rectangle")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                    .selectionDisabled()
                            }
                            ForEach(t.panes) { p in
                                PaneRow(pane: p).padding(.leading, s.tabs.count > 1 ? 16 : 0).tag(p.id)
                            }
                        }
                    }
                }
            }
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
                    TerminalRepresentable(stream: s, fontSize: fontSize,
                                          onEdgeSwipe: { if sizeClass == .compact { app.closePane() } else { columns = .all } },
                                          onEdgeHover: { if !tabHovered { tabY = $0 } }).id(s.blockId)
                } else {
                    Spacer(); Text(app.sessions.isEmpty ? "Connect to a Rex server" : "Pick a pane").foregroundStyle(.secondary); Spacer()
                }
                if !app.status.isEmpty {
                    Text(app.status).font(.footnote).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // The terminal gets the whole height; the way back is a small button instead of a bar.
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .topLeading) {
                if sizeClass == .compact {
                    // iPhone: back to the list (a swipe from the left edge does the same).
                    Button { app.closePane() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
                    }
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(.leading, 6).padding(.top, 2)
                } else if columns == .detailOnly && (tabY != nil || tabHovered || app.stream == nil) {
                    // orex's reveal tab: hidden until the pointer touches the left edge, then out at its height.
                    // Touch opens the sidebar with an edge swipe; with no terminal there's no edge, so it stays out.
                    GeometryReader { geo in
                        Button { columns = .all; tabY = nil; tabHovered = false } label: {
                            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).frame(width: 26, height: 40)
                        }
                        .background(tabHovered ? Color.accentColor.opacity(0.35) : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .onHover { tabHovered = $0 }
                        .offset(y: min(max(4, (tabY ?? 24) - 20), geo.size.height - 44))
                    }
                    .transition(.move(edge: .leading))
                }
            }
            .animation(.easeOut(duration: 0.12), value: tabY == nil && !tabHovered)
        }
        .sheet(isPresented: $settingsShown) { SettingsView(app: app, server: $server, fontSize: $fontSize, keepAwake: $keepAwake) }
        // Watching an agent work shouldn't lock the phone.
        .onChange(of: keepAwake && app.stream != nil, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        // First launch: nothing to connect to yet, so ask for the server.
        .task { if server.isEmpty { settingsShown = true } else { await app.connect(server) } }
        .onChange(of: phase) { _, p in
            guard p == .active else { return }
            // iOS drops sockets in the background; come back connected.
            if app.isIdle && !server.isEmpty { Task { await app.connect(server) } }
            else if let s = app.stream { Task { await s.claim(.sceneActive) } }
        }
    }
}

struct PaneRow: View {
    let pane: AppModel.Pane

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(color)
                .symbolEffect(.pulse, isActive: pane.status == "working")
            Text(pane.title).lineLimit(1)
            Spacer(minLength: 4)
            if pane.status == "blocked" {
                Text("Needs you").font(.caption.weight(.medium)).foregroundStyle(.red)
            }
        }
    }

    private var color: Color {
        switch pane.status {
        case "blocked": .red
        case "working": .orange
        case "done": .green
        default: Color.secondary.opacity(0.3)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @Binding var server: String
    @Binding var fontSize: Double
    @Binding var keepAwake: Bool
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
                    Stepper("Text size \(Int(fontSize))", value: $fontSize, in: 9...24)
                    Toggle("Keep screen on", isOn: $keepAwake)
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("While a pane is open, the phone doesn't lock by itself.")
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

struct TerminalRepresentable: UIViewRepresentable {
    let stream: BlockStream
    let fontSize: Double
    let onEdgeSwipe: () -> Void
    let onEdgeHover: (CGFloat?) -> Void

    func makeUIView(context: Context) -> TerminalView {
        let v = TerminalView(model: stream.terminal)
        v.setFont(size: fontSize)
        v.onInput = { stream.send($0) }
        v.onGridSize = { stream.requestSize(cols: $0, rows: $1) }
        v.onActivate = { trigger in Task { await stream.claim(trigger) } }
        v.onEdgeSwipe = onEdgeSwipe
        v.onEdgeHover = onEdgeHover
        Task {
            await stream.start()
            v.becomeFirstResponder()
        }
        return v
    }

    func updateUIView(_ v: TerminalView, context: Context) {
        if v.fontSize != fontSize { v.setFont(size: fontSize) }
    }

    static func dismantleUIView(_ v: TerminalView, coordinator: ()) {}
}
