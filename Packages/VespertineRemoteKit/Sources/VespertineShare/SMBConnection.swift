//
// Vespertine: an SMB client that only reads: signs in to a server, connects to a share, lists folders and reads files
// (SMB 2.0.2 to 3.1.1, MS-SMB2). It never creates, writes, renames or deletes: there is no code here that could.
// With SMB 3.1.1 the messages that open the connection are bound into the session's keys, so nothing can have been
// changed in them on the way; with SMB 3 a server or share that asks for encryption gets it (AES-128-GCM or CCM).
// One request at a time, each waited for; `SMBShare` puts reconnecting and paths on top.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// A file or folder as a folder listing gives it.
public struct SMBEntry: Equatable, Sendable {
    public var name: String
    public var isFolder: Bool
    public var size: Int64
    public var modified: Date
    /// Hidden or system: left out of a library.
    public var hidden: Bool

    public init(name: String, isFolder: Bool, size: Int64, modified: Date, hidden: Bool = false) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.hidden = hidden
    }
}

/// An open file or folder.
public struct SMBHandle: Equatable, Sendable {
    var id: [UInt8]
    public var size: Int64
    public var modified: Date
    public var isFolder: Bool
}

public struct SMBCredentials: Equatable, Sendable {
    public var user: String
    public var domain: String
    public var password: String

    /// `name` as people type it: `user`, `DOMAIN\user` or `user@domain`.
    public init(name: String, password: String) {
        if let slash = name.firstIndex(of: "\\") {
            domain = String(name[..<slash])
            user = String(name[name.index(after: slash)...])
        } else if let at = name.lastIndex(of: "@") {
            user = String(name[..<at])
            domain = String(name[name.index(after: at)...])
        } else {
            user = name
            domain = ""
        }
        self.password = password
    }

    /// No account was typed: the server is asked for what it gives a guest.
    public var isGuest: Bool { user.isEmpty }
}

/// What a connection needs that tests pin down: its identity, its random bytes and the time.
public struct SMBOptions: Sendable {
    public var clientGUID: [UInt8]
    public var random: @Sendable (Int) -> [UInt8]
    /// Now, as a Windows file time (100 ns since 1601).
    public var now: @Sendable () -> UInt64

    public init(clientGUID: [UInt8]? = nil, random: (@Sendable (Int) -> [UInt8])? = nil, now: (@Sendable () -> UInt64)? = nil) {
        let random = random ?? { count in (0..<count).map { _ in UInt8.random(in: 0...255) } }
        self.random = random
        self.clientGUID = clientGUID ?? random(16)
        self.now = now ?? { SMBConnection.fileTime(Date()) }
    }
}

public final class SMBConnection: @unchecked Sendable {
    // Commands (MS-SMB2 2.2.1).
    private enum Command: UInt16 {
        case negotiate = 0, sessionSetup = 1, logoff = 2, treeConnect = 3, treeDisconnect = 4, create = 5, close = 6, read = 8, queryDirectory = 14
    }

    private static let statusOK: UInt32 = 0
    private static let statusPending: UInt32 = 0x0000_0103
    private static let statusMoreProcessing: UInt32 = 0xC000_0016
    private static let statusNoMoreFiles: UInt32 = 0x8000_0006
    private static let statusEndOfFile: UInt32 = 0xC000_0011

    private static let flagAsync: UInt32 = 0x2
    private static let flagSigned: UInt32 = 0x8
    private static let headerSize = 64
    /// What goes in front of an encrypted message (MS-SMB2 2.2.41): its mark, the tag, the nonce, the size, the session.
    private static let sealedHeaderSize = 52
    private static let sealedMark: [UInt8] = [0xfd, 0x53, 0x4d, 0x42]
    private static let capabilityLargeReads: UInt32 = 0x4
    private static let capabilityEncryption: UInt32 = 0x40
    /// The most asked for in one read: what the stream channel moves at a time.
    static let readLimit = 1 << 20

    private let lock = NSLock()
    private let transport: any SMBTransport
    private let options: SMBOptions

