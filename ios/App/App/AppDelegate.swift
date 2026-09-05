import UIKit
import Capacitor
import AVFoundation

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
                options: []
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


    // ========================================================
    // WORKOUT STATE
    // ========================================================

    private var workoutDurations: [Double] = []
    private var workoutStarts: [Double] = []

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
                options: []
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
            let rawDurations = json["durations"] as? [Any]
        else {

            call.reject("Invalid workout plan")

            return
        }


        let durations: [Double] = rawDurations.compactMap {

            if let number = $0 as? NSNumber {
                return max(1.0, number.doubleValue)
            }

            if let string = $0 as? String,
               let number = Double(string) {

                return max(1.0, number)
            }

            return nil
        }


        guard !durations.isEmpty else {

            call.reject("Workout has no intervals")

            return
        }


        stopWorkoutEngine(resetState: true)

        configureAudioSession()


        workoutDurations = durations
        workoutStarts = []

        var cursor = 0.0

        for duration in durations {

            workoutStarts.append(cursor)

            // 1 second hold on zero/final beep.
            cursor += duration + 1.0
        }


        workoutFrame = 0

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

            workoutDurations = []
            workoutStarts = []

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
