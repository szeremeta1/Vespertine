//
// Vespertine — network shares (SMB, NFS, WebDAV): addresses, mounting, reachability, credentials.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Works the same on a LAN, over Tailscale (MagicDNS names, 100.x addresses, subnet routes)
// or any other VPN: Vespertine only needs the server to be reachable when it connects.
//

import Foundation
import NetFS
import Network
import Security
import os

private let networkLog = Logger(subsystem: "org.szeremeta.vespertine.player", category: "shares")

/// A folder on a file server, e.g. smb://music@nas.local/Music/Hi-Res.
public struct NetworkShare: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case smb, nfs, webdav }

    public var kind: Kind
    public var host: String
    public var port: Int?
    /// nil connects as guest (SMB) or without credentials (NFS, WebDAV).
    public var user: String?
    /// What gets mounted: the SMB share name, or the NFS export / WebDAV path ("/" separated).
    public var share: String
    /// Folder inside the mounted share to index; "" indexes all of it.
    public var subpath: String
    /// WebDAV over TLS.
    public var secure: Bool = true

    public init(kind: Kind, host: String, port: Int? = nil, user: String? = nil, share: String, subpath: String = "", secure: Bool = true) {
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user.flatMap { $0.isEmpty ? nil : $0 }
        self.share = share
        self.subpath = subpath
        self.secure = secure
    }

    /// Accepts what people paste: smb://host/share/folder, host/share, \\host\share\folder,
    /// nfs://host/export, https://host/dav (WebDAV), with an optional user@.
    public init?(string raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("\\\\") { text = "smb://" + text.dropFirst(2).replacingOccurrences(of: "\\", with: "/") }
        if !text.contains("://") { text = "smb://" + text }
        // Encode spaces etc. so URLComponents accepts folder names as typed.
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(["%"])) ?? text
        guard let c = URLComponents(string: encoded), let scheme = c.scheme?.lowercased(),
              let host = c.host, !host.isEmpty else { return nil }
        let parts = c.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let user = c.user?.removingPercentEncoding
        guard host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        switch scheme {
        case "smb", "cifs":
            guard let share = parts.first else { return nil }
            self.init(kind: .smb, host: host, port: c.port, user: user, share: share, subpath: parts.dropFirst().joined(separator: "/"))
        case "nfs":
            guard !parts.isEmpty else { return nil }
            self.init(kind: .nfs, host: host, port: c.port, user: nil, share: parts.joined(separator: "/"))
        case "http", "https", "webdav", "webdavs", "dav", "davs":
            let secure = !["http", "webdav", "dav"].contains(scheme)
            self.init(kind: .webdav, host: host, port: c.port, user: user, share: parts.joined(separator: "/"), secure: secure)
        default:
            return nil
        }
    }

    var scheme: String {
        switch kind {
        case .smb: "smb"
        case .nfs: "nfs"
        case .webdav: secure ? "https" : "http"
        }
    }

    public var defaultPort: Int {
        switch kind {
        case .smb: 445
        case .nfs: 2049
        case .webdav: secure ? 443 : 80
        }
    }

    private static let pathAllowed = CharacterSet.urlPathAllowed.subtracting(["/", ";", "?", "#"])
    private static func encode(_ component: String) -> String { component.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? component }
    private var encodedShare: String { share.split(separator: "/").map { Self.encode(String($0)) }.joined(separator: "/") }
    private var authority: String {
        let userPart = user.map { ($0.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? $0) + "@" } ?? ""
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return userPart + hostPart + (port.map { ":\($0)" } ?? "")
    }

    /// What NetFS mounts (the share itself; the subfolder is walked afterwards).
    /// What NetFS mounts. An address that can't form a URL mounts nothing (and fails to connect) rather than crashing.
    public var mountURL: URL { URL(string: "\(scheme)://\(authority)/\(encodedShare)") ?? URL(string: "\(scheme)://invalid.invalid/")! }

    /// Stored in the library: the share plus the indexed folder. Never contains a password.
    public var urlString: String {
        let sub = subpath.isEmpty ? "" : "/" + subpath.split(separator: "/").map { Self.encode(String($0)) }.joined(separator: "/")
        return "\(scheme)://\(authority)/\(encodedShare)\(sub)"
    }

    /// Readable form for the interface, e.g. "smb://nas.local/Music/Hi-Res".
    public var displayString: String {
        let sub = subpath.isEmpty ? "" : "/" + subpath
        return "\(scheme)://\(host)/\(share)\(sub)"
    }

    public var defaultName: String {
        if let last = subpath.split(separator: "/").last { return String(last) }
        return share.split(separator: "/").last.map(String.init) ?? host
    }

    /// Where Vespertine mounts it: a private folder, so paths stay stable between launches.
    public func mountDirectory(in base: URL) -> URL {
        let raw = "\(host)-\(share)".replacingOccurrences(of: "/", with: "-")
        let safe = raw.map { $0.isLetter || $0.isNumber || "-_. ".contains($0) ? $0 : "_" }
        return base.appendingPathComponent(String(safe), isDirectory: true)
    }

    /// The folder to index, given where the share is mounted.
    public func root(at mountPoint: URL) -> URL {
        subpath.isEmpty ? mountPoint : mountPoint.appendingPathComponent(subpath, isDirectory: true)
    }
}