    private var messageID: UInt64 = 0
    private var credits = 1
    private var sessionID: UInt64 = 0
    private var treeID: UInt32 = 0
    private var signingKey: [UInt8]?
    /// The version the server chose, e.g. 0x0311.
    public private(set) var dialect: UInt16 = 0
    /// Every request is sent encrypted, and every answer must be: the server or the share asked for it.
    public private(set) var encrypted = false
    /// The server signed this connection in as a guest (or as nobody): there are no keys, so nothing is signed.
    public private(set) var guest = false
    /// The cipher the server agreed to, when it agreed to one.
    private var cipher: ShareCiphers.Kind?
    /// The keys messages are encrypted and decrypted with, and what this session's nonces start with.
    private var sealing: (seal: [UInt8], open: [UInt8], noncePrefix: [UInt8])?
    private var nonceCount: UInt64 = 0
    /// SMB 3.1.1: the running SHA-512 of the messages that agreed the version, which the session's keys are made from.
    private var negotiated: [UInt8]?
    /// The last request, as sent (without its length in front).
    private var lastSent: [UInt8] = []
    private var maxRead = 65536
    private var maxTransact = 65536
    private var largeReads = false

    public init(transport: any SMBTransport, options: SMBOptions = SMBOptions()) {
        self.transport = transport
        self.options = options
    }

    // MARK: Signing in

    /// Agrees a version, signs in and connects to `share` on `server` (the name the server is addressed by).
    public func connect(server: String, share: String, credentials: SMBCredentials) throws {
        try lock.withLock {
            try negotiate()
            try signIn(credentials)
            try treeConnect(server: server, share: share)
        }
    }

    private func negotiate() throws {
        let dialects: [UInt16] = [0x0202, 0x0210, 0x0300, 0x0302, 0x0311]
        var w = ByteWriter()
        w.u16(36)
        w.u16(UInt16(dialects.count))
        w.u16(1)            // signing is supported
        w.u16(0)
        w.u32(Self.capabilityLargeReads | Self.capabilityEncryption)
        w.raw(options.clientGUID)
        // SMB 3.1.1's extras follow the versions, at a multiple of eight bytes from the start of the message.
        let contextsAt = (Self.headerSize + 36 + dialects.count * 2 + 7) / 8 * 8
        w.u32(UInt32(contextsAt))
        w.u16(2)
        w.u16(0)
        for dialect in dialects { w.u16(dialect) }
        w.zeros(contextsAt - Self.headerSize - w.bytes.count)
        // The digest the opening messages are bound with (SHA-512, the only one there is), and a salt so it can't be made ahead.
        let salt = options.random(32)
        w.u16(1); w.u16(UInt16(6 + salt.count)); w.u32(0)
        w.u16(1); w.u16(UInt16(salt.count)); w.u16(1)
        w.raw(salt)
        w.zeros(2)
        // The ciphers, the preferred one first.
        w.u16(2); w.u16(6); w.u32(0)
        w.u16(2); w.u16(ShareCiphers.Kind.gcm.rawValue); w.u16(ShareCiphers.Kind.ccm.rawValue)
        let reply = try exchange(.negotiate, w.bytes)
        guard reply.status == Self.statusOK else { throw SMBError.unsupported }
        let r = ByteReader(reply.body)
        guard try r.u16(0) == 65 else { throw SMBError.malformed }
        dialect = try r.u16(4)
        guard dialects.contains(dialect) else { throw SMBError.unsupported }
        let capabilities = try r.u32(24)
        maxTransact = Int(try r.u32(28))
        maxRead = Int(try r.u32(32))
        largeReads = dialect >= 0x0210 && capabilities & Self.capabilityLargeReads != 0
        if !largeReads {
            maxRead = min(maxRead, 65536)
            maxTransact = min(maxTransact, 65536)
        }
        if dialect == 0x0311 {
            // The server's extras: it must agree to the digest, and names the cipher if it has one in common.
            var bound = false
            var at = Int(try r.u32(60)) - Self.headerSize
            for _ in 0..<Int(try r.u16(6)) {
                let type = try r.u16(at), length = Int(try r.u16(at + 2))
                let data = ByteReader(try r.slice(at + 8, length))
                if type == 1, try data.u16(0) == 1, try data.u16(4) == 1 { bound = true }
                if type == 2, try data.u16(0) == 1 { cipher = ShareCiphers.Kind(rawValue: try data.u16(2)) }
                at += (8 + length + 7) / 8 * 8
            }
            guard bound else { throw SMBError.unsupported }
            let zeros = [UInt8](repeating: 0, count: 64)
            negotiated = ShareDigests.sha512(ShareDigests.sha512(zeros + lastSent) + reply.raw)
        } else if dialect >= 0x0300, capabilities & Self.capabilityEncryption != 0 {
            cipher = .ccm
        }
    }

