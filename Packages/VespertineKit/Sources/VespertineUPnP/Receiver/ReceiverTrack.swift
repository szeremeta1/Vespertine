//
// Vespertine: a song a control app sent to the receiver: its address, what its DIDL-Lite description says about it, and the
// private address (vespertine-receiver://track/<id>) the engine opens it by. The real address stays in a table in memory,
// so it is never written to disk, a log or the queue.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public struct ReceiverTrack: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The http or https address the control app gave.
    public let address: URL
    public var info: RendererTrackInfo
    /// The media type the control app named for it (`audio/flac`), if it named one.
    public var mediaType: String?
    /// The description as it was sent, handed back to control apps that ask what is playing.
    public var metadata: String

    public init(id: UUID = UUID(), address: URL, info: RendererTrackInfo, mediaType: String? = nil, metadata: String = "") {
        self.id = id
        self.address = address
        self.info = info
        self.mediaType = mediaType
        self.metadata = metadata
    }

    /// What the engine plays: staged in the transient playback cache under a key of its own, like a share's file.
    public var item: PlayableItem { PlayableItem(id: id, url: ReceiverStreams.itemURL(id), cacheKey: ReceiverStreams.cacheKey(id)) }
}

/// What a control app's DIDL-Lite says about a song.
public struct ReceivedMetadata: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artworkURL: URL?
    public var duration: TimeInterval?
    /// The third field of the first `res` element's protocolInfo.
    public var mediaType: String?

    /// The longest description taken (a few kilobytes is usual; a description with embedded art is not taken).
    public static let maximumLength = 64 * 1024
    /// No field is kept longer than this.
    static let maximumField = 1024

    public enum Failure: Error, Equatable { case tooLong, malformed }

    /// Reads a DIDL-Lite document holding one item. Empty text and "NOT_IMPLEMENTED" are no description (nil). Anything that
    /// is not well-formed XML with a DIDL-Lite root, or that declares a document type or entities, is refused.
    public static func parse(_ text: String) throws(Failure) -> ReceivedMetadata? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "NOT_IMPLEMENTED" { return nil }
        guard trimmed.utf8.count <= maximumLength else { throw .tooLong }
        // Entities are how XML is made to read files or grow without end: a description never needs them.
        guard trimmed.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil, trimmed.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw .malformed }
        let delegate = Parser()
        let parser = XMLParser(data: Data(trimmed.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot, delegate.sawItem else { throw .malformed }
        var found = delegate.found
        // upnp:artist is the performer; dc:creator stands in when it is all there is.
        if found.artist == nil { found.artist = delegate.creator }
        return found
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var found = ReceivedMetadata()
        var sawRoot = false
        var sawItem = false
        var creator: String?
        private var depth = 0
        private var text = ""
        private var resSeen = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            depth += 1
            text = ""
            if depth == 1 {
                guard name == "DIDL-Lite" else { parser.abortParsing(); return }
                sawRoot = true
            } else if depth == 2, name == "item" {
                // One item is one song; a second one is somebody else's.
                if sawItem { parser.abortParsing(); return }
                sawItem = true
            } else if depth == 3, name == "res", !resSeen {
                resSeen = true
                found.duration = DIDLLite.seconds(attributes["duration"]).flatMap { $0.isFinite && $0 > 0 && $0 < 360_000 ? $0 : nil }
                let fields = (attributes["protocolInfo"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
                if fields.count >= 3, !fields[2].isEmpty, fields[2] != "*" { found.mediaType = String(fields[2].prefix(128)).lowercased() }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if text.utf8.count <= ReceivedMetadata.maximumField * 4 { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { depth -= 1; text = "" }
            guard depth == 3 else { return }
            let value = String(text.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }.prefix(ReceivedMetadata.maximumField))
            guard !value.isEmpty else { return }
            switch name {
            case "title": found.title = found.title ?? value
            case "artist": found.artist = found.artist ?? value
            case "creator": creator = creator ?? value
            case "album": found.album = found.album ?? value
            case "albumArtURI":
                if found.artworkURL == nil, let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    found.artworkURL = url
                }
            default: break
            }
        }
    }
}

/// The songs the receiver has been sent and may still be asked to play, by id. Process-wide, because the playback cache's
/// reader registry is: each receiver adds and removes its own.
public enum ReceiverStreams {
    public static let scheme = "vespertine-receiver"

    struct Entry {
        var address: URL
        var options: HTTPStreamReader.Options
        /// The reader that checked the address when it was sent: the first open takes it, so the stream isn't asked twice.
        var checked: HTTPStreamReader?
    }

    private static let table = Locked([UUID: Entry]())
    private static let users = Locked(0)

    public static func itemURL(_ id: UUID) -> URL { URL(string: "\(scheme)://track/\(id.uuidString)")! }
    public static func cacheKey(_ id: UUID) -> String { "receiver:\(id.uuidString)" }
    /// The id in a `vespertine-receiver://track/<id>` address.
    public static func id(of url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
    public static func isReceiverItem(_ url: URL) -> Bool { url.scheme?.lowercased() == scheme }

    static func add(_ id: UUID, address: URL, options: HTTPStreamReader.Options, checked: HTTPStreamReader?) {
        table.withLock { $0[id] = Entry(address: address, options: options, checked: checked) }
    }

    static func remove(_ id: UUID) {
        let reader = table.withLock { $0.removeValue(forKey: id)?.checked }
        reader?.cancel()
    }

    static func open(_ url: URL) throws -> any RemoteCacheReader {
        guard let id = id(of: url) else { throw StreamRefusal.notHTTP }
        let entry = table.withLock { table -> Entry? in
            guard let entry = table[id] else { return nil }
            table[id]?.checked = nil
            return entry
        }
        guard let entry else {
            throw StreamRefusal.unreachable(String(localized: "The control app took the song back.", comment: "A whole sentence shown after “The address didn’t answer:” when a control app replaced a song before it was opened."))
        }
        if let checked = entry.checked { return checked }
        return try HTTPStreamReader(url: entry.address, options: entry.options)
    }

    /// The scheme is registered with the playback cache while any receiver runs, and forgotten when the last one stops.
    static func retain() {
        users.withLock { count in
            if count == 0 {
                NetworkPlaybackCache.registerRemoteReader(scheme: scheme, notAnsweringMessage: notAnswering) { try open($0) }
            }
            count += 1
        }
    }

    static func release() {
        users.withLock { count in
            count = max(0, count - 1)
            if count == 0 { NetworkPlaybackCache.unregisterRemoteReader(scheme: scheme) }
        }
    }

    static var notAnswering: String {
        String(localized: "The control app’s stream stopped answering.", comment: "A song sent by a UPnP control app stopped arriving for too long.")
    }
}
