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

/// A pane's status at a glance: pulses while working, a check when done, hollow when idle.
struct StatusGlyph: View {
    let status: String

    var body: some View {
        Group {
            switch status {
            case "done": Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .bold))
            case "": Image(systemName: "circle").font(.system(size: 9, weight: .semibold))
            default:
                Image(systemName: "circle.fill").font(.system(size: 9))
                    .symbolEffect(.pulse, isActive: status == "working")
            }
        }
        .foregroundStyle(status.isEmpty ? Color.secondary.opacity(0.5) : Status.color(status))
        .frame(width: 14)
    }
}

/// "Reviewing the parser · 3 min ago", kept fresh.
struct ActivityLine: View {
    let detail: String
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 4) {
                if !detail.isEmpty { Text(detail).lineLimit(1) }
                if !detail.isEmpty && since != nil { Text("·") }
                if let since { Text(since, format: .relative(presentation: .named, unitsStyle: .abbreviated)).fixedSize() }
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusGlyph(status: pane.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title).font(.body.weight(pane.status.isEmpty ? .regular : .medium)).lineLimit(1)
                    .foregroundStyle(pane.status.isEmpty ? .secondary : .primary)
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
    }
}

/// A session: its name and what its agents are up to, then its panes, tab by tab.
struct SessionCard: View {
    let session: AppModel.Session
    let mutedIDs: Set<String>
    let openPaneId: String?
    let onOpen: (AppModel.Pane) -> Void
    let onMute: (String, Bool) -> Void

    private var sessionMuted: Bool { mutedIDs.contains(session.id) }

    private var summary: String {
        let panes = session.tabs.flatMap(\.panes)
        let blocked = panes.filter { $0.status == "blocked" }.count, working = panes.filter { $0.status == "working" }.count
        if blocked > 0 { return "\(blocked) need\(blocked == 1 ? "s" : "") you" }
        if working > 0 { return "\(working) working" }
        return "\(panes.count) pane\(panes.count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(session.label).font(.subheadline.weight(.semibold)).lineLimit(1)
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
                } label: {
                    Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 24).contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)

            ForEach(session.tabs) { tab in
                if session.tabs.count > 1 {
                    Text(tab.label.isEmpty ? "Tab" : tab.label)
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary).textCase(.uppercase)
                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                }
                ForEach(tab.panes) { pane in
                    let paneMuted = mutedIDs.contains(pane.id)
                    Button { onOpen(pane) } label: {
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
                    }
                }
            }
            Spacer(minLength: 6)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// An agent waiting on you, at the top of the list: what it asks, and the way to answer.
struct NeedsYouCard: View {
    let pane: AppModel.Pane
    let onReply: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.red).frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
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
    let compact: Bool
    let onBack: () -> Void
    let onCompose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: compact ? "chevron.left" : "sidebar.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel(compact ? "Back" : "Show sessions")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let pane, !pane.status.isEmpty { StatusGlyph(status: pane.status) }
                    Text(pane?.title ?? "Pane").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if let pane {
                    Text(pane.detail.isEmpty ? pane.sessionLabel : "\(pane.sessionLabel) · \(pane.detail)")
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
    let onOpen: () -> Void
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
                ToolbarItem(placement: .confirmationAction) { Button("Open", action: onOpen) }
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
    let target: (pane: AppModel.Pane, position: Int, count: Int)?
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
                HStack(spacing: 6) {
                    if !t.pane.status.isEmpty { StatusGlyph(status: t.pane.status) }
                    Text(t.pane.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                }
                Text("\(t.position) of \(t.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(armed ? "Release to open" : "Keep swiping").font(.caption2.weight(.medium))
                    .foregroundStyle(armed ? Color.accentColor : .secondary)
            } else {
                Text(forward ? "Last pane" : "First pane").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(armed ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(armed ? Color.accentColor : .clear, lineWidth: 1.5))
        .scaleEffect(0.85 + 0.15 * progress)
        .opacity(Double(0.35 + 0.65 * progress))
        .animation(.spring(duration: 0.2), value: armed)
    }
}