    private func signIn(_ credentials: SMBCredentials) throws {
        guard credentials.isGuest else {
            return try signIn(user: credentials.user, domain: credentials.domain, password: credentials.password)
        }
        // A guest: by the name servers keep for one (a NAS with its guest account on, a Mac, Windows, Samba set to treat
        // unknown names as guests), and where that name is refused, as nobody at all, which Samba lets in to a share
        // that allows guests.
        do {
            try signIn(user: "guest", domain: "", password: "")
        } catch SMBError.signInFailed {
            try signIn(user: "", domain: "", password: "")
        }
    }

    /// One sign-in. An empty `user` signs in as nobody (NTLM's anonymous).
    private func signIn(user: String, domain: String, password: String) throws {
        sessionID = 0
        signingKey = nil
        sealing = nil
        // SMB 3.1.1: each session carries the digest on through its own sign-in messages, all but the server's last.
        var bound = negotiated
        func setup(_ token: [UInt8]) throws -> Reply {
            var w = ByteWriter()
            w.u16(25)
            w.u8(0)
            w.u8(1)         // signing is supported
            w.u32(0)
            w.u32(0)
            w.u16(UInt16(Self.headerSize + 24))
            w.u16(UInt16(token.count))
            w.u64(0)
            w.raw(token)
            let reply = try exchange(.sessionSetup, w.bytes)
            if let so = bound {
                let sent = ShareDigests.sha512(so + lastSent)
                bound = reply.status == Self.statusMoreProcessing ? ShareDigests.sha512(sent + reply.raw) : sent
            }
            return reply
        }
        func token(_ reply: Reply) throws -> [UInt8] {
            let r = ByteReader(reply.body)
            let offset = Int(try r.u16(4)) - Self.headerSize, length = Int(try r.u16(6))
            return try r.slice(offset, length)
        }

        let first = NTLM.negotiate()
        let challenged = try setup(SPNEGO.initial(first))
        guard challenged.status == Self.statusMoreProcessing else { throw Self.error(for: challenged.status, signingIn: true) }
        sessionID = challenged.sessionID
        guard let challenge = SPNEGO.ntlmToken(in: try token(challenged)) else { throw SMBError.malformed }
        let done: Reply
        var sessionKey: [UInt8]?
        if user.isEmpty {
            done = try setup(SPNEGO.response(try NTLM.anonymous(challenge: challenge)))
        } else {
            let answer = try NTLM.authenticate(user: user, domain: domain, password: password,
                                               negotiate: first, challenge: challenge, clientChallenge: options.random(8), time: options.now())
            done = try setup(SPNEGO.response(answer.message, mechListMIC: answer.carriesDigest ? answer.listSignature(SPNEGO.mechanismList) : nil))
            sessionKey = Array(answer.sessionKey.prefix(16))
        }
        guard done.status == Self.statusOK else {
            sessionID = 0
            throw Self.error(for: done.status, signingIn: true)
        }
        let flags = try ByteReader(done.body).u16(2)
        // A guest or anonymous session has no key: nothing is signed or encrypted, as the protocol has it.
        guest = flags & 0x3 != 0 || sessionKey == nil
        if !guest, let key = sessionKey {
            if dialect == 0x0311, let bound {
                signingKey = Self.derive(key, label: "SMBSigningKey", context: bound)
                // The server signs its last sign-in answer with a key made from the digest of everything said so far.
                // If any of it was changed on the way (a version or a cipher struck out), the two keys differ and this fails.
                guard done.flags & Self.flagSigned != 0, signatureFits(done.raw) else { throw SMBError.badSignature }
                if cipher != nil {
                    sealing = (Self.derive(key, label: "SMBC2SCipherKey", context: bound), Self.derive(key, label: "SMBS2CCipherKey", context: bound),
                               options.random((cipher?.nonceLength ?? 12) - 8))
                }
            } else if dialect >= 0x0300 {
                signingKey = Self.derive(key, label: "SMB2AESCMAC", context: "SmbSign")
                if cipher != nil {
                    sealing = (Self.derive(key, label: "SMB2AESCCM", context: "ServerIn "), Self.derive(key, label: "SMB2AESCCM", context: "ServerOut"),
                               options.random((cipher?.nonceLength ?? 11) - 8))
                }
            } else {
                signingKey = key
            }
        }
        if flags & 0x4 != 0 {
            // The server wants everything encrypted from here on.
            guard sealing != nil else { throw SMBError.unsupported }
            encrypted = true
        }
    }

