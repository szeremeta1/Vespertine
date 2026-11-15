//
// Vespertine: a song at an http or https address (sent by a control app, or served by a music server), read by byte ranges into
// the transient playback cache like a share's file. It says in plain words why an address is refused, and never follows one to
// this Mac itself or to a link-local address unless its owner says the address is the listener's own.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation

/// Why a stream was refused. The description is what the listener reads, and what a control app is told.
public enum StreamRefusal: Error, LocalizedError, Equatable, Sendable {
    /// Not http or https (`file:`, `rtsp:`…).
    case notHTTP
    /// The address is this Mac, a link-local address, or no address a stream can come from.
    case forbiddenAddress
    /// The server redirected to an address that is refused.
    case forbiddenRedirect
    case status(Int)
    /// The server sends the whole stream or nothing: no reading from the middle.
    case noRanges
    /// No length is stated (a live or converted stream).
    case unknownLength
    case empty
    /// Copy-protected: only the app it came from can play it.
    case protected
    /// A list of segments (HLS, DASH), not one audio file.
    case segmented
    /// Not audio the engine decodes; the type the server gave, if it gave one.
    case notDecodable(String?)
    /// Nothing answered at the address: the system's reason.
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .notHTTP:
            String(localized: "Only http and https addresses can be played.", comment: "A control app sent an address of another kind (file, rtsp).")
        case .forbiddenAddress:
            String(localized: "The address points at this Mac itself or at a link-local address, so it wasn’t opened.", comment: "A control app sent a song address that Vespertine refuses for safety.")
        case .forbiddenRedirect:
            String(localized: "The server redirected to this Mac itself or to a link-local address, so it wasn’t followed.", comment: "A song's server redirected to an address Vespertine refuses for safety.")
        case .status(let code):
            String(localized: "The server answered with HTTP status \(String(code)).", comment: "A stream’s server answered with an error. %@ is the HTTP status code, such as 404.")
        case .noRanges:
            String(localized: "The server doesn’t allow reading from the middle of a stream, which playing and seeking need.", comment: "The server has no HTTP range requests.")
        case .unknownLength:
            String(localized: "The stream doesn’t say how long it is (a live or converted stream).", comment: "An HTTP stream with no length can't be played.")
        case .empty:
            String(localized: "The stream is empty.", comment: "An HTTP stream of zero bytes.")
        case .protected:
            String(localized: "The stream is copy-protected (DRM), so only the app it came from can play it.", comment: "A DRM-protected stream was sent to Vespertine.")
        case .segmented:
            String(localized: "This is a list of segments (HLS or DASH), not one audio file.", comment: "A control app sent a segmented stream's playlist.")
        case .notDecodable(let type?):
            String(localized: "The stream is in a format Vespertine can’t decode (\(type)).", comment: "%@ is a media type such as video/mp4.")
        case .notDecodable(nil):
            String(localized: "The stream is in a format Vespertine can’t decode.", comment: "A stream whose format is unknown.")
        case .unreachable(let reason):
            String(localized: "The address didn’t answer: \(reason)", comment: "%@ is the system's reason, such as “Could not connect to the server.”")
        }
    }
}

/// Which addresses a stream may be fetched from.
public struct StreamAddressPolicy: Sendable, Equatable {
    /// 127.0.0.0/8 and ::1.
    public var allowsLoopback: Bool
    /// 169.254.0.0/16 and fe80::/10.
    public var allowsLinkLocal: Bool

    public init(allowsLoopback: Bool, allowsLinkLocal: Bool) {
        self.allowsLoopback = allowsLoopback
        self.allowsLinkLocal = allowsLinkLocal
    }

    /// What something else on the network may point Vespertine at: never this Mac itself, never a link-local address.
    public static let fromTheNetwork = StreamAddressPolicy(allowsLoopback: false, allowsLinkLocal: false)
    /// An address the listener typed in (their own server, which may well run on this Mac).
    public static let listenersOwn = StreamAddressPolicy(allowsLoopback: true, allowsLinkLocal: true)

    /// What kind of address `bytes` (4 for IPv4, 16 for IPv6, network order) is.
    public enum AddressKind: Sendable, Equatable { case loopback, linkLocal, unusable, routable }

    public static func kind(ofIPv4 a: [UInt8]) -> AddressKind {
        guard a.count == 4 else { return .unusable }
        if a[0] == 127 { return .loopback }
        if a[0] == 169, a[1] == 254 { return .linkLocal }
        // "This network", multicast, reserved and broadcast: nothing a stream comes from.
        if a[0] == 0 || a[0] >= 224 { return .unusable }
        return .routable
    }

