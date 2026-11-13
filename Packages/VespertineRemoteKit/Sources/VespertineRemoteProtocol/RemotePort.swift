//
// Vespertine: the Mac's remote port. The server tries the same port every time it starts, so a paired phone's saved
// address (a Tailscale name and this port, say) keeps working across restarts of Vespertine; when something else has
// the port, it takes the next free one and says which on Bonjour.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public enum RemotePort {
    /// The port the Mac tries first. Below the range the system hands out on its own (49152 and up), so no other
    /// program is given it by chance, and beside the web remote's.
    public static let preferred: UInt16 = 47_821
    /// The web remote's port (the page a browser opens). The phone remote never uses it.
    public static let webRemote: UInt16 = 47_820
    /// How many ports the server tries (the preferred one and the ones after it) before it lets the system choose.
    public static let fallbackCount = 20

    /// Ports a server may use: registered-range ports, not the web remote's.
    private static func isUsable(_ port: UInt16) -> Bool {
        port >= 1024 && port < 49_152 && port != webRemote
    }

    /// The ports to try, in order: the one saved from the last run (so a phone that learned a moved port isn't
    /// stranded when the usual one is free again), then `preferred` and the next ones. Without repeats.
    public static func candidates(saved: UInt16?, preferred: UInt16 = RemotePort.preferred, count: Int = fallbackCount) -> [UInt16] {
        var out: [UInt16] = []
        if let saved, isUsable(saved) { out.append(saved) }
        for offset in 0..<max(count, 1) {
            let (port, overflow) = preferred.addingReportingOverflow(UInt16(offset))
            if !overflow, isUsable(port), !out.contains(port) { out.append(port) }
        }
        return out
    }

    /// The port a Mac says it listens on in its Bonjour TXT record (nil when it says none, or nonsense).
    public static func advertised(txt: [String: String]) -> UInt16? {
        guard let text = txt[RemoteProtocol.TXTKey.port], let port = UInt16(text), port > 0 else { return nil }
        return port
    }
}