    /// SMB 3's key derivation (SP 800-108, counter mode, HMAC-SHA-256), for a 16-byte key. `context` is followed by a
    /// zero byte when it is text (SMB 3.0), and goes in as it is when it is SMB 3.1.1's digest.
    static func derive(_ key: [UInt8], label: String, context: String) -> [UInt8] {
        derive(key, label: label, context: Array(context.utf8) + [0])
    }

    static func derive(_ key: [UInt8], label: String, context: [UInt8]) -> [UInt8] {
        var input: [UInt8] = [0, 0, 0, 1]
        input += Array(label.utf8) + [0]
        input.append(0)
        input += context
        input += [0, 0, 0, 128]
        return Array(ShareDigests.hmacSHA256(key: key, input).prefix(16))
    }

    private func treeConnect(server: String, share: String) throws {
        let path = "\\\\\(server)\\\(share)".utf16LE
        var w = ByteWriter()
        w.u16(9)
        w.u16(0)
        w.u16(UInt16(Self.headerSize + 8))
        w.u16(UInt16(path.count))
        w.raw(path)
        let reply = try exchange(.treeConnect, w.bytes)
        guard reply.status == Self.statusOK else { throw Self.error(for: reply.status, connecting: true) }
        let r = ByteReader(reply.body)
        guard try r.u8(2) == 1 else { throw SMBError.noSuchShare }      // a disk share, not a printer or a pipe
        treeID = reply.treeID
        if try r.u32(4) & 0x8000 != 0 {
            // The share wants everything encrypted from here on.
            guard sealing != nil else { throw SMBError.unsupported }
            encrypted = true
        }
    }

    // MARK: Files and folders