    public static func kind(ofIPv6 a: [UInt8]) -> AddressKind {
        guard a.count == 16 else { return .unusable }
        if a[0..<15].allSatisfy({ $0 == 0 }) { return a[15] == 1 ? .loopback : .unusable }
        // IPv4-mapped (::ffff:a.b.c.d) and the NAT64 well-known prefix (64:ff9b::/96) carry an IPv4 address: judged as that.
        if a[0..<10].allSatisfy({ $0 == 0 }), a[10] == 0xff, a[11] == 0xff { return kind(ofIPv4: Array(a[12..<16])) }
        if a[0] == 0x00, a[1] == 0x64, a[2] == 0xff, a[3] == 0x9b, a[4..<12].allSatisfy({ $0 == 0 }) { return kind(ofIPv4: Array(a[12..<16])) }
        if a[0] == 0xfe, a[1] & 0xc0 == 0x80 { return .linkLocal }
        if a[0] == 0xff { return .unusable }
        return .routable
    }

    func admits(_ kind: AddressKind) -> Bool {
        switch kind {
        case .loopback: allowsLoopback
        case .linkLocal: allowsLinkLocal
        case .unusable: false
        case .routable: true
        }
    }

    /// The addresses `host` names: itself when it is an address, else what the resolver answers (this asks the network, so never
    /// on the main thread).
    public static func addresses(of host: String) -> [[UInt8]] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        // A scoped IPv6 literal arrives as "fe80::1%en0"; the brackets of a URL's host are already gone.
        guard getaddrinfo(host, nil, &hints, &info) == 0 else { return [] }
        defer { freeaddrinfo(info) }
        var found: [[UInt8]] = []
        var next = info
        while let entry = next {
            if entry.pointee.ai_family == AF_INET, let address = entry.pointee.ai_addr {
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                    withUnsafeBytes(of: p.pointee.sin_addr) { found.append(Array($0)) }
                }
            } else if entry.pointee.ai_family == AF_INET6, let address = entry.pointee.ai_addr {
                address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                    withUnsafeBytes(of: p.pointee.sin6_addr) { found.append(Array($0)) }
                }
            }
            next = entry.pointee.ai_next
        }
        return found
    }

    /// Throws unless `url` is http or https and every address its host names is one this policy admits. A name that resolves
    /// to several addresses is refused if any of them is refused: which one would be used is not ours to choose.
    public func check(_ url: URL, redirect: Bool = false) throws(StreamRefusal) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw .notHTTP }
        guard var host = url.host, !host.isEmpty else { throw .notHTTP }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let addresses = Self.addresses(of: host)
        guard !addresses.isEmpty else {
            throw .unreachable(String(localized: "Its name couldn’t be found on the network.", comment: "A whole sentence shown after “The address didn’t answer:” when a host name doesn't resolve."))
        }
        for address in addresses {
            let kind = address.count == 4 ? Self.kind(ofIPv4: address) : Self.kind(ofIPv6: address)
            if !admits(kind) { throw redirect ? .forbiddenRedirect : .forbiddenAddress }
        }
    }
}

/// What a stream's first bytes say it is.
public enum StreamSniffer {
    public enum Finding: Sendable, Equatable {
        /// A container the engine opens, by the file extension its decoders go by.
        case audio(fileExtension: String)
        case protected
        case segmented
        case unknown
    }

