//
// Vespertine: driving a renderer's transport. It only ever holds the song playing and the one after it: OpenHome as a
// two-entry playlist, UPnP AV as the current and next transport URIs. Vespertine's queue decides what they are.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct RendererTrack: Sendable, Hashable {
    public var uri: URL
    /// DIDL-Lite for the song.
    public var metadata: String

    public init(uri: URL, metadata: String) {
        self.uri = uri
        self.metadata = metadata
    }
}

public enum RendererState: Sendable, Hashable {
    case playing, paused, stopped, transitioning, noMedia
}

public struct RendererStatus: Sendable, Hashable {
    public var state: RendererState
    public var position: TimeInterval
    public var duration: TimeInterval?
    /// The URI the renderer is on, as Vespertine gave it; nil when it isn't one of ours (or it holds none).
    public var currentURI: URL?

    public init(state: RendererState, position: TimeInterval, duration: TimeInterval?, currentURI: URL?) {
        self.state = state
        self.position = position
        self.duration = duration
        self.currentURI = currentURI
    }
}

public protocol RendererTransport: Sendable {
    /// The renderer joins the current song to the next one itself.
    var gapless: Bool { get }
    /// Replaces whatever the renderer holds with `current` (and `next`) and starts `current`.
    func load(current: RendererTrack, next: RendererTrack?) async throws
    /// The song after the one playing now changed (a skip planned, the queue reordered, the renderer moved on).
    func replaceNext(_ next: RendererTrack?) async throws
    func play() async throws
    func pause() async throws
    func stop() async throws
    func seek(to seconds: TimeInterval) async throws
    func status() async throws -> RendererStatus
}

// MARK: - OpenHome

/// OpenHome Playlist (with Product to select the playlist source, and Time for the position).
public actor OpenHomeTransport: RendererTransport {
    nonisolated public let gapless = true
    private let product: UPnPService
    private let playlist: UPnPService
    private let time: UPnPService
    private let client: SOAPClient
    /// The playlist ids Vespertine inserted, by URI.
    private var ids: [(id: Int, uri: URL)] = []

    public init(description: DeviceDescription, client: SOAPClient = SOAPClient()) throws {
        guard let product = description.service(.ohProduct), let playlist = description.service(.ohPlaylist),
              let time = description.service(.ohTime) else { throw UPnPError.badResponse }
        self.product = product
        self.playlist = playlist
        self.time = time
        self.client = client
    }

    /// Makes the Playlist source the current one (a renderer may be on its radio or a receiver source).
    private func selectPlaylistSource() async throws {
        guard let xml = try? await client.call(product, "SourceXml")["Value"] else { return }
        let types = SourceListParser.types(Data(xml.utf8))
        guard let index = types.firstIndex(of: "Playlist") else { return }
        let current = try? await client.call(product, "SourceIndex")["Value"].flatMap { Int($0) }
        if current != index { _ = try await client.call(product, "SetSourceIndex", [("Value", String(index))]) }
    }

    private func insert(_ track: RendererTrack, after: Int) async throws -> Int {
        let reply = try await client.call(playlist, "Insert", [("AfterId", String(after)), ("Uri", track.uri.absoluteString), ("Metadata", track.metadata)])
        guard let id = Int(reply["NewId"] ?? "") else { throw UPnPError.badResponse }
        ids.append((id, track.uri))
        return id
    }

    public func load(current: RendererTrack, next: RendererTrack?) async throws {
        try await selectPlaylistSource()
        _ = try await client.call(playlist, "DeleteAll")
        ids = []
        let first = try await insert(current, after: 0)
        if let next { _ = try await insert(next, after: first) }
        _ = try await client.call(playlist, "SeekId", [("Value", String(first))])
        _ = try await client.call(playlist, "Play")
    }

    public func replaceNext(_ next: RendererTrack?) async throws {
        let current = Int(try await client.call(playlist, "Id")["Value"] ?? "") ?? 0
        // Everything but the song playing goes: the one before it (played) and the old next.
        for entry in ids where entry.id != current {
            _ = try? await client.call(playlist, "DeleteId", [("Value", String(entry.id))])
        }
        ids.removeAll { $0.id != current }
        if let next { _ = try await insert(next, after: current) }
    }

    public func play() async throws { _ = try await client.call(playlist, "Play") }
    public func pause() async throws { _ = try await client.call(playlist, "Pause") }
    public func stop() async throws { _ = try await client.call(playlist, "Stop") }

    public func seek(to seconds: TimeInterval) async throws {
        _ = try await client.call(playlist, "SeekSecondAbsolute", [("Value", String(max(0, Int(seconds.rounded()))))])
    }

    public func status() async throws -> RendererStatus {
        let id = Int(try await client.call(playlist, "Id")["Value"] ?? "")
        let stateText = try await client.call(playlist, "TransportState")["Value"] ?? ""
        let t = try await client.call(time, "Time")
        let state: RendererState = switch stateText {
        case "Playing": .playing
        case "Paused": .paused
        case "Buffering": .transitioning
        default: .stopped
        }
        let duration = Double(t["Duration"] ?? "").flatMap { $0 > 0 ? $0 : nil }
        return RendererStatus(state: state, position: Double(t["Seconds"] ?? "") ?? 0, duration: duration,
                              currentURI: ids.first { $0.id == id }?.uri)
    }
}