public enum NetworkShareError: LocalizedError, Equatable {
    case invalidAddress
    case unreachable(host: String)
    case authenticationFailed
    /// No saved password could be found for the account (so nothing was sent to the server).
    case passwordMissing(account: String)
    /// macOS refused the mount itself (a privacy rule or permission), not the server.
    case notPermitted
    case shareNotFound(String)
    case folderNotFound(String)
    case cancelled
    case failed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "That doesn’t look like a server address. Try smb://server/share."
        case .unreachable(let host):
            "Can’t reach \(host). Check that the server is on, and if you reach it through Tailscale or another VPN, that it’s connected."
        case .authenticationFailed:
            "The server didn’t accept that name and password."
        case .notPermitted:
            "macOS didn’t allow Vespertine to mount the share (operation not permitted). Try Reconnect; if it keeps happening, check System Settings → Privacy & Security → Files & Folders for Vespertine."
        case .passwordMissing(let account):
            "No saved password for \(account) was found. Right-click the share and choose Enter Password…; Vespertine saves it in your keychain."
        case .shareNotFound(let share):
            "The server has no share named “\(share)”."
        case .folderNotFound(let folder):
            "Connected, but there’s no folder “\(folder)” in that share."
        case .cancelled:
            "Connecting was cancelled."
        case .failed(let code):
            "Couldn’t connect (\(Self.describe(code)))."
        }
    }

    /// The server refused the name and password, or none could be read: trying again won't help until it changes.
    public var isCredentialProblem: Bool {
        switch self {
        case .authenticationFailed, .passwordMissing: true
        default: false
        }
    }

    static func describe(_ code: Int32) -> String {
        let text = String(cString: strerror(code))
        return text.hasPrefix("Unknown") ? "error \(code)" : text
    }

    static func from(code: Int32, share: NetworkShare) -> NetworkShareError {
        switch code {
        case EAUTH, -6003, -5045: .authenticationFailed
        case EPERM, EACCES: .notPermitted
        case ENOENT: .shareNotFound(share.share)
        case ECANCELED, -128, -5999: .cancelled
        case ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ECONNREFUSED, -5998: .unreachable(host: share.host)
        default: .failed(code: code)
        }
    }
}

public enum NetworkVolume {
    /// Where deadlines fire. GCD's shared pool has a thread limit, and work stuck on a wedged mount holds its
    /// threads, so a deadline queued there can wait seconds for one: late because of the very work it guards
    /// against. A queue of its own always gets a thread.
    private static let deadlines = DispatchQueue(label: "org.szeremeta.vespertine.share-deadlines", qos: .userInitiated)

