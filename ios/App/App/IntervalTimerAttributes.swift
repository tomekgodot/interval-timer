import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct IntervalTimerAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        var intervalStart: Date
        var intervalEnd: Date
        var pausedSeconds: Int?
        var sectionText: String
        var repeatText: String
        var isPaused: Bool
    }

    var workoutName: String
}
