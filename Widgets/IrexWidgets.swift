import ActivityKit
import SwiftUI
import WidgetKit

@main
struct IrexWidgets: WidgetBundle {
    var body: some Widget {
        AgentsLiveActivity()
        AgentsWidget()
    }
}

/// On the lock screen and in the Dynamic Island: what every agent is up to, the ones
/// that need you first. Tapping opens irex at the agent on top.
struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentsAttributes.self) { context in
            ActivityMain(state: context.state)
                .activityBackgroundTint(activityNavy)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(paneURL(context.state.items.first?.block))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Mark().padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedHeadline(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Rows(items: Array(context.state.items.prefix(activityRows))).padding(.horizontal, 6)
                }
            } compactLeading: {
                Mark()
            } compactTrailing: {
                CompactCount(state: context.state)
            } minimal: {
                MinimalDot(state: context.state)
            }
            .widgetURL(paneURL(context.state.items.first?.block))
            .keylineTint(activityTeal)
        }
        .supplementalActivityFamilies([.small])   // its own layout in the Apple Watch Smart Stack
    }
}

