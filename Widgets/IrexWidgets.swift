import ActivityKit
import SwiftUI
import WidgetKit

@main
struct IrexWidgets: WidgetBundle {
    var body: some Widget { AgentsLiveActivity() }
}

private let teal = Color(red: 0.18, green: 0.83, blue: 0.75)
private let navy = Color(red: 0.07, green: 0.09, blue: 0.15)

private func color(_ state: String) -> Color {
    switch state {
    case "blocked": .red
    case "working": .orange
    case "done": .green
    default: .gray
    }
}

private func word(_ state: String) -> String {
    switch state {
    case "blocked": "Needs you"
    case "working": "Working"
    case "done": "Done"
    default: ""
    }
}

/// On the lock screen and in the Dynamic Island: what every agent is up to, the ones
/// that need you first. Tapping opens irex at the agent on top.
struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentsAttributes.self) { context in
            LockScreen(state: context.state)
                .activityBackgroundTint(navy)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(paneURL(context.state.items.first?.block))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Mark().padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.headline).font(.caption.weight(.semibold))
                        .foregroundStyle(context.state.blocked > 0 ? .red : .secondary)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Rows(items: context.state.items).padding(.horizontal, 6)
                }
            } compactLeading: {
                Mark()
            } compactTrailing: {
                // The number that matters most: who needs you, else how many work.
                let s = context.state
                Text("\(s.blocked > 0 ? s.blocked : s.working)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(s.blocked > 0 ? .red : .orange)
            } minimal: {
                Circle().fill(context.state.blocked > 0 ? .red : context.state.working > 0 ? .orange : .green)
                    .frame(width: 10, height: 10)
            }
            .widgetURL(paneURL(context.state.items.first?.block))
            .keylineTint(teal)
        }
    }
}

/// irex's mark: a prompt and a cursor.
struct Mark: View {
    var body: some View {
        Text(">_").font(.system(.subheadline, design: .monospaced).weight(.heavy)).foregroundStyle(teal)
    }
}

struct LockScreen: View {
    let state: AgentsAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Mark()
                Text(state.headline).font(.headline).foregroundStyle(.white)
                Spacer()
            }
            Rows(items: state.items)
        }
        .padding(14)
    }
}

struct Rows: View {
    let items: [AgentsAttributes.ContentState.Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items, id: \.block) { item in
                Link(destination: paneURL(item.block) ?? URL(string: "irex://")!) {
                    HStack(spacing: 8) {
                        Circle().fill(color(item.state)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(word(item.state)).font(.caption2.weight(.semibold)).foregroundStyle(color(item.state))
                    }
                }
            }
        }
    }
}
