//
// Speaker probe — what the system says about the current audio output.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation

enum RouteReport {
    #if os(tvOS)
    /// Asks for as many output channels as the route offers. Call once at launch and again after a route change.
    static func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setSupportsMultichannelContent(true)
        try session.setActive(true)
        if session.maximumOutputNumberOfChannels > session.outputNumberOfChannels {
            try session.setPreferredOutputNumberOfChannels(session.maximumOutputNumberOfChannels)
        }
    }

    static func current() -> String {
        let session = AVAudioSession.sharedInstance()
        var lines = [
            "Output channels: \(session.outputNumberOfChannels) (route maximum \(session.maximumOutputNumberOfChannels))",
            "Session sample rate: \(Int(session.sampleRate)) Hz",
            "Rendering mode: \(name(of: session.renderingMode))",
            "Supports multichannel content: \(session.supportsMultichannelContent ? "yes" : "no")",
        ]
        for port in session.currentRoute.outputs {
            lines.append("Output: \(port.portName) [\(port.portType.rawValue)]")
            let channels = (port.channels ?? []).map { "\($0.channelNumber): \($0.channelName) (label \($0.channelLabel))" }
            lines.append(contentsOf: channels.map { "  " + $0 })
        }
        return lines.joined(separator: "\n")
    }

    private static func name(of mode: AVAudioSession.RenderingMode) -> String {
        switch mode {
        case .notApplicable: "not applicable"
        case .monoStereo: "mono / stereo"
        case .surround: "surround"
        case .spatialAudio: "spatial audio"
        case .dolbyAudio: "Dolby audio"
        case .dolbyAtmos: "Dolby Atmos"
        @unknown default: "unknown (\(mode.rawValue))"
        }
    }
    #else
    static func prepareSession() throws {}

    static func current() -> String {
        """
        On a Mac the receiver is what reports the format.
        Pick the Shairport Sync receiver with the AirPlay button,
        play each signal and note the stream type and format in its log.
        """
    }
    #endif
}