/// The `Type` of each source in a Product's SourceXml, in order (their index is the position).
enum SourceListParser {
    static func types(_ data: Data) -> [String] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.types
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var types: [String] = []
        private var text = ""
        private var inSource = false
        private var type: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "Source" { inSource = true; type = nil }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Type", inSource { type = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if name == "Source" { types.append(type ?? ""); inSource = false }
        }
    }
}

// MARK: - UPnP AV

/// AVTransport. With SetNextAVTransportURI the renderer moves on by itself; without it, the next song is set when the
/// current one ends, which leaves a gap.
public actor AVTransportControl: RendererTransport {
    nonisolated public let gapless: Bool
    private let transport: UPnPService
    private let client: SOAPClient
    private var current: RendererTrack?
    private var next: RendererTrack?
    /// Vespertine asked it to play, and hasn't asked it to stop or pause since.
    private var shouldPlay = false
    private var sawPlaying = false
    private static let instance = ("InstanceID", "0")

    public init(description: DeviceDescription, gapless: Bool, client: SOAPClient = SOAPClient()) throws {
        guard let transport = description.service(.avTransport) else { throw UPnPError.badResponse }
        self.transport = transport
        self.gapless = gapless
        self.client = client
    }

    private func setCurrent(_ track: RendererTrack) async throws {
        _ = try await client.call(transport, "SetAVTransportURI", [Self.instance, ("CurrentURI", track.uri.absoluteString), ("CurrentURIMetaData", track.metadata)])
        current = track
        sawPlaying = false
    }

    private func setNextOnRenderer(_ track: RendererTrack?) async throws {
        guard gapless else { return }
        _ = try await client.call(transport, "SetNextAVTransportURI", [Self.instance, ("NextURI", track?.uri.absoluteString ?? ""),
                                                                       ("NextURIMetaData", track?.metadata ?? "")])
    }

    public func load(current: RendererTrack, next: RendererTrack?) async throws {
        try await setCurrent(current)
        self.next = next
        // A next song left from before must not play after this one: an empty NextURI clears it (some renderers refuse
        // the empty one; setting the current URI clears it on those).
        if let next { try await setNextOnRenderer(next) } else { try? await setNextOnRenderer(nil) }
        try await play()
    }

    public func replaceNext(_ next: RendererTrack?) async throws {
        self.next = next
        try await setNextOnRenderer(next)
    }

    public func play() async throws {
        _ = try await client.call(transport, "Play", [Self.instance, ("Speed", "1")])
        shouldPlay = true
    }

    public func pause() async throws {
        shouldPlay = false
        _ = try await client.call(transport, "Pause", [Self.instance])
    }

    public func stop() async throws {
        shouldPlay = false
        _ = try await client.call(transport, "Stop", [Self.instance])
    }

    public func seek(to seconds: TimeInterval) async throws {
        _ = try await client.call(transport, "Seek", [Self.instance, ("Unit", "REL_TIME"), ("Target", DIDLLite.time(seconds).components(separatedBy: ".")[0])])
    }

    public func status() async throws -> RendererStatus {
        let info = try await client.call(transport, "GetTransportInfo", [Self.instance])
        let position = try await client.call(transport, "GetPositionInfo", [Self.instance])
        var state: RendererState = switch info["CurrentTransportState"] ?? "" {
        case "PLAYING": .playing
        case "PAUSED_PLAYBACK", "PAUSED_RECORDING": .paused
        case "TRANSITIONING": .transitioning
        case "NO_MEDIA_PRESENT": .noMedia
        default: .stopped
        }
        let uri = (position["TrackURI"]).flatMap { URL(string: $0) }
        var currentURI = [current, next].compactMap { $0 }.first { $0.uri == uri }?.uri ?? (uri == nil ? current?.uri : nil)
        if let currentURI, currentURI == next?.uri {
            // The renderer moved on to the next song by itself.
            current = next
            next = nil
        }
        if state == .playing { sawPlaying = true }
        // No SetNext: once the song ends by itself, the next one is set and started (a gap is unavoidable).
        if !gapless, shouldPlay, sawPlaying, state == .stopped || state == .noMedia, let following = next {
            next = nil
            try await setCurrent(following)
            try await play()
            state = .transitioning
            currentURI = following.uri
            return RendererStatus(state: state, position: 0, duration: nil, currentURI: currentURI)
        }
        return RendererStatus(state: state, position: DIDLLite.seconds(position["RelTime"]) ?? 0,
                              duration: DIDLLite.seconds(position["TrackDuration"]).flatMap { $0 > 0 ? $0 : nil }, currentURI: currentURI)
    }
}
