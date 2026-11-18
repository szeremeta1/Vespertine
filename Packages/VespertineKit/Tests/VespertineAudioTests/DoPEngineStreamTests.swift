//
// Vespertine: what a DoP DAC is sent through a pause long enough to let the output go, the resume after it and seeks,
// read back frame by frame from a simulated output: the real engine thread, decoder, ring and render context, no Core
// Audio device and no sound.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("DoP through the engine: pause, release, resume and seek")
struct DoPEngineStreamTests {
    /// A stereo DSF whose DoP frame n carries n itself: the low 16 bits on the left, the high 16 on the right. Every
    /// frame that comes out then says which frame of the file it is.
    static func writeCountingDSF(_ url: URL, dsdRate: Double, frames: Int) throws {
        var reverse = [UInt8](repeating: 0, count: 256)
        for b in 0..<256 {
            var r = 0
            for i in 0..<8 where b & (1 << i) != 0 { r |= 0x80 >> i }
            reverse[b] = UInt8(r)
        }
        let block = 4096, perChannel = frames * 2, blocks = (perChannel + block - 1) / block
        var data = [UInt8](repeating: 0, count: blocks * block * 2)
        data.withUnsafeMutableBufferPointer { out in
            func put(_ i: Int, _ left: UInt8, _ right: UInt8) {
                let at = (i / block) * block * 2 + i % block
                out[at] = reverse[Int(left)]
                out[at + block] = reverse[Int(right)]
            }
            for n in 0..<frames {
                let v = UInt32(n)
                put(2 * n, UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 24))
                put(2 * n + 1, UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 16))
            }
        }
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        var head = Array("DSD ".utf8) + le(UInt64(28)) + le(UInt64(28 + 52 + 12 + data.count)) + le(UInt64(0))
        head += Array("fmt ".utf8) + le(UInt64(52)) + le(UInt32(1)) + le(UInt32(0)) + le(UInt32(2)) + le(UInt32(2))
        head += le(UInt32(dsdRate)) + le(UInt32(1)) + le(UInt64(perChannel * 8)) + le(UInt32(block)) + le(UInt32(0))
        head += Array("data".utf8) + le(UInt64(12 + data.count))
        var file = Data(head)
        file.append(contentsOf: data)
        try file.write(to: url)
    }

    /// The 24-bit word a sample carries (the decoder writes the word over 2^23, exact in a float).
    static func word(_ sample: Float) -> UInt32 { UInt32(bitPattern: Int32((sample * 8_388_608).rounded())) & 0xFF_FFFF }

    /// What one output was sent, read back: whether every frame carried a DoP marker and the markers alternated, and
    /// the stretches of the file it played (each a first frame and a count; idle frames between them are not counted).
    struct Readback {
        var frames = 0
        var badMarkers = 0
        var repeatedMarkers = 0
        var channelsDisagree = 0
        var runs: [(first: Int, count: Int)] = []
    }

    static func read(_ samples: [Float]) -> Readback {
        var result = Readback()
        var last: UInt32?
        var next: Int?
        for f in 0..<samples.count / 2 {
            let l = word(samples[2 * f]), r = word(samples[2 * f + 1])
            let marker = l >> 16
            result.frames += 1
            if marker != 0x05 && marker != 0xFA { result.badMarkers += 1 }
            if r >> 16 != marker { result.channelsDisagree += 1 }
            if marker == last { result.repeatedMarkers += 1 }
            last = marker
            let index = Int((r & 0xFFFF) << 16 | (l & 0xFFFF))
            if index == 0x6969_6969 { continue }   // an idle frame: DSD silence on both channels
            if index == next, !result.runs.isEmpty { result.runs[result.runs.count - 1].count += 1 }
            else { result.runs.append((index, 1)) }
            next = index + 1
        }
        return result
    }

    struct Seen: Sendable {
        var played = false, resumed = false, soughtForward = false, soughtBack = false
        var playedAsDoP = false
        var pausedAt = 0.0
    }

    @Test("Every frame sent carries an alternating marker, and the file's own DSD in order: nothing lost, repeated or out of place",
          arguments: [2_822_400.0, 5_644_800.0])
    func pauseReleaseResumeSeek(dsdRate: Double) async throws {
        let carrier = dsdRate / 16
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dop-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counting.dsf")
        try Self.writeCountingDSF(file, dsdRate: dsdRate, frames: Int(carrier) * 12)

        let device = OutputDevice(id: 4250, uid: "sim-dsd-dac", name: "Simulated DSD DAC", manufacturer: "", modelUID: nil,
                                  transport: .usb, nominalSampleRate: 48_000,
                                  capabilities: DeviceCapabilities(sampleRates: [44_100, 48_000, 176_400, 352_800], physicalFormats: [],
                                                                   outputChannels: 2, supportsDoP: true),
                                  hasHardwareVolume: false, isDefault: true)
        let engine = PlaybackEngine()
        let outputs = Locked<[SimulatedOutput]>([])
        engine.outputListing = { [device] }
        engine.sessionFactory = { _, plan in
            let session = try OutputSession(simulating: plan, rate: plan.deviceSampleRate)
            session.simulated!.captures = true
            outputs.withLock { $0.append(session.simulated!) }
            return session
        }
        var settings = EngineSettings()
        settings.deviceUID = device.uid
        settings.exclusive = true
        settings.dopDeviceUIDs = [device.uid]
        settings.releaseExclusiveAfterPause = 0.3
        engine.update(settings: settings)
        let item = PlayableItem(url: file)

        // On a thread of its own: the waits are short polls, which must not hold one of Swift's few cooperative threads.
        let seen: Seen = await withCheckedContinuation { continuation in
            let thread = Thread {
                func wait(_ timeout: Double = 30, _ condition: (EngineSnapshot) -> Bool) -> Bool {
                    let end = Date().addingTimeInterval(timeout)
                    while Date() < end {
                        if condition(engine.snapshot) { return true }
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    return condition(engine.snapshot)
                }
                var seen = Seen()
                engine.play(item)
                seen.played = wait { $0.state == .playing && $0.position >= 1 }
                seen.playedAsDoP = engine.snapshot.signalPath?.plan.mode == .dop
                // A pause longer than the release setting: the output is let go.
                engine.pause()
                _ = wait { $0.state == .paused }
                seen.pausedAt = engine.snapshot.position
                Thread.sleep(forTimeInterval: 1.5)
                engine.resume()
                seen.resumed = wait { $0.state == .playing && $0.position >= seen.pausedAt + 0.5 }
                engine.seek(to: 8)
                seen.soughtForward = wait { $0.state == .playing && $0.position >= 8.5 }
                engine.pause()
                _ = wait { $0.state == .paused }
                engine.seek(to: 2)
                Thread.sleep(forTimeInterval: 0.3)
                engine.resume()
                seen.soughtBack = wait { $0.state == .playing && $0.position >= 2.5 && $0.position < 7 }
                engine.stopAndWait()
                continuation.resume(returning: seen)
            }
            thread.name = "DoP stream script"
            thread.start()
        }
        #expect(seen.played && seen.resumed && seen.soughtForward && seen.soughtBack, "the script ran through: \(seen)")
        #expect(seen.playedAsDoP)

        let captured = outputs.withLock { $0.map(\.captured) }
        // The pause let the first output go; the resume opened a second.
        try #require(captured.count == 2, "outputs opened: \(captured.count)")
        let first = Self.read(captured[0]), second = Self.read(captured[1])
        for (name, output) in [("before the release", first), ("after it", second)] {
            #expect(output.frames > 0, "\(name)")
            #expect(output.badMarkers == 0, "\(name): frames without a DoP marker")
            #expect(output.channelsDisagree == 0, "\(name): frames whose channels carry different markers")
            #expect(output.repeatedMarkers == 0, "\(name): markers that did not alternate")
        }
        // Before the release: the song from its first frame, in one piece.
        try #require(first.runs.count == 1, "runs before the release: \(first.runs)")
        #expect(first.runs[0].first == 0)
        // After it: on from where the pause left it, then from 8 s, then from 2 s, each in one piece.
        try #require(second.runs.count == 3, "runs after the release: \(second.runs)")
        let heard = first.runs[0].count
        #expect(abs(second.runs[0].first - heard) <= Int(carrier * 0.05), "resumed at frame \(second.runs[0].first), \(heard) were sent before the pause")
        #expect(second.runs[1].first == Int(carrier) * 8)
        #expect(second.runs[2].first == Int(carrier) * 2)
        #expect(second.runs.allSatisfy { $0.count > Int(carrier * 0.3) }, "\(second.runs)")
    }
}
