import SwiftUI
import WidgetKit

// The Agents widget's look, shared with the app to render it for checks.

struct AgentsEntry: TimelineEntry {
    let date: Date
    let state: AgentsAttributes.ContentState?   // nil: the build didn't say where irex-push is (RELAY in bin/config)
    var stale = false                           // irex-push didn't answer; this is the last thing it said
}

struct AgentsWidgetView: View {
    let entry: AgentsEntry
    var size: WidgetFamily?   // for rendering outside a widget; inside one, the family it's in
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { size ?? envFamily }

    var body: some View {
        if let state = entry.state {
            switch family {
            case .accessoryInline:
                Text(state.blocked > 0 ? "✋ \(state.headline)" : state.headline)
            case .accessoryCircular:
                circular(state)
            case .accessoryRectangular:
                rectangular(state)
            case .systemSmall:
                small(state)
            default:
                // Medium has room for two rows.
                let rows = Array(state.items.prefix(2))
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Mark()
                        Text(state.headline).font(.headline).foregroundStyle(.white)
                        Spacer()
                        staleMark
                    }
                    Rows(items: rows, more: state.more + state.items.count - rows.count)
                    Spacer(minLength: 0)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Mark()
                Text("Set RELAY in bin/config and build again").font(.footnote.weight(.semibold)).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var staleMark: some View {
        if entry.stale {
            Image(systemName: "bolt.horizontal.circle").font(.caption).foregroundStyle(.white.opacity(0.5))
                .accessibilityLabel("Not current")
        }
    }

    private func small(_ s: AgentsAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Mark(); Spacer(); staleMark }
            Spacer(minLength: 0)
            if s.blocked + s.working == 0 {
                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                Text(s.done > 0 ? "All done" : "All quiet").font(.headline).foregroundStyle(.white)
            } else {
                count(s.blocked, "need you", .red)
                count(s.working, "working", .orange)
            }
            if let top = s.items.first {
                Text(top.title).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func count(_ n: Int, _ label: String, _ color: Color) -> some View {
        if n > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(n)").font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(color)
                Text(n == 1 && label == "need you" ? "needs you" : label).font(.footnote.weight(.semibold)).foregroundStyle(.white)
            }
        }
    }

    private func circular(_ s: AgentsAttributes.ContentState) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: s.blocked > 0 ? "hand.raised.fill" : s.working > 0 ? "circle.dotted" : "checkmark")
                    .font(.system(size: 13, weight: .bold))
                if s.blocked + s.working > 0 {
                    Text("\(s.blocked > 0 ? s.blocked : s.working)").font(.system(.title3, design: .rounded).weight(.bold))
                }
            }
        }
        .widgetAccentable()
    }

    private func rectangular(_ s: AgentsAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // Only the part that matters most fits: who needs you, else who's working.
            let first = s.headline.components(separatedBy: " · ").first ?? s.headline
            Text(s.blocked > 0 ? "✋ \(first)" : first).font(.headline).widgetAccentable().lineLimit(1)
            ForEach(s.items.prefix(2), id: \.block) { item in
                Text(item.title).font(.caption).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
