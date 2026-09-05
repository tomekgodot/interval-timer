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

            print(
                "Could not configure audio session: \(error)"
            )

        }
    }

    func applicationWillResignActive(
        _ application: UIApplication
    ) {
    }

    func applicationDidEnterBackground(
        _ application: UIApplication
    ) {
    }

    func applicationWillEnterForeground(
        _ application: UIApplication
    ) {
    }

    func applicationDidBecomeActive(
        _ application: UIApplication
    ) {
    }

    func applicationWillTerminate(
        _ application: UIApplication
    ) {
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
// NATIVE AUDIO PLUGIN
// ============================================================

@objc(NativeAudioPlugin)
public class NativeAudioPlugin:
    CAPPlugin,
    CAPBridgedPlugin
{

    public let identifier =
        "NativeAudioPlugin"

    public let jsName =
        "NativeAudio"

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
            name: "backgroundTest",
            returnType: CAPPluginReturnPromise
        ),

        CAPPluginMethod(
            name: "stopBackgroundTest",
            returnType: CAPPluginReturnPromise
        )
    ]


    // ========================================================
    // ZWYKŁE BIPY
    // ========================================================

    private var beepEngine: AVAudioEngine?
    private var beepPlayer: AVAudioPlayerNode?


    // ========================================================
    // BACKGROUND TEST
    // ========================================================

    private var backgroundEngine: AVAudioEngine?

    private var backgroundSource:
        AVAudioSourceNode?

    private var backgroundFrame:
        Int64 = 0

    private let sampleRate:
        Double = 44100.0


    public override func load() {

        super.load()

        configureAudioSession()
    }


    private func configureAudioSession() {

        do {

            let session =
                AVAudioSession.sharedInstance()

            try session.setCategory(
                .playback,
                mode: .default,
                options: []
            )

            try session.setActive(true)

        } catch {

            print(
                "NativeAudio session error: \(error)"
            )

        }
    }


    // ========================================================
    // WARNING BEEP
    // ========================================================

    @objc func warningBeep(
        _ call: CAPPluginCall
    ) {

        playTone(
            duration: 0.12
        )

        call.resolve()
    }


    // ========================================================
    // FINAL BEEP
    // ========================================================

    @objc func finalBeep(
        _ call: CAPPluginCall
    ) {

        playTone(
            duration: 1.0
        )

        call.resolve()
    }


    // ========================================================
    // TEST 10 SEKUND W TLE
    //
    // 7 s  -> krótki beep
    // 8 s  -> krótki beep
    // 9 s  -> krótki beep
    // 10 s -> długi beep
    // ========================================================

    @objc func backgroundTest(
        _ call: CAPPluginCall
    ) {

        stopBackgroundAudio()

        configureAudioSession()

        backgroundFrame = 0


        let engine =
            AVAudioEngine()


        guard let format =
            AVAudioFormat(
                standardFormatWithSampleRate:
                    sampleRate,
                channels: 1
            )
        else {

            call.reject(
                "Could not create audio format"
            )

            return
        }


        let warningLength =
            Int64(
                sampleRate * 0.12
            )

        let finalLength =
            Int64(
                sampleRate * 1.0
            )


        let beep7 =
            Int64(sampleRate * 7.0)

        let beep8 =
            Int64(sampleRate * 8.0)

        let beep9 =
            Int64(sampleRate * 9.0)

        let finalStart =
            Int64(sampleRate * 10.0)


        let frequency =
            800.0

        let amplitude:
            Float = 0.12


        let source =
            AVAudioSourceNode {

                [weak self]

                _,
                _,
                frameCount,
                audioBufferList

                -> OSStatus in


                guard let self = self
                else {
                    return noErr
                }


                let ablPointer =
                    UnsafeMutableAudioBufferListPointer(
                        audioBufferList
                    )


                for frame in
                    0..<Int(frameCount)
                {

                    let absoluteFrame =
                        self.backgroundFrame
                        +
                        Int64(frame)


                    var value:
                        Float = 0.0


                    // ----------------------------
                    // WARNING BEEP @ 7
                    // ----------------------------

                    if absoluteFrame >= beep7 &&
                       absoluteFrame <
                            beep7 + warningLength {

                        let localFrame =
                            absoluteFrame - beep7

                        let time =
                            Double(localFrame)
                            /
                            self.sampleRate

                        value =
                            amplitude *
                            Float(
                                sin(
                                    2.0 *
                                    Double.pi *
                                    frequency *
                                    time
                                )
                            )
                    }


                    // ----------------------------
                    // WARNING BEEP @ 8
                    // ----------------------------

                    if absoluteFrame >= beep8 &&
                       absoluteFrame <
                            beep8 + warningLength {

                        let localFrame =
                            absoluteFrame - beep8

                        let time =
                            Double(localFrame)
                            /
                            self.sampleRate

                        value =
                            amplitude *
                            Float(
                                sin(
                                    2.0 *
                                    Double.pi *
                                    frequency *
                                    time
                                )
                            )
                    }


                    // ----------------------------
                    // WARNING BEEP @ 9
                    // ----------------------------

                    if absoluteFrame >= beep9 &&
                       absoluteFrame <
                            beep9 + warningLength {

                        let localFrame =
                            absoluteFrame - beep9

                        let time =
                            Double(localFrame)
                            /
                            self.sampleRate

                        value =
                            amplitude *
                            Float(
                                sin(
                                    2.0 *
                                    Double.pi *
                                    frequency *
                                    time
                                )
                            )
                    }


                    // ----------------------------
                    // FINAL BEEP @ 10
                    // ----------------------------

                    if absoluteFrame >= finalStart &&
                       absoluteFrame <
                            finalStart + finalLength {

                        let localFrame =
                            absoluteFrame - finalStart

                        let time =
                            Double(localFrame)
                            /
                            self.sampleRate


                        var envelope:
                            Float = 1.0


                        let fadeFrames =
                            Int64(
                                self.sampleRate * 0.15
                            )


                        if localFrame >
                            finalLength - fadeFrames {

                            envelope =
                                Float(
                                    finalLength -
                                    localFrame
                                )
                                /
                                Float(
                                    fadeFrames
                                )
                        }


                        value =
                            amplitude *
                            envelope *
                            Float(
                                sin(
                                    2.0 *
                                    Double.pi *
                                    frequency *
                                    time
                                )
                            )
                    }


                    for buffer
                        in ablPointer {

                        guard let data =
                            buffer
                                .mData?
                                .assumingMemoryBound(
                                    to: Float.self
                                )
                        else {
                            continue
                        }

                        data[frame] =
                            value
                    }
                }


                self.backgroundFrame +=
                    Int64(frameCount)


                return noErr
            }


        engine.attach(
            source
        )


        engine.connect(
            source,
            to: engine.mainMixerNode,
            format: format
        )


        do {

            try engine.start()

            backgroundEngine =
                engine

            backgroundSource =
                source

            call.resolve()

        } catch {

            print(
                "Background engine error: \(error)"
            )

            call.reject(
                "Could not start background audio"
            )
        }
    }


    // ========================================================
    // STOP TESTU
    // ========================================================

    @objc func stopBackgroundTest(
        _ call: CAPPluginCall
    ) {

        stopBackgroundAudio()

        call.resolve()
    }


    private func stopBackgroundAudio() {

        backgroundEngine?.stop()

        if let source =
            backgroundSource {

            backgroundEngine?
                .detach(source)
        }

        backgroundSource = nil

        backgroundEngine = nil

        backgroundFrame = 0
    }


    // ========================================================
    // ZWYKŁY GENERATOR BIPU
    // ========================================================

    private func playTone(
        duration: Double
    ) {

        let sampleRate =
            44100.0

        let frequency =
            800.0

        let amplitude:
            Float = 0.12


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


        for frame in
            0..<Int(frameCount)
        {

            let time =
                Double(frame)
                /
                sampleRate


            var envelope:
                Float = 1.0


            let fadeDuration =
                min(
                    0.15,
                    duration
                )


            if time >
                duration - fadeDuration {

                envelope =
                    Float(
                        (duration - time)
                        /
                        fadeDuration
                    )
            }


            data[frame] =
                amplitude *
                envelope *
                Float(
                    sin(
                        2.0 *
                        Double.pi *
                        frequency *
                        time
                    )
                )
        }


        let engine =
            AVAudioEngine()

        let player =
            AVAudioPlayerNode()


        engine.attach(
            player
        )


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


            beepEngine =
                engine

            beepPlayer =
                player

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

class MyViewController:
    CAPBridgeViewController
{

    override open func capacitorDidLoad() {

        bridge?.registerPluginInstance(
            NativeAudioPlugin()
        )
    }
}