    private static func has(_ data: Data, _ text: String, at offset: Int = 0) -> Bool {
        let bytes = Array(text.utf8)
        guard data.count >= offset + bytes.count else { return false }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + bytes.count)).elementsEqual(bytes)
    }

    private static func contains(_ data: Data, _ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

    public static func sniff(_ head: Data) -> Finding {
        var data = head
        // An ID3v2 tag may sit in front of MP3 frames, and sometimes in front of a FLAC stream.
        if has(data, "ID3"), data.count >= 10 {
            let b = [UInt8](data.prefix(10))
            let size = Int(b[6] & 0x7f) << 21 | Int(b[7] & 0x7f) << 14 | Int(b[8] & 0x7f) << 7 | Int(b[9] & 0x7f)
            guard data.count > 10 + size else { return .audio(fileExtension: "mp3") }
            data = data.subdata(in: (data.startIndex + 10 + size)..<data.endIndex)
            if !has(data, "fLaC") { return .audio(fileExtension: "mp3") }
        }
        if has(data, "fLaC") { return .audio(fileExtension: "flac") }
        if has(data, "RIFF") || has(data, "RF64") || has(data, "BW64") { return has(data, "WAVE", at: 8) ? .audio(fileExtension: "wav") : .unknown }
        if has(data, "FORM") { return has(data, "AIFF", at: 8) || has(data, "AIFC", at: 8) ? .audio(fileExtension: "aiff") : .unknown }
        if has(data, "DSD ") { return .audio(fileExtension: "dsf") }
        if has(data, "FRM8") { return has(data, "DSD ", at: 12) ? .audio(fileExtension: "dff") : .unknown }
        if has(data, "OggS") { return .audio(fileExtension: contains(data.prefix(256), "OpusHead") ? "opus" : "ogg") }
        if has(data, "MAC ") { return .audio(fileExtension: "ape") }
        if has(data, "wvpk") { return .audio(fileExtension: "wv") }
        if has(data, "TTA1") { return .audio(fileExtension: "tta") }
        if has(data, "tBaK") { return .audio(fileExtension: "tak") }
        if has(data, "caff") { return .audio(fileExtension: "caf") }
        if has(data, "ftyp", at: 4) {
            // An encrypted sample entry or a protection header: a DRM stream.
            if contains(data, "enca") || contains(data, "encv") || contains(data, "pssh") { return .protected }
            // A fragmented stream's first segment alone is no song.
            if contains(data, "styp") || has(data, "dash", at: 8) || has(data, "msdh", at: 8) { return .segmented }
            return .audio(fileExtension: "m4a")
        }
        if data.count >= 4, [UInt8](data.prefix(4)) == [0x1a, 0x45, 0xdf, 0xa3] { return .audio(fileExtension: "mka") }
        let text = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#EXTM3U") { return .segmented }
        if text.hasPrefix("<?xml") || text.hasPrefix("<MPD") || text.hasPrefix("<SmoothStreamingMedia") {
            return text.contains("<MPD") || text.contains("SmoothStreamingMedia") ? .segmented : .unknown
        }
        if data.count >= 2 {
            let b = [UInt8](data.prefix(2))
            if b[0] == 0xff, b[1] & 0xf6 == 0xf0 { return .audio(fileExtension: "aac") }       // ADTS
            if b[0] == 0xff, b[1] & 0xe0 == 0xe0 { return .audio(fileExtension: "mp3") }       // an MPEG audio frame
        }
        return .unknown
    }

    /// A media type that names protection or segments, whatever the bytes are.
    public static func finding(forMediaType type: String?) -> Finding? {
        guard let type = type?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if type.contains("dtcp") || type.contains("playready") || type.contains("widevine") || type.contains("fairplay") { return .protected }
        if type == "application/vnd.apple.mpegurl" || type == "application/x-mpegurl" || type == "audio/mpegurl" || type == "audio/x-mpegurl"
            || type == "application/dash+xml" || type == "application/vnd.ms-sstr+xml" { return .segmented }
        return nil
    }
}

/// A song at an http(s) address, read by ranges. Opening it asks for its first bytes (blocking: call it off the main thread).
public final class HTTPStreamReader: NSObject, RemoteCacheReader, URLSessionDataDelegate, @unchecked Sendable {
    public struct Options: Sendable {
        public var policy: StreamAddressPolicy
        /// Sent with every request (an authorisation the caller holds). Never logged.
        public var headers: [String: String]
        /// How long one request may go without a byte before it is made again.
        public var idleTimeout: TimeInterval
        public var notAnsweringMessage: String?
        /// How long a listener waits with nothing from the server before the song is given up (nil: the playback cache's limit).
        /// With it, a server that can't be reached when the song is opened is "not answering" too, so playback stops there
        /// instead of trying each song after it.
        public var silenceLimit: TimeInterval?
        /// The file extension to go by when the bytes don't say (from the media type a control app named).
        public var fallbackExtension: String?

        public init(policy: StreamAddressPolicy = .fromTheNetwork, headers: [String: String] = [:], idleTimeout: TimeInterval = 15,
                    notAnsweringMessage: String? = nil, silenceLimit: TimeInterval? = nil, fallbackExtension: String? = nil) {
            self.policy = policy
            self.headers = headers
            self.idleTimeout = idleTimeout
            self.notAnsweringMessage = notAnsweringMessage
            self.silenceLimit = silenceLimit
            self.fallbackExtension = fallbackExtension
        }
    }

    /// The first request asks for this much: enough to tell what the stream is.
    static let probeBytes = 64 << 10

