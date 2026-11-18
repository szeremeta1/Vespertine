//
// Vespertine: the phone's audio session (iOS only): playback category, activation, and a read-back of what iOS gave us: the
// output, its rate, how many channels it runs with and how many it could. What is asked of an output (a DAC's rate, an
// interface's channels) is decided in PhoneSystemPolicy.swift and asked in PhoneSystem.swift; Bluetooth and the speaker are
// never asked for anything. See docs/plans/ios-spatial-multichannel.md.
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
        /// The most channels the route could run with.
        public var maximumChannels: Int
        /// The speaker of each channel, as the output describes them (often it doesn't).
        public var channelLabels: [UInt32]
        /// iOS's identifier for the output port.
        public var uid: String
    }

    /// `.playback`, so music plays with the silent switch on and in the background (once the app has the audio background mode).
    public static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        // Tells iOS this app supplies multichannel audio (surround songs, handed over whole through a sample buffer
        // renderer): what iOS asks of a "Now Playing" app before it offers Spatial Audio for it.
        if !session.supportsMultichannelContent { try? session.setSupportsMultichannelContent(true) }
        try session.setActive(true)
    }

    /// What iOS says it renders the app's audio as right now (iOS 17.2 and later); nil before.
    public static func renderingMode() -> SystemRenderingMode? {
        guard #available(iOS 17.2, *) else { return nil }
        return SystemRenderingMode(rawValue: AVAudioSession.sharedInstance().renderingMode.rawValue)
    }

    /// Everything iOS says about spatial and multichannel output, as words for a log line (the bench and the probe).
    public static func readback() -> String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map {
            "\($0.portName) [\($0.portType.rawValue)] channels=\($0.channels?.count ?? 0) spatialAudioEnabled=\($0.isSpatialAudioEnabled)"
        }
        var mode = "n/a"
        if #available(iOS 17.2, *) { mode = "\(session.renderingMode.rawValue) (\(renderingMode().map { "\($0)" } ?? "?"))" }
        return "route=\(outputs) sampleRate=\(session.sampleRate) outputNumberOfChannels=\(session.outputNumberOfChannels) "
            + "maximumOutputNumberOfChannels=\(session.maximumOutputNumberOfChannels) supportsMultichannelContent=\(session.supportsMultichannelContent) "
            + "renderingMode=\(mode)"
    }

    public static func currentRoute() -> Route? {
        let session = AVAudioSession.sharedInstance()
        guard let output = session.currentRoute.outputs.first else { return nil }
        return Route(outputName: output.portName, portType: output.portType.rawValue, sampleRate: session.sampleRate,
                     outputChannels: output.channels?.count ?? 0, isSpatialAudioEnabled: output.isSpatialAudioEnabled,
                     maximumChannels: session.maximumOutputNumberOfChannels, channelLabels: output.channels?.map(\.channelLabel) ?? [], uid: output.uid)
    }
}
/// iOS's audio session as the output's state is read from it (`OutputWatch`): one call reads the output, its rate and
/// channels, the volume and the rendering mode.
@MainActor
final class SystemOutputSession: OutputSession {
    func read() -> OutputReading {
        let session = AVAudioSession.sharedInstance()
        let route = PhoneAudioSession.currentRoute().map {
            PhoneRoute(name: $0.outputName, portType: $0.portType, sampleRate: $0.sampleRate, channels: $0.outputChannels, spatial: $0.isSpatialAudioEnabled,
                       maximumChannels: $0.maximumChannels, channelLabels: $0.channelLabels, uid: $0.uid)
        }
        // iOS's volume for the output it names; with no output there is nothing the number would be about.
        return OutputReading(route: route, volume: route == nil ? nil : Double(session.outputVolume), rendering: PhoneAudioSession.renderingMode())
    }

    func ask(rate: Double) { try? AVAudioSession.sharedInstance().setPreferredSampleRate(rate) }

    func ask(channels: Int) { try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(channels) }
}
#endif
