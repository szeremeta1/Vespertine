//
// Vespertine: processed mode: the engine's chain rendered offline, encoded as 24-bit FLAC, sent while it is written.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
import VespertineAudio
@testable import VespertineUPnP

/// The interleaved 24-bit samples of a WAV written by `makeWAV`.
func wavSamples(_ url: URL) throws -> [Int32] {
    let data = try Data(contentsOf: url)
    let body = data.dropFirst(44)
    var out: [Int32] = []
    out.reserveCapacity(body.count / 3)
    var i = body.startIndex
    while i + 2 < body.endIndex {
        let u = UInt32(body[i]) | UInt32(body[i + 1]) << 8 | UInt32(body[i + 2]) << 16
        out.append(Int32(bitPattern: u << 8) >> 8)
        i += 3
    }
    return out
}

func renderAll(_ render: NetworkRender) -> [Int32] {
    var all: [Int32] = []
    while true {
        let chunk = render.next()
        if chunk.isEmpty { return all }
        all += chunk
    }
}

/// A FLAC file's samples as 24-bit values.
func flacSamples(_ url: URL) throws -> [Int32] {
    let decoder = try AudioDecoder(url: url)
    try decoder.open()
    defer { try? decoder.close() }
    let format = decoder.processingFormat
    let channels = Int(format.channelCount)
    let shift = 32 - Int(format.streamDescription.pointee.mBitsPerChannel)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return [] }
    var out: [Int32] = []
    while true {
        try decoder.decode(into: buffer, length: 4096)
        if buffer.frameLength == 0 { break }
        let n = Int(buffer.frameLength)
        if format.isInterleaved, let words = buffer.int32ChannelData?[0] {
            for i in 0..<(n * channels) { out.append(words[i] >> shift) }
        } else if let planes = buffer.int32ChannelData {
            for f in 0..<n { for c in 0..<channels { out.append(planes[c][f] >> shift) } }
        }
    }
    return out
}

@Suite("Processed stream", .serialized)
struct ProcessedStreamTests {
    @Test("At unity with nothing on, the chain gives back the 24-bit source exactly")
    func unity() throws {
        let wav = try makeWAV(seconds: 0.5, seed: 3)
        let render = try NetworkRender(item: PlayableItem(url: wav), url: wav, equalizer: nil, roomCorrection: nil, digitalVolumeDB: nil)
        #expect(render.format.sampleRate == 48_000)
        #expect(render.format.bitDepth == 24)
        #expect(renderAll(render) == (try wavSamples(wav)))
    }

    @Test("Digital volume scales every sample, within the dither")
    func gain() throws {
        let wav = try makeWAV(seconds: 0.25, seed: 2)
        let render = try NetworkRender(item: PlayableItem(url: wav), url: wav, equalizer: nil, roomCorrection: nil, digitalVolumeDB: -6)
        let out = renderAll(render), source = try wavSamples(wav)
        #expect(out.count == source.count)
        let g = pow(10, -6.0 / 20)
        let worst = zip(out, source).map { abs(Double($0) - Double($1) * g) }.max() ?? 99
        #expect(worst <= 2)
        #expect(out != source)
    }

    @Test("A start position skips that much of the song")
    func startPosition() throws {
        let wav = try makeWAV(seconds: 1, seed: 4)
        let render = try NetworkRender(item: PlayableItem(url: wav), url: wav, equalizer: nil, roomCorrection: nil, digitalVolumeDB: nil, startSeconds: 0.5)
        let out = renderAll(render), source = try wavSamples(wav)
        #expect(out == Array(source.suffix(out.count)))
        #expect(abs(out.count - source.count / 2) <= 2 * 4096)
    }

