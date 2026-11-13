//
// Vespertine: turns a TIDAL track ID into something the player can fetch: one file URL (BTS manifests) or an init segment plus
// numbered media segments (DASH manifests, used for hi-res FLAC). Protected streams are refused.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct TidalStream: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file(URL)
        case dash(initialization: URL, segments: [URL])
    }

    public var kind: Kind
    /// As the manifest names it: `flac`, `mp4a.40.2`, `eac3`, …
    public var codec: String
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var audioQuality: String
    public var audioMode: String
    /// `flac` for FLAC codecs, `m4a` otherwise.
    public var fileExtension: String

    public init(kind: Kind, codec: String, sampleRate: Int?, bitDepth: Int?, audioQuality: String, audioMode: String, fileExtension: String) {
        self.kind = kind; self.codec = codec; self.sampleRate = sampleRate; self.bitDepth = bitDepth
        self.audioQuality = audioQuality; self.audioMode = audioMode; self.fileExtension = fileExtension
    }
}

public struct TidalStreamResolver: Sendable {
    private let gate: TidalGate
    private let quality: String

    public init(gate: TidalGate, quality: String = "HI_RES_LOSSLESS") {
        self.gate = gate
        self.quality = quality
    }

    public func resolve(trackId: Int, priority: TidalPriority = .playback) async throws -> TidalStream {
        let data: Data
        do {
            data = try await gate.get("tracks/\(trackId)/playbackinfopostpaywall",
                                      query: ["playbackmode": "STREAM", "assetpresentation": "FULL", "audioquality": quality],
                                      priority: priority)
        } catch TidalError.http(let status, let body) where status == 401 || status == 404 {
            if let message = Self.notReadyMessage(body) { throw TidalError.notStreamable(message) }
            throw TidalError.http(status: status, body: body)
        }
        guard let info = try? JSONDecoder().decode(PlaybackInfo.self, from: data) else {
            throw TidalError.malformedStream("the playback info is not valid JSON")
        }
        guard let manifest = Data(base64Encoded: info.manifest) else { throw TidalError.malformedStream("the manifest is not base64") }
        let mime = info.manifestMimeType.lowercased()
        if mime.contains("vnd.tidal.bts") { return try Self.fromBTS(manifest, info) }
        if mime.contains("dash+xml") { return try Self.fromDASH(manifest, info) }
        throw TidalError.malformedStream("unsupported manifest type \(info.manifestMimeType)")
    }

    // MARK: Manifests

    private static func fromBTS(_ manifest: Data, _ info: PlaybackInfo) throws -> TidalStream {
        guard let bts = try? JSONDecoder().decode(BTSManifest.self, from: manifest) else {
            throw TidalError.malformedStream("the BTS manifest is not valid JSON")
        }
        guard bts.encryptionType.uppercased() == "NONE" else { throw TidalError.encrypted }
        guard let first = bts.urls.first, let url = httpsURL(first) else { throw TidalError.malformedStream("the BTS manifest has no URL") }
        return TidalStream(kind: .file(url), codec: bts.codecs, sampleRate: info.sampleRate, bitDepth: info.bitDepth,
                           audioQuality: info.audioQuality, audioMode: info.audioMode, fileExtension: fileExtension(for: bts.codecs))
    }

    private static func fromDASH(_ manifest: Data, _ info: PlaybackInfo) throws -> TidalStream {
        let mpd = try MPDParser.parse(String(decoding: manifest, as: UTF8.self))
        if mpd.hasContentProtection { throw TidalError.encrypted }
        guard let initialization = httpsURL(mpd.initialization) else { throw TidalError.malformedStream("the initialization URL is not valid") }
        var segments: [URL] = []
        segments.reserveCapacity(mpd.segmentCount)
        for number in mpd.startNumber..<(mpd.startNumber + mpd.segmentCount) {
            guard let url = httpsURL(substituteNumber(in: mpd.media, with: number)) else {
                throw TidalError.malformedStream("the media URL is not valid")
            }
            segments.append(url)
        }
        return TidalStream(kind: .dash(initialization: initialization, segments: segments), codec: mpd.codecs,
                           sampleRate: mpd.sampleRate ?? info.sampleRate, bitDepth: info.bitDepth,
                           audioQuality: info.audioQuality, audioMode: info.audioMode, fileExtension: fileExtension(for: mpd.codecs))
    }

    /// `$Number$`, or `$Number%05d$` with a printf width.
    private static func substituteNumber(in template: String, with number: Int) -> String {
        var result = template
        while let open = result.range(of: "$Number") {
            guard let close = result.range(of: "$", range: open.upperBound..<result.endIndex) else { break }
            let format = String(result[open.upperBound..<close.lowerBound])
            let text = format.isEmpty ? String(number) : String(format: format, number)
            result.replaceSubrange(open.lowerBound..<close.upperBound, with: text)
        }
        return result
    }

    private static func httpsURL(_ string: String) -> URL? {
        guard var components = URLComponents(string: string), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http", components.host != nil else { return nil }
        components.scheme = "https"
        return components.url
    }

    private static func fileExtension(for codec: String) -> String {
        codec.lowercased().contains("flac") ? "flac" : "m4a"
    }

    /// TIDAL's message when the answer says the asset isn't ready (`subStatus` 4005, or "not ready" in the text).
    private static func notReadyMessage(_ body: String) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let message = (object?["userMessage"] as? String) ?? (object?["description"] as? String)
        let subStatus = (object?["subStatus"] as? Int) ?? (object?["sub_status"] as? Int)
        guard subStatus == 4005 || body.lowercased().contains("not ready") else { return nil }
        return message ?? "The track isn't ready for streaming"
    }

    // MARK: Wire shapes

    private struct PlaybackInfo: Decodable {
        var audioMode: String
        var audioQuality: String
        var manifestMimeType: String
        var manifest: String
        var bitDepth: Int?
        var sampleRate: Int?
    }

    private struct BTSManifest: Decodable {
        var codecs: String
        var encryptionType: String
        var urls: [String]
    }
}
