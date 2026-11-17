//
// Vespertine: pairing spoken to a receiver. The messages of `PairSetup` and `PairVerify` go as POSTs on the same
// connection the session then uses, and once the two sides share a secret the connection is sealed (`PairingChannel`)
// for everything after.
//
// - A receiver that lets anyone on the network play: `withoutPIN()`, two POSTs, every session.
// - A receiver that shows a PIN: `showPIN()`, then `setup(pin:identity:)` once (what it returns is kept), and
//   `verify(identity:receiver:)` at the start of every session after.
//
// The request paths and headers are the ones AirPlay 2 senders use, as OwnTone (GPL-2.0-or-later) and pyatv (MIT) record
// them. None of their code is included.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

actor PairingExchange {
    private let connection: RTSPConnection
    /// The number of the next request. The session carries on from here, on the same connection.
    private(set) var cseq: Int

    init(connection: RTSPConnection, cseq: Int = 1) {
        self.connection = connection
        self.cseq = cseq
    }

    /// Asks the receiver to put a PIN on its screen.
    func showPIN() async throws {
        _ = try await post("/pair-pin-start", transient: false)
    }

    /// Pairs with a receiver that asks for no PIN and seals the connection; gives the session's secret. `secret`: SRP's
    /// private number (random unless a test gives one).
    @discardableResult
    func withoutPIN(secret: Data? = nil) async throws -> Data {
        var setup = PairSetup.withoutPIN(secret: secret)
        let m2 = try await post("/pair-setup", transient: true, body: setup.start)
        let m4 = try await post("/pair-setup", transient: true, body: try setup.proof(answering: m2))
        let key = try setup.finish(answering: m4)
        await connection.secure(keys: .control(secret: key))
        return key
    }

    /// Pairs for good with a receiver whose screen shows `pin`: gives its name and key, to keep with `identity`. The
    /// connection is not sealed by this; `verify` does that, here or on a later connection.
    func setup(pin: String, identity: PairingIdentity, secret: Data? = nil) async throws -> PairedReceiver {
        var setup = PairSetup(pin: pin, secret: secret)
        let m2 = try await post("/pair-setup", transient: false, body: setup.start)
        let m4 = try await post("/pair-setup", transient: false, body: try setup.proof(answering: m2))
        try setup.finish(answering: m4)
        let m6 = try await post("/pair-setup", transient: false, body: try setup.exchange(identity))
        return try setup.receiver(answering: m6)
    }

    /// Proves to a receiver paired with before that this is the same Mac, checks that it is the same receiver, and seals
    /// the connection; gives the session's secret.
    @discardableResult
    func verify(identity: PairingIdentity, receiver: PairedReceiver,
                seed: Data = Curve25519.KeyAgreement.PrivateKey().rawRepresentation) async throws -> Data {
        var verify = PairVerify(identity: identity, receiver: receiver, seed: seed)
        let m2 = try await post("/pair-verify", transient: false, body: verify.start)
        let m4 = try await post("/pair-verify", transient: false, body: try verify.proof(answering: m2))
        let secret = try verify.finish(answering: m4)
        await connection.secure(keys: .control(secret: secret))
        return secret
    }

    /// One POST; the answer's body. `X-Apple-HKP` says which kind of pairing the sender is doing (3: with a PIN, and
    /// pair-verify; 4: without).
    private func post(_ path: String, transient: Bool, body: Data = Data()) async throws -> Data {
        let number = cseq
        cseq += 1
        var headers: [(String, String)] = [("CSeq", String(number)), ("User-Agent", "AirPlay/320.20"), ("Connection", "keep-alive"),
                                           ("X-Apple-HKP", transient ? "4" : "3")]
        if !body.isEmpty { headers.append(("Content-Type", "application/octet-stream")) }
        let response = try await connection.send(.request("POST", path, headers: headers, body: body))
        guard response.status == 200 else { throw RAOPError.refused(path, response.status) }
        return response.body
    }
}