    public let url: URL
    public let size: Int64
    public let fileExtension: String
    /// The media type the server gave for the stream, in lower case without parameters.
    public let mediaType: String?
    public let notAnsweringMessage: String?
    public var silenceLimit: TimeInterval? { options.silenceLimit }
    /// Counted only while a read is asked of the server (its retries included): from the server's last byte, or from when the
    /// asking began. A read that is tried again, and a new read begun while another still waits, do not begin it again.
    public var quietFor: TimeInterval? {
        lock.withLock { reading > 0 ? max(0, uptime() - max(lastByteAt, askedSince)) : 0 }
    }
    /// When the server last sent a byte of the song (on `uptime`). An error page is not the song. Under `lock`.
    private var lastByteAt = ProcessInfo.processInfo.systemUptime
    /// Reads of the server in flight, and when the first of them began (on `uptime`). Under `lock`.
    private var reading = 0
    private var askedSince = ProcessInfo.processInfo.systemUptime
    /// Under `lock`.
    private var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Tests count the server's silence on a clock of their own, from now.
    func countSilence(on clock: @escaping @Sendable () -> TimeInterval) {
        lock.withLock { uptime = clock; lastByteAt = clock(); askedSince = lastByteAt }
    }
    private let options: Options
    private var session: URLSession!
    private let head: Data

    private final class Pending {
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        /// A full answer (200) to a request for a part: stopped at once, nothing kept.
        var wholeBody = false
        let wanted: Int
        let done = DispatchSemaphore(value: 0)
        init(wanted: Int) { self.wanted = wanted }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var cancelled = false
    private var refusedRedirect = false
    private let wake = NSCondition()

    public init(url: URL, options: Options = Options()) throws {
        self.url = url
        self.options = options
        notAnsweringMessage = options.notAnsweringMessage
        try options.policy.check(url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = options.silenceLimit.map { min($0, options.idleTimeout) } ?? options.idleTimeout
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        (size, fileExtension, mediaType, head) = try Probe(url: url, options: options, configuration: configuration).run()
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session?.invalidateAndCancel() }

    public func cancel() {
        lock.withLock { cancelled = true }
        // Each request in flight ends with an error, which wakes the read that waits on it.
        session.getAllTasks { $0.forEach { $0.cancel() } }
        wake.withLock { wake.broadcast() }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let end = min(size, offset + Int64(count))
        if end <= Int64(head.count) { return head.subdata(in: Int(offset)..<Int(end)) }
        lock.withLock {
            if reading == 0 { askedSince = uptime() }
            reading += 1
        }
        defer { lock.withLock { reading -= 1 } }
        // A link that drops or a server that stalls is tried again at the same offset for as long as the copy lets it: the
        // cache gives the song up after its own limit without a byte, and cancels this reader then.
        while true {
            if isCancelled { throw CancellationError() }
            do {
                return try fetch(offset: offset, end: end)
            } catch let refusal as StreamRefusal {
                // A busy or restarting server (5xx) may answer the next time; anything else it said is its answer.
                guard case .status(let code) = refusal, code >= 500 else { throw refusal }
            } catch let error as URLError where Self.isTransient(error) {
                // Tried again below.
            }
            wake.withLock { if !cancelled { _ = wake.wait(until: Date().addingTimeInterval(0.5)) } }
        }
    }

    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed:
            true
        default:
            false
        }
    }

