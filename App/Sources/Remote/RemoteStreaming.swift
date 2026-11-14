//
// Vespertine: playing from this Mac's library on a phone: the stream channel's Mac side wired to the library and the decoders.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// `StreamPreparer` (VespertineRemoteKit) decides what to send and serves ranged reads; here it gets library songs by ID and a
// converter made of the player's own decoders (`FLACStreamTranscoder`): DSD, CUE tracks, disc images and formats iOS can't open
// become FLAC once, in the Caches folder, with every channel kept. A phone names songs by library ID only.
//

import Foundation
import VespertineAudio
import VespertineLibrary
import VespertineRemoteProtocol
import VespertineStreamServer

extension Track {
    /// This song as the stream channel plans it.
    var streamFacts: StreamSourceFacts? {
        guard let id else { return nil }
        let ext = (filePath as NSString).pathExtension.lowercased()
        let disc = sacdArea != nil || dvdStream != nil || audioStream != nil
        return StreamSourceFacts(id: id, url: fileURL, fileExtension: ext, codec: codec, isDSD: isDSD, isLossless: isLossless, sampleRate: sampleRate,
                                 bitDepth: bitDepth, channels: channels, duration: duration, fileSize: fileSize, modifiedAt: modifiedAt,
                                 isRegion: cueStartFrame != nil, needsMacDecoder: disc,
                                 replayGain: rgTrackGain == nil && rgAlbumGain == nil ? nil
                                     : ReplayGain(trackGain: rgTrackGain, trackPeak: rgTrackPeak, albumGain: rgAlbumGain, albumPeak: rgAlbumPeak),
                                 regionKey: location)
    }

    var streamItem: PlayableItem {
        PlayableItem(url: fileURL, trackID: id, regionStartFrame: cueStartFrame, regionFrameLength: cueFrameLength,
                     sacdArea: sacdArea, dvd: dvdStream, audioStream: audioStream)
    }
}

/// One conversion at a time: a FLAC of a DSD album is minutes of the Mac's CPU, and the player has first call on it (its
/// audio thread runs at real-time priority whatever a conversion does).
private actor ConversionGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// The converter the stream channel uses: the player's decoders, writing FLAC.
struct PhoneTranscoder: StreamTranscoding {
    /// Finds the library song's playable form on the main actor.
    let item: @Sendable (Int64) async -> PlayableItem?
    private let gate = ConversionGate()

    init(item: @escaping @Sendable (Int64) async -> PlayableItem?) { self.item = item }

    func transcode(_ request: TranscodeRequest, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> TranscodeResult {
        guard let id = request.trackID, let playable = await item(id) else { throw TranscodeFailure(message: StreamWords.say(.notInLibrary)) }
        await gate.enter()
        defer { Task { await gate.leave() } }
        do {
            // `progress` is only used while this call runs, so it may be lent to the detached task.
            let result = try await withoutActuallyEscaping(progress) { relay in
                // Somebody is waiting to hear this: it runs on the fast cores, not held back to the efficiency ones as
                // background work is.
                try await Task.detached(priority: .userInitiated) {
                    try FLACStreamTranscoder.transcode(playable, sampleRate: request.sampleRate, bitDepth: request.bitDepth, to: destination,
                                                       progress: relay, isCancelled: { Task.isCancelled })
                }.value
            }
            return TranscodeResult(format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: result.sampleRate, bitDepth: result.bitDepth,
                                                        channels: result.channels, channelLabels: result.labels, lossless: true),
                                   frames: result.frames)
        } catch {
            throw TranscodeFailure(message: error.localizedDescription)
        }
    }

    func channelLabels(of facts: StreamSourceFacts) async -> [UInt32]? {
        guard let playable = await item(facts.id) else { return nil }
        return await Task.detached(priority: .utility) { FLACStreamTranscoder.channelLabels(of: playable) }.value
    }
}

@MainActor
enum RemoteStreaming {
    static func bytes(gigabytes: Int) -> Int64 { Int64(gigabytes) * 1024 * 1024 * 1024 }

    /// `gigabytes`: how much the converted FLACs may take in Caches (least recently used go first).
    static func makePreparer(model: AppModel, gigabytes: Int) -> StreamPreparer? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Vespertine", isDirectory: true).appendingPathComponent("Remote", isDirectory: true)
            .appendingPathComponent("Streams", isDirectory: true)
        guard let cache = try? StreamCache(directory: folder, limitBytes: bytes(gigabytes: gigabytes)) else { return nil }
        let transcoder = PhoneTranscoder { [weak model] id in
            await MainActor.run { model?.library.tracks(ids: [id]).first?.streamItem }
        }
        return StreamPreparer(cache: cache, transcoder: transcoder) { [weak model] id in
            await MainActor.run { model?.library.tracks(ids: [id]).first?.streamFacts }
        }
    }
}
