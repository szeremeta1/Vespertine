//
// Vespertine — the studio evidence run's per-file device configuration check (verification/studio/). For each listed
// file: the plan the engine would make for this output (FormatPlanner with the engine's default settings), then the
// engine's own configuration step (exclusive access, DeviceControl.apply: rate, physical format), then what Core Audio
// reports for the device, read here straight from the HAL. No I/O is started and no audio is played: this is the
// half of OutputSession before its IOProc (which a process without Microphone permission can't create on a device
// that also has inputs, such as a loopback). Virtual devices only, and the device is left at the rate it was found at.
// Runs when VESPERTINE_STUDIO_CONFIG=<file with one path per line>, VESPERTINE_STUDIO_CONFIG_DEVICE=<name or UID> and
// VESPERTINE_STUDIO_CONFIG_OUT=<jsonl> are set.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Studio device configuration (opt-in)", .serialized)
struct StudioDeviceConfigTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["VESPERTINE_STUDIO_CONFIG"] != nil && env["VESPERTINE_STUDIO_CONFIG_DEVICE"] != nil
        && env["VESPERTINE_STUDIO_CONFIG_OUT"] != nil

    /// Core Audio's report for the device's output: nominal rate, every output stream's physical and virtual format, hog owner.
    static func readback(_ id: AudioObjectID) -> [String: Any] {
        let rate = (try? HAL.get(id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
        let streams = DeviceQuery.outputStreams(id)
        var physicalChannels = 0, virtualChannels = 0, bits: [Int] = [], integer = true
        for s in streams {
            if let p = try? HAL.get(s, .global(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription()) {
                physicalChannels += Int(p.mChannelsPerFrame); bits.append(Int(p.mBitsPerChannel))
                if p.mFormatFlags & kAudioFormatFlagIsFloat != 0 { integer = false }
            }
            if let v = try? HAL.get(s, .global(kAudioStreamPropertyVirtualFormat), initial: AudioStreamBasicDescription()) {
                virtualChannels += Int(v.mChannelsPerFrame)
            }
        }
        return ["rate": rate, "channels": virtualChannels, "physical_channels": physicalChannels, "bits": bits.min() ?? 0,
                "integer": integer, "streams": streams.count, "hog_pid": Int(DeviceControl.hogOwner(id))]
    }

    static func planRow(_ p: OutputPlan) -> [String: Any] {
        ["mode": p.mode.rawValue, "rate": p.deviceSampleRate, "decoded_rate": p.decodedSampleRate, "bits": p.physicalBitDepth,
         "channels": p.channels, "device_channels": p.deviceChannels, "resamples": p.resamples, "dsd_to_pcm": p.dsdConvertedToPCM,
         "spatial": p.spatial.rawValue, "reason": p.reason]
    }

    @Test(.enabled(if: enabled))
    func configureForEveryFile() throws {
        let name = Self.env["VESPERTINE_STUDIO_CONFIG_DEVICE"]!
        let device = try #require(OutputDevices.list().first { $0.uid == name || $0.name == name }, "no output device named \(name)")
        try #require(device.transport == .virtual, "\(device.name) is not a virtual device: refused")
        let paths = try String(contentsOfFile: Self.env["VESPERTINE_STUDIO_CONFIG"]!, encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let found = (try? HAL.get(device.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
        defer { if found > 0 { try? HAL.set(device.id, .global(kAudioDevicePropertyNominalSampleRate), found) } }
        var lines: [String] = []
        for path in paths {
            var row: [String: Any] = ["file": path, "pid": Int(getpid()), "device": device.name, "device_uid": device.uid,
                                      "transport": device.transport.rawValue, "exclusive_requested": true, "stage": "configuration"]
            do {
                let probed = try SourceOpener.probe(URL(fileURLWithPath: path))
                let f = probed.format
                row["source"] = ["codec": f.codec, "channels": f.channels, "rate": f.sampleRate, "bits": f.bitDepth.map { $0 as Any } ?? NSNull(),
                                 "encoding": f.encoding.rawValue, "description": f.shortDescription, "decoder": probed.decoderName]
                if f.codec == DolbyAtmos.codecName {
                    row["error"] = "system-rendered Atmos: macOS renders it, not FormatPlanner (not checked here)"
                } else {
                    // The engine's plan with its default settings: match the source rate, no spatial, no bitstream, no DoP,
                    // no integer mode, 16-bit matching off.
                    let plan = FormatPlanner.plan(source: f, device: device.capabilities, policy: .matchSource, spatial: .off, bitstream: false)
                    row["computed"] = Self.planRow(plan)
                    let hogged = DeviceControl.acquireHog(device.id)
                    defer { if hogged { DeviceControl.releaseHog(device.id) } }
                    do { try DeviceControl.apply(plan: plan, to: device.id) } catch { row["apply_error"] = "\(error)" }
                    row["hogged"] = hogged
                    row["readback"] = Self.readback(device.id)
                }
            } catch {
                row["error"] = "probe: \(error.localizedDescription)"
            }
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: Self.env["VESPERTINE_STUDIO_CONFIG_OUT"]!, atomically: true, encoding: .utf8)
        print("studio device configuration: \(paths.count) files on \(device.name)")
        #expect(!paths.isEmpty)
    }
}
