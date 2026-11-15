//
// Vespertine: "Play to Vespertine": this Mac as a UPnP AV MediaRenderer:1. A control app (on a phone, or a streaming service's
// own app) finds it, sends the address of a song and presses Play; the song is fetched into the transient playback cache and
// played by the same engine as a local file. Nothing here opens a socket until `start()`, which the app calls only while the
// listener has the switch on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

/// The app that is controlling the receiver, as far as it says who it is.
public struct ReceiverControlApp: Sendable, Hashable {
    /// Its name from the User-Agent it sends ("BubbleUPnP"), cleaned; nil when it gives none worth showing.
    public var name: String?
    /// The address it controls from ("192.0.2.7").
    public var address: String?

    public init(name: String? = nil, address: String? = nil) {
        self.name = name
        self.address = address
    }

    /// Product names that say what a control app is built with, not what it is.
    private static let generic: Set<String> = [
        "upnp", "dlnadoc", "linux", "android", "dalvik", "mozilla", "okhttp", "darwin", "cfnetwork", "java", "libupnp", "portable",
        "sdk", "for", "devices", "microsoft-windows", "windows", "windows-nt", "http", "user-agent", "ios", "iphone", "ipad", "mac",
        "macos", "applewebkit", "khtml", "like", "gecko", "version", "mobile", "safari", "chrome", "unknown", "neon", "curl", "python",
        "python-urllib", "python-requests", "go-http-client", "ksoap2-android", "cling", "jupnp", "ohnet", "ohnetmon", "allegro-software-rpc",
    ]

    /// The first product in a User-Agent that isn't a library or a system ("Linux/4.9 UPnP/1.0 BubbleUPnP/3.5" → "BubbleUPnP").
    /// Only letters, digits, spaces and a few marks are kept, and no more than 40 characters: this is text from the network.
    public static func name(fromUserAgent agent: String?) -> String? {
        guard let agent, agent.utf8.count <= 512 else { return nil }
        var depth = 0
        var plain = ""
        for c in agent {   // comments in brackets say what it runs on
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) } else if depth == 0 { plain.append(c) }
        }
        for token in plain.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }) {
            let product = token.split(separator: "/").first.map(String.init) ?? ""
            let cleaned = String(product.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "+" }.prefix(40))
            guard cleaned.count >= 2, cleaned.contains(where: \.isLetter), !generic.contains(cleaned.lowercased()) else { continue }
            return cleaned
        }
        return nil
    }
}

public struct ReceiverPosition: Sendable, Hashable {
    public var position: TimeInterval
    public var duration: TimeInterval?
    public init(position: TimeInterval = 0, duration: TimeInterval? = nil) {
        self.position = position
        self.duration = duration
    }
}

/// What plays the songs the receiver is sent: the app's player (which keeps the listener's own queue aside meanwhile), or an
/// engine in the tests. Called from the receiver's own executor, never from the audio thread.
public protocol ReceiverPlayer: AnyObject, Sendable {
    /// Play `track` now, in place of whatever plays; `next` follows it without a gap.
    func receiverPlay(_ track: ReceiverTrack, next: ReceiverTrack?, from app: ReceiverControlApp) async
    /// What follows the song playing (nil: nothing).
    func receiverSetNext(_ track: ReceiverTrack?) async
    func receiverPause() async
    func receiverResume() async
    /// The control app is done: stop, and give the listener's own queue back.
    func receiverStop() async
    func receiverSeek(to seconds: TimeInterval) async
    func receiverPosition() async -> ReceiverPosition
    /// The listener's volume, 0…1, and whether it is muted.
    func receiverVolume() async -> (level: Double, muted: Bool)
    func receiverSetVolume(_ level: Double) async
    func receiverSetMuted(_ muted: Bool) async
}

/// What the player tells the receiver, so that control apps see what really happens.
public enum ReceiverPlayerEvent: Sendable, Equatable {
    /// The song became audible.
    case started(UUID)
    case paused
    case resumed
    /// The last song sent played to its end.
    case ended
    /// A song could not be played: why, in words the listener reads.
    case failed(UUID?, String)
    /// The listener played something of their own: the control app's session is over.
    case tookOver
    case volume(level: Double, muted: Bool)
}

