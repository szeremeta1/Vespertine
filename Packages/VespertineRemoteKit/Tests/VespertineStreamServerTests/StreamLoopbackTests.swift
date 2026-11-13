//
// Vespertine: the stream channel over the real transport, on loopback: TLS with a pre-shared key, the length framing, the
// phone's session on one end and the Mac's stream handler on the other. Reads come back as binary frames, matched by id.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network)
import Foundation
import Network
import Testing
import VespertineRemoteClient
@testable import VespertineRemoteProtocol
@testable import VespertineStreamServer

private struct FlacMaker: StreamTranscoding {
    static let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
    func transcode(_ request: TranscodeRequest, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> TranscodeResult {
        try Self.bytes.write(to: destination)
        let labels: [UInt32] = [1, 2, 3, 4, 5, 6]
        return TranscodeResult(format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: request.sampleRate, bitDepth: request.bitDepth,
                                                    channels: request.channels, channelLabels: labels, lossless: true), frames: 441_000)
    }
}

/// A Mac that welcomes a phone at the version its hello negotiates, and serves stream commands from a real `StreamPreparer`.
private final class StreamMac: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "stream-loopback.server")
    let info = ServerInfo(name: "Test Mac", serverID: "S-TEST", appVersion: "1.2.0")

    init(key: RemoteTransport.PresharedKey, preparer: StreamPreparer, allowed: Bool = true) throws {
        listener = try NWListener(using: RemoteTransport.parameters(keys: [key]), on: .any)
        listener.newConnectionHandler = { [queue, info] connection in
            connection.start(queue: queue)
            let version = VersionBox()
            func send(_ data: Data) {
                connection.send(content: data, contentContext: RemoteTransport.textContext, isComplete: true, completion: .contentProcessed { _ in })
            }
            func receive() {
                connection.receiveMessage { content, _, _, error in
                    guard error == nil, let content, let message = try? RemoteProtocol.decoder().decode(ClientMessage.self, from: content) else {
                        connection.cancel(); return
                    }
                    if case .hello(_, _, let baseline, let highest) = message.command {
                        let negotiated = RemoteProtocol.negotiate(baseline: baseline, highest: highest) ?? 1
                        version.value = negotiated
                        var served = info
                        served.protocolVersion = negotiated
                        send(try! RemoteProtocol.encoder().encode(ServerMessage.reply(id: message.id, result: .welcome(served))))
                    } else if StreamPreparer.isStreamCommand(message.command) {
                        Task {
                            switch await preparer.handle(message.command, id: message.id, client: "phone", protocolVersion: version.value, allowed: allowed) {
                            case .reply(let reply)?: send(try! RemoteProtocol.encoder().encode(ServerMessage.reply(id: message.id, result: reply)))
                            case .frame(let frame)?: send(frame.encoded())
                            case nil: break
                            }
                        }
                    } else {
                        send(try! RemoteProtocol.encoder().encode(ServerMessage.reply(id: message.id, result: .ok)))
                    }
                    receive()
                }
            }
            receive()
        }
    }

    final class VersionBox: @unchecked Sendable { var value = 1 }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
            let once = OnceBox()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port!) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }
}

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) { let go = lock.withLock { () -> Bool in defer { done = true }; return !done }; if go { body() } }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(30))
    }
    return condition()
}

private struct Rig {
    let dir: URL
    let mac: StreamMac
    let session: RemoteSession
    let original: Data

