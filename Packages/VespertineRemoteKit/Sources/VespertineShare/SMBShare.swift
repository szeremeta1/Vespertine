//
// Vespertine: a share as the library sees it: folders to list and files to read ranges of, by path. Connects when first
// needed, connects again when the line has dropped (the phone changed networks, the server restarted) and carries on
// with the same request.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// Where a share is and who signs in to it. The password is kept apart, in the Keychain.
public struct ShareAddress: Codable, Hashable, Sendable {
    /// A name or address: `nas.local`, `192.168.1.20`, `nas.tail1a2b3.ts.net`.
    public var host: String
    public var port: Int
    public var share: String
    /// The folder inside the share the music is in, with `/` between names; empty for the whole share.
    public var folder: String
    /// The account as typed: `user`, `DOMAIN\user` or `user@domain`.
    public var user: String

    public init(host: String, port: Int = 445, share: String, folder: String = "", user: String) {
        self.host = host
        self.port = port
        self.share = share
        self.folder = folder
        self.user = user
    }

    /// What people type or paste for a share, taken apart: `smb://nas/music/Albums`, `//nas/music`, `\\nas\music\Albums`,
    /// `nas/music`, with an optional `user@` and `:port`. nil when there is no server and share in it.
    public init?(typed text: String, user: String = "") {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if rest.lowercased().hasPrefix("smb:") { rest.removeFirst(4) }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        var host = parts[0]
        var user = user
        if let at = host.lastIndex(of: "@") {
            if user.isEmpty { user = String(host[..<at]).removingPercentEncoding ?? String(host[..<at]) }
            host = String(host[host.index(after: at)...])
        }
        var port = 445
        // A port follows the last colon, unless the colons are an IPv6 address's own.
        if let colon = host.lastIndex(of: ":"), host.firstIndex(of: ":") == colon || host.contains("]"), let number = Int(host[host.index(after: colon)...]) {
            guard (1...65535).contains(number) else { return nil }
            port = number
            host = String(host[..<colon])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        self.init(host: host, port: port, share: parts[1].removingPercentEncoding ?? parts[1],
                  folder: parts.dropFirst(2).map { $0.removingPercentEncoding ?? $0 }.joined(separator: "/"), user: user)
    }

    /// `smb://nas/music/Albums`, for showing.
    public var display: String {
        let server = host.contains(":") ? "[\(host)]" : host
        return "smb://" + ([port == 445 ? server : "\(server):\(port)", share] + folder.split(separator: "/").map(String.init)).joined(separator: "/")
    }
}

/// Files somewhere, read a range at a time: a share, or a made-up folder in a test.
public protocol ShareFiles: Sendable {
    /// What is in `folder` (a path from the top, `/` between names; empty for the top).
    func list(_ folder: String) throws -> [SMBEntry]
    /// Up to `length` bytes of the file at `path` from `offset`: fewer only at its end.
    func read(_ path: String, offset: Int64, length: Int) throws -> Data
    /// The file's size and when it was last changed.
    func info(_ path: String) throws -> (size: Int64, modified: Date)
    /// Lets go of the connection, if there is one (it is made again when next needed).
    func rest()
}

/// What `SMBShare` needs of a connection (so its reconnecting can be tested without a server).
protocol SMBSession: AnyObject, Sendable {
    func open(_ path: String, folder: Bool) throws -> SMBHandle
    func close(_ handle: SMBHandle) throws
    func read(_ handle: SMBHandle, offset: Int64, length: Int) throws -> [UInt8]
    func list(_ folder: SMBHandle) throws -> [SMBEntry]
    func disconnect()
}

extension SMBConnection: SMBSession {}

public final class SMBShare: ShareFiles, @unchecked Sendable {
    private let lock = NSLock()
    private let connect: @Sendable () throws -> any SMBSession
    private let base: String
    private var session: (any SMBSession)?
    /// Files kept open between reads (a song is read in many pieces), most recently used last.
    private var open: [(path: String, handle: SMBHandle)] = []
    private let openLimit = 3

    /// A share at `address`, signed in to with `password`. Nothing is connected until something is asked for.
    public convenience init(address: ShareAddress, password: String, timeout: TimeInterval = 15) {
        self.init(folder: address.folder) {
            let connection = SMBConnection(transport: try SocketTransport(host: address.host, port: address.port, timeout: timeout))
            do {
                try connection.connect(server: address.host, share: address.share, credentials: SMBCredentials(name: address.user, password: password))
            } catch {
                connection.disconnect()
                throw error
            }
            return connection
        }
    }

    init(folder: String, connect: @escaping @Sendable () throws -> any SMBSession) {
        base = folder.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        self.connect = connect
    }

    deinit { session?.disconnect() }

    private func full(_ path: String) -> String {
        let path = path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        return base.isEmpty ? path : (path.isEmpty ? base : base + "/" + path)
    }

    /// Runs `body` on a connection; when the line turns out to be dead, on a new one, once.
    private func onLine<T>(_ body: (any SMBSession) throws -> T) throws -> T {
        try lock.withLock {
            for attempt in 0..<2 {
                let line: any SMBSession
                if let session { line = session } else {
                    line = try connect()
                    session = line
                }
                do {
                    return try body(line)
                } catch let error as SMBError where Self.lineIsGone(error) && attempt == 0 {
                    drop()
                }
            }
            throw SMBError.closed
        }
    }

    /// A failure that says the connection is no good any more, rather than something about the file asked for.
    /// 0xC000035C and 0xC0000203: the server ended the session. 0xC0000128: the file was closed under us.
    static func lineIsGone(_ error: SMBError) -> Bool {
        switch error {
        case .closed, .timedOut, .malformed, .status(0xC000_035C), .status(0xC000_0203), .status(0xC000_0128): true
        default: false
        }
    }

    private func drop() {
        session?.disconnect()
        session = nil
        open.removeAll()
    }

    public func rest() { lock.withLock { drop() } }

    public func list(_ folder: String) throws -> [SMBEntry] {
        try onLine { line in
            let handle = try line.open(full(folder), folder: true)
            defer { try? line.close(handle) }
            return try line.list(handle)
        }
    }

    private func handle(_ path: String, on line: any SMBSession) throws -> SMBHandle {
        if let index = open.firstIndex(where: { $0.path == path }) {
            let found = open.remove(at: index)
            open.append(found)
            return found.handle
        }
        let handle = try line.open(full(path), folder: false)
        open.append((path, handle))
        while open.count > openLimit { try? line.close(open.removeFirst().handle) }
        return handle
    }

    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        try onLine { line in
            Data(try line.read(try handle(path, on: line), offset: offset, length: length))
        }
    }

    public func info(_ path: String) throws -> (size: Int64, modified: Date) {
        try onLine { line in
            let handle = try handle(path, on: line)
            return (handle.size, handle.modified)
        }
    }
}