    /// Opens a file or folder for reading. `path` is from the share's top, with `/` between names; empty is the top itself.
    public func open(_ path: String, folder: Bool) throws -> SMBHandle {
        try lock.withLock {
            let name = path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "\\").utf16LE
            var w = ByteWriter()
            w.u16(57)
            w.u8(0)
            w.u8(0)                             // no oplock
            w.u32(2)                            // impersonation
            w.u64(0)
            w.u64(0)
            w.u32(0x0010_0081)                  // read data (or list), read attributes, synchronize
            w.u32(0)
            w.u32(0x7)                          // others may read, write and delete meanwhile
            w.u32(1)                            // open only what exists
            w.u32(folder ? 0x1 : 0x40)          // must be a folder / must not be one
            w.u16(UInt16(Self.headerSize + 56))
            w.u16(UInt16(name.count))
            w.u32(0)
            w.u32(0)
            w.raw(name.isEmpty ? [0] : name)
            let reply = try exchange(.create, w.bytes)
            guard reply.status == Self.statusOK else { throw Self.error(for: reply.status) }
            let r = ByteReader(reply.body)
            guard try r.u16(0) == 89 else { throw SMBError.malformed }
            return SMBHandle(id: try r.slice(64, 16), size: Int64(clamping: try r.u64(48)),
                             modified: Self.date(fileTime: try r.u64(24)), isFolder: try r.u32(56) & 0x10 != 0)
        }
    }

    public func close(_ handle: SMBHandle) throws {
        try lock.withLock {
            var w = ByteWriter()
            w.u16(24)
            w.u16(0)
            w.u32(0)
            w.raw(handle.id)
            let reply = try exchange(.close, w.bytes)
            guard reply.status == Self.statusOK else { throw Self.error(for: reply.status) }
        }
    }

    /// Up to `length` bytes of `handle` from `offset`: fewer only at the end of the file.
    public func read(_ handle: SMBHandle, offset: Int64, length: Int) throws -> [UInt8] {
        try lock.withLock {
            var out: [UInt8] = []
            out.reserveCapacity(max(0, length))
            while out.count < length {
                let piece = try readOnce(handle, offset: offset + Int64(out.count), length: length - out.count)
                if piece.isEmpty { break }
                out += piece
            }
            return out
        }
    }

    private func readOnce(_ handle: SMBHandle, offset: Int64, length: Int) throws -> [UInt8] {
        var count = min(length, maxRead, Self.readLimit)
        // A read above 64 KiB costs a credit per 64 KiB: no more is asked for than the server has granted.
        var charge = 1
        if largeReads {
            charge = max(1, min((count + 65535) / 65536, credits))
            count = min(count, charge * 65536)
        }
        var w = ByteWriter()
        w.u16(49)
        w.u8(0x50)
        w.u8(0)
        w.u32(UInt32(count))
        w.u64(UInt64(offset))
        w.raw(handle.id)
        w.u32(0)
        w.u32(0)
        w.u32(0)
        w.u16(0)
        w.u16(0)
        w.u8(0)
        let reply = try exchange(.read, w.bytes, charge: charge)
        if reply.status == Self.statusEndOfFile { return [] }
        guard reply.status == Self.statusOK else { throw Self.error(for: reply.status) }
        let r = ByteReader(reply.body)
        let at = Int(try r.u8(2)) - Self.headerSize, got = Int(try r.u32(4))
        return try r.slice(at, got)
    }

    /// Everything in an open folder, `.` and `..` left out.
    public func list(_ folder: SMBHandle) throws -> [SMBEntry] {
        try lock.withLock {
            var entries: [SMBEntry] = []
            var first = true
            let pattern = "*".utf16LE
            while true {
                var w = ByteWriter()
                w.u16(33)
                w.u8(1)                         // names, sizes and times
                w.u8(first ? 0x1 : 0)           // from the start
                w.u32(0)
                w.raw(folder.id)
                w.u16(UInt16(Self.headerSize + 32))
                w.u16(UInt16(pattern.count))
                w.u32(UInt32(min(maxTransact, 65536)))
                w.raw(pattern)
                first = false
                let reply = try exchange(.queryDirectory, w.bytes)
                if reply.status == Self.statusNoMoreFiles { break }
                guard reply.status == Self.statusOK else { throw Self.error(for: reply.status) }
                let r = ByteReader(reply.body)
                let buffer = try r.slice(Int(try r.u16(2)) - Self.headerSize, Int(try r.u32(4)))
                let b = ByteReader(buffer)
                var at = 0
                while true {
                    let next = Int(try b.u32(at))
                    let attributes = try b.u32(at + 56)
                    let name = String(utf16LE: try b.slice(at + 64, Int(try b.u32(at + 60))))
                    if name != ".", name != ".." {
                        entries.append(SMBEntry(name: name, isFolder: attributes & 0x10 != 0, size: Int64(clamping: try b.u64(at + 40)),
                                                modified: Self.date(fileTime: try b.u64(at + 24)), hidden: attributes & 0x6 != 0))
                    }
                    if next == 0 { break }
                    at += next
                }
            }
            return entries
        }
    }

    /// Ends the connection. The server closes whatever was open.
    public func disconnect() { transport.close() }

    // MARK: Messages

    private struct Reply {
        var status: UInt32
        var flags: UInt32
        var sessionID: UInt64
        var treeID: UInt32
        /// The message after its 64-byte header.
        var body: [UInt8]
        /// The whole message, header and all.
        var raw: [UInt8]
    }

    private func exchange(_ command: Command, _ body: [UInt8], charge: Int = 1) throws -> Reply {
        let id = messageID
        var w = ByteWriter()
        w.raw([0xfe, 0x53, 0x4d, 0x42])
        w.u16(64)
        w.u16(dialect >= 0x0210 ? UInt16(charge) : 0)
        w.u32(0)
        w.u16(command.rawValue)
        w.u16(64)                               // credits asked for
        // An encrypted message isn't signed as well: the cipher's own tag says it is whole.
        let seals = encrypted && command != .negotiate && command != .sessionSetup
        let signs = signingKey != nil && !seals && command != .negotiate && command != .sessionSetup
        w.u32(signs ? Self.flagSigned : 0)
        w.u32(0)
        w.u64(id)
        w.u32(0)
        w.u32(treeID)
        w.u64(sessionID)
        w.zeros(16)
        w.raw(body)
        var message = w.bytes
        if signs, let signingKey {
            message.replaceSubrange(48..<64, with: signature(of: message, key: signingKey))
        }
        messageID += UInt64(max(1, charge))
        credits -= max(1, charge)
        lastSent = message
        if seals { message = try seal(message) }

        let length = message.count
        try transport.send([0, UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)] + message)

        while true {
            let prefix = try transport.receive(4)
            let size = Int(prefix[1]) << 16 | Int(prefix[2]) << 8 | Int(prefix[3])
            guard prefix[0] == 0, size >= Self.headerSize, size <= 16 << 20 else { throw SMBError.malformed }
            var reply = try transport.receive(size)
            let sealed = reply.starts(with: Self.sealedMark)
            if sealed { reply = try open(reply) }
            let r = ByteReader(reply)
            guard reply.count >= Self.headerSize, try r.slice(0, 4) == [0xfe, 0x53, 0x4d, 0x42] else { throw SMBError.malformed }
            // Something the server sends on its own (it has message ID 0xFFFF…): not an answer to anything.
            guard try r.u64(24) == id else { continue }
            credits += Int(try r.u16(14))
            let status = try r.u32(8), flags = try r.u32(16)
            // "Still working on it": the real answer follows under the same ID.
            if status == Self.statusPending, flags & Self.flagAsync != 0 { continue }
            if seals || sealed {
                // What was asked encrypted is answered encrypted. An answer in the clear didn't come from the server signed in to.
                guard seals, sealed else { throw SMBError.badSignature }
            } else if flags & Self.flagSigned != 0, signingKey != nil, command != .sessionSetup {
                guard signatureFits(reply) else { throw SMBError.badSignature }
            } else if signs, status == Self.statusOK {
                // A signed session's answers are signed. One that isn't didn't come from the server signed in to.
                throw SMBError.badSignature
            }
            // An asynchronous answer carries an ID of its own where the tree ID is.
            let tree = flags & Self.flagAsync != 0 ? treeID : try r.u32(36)
            return Reply(status: status, flags: flags, sessionID: try r.u64(40), treeID: tree, body: Array(reply[Self.headerSize...]), raw: reply)
        }
    }

    /// Whether `message`'s signature is the one this session's key gives it.
    private func signatureFits(_ message: [UInt8]) -> Bool {
        guard let signingKey, message.count >= Self.headerSize else { return false }
        var unsigned = message
        unsigned.replaceSubrange(48..<64, with: [UInt8](repeating: 0, count: 16))
        return signature(of: unsigned, key: signingKey) == Array(message[48..<64])
    }

    // MARK: Encryption

    /// `message` encrypted, behind the header that says how (MS-SMB2 3.1.4.3).
    private func seal(_ message: [UInt8]) throws -> [UInt8] {
        guard let sealing, let cipher else { throw SMBError.unsupported }
        // A nonce must never be used twice with a key: random bytes chosen at sign-in, then a count of the messages sent.
        nonceCount += 1
        var nonce = ByteWriter()
        nonce.raw(sealing.noncePrefix)
        nonce.u64(nonceCount)
        nonce.zeros(16 - nonce.bytes.count)
        return Self.sealed(message, cipher: cipher, key: sealing.seal, nonceField: nonce.bytes, sessionID: sessionID)
    }

    /// The message inside an encrypted one. One whose tag doesn't fit didn't come from the server signed in to.
    private func open(_ message: [UInt8]) throws -> [UInt8] {
        guard let sealing, let cipher else { throw SMBError.malformed }
        return try Self.opened(message, cipher: cipher, key: sealing.open, sessionID: sessionID)
    }

    /// `nonceField` is the header's 16 bytes for a nonce; the cipher uses as many from the front as it takes.
    static func sealed(_ message: [UInt8], cipher: ShareCiphers.Kind, key: [UInt8], nonceField: [UInt8], sessionID: UInt64) -> [UInt8] {
        var w = ByteWriter()
        w.raw(nonceField)
        w.u32(UInt32(message.count))
        w.u16(0)
        w.u16(1)            // encrypted (SMB 3.1.1); with AES-128-CCM (SMB 3.0)
        w.u64(sessionID)
        // The tag covers the header from the nonce on as well as the message.
        let sealed = ShareCiphers.seal(cipher, key: key, nonce: Array(nonceField.prefix(cipher.nonceLength)), message, aad: w.bytes)
        return sealedMark + sealed.tag + w.bytes + sealed.ciphertext
    }

    static func opened(_ message: [UInt8], cipher: ShareCiphers.Kind, key: [UInt8], sessionID: UInt64) throws -> [UInt8] {
        guard message.count >= sealedHeaderSize, message.starts(with: sealedMark) else { throw SMBError.malformed }
        let r = ByteReader(message)
        guard try r.u64(44) == sessionID, Int(try r.u32(36)) == message.count - sealedHeaderSize else { throw SMBError.malformed }
        let sealed = ShareCiphers.Sealed(ciphertext: Array(message[sealedHeaderSize...]), tag: Array(message[4..<20]))
        guard let opened = ShareCiphers.open(cipher, key: key, nonce: Array(message[20..<(20 + cipher.nonceLength)]), sealed,
                                             aad: Array(message[20..<sealedHeaderSize])) else { throw SMBError.badSignature }
        return opened
    }

    private func signature(of message: [UInt8], key: [UInt8]) -> [UInt8] {
        dialect >= 0x0300 ? ShareDigests.aesCMAC(key: key, message) : Array(ShareDigests.hmacSHA256(key: key, message).prefix(16))
    }

    // MARK: Words for a refusal

    private static func error(for status: UInt32, signingIn: Bool = false, connecting: Bool = false) -> SMBError {
        switch status {
        case 0xC000_006D, 0xC000_006E, 0xC000_0064, 0xC000_006A, 0xC000_0072, 0xC000_0071, 0xC000_0234, 0xC000_0193, 0xC000_015B:
            // Wrong name or password, or an account that is disabled, expired, locked or not allowed in this way.
            return .signInFailed
        case 0xC000_0022: return signingIn ? .signInFailed : .accessDenied
        case 0xC000_00CC: return .noSuchShare
        case 0xC000_0034, 0xC000_003A, 0xC000_0033, 0xC000_000F, 0xC000_00BA, 0xC000_0103: return connecting ? .noSuchShare : .notFound
        case 0xC000_00BB: return .unsupported
        default: return .status(status)
        }
    }

    // MARK: Times

    /// Seconds between 1601 and 1970.
    private static let epochGap: Double = 11_644_473_600

    static func date(fileTime: UInt64) -> Date {
        Date(timeIntervalSince1970: Double(fileTime) / 10_000_000 - epochGap)
    }

    static func fileTime(_ date: Date) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 + epochGap) * 10_000_000))
    }
}