public actor UPnPReceiver {
    public struct Configuration: Sendable {
        /// "uuid:…", the same across launches.
        public var udn: String
        /// What control apps show (see `ReceiverDescription.friendlyName`).
        public var name: String
        public var version: String
        /// Control is taken only from addresses on this Mac's own subnets; off, from any private address.
        public var ownSubnetsOnly = true
        /// Control apps may set the listener's volume; off, the receiver says its volume is fixed and ignores them.
        public var allowsVolume = false
        /// Where songs may be fetched from.
        public var streamPolicy = StreamAddressPolicy.fromTheNetwork
        public var port: UInt16 = 0
        /// Off in tests that only talk to the HTTP side.
        public var advertises = true
        public var listenOn: (host: String, port: UInt16)?
        public var announceTo: (host: String, port: UInt16)?
        public var networks: @Sendable () -> [LocalNetwork] = { LocalNetworks.current() }
        /// How long a search is left unanswered (nil: the random wait the UDA asks for; see `ReceiverAdvertiser`).
        public var responseDelay: (@Sendable (Int) -> TimeInterval)?
        /// A refusal the listener should see (the address was refused, or the song could not be opened), and who sent it.
        public var onRefusal: (@Sendable (String, ReceiverControlApp) -> Void)?

        public init(udn: String, name: String, version: String) {
            self.udn = udn
            self.name = name
            self.version = version
        }
    }

    public enum TransportState: String, Sendable {
        case noMedia = "NO_MEDIA_PRESENT", stopped = "STOPPED", playing = "PLAYING", paused = "PAUSED_PLAYBACK", transitioning = "TRANSITIONING"
    }

    public struct Snapshot: Sendable, Equatable {
        public var state: TransportState
        public var current: ReceiverTrack?
        public var next: ReceiverTrack?
        public var app: ReceiverControlApp
        public var lastError: String?
    }

    /// The longest SOAP call taken; a longer one is answered 413 and not read into a parser.
    public static let maximumSOAP = 256 * 1024
    static let maximumAddress = 4096

    private var configuration: Configuration
    private let player: any ReceiverPlayer
    private var server: HTTPServer?
    private var advertiser: ReceiverAdvertiser?
    private var eventTask: Task<Void, Never>?
    private nonisolated let eventFeed: AsyncStream<ReceiverPlayerEvent>.Continuation
    private let events: AsyncStream<ReceiverPlayerEvent>
    private let subscriptions: [ReceiverService: ReceiverSubscriptions] = [
        .avTransport: ReceiverSubscriptions(), .renderingControl: ReceiverSubscriptions(), .connectionManager: ReceiverSubscriptions(),
    ]

    public private(set) var port: UInt16 = 0
    public private(set) var isRunning = false
    private var state = TransportState.noMedia
    private var status = "OK"
    private var lastError: String?
    private var current: ReceiverTrack?
    private var next: ReceiverTrack?
    private var app = ReceiverControlApp()
    /// The player is playing (or holding, paused) a song of ours.
    private var sessionActive = false
    private var volume = 1.0
    private var muted = false
    private var sentTransport: [String: String] = [:]
    private var sentRendering: [String: String] = [:]

    public init(_ configuration: Configuration, player: any ReceiverPlayer) {
        self.configuration = configuration
        self.player = player
        (events, eventFeed) = AsyncStream<ReceiverPlayerEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public var snapshot: Snapshot { Snapshot(state: state, current: current, next: next, app: app, lastError: lastError) }

    /// The address of the description on `host` (for the Settings line and the tests).
    public func location(host: String) -> URL? { URL(string: "http://\(host):\(port)\(ReceiverDescription.descriptionPath)") }

    // MARK: Start and stop

    /// Opens the HTTP port and starts announcing. Until this is called the receiver has no socket and sends nothing.
    public func start() async throws {
        guard !isRunning else { return }
        let ownSubnetsOnly = configuration.ownSubnetsOnly
        let networks = configuration.networks
        let server = HTTPServer(maximumConnections: 32, admits: { peer in
            ownSubnetsOnly ? LocalNetworks.isOnOwnSubnet(peer, networks: networks()) : LocalNetworks.isPrivate(peer)
        }, handler: { [weak self] request in
            await self?.handle(request) ?? .status(503)
        })
        port = try await server.start(port: configuration.port)
        self.server = server
        ReceiverStreams.retain()
        if configuration.advertises {
            var settings = ReceiverAdvertiser.Configuration(udn: configuration.udn, httpPort: port, server: Self.serverHeader(version: configuration.version))
            settings.listenOn = configuration.listenOn
            settings.announceTo = configuration.announceTo
            settings.networks = networks
            if let delay = configuration.responseDelay { settings.responseDelay = delay }
            settings.answers = { peer in
                ownSubnetsOnly ? LocalNetworks.isOnOwnSubnet(peer, networks: networks()) : LocalNetworks.isPrivate(peer)
            }
            let advertiser = ReceiverAdvertiser(settings)
            do {
                try advertiser.start()
            } catch {
                server.stop()
                self.server = nil
                port = 0
                ReceiverStreams.release()
                throw error
            }
            self.advertiser = advertiser
        }
        let level = await player.receiverVolume()
        volume = level.level
        muted = level.muted
        isRunning = true
        // A subscriber's first event is the whole state; after that only what changed since.
        sentTransport = Dictionary(transportVariables, uniquingKeysWith: { $1 })
        sentRendering = Dictionary(renderingVariables, uniquingKeysWith: { $1 })
        let events = events
        eventTask = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    /// Stops what a control app was playing, says goodbye on the network (ssdp:byebye) and closes every socket.
    /// `stoppingPlayer`: off when the player is being stopped by whoever asked (the app's quit sequence, which can't wait on it).
    public func stop(stoppingPlayer: Bool = true) async {
        guard isRunning else { return }
        isRunning = false
        if sessionActive {
            sessionActive = false
            if stoppingPlayer { await player.receiverStop() }
        }
        eventTask?.cancel()
        eventTask = nil
        advertiser?.stop()
        advertiser = nil
        subscriptions.values.forEach { $0.removeAll() }
        server?.stop()
        server = nil
        port = 0
        for track in [current, next].compactMap({ $0 }) { ReceiverStreams.remove(track.id) }
        current = nil
        next = nil
        state = .noMedia
        status = "OK"
        lastError = nil
        sentTransport = [:]
        sentRendering = [:]
        ReceiverStreams.release()
    }

    /// The UDP port searches are answered on (tests).
    public var searchPort: UInt16 { advertiser?.port ?? 0 }

    public func setAllowsVolume(_ allowed: Bool) {
        configuration.allowsVolume = allowed
        publish()
    }

    static func serverHeader(version: String) -> String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let clean = version.filter { $0.isNumber || $0 == "." }
        return "macOS/\(system.majorVersion).\(system.minorVersion) UPnP/1.1 Vespertine/\(clean.isEmpty ? "1" : clean)"
    }

    // MARK: The player's side

    /// Tells the receiver what the player did. Events are taken in the order they are given.
    public nonisolated func playerEvent(_ event: ReceiverPlayerEvent) { eventFeed.yield(event) }

    private func handle(_ event: ReceiverPlayerEvent) async {
        guard isRunning else { return }
        switch event {
        case .started(let id):
            if let following = next, following.id == id {
                // The song sent as next has begun, with no gap: it is the current one now.
                if let finished = current { ReceiverStreams.remove(finished.id) }
                current = following
                next = nil
            }
            guard current?.id == id else { return }
            sessionActive = true
            state = .playing
            status = "OK"
            lastError = nil
            if let duration = await player.receiverPosition().duration, duration > 0, current?.id == id { current?.info.duration = duration }
        case .paused:
            if sessionActive, state == .playing || state == .transitioning { state = .paused }
        case .resumed:
            if sessionActive, state == .paused { state = .playing }
        case .ended:
            guard sessionActive else { return }
            state = current == nil ? .noMedia : .stopped
        case .failed(let id, let message):
            guard id == nil || id == current?.id || id == next?.id else { return }
            if let id, id == next?.id, id != current?.id {
                // The song to follow can't be played: the one playing carries on, and nothing follows it.
                ReceiverStreams.remove(id)
                next = nil
            } else {
                state = current == nil ? .noMedia : .stopped
                status = "ERROR_OCCURRED"
            }
            lastError = message
            configuration.onRefusal?(message, app)
        case .tookOver:
            sessionActive = false
            if state != .noMedia { state = .stopped }
        case .volume(let level, let isMuted):
            volume = level
            muted = isMuted
        }
        publish()
    }

    // MARK: HTTP

    private func xml(_ text: String) -> HTTPResponse {
        let data = Data(text.utf8)
        return HTTPResponse(status: 200, headers: [("Content-Type", "text/xml; charset=\"utf-8\""), ("Content-Length", "\(data.count)"),
                                                   ("Server", Self.serverHeader(version: configuration.version))], body: .data(data))
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard isRunning else { return .status(503) }
        let path = request.path
        switch request.method {
        case "GET", "HEAD":
            if path == ReceiverDescription.descriptionPath {
                return xml(ReceiverDescription.device(udn: configuration.udn, name: configuration.name, version: configuration.version))
            }
            if let service = ReceiverService.allCases.first(where: { $0.scpdPath == path }) { return xml(ReceiverDescription.scpd(service)) }
            return .status(404)
        case "POST":
            guard let service = ReceiverService.allCases.first(where: { $0.controlPath == path }) else { return .status(404) }
            return await control(service, request)
        case "SUBSCRIBE":
            guard let service = ReceiverService.allCases.first(where: { $0.eventPath == path }) else { return .status(404) }
            return subscribe(service, request)
        case "UNSUBSCRIBE":
            guard let service = ReceiverService.allCases.first(where: { $0.eventPath == path }) else { return .status(404) }
            guard let sid = request.headers["sid"], request.headers["nt"] == nil, request.headers["callback"] == nil else { return .status(400) }
            return .status(subscriptions[service]?.unsubscribe(sid) == true ? 200 : 412)
        default:
            return .status(405)
        }
    }

    private func subscribe(_ service: ReceiverService, _ request: HTTPRequest) -> HTTPResponse {
        guard let list = subscriptions[service] else { return .status(404) }
        let seconds = ReceiverSubscriptions.timeout(request.headers["timeout"])
        let sid: String
        if let renewing = request.headers["sid"] {
            guard request.headers["nt"] == nil, request.headers["callback"] == nil else { return .status(400) }
            guard list.renew(renewing, seconds: seconds) else { return .status(412) }
            sid = renewing
        } else {
            guard request.headers["nt"] == "upnp:event" else { return .status(412) }
            guard let callback = ReceiverSubscriptions.callback(request.headers["callback"], peer: request.peer) else { return .status(412) }
            guard let made = list.subscribe(callback: callback, seconds: seconds, initial: initialEvent(service)) else { return .status(503) }
            sid = made
        }
        return HTTPResponse(status: 200, headers: [("SID", sid), ("TIMEOUT", "Second-\(seconds)"), ("Server", Self.serverHeader(version: configuration.version)),
                                                   ("Content-Length", "0")])
    }

    private struct Fault: Error {
        var code: Int
        var description: String
        static let invalidAction = Fault(code: 401, description: "Invalid Action")
        static let invalidArguments = Fault(code: 402, description: "Invalid Args")
        static let transition = Fault(code: 701, description: "Transition not available")
    }

    private func control(_ service: ReceiverService, _ request: HTTPRequest) async -> HTTPResponse {
        guard request.body.count <= Self.maximumSOAP else { return .status(413) }
        // "urn:schemas-upnp-org:service:AVTransport:1#Play", in quotes.
        let header = (request.headers["soapaction"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let parts = header.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == service.type, !parts[1].isEmpty, parts[1].count <= 64,
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return .status(400) }
        let action = String(parts[1])
        // A document type or entity declaration has no place in a call, and is how XML is made to misbehave.
        guard request.body.range(of: Data("<!DOCTYPE".utf8)) == nil, request.body.range(of: Data("<!ENTITY".utf8)) == nil,
              let arguments = SOAP.arguments(in: request.body, element: action) else { return .status(400) }
        let caller = ReceiverControlApp(name: ReceiverControlApp.name(fromUserAgent: request.headers["user-agent"]), address: request.peer)
        do {
            let result: [(String, String)]
            switch service {
            case .avTransport: result = try await avTransport(action, arguments, caller: caller)
            case .renderingControl: result = try await renderingControl(action, arguments)
            case .connectionManager: result = try connectionManager(action, arguments)
            }
            publish()
            let body = SOAP.response(serviceType: service.type, action: action, arguments: result)
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/xml; charset=\"utf-8\""), ("Content-Length", "\(body.count)"), ("EXT", ""),
                                                       ("Server", Self.serverHeader(version: configuration.version))], body: .data(body))
        } catch let fault as Fault {
            publish()
            let body = SOAP.fault(code: fault.code, description: fault.description)
            return HTTPResponse(status: 500, headers: [("Content-Type", "text/xml; charset=\"utf-8\""), ("Content-Length", "\(body.count)"), ("EXT", ""),
                                                       ("Server", Self.serverHeader(version: configuration.version))], body: .data(body))
        } catch {
            return .status(500)
        }
    }

    // MARK: AVTransport

    private func instance(_ arguments: [String: String], invalid: Int) throws {
        guard arguments["InstanceID"]?.trimmingCharacters(in: .whitespaces) == "0" else { throw Fault(code: invalid, description: "Invalid InstanceID") }
    }

    /// The UPnP error a refused stream is answered with; its description is the sentence the listener reads too.
    private static func fault(for refusal: StreamRefusal) -> Fault {
        let code: Int
        switch refusal {
        case .notHTTP, .forbiddenAddress, .forbiddenRedirect, .unreachable, .status, .empty: code = 716   // Resource not found
        case .segmented, .notDecodable: code = 714                                                         // Illegal MIME-type
        case .protected, .noRanges, .unknownLength: code = 704                                            // Format not supported for playback
        }
        return Fault(code: code, description: refusal.localizedDescription)
    }

    /// Checks the address a control app sent and asks it for its first bytes. Throws the fault to answer with when it is
    /// refused; the listener is told too.
    private func accept(address text: String, metadata: String, caller: ReceiverControlApp) async throws -> ReceiverTrack {
        func refuse(_ refusal: StreamRefusal) -> Fault {
            let fault = Self.fault(for: refusal)
            lastError = fault.description
            configuration.onRefusal?(fault.description, caller)
            return fault
        }
        guard text.utf8.count <= Self.maximumAddress else { throw Fault.invalidArguments }
        guard let address = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = address.scheme?.lowercased() else { throw Fault.invalidArguments }
        guard scheme == "http" || scheme == "https" else { throw refuse(.notHTTP) }
        let described: ReceivedMetadata?
        do {
            described = try ReceivedMetadata.parse(metadata)
        } catch {
            let words = String(localized: "The control app’s description of the song couldn’t be read.", comment: "A UPnP control app sent a song with malformed metadata.")
            lastError = words
            configuration.onRefusal?(words, caller)
            throw Fault(code: 402, description: words)
        }
        let options = HTTPStreamReader.Options(policy: configuration.streamPolicy, notAnsweringMessage: ReceiverStreams.notAnswering,
                                               fallbackExtension: ReceiverDescription.fileExtension(forMediaType: described?.mediaType))
        // Asking the address blocks until it answers: never on this actor's thread.
        let opened: Result<HTTPStreamReader, StreamRefusal> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: .success(try HTTPStreamReader(url: address, options: options)))
                } catch let refusal as StreamRefusal {
                    continuation.resume(returning: .failure(refusal))
                } catch {
                    continuation.resume(returning: .failure(.unreachable(error.localizedDescription)))
                }
            }
        }
        let reader: HTTPStreamReader
        switch opened {
        case .success(let made): reader = made
        case .failure(let refusal): throw refuse(refusal)
        }
        guard isRunning else { reader.cancel(); throw Fault.transition }
        let title = described?.title ?? address.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
        let info = RendererTrackInfo(title: title.isEmpty ? String(localized: "Untitled", comment: "A song sent by a control app with no title.") : title,
                                     artist: described?.artist, album: described?.album, artworkURL: described?.artworkURL, duration: described?.duration)
        let track = ReceiverTrack(address: address, info: info, mediaType: described?.mediaType ?? reader.mediaType,
                                  metadata: described == nil ? "" : metadata)
        ReceiverStreams.add(track.id, address: address, options: options, checked: reader)
        return track
    }

    private func avTransport(_ action: String, _ arguments: [String: String], caller: ReceiverControlApp) async throws -> [(String, String)] {
        try instance(arguments, invalid: 718)
        switch action {
        case "SetAVTransportURI":
            guard let address = arguments["CurrentURI"] else { throw Fault.invalidArguments }
            let previous = current
            if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Nothing to play any more.
                current = nil
                if let old = next { ReceiverStreams.remove(old.id); next = nil }
                if sessionActive { sessionActive = false; await player.receiverStop() }
                if let previous { ReceiverStreams.remove(previous.id) }
                state = .noMedia
                return []
            }
            let track = try await accept(address: address, metadata: arguments["CurrentURIMetaData"] ?? "", caller: caller)
            app = caller
            current = track
            status = "OK"
            lastError = nil
            // A new current song takes the place of whatever was to follow the old one.
            if let old = next { ReceiverStreams.remove(old.id); next = nil }
            if state == .playing || state == .transitioning {
                // A song sent while one plays is played at once (AVTransport:1, 2.4.1).
                state = .transitioning
                sessionActive = true
                await player.receiverPlay(track, next: nil, from: app)
            } else {
                if state == .paused, sessionActive { sessionActive = false; await player.receiverStop() }
                state = .stopped
            }
            if let previous { ReceiverStreams.remove(previous.id) }
            return []
        case "SetNextAVTransportURI":
            guard let address = arguments["NextURI"] else { throw Fault.invalidArguments }
            let previous = next
            if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                next = nil
            } else {
                next = try await accept(address: address, metadata: arguments["NextURIMetaData"] ?? "", caller: caller)
            }
            if let previous { ReceiverStreams.remove(previous.id) }
            if sessionActive, state == .playing || state == .paused || state == .transitioning { await player.receiverSetNext(next) }
            return []
        case "Play":
            guard arguments["Speed"] == nil || arguments["Speed"] == "1" else { throw Fault(code: 717, description: "Play speed not supported") }
            guard let track = current else { throw Fault(code: 702, description: "No contents") }
            switch state {
            case .playing, .transitioning:
                break
            case .paused where sessionActive:
                state = .playing
                await player.receiverResume()
            default:
                app = caller
                state = .transitioning
                status = "OK"
                lastError = nil
                sessionActive = true
                await player.receiverPlay(track, next: next, from: app)
            }
            return []
        case "Pause":
            switch state {
            case .playing, .transitioning:
                guard sessionActive else { throw Fault.transition }
                state = .paused
                await player.receiverPause()
            case .paused:
                break
            default:
                throw Fault.transition
            }
            return []
        case "Stop":
            if sessionActive {
                sessionActive = false
                await player.receiverStop()
            }
            state = current == nil ? .noMedia : .stopped
            return []
        case "Seek":
            guard sessionActive, state == .playing || state == .paused else { throw Fault.transition }
            let unit = arguments["Unit"] ?? ""
            let target = arguments["Target"] ?? ""
            switch unit {
            case "REL_TIME", "ABS_TIME":
                guard let seconds = DIDLLite.seconds(target), seconds.isFinite, seconds >= 0 else { throw Fault(code: 711, description: "Illegal seek target") }
                if let duration = current?.info.duration, seconds > duration + 1 { throw Fault(code: 711, description: "Illegal seek target") }
                await player.receiverSeek(to: seconds)
            case "TRACK_NR":
                guard target.trimmingCharacters(in: .whitespaces) == "1" else { throw Fault(code: 711, description: "Illegal seek target") }
                await player.receiverSeek(to: 0)
            default:
                throw Fault(code: 710, description: "Seek mode not supported")
            }
            return []
        case "Next":
            guard let following = next else { throw Fault(code: 711, description: "Illegal seek target") }
            let finished = current
            current = following
            next = nil
            state = .transitioning
            sessionActive = true
            await player.receiverPlay(following, next: nil, from: app)
            if let finished { ReceiverStreams.remove(finished.id) }
            return []
        case "Previous":
            guard sessionActive, state == .playing || state == .paused else { throw Fault.transition }
            await player.receiverSeek(to: 0)
            return []
        case "GetTransportInfo":
            return [("CurrentTransportState", state.rawValue), ("CurrentTransportStatus", status), ("CurrentSpeed", "1")]
        case "GetPositionInfo":
            guard let track = current else {
                return [("Track", "0"), ("TrackDuration", "0:00:00"), ("TrackMetaData", ""), ("TrackURI", ""), ("RelTime", "0:00:00"),
                        ("AbsTime", "0:00:00"), ("RelCount", "2147483647"), ("AbsCount", "2147483647")]
            }
            var position = ReceiverPosition(position: 0, duration: track.info.duration)
            if sessionActive, state == .playing || state == .paused {
                let live = await player.receiverPosition()
                position.position = live.position
                if let duration = live.duration, duration > 0 { position.duration = duration }
            }
            let time = Self.clock(position.position)
            return [("Track", "1"), ("TrackDuration", Self.clock(position.duration ?? 0)), ("TrackMetaData", track.metadata),
                    ("TrackURI", track.address.absoluteString), ("RelTime", time), ("AbsTime", time), ("RelCount", "2147483647"), ("AbsCount", "2147483647")]
        case "GetMediaInfo":
            return [("NrTracks", current == nil ? "0" : "1"), ("MediaDuration", Self.clock(current?.info.duration ?? 0)),
                    ("CurrentURI", current?.address.absoluteString ?? ""), ("CurrentURIMetaData", current?.metadata ?? ""),
                    ("NextURI", next?.address.absoluteString ?? ""), ("NextURIMetaData", next?.metadata ?? ""),
                    ("PlayMedium", current == nil ? "NONE" : "NETWORK"), ("RecordMedium", "NOT_IMPLEMENTED"), ("WriteStatus", "NOT_IMPLEMENTED")]
        case "GetDeviceCapabilities":
            return [("PlayMedia", "NETWORK"), ("RecMedia", "NOT_IMPLEMENTED"), ("RecQualityModes", "NOT_IMPLEMENTED")]
        case "GetTransportSettings":
            return [("PlayMode", "NORMAL"), ("RecQualityMode", "NOT_IMPLEMENTED")]
        case "GetCurrentTransportActions":
            return [("Actions", transportActions)]
        default:
            throw Fault.invalidAction
        }
    }

    /// "H:MM:SS", whole seconds (the form every control app reads).
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
    }

    private var transportActions: String {
        switch state {
        case .playing, .transitioning: next == nil ? "Pause,Stop,Seek,Previous" : "Pause,Stop,Seek,Next,Previous"
        case .paused: "Play,Stop,Seek"
        case .stopped: "Play"
        case .noMedia: ""
        }
    }

    // MARK: RenderingControl

    /// What control apps are told the volume is: the listener's own when they may set it, otherwise full and fixed.
    private var shownVolume: Int { configuration.allowsVolume ? Int((min(max(volume, 0), 1) * 100).rounded()) : 100 }
    private var shownMute: Bool { configuration.allowsVolume && muted }

    private func renderingControl(_ action: String, _ arguments: [String: String]) async throws -> [(String, String)] {
        try instance(arguments, invalid: 702)
        func master() throws {
            guard (arguments["Channel"] ?? "Master") == "Master" else { throw Fault.invalidArguments }
        }
        switch action {
        case "ListPresets":
            return [("CurrentPresetNameList", "FactoryDefaults")]
        case "SelectPreset":
            guard arguments["PresetName"] == "FactoryDefaults" else { throw Fault(code: 701, description: "Invalid Name") }
            return []
        case "GetVolume":
            try master()
            return [("CurrentVolume", String(shownVolume))]
        case "SetVolume":
            try master()
            guard let wanted = Int(arguments["DesiredVolume"] ?? ""), (0...100).contains(wanted) else { throw Fault.invalidArguments }
            // Fixed unless the listener lets control apps set it: the call is answered, and nothing changes.
            if configuration.allowsVolume {
                volume = Double(wanted) / 100
                await player.receiverSetVolume(volume)
            }
            return []
        case "GetMute":
            try master()
            return [("CurrentMute", shownMute ? "1" : "0")]
        case "SetMute":
            try master()
            let wanted: Bool
            switch (arguments["DesiredMute"] ?? "").lowercased() {
            case "1", "true", "yes": wanted = true
            case "0", "false", "no": wanted = false
            default: throw Fault.invalidArguments
            }
            if configuration.allowsVolume {
                muted = wanted
                await player.receiverSetMuted(wanted)
            }
            return []
        default:
            throw Fault.invalidAction
        }
    }

    // MARK: ConnectionManager

    private func connectionManager(_ action: String, _ arguments: [String: String]) throws -> [(String, String)] {
        switch action {
        case "GetProtocolInfo":
            return [("Source", ""), ("Sink", ReceiverDescription.sinkProtocolInfo)]
        case "GetCurrentConnectionIDs":
            return [("ConnectionIDs", "0")]
        case "GetCurrentConnectionInfo":
            guard arguments["ConnectionID"]?.trimmingCharacters(in: .whitespaces) == "0" else { throw Fault(code: 706, description: "Invalid connection reference") }
            return [("RcsID", "0"), ("AVTransportID", "0"), ("ProtocolInfo", ""), ("PeerConnectionManager", ""), ("PeerConnectionID", "-1"),
                    ("Direction", "Input"), ("Status", "OK")]
        default:
            throw Fault.invalidAction
        }
    }

    // MARK: Events

    private var transportVariables: [(String, String)] {
        [("TransportState", state.rawValue), ("TransportStatus", status), ("PlaybackStorageMedium", current == nil ? "NONE" : "NETWORK"),
         ("CurrentPlayMode", "NORMAL"), ("TransportPlaySpeed", "1"), ("NumberOfTracks", current == nil ? "0" : "1"),
         ("CurrentTrack", current == nil ? "0" : "1"), ("CurrentTrackDuration", Self.clock(current?.info.duration ?? 0)),
         ("CurrentMediaDuration", Self.clock(current?.info.duration ?? 0)), ("CurrentTrackURI", current?.address.absoluteString ?? ""),
         ("AVTransportURI", current?.address.absoluteString ?? ""), ("CurrentTrackMetaData", current?.metadata ?? ""),
         ("AVTransportURIMetaData", current?.metadata ?? ""), ("NextAVTransportURI", next?.address.absoluteString ?? ""),
         ("NextAVTransportURIMetaData", next?.metadata ?? ""), ("CurrentTransportActions", transportActions)]
    }

    private var renderingVariables: [(String, String)] {
        [("Volume", String(shownVolume)), ("Mute", shownMute ? "1" : "0"), ("PresetNameList", "FactoryDefaults")]
    }

    private func initialEvent(_ service: ReceiverService) -> Data {
        switch service {
        case .avTransport:
            return ReceiverEventBody.lastChange(namespace: ReceiverEventBody.avTransportNamespace,
                                                variables: transportVariables.map { ($0.0, $0.1, nil) })
        case .renderingControl:
            return ReceiverEventBody.lastChange(namespace: ReceiverEventBody.renderingControlNamespace,
                                                variables: renderingVariables.map { ($0.0, $0.1, $0.0 == "PresetNameList" ? nil : "Master") })
        case .connectionManager:
            return ReceiverEventBody.propertySet([("SourceProtocolInfo", ""), ("SinkProtocolInfo", ReceiverDescription.sinkProtocolInfo), ("CurrentConnectionIDs", "0")])
        }
    }

    /// Sends subscribers whatever differs from what they were last told.
    private func publish() {
        guard isRunning else { return }
        let transport = transportVariables.filter { sentTransport[$0.0] != $0.1 }
        if !transport.isEmpty {
            for (name, value) in transport { sentTransport[name] = value }
            subscriptions[.avTransport]?.send(ReceiverEventBody.lastChange(namespace: ReceiverEventBody.avTransportNamespace,
                                                                           variables: transport.map { ($0.0, $0.1, nil) }))
        }
        let rendering = renderingVariables.filter { sentRendering[$0.0] != $0.1 }
        if !rendering.isEmpty {
            for (name, value) in rendering { sentRendering[name] = value }
            subscriptions[.renderingControl]?.send(ReceiverEventBody.lastChange(namespace: ReceiverEventBody.renderingControlNamespace,
                                                                                variables: rendering.map { ($0.0, $0.1, $0.0 == "PresetNameList" ? nil : "Master") }))
        }
    }
}
