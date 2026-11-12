//
// Vespertine: the connection settings both ends of the remote use (Network.framework, Apple platforms only).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// TLS 1.2 with pre-shared keys (TLS_PSK_WITH_AES_128_GCM_SHA256), as in Apple's peer-to-peer networking sample: no
// certificates to make, trust or renew. The Mac lists every paired phone's key, plus the pairing keys while a pairing
// window is open; a phone offers just its own. Inside the TLS, each JSON message goes as a 4-byte big-endian length
// and then its bytes (`RemoteFrame`). (Network's WebSocket refused to connect on loopback in CI, with or without TLS,
// and a WebSocket gains nothing here: nothing but this app speaks to the port.)
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

    /// TCP + TLS (with `keys`) + message framing, for the Mac's listener (every key it accepts) or a phone's connection (its one).
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
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: RemoteFrame.definition), at: 0)
        return parameters
    }

    /// The context to send one JSON message with.
    public static var textContext: NWConnection.ContentContext {
        NWConnection.ContentContext(identifier: "vespertine-remote", metadata: [NWProtocolFramer.Message(definition: RemoteFrame.definition)])
    }
}

/// Messages on the stream: a 4-byte big-endian length, then that many bytes. A length over
/// `RemoteProtocol.maximumMessageSize` ends the connection.
public final class RemoteFrame: NWProtocolFramerImplementation, @unchecked Sendable {
    nonisolated(unsafe) public static let definition = NWProtocolFramer.Definition(implementation: RemoteFrame.self)
    public static var label: String { "VespertineRemote" }
    private static let headerSize = 4

    public required init(framer: NWProtocolFramer.Instance) {}
    public func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    public func wakeup(framer: NWProtocolFramer.Instance) {}
    public func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    public func cleanup(framer: NWProtocolFramer.Instance) {}

    public func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        framer.writeOutput(data: Self.header(length: messageLength))
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }

    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var length: Int?
            let parsed = framer.parseInput(minimumIncompleteLength: Self.headerSize, maximumLength: Self.headerSize) { buffer, _ in
                guard let buffer, buffer.count >= Self.headerSize else { return 0 }
                length = Self.length(of: Data(buffer.prefix(Self.headerSize)))
                return Self.headerSize
            }
            guard parsed, let length else { return Self.headerSize }
            guard length <= RemoteProtocol.maximumMessageSize else {
                framer.markFailed(error: .posix(.EMSGSIZE))
                return 0
            }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            if !framer.deliverInputNoCopy(length: length, message: message, isComplete: true) { return 0 }
        }
    }

    /// The 4 bytes that go before a message of `length` bytes.
    public static func header(length: Int) -> Data {
        let value = UInt32(clamping: length)
        return Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    /// The length a header gives.
    public static func length(of header: Data) -> Int {
        header.prefix(headerSize).reduce(0) { $0 << 8 | Int($1) }
    }
}
#endif
