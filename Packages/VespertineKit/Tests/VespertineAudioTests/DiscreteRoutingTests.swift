//
// Vespertine — a multichannel file on a device with as many outputs and no speaker setup: every channel on an output of
// its own, at the file's level, in the standard order (L R C LFE Ls Rs …), each output named for the speaker it carries.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Discrete multichannel output (no speaker setup)")
struct DiscreteRoutingTests {
    static let labels: [String: AudioChannelLabel] = [
        "L": kAudioChannelLabel_Left, "R": kAudioChannelLabel_Right, "C": kAudioChannelLabel_Center, "LFE": kAudioChannelLabel_LFEScreen,
        "Ls": kAudioChannelLabel_LeftSurround, "Rs": kAudioChannelLabel_RightSurround,
        "Lsd": kAudioChannelLabel_LeftSurroundDirect, "Rsd": kAudioChannelLabel_RightSurroundDirect,
        "Lrs": kAudioChannelLabel_RearSurroundLeft, "Rrs": kAudioChannelLabel_RearSurroundRight, "Cs": kAudioChannelLabel_CenterSurround,
        "Lc": kAudioChannelLabel_LeftCenter, "Rc": kAudioChannelLabel_RightCenter,
        "Ltf": kAudioChannelLabel_VerticalHeightLeft, "Rtf": kAudioChannelLabel_VerticalHeightRight, "-": kAudioChannelLabel_Unused,
    ]

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        /// The decoder's layout, as channel descriptions; nil: none (Core Audio's "unknown" tag for the count).
        let source: [String]?
        /// The decoder's layout as a tag instead (Core Audio reads CAF and WAVE layouts as tags).
        let tag: AudioChannelLayoutTag?
        let channels: Int
        /// The name of each output, and the source channel each carries.
        let outputs: [String]
        let carries: [Int]
        var testDescription: String { name }
        init(_ name: String, _ source: [String]?, tag: AudioChannelLayoutTag? = nil, channels: Int? = nil, outputs: [String], carries: [Int]? = nil) {
            self.name = name
            self.source = source
            self.tag = tag
            self.channels = channels ?? source?.count ?? outputs.count
            self.outputs = outputs
            self.carries = carries ?? Array(0..<outputs.count)
        }
    }

    // The studio evidence run's engine-routing-render failures (2026-10-23), one case per kind, and the layouts that passed.
    static let cases: [Case] = [
        Case("5.1 with no layout (AIFF, legacy WAV, mask 0): was silent", nil, channels: 6, outputs: ["L", "R", "C", "LFE", "Ls", "Rs"]),
        // With no layout, channels are in WAV order (FL FR FC LFE BL BR SL SR, as FFmpeg and SMPTE also write 7.1): the side
        // pair goes to Ls/Rs and the back pair to Lrs/Rrs, like a labelled WAV 7.1.
        Case("7.1 with no layout (AIFF, legacy WAV): was silent", nil, channels: 8, outputs: ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"],
             carries: [0, 1, 2, 3, 6, 7, 4, 5]),
        Case("6.1 with no layout (WAV order FL FR FC LFE BC SL SR)", nil, channels: 7, outputs: ["L", "R", "C", "LFE", "Ls", "Rs", "Cs"],
             carries: [0, 1, 2, 3, 5, 6, 4]),
        Case("5.1 with a 2-speaker mask: C, LFE and surrounds were lost", ["L", "R", "-", "-", "-", "-"], outputs: ["L", "R", "C", "LFE", "Ls", "Rs"]),
        Case("5.1 back pair (CAF WAVE tag): BL/BR were lost", ["L", "R", "C", "LFE", "Lrs", "Rrs"], tag: kAudioChannelLayoutTag_WAVE_5_1_B,
             outputs: ["L", "R", "C", "LFE", "Ls", "Rs"]),
        Case("5.1 back pair (as descriptions)", ["L", "R", "C", "LFE", "Lrs", "Rrs"], outputs: ["L", "R", "C", "LFE", "Ls", "Rs"]),
        Case("2.1: LFE was lost", ["L", "R", "LFE"], outputs: ["L", "R", "LFE"]),
        Case("quad back pair (CAF): surrounds were -3 dB", ["L", "R", "Lrs", "Rrs"], outputs: ["L", "R", "Ls", "Rs"]),
        Case("4.0 LCRS: C and Cs were split over pairs", ["L", "R", "C", "Cs"], outputs: ["L", "R", "C", "Cs"]),
        Case("6.1 (WAVE side pair): sides were -3 dB", ["L", "R", "C", "LFE", "Cs", "Lsd", "Rsd"],
             outputs: ["L", "R", "C", "LFE", "Ls", "Rs", "Cs"], carries: [0, 1, 2, 3, 5, 6, 4]),
        Case("7.1 side + back (WAVE): sides were -3 dB on the back pair", ["L", "R", "C", "LFE", "Ls", "Rs", "Lsd", "Rsd"],
             outputs: ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"], carries: [0, 1, 2, 3, 6, 7, 4, 5]),
        Case("7.1 wide (front centres): whole mix attenuated", ["L", "R", "C", "LFE", "Ls", "Rs", "Lc", "Rc"],
             outputs: ["L", "R", "C", "LFE", "Ls", "Rs", "Lc", "Rc"]),
        Case("7.1 wide-side (Apple AAC/ALAC 8 ch): whole mix attenuated", ["L", "R", "C", "LFE", "Lc", "Rc", "Ls", "Rs"],
             outputs: ["L", "R", "C", "LFE", "Ls", "Rs", "Lc", "Rc"], carries: [0, 1, 2, 3, 6, 7, 4, 5]),
        Case("5.1.2: whole mix attenuated", ["L", "R", "C", "LFE", "Ls", "Rs", "Ltf", "Rtf"],
             outputs: ["L", "R", "C", "LFE", "Ls", "Rs", "Ltf", "Rtf"]),
        Case("AC-3 3/0+LFE: LFE lost, C split", ["L", "C", "R", "LFE"], outputs: ["L", "R", "C", "LFE"], carries: [0, 2, 1, 3]),
        Case("AC-3 2/1+LFE: LFE lost", ["L", "R", "Cs", "LFE"], outputs: ["L", "R", "Cs", "LFE"]),
        Case("AC-3 3/1+LFE: LFE lost, Cs split", ["L", "C", "R", "Cs", "LFE"], outputs: ["L", "R", "C", "Cs", "LFE"], carries: [0, 2, 1, 3, 4]),
        Case("AC-3 2/1: S split", ["L", "R", "Cs"], outputs: ["L", "R", "Cs"]),
        Case("AC-3 3/1: C and S split", ["L", "C", "R", "Cs"], outputs: ["L", "R", "C", "Cs"], carries: [0, 2, 1, 3]),
        Case("5.1 side (WAVE mask 0x60F)", ["L", "R", "C", "LFE", "Lsd", "Rsd"], outputs: ["L", "R", "C", "LFE", "Ls", "Rs"]),
        Case("5.1 (passed)", ["L", "R", "C", "LFE", "Ls", "Rs"], outputs: ["L", "R", "C", "LFE", "Ls", "Rs"]),
        Case("7.1 (passed)", ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"], outputs: ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"]),
    ]

    /// Plays a voice on each source channel in turn through the engine's plan, route layout and converter; returns, per
    /// source channel, the outputs that carry it and at what level, and the outputs' names.
    static func render(_ c: Case) throws -> (heard: [[(output: Int, level: Float)]], names: [String]) {
        let layout = try #require(c.tag.flatMap { AVAudioChannelLayout(layoutTag: $0) }
            ?? c.source.map { $0.map { labels[$0]! } }.flatMap(ChannelLayouts.layout(labels:))
            ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Unknown | AudioChannelLayoutTag(c.channels)))
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let source = SourceFormat(encoding: .pcm, codec: "WAV", sampleRate: 48_000, bitDepth: 24, channels: c.channels,
                                  channelLabels: ChannelLayouts.speakerLabels(layout))
        var plan = FormatPlanner.plan(source: source, device: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [],
                                                                                 outputChannels: c.channels, supportsDoP: false))
        plan.integerSamples = false
        let route = OutputSession.routeLayout(plan: plan, speakers: nil)
        let output = try #require(AudioFormats.float32(sampleRate: 48_000, channels: plan.channels, interleaved: true, layout: route))
        var heard: [[(output: Int, level: Float)]] = []
        for voice in 0..<c.channels {
            let converter = try #require(OutputSession.converter(from: input, to: output, plan: plan))
            let inBuffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1024))
            inBuffer.frameLength = 1024
            for ch in 0..<c.channels { for f in 0..<1024 { inBuffer.floatChannelData![ch][f] = ch == voice ? 0.5 : 0 } }
            let outBuffer = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1024))
            try converter.convert(to: outBuffer, from: inBuffer)
            let n = Int(output.channelCount), frames = Int(outBuffer.frameLength), samples = outBuffer.floatChannelData![0]
            heard.append((0..<n).compactMap { o in
                let level = (0..<frames).map { abs(samples[$0 * n + o]) }.max() ?? 0
                return level > 1e-4 ? (o, level / 0.5) : nil
            })
        }
        return (heard, route?.shortNames ?? [])
    }

    @Test("Every channel reaches an output of its own, at the file's level, named for its speaker", arguments: cases)
    func everyChannelAlone(_ c: Case) throws {
        let (heard, names) = try Self.render(c)
        #expect(names == c.outputs)
        for (output, voice) in c.carries.enumerated() {
            let got = heard[voice]
            #expect(got.count == 1 && got.first?.output == output && abs((got.first?.level ?? 0) - 1) < 1e-4,
                    "source channel \(voice) (\(c.source?[voice] ?? "unlabelled")): \(got.map { "out \($0.output + 1) at \(20 * log10($0.level)) dB" })")
        }
    }
}
