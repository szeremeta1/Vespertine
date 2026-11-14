//
// Vespertine: a network renderer for the tests, on 127.0.0.1. It serves a description and service descriptions, runs
// OpenHome Playlist/Time/Product or UPnP AV as a small state machine, records every SOAP call, and fetches each URI it
// is told to play, so a test can compare the bytes it got with the source file.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@testable import VespertineUPnP

final class FakeRenderer: @unchecked Sendable {
    enum Kind { case openHome, av(setNext: Bool) }

    struct Call: Hashable { var service: String; var action: String; var arguments: [String: String] }

    let kind: Kind
    var sink = "http-get:*:audio/flac:*,http-get:*:audio/x-flac:*,http-get:*:audio/wav:*,http-get:*:audio/L16;rate=48000;channels=2:*"
    private let lock = NSLock()
    private var server: HTTPServer!
    private(set) var port: UInt16 = 0

    // State, under `lock`.
    private var _calls: [Call] = []
    private var playlist: [(id: Int, uri: String)] = []
    private var nextID = 1
    private var currentID = 0
    private var avCurrent: String?
    private var avNext: String?
    private var state = "Stopped"        // OpenHome words; AV maps them
    private var seconds = 0
    private var _fetched: [String: Data] = [:]
    private var failures: [String: (code: Int, times: Int)] = [:]
    private var sourceIndex = 0          // starts on the radio, as a real one may

    init(kind: Kind) async throws {
        self.kind = kind
        server = HTTPServer { [weak self] request in self?.handle(request) ?? .status(503) }
        port = try await server.start()
    }

    func stop() { server.stop() }

    var location: URL { URL(string: "http://127.0.0.1:\(port)/description.xml")! }
    var calls: [Call] { lock.withLock { _calls } }
    var actions: [String] { calls.map(\.action) }
    var playlistURIs: [String] { lock.withLock { playlist.map(\.uri) } }
    var nextURI: String? { lock.withLock { avNext } }
    var currentURI: String? {
        lock.withLock {
            switch kind {
            case .openHome: playlist.first { $0.id == currentID }?.uri
            case .av: avCurrent
            }
        }
    }
    var transportState: String { lock.withLock { state } }
    var selectedSource: Int { lock.withLock { sourceIndex } }

    func setPosition(_ s: Int) { lock.withLock { seconds = s } }
    /// The next call of `action` fails with UPnP error `code`.
    func fail(_ action: String, code: Int, times: Int = 1) { lock.withLock { failures[action] = (code, times) } }

