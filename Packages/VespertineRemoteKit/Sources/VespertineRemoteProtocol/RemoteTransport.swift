//
// Vespertine: the connection settings both ends of the remote use (Network.framework, Apple platforms only).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// TLS 1.2 with pre-shared keys (TLS_PSK_WITH_AES_128_GCM_SHA256), as in Apple's peer-to-peer networking sample: no
// certificates to make, trust or renew. The Mac lists every paired phone's key, plus the pairing keys while a pairing
// window is open; a phone offers just its own. Inside the TLS, one WebSocket carries JSON text messages.
//

#if canImport(Network)
import Foundation
import Network
import Security

public enum RemoteTransport {
    public struct PresharedKey: Sendable, Equatable {
        public var identity: String
        public var key: Data

        public init(identity: String, key: Data) {
            self.identity = identity
            self.key = key
        }
    }

    /// TCP + TLS (with `keys`) + WebSocket, for the Mac's listener (every key it accepts) or a phone's connection (its one).
    public static func parameters(keys: [PresharedKey]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        for psk in keys {
            let key = psk.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(psk.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(security, key as __DispatchData, identity as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(security, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.noDelay = true

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = RemoteProtocol.maximumMessageSize
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }

    /// The context to send one JSON text message with.
    public static var textContext: NWConnection.ContentContext {
        NWConnection.ContentContext(identifier: "vespertine-remote-text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
    }
}
#endif
