import SwiftUI
import WidgetKit

// The Live Activity's views, shared by the widget extension and, for rendering checks, the app.

let activityTeal = Color(red: 0.18, green: 0.83, blue: 0.75)
let activityNavy = Color(red: 0.07, green: 0.09, blue: 0.15)

func activityColor(_ state: String) -> Color {
    switch state {
    case "blocked": .red
    case "working": .orange
    case "done": .green
    default: .gray
    }
}

func activityWord(_ state: String) -> String {
    switch state {
    case "blocked": "Needs you"
    case "working": "Working"
    case "done": "Done"
    default: ""
    }
}

/// irex's mark: a prompt and a cursor.
struct Mark: View {
    var body: some View {
        Text(">_").font(.system(.subheadline, design: .monospaced).weight(.heavy)).foregroundStyle(activityTeal)
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
            Rows(items: state.items, more: state.more)
        }
        .padding(14)
    }
}

struct Rows: View {
    let items: [AgentsAttributes.ContentState.Item]
    var more = 0   // agents beyond the rows shown

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items, id: \.block) { item in
                Link(destination: paneURL(item.block) ?? URL(string: "irex://")!) {
                    HStack(spacing: 8) {
                        Circle().fill(activityColor(item.state)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(activityWord(item.state)).font(.caption2.weight(.semibold)).foregroundStyle(activityColor(item.state))
                    }
                }
            }
            if more > 0 {
                Text("+\(more) more").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.5)).padding(.leading, 15)
            }
        }
    }
}

/// The Dynamic Island's compact trailing side: the number that matters most, who needs you, else how many work.
struct CompactCount: View {
    let state: AgentsAttributes.ContentState
    var body: some View {
        // What the number counts, by its mark: a raised hand waits on you, a dot works, a check is done.
        HStack(spacing: 3) {
            if state.blocked > 0 {
                Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .bold))
                Text("\(state.blocked)").font(.caption.weight(.bold).monospacedDigit())
            } else if state.working > 0 {
                Image(systemName: "circle.fill").font(.system(size: 7))
                Text("\(state.working)").font(.caption.weight(.bold).monospacedDigit())
            } else {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
            }
        }
        .foregroundStyle(state.blocked > 0 ? .red : state.working > 0 ? .orange : .green)
    }
}

struct MinimalDot: View {
    let state: AgentsAttributes.ContentState
    var body: some View {
        Circle().fill(state.blocked > 0 ? .red : state.working > 0 ? .orange : .green).frame(width: 10, height: 10)
    }
}

struct ExpandedHeadline: View {
    let state: AgentsAttributes.ContentState
    var body: some View {
        Text(state.headline).font(.caption.weight(.semibold))
            .foregroundStyle(state.blocked > 0 ? .red : .secondary)
            .padding(.trailing, 6)
    }
}

/// The Live Activity in the Apple Watch Smart Stack: the count that matters, and the agent on top.
struct WatchStack: View {
    let state: AgentsAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Mark()
                Text(state.headline).font(.caption.weight(.semibold))
                    .foregroundStyle(state.blocked > 0 ? .red : .primary).lineLimit(1)
            }
            if let top = state.items.first {
                HStack(spacing: 5) {
                    Circle().fill(activityColor(top.state)).frame(width: 6, height: 6)
                    Text(top.title).font(.footnote.weight(.semibold)).lineLimit(1)
                }
                if !top.detail.isEmpty {
                    Text(top.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if state.more + state.items.count > 1 {
                Text("+\(state.more + state.items.count - 1) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Live Activity's main view: the Lock Screen's, or the Watch's in its Smart Stack.
struct ActivityMain: View {
    let state: AgentsAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small: WatchStack(state: state).padding(8)
        default: LockScreen(state: state)
        }
    }
}