    /// True for SMB, NFS, WebDAV, AFP… volumes (anything macOS doesn't mark local).
    public static func isNetwork(_ url: URL) -> Bool {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return false }
        return s.f_flags & UInt32(MNT_LOCAL) == 0
    }

    public struct Mount: Sendable {
        public var mountPoint: URL
        public var from: String
        public var type: String
    }

    /// Mounted volumes, read without waiting on (possibly dead) servers.
    public static func mounts() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).map { i in
            var fs = buffer[i]
            let point = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let type = withUnsafeBytes(of: &fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return Mount(mountPoint: URL(fileURLWithPath: point, isDirectory: true), from: from, type: type)
        }
    }

    /// Where this share is already mounted (by Vespertine, Finder or anything else), if it is.
    public static func existingMount(for share: NetworkShare) -> URL? {
        func norm(_ s: String) -> String { (s.removingPercentEncoding ?? s).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let host = share.host.lowercased(), target = norm(share.share)
        for m in mounts() {
            switch (share.kind, m.type) {
            case (.smb, "smbfs"):
                // //user@host/share or //host/share (user may carry a ;domain)
                var rest = Substring(m.from.hasPrefix("//") ? String(m.from.dropFirst(2)) : m.from)
                if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
                guard let slash = rest.firstIndex(of: "/") else { continue }
                let h = rest[..<slash].lowercased().split(separator: ":").first.map(String.init) ?? ""
                if h == host, norm(String(rest[slash...])) == target { return m.mountPoint }
            case (.nfs, "nfs"):
                let parts = m.from.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == host, norm(String(parts[1])) == target { return m.mountPoint }
            case (.webdav, "webdav"):
                if let u = URL(string: m.from), u.host?.lowercased() == host, norm(u.path) == target { return m.mountPoint }
            default:
                continue
            }
        }
        return nil
    }

    /// Quick TCP check, so an offline server fails in seconds instead of NetFS's long timeouts.
    public static func isReachable(_ share: NetworkShare, timeout: TimeInterval = 4) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(share.port ?? share.defaultPort)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(share.host), port: port, using: .tcp)
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finish: @Sendable (Bool) -> Void = { ok in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: break // no route yet (e.g. VPN down); the timeout decides
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            deadlines.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Mounts the share (or finds it already mounted) and returns the mount point.
    /// Mounts are soft (I/O fails instead of hanging when the server goes away), hidden from
    /// the Finder sidebar, and read-only unless `readOnly` is false. They go where macOS puts
    /// network volumes (/Volumes): current macOS refuses to mount inside an app's Application
    /// Support folder ("TCC-protected app data"), so a share mounted there once could never be
    /// remounted by the app itself. `base` is only used to recognize mounts older versions made.
    public static func mount(_ share: NetworkShare, password: String?, in base: URL, readOnly: Bool = true, timeout: TimeInterval = 6) async throws -> URL {
        if let existing = existingMount(for: share) { return existing }
        guard await isReachable(share, timeout: timeout) else { throw NetworkShareError.unreachable(host: share.host) }

        let url = share.mountURL
        let user = share.user, guest = share.user == nil && password == nil && share.kind == .smb
        let (code, point): (Int32, String?) = await Task.detached(priority: .userInitiated) {
            let open = NSMutableDictionary()
            open[kNAUIOptionKey] = kNAUIOptionNoUI
            if guest { open[kNetFSUseGuestKey] = true }
            let mount = NSMutableDictionary()
            mount[kNetFSSoftMountKey] = true
            mount[kNetFSMountFlagsKey] = (readOnly ? MNT_RDONLY : 0) | MNT_DONTBROWSE | MNT_NOSUID | MNT_NODEV
            var points: Unmanaged<CFArray>?
            let rc = NetFSMountURLSync(url as CFURL, nil, user as CFString?, password as CFString?, open, mount, &points)
            let first = (points?.takeRetainedValue() as? [String])?.first
            return (rc, first)
        }.value
        if code == EEXIST, let existing = existingMount(for: share) { return existing }
        guard code == 0 else {
            networkLog.error("mount \(share.host, privacy: .public)/\(share.share, privacy: .public) failed: code \(code, privacy: .public) (\(NetworkShareError.describe(code), privacy: .public)); user \(user != nil, privacy: .public), password \(password != nil, privacy: .public)")
            throw NetworkShareError.from(code: code, share: share)
        }
        if let point { return URL(fileURLWithPath: point, isDirectory: true) }
        if let existing = existingMount(for: share) { return existing }
        throw NetworkShareError.failed(code: ENOENT)
    }

    /// Mounts Vespertine made: hidden from Finder (MNT_DONTBROWSE), or in the folder older versions used.
    /// A share you mounted yourself in Finder is never unmounted by Vespertine.
    public static func isOwnMount(_ mountPoint: URL, legacyBase base: URL) -> Bool {
        if mountPoint.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path) { return true }
        var s = statfs()
        guard statfs(mountPoint.path, &s) == 0 else { return false }
        return s.f_flags & UInt32(MNT_DONTBROWSE) != 0
    }

    /// Runs file-system work that can block on a network mount (stat, list, open, unmount) on a GCD thread, never
    /// the caller's: not the main thread, and not the Swift concurrency pool, whose few threads would all stall on a
    /// wedged share. Waits at most `timeout`, then returns `fallback`; work that's still blocked finishes (or stays
    /// stuck) on its own thread and its result is dropped.
    public static func blocking<T: Sendable>(timeout: TimeInterval, otherwise fallback: T,
                                             _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            blocking(timeout: timeout, otherwise: fallback, work) { continuation.resume(returning: $0) }
        }
    }

    /// The same, handing the result to `then` (exactly once) on the thread that has it: the work's, or the deadline's.
    static func blocking<T: Sendable>(timeout: TimeInterval, otherwise fallback: T, _ work: @escaping @Sendable () -> T,
                                      then deliver: @escaping @Sendable (T) -> Void) {
        let once = ResumeOnce()
        DispatchQueue.global(qos: .utility).async {
            let value = work()
            if once.claim() { deliver(value) }
        }
        deadlines.asyncAfter(deadline: .now() + timeout) {
            if once.claim() { deliver(fallback) }
        }
    }

    /// Whether a mounted share still answers: lists its root on a background thread, within `timeout`.
    /// A mount can stay listed after the server rebooted or the connection died; it then errors or stalls.
    public static func isResponsive(_ root: URL, timeout: TimeInterval = 8) async -> Bool {
        await blocking(timeout: timeout, otherwise: false) { (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil }
    }

    /// Whether `url` is a folder, asked off the calling thread: on a dead mount even a stat can hang.
    public static func isDirectory(_ url: URL, timeout: TimeInterval = 8) async -> Bool {
        await blocking(timeout: timeout, otherwise: false) {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Drops a dead mount even if it's wedged (forced), so it can be mounted again. On a wedged mount the statfs
    /// and the unmount itself can block for minutes, so they run on their own thread and the caller waits at most
    /// `timeout` (a forced unmount usually takes well under a second).
    public static func forceUnmount(_ mountPoint: URL, ownedBy base: URL, timeout: TimeInterval = 15) async {
        await blocking(timeout: timeout, otherwise: ()) {
            guard isOwnMount(mountPoint, legacyBase: base) else { return }
            _ = Darwin.unmount(mountPoint.path, MNT_FORCE)
            if mountPoint.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path) { try? FileManager.default.removeItem(at: mountPoint) }
        }
    }

    /// Unmounts a share Vespertine mounted. Other mounts (Finder's) are left alone.
    public static func unmount(_ mountPoint: URL, ownedBy base: URL) async {
        guard await blocking(timeout: 8, otherwise: false, { isOwnMount(mountPoint, legacyBase: base) }) else { return }
        try? await FileManager.default.unmountVolume(at: mountPoint, options: [.withoutUI])
        if mountPoint.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path) {
            await blocking(timeout: 8, otherwise: ()) { try? FileManager.default.removeItem(at: mountPoint) }
        }
    }
}

