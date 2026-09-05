import UIKit
import Capacitor
import AVFoundation
import ActivityKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        configureAudioSession()

        return true
    }

    private func configureAudioSession() {

        do {

            let session = AVAudioSession.sharedInstance()

            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )

            try session.setActive(true)

        } catch {

            print("Could not configure audio session: \(error)")
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
    }

    func applicationWillTerminate(_ application: UIApplication) {
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {

        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )

        config.delegateClass = SceneDelegate.self

        return config
    }
}


// ============================================================
// NATIVE AUDIO + BACKGROUND WORKOUT TIMER
// ============================================================

@objc(NativeAudioPlugin)
public class NativeAudioPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "NativeAudioPlugin"
    public let jsName = "NativeAudio"

    public let pluginMethods: [CAPPluginMethod] = [

        CAPPluginMethod(
            name: "warningBeep",
            returnType: CAPPluginReturnPromise
        ),

        CAPPluginMethod(
            name: "finalBeep",
            returnType: CAPPluginReturnPromise
        ),

        CAPPluginMethod(
            name: "startWorkout",
            returnType: CAPPluginReturnPromise
        ),

        CAPPluginMethod(
            name: "pauseWorkout",
            returnType: CAPPluginReturnPromise
        ),

        CAPPluginMethod(
            name: "resumeWorkout",
            returnType: CAPPluginReturnPromise
        ),

        CAPPluginMethod(
            name: "stopWorkout",
            returnType: CAPPluginReturnPromise
        ),

        CAPPluginMethod(
            name: "getWorkoutState",
            returnType: CAPPluginReturnPromise
        )
    ]


    // ========================================================
    // AUDIO
    // ========================================================

    private let sampleRate: Double = 44100.0
    private let toneFrequency: Double = 800.0
    private let toneAmplitude: Float = 0.12

    private var beepEngine: AVAudioEngine?
    private var beepPlayer: AVAudioPlayerNode?

    private var workoutEngine: AVAudioEngine?
    private var workoutSource: AVAudioSourceNode?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var lastAnnouncedItemIndex: Int = -1


    // ========================================================
    // WORKOUT STATE
    // ========================================================

    private struct WorkoutItem {
        let duration: Double
        let start: Double
        let sectionText: String
        let repeatText: String
        let sectionCommand: String
        let announceSection: Bool
    }

    private var workoutItems: [WorkoutItem] = []
    private var workoutDurations: [Double] = []
    private var workoutStarts: [Double] = []

    private var liveActivityIndex: Int = -1

    // Stored as Any so the main app can keep iOS 15.0 as its
    // deployment target. ActivityKit's Activity type is only
    // available on newer iOS versions and is cast only inside
    // @available(iOS 16.2, *) methods below.
    private var liveActivityStorage: Any?

    private var workoutFrame: Int64 = 0
    private var workoutTotalFrames: Int64 = 0

    private var workoutRunning = false
    private var workoutPaused = false
    private var workoutFinished = false
    private var finishStopScheduled = false


    public override func load() {

        super.load()

        configureAudioSession()
    }


    private func configureAudioSession() {

        do {

            let session = AVAudioSession.sharedInstance()

            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )

            try session.setActive(true)

        } catch {

            print("NativeAudio session error: \(error)")
        }
    }


    // ========================================================
    // STANDALONE BEEPS
    // ========================================================

    @objc func warningBeep(_ call: CAPPluginCall) {

        playTone(duration: 0.12)

        call.resolve()
    }


    @objc func finalBeep(_ call: CAPPluginCall) {

        playTone(duration: 1.0)

        call.resolve()
    }


    // ========================================================
    // START WORKOUT
    // ========================================================

    @objc func startWorkout(_ call: CAPPluginCall) {

        guard let planString = call.getString("plan") else {

            call.reject("Missing workout plan")

            return
        }


        guard
            let data = planString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            let rawItems = json["items"] as? [[String: Any]]
        else {

            call.reject("Invalid workout plan")

            return
        }


        var parsedItems: [
            (
                duration: Double,
                sectionText: String,
                repeatText: String,
                sectionCommand: String,
                announceSection: Bool
            )
        ] = []


        for rawItem in rawItems {

            guard let number =
                rawItem["duration"] as? NSNumber
            else {
                continue
            }


            let duration =
                max(
                    1.0,
                    number.doubleValue
                )


            let sectionText =
                rawItem["sectionText"] as? String
                ?? "Interwał"


            let repeatText =
                rawItem["repeatText"] as? String
                ?? ""


            let sectionCommand =
                rawItem["sectionCommand"] as? String
                ?? ""

            let announceSection =
                rawItem["announceSection"] as? Bool
                ?? false

            parsedItems.append(
                (
                    duration,
                    sectionText,
                    repeatText,
                    sectionCommand,
                    announceSection
                )
            )
        }


        guard !parsedItems.isEmpty else {

            call.reject("Workout has no intervals")

            return
        }


        stopWorkoutEngine(resetState: true)

        configureAudioSession()


        workoutItems = []
        workoutDurations = []
        workoutStarts = []

        var cursor = 0.0

        for item in parsedItems {

            workoutStarts.append(cursor)
            workoutDurations.append(item.duration)

            workoutItems.append(
                WorkoutItem(
                    duration: item.duration,
                    start: cursor,
                    sectionText: item.sectionText,
                    repeatText: item.repeatText,
                    sectionCommand: item.sectionCommand,
                    announceSection: item.announceSection
                )
            )

            // 1 second hold on zero/final beep.
            cursor += item.duration + 1.0
        }


        workoutFrame = 0
        liveActivityIndex = -1
        lastAnnouncedItemIndex = -1

        workoutTotalFrames =
            Int64(
                (cursor * sampleRate).rounded()
            )

        workoutRunning = true
        workoutPaused = false
        workoutFinished = false
        finishStopScheduled = false


        guard startWorkoutEngine() else {

            workoutRunning = false

            call.reject("Could not start workout audio engine")

            return
        }


        if #available(iOS 16.2, *) {

            Task { @MainActor in
                self.startLiveActivity()
            }
        }


        call.resolve([
            "totalDuration": cursor
        ])
    }


    // ========================================================
    // PAUSE
    // ========================================================

    @objc func pauseWorkout(_ call: CAPPluginCall) {

        guard workoutRunning,
              !workoutFinished
        else {

            call.resolve()

            return
        }


        workoutEngine?.pause()

        workoutPaused = true


        if #available(iOS 16.2, *) {

            Task { @MainActor in
                await self.updateLiveActivity(
                    paused: true
                )
            }
        }


        call.resolve()
    }


    // ========================================================
    // RESUME
    // ========================================================

    @objc func resumeWorkout(_ call: CAPPluginCall) {

        guard workoutRunning,
              workoutPaused,
              !workoutFinished
        else {

            call.resolve()

            return
        }


        configureAudioSession()


        do {

            try workoutEngine?.start()

            workoutPaused = false


            if #available(iOS 16.2, *) {

                Task { @MainActor in
                    await self.updateLiveActivity(
                        paused: false
                    )
                }
            }


            call.resolve()

        } catch {

            call.reject(
                "Could not resume workout: \(error)"
            )
        }
    }


    // ========================================================
    // STOP
    // ========================================================

    @objc func stopWorkout(_ call: CAPPluginCall) {

        if #available(iOS 16.2, *) {

            Task { @MainActor in
                await self.endLiveActivity()
            }
        }


        stopWorkoutEngine(resetState: true)

        call.resolve()
    }


    // ========================================================
    // GET STATE
    // ========================================================

    @objc func getWorkoutState(_ call: CAPPluginCall) {

        let elapsed =
            min(
                Double(workoutFrame) / sampleRate,
                Double(workoutTotalFrames) / sampleRate
            )


        call.resolve([

            "elapsed": elapsed,

            "totalDuration":
                Double(workoutTotalFrames) / sampleRate,

            "running": workoutRunning,

            "paused": workoutPaused,

            "finished": workoutFinished

        ])
    }


    // ========================================================
    // WORKOUT AUDIO ENGINE
    // ========================================================

    private func startWorkoutEngine() -> Bool {

        let engine = AVAudioEngine()


        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {

            return false
        }


        let source = AVAudioSourceNode {

            [weak self]

            _,
            _,
            frameCount,
            audioBufferList

            -> OSStatus in


            guard let self = self else {

                return noErr
            }


            let buffers =
                UnsafeMutableAudioBufferListPointer(
                    audioBufferList
                )


            for frame in 0..<Int(frameCount) {

                let absoluteFrame =
                    self.workoutFrame +
                    Int64(frame)


                var value: Float = 0.0


                if absoluteFrame <
                    self.workoutTotalFrames {

                    let absoluteTime =
                        Double(absoluteFrame) /
                        self.sampleRate


                    value =
                        self.sampleValue(
                            at: absoluteTime
                        )
                }


                for buffer in buffers {

                    guard let data =
                        buffer.mData?
                            .assumingMemoryBound(
                                to: Float.self
                            )
                    else {

                        continue
                    }


                    data[frame] = value
                }
            }


            self.workoutFrame +=
                Int64(frameCount)


            let elapsed =
                Double(self.workoutFrame) /
                self.sampleRate


            let newIndex =
                self.workoutItemIndex(
                    at: elapsed
                )


            if
                newIndex >= 0,
                newIndex != self.liveActivityIndex
            {

                self.liveActivityIndex =
                    newIndex

                if
                    newIndex != self.lastAnnouncedItemIndex,
                    newIndex < self.workoutItems.count
                {
                    let item =
                        self.workoutItems[newIndex]

                    if
                        item.announceSection,
                        !item.sectionCommand
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            .isEmpty
                    {
                        self.lastAnnouncedItemIndex =
                            newIndex

                        let command =
                            item.sectionCommand

                        DispatchQueue.main.async {
                            self.speakSectionCommand(
                                command
                            )
                        }
                    }
                }


                if #available(iOS 16.2, *) {

                    Task { @MainActor in
                        await self.updateLiveActivity(
                            paused: false
                        )
                    }
                }
            }


            if
                self.workoutFrame >=
                    self.workoutTotalFrames,
                !self.finishStopScheduled
            {

                self.finishStopScheduled = true
                self.workoutFinished = true
                self.workoutPaused = false


                DispatchQueue.main.async {

                    guard self.workoutFinished else {
                        return
                    }

                    self.workoutEngine?.stop()

                    self.workoutRunning = false


                    if #available(iOS 16.2, *) {

                        Task { @MainActor in
                            await self.endLiveActivity()
                        }
                    }
                }
            }


            return noErr
        }


        engine.attach(source)


        engine.connect(
            source,
            to: engine.mainMixerNode,
            format: format
        )


        do {

            try engine.start()

            workoutEngine = engine
            workoutSource = source

            return true

        } catch {

            print(
                "Workout audio engine error: \(error)"
            )

            return false
        }
    }


    // ========================================================
    // SPOKEN SECTION COMMAND
    // ========================================================

    @MainActor
    private func speakSectionCommand(
        _ command: String
    ) {
        let text =
            command.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !text.isEmpty else {
            return
        }

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(
                at: .immediate
            )
        }

        let utterance =
            AVSpeechUtterance(
                string: text
            )

        utterance.voice =
            AVSpeechSynthesisVoice(
                language: "pl-PL"
            )

        utterance.rate =
            AVSpeechUtteranceDefaultSpeechRate

        utterance.volume = 1.0

        speechSynthesizer.speak(
            utterance
        )
    }


    // ========================================================
    // CURRENT WORKOUT ITEM
    // ========================================================

    private func workoutItemIndex(
        at elapsed: Double
    ) -> Int {

        guard !workoutItems.isEmpty else {
            return -1
        }


        for index in 0..<workoutItems.count {

            let item =
                workoutItems[index]


            let nextStart =
                index + 1 < workoutItems.count
                ? workoutItems[index + 1].start
                : Double(workoutTotalFrames) /
                    sampleRate


            if
                elapsed >= item.start,
                elapsed < nextStart
            {

                return index
            }
        }


        return workoutItems.count - 1
    }


    private func secondsLeftInCurrentInterval() -> Int {

        let elapsed =
            Double(workoutFrame) /
            sampleRate


        let index =
            workoutItemIndex(
                at: elapsed
            )


        guard
            index >= 0,
            index < workoutItems.count
        else {

            return 0
        }


        let item =
            workoutItems[index]


        let localElapsed =
            max(
                0.0,
                elapsed - item.start
            )


        return max(
            0,
            Int(
                ceil(
                    item.duration -
                    localElapsed
                )
            )
        )
    }


    // ========================================================
    // LIVE ACTIVITY DIAGNOSTICS
    // ========================================================

    @MainActor
    private func showLiveActivityDiagnostic(
        _ message: String
    ) {
        print(
            "LIVE ACTIVITY DIAGNOSTIC: \(message)"
        )
    }


    // ========================================================
    // LIVE ACTIVITY
    // ========================================================

    @available(iOS 16.2, *)
    @MainActor
    private func startLiveActivity() {

        guard ActivityAuthorizationInfo()
            .areActivitiesEnabled
        else {

            showLiveActivityDiagnostic(
                "iOS zgłasza, że Live Activities są wyłączone dla tej aplikacji."
            )

            return
        }


        guard !workoutItems.isEmpty else {

            showLiveActivityDiagnostic(
                "Nie można uruchomić Live Activity: plan treningu jest pusty."
            )

            return
        }


        Task {

            for activity in
                Activity<IntervalTimerAttributes>
                    .activities
            {

                await activity.end(
                    nil,
                    dismissalPolicy:
                        .immediate
                )
            }


            let first =
                workoutItems[0]


            let now = Date()

            let state =
                IntervalTimerAttributes
                    .ContentState(
                        intervalStart: now,
                        intervalEnd:
                            now.addingTimeInterval(
                                first.duration
                            ),
                        pausedSeconds: nil,
                        sectionText:
                            first.sectionText,
                        repeatText:
                            first.repeatText,
                        isPaused: false
                    )


            let content =
                ActivityContent(
                    state: state,
                    staleDate: nil
                )


            let attributes =
                IntervalTimerAttributes(
                    workoutName:
                        "Interval Timer"
                )


            do {

                let activity =
                    try Activity.request(
                        attributes:
                            attributes,
                        content:
                            content,
                        pushType: nil
                    )

                liveActivityStorage =
                    activity

                liveActivityIndex = 0

                let activityCount =
                    Activity<IntervalTimerAttributes>
                        .activities
                        .count

                showLiveActivityDiagnostic(
                    """
                    START OK
                    Activity ID: \(activity.id)
                    Stan: \(String(describing: activity.activityState))
                    Aktywne Live Activities: \(activityCount)

                    Po zamknięciu tego komunikatu zablokuj ekran i sprawdź ekran blokady.
                    """
                )

            } catch {

                showLiveActivityDiagnostic(
                    """
                    START ERROR

                    \(String(describing: error))
                    """
                )
            }
        }
    }


    @available(iOS 16.2, *)
    @MainActor
    private func updateLiveActivity(
        paused: Bool
    ) async {

        guard
            let activity =
                liveActivityStorage
                    as? Activity<IntervalTimerAttributes>,
            !workoutItems.isEmpty
        else {

            return
        }


        let elapsed =
            Double(workoutFrame) /
            sampleRate


        let index =
            workoutItemIndex(
                at: elapsed
            )


        guard
            index >= 0,
            index < workoutItems.count
        else {

            return
        }


        let item =
            workoutItems[index]


        let secondsLeft =
            secondsLeftInCurrentInterval()


        let now =
            Date()


        let state =
            IntervalTimerAttributes
                .ContentState(
                    intervalStart: now,
                    intervalEnd:
                        now.addingTimeInterval(
                            TimeInterval(
                                secondsLeft
                            )
                        ),
                    pausedSeconds:
                        paused
                        ? secondsLeft
                        : nil,
                    sectionText:
                        item.sectionText,
                    repeatText:
                        item.repeatText,
                    isPaused:
                        paused
                )


        let content =
            ActivityContent(
                state: state,
                staleDate: nil
            )


        await activity.update(
            content
        )
    }


    @available(iOS 16.2, *)
    @MainActor
    private func endLiveActivity() async {

        guard let activity =
            liveActivityStorage
                as? Activity<IntervalTimerAttributes>
        else {

            liveActivityStorage = nil
            return
        }


        await activity.end(
            nil,
            dismissalPolicy:
                .immediate
        )


        liveActivityStorage = nil
    }


    // ========================================================
    // SAMPLE GENERATOR
    // ========================================================

    private func sampleValue(
        at absoluteTime: Double
    ) -> Float {

        for index in 0..<workoutDurations.count {

            let start =
                workoutStarts[index]

            let duration =
                workoutDurations[index]


            // Warning beeps at remaining 3, 2, 1.
            for remaining in [3.0, 2.0, 1.0] {

                let beepStart =
                    start +
                    duration -
                    remaining


                // Same behavior as the old JS timer:
                // no beep exactly at interval start.
                if beepStart > start {

                    if let value =
                        toneSample(
                            absoluteTime:
                                absoluteTime,
                            start:
                                beepStart,
                            duration:
                                0.12
                        )
                    {

                        return value
                    }
                }
            }


            // Final 1-second beep at zero.
            let finalStart =
                start + duration


            if let value =
                toneSample(
                    absoluteTime:
                        absoluteTime,
                    start:
                        finalStart,
                    duration:
                        1.0
                )
            {

                return value
            }
        }


        return 0.0
    }


    private func toneSample(
        absoluteTime: Double,
        start: Double,
        duration: Double
    ) -> Float? {

        let localTime =
            absoluteTime - start


        guard
            localTime >= 0,
            localTime < duration
        else {

            return nil
        }


        var envelope: Float = 1.0

        let fadeDuration =
            min(
                0.15,
                duration
            )


        if localTime >
            duration - fadeDuration {

            envelope =
                Float(
                    (duration - localTime) /
                    fadeDuration
                )
        }


        return
            toneAmplitude *
            envelope *
            Float(
                sin(
                    2.0 *
                    Double.pi *
                    toneFrequency *
                    localTime
                )
            )
    }


    // ========================================================
    // RESET ENGINE
    // ========================================================

    private func stopWorkoutEngine(
        resetState: Bool
    ) {

        workoutEngine?.stop()


        if let source = workoutSource {

            workoutEngine?.detach(source)
        }


        workoutSource = nil
        workoutEngine = nil


        if resetState {

            workoutItems = []
            workoutDurations = []
            workoutStarts = []

            liveActivityIndex = -1

            workoutFrame = 0
            workoutTotalFrames = 0

            workoutRunning = false
            workoutPaused = false
            workoutFinished = false
            finishStopScheduled = false
        }
    }


    // ========================================================
    // STANDALONE TONE
    // ========================================================

    private func playTone(
        duration: Double
    ) {

        let frameCount =
            AVAudioFrameCount(
                sampleRate * duration
            )


        guard let format =
            AVAudioFormat(
                standardFormatWithSampleRate:
                    sampleRate,
                channels: 1
            )
        else {

            return
        }


        guard let buffer =
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        else {

            return
        }


        buffer.frameLength =
            frameCount


        guard let data =
            buffer.floatChannelData?[0]
        else {

            return
        }


        for frame in 0..<Int(frameCount) {

            let time =
                Double(frame) /
                sampleRate


            var envelope: Float = 1.0

            let fadeDuration =
                min(
                    0.15,
                    duration
                )


            if time >
                duration - fadeDuration {

                envelope =
                    Float(
                        (duration - time) /
                        fadeDuration
                    )
            }


            data[frame] =
                toneAmplitude *
                envelope *
                Float(
                    sin(
                        2.0 *
                        Double.pi *
                        toneFrequency *
                        time
                    )
                )
        }


        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()


        engine.attach(player)


        engine.connect(
            player,
            to: engine.mainMixerNode,
            format: format
        )


        do {

            try engine.start()


            player.scheduleBuffer(
                buffer,
                at: nil,
                options: []
            )


            player.play()


            beepEngine = engine
            beepPlayer = player

        } catch {

            print(
                "NativeAudio playback error: \(error)"
            )
        }
    }
}


// ============================================================
// CAPACITOR VIEW CONTROLLER
// ============================================================

class MyViewController: CAPBridgeViewController {

    override open func capacitorDidLoad() {

        bridge?.registerPluginInstance(
            NativeAudioPlugin()
        )
    }
}
