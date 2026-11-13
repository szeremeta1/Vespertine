//
// Vespertine: the phone's audio session (iOS only): playback category, activation, and a read-back of what iOS gave us. It never
// asks iOS for a sample rate or a buffer size: a Bluetooth link refuses other rates while a microphone is open (the Mac's 1.1.1
// bug), so the app plays at the route's rate and shows it. See docs/plans/ios-spatial-multichannel.md.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if os(iOS)
import AVFAudio
import Foundation

public enum PhoneAudioSession {
    /// What the output route is right now.
    public struct Route: Equatable, Sendable {
        public var outputName: String
        public var portType: String
        /// The session's rate: what iOS runs the route at (the app asked for none).
        public var sampleRate: Double
        public var outputChannels: Int
        /// iOS can spatialize on this route (AirPods with Spatial Audio on).
        public var isSpatialAudioEnabled: Bool
    }

    /// `.playback`, so music plays with the silent switch on and in the background (once the app has the audio background mode).
    public static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    public static func currentRoute() -> Route? {
        let session = AVAudioSession.sharedInstance()
        guard let output = session.currentRoute.outputs.first else { return nil }
        return Route(outputName: output.portName, portType: output.portType.rawValue, sampleRate: session.sampleRate,
                     outputChannels: output.channels?.count ?? 0, isSpatialAudioEnabled: output.isSpatialAudioEnabled)
    }
}
#endif