    @Test("The FLAC written decodes to exactly what the chain rendered")
    func flacExact() async throws {
        let wav = try makeWAV(seconds: 0.5, seed: 5)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString)")
        let maker = ProcessedStreamMaker(directory: directory)
        let (file, format) = try maker.makeStream(item: PlayableItem(url: wav), url: wav, settings: RendererSettings(), startSeconds: 0)
        #expect(format.bitDepth == 24)
        for _ in 0..<500 where !file.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(file.isFinished)
        let head = try FileHandle(forReadingFrom: file.url).read(upToCount: 4)
        #expect(head == Data("fLaC".utf8))
        #expect(try flacSamples(file.url) == (try wavSamples(wav)))
    }

    @Test("With an equalizer on, the renderer gets a FLAC stream and the path says PROCESSED · EQ; turning it off restarts the song as the original")
    func processedPlayback() async throws {
        let fake = try await FakeRenderer(kind: .openHome)
        let media = MediaServer()
        try await media.start()
        defer { media.stop(); fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        let playback = RendererPlayback(renderer: device, transport: try device.makeTransport(), media: media,
                                        processed: ProcessedStreamMaker(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString)")),
                                        pollInterval: 0.05)
        defer { playback.shutdown() }
        let events = EventLog()
        playback.eventHandler = { events.add($0) }
        let wav = try makeWAV(seconds: 0.5, seed: 6)
        let eq = EQPreset(name: "Warm", preampDB: -3, bands: [EQBand(kind: .peak, frequency: 1000, gainDB: 3, q: 1)])
        playback.update(settings: RendererSettings(equalizer: eq))
        playback.play(PlayableItem(url: wav))
        #expect(await events.wait(for: "started"))
        for _ in 0..<50 where fake.currentURI == nil { try await Task.sleep(for: .milliseconds(20)) }
        let uri = try #require(fake.currentURI, "calls: \(fake.actions) events: \(events.all) state: \(fake.transportState)")
        #expect(uri.hasSuffix(".flac"))
        let bytes = try #require(await fake.fetched(uri))
        #expect(bytes.prefix(4) == Data("fLaC".utf8))
        #expect(playback.snapshot.signalPath?.statusLine == "PROCESSED · EQ")
        #expect(playback.snapshot.signalPath?.renderer?.sentBitDepth == 24)
        playback.update(settings: RendererSettings())
        // The restart empties the playlist for a moment (DeleteAll, then Insert): wait for the new entry, not just for the old to go.
        for _ in 0..<200 where fake.currentURI == uri || fake.currentURI == nil { try await Task.sleep(for: .milliseconds(20)) }
        let original = try #require(fake.currentURI)
        #expect(original != uri)
        #expect(original.hasSuffix(".wav"))
        #expect(await fake.fetched(original) == (try Data(contentsOf: wav)))
        for _ in 0..<100 where playback.snapshot.signalPath?.renderer?.passesThrough != true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(playback.snapshot.signalPath?.statusLine == "BIT-PERFECT · 24/48 SENT")
        #expect(events.all.filter { $0.hasPrefix("started") }.count == 1)   // a restart isn't a new song
    }
}

@Suite("Processed stream housekeeping", .serialized)
struct ProcessedHousekeepingTests {
    @Test("Stopping the media server abandons processed streams and deletes their files")
    func stopDeletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString)")
        let media = MediaServer()
        try await media.start()
        let wav = try makeWAV(seconds: 2, seed: 7)
        let (file, _) = try ProcessedStreamMaker(directory: directory).makeStream(item: PlayableItem(url: wav), url: wav, settings: RendererSettings(), startSeconds: 0)
        _ = try #require(media.register(.growing(file, mime: "audio/flac"), toward: "127.0.0.1"))
        media.stop()
        #expect(file.isAbandoned)
        for _ in 0..<100 where ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).contains(where: { $0.hasSuffix(".flac") }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".flac") }.isEmpty)
    }

    @Test("Dragging the volume restarts the stream once, after the drag, not once per step")
    func debouncedRestart() async throws {
        let fake = try await FakeRenderer(kind: .openHome)
        let media = MediaServer()
        try await media.start()
        defer { media.stop(); fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        let playback = RendererPlayback(renderer: device, transport: try device.makeTransport(), media: media,
                                        processed: ProcessedStreamMaker(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString)")),
                                        pollInterval: 0.05)
        defer { playback.shutdown() }
        let events = EventLog()
        playback.eventHandler = { events.add($0) }
        playback.update(settings: RendererSettings(digitalVolumeDB: -3))
        try await Task.sleep(for: .milliseconds(400))
        playback.play(PlayableItem(url: try makeWAV(seconds: 2, seed: 8)))
        #expect(await events.wait(for: "started"))
        let loadsBefore = fake.actions.filter { $0 == "DeleteAll" }.count
        for step in 1...10 {
            playback.update(settings: RendererSettings(digitalVolumeDB: -3 - Double(step)))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(900))
        #expect(fake.actions.filter { $0 == "DeleteAll" }.count - loadsBefore == 1)
        #expect(playback.snapshot.signalPath?.volume == .digital(dB: -13))
    }
}

/// Records the dispatch queue it is asked on, then makes nothing.
final class QueueRecordingMaker: ProcessedStreamMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    var recorded: [String] { lock.withLock { labels } }
    func makeStream(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval) throws -> (GrowingFile, SourceFormat) {
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.withLock { labels.append(label) }
        throw RendererPlaybackError.unplayable("test")
    }
}

@Suite("Renderer preparation queue")
struct PreparationQueueTests {
    @Test("Opening files and starting encoders happens on a queue of its own, not on Swift's cooperative pool")
    func offThePool() async throws {
        let fake = try await FakeRenderer(kind: .openHome)
        let media = MediaServer()
        try await media.start()
        defer { media.stop(); fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        let maker = QueueRecordingMaker()
        let playback = RendererPlayback(renderer: device, transport: try device.makeTransport(), media: media, processed: maker, pollInterval: 0.05)
        defer { playback.shutdown() }
        playback.update(settings: RendererSettings(digitalVolumeDB: -6))
        let events = EventLog()
        playback.eventHandler = { events.add($0) }
        playback.play(PlayableItem(url: try makeWAV(seconds: 0.2)))
        #expect(await events.wait(for: "failed"))
        #expect(maker.recorded == [RendererPlayback.preparationQueueLabel])
    }
}