/// Share passwords live in the login keychain as the same internet-password items Finder
/// uses, so a password saved by either is found by both. Every query names the keychain
/// explicitly: on recent macOS an app's plain SecItem calls go to the data-protection keychain,
/// where Finder's (and older Vespertine's) share passwords never are, so a share would silently
/// mount with no password and be refused.
public enum NetworkCredentials {
    private static func query(_ share: NetworkShare, dataProtection: Bool) -> [String: Any]? {
        guard let user = share.user else { return nil }
        let proto: CFString
        switch share.kind {
        case .smb: proto = kSecAttrProtocolSMB
        case .nfs: return nil // NFS authenticates by host, not password
        case .webdav: proto = share.secure ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP
        }
        return [kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: share.host,
                kSecAttrAccount as String: user,
                kSecAttrProtocol as String: proto,
                kSecUseDataProtectionKeychain as String: dataProtection]
    }

    /// The saved password: the login keychain first (Finder's and NetAuth's), then the data-protection one.
    public static func password(for share: NetworkShare) -> String? { lookup(share).password }

    /// Password plus the keychain result codes, for diagnosing a failed mount.
    public static func lookup(_ share: NetworkShare) -> (password: String?, status: String) {
        var codes: [String] = []
        for dp in [false, true] {
            guard var q = query(share, dataProtection: dp) else { return (nil, "no account") }
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let rc = SecItemCopyMatching(q as CFDictionary, &out)
            codes.append("\(dp ? "data-protection" : "login") \(rc)")
            if rc == errSecSuccess, let data = out as? Data, let text = String(data: data, encoding: .utf8) { return (text, codes.joined(separator: ", ")) }
        }
        return (nil, codes.joined(separator: ", "))
    }

    /// Whether a password is saved, without reading it (so no keychain access prompt).
    public static func hasPassword(for share: NetworkShare) -> Bool {
        for dp in [false, true] {
            guard var q = query(share, dataProtection: dp) else { return false }
            q[kSecReturnAttributes as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess { return true }
        }
        return false
    }

    /// Saves to the login keychain (where Finder and macOS's network-auth agent look too).
    public static func save(_ password: String, for share: NetworkShare) {
        guard let q = query(share, dataProtection: false) else { return }
        let data = Data(password.utf8)
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = share.host
            add[kSecAttrComment as String] = "Saved by Vespertine for \(share.displayString)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func delete(for share: NetworkShare) {
        for dp in [false, true] {
            if let q = query(share, dataProtection: dp) { SecItemDelete(q as CFDictionary) }
        }
    }
}

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
