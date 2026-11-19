import SwiftUI

// irex's own components: the list is a dashboard of agents, not a settings page,
// so it's drawn with cards rather than a grouped List.

enum Status {
    static func color(_ s: String) -> Color {
        switch s {
        case "blocked": .red
        case "working": .orange
        case "done": .green
        default: .secondary
        }
    }

    static func word(_ s: String) -> String {
        switch s {
        case "blocked": "Needs you"
        case "working": "Working"
        case "done": "Done"
        default: ""
        }
    }
}

/// The mark of the coding agent in a pane (Simple Icons, CC0), when there is one.
struct AgentIcon: View {
    let agent: String
    @ScaledMetric private var size: CGFloat
    init(agent: String, size: CGFloat = 14) { self.agent = agent; _size = ScaledMetric(wrappedValue: size) }

    private static let assets = ["claude": "agent-claude", "codex": "agent-openai", "copilot": "agent-githubcopilot",
                                 "gemini": "agent-googlegemini", "opencode": "agent-opencode", "kimi": "agent-kimi"]

    var body: some View {
        if let name = Self.assets[agent] {
            Image(name).resizable().scaledToFit().frame(width: size, height: size).accessibilityLabel(agent)
        }
    }
}

/// A pane's status at a glance: pulses while working, a check when done, hollow when idle.
struct StatusGlyph: View {
    let status: String
    @ScaledMetric private var dot: CGFloat = 9   // grows with the text beside it

    var body: some View {
        Group {
            switch status {
            case "done": Image(systemName: "checkmark.circle.fill").font(.system(size: dot * 1.2, weight: .bold))
            case "": Image(systemName: "circle").font(.system(size: dot, weight: .semibold))
            default:
                Image(systemName: "circle.fill").font(.system(size: dot))
                    .symbolEffect(.pulse, isActive: status == "working")
            }
        }
        .foregroundStyle(status.isEmpty ? Color.secondary.opacity(0.5) : Status.color(status))
        .frame(width: dot * 1.6)
    }
}

