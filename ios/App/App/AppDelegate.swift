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

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: []
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Could not configure audio session: \(error)")
        }

        return true
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
@objc(NativeAudioPlugin)
public class NativeAudioPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "NativeAudioPlugin"
    public let jsName = "NativeAudio"

    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "warningBeep", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finalBeep", returnType: CAPPluginReturnPromise)
    ]

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    public override func load() {
        super.load()

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

    @objc func warningBeep(_ call: CAPPluginCall) {
        playTone(duration: 0.12)
        call.resolve()
    }

    @objc func finalBeep(_ call: CAPPluginCall) {
        playTone(duration: 1.0)
        call.resolve()
    }

    private func playTone(duration: Double) {

        let sampleRate = 44100.0
        let frequency = 800.0
        let amplitude: Float = 0.12

        let frameCount = AVAudioFrameCount(
            sampleRate * duration
        )

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            return
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            return
        }

        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData?[0] else {
            return
        }

        for frame in 0..<Int(frameCount) {

            let time = Double(frame) / sampleRate

            var envelope: Float = 1.0

            let fadeDuration = min(0.15, duration)

            if time > duration - fadeDuration {
                envelope = Float(
                    (duration - time) / fadeDuration
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

            self.audioEngine = engine
            self.playerNode = player

        } catch {
            print("NativeAudio playback error: \(error)")
        }
    }
}
class MyViewController: CAPBridgeViewController {

    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(
            NativeAudioPlugin()
        )
    }
}