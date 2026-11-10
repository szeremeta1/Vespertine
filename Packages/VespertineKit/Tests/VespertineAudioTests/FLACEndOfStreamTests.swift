//
// Vespertine: a FLAC read through the share cache's input source ends where the file does. It used to search for a frame sync past
// the last byte inside one decode call for ever (a core at 100% per song, and the song never ended).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineGuard
import Darwin
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

/// A cache input source and how many times its block was asked for bytes (a decoder spinning on a file makes reads for ever).
private struct Counted {
    let source: VTCacheInputSource
    let reads: Locked<Int>
}

/// CPU time a thread has used, in seconds, from outside it.
private func cpuSeconds(ofMachThread port: mach_port_t) -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    guard result == KERN_SUCCESS else { return -1 }
    func s(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1e6 }
    return s(info.user_time) + s(info.system_time)
}

@Suite("A FLAC read from the share cache ends at the end of the file")
struct FLACEndOfStreamTests {
    private func flacBytes(seconds: Double = 2) throws -> Data {
        let wav = try writeWAV("eos", rate: 44_100, bits: 16, seconds: seconds) { c, i in
            var x = UInt32(truncatingIfNeeded: i &* 2_654_435_761 &+ c &* 40_503)
            x ^= x >> 13; x = x &* 0x5bd1e995; x ^= x >> 15
            return Float(Int32(bitPattern: x) >> 8) / Float(1 << 23) * 0.5
        }
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = wav.deletingPathExtension().appendingPathExtension("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try AVAudioFile(forReading: wav)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
                                       AVEncoderBitDepthHintKey: 16]
        do {
            let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length))!
            try source.read(into: buffer)
            try out.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    /// A source over `data` that the block ends where `data` does, claiming `claimedLength` (a file longer on the share than what
    /// reached the cache, or a copy that stopped).
    private func source(_ data: Data, claimedLength: Int? = nil) -> Counted {
        let reads = Locked(0)
        let source = VTCacheInputSource(url: URL(fileURLWithPath: "/share/cut.flac"), length: Int64(claimedLength ?? data.count)) { offset, buffer, count in
            reads.withLock { $0 += 1 }
            let from = Int(offset)
            guard from < data.count else { return 0 }
            let n = min(count, data.count - from)
            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: from..<(from + n))
            return n
        }
        return Counted(source: source, reads: reads)
    }

    struct Outcome { var frames = 0; var finished = false; var failed = false; var cpu = -1.0; var reads = 0 }

    /// CPU time the calling thread has used so far, in seconds.
    private static func ownCPU() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    /// Decodes to the end on a thread of its own and gives it `patience` seconds: a decoder that spins never finishes, so the
    /// thread is left to it (it is stopped with the test process) and its CPU time is what it used in that time.
    private func decodeToEnd(_ src: Counted, patience: TimeInterval = 3) throws -> Outcome {
        let decoder = try AudioDecoder(inputSource: src.source)
        try decoder.open()
        let box = Locked(Outcome())
        let port = Locked<mach_port_t>(0)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            port.withLock { $0 = mach_thread_self() }
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
            var frames = 0
            do {
                while true {
                    try decoder.decode(into: buffer, length: 4096)
                    if buffer.frameLength == 0 { break }
                    frames += Int(buffer.frameLength)
                }
            } catch { box.withLock { $0.failed = true } }
            let own = Self.ownCPU()
            box.withLock { $0.frames = frames; $0.finished = true; $0.cpu = own }
            done.signal()
        }
        thread.start()
        _ = done.wait(timeout: .now() + patience)
        var outcome = box.withLock { $0 }
        let p = port.withLock { $0 }
        // A thread that finished reported its own CPU time; one still going (a spin) is read from outside.
        if !outcome.finished { outcome.cpu = p == 0 ? -1 : cpuSeconds(ofMachThread: p) }
        outcome.reads = src.reads.withLock { $0 }
        return outcome
    }

    @Test("An input source over a whole file reports the end of it")
    func atEOF() throws {
        let data = Data(repeating: 7, count: 10_000)
        let src = source(data).source
        try src.open()
        #expect(!src.atEOF)
        var buffer = [UInt8](repeating: 0, count: 6_000)
        var got = 0
        try src.__readBytes(&buffer, length: 6_000, bytesRead: &got)
        #expect(got == 6_000 && !src.atEOF)
        try src.__readBytes(&buffer, length: 6_000, bytesRead: &got)
        #expect(got == 4_000)
        #expect(src.atEOF)
    }

    @Test("A source whose block ends before the length it claimed ends there, and a seek back reads on")
    func endsEarly() throws {
        let src = source(Data(repeating: 9, count: 5_000), claimedLength: 20_000).source
        try src.open()
        var buffer = [UInt8](repeating: 0, count: 8_000)
        var got = 0
        try src.__readBytes(&buffer, length: 8_000, bytesRead: &got)
        #expect(got == 5_000)
        try src.__readBytes(&buffer, length: 8_000, bytesRead: &got)
        #expect(got == 0)
        #expect(src.atEOF)
        try src.seek(toOffset: 100)
        #expect(!src.atEOF)
        try src.__readBytes(&buffer, length: 8_000, bytesRead: &got)
        #expect(got == 4_900)
    }

    @Test("A whole FLAC decodes to its last frame and stops, in a bounded number of reads")
    func wholeFile() throws {
        let data = try flacBytes()
        let result = try decodeToEnd(source(data))
        print("whole file: \(result)")
        #expect(result.finished && !result.failed)
        #expect(result.frames == 88_200)
        #expect(result.reads < data.count / 1024 + 200)
        #expect(result.cpu >= 0 && result.cpu < 1.0)
    }

    @Test("A FLAC cut short stops at the cut instead of searching past it for ever")
    func truncated() throws {
        let data = try flacBytes()
        let cut = data.prefix(data.count / 2)
        let result = try decodeToEnd(source(Data(cut)))
        print("truncated: \(result)")
        #expect(result.finished)
        #expect(result.frames > 0 && result.frames < 88_200)
        #expect(result.reads < data.count / 1024 + 200)
        #expect(result.cpu >= 0 && result.cpu < 1.0)
    }

    @Test("A FLAC whose share file is longer than what the cache could read stops where the reads did")
    func claimedLonger() throws {
        let data = try flacBytes()
        let cut = Data(data.prefix(data.count * 2 / 3))
        let result = try decodeToEnd(source(cut, claimedLength: data.count))
        print("claimed longer: \(result)")
        #expect(result.finished)
        #expect(result.reads < data.count / 1024 + 200)
        #expect(result.cpu >= 0 && result.cpu < 1.0)
    }

    @Test("The read-ahead decoder of a cut FLAC ends, so the engine moves on to the next song")
    func readAheadEnds() throws {
        let data = try flacBytes()
        let decoder = try AudioDecoder(inputSource: source(Data(data.prefix(data.count / 2))).source)
        try decoder.open()
        let ahead = ReadAheadDecoder(GuardedDecoder(decoder), seconds: 0.5)
        let buffer = AVAudioPCMBuffer(pcmFormat: ahead.processingFormat, frameCapacity: 4096)!
        let giveUp = Date().addingTimeInterval(5)
        var ended = false
        while Date() < giveUp {
            do {
                try ahead.decode(into: buffer, length: 4096)
                if buffer.frameLength == 0 { ended = true; break }
            } catch is ReadAheadDecoder.Starved {
                ahead.waitForAudio(timeout: 0.05)
            } catch { ended = true; break }
        }
        #expect(ended)
        #expect(ahead.hasEnded)
    }
}