/// "Reviewing the parser · 3 min ago", kept fresh.
struct ActivityLine: View {
    let detail: String
    let since: Date?
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            // Large text: the activity gets lines of its own, and the time one below it.
            if type.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    if !detail.isEmpty { Text(detail).lineLimit(3) }
                    if let since { Text(since, format: .relative(presentation: .named, unitsStyle: .abbreviated)) }
                }
            } else {
                HStack(spacing: 4) {
                    if !detail.isEmpty { Text(detail).lineLimit(1) }
                    if !detail.isEmpty && since != nil { Text("·") }
                    if let since { Text(since, format: .relative(presentation: .named, unitsStyle: .abbreviated)).fixedSize() }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One pane in a session card.
struct PaneLine: View {
    let pane: AppModel.Pane
    let muted: Bool
    let selected: Bool
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusGlyph(status: pane.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AgentIcon(agent: pane.agent)
                    Text(pane.title).font(.body.weight(pane.status.isEmpty ? .regular : .medium))
                        .lineLimit(type.isAccessibilitySize ? 3 : 1)
                        .foregroundStyle(pane.status.isEmpty ? .secondary : .primary)
                }
                if !pane.detail.isEmpty || (pane.since != nil && !pane.status.isEmpty) {
                    ActivityLine(detail: pane.detail, since: pane.status.isEmpty ? nil : pane.since)
                }
            }
            Spacer(minLength: 6)
            if muted { Image(systemName: "bell.slash").font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        // One sentence for VoiceOver: "REVIEWER, working, reviewing the PR, 3 minutes ago".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var spoken: String {
        var parts = [pane.title]
        if !pane.agent.isEmpty { parts.append(pane.agent) }
        parts.append(pane.status.isEmpty ? "idle" : Status.word(pane.status).lowercased())
        if !pane.detail.isEmpty { parts.append(pane.detail) }
        if let since = pane.since, !pane.status.isEmpty {
            parts.append(since.formatted(.relative(presentation: .named, unitsStyle: .wide)))
        }
        if muted { parts.append("muted") }
        return parts.joined(separator: ", ")
    }
}

/// A session: its name and what its agents are up to, then its panes, tab by tab.
struct SessionCard: View {
    let session: AppModel.Session
    let mutedIDs: Set<String>
    let openPaneId: String?
    let onOpen: (AppModel.Pane) -> Void
    let onMute: (String, Bool) -> Void
    var onRename: () -> Void = {}
    var onClose: () -> Void = {}
    var onClosePane: (AppModel.Pane) -> Void = { _ in }
    var searching = false
    @State private var showIdle = false
    @Environment(\.dynamicTypeSize) private var type

    private var sessionMuted: Bool { mutedIDs.contains(session.id) }

    /// Idle panes fold away behind one row when there are a few of them, so busy ones stand out.
    /// The open pane always shows, and nothing folds while searching.
    private var folded: (shown: [AppModel.Pane], idle: Int)? {
        let panes = session.tabs.flatMap(\.panes)
        let idle = panes.filter { $0.status.isEmpty && $0.id != openPaneId }
        guard !searching, !showIdle, idle.count >= 2 else { return nil }
        return (panes.filter { !$0.status.isEmpty || $0.id == openPaneId }, idle.count)
    }

    private var summary: String {
        let panes = session.tabs.flatMap(\.panes)
        let blocked = panes.filter { $0.status == "blocked" }.count, working = panes.filter { $0.status == "working" }.count
        if blocked > 0 { return "\(blocked) need\(blocked == 1 ? "s" : "") you" }
        if working > 0 { return "\(working) working" }
        return "\(panes.count) pane\(panes.count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Large text: the name gets the width, with what's going on beneath it.
            Group {
                if type.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.label).font(.subheadline.weight(.semibold)).lineLimit(2)
                        HStack(spacing: 8) { headerDetails }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(session.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                        headerDetails
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)

            if let folded {
                ForEach(folded.shown) { row($0) }
                foldRow(folded.idle == session.tabs.flatMap(\.panes).count
                        ? "\(folded.idle) idle panes" : "\(folded.idle) more idle panes", open: false)
            } else {
                ForEach(session.tabs) { tab in
                    if session.tabs.count > 1 {
                        HStack(spacing: 6) {
                            if tab.panes.count > 1 { PaneMap(tab: tab, current: openPaneId, width: 18) }
                            Text(tab.label.isEmpty ? "Tab" : tab.label)
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary).textCase(.uppercase)
                        }
                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                    }
                    ForEach(tab.panes) { row($0) }
                }
                if showIdle && !searching { foldRow("Hide idle panes", open: true) }
            }
            Spacer(minLength: 6)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// An agent waiting on you, at the top of the list: what it asks, and the way to answer.
extension SessionCard {
    @ViewBuilder private var headerDetails: some View {
                Text(summary).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(summary.contains("need") ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12)))
            .foregroundStyle(summary.contains("need") ? .red : .secondary)
        Spacer(minLength: 4)
        if let host = session.host {
            Label(host, systemImage: "desktopcomputer").font(.caption2).foregroundStyle(.secondary)
        }
        if sessionMuted { Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(.secondary) }
        Menu {
            Button { onMute(session.id, !sessionMuted) } label: {
                Label(sessionMuted ? "Unmute session" : "Mute session", systemImage: sessionMuted ? "bell" : "bell.slash")
            }
            Button(action: onRename) { Label("Rename…", systemImage: "pencil") }
            Divider()
            Button(role: .destructive, action: onClose) { Label("Close Session…", systemImage: "xmark.circle") }
        } label: {
            Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 28, height: 24).contentShape(Rectangle())
        }
    }

    private func row(_ pane: AppModel.Pane) -> some View {
        let paneMuted = mutedIDs.contains(pane.id)
        return Button { onOpen(pane) } label: {
            PaneLine(pane: pane, muted: paneMuted || sessionMuted, selected: pane.id == openPaneId)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onMute(pane.id, !paneMuted) } label: {
                Label(paneMuted ? "Unmute this pane" : "Mute this pane", systemImage: paneMuted ? "bell" : "bell.slash")
            }
            Button { onMute(session.id, !sessionMuted) } label: {
                Label(sessionMuted ? "Unmute \(session.label)" : "Mute \(session.label)",
                      systemImage: sessionMuted ? "bell" : "bell.slash")
            }
            Divider()
            Button(role: .destructive) { onClosePane(pane) } label: { Label("Close Pane…", systemImage: "xmark.square") }
        }
    }

    private func foldRow(_ title: String, open: Bool) -> some View {
        Button { withAnimation(.snappy) { showIdle.toggle() } } label: {
            HStack(spacing: 10) {
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).frame(width: 14)
                Text(title).font(.subheadline)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NeedsYouCard: View {
    let pane: AppModel.Pane
    let onReply: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.red).frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    AgentIcon(agent: pane.agent, size: 16)
                    Text(pane.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 6)
                    if let since = pane.since {
                        Text(since, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(pane.detail.isEmpty ? "Waiting for you in \(pane.sessionLabel)" : pane.detail)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Button(action: onReply) {
                        Label("Reply", systemImage: "arrowshape.turn.up.left.fill").font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    Button(action: onOpen) {
                        Text("Open").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.regular)
            }
            .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Above the terminal: the way back, which pane this is, and what you can do with it.
struct PaneHeader: View {
    @ObservedObject var stream: BlockStream
    let pane: AppModel.Pane?
    let place: AppModel.Place?
    let compact: Bool
    let onBack: () -> Void
    let onOverview: () -> Void
    let onCompose: () -> Void
    let onAttach: (AttachSource) -> Void

    enum AttachSource { case photos, camera, files }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: compact ? "chevron.left" : "sidebar.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel(compact ? "Back" : "Show sessions")
            if let place, place.count > 1 {
                // Where this pane sits in its tab; tap for every tab and pane.
                Button(action: onOverview) {
                    PaneMap(tab: place.tab, current: place.pane.id, width: 24)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .accessibilityLabel("All panes, \(place.position) of \(place.count)")
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let pane, !pane.status.isEmpty { StatusGlyph(status: pane.status) }
                    if let pane { AgentIcon(agent: pane.agent) }
                    Text(pane?.title ?? "Pane").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if let pane {
                    let tab = place.flatMap { $0.tabCount > 1 ? " · \($0.tab.label)" : nil } ?? ""
                    Text(pane.sessionLabel + tab + (pane.detail.isEmpty ? "" : " · \(pane.detail)"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if !stream.owning {
                // Another client sizes this pane; take it for this screen.
                Button { Task { await stream.claim(.explicit) } } label: {
                    Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            // An image or file for the agent: Rex puts it on the pane's machine and types its path.
            Menu {
                Button { onAttach(.photos) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { onAttach(.camera) } label: { Label("Take Photo", systemImage: "camera") }
                }
                Button { onAttach(.files) } label: { Label("Files", systemImage: "folder") }
            } label: {
                Image(systemName: "paperclip").font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Attach")
            Button(action: onCompose) {
                Image(systemName: "square.and.pencil").font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Write a message")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: quick reply

/// A choice an agent offers on screen, such as "1. Yes".
struct ReplyOption: Identifiable {
    let key: String
    var label: String
    var id: String { key }

    /// The numbered choices at the bottom of the screen, with lines the terminal wrapped joined back up.
    static func parse(_ lines: [String]) -> (question: String?, options: [ReplyOption]) {
        let pattern = #"^\s*(?:[❯›>]\s*)?(\d)\.\s+(.*)$"#
        let width = lines.map(\.count).max() ?? 0
        var options: [ReplyOption] = []
        var firstOptionLine: Int?
        for (i, line) in lines.enumerated() {
            if let m = line.range(of: pattern, options: .regularExpression) {
                let text = String(line[m])
                let key = text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
                let label = text.replacingOccurrences(of: pattern, with: "$2", options: .regularExpression)
                // A fresh run of numbers starts the choices over: only the last list counts.
                if key == "1" { options = []; firstOptionLine = i }
                options.append(ReplyOption(key: key, label: label.trimmingCharacters(in: .whitespaces)))
            } else if !options.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty, i > 0 {
                // A wrapped line carries on the last choice; a full previous line means no space was lost.
                let joiner = lines[i - 1].count >= width - 1 ? "" : " "
                options[options.count - 1].label += joiner + line.trimmingCharacters(in: .whitespaces)
            }
        }
        let question = firstOptionLine.flatMap { first in
            lines[..<first].last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces)
        }
        return (question, options)
    }
}

/// A blocked agent's question and its choices as buttons, read from a stream that only watches.
struct QuickReplyView: View {
    @ObservedObject var app: AppModel
    let pane: AppModel.Pane
    let onOpen: (BlockStream?) -> Void
    @StateObject private var preview = PanePreview()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let parsed = ReplyOption.parse(preview.lines)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pane.sessionLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(parsed.question ?? (pane.detail.isEmpty ? "Waiting for you" : pane.detail))
                            .font(.title3.weight(.semibold))
                    }
                    // The end of the screen, as the agent shows it.
                    Text(preview.lines.suffix(10).joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(red: 0.07, green: 0.09, blue: 0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if parsed.options.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(["1", "2", "3"], id: \.self) { n in
                                choice(key: n, label: nil) { $0.send(Data(n.utf8)) }
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(parsed.options) { o in
                                choice(key: o.key, label: o.label) { $0.send(Data(o.key.utf8)) }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        secondary("Esc") { $0.send($0.terminal.escapeKey) }
                        secondary("Enter") { $0.send($0.terminal.enterKey) }
                    }
                }
                .padding()
            }
            .navigationTitle(pane.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Open") { onOpen(preview.take()) } }
            }
        }
        .onAppear { preview.start(app.watch(pane)) }
        .onDisappear { preview.stop() }
    }

    private func send(_ action: @escaping (BlockStream) -> Void) {
        guard let s = preview.stream else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        action(s)
        // Long enough to see the agent take it.
        Task { try? await Task.sleep(for: .milliseconds(600)); dismiss() }
    }

    private func choice(key: String, label: String?, _ action: @escaping (BlockStream) -> Void) -> some View {
        Button { send(action) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(key).font(.headline.monospaced()).foregroundStyle(.tint)
                    .frame(width: 28, height: 28).background(Circle().fill(Color.accentColor.opacity(0.15)))
                if let label {
                    Text(label).font(.body).multilineTextAlignment(.leading).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: label == nil ? .center : .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ title: String, _ action: @escaping (BlockStream) -> Void) -> some View {
        Button { send(action) } label: {
            Text(title).font(.subheadline.weight(.semibold).monospaced()).frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
    }
}

/// Beside the terminal during a sideways swipe: the pane letting go would open, or that there's none.
struct SwipePreview: View {
    let target: AppModel.Place?
    let newTab: Bool     // letting go crosses into another tab
    let forward: Bool
    let armed: Bool
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: forward ? (armed ? "arrow.right.circle.fill" : "arrow.right.circle")
                                      : (armed ? "arrow.left.circle.fill" : "arrow.left.circle"))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(target == nil ? Color.secondary : Color.accentColor)
                .symbolEffect(.bounce, value: armed)
            if let t = target {
                if t.tab.panes.count > 1 || newTab { PaneMap(tab: t.tab, current: t.pane.id, width: 44).padding(.vertical, 2) }
                HStack(spacing: 6) {
                    if !t.pane.status.isEmpty { StatusGlyph(status: t.pane.status) }
                    Text(t.pane.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                }
                Text(newTab ? "\(t.tab.label) · \(t.position) of \(t.count)" : "\(t.position) of \(t.count)")
                    .font(.caption2.monospacedDigit().weight(newTab ? .semibold : .regular))
                    .foregroundStyle(newTab ? Color.accentColor : .secondary)
                Text(armed ? "Release to open" : "Keep swiping").font(.caption2.weight(.medium))
                    .foregroundStyle(armed ? Color.accentColor : .secondary)
            } else {
                Text(forward ? "Last pane" : "First pane").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(armed ? Color.accentColor.opacity(0.18) : .clear)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(armed ? Color.accentColor : .clear, lineWidth: 1.5))
        .scaleEffect(0.85 + 0.15 * progress)
        .opacity(Double(0.35 + 0.65 * progress))
        .animation(.spring(duration: 0.2), value: armed)
    }
}

/// irex's mark drawn in SwiftUI: the app icon's prompt and cursor.
struct AppMark: View {
    var size: CGFloat = 88

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.27), Color(red: 0.04, green: 0.06, blue: 0.10)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                HStack(alignment: .bottom, spacing: size * 0.06) {
                    Image(systemName: "chevron.right").font(.system(size: size * 0.42, weight: .heavy))
                        .foregroundStyle(Color(red: 0.18, green: 0.83, blue: 0.75))
                    RoundedRectangle(cornerRadius: size * 0.03).fill(Color(white: 0.9))
                        .frame(width: size * 0.2, height: size * 0.09).padding(.bottom, size * 0.08)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }
}

/// The first launch: what irex is, and the one thing it needs, a server to connect to.
struct WelcomeView: View {
    let onConnect: (String) -> Void
    @State private var address = ""
    @FocusState private var focused: Bool

    private var valid: Bool { RexEndpoint(address) != nil }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppMark()
            Text("irex").font(.system(size: 34, weight: .bold, design: .monospaced)).padding(.top, 20)
            Text("Your Rex sessions and the agents in them, wherever you are.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 6).padding(.horizontal, 32)
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("Rex server").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                TextField("host.tailnet.ts.net:7297", text: $address)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .submitLabel(.go).focused($focused)
                    .onSubmit { if valid { onConnect(address.trimmingCharacters(in: .whitespaces)) } }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("A Rex server you can reach, such as one on your tailnet. Put account@ in front to connect as another account.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            Button { onConnect(address.trimmingCharacters(in: .whitespaces)) } label: {
                Text("Connect").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!valid)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
    }
}

/// Over the top of the terminal while an attachment goes up, and briefly once it's there.
struct UploadNote: View {
    @ObservedObject var stream: BlockStream

    var body: some View {
        if let note = stream.uploadNote {
            HStack(spacing: 6) {
                if stream.uploadFailed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else if note.hasPrefix("Uploading") {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(note).lineLimit(2)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Where a new session goes, and what it's called; the server picks a name if you don't.
struct NewSessionView: View {
    let hosts: [AppModel.HostState]
    let onCreate: (String, String) -> Void
    @State private var name = ""
    @State private var host = "local"
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused).submitLabel(.go)
                        .onSubmit { onCreate(host, name) }
                } footer: {
                    Text("A shell starts in it. Leave the name empty and the server picks one.")
                }
                if hosts.count > 1 {
                    Section("Host") {
                        Picker("Host", selection: $host) {
                            ForEach(hosts) { h in Text(h.label).tag(h.id) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { onCreate(host, name) } }
            }
            .onAppear { focused = true }
        }
    }
}

/// Over a pane whose stream stopped: the program ended, or the connection to it went.
struct StreamEnded: View {
    @ObservedObject var stream: BlockStream
    let onReconnect: () -> Void
    let onClose: () -> Void

    var body: some View {
        if let reason = stream.ended {
            VStack(spacing: 10) {
                Image(systemName: stream.exited ? "checkmark.circle" : "bolt.horizontal.circle")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(stream.exited ? Color.secondary : Color.orange)
                Text(stream.exited ? "The program ended" : "Lost the connection to this pane")
                    .font(.headline).multilineTextAlignment(.center)
                if !reason.isEmpty {
                    Text(reason).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(3)
                }
                HStack(spacing: 10) {
                    Button("Close", action: onClose).buttonStyle(.bordered)
                    if !stream.exited { Button("Reconnect", action: onReconnect).buttonStyle(.borderedProminent) }
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.25))
            .transition(.opacity)
        }
    }
}

/// The pane side with no pane open (iPad): where things stand, and the keys that get around.
struct DetailPlaceholder: View {
    let connected: Bool
    let summary: String
    let hasSessions: Bool

    private let keys: [(String, String)] = [("⌘ [  ⌘ ]", "Previous and next pane"), ("⌘ F", "Search"),
                                             ("⌘ N", "New session"), ("⌘ ↩", "Write a message"), ("⌘ \\", "All panes"), ("⌘ W", "Close the pane")]

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            AppMark(size: 64).opacity(connected ? 1 : 0.5)
            Text(!connected ? "Not connected" : hasSessions ? "Pick a pane" : "No sessions yet")
                .font(.title3.weight(.semibold))
            Text(!connected ? "Connect to a Rex server in Settings." : summary.isEmpty ? "Choose one from the list." : summary)
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if connected {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(keys, id: \.0) { k in
                        GridRow {
                            Text(k.0).font(.footnote.monospaced().weight(.semibold)).gridColumnAlignment(.trailing)
                            Text(k.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// A tab's split drawn small: where each pane sits, the one you're on filled in, one waiting on you in red.
struct PaneMap: View {
    let tab: AppModel.Tab
    var current: String?
    var width: CGFloat = 22

    var body: some View {
        let height = width / 1.6   // about a desktop window's shape
        let gap = max(1, width * 0.06)
        ZStack(alignment: .topLeading) {
            ForEach(tab.panes) { p in
                RoundedRectangle(cornerRadius: max(1, width * 0.05), style: .continuous)
                    .fill(p.id == current ? Color.accentColor : p.status == "blocked" ? Color.red : Color.secondary.opacity(0.35))
                    .frame(width: max(2, p.rect.width * width - gap), height: max(2, p.rect.height * height - gap))
                    .offset(x: p.rect.minX * width + gap / 2, y: p.rect.minY * height + gap / 2)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// Every tab of a session drawn as its split, each pane with its latest output, like a tab grid.
/// Tapping a pane goes there.
struct PaneOverview: View {
    @ObservedObject var app: AppModel
    let sessionId: String
    let onPick: (AppModel.Pane, BlockStream?) -> Void
    @StateObject private var previews = PanePreviews()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let session = app.sessions.first { $0.id == sessionId }
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], alignment: .leading, spacing: 20) {
                    ForEach(session?.tabs ?? []) { tab in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(tab.label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                                Spacer()
                                Text(tab.panes.count == 1 ? "1 pane" : "\(tab.panes.count) panes").font(.caption2).foregroundStyle(.tertiary)
                            }
                            GeometryReader { g in
                                ForEach(tab.panes) { p in region(p, in: g.size) }
                            }
                            .aspectRatio(1.6, contentMode: .fit)
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(session?.label ?? "Panes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { previews.start(session?.tabs.flatMap(\.panes) ?? [], app: app) }
        .onDisappear { previews.stop() }
        #if DEBUG
        // `-overviewPick <n>` with `-showOverview YES`: taps the nth pane, for simulator checks.
        .task {
            let n = UserDefaults.standard.integer(forKey: "overviewPick")
            guard n > 0 else { return }
            try? await Task.sleep(for: .seconds(4))
            if let p = session?.tabs.flatMap(\.panes).dropFirst(n - 1).first { onPick(p, previews.take(p.id)) }
        }
        #endif
    }

    private func region(_ p: AppModel.Pane, in size: CGSize) -> some View {
        let gap: CGFloat = 5
        let w = max(10, p.rect.width * size.width - gap), h = max(10, p.rect.height * size.height - gap)
        let here = p.id == app.openPaneId
        // As many of the latest lines as fit under the title and the agent's note.
        let rows = max(0, Int((h - (p.detail.isEmpty ? 30 : 52)) / 9))
        return Button { onPick(p, previews.take(p.id)) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if !p.status.isEmpty { StatusGlyph(status: p.status) }
                    AgentIcon(agent: p.agent)
                    Text(p.title).font(.caption2.weight(.semibold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                if !p.detail.isEmpty {
                    Text(p.detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(previews.lines[p.id, default: []].suffix(rows).enumerated()), id: \.offset) { _, line in
                        Text(line).lineLimit(1).frame(height: 9)
                    }
                }
                .font(.system(size: 7, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(7)
            .frame(width: w, height: h, alignment: .topLeading)
            .background(Color(red: 0.07, green: 0.09, blue: 0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(here ? Color.accentColor : p.status == "blocked" ? .red : .clear, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(x: p.rect.minX * size.width + gap / 2, y: p.rect.minY * size.height + gap / 2)
        .accessibilityLabel("\(p.title)\(here ? ", open now" : "")\(p.detail.isEmpty ? "" : ", \(p.detail)")")
    }
}

/// At the bottom of a pane whose agent waits on you: its choices as buttons, read off the screen,
/// so answering doesn't need the keyboard. Gone once the agent moves on.
struct AnswerBar: View {
    @ObservedObject var stream: BlockStream
    let pane: AppModel.Pane?

    var body: some View {
        if pane?.status == "blocked" {
            // The terminal's own redraw hook is the view's, so read the screen once a second instead.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let options = ReplyOption.parse(stream.terminal.lastLines(30)).options
                if !options.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(options) { o in
                                chip(o.key, o.label) { stream.send(Data(o.key.utf8)) }
                            }
                            chip(nil, "Esc") { stream.send(stream.terminal.escapeKey) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func chip(_ key: String?, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                if let key {
                    Text(key).font(.subheadline.monospaced().weight(.bold)).foregroundStyle(.tint)
                }
                Text(label).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
            }
            .padding(.horizontal, 12).frame(minHeight: 36).frame(maxWidth: 240)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.map { "\($0), \(label)" } ?? label)
    }
}
