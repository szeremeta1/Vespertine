//
// Vespertine: UPnP control (SOAP 1.1 over HTTP, UPnP Device Architecture 1.1, section 3) and the DIDL-Lite metadata a
// renderer shows for a song.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public enum UPnPError: Error, Equatable, Sendable {
    /// The renderer refused: a UPnP error code and its description (714 "Illegal MIME-type", 701 "Transition not available"…).
    case fault(code: Int, description: String)
    case http(Int)
    case timeout
    case unreachable(String)
    case badResponse

    public var message: String {
        switch self {
        case .fault(let code, let description):
            description.isEmpty ? String(localized: "UPnP error \(code)") : String(localized: "UPnP error \(code): \(description)")
        case .http(let status): String(localized: "HTTP status \(status)")
        case .timeout: String(localized: "it didn't answer in time")
        case .unreachable(let reason): reason
        case .badResponse: String(localized: "its answer couldn't be read")
        }
    }
}

public enum SOAP {
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    public static func envelope(serviceType: String, action: String, arguments: [(String, String)]) -> Data {
        let args = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(escape(serviceType))\">\(args)</u:\(action)></s:Body></s:Envelope>"
        return Data(xml.utf8)
    }

    /// The children of the first element named `element` (local name), as name → text. nil when there is no such element.
    public static func arguments(in data: Data, element: String) -> [String: String]? {
        let delegate = ArgumentsParser(element: element)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.found ? delegate.arguments : nil
    }

    public static func parseResponse(_ data: Data, action: String) throws -> [String: String] {
        guard let arguments = arguments(in: data, element: action + "Response") else { throw UPnPError.badResponse }
        return arguments
    }

    /// A `<UPnPError>` fault's code and description.
    public static func parseFault(_ data: Data) -> UPnPError? {
        guard let fault = arguments(in: data, element: "UPnPError"), let code = Int(fault["errorCode"] ?? "") else { return nil }
        return .fault(code: code, description: fault["errorDescription"] ?? "")
    }

    public static func fault(code: Int, description: String) -> Data {
        let xml = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault>"
            + "<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\">"
            + "<errorCode>\(code)</errorCode><errorDescription>\(escape(description))</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
        return Data(xml.utf8)
    }

    public static func response(serviceType: String, action: String, arguments: [(String, String)]) -> Data {
        let args = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let xml = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action)Response xmlns:u=\"\(escape(serviceType))\">\(args)</u:\(action)Response></s:Body></s:Envelope>"
        return Data(xml.utf8)
    }
}

private final class ArgumentsParser: NSObject, XMLParserDelegate {
    let element: String
    var arguments: [String: String] = [:]
    var found = false
    private var depth = 0          // inside the element: 1; inside one of its children: 2
    private var text = ""
    private var done = false

    init(element: String) { self.element = element }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard !done else { return }
        if depth == 0, name == element { found = true; depth = 1; return }
        if depth >= 1 { depth += 1; if depth == 2 { text = "" } }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if depth >= 2 { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard !done, depth >= 1 else { return }
        if depth == 2 { arguments[name] = text }
        depth -= 1
        if depth == 0 { done = true }
    }
}

public struct SOAPClient: Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 5) { self.timeout = timeout }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public func call(_ service: UPnPService, _ action: String, _ arguments: [(String, String)] = []) async throws -> [String: String] {
        var request = URLRequest(url: service.controlURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.type)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = SOAP.envelope(serviceType: service.type, action: action, arguments: arguments)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw UPnPError.timeout
        } catch {
            throw UPnPError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SOAP.parseFault(data) ?? UPnPError.http(status) }
        return try SOAP.parseResponse(data, action: action)
    }

    /// GET of a description or SCPD, at most `limit` bytes (more is an error, and isn't read).
    public func get(_ url: URL, limit: Int = 1 << 20) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        do {
            let (bytes, response) = try await Self.session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UPnPError.http(status) }
            if response.expectedContentLength > Int64(limit) { throw UPnPError.badResponse }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw UPnPError.badResponse }
            }
            return data
        } catch let error as UPnPError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw UPnPError.timeout
        } catch {
            throw UPnPError.unreachable(error.localizedDescription)
        }
    }
}

/// What a renderer shows for a song.
public struct RendererTrackInfo: Sendable, Hashable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var artworkURL: URL?
    public var duration: TimeInterval?

    public init(title: String, artist: String? = nil, album: String? = nil, artworkURL: URL? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
    }
}

public enum DIDLLite {
    /// "H:MM:SS.mmm" (UPnP AV's duration and time format).
    public static func time(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        let millis = Int(((total - Double(whole)) * 1000).rounded())
        return String(format: "%d:%02d:%02d.%03d", whole / 3600, (whole / 60) % 60, whole % 60, min(millis, 999))
    }

    /// Seconds from "H:MM:SS", "H:MM:SS.mmm" or "H:MM:SS.F0/F1"; nil for "NOT_IMPLEMENTED" or nonsense.
    public static func seconds(_ text: String?) -> TimeInterval? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]) else { return nil }
        let secondsPart = parts[2].split(separator: "/").first.map(String.init) ?? ""
        guard let s = Double(secondsPart) else { return nil }
        return h * 3600 + m * 60 + s
    }

    public static func item(id: String, info: RendererTrackInfo, url: URL, mime: String, size: Int64?, format: SourceFormat?) -> String {
        var res = "<res protocolInfo=\"http-get:*:\(SOAP.escape(mime)):*\""
        if let duration = info.duration { res += " duration=\"\(time(duration))\"" }
        if let size { res += " size=\"\(size)\"" }
        if let format, format.encoding != .dsd {
            res += " sampleFrequency=\"\(Int(format.sampleRate))\" nrAudioChannels=\"\(format.channels)\""
            if let bits = format.bitDepth { res += " bitsPerSample=\"\(bits)\"" }
        }
        res += ">\(SOAP.escape(url.absoluteString))</res>"
        var item = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"\(SOAP.escape(id))\" parentID=\"0\" restricted=\"1\">"
            + "<dc:title>\(SOAP.escape(info.title))</dc:title>"
        if let artist = info.artist { item += "<dc:creator>\(SOAP.escape(artist))</dc:creator><upnp:artist>\(SOAP.escape(artist))</upnp:artist>" }
        if let album = info.album { item += "<upnp:album>\(SOAP.escape(album))</upnp:album>" }
        if let art = info.artworkURL { item += "<upnp:albumArtURI>\(SOAP.escape(art.absoluteString))</upnp:albumArtURI>" }
        item += "<upnp:class>object.item.audioItem.musicTrack</upnp:class>\(res)</item></DIDL-Lite>"
        return item
    }
}
