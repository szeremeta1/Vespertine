//
// Vespertine: the readers that hand the playback cache a TIDAL stream's bytes, against a CDN on 127.0.0.1: one FLAC file read by
// ranges, and a DASH stream read as the FLAC it remuxes to, with expiring URLs, stalls and dropped connections.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineTidal

private func fileStream(_ url: URL) -> TidalStream {
    TidalStream(kind: .file(url), codec: "flac", sampleRate: 44_100, bitDepth: 16, audioQuality: "LOSSLESS", audioMode: "STEREO",
                fileExtension: "flac")
}

private func dashStream(_ server: FakeHTTPServer, segments: Int, prefix: String = "/dash") -> TidalStream {
    TidalStream(kind: .dash(initialization: server.url("\(prefix)/init.mp4"), segments: (1...segments).map { server.url("\(prefix)/\($0).m4s") }),
                codec: "flac", sampleRate: 96_000, bitDepth: 24, audioQuality: "HI_RES_LOSSLESS", audioMode: "STEREO", fileExtension: "flac")
}

/// Serves the fixture's init and chunks under `prefix`.
private func serveFixture(_ server: FakeHTTPServer, prefix: String = "/dash") throws -> Int {
    server.serve("\(prefix)/init.mp4", try DASHFixture.initSegment())
    let chunks = try DASHFixture.chunks()
    for (index, chunk) in chunks.enumerated() { server.serve("\(prefix)/\(index + 1).m4s", chunk) }
    return chunks.count
}

private let noRenew: @Sendable () throws -> TidalStream = { throw TidalError.unavailable }

/// Reads `reader` start to end in pieces of `piece` bytes.
private func readAll(_ reader: any RemoteCacheReader, piece: Int = 256 << 10) throws -> Data {
    var out = Data()
    while Int64(out.count) < reader.size {
        let part = try reader.read(at: Int64(out.count), count: piece)
        guard !part.isEmpty else { break }
        out += part
    }
    return out
}

@Suite("TIDAL readers")
struct TidalReadersTests {
    // MARK: One file

