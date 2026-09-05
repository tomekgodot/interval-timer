import ActivityKit
import WidgetKit
import SwiftUI

@main
struct IntervalTimerLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        IntervalTimerLiveActivity()
    }
}

struct IntervalTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IntervalTimerAttributes.self) { context in
            VStack(spacing: 8) {
                Text("INTERVAL TIMER")
                    .font(.caption)
                    .fontWeight(.semibold)

                Text("LIVE ACTIVITY WORKS")
                    .font(.title2)
                    .fontWeight(.bold)

                Text(context.state.sectionText)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("LIVE ACTIVITY WORKS")
                        .fontWeight(.bold)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.sectionText)
                        .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                Text("OK")
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }
}