    @MainActor
    static func make(allowed: Bool = true) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stream-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let flac = dir.appendingPathComponent("a.flac")
        let original = Data((0..<500_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
        try original.write(to: flac)
        let dsf = dir.appendingPathComponent("b.dsf")
        try Data(count: 1000).write(to: dsf)
        let now = Date(timeIntervalSince1970: 1)
        let songs: [Int64: StreamSourceFacts] = [
            1: StreamSourceFacts(id: 1, url: flac, fileExtension: "flac", codec: "FLAC", isDSD: false, isLossless: true, sampleRate: 96_000, bitDepth: 24, channels: 2,
                                 duration: 10, fileSize: Int64(original.count), modifiedAt: now, isRegion: false, needsMacDecoder: false, replayGain: nil),
            2: StreamSourceFacts(id: 2, url: dsf, fileExtension: "dsf", codec: "DSD", isDSD: true, isLossless: true, sampleRate: 2_822_400, bitDepth: 1, channels: 6,
                                 duration: 10, fileSize: 1000, modifiedAt: now, isRegion: false, needsMacDecoder: false, replayGain: nil),
        ]
        let preparer = StreamPreparer(cache: try StreamCache(directory: dir.appendingPathComponent("cache"), limitBytes: 10_000_000), transcoder: FlacMaker(), source: { songs[$0] })
        let key = RemoteTransport.PresharedKey(identity: "phone-test", key: Data(repeating: 0x5A, count: 32))
        let mac = try StreamMac(key: key, preparer: preparer, allowed: allowed)
        let port = try await mac.start()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let saved = SavedPairing(serverID: "S-TEST", name: "Test Mac", device: "phone-test", key: key.key)
        let session = RemoteSession(pairing: saved, clientName: "Test phone") { _ in endpoint }
        session.connect()
        guard await waitUntil({ session.isConnected }) else { throw RigError.notConnected }
        return Rig(dir: dir, mac: mac, session: session, original: original)
    }

    enum RigError: Error { case notConnected }
}

@Suite(.serialized) @MainActor struct StreamOverTheWire {
    @Test func aPhoneThatSpeaksVersionTwoLearnsTheMacCanStream() async throws {
        let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        #expect(rig.session.canStream)
    }

    @Test func aWholeSongReadInRangesIsByteForByteTheFile() async throws {
        let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        guard case .streamOpened(let descriptor) = await rig.session.send(.streamOpen(id: 1, maxSampleRate: nil)) else { Issue.record("not opened"); return }
        #expect(descriptor.kind == .original && descriptor.byteSize == Int64(rig.original.count) && descriptor.format.container == "flac")
        var received = Data()
        var offset: Int64 = 0
        while offset < descriptor.byteSize {
            let frame = try await rig.session.readStream(descriptor.stream, offset: offset, length: 100_000)
            #expect(frame.offset == offset && frame.stream == descriptor.stream)
            received.append(frame.payload)
            offset += Int64(frame.payload.count)
            if frame.endOfStream { break }
        }
        #expect(received == rig.original)
        #expect(await rig.session.send(.streamClose(stream: descriptor.stream)) == .ok)
    }

    @Test func manyReadsInFlightAreMatchedToTheirOwnRanges() async throws {
        let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        guard case .streamOpened(let d) = await rig.session.send(.streamOpen(id: 1, maxSampleRate: nil)) else { Issue.record("not opened"); return }
        let session = rig.session
        let original = rig.original
        let chunk = 50_000
        // All eight at once on one connection: the Mac answers them in any order.
        let tasks = (0..<8).map { index in
            Task { @MainActor in try await session.readStream(d.stream, offset: Int64(index * chunk), length: chunk) }
        }
        for (index, task) in tasks.enumerated() {
            let frame = try await task.value
            let range = index * chunk..<(index + 1) * chunk
            #expect(frame.payload == original[range] && frame.offset == Int64(index * chunk), "range \(index)")
        }
    }

    @Test func aDsdFiveOneIsConvertedAndItsSpeakersTravelWithIt() async throws {
        let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        var descriptor: StreamDescriptor?
        for _ in 0..<100 {
            let reply = await rig.session.send(.streamOpen(id: 2, maxSampleRate: 48_000))
            if case .streamOpened(let d) = reply { descriptor = d; break }
            guard case .streamPreparing = reply else { Issue.record("unexpected \(reply)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let d = try #require(descriptor)
        #expect(d.kind == .flac && d.format.channels == 6 && d.format.channelLabels == [1, 2, 3, 4, 5, 6] && d.format.sampleRate == 44_100)
        let frame = try await rig.session.readStream(d.stream, offset: 1000, length: 4096)
        #expect(frame.payload == FlacMaker.bytes[1000..<5096])
    }

    @Test func aRefusedReadThrowsTheMacsReason() async throws {
        let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        do {
            _ = try await rig.session.readStream(99, offset: 0, length: 10)
            Issue.record("a read of a stream that isn't open succeeded")
        } catch RemoteLinkError.readFailed(let reason) {
            #expect(!reason.isEmpty)
        }
    }

    @Test func streamingTurnedOffOnTheMacIsSaidInWords() async throws {
        let rig = try await Rig.make(allowed: false); defer { try? FileManager.default.removeItem(at: rig.dir) }
        guard case .failed(let reason) = await rig.session.send(.streamOpen(id: 1, maxSampleRate: nil)) else { Issue.record("opened"); return }
        #expect(reason.contains("Settings"))
    }
}
#endif