    @Test("HTTP reader: the size is the file's, random reads are its bytes, and the extension is the stream's")
    func httpRandomReads() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        let file = noise(3 << 20)
        server.serve("/track.flac", file)
        let reader = try TidalHTTPReader(stream: fileStream(server.url("/track.flac")), renew: noRenew)
        #expect(reader.size == Int64(file.count))
        #expect(reader.fileExtension == "flac")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let offset = Int.random(in: 0..<file.count, using: &generator)
            let count = Int.random(in: 1...(300 << 10), using: &generator)
            let expected = file.subdata(in: offset..<min(file.count, offset + count))
            #expect(try reader.read(at: Int64(offset), count: count) == expected)
        }
        #expect(try reader.read(at: Int64(file.count), count: 10).isEmpty)
        // The reads asked for ranges; nothing fetched the whole file.
        #expect(server.requests.allSatisfy { $0.range != nil })
    }

    @Test("HTTP reader: a URL that expires after 1 MiB is renewed once and the bytes still match")
    func httpExpiry() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        let file = noise(3 << 20, seed: 11)
        server.serve("/track.flac", file)
        server.expire("/track.flac", afterBytes: 1 << 20)
        let renewals = Counter()
        let reader = try TidalHTTPReader(stream: fileStream(server.url("/track.flac", token: "first")), renew: {
            fileStream(server.url("/track.flac", token: "renewed-\(renewals.next())"))
        })
        // Three reads of 768 KiB: the first token has served 1.5 MiB when the third is asked, the second has room for it.
        var head = Data()
        for _ in 0..<3 { head += try reader.read(at: Int64(head.count), count: 768 << 10) }
        #expect(head == file.prefix(3 * (768 << 10)))
        #expect(renewals.next() == 1, "renewed once")
        #expect(server.requests.contains { $0.status == 403 })
    }

    @Test("HTTP reader: a stall blocks the read, which returns the right bytes once the CDN answers again")
    func httpStall() async throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        let file = noise(1 << 20, seed: 3)
        server.serve("/track.flac", file)
        let reader = try TidalHTTPReader(stream: fileStream(server.url("/track.flac")), renew: noRenew)
        server.stall(true)
        let result = Locked<Data?>(nil)
        let thread = Thread { let data = try? reader.read(at: 1000, count: 5000); result.mutate { $0 = data } }
        thread.start()
        #expect(await eventually { server.waitingOnStall > 0 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(result.value == nil, "still waiting")
        server.stall(false)
        #expect(await eventually { result.value != nil })
        #expect(result.value == file.subdata(in: 1000..<6000))
    }

    @Test("HTTP reader: a cancelled reader gives up a stalled read at once")
    func httpCancel() async throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        server.serve("/track.flac", noise(1 << 20))
        let reader = try TidalHTTPReader(stream: fileStream(server.url("/track.flac")), renew: noRenew)
        server.stall(true)
        let failed = Locked(false)
        let thread = Thread {
            do { _ = try reader.read(at: 0, count: 100) } catch { failed.mutate { $0 = true } }
        }
        thread.start()
        #expect(await eventually { server.waitingOnStall > 0 })
        reader.cancel()
        #expect(await eventually { failed.value })
        server.stall(false)
    }

    @Test("HTTP reader: a timed-out request is retried after growing waits; a missing file is an HTTP error")
    func httpRetries() async throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        let file = noise(200_000)
        server.serve("/track.flac", file)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 0.3
        let impatient = URLSession(configuration: configuration)
        let waits = Locked<[TimeInterval]>([])
        let reader = try TidalHTTPReader(stream: fileStream(server.url("/track.flac")), renew: noRenew, session: impatient,
                                         retryDelay: { attempt in waits.mutate { $0.append(TidalCDN.retryDelay(attempt)) }; return 0.05 })
        // The CDN says nothing for a second: the read times out (0.3 s) a few times, waiting between tries, then gets its bytes.
        server.stall(true)
        let result = Locked<Data?>(nil)
        Thread { let data = try? reader.read(at: 10, count: 100); result.mutate { $0 = data } }.start()
        try await Task.sleep(for: .seconds(1))
        server.stall(false)
        #expect(await eventually { result.value != nil })
        #expect(result.value == file.subdata(in: 10..<110))
        let recorded = waits.value
        #expect(recorded.count >= 2 && Array(recorded.prefix(2)) == [2, 4], "growing waits: 2 s, 4 s…: \(recorded)")

        #expect(throws: TidalError.http(status: 404, body: "not found")) {
            _ = try TidalHTTPReader(stream: fileStream(server.url("/missing.flac")), renew: noRenew)
        }
    }

    // MARK: DASH

    @Test("DASH reader: the size is header + payloads, a full read decodes to source.flac, a read across a segment boundary matches")
    func dashFixture() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        let count = try serveFixture(server)
        let reader = try DASHFLACReader(stream: dashStream(server, segments: count), renew: noRenew)
        let expected = try DASHFixture.remuxed()
        #expect(reader.size == Int64(expected.count))
        #expect(reader.fileExtension == "flac")
        // Indexing read only the first bytes of each segment.
        let probes = server.requests.filter { $0.path.hasSuffix(".m4s") }
        #expect(probes.count == count && probes.allSatisfy { $0.range == "bytes=0-4095" })

        let all = try readAll(reader, piece: 100_000)
        #expect(all == expected)
        let directory = try DASHFixture.temporaryDirectory("dash-reader"); defer { try? FileManager.default.removeItem(at: directory) }
        let rebuilt = directory.appendingPathComponent("read.flac")
        try all.write(to: rebuilt)
        let source = try DASHFixture.decode(DASHFixture.directory().appendingPathComponent("source.flac"))
        let decoded = try DASHFixture.decode(rebuilt)
        #expect(decoded.frames == source.frames && decoded.bytes == source.bytes)

        // Segment 1's payload ends at header + payload 1: a read on either side of it.
        let header = try DASHFLACLayout.flacHeader(fromInit: DASHFixture.initSegment()).count
        let first = try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: DASHFixture.chunks()[0])).totalPayloadLength
        let boundary = header + first
        #expect(try reader.read(at: Int64(boundary - 5000), count: 10_000) == expected.subdata(in: (boundary - 5000)..<(boundary + 5000)))
        // From the header into the first segment, and past the end.
        #expect(try reader.read(at: 10, count: header + 100) == expected.subdata(in: 10..<(header + 110)))
        #expect(try reader.read(at: Int64(expected.count - 10), count: 100) == expected.suffix(10))
    }

    @Test("DASH reader: a segment whose moof is larger than 4 KiB is still indexed, by asking for more of it")
    func dashLargeMoof() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        server.serve("/dash/init.mp4", try DASHFixture.initSegment())
        let sizes = Array(repeating: 100, count: 1500)   // trun entries alone are 6000 bytes
        let payload = noise(150_000, seed: 5)
        server.serve("/dash/1.m4s", DASHFixture.segment(sizes: sizes, payload: payload))
        let reader = try DASHFLACReader(stream: dashStream(server, segments: 1), renew: noRenew)
        let header = try DASHFLACLayout.flacHeader(fromInit: DASHFixture.initSegment())
        #expect(reader.size == Int64(header.count + payload.count))
        #expect(try readAll(reader) == header + payload)
        #expect(server.requests.filter { $0.path == "/dash/1.m4s" }.count >= 2, "asked again for a longer prefix")
    }

    @Test("DASH reader: a segment of several fragments is indexed to its end; one with bytes no fragment covers is malformed")
    func dashFragments() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        server.serve("/dash/init.mp4", try DASHFixture.initSegment())
        let chunks = try DASHFixture.chunks()
        server.serve("/dash/1.m4s", chunks.reduce(Data(), +))
        let reader = try DASHFLACReader(stream: dashStream(server, segments: 1), renew: noRenew)
        #expect(try readAll(reader) == (try DASHFixture.remuxed()))

        server.serve("/dash/1.m4s", chunks[0] + Data(repeating: 0, count: 64))
        #expect(throws: TidalError.self) { _ = try DASHFLACReader(stream: dashStream(server, segments: 1), renew: noRenew) }
        // A trun sum that doesn't match its mdat.
        server.serve("/dash/1.m4s", DASHFixture.segment(sizes: [100, 100], payload: Data(repeating: 1, count: 300)))
        #expect(throws: TidalError.self) { _ = try DASHFLACReader(stream: dashStream(server, segments: 1), renew: noRenew) }
    }

    @Test("DASH reader: expired segment URLs are renewed and the read continues with the same bytes")
    func dashExpiry() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        let count = try serveFixture(server)
        for index in 1...count { server.expire("/dash/\(index).m4s", afterBytes: 60_000) }
        let renewals = Counter()
        @Sendable func tokened(_ token: String) -> TidalStream {
            TidalStream(kind: .dash(initialization: server.url("/dash/init.mp4"),
                                    segments: (1...count).map { server.url("/dash/\($0).m4s", token: token) }),
                        codec: "flac", sampleRate: 96_000, bitDepth: 24, audioQuality: "HI_RES_LOSSLESS", audioMode: "STEREO", fileExtension: "flac")
        }
        let reader = try DASHFLACReader(stream: tokened("first"), renew: { tokened("renewed-\(renewals.next())") })
        #expect(try readAll(reader, piece: 50_000) == (try DASHFixture.remuxed()))
        #expect(renewals.next() >= 1)
    }

    @Test("DASH reader: the index is built 8 segments at a time at most")
    func dashConcurrency() throws {
        let server = try FakeHTTPServer(); defer { server.stop() }
        server.serve("/dash/init.mp4", try DASHFixture.initSegment())
        let chunk = try DASHFixture.chunks()[0]
        for index in 1...24 { server.serve("/dash/\(index).m4s", chunk) }
        server.throttle(400_000)   // each 4 KiB probe takes about 10 ms, so they overlap
        let reader = try DASHFLACReader(stream: dashStream(server, segments: 24), renew: noRenew)
        #expect(reader.size > 0)
        #expect(server.peakConcurrency <= 8)
        #expect(server.peakConcurrency >= 2)
    }
}