    private func fetch(offset: Int64, end: Int64) throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: options.idleTimeout)
        for (name, value) in options.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(offset)-\(end - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let wanted = Int(end - offset)
        let task = session.dataTask(with: request)
        let state = Pending(wanted: wanted)
        let refused = lock.withLock { () -> Bool in
            if cancelled { return true }
            pending[task.taskIdentifier] = state
            return false
        }
        if refused { throw CancellationError() }
        task.resume()
        state.done.wait()
        lock.withLock { pending[task.taskIdentifier] = nil }
        if isCancelled { throw CancellationError() }
        if lock.withLock({ refusedRedirect }) { throw StreamRefusal.forbiddenRedirect }
        if state.wholeBody { throw StreamRefusal.noRanges }
        if let error = state.error {
            if let urlError = error as? URLError { throw urlError }
            throw StreamRefusal.unreachable(error.localizedDescription)
        }
        guard let response = state.response else { throw URLError(.badServerResponse) }
        guard response.statusCode == 206 else { throw StreamRefusal.status(response.statusCode) }
        // The stream was replaced on the server since it was opened: what was copied so far does not belong with this.
        if let total = Self.total(of: response), total != size { throw NetworkPlaybackCache.Failure.changed }
        guard state.data.count == wanted else { throw URLError(.networkConnectionLost) }
        return state.data
    }

    /// The whole length in a `Content-Range: bytes a-b/total` header; nil when it is `*` or missing.
    static func total(of response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"), let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    // MARK: URLSession

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let state = lock.withLock { pending[dataTask.taskIdentifier] }
        state?.response = response as? HTTPURLResponse
        // The whole stream in answer to a request for a part is never taken into memory.
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            state?.wholeBody = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = lock.withLock({ () -> Pending? in
            let state = pending[dataTask.taskIdentifier]
            if state?.response?.statusCode == 206 { lastByteAt = uptime() }
            return state
        }) else { return }
        state.data.append(data)
        // More than was asked for: a server that ignores the end of the range.
        if state.data.count > state.wanted { dataTask.cancel() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = lock.withLock({ pending[task.taskIdentifier] }) else { return }
        if state.data.count > state.wanted { state.data = state.data.prefix(state.wanted) } else { state.error = error }
        if state.wholeBody { state.error = nil }
        state.done.signal()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let target = request.url, (try? options.policy.check(target, redirect: true)) != nil else {
            lock.withLock { refusedRedirect = true }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// The first request: how long the stream is, what it is, and its first bytes.
    private final class Probe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let url: URL
        let options: Options
        let configuration: URLSessionConfiguration
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()
        private var response: HTTPURLResponse?
        private var error: Error?
        private var refusedRedirect = false
        private var wholeBodyTooLong = false
        /// The request was ended here once enough had arrived: its "cancelled" is no failure.
        private var stoppedHere = false

        init(url: URL, options: Options, configuration: URLSessionConfiguration) {
            self.url = url
            self.options = options
            self.configuration = configuration
        }

        func run() throws -> (Int64, String, String?, Data) {
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeoutIntervalForRequest)
            for (name, value) in options.headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("bytes=0-\(HTTPStreamReader.probeBytes - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            session.dataTask(with: request).resume()
            done.wait()
            if refusedRedirect { throw StreamRefusal.forbiddenRedirect }
            if wholeBodyTooLong {
                throw response?.expectedContentLength ?? -1 < 0 ? StreamRefusal.unknownLength : StreamRefusal.noRanges
            }
            if let error {
                // A server that is not there (refused, timed out, no route) is the same silence as one that stops mid-song.
                if options.silenceLimit != nil, let gone = error as? URLError, HTTPStreamReader.isTransient(gone) {
                    throw NetworkPlaybackCache.Failure.notAnswering(options.notAnsweringMessage)
                }
                throw StreamRefusal.unreachable(error.localizedDescription)
            }
            guard let response else { throw StreamRefusal.unreachable(URLError(.badServerResponse).localizedDescription) }
            let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let size: Int64
            switch response.statusCode {
            case 206:
                guard let total = HTTPStreamReader.total(of: response) else { throw StreamRefusal.unknownLength }
                size = total
            case 200:
                // A short stream sent whole: all of it is here.
                size = Int64(data.count)
            case 416:
                throw StreamRefusal.empty
            default:
                throw StreamRefusal.status(response.statusCode)
            }
            guard size > 0, !data.isEmpty else { throw StreamRefusal.empty }
            switch StreamSniffer.finding(forMediaType: type) ?? StreamSniffer.sniff(data) {
            case .protected: throw StreamRefusal.protected
            case .segmented: throw StreamRefusal.segmented
            case .audio(let ext): return (size, ext, type, data)
            case .unknown:
                if let type, type.hasPrefix("video/") || type.hasPrefix("image/") || type.hasPrefix("text/") { throw StreamRefusal.notDecodable(type) }
                // Not recognised by its first bytes: the decoders are asked, under the extension its address or its sender names.
                let named = url.pathExtension.lowercased()
                guard let ext = named.isEmpty ? options.fallbackExtension : named, !ext.isEmpty else { throw StreamRefusal.notDecodable(type) }
                return (size, ext, type, data)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                // Without ranges only a stream that fits in the first request is taken; a longer one is stopped here.
                let length = http.expectedContentLength
                if length < 0 || length > Int64(HTTPStreamReader.probeBytes) {
                    wholeBodyTooLong = true
                    completionHandler(.cancel)
                    return
                }
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.data.append(data)
            if self.data.count > HTTPStreamReader.probeBytes {
                self.data = self.data.prefix(HTTPStreamReader.probeBytes)
                stoppedHere = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if !wholeBodyTooLong, !stoppedHere { self.error = error }
            done.signal()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let target = request.url, (try? options.policy.check(target, redirect: true)) != nil else {
                refusedRedirect = true
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
