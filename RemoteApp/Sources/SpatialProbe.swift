//
// Vespertine Remote: the surround probe, started by a launch argument (debug builds only; see LaunchOptions). It makes a
// silent 5.1 file (every sample zero, so nothing can be heard), plays it through the path a surround song takes to iOS's
// Spatial Audio (forced on, whatever the output), and prints what iOS says at each step: the route, its channels, whether
// Spatial Audio is on for it, whether the session says it supplies multichannel content, iOS's rendering mode, the
// renderer's status and whether its clock moves. Then it quits:
//   xcrun devicectl device process launch --console --terminate-existing --device <phone> <bundle id> -VTSpatialProbe YES
// With AirPods connected it shows what Spatial Audio does with the app's audio; on the speaker, that the path works.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if DEBUG
import AVFAudio
import Foundation
import UIKit
import VespertinePhonePlayer
import VespertineRemoteProtocol

@MainActor
enum SpatialProbe {
    static func runIfAsked() async {
        guard let asked = LaunchOptions.spatialProbe, asked.uppercased() == "YES" else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        func say(_ line: String) {
            print("VTSPATIAL \(line)")
            fflush(stdout)
        }
        let rate = 48_000.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-probe-silent-5.1.wav")
        do {
            // 5.1 in WAVE order (L R C LFE Ls Rs), 24-bit, six seconds of digital silence.
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 6,
                                           AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(6 * rate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            try file.write(from: buffer)
        } catch {
            say("FAIL could not make the silent file: \(error.localizedDescription)")
            exit(1)
        }
        say("before: \(PhoneAudioSession.readback())")
        let player = PhonePlayer()
        player.setSurround(spatialMode: .off, systemSpatial: true)
        let labels = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                      kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        let format = StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: 6, channelLabels: labels, lossless: true)
        var failure: String?
        player.onFailure = { failure = $0.localizedDescription }
        do {
            try player.load(url, format: format)
            try player.play()
        } catch {
            say("FAIL could not play: \(error.localizedDescription)")
            exit(1)
        }
        var positions: [Double] = []
        for second in 1...4 {
            try? await Task.sleep(for: .seconds(1))
            player.tick()
            positions.append(player.position)
            let status = player.systemRendererStatus.map { "renderer status=\($0.status) error=\($0.error ?? "none")" } ?? "renderer none"
            say("t=\(second)s path=\(player.rendering) state=\(player.state) position=\(String(format: "%.3f", player.position)) \(status)")
            say("t=\(second)s session: \(PhoneAudioSession.readback())")
        }
        player.halt()
        let moved = (positions.last ?? 0) - (positions.first ?? 0)
        let ok = failure == nil && player.state == .idle && moved > 2.5 && moved < 3.5
        say("clock moved \(String(format: "%.3f", moved)) s in 3 s; failure=\(failure ?? "none")")
        say(ok ? "RESULT PASS: six channels with their layout were handed to iOS and played on its clock" : "RESULT FAIL")
        try? FileManager.default.removeItem(at: url)
        exit(ok ? 0 : 1)
    }
}
#endif
