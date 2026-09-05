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

        ActivityConfiguration(
            for: IntervalTimerAttributes.self
        ) { context in

            VStack(alignment: .leading, spacing: 8) {

                HStack {
                    Text("INTERVAL TIMER")
                        .font(.caption)
                        .fontWeight(.semibold)

                    Spacer()

                    Text(context.state.sectionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                timerText(context.state)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text(context.state.repeatText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

        } dynamicIsland: { context in

            DynamicIsland {

                DynamicIslandExpandedRegion(.leading) {
                    Text("Interval")
                        .font(.caption)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.sectionText)
                        .font(.caption)
                }

                DynamicIslandExpandedRegion(.center) {
                    timerText(context.state)
                        .font(.title2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.repeatText)
                        .font(.caption)
                }

            } compactLeading: {

                Image(systemName: "timer")

            } compactTrailing: {

                compactTimerText(context.state)
                    .monospacedDigit()

            } minimal: {

                Image(systemName: "timer")
            }
        }
    }


    @ViewBuilder
    private func timerText(
        _ state: IntervalTimerAttributes.ContentState
    ) -> some View {

        if state.isPaused {

            Text(
                formatSeconds(
                    state.pausedSeconds ?? 0
                )
            )

        } else {

            Text(
                timerInterval:
                    state.intervalStart...state.intervalEnd,
                countsDown: true
            )
        }
    }


    @ViewBuilder
    private func compactTimerText(
        _ state: IntervalTimerAttributes.ContentState
    ) -> some View {

        if state.isPaused {

            Text(
                shortSeconds(
                    state.pausedSeconds ?? 0
                )
            )

        } else {

            Text(
                timerInterval:
                    state.intervalStart...state.intervalEnd,
                countsDown: true
            )
            .frame(width: 48)
        }
    }


    private func formatSeconds(
        _ seconds: Int
    ) -> String {

        let safe = max(0, seconds)

        return String(
            format: "%02d:%02d",
            safe / 60,
            safe % 60
        )
    }


    private func shortSeconds(
        _ seconds: Int
    ) -> String {

        let safe = max(0, seconds)

        if safe < 60 {
            return "\(safe)s"
        }

        return String(
            format: "%d:%02d",
            safe / 60,
            safe % 60
        )
    }
}
