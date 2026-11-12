//
// Vespertine Remote: the app's state: the Macs it found, the ones it paired with, and the session with the chosen one.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Network
import Observation
import SwiftUI
import UIKit
import VespertineRemoteClient
import VespertineRemoteProtocol

@Observable
final class RemoteAppModel {
    let discovery = RemoteDiscovery()
    private(set) var pairings: [SavedPairing]
    private(set) var session: RemoteSession?
    /// A pairing link opened from the Camera app or scanned, waiting for its Mac to show up on Bonjour.
    var pendingLink: PairingLink?
    /// What went wrong with the last pairing attempt, for the pairing screen.
    var pairingError: String?
    var isPairing = false
    let artwork = ArtworkCache()

    @ObservationIgnored private let keychain = PairingKeychain()
    @ObservationIgnored private var linkWatch: Task<Void, Never>?
    private static let lastMacKey = "lastMac"

    init() {
        pairings = keychain.load().sorted { $0.pairedAt < $1.pairedAt }
        discovery.start()
        if let last = UserDefaults.standard.string(forKey: Self.lastMacKey), let pairing = pairings.first(where: { $0.serverID == last }) {
            choose(pairing)
        } else if pairings.count == 1 {
            choose(pairings[0])
        }
    }

    /// The name this phone shows in the Mac's list of paired phones.
    var deviceName: String { UIDevice.current.name }

    // MARK: Choosing a Mac

    func choose(_ pairing: SavedPairing) {
        session?.close()
        let session = RemoteSession(pairing: pairing, clientName: deviceName) { [weak self] serverID in
            self?.discovery.mac(serverID: serverID)?.endpoint
        }
        self.session = session
        artwork.session = session
        UserDefaults.standard.set(pairing.serverID, forKey: Self.lastMacKey)
        session.connect()
    }

    /// Tries the remote on a pretend Mac inside the app (no network, no sound). Not saved as a pairing.
    func tryDemo() {
        session?.close()
        let pairing = SavedPairing(serverID: DemoMac.serverID, name: String(localized: "Demo Mac"), device: "demo", key: Data())
        // One pretend Mac for the whole demo, so the queue survives the app going to the background and back.
        let mac = DemoMac(name: pairing.name) { key, size in DemoArtwork.png(key: key, size: size) }
        let session = RemoteSession(pairing: pairing, clientName: deviceName) { mac }
        self.session = session
        artwork.session = session
        session.connect()
    }

    /// Back to the list of Macs.
    func leave() {
        session?.close()
        session = nil
        artwork.session = nil
        UserDefaults.standard.removeObject(forKey: Self.lastMacKey)
    }

    func forget(_ pairing: SavedPairing) {
        if session?.pairing.serverID == pairing.serverID { leave() }
        keychain.remove(serverID: pairing.serverID)
        pairings.removeAll { $0.serverID == pairing.serverID }
    }

    func isPaired(_ mac: DiscoveredMac) -> Bool {
        pairings.contains { $0.serverID == mac.serverID }
    }

    // MARK: Pairing

    /// A `vespertine-remote://pair?…` link, from the Camera app or the in-app scanner.
    func open(_ url: URL) {
        guard let link = PairingLink(url: url) else { return }
        pair(link: link)
    }

    func pair(link: PairingLink) {
        pendingLink = link
        pairingError = nil
        linkWatch?.cancel()
        // The Mac may not be on the Bonjour list yet (the app just opened): give it a few seconds.
        linkWatch = Task { [weak self] in
            for _ in 0..<40 {
                guard let self, !Task.isCancelled else { return }
                if let mac = self.discovery.mac(serverID: link.serverID) {
                    self.pendingLink = nil
                    await self.pair(mac, secret: link.secret, viaLink: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingLink = nil
            self.pairingError = String(localized: "Couldn’t find “\(link.name)” on this network. Check that the iPhone and the Mac are on the same Wi-Fi network.")
        }
    }

    /// Pairs with `mac` using the 6-digit code it shows (or the secret in its QR link).
    func pair(_ mac: DiscoveredMac, secret: String, viaLink: Bool) async {
        isPairing = true
        pairingError = nil
        defer { isPairing = false }
        do {
            let pairing = try await RemoteSession.pair(endpoint: mac.endpoint, serverID: mac.serverID, secret: secret, viaLink: viaLink, clientName: deviceName)
            keychain.upsert(pairing)
            pairings.removeAll { $0.serverID == pairing.serverID }
            pairings.append(pairing)
            choose(pairing)
        } catch {
            switch error {
            case .refused:
                pairingError = viaLink
                    ? String(localized: "That pairing code has expired. On the Mac, choose Pair a Phone again and scan the new code.")
                    : String(localized: "That code didn’t work. Check the code on the Mac, or choose Pair a Phone there again for a new one.")
            case .failed(let reason):
                pairingError = reason.isEmpty ? String(localized: "The Mac didn’t accept this iPhone.") : reason
            case .unreachable:
                pairingError = String(localized: "The Mac stopped answering. Check that it’s awake and on the same network.")
            }
        }
    }

    // MARK: Background

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            discovery.start()
            session?.connect()
        case .background:
            session?.suspend()
            discovery.stop()
        default:
            break
        }
    }
}