    /// The bytes fetched from `uri` once the fetch is complete (waits up to 10 s).
    func fetched(_ uri: String) async -> Data? {
        for _ in 0..<500 {
            if let data = lock.withLock({ _fetched[uri] }) { return data }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The song playing ends: the renderer moves to the next one, or stops.
    func advance() {
        let toFetch: String? = lock.withLock {
            seconds = 0
            switch kind {
            case .openHome:
                guard let index = playlist.firstIndex(where: { $0.id == currentID }), index + 1 < playlist.count else { state = "Stopped"; return nil }
                currentID = playlist[index + 1].id
                return playlist[index + 1].uri
            case .av(let setNext):
                if setNext, let next = avNext { avCurrent = next; avNext = nil; return next }
                state = "Stopped"
                return nil
            }
        }
        if let toFetch { fetch(toFetch) }
    }

    private func fetch(_ uri: String) {
        guard let url = URL(string: uri) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            lock.withLock { _fetched[uri] = data }
        }
    }

    // MARK: HTTP

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/description.xml"): return xml(description)
        case ("GET", "/scpd/AVTransport.xml"):
            let setNext: Bool = if case .av(let s) = kind { s } else { true }
            return xml(scpd(["SetAVTransportURI", "Play", "Pause", "Stop", "Seek", "GetPositionInfo", "GetTransportInfo"] + (setNext ? ["SetNextAVTransportURI"] : [])))
        case ("GET", let path) where path.hasPrefix("/scpd/"): return xml(scpd(["Placeholder"]))
        case ("POST", let path) where path.hasPrefix("/ctl/"):
            let service = String(path.dropFirst(5))
            let soapAction = (request.headers["soapaction"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let action = soapAction.components(separatedBy: "#").last ?? ""
            let arguments = SOAP.arguments(in: request.body, element: action) ?? [:]
            return control(service: service, type: soapAction.components(separatedBy: "#").first ?? "", action: action, arguments: arguments)
        default: return .status(404)
        }
    }

    private func xml(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "text/xml"), ("Content-Length", "\(text.utf8.count)")], body: .data(Data(text.utf8)))
    }

    private func control(service: String, type: String, action: String, arguments: [String: String]) -> HTTPResponse {
        var toFetch: String?
        let result: Result<[(String, String)], FakeFault> = lock.withLock {
            _calls.append(Call(service: service, action: action, arguments: arguments))
            if let failure = failures[action] {
                failures[action] = failure.times > 1 ? (failure.code, failure.times - 1) : nil
                return .failure(FakeFault(code: failure.code))
            }
            switch (service, action) {
            case ("ConnectionManager", "GetProtocolInfo"): return .success([("Source", ""), ("Sink", sink)])
            case ("Product", "SourceXml"):
                return .success([("Value", "<SourceList><Source><Name>Radio</Name><Type>Radio</Type><Visible>true</Visible></Source><Source><Name>Playlist</Name><Type>Playlist</Type><Visible>true</Visible></Source><Source><Name>Receiver</Name><Type>Receiver</Type><Visible>true</Visible></Source></SourceList>")])
            case ("Product", "SourceIndex"): return .success([("Value", String(sourceIndex))])
            case ("Product", "SetSourceIndex"): sourceIndex = Int(arguments["Value"] ?? "") ?? -1; return .success([])
            case ("Playlist", "DeleteAll"): playlist = []; currentID = 0; state = "Stopped"; return .success([])
            case ("Playlist", "Insert"):
                let after = Int(arguments["AfterId"] ?? "") ?? -1
                let id = nextID
                nextID += 1
                let at = after == 0 ? 0 : (playlist.firstIndex { $0.id == after }.map { $0 + 1 } ?? playlist.count)
                playlist.insert((id, arguments["Uri"] ?? ""), at: at)
                return .success([("NewId", String(id))])
            case ("Playlist", "DeleteId"):
                let id = Int(arguments["Value"] ?? "") ?? -1
                playlist.removeAll { $0.id == id }
                if currentID == id { currentID = 0; state = "Stopped" }
                return .success([])
            case ("Playlist", "SeekId"):
                currentID = Int(arguments["Value"] ?? "") ?? 0
                seconds = 0
                state = "Playing"
                toFetch = playlist.first { $0.id == currentID }?.uri
                return .success([])
            case ("Playlist", "Play"), ("AVTransport", "Play"):
                if state == "Stopped", service == "AVTransport" { toFetch = avCurrent }
                state = "Playing"; return .success([])
            case ("Playlist", "Pause"), ("AVTransport", "Pause"): state = "Paused"; return .success([])
            case ("Playlist", "Stop"), ("AVTransport", "Stop"): state = "Stopped"; return .success([])
            case ("Playlist", "SeekSecondAbsolute"): seconds = Int(arguments["Value"] ?? "") ?? 0; return .success([])
            case ("Playlist", "Id"): return .success([("Value", String(currentID))])
            case ("Playlist", "TransportState"): return .success([("Value", state)])
            case ("Time", "Time"): return .success([("TrackCount", "1"), ("Duration", "200"), ("Seconds", String(seconds))])
            case ("AVTransport", "SetAVTransportURI"):
                avCurrent = arguments["CurrentURI"]; state = "Stopped"; seconds = 0; return .success([])
            case ("AVTransport", "SetNextAVTransportURI"):
                avNext = (arguments["NextURI"] ?? "").isEmpty ? nil : arguments["NextURI"]; return .success([])
            case ("AVTransport", "Seek"): seconds = Int(DIDLLite.seconds(arguments["Target"]) ?? 0); return .success([])
            case ("AVTransport", "GetTransportInfo"):
                let av = switch state { case "Playing": "PLAYING"; case "Paused": "PAUSED_PLAYBACK"; default: avCurrent == nil ? "NO_MEDIA_PRESENT" : "STOPPED" }
                return .success([("CurrentTransportState", av), ("CurrentTransportStatus", "OK"), ("CurrentSpeed", "1")])
            case ("AVTransport", "GetPositionInfo"):
                return .success([("Track", "1"), ("TrackDuration", "0:03:20"), ("TrackURI", avCurrent ?? ""),
                                 ("RelTime", DIDLLite.time(Double(seconds)).components(separatedBy: ".")[0])])
            default: return .failure(FakeFault(code: 401))
            }
        }
        if let toFetch { fetch(toFetch) }
        switch result {
        case .success(let args):
            let body = SOAP.response(serviceType: type, action: action, arguments: args)
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/xml; charset=\"utf-8\""), ("Content-Length", "\(body.count)")], body: .data(body))
        case .failure(let fault):
            let code = fault.code
            let body = SOAP.fault(code: code, description: code == 401 ? "Invalid Action" : "Fake failure")
            return HTTPResponse(status: 500, headers: [("Content-Type", "text/xml"), ("Content-Length", "\(body.count)")], body: .data(body))
        }
    }

    private func scpd(_ actions: [String]) -> String {
        "<?xml version=\"1.0\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><actionList>"
            + actions.map { "<action><name>\($0)</name></action>" }.joined() + "</actionList></scpd>"
    }

    private var description: String {
        func service(_ type: String, _ name: String) -> String {
            "<service><serviceType>\(type)</serviceType><serviceId>urn:x:serviceId:\(name)</serviceId><SCPDURL>/scpd/\(name).xml</SCPDURL>"
                + "<controlURL>/ctl/\(name)</controlURL><eventSubURL>/evt/\(name)</eventSubURL></service>"
        }
        var services = service("urn:schemas-upnp-org:service:AVTransport:1", "AVTransport")
            + service("urn:schemas-upnp-org:service:ConnectionManager:1", "ConnectionManager")
            + service("urn:schemas-upnp-org:service:RenderingControl:1", "RenderingControl")
        if case .openHome = kind {
            services += service("urn:av-openhome-org:service:Product:1", "Product") + service("urn:av-openhome-org:service:Playlist:1", "Playlist")
                + service("urn:av-openhome-org:service:Time:1", "Time") + service("urn:av-openhome-org:service:Info:1", "Info")
        }
        return "<?xml version=\"1.0\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device>"
            + "<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>Fake Renderer</friendlyName>"
            + "<manufacturer>Tests</manufacturer><modelName>Fake</modelName><modelNumber>1</modelNumber><UDN>uuid:fake-\(port)</UDN>"
            + "<serviceList>\(services)</serviceList></device></root>"
    }
}

struct FakeFault: Error { var code: Int }
