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
import VespertineShare

@Observable
final class RemoteAppModel {
    let discovery = RemoteDiscovery()
    /// How long "Looking for Macs" has been turning with nothing to pair with: after a while the list says what to try.
    let search = DiscoveryPatience()
    private(set) var pairings: [SavedPairing]
    private(set) var session: RemoteSession?
    /// The SMB shares this device plays from by itself, without a Mac.
    private(set) var shares: [SavedShare]
    /// What the open share is doing (scanning, not answering), for the screens; nil when a Mac or nothing is open.
    private(set) var shareStatus: ShareStatus?
    /// Goes up when the open share's library changed under the screens (a scan found new or changed songs).
    private(set) var libraryRevision = 0
    /// A pairing link opened from the Camera app or scanned, waiting for its Mac to show up on Bonjour.
    var pendingLink: PairingLink?
    /// What went wrong with the last pairing attempt, for the pairing screen.
    var pairingError: String?
    var isPairing = false
    let artwork = ArtworkCache()
    let settings = AppSettings()
    let tiltSensor = TiltSensor()
    /// This device has a network at all (Wi-Fi, cellular or a VPN).
    private(set) var isOnline = true
    /// The network in use is cellular data (not Wi-Fi or a cable).
    private(set) var onCellular = false
    /// Tailscale is connected on this device (it has a Tailscale address).
    private(set) var tailscaleOn = false
    /// Which screen the remote opens on (set by a launch option in debug builds).
    var startScreen: String?

    @ObservationIgnored private let keychain = PairingKeychain()
    @ObservationIgnored private let shareKeychain = ShareKeychain()
    /// The open share, answering the screens as a Mac would.
    @ObservationIgnored private var shareMac: ShareMac?
    /// Pairings that are never saved (a made-up one for screenshots).
    @ObservationIgnored private var transientPairings: Set<String> = []
    @ObservationIgnored private var linkWatch: Task<Void, Never>?
    /// The paired Macs Bonjour listed last time, to notice one that just showed up.
    @ObservationIgnored private var listedPaired: Set<String> = []
    @ObservationIgnored private var shareRevisionSeen = 0
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    private static let lastMacKey = "lastMac"

    init() {
        pairings = keychain.load().sorted { $0.pairedAt < $1.pairedAt }
        shares = shareKeychain.load().sorted { $0.addedAt < $1.addedAt }
        discovery.onChange = { [weak self] macs in self?.discovered(macs) }
        discovery.start()
        searchChanged()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            MainActor.assumeIsolated { self?.networkChanged(online: online, cellular: cellular) }
        }
        pathMonitor.start(queue: .main)
        #if DEBUG
        if applyLaunchOptions() { return }
        #endif
        if let last = UserDefaults.standard.string(forKey: Self.lastMacKey), let pairing = pairings.first(where: { $0.serverID == last }) {
            choose(pairing)
        } else if let last = UserDefaults.standard.string(forKey: Self.lastMacKey), let share = shares.first(where: { $0.id == last }) {
            choose(share)
        } else if pairings.count == 1, shares.isEmpty {
            choose(pairings[0])
        } else if shares.count == 1, pairings.isEmpty {
            choose(shares[0])
        }
    }

    /// The name this phone shows in the Mac's list of paired phones.
    var deviceName: String { UIDevice.current.name }

    // MARK: Choosing a Mac

    func choose(_ pairing: SavedPairing) {
        PlayTarget.shared.leave()
        session?.close()
        closeShare()
        let serverID = pairing.serverID
        let session = RemoteSession(pairing: pairing, clientName: deviceName, routes: { [weak self] in
            self?.routes(to: serverID) ?? []
        })
        // The Mac words what it refuses in the language this app is showing.
        session.language = Bundle.main.preferredLocalizations.first
        session.onConnected = { [weak self, weak session] _, address in
            self?.remember(address, told: session?.server, for: serverID)
            if let session { KeptShelf.shared.connected(session) }
        }
        self.session = session
        artwork.session = session
        UserDefaults.standard.set(pairing.serverID, forKey: Self.lastMacKey)
        session.connect()
    }

    /// Tries the remote on a pretend Mac inside the app (no network, no sound). Not saved as a pairing.
    func tryDemo() {
        PlayTarget.shared.leave()
        session?.close()
        closeShare()
        let pairing = SavedPairing(serverID: DemoMac.serverID, name: String(localized: "Demo Mac"), device: "demo", key: Data())
        // One pretend Mac for the whole demo, so the queue survives the app going to the background and back.
        let mac = DemoMac(name: pairing.name, appVersion: Self.demoVersion(info: Bundle.main.infoDictionary)) { key, size in
            DemoArtwork.png(key: key, size: size)
        }
        let session = RemoteSession(pairing: pairing, clientName: deviceName) { mac }
        self.session = session
        artwork.session = session
        session.connect()
    }

    /// The version the demo's pretend Mac shows: this app's own, so it is never a release behind. Nothing if the app
    /// can't say (the line is then left out).
    nonisolated static func demoVersion(info: [String: Any]?) -> String {
        (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Back to the list of Macs.
    func leave() {
        PlayTarget.shared.leave()
        session?.close()
        closeShare()
        session = nil
        artwork.session = nil
        UserDefaults.standard.removeObject(forKey: Self.lastMacKey)
    }

    func forget(_ pairing: SavedPairing) {
        if session?.pairing.serverID == pairing.serverID { leave() }
        if !transientPairings.contains(pairing.serverID) { keychain.remove(serverID: pairing.serverID) }
        KeptShelf.shared.forget(serverID: pairing.serverID)
        PlayTarget.queues.forget(pairing.serverID)
        pairings.removeAll { $0.serverID == pairing.serverID }
    }

    // MARK: Shares

    /// Opens a share in place of a Mac: this device reads its songs itself and is where they play.
    func choose(_ share: SavedShare) {
        PlayTarget.shared.leave()
        session?.close()
        closeShare()
        // Two connections: a song being played never waits behind a scan or a cover.
        let mac = ShareMac(id: share.id, name: share.name, files: share.files(), playback: share.files(), store: share.store,
                           sayings: ShareWording.sayings, shrink: { data, size in ShareCovers.shrink(data, to: size) })
        mac.onChange = { [weak self, weak mac] in
            guard let self, let mac, self.shareMac === mac else { return }
            self.noteShare(mac)
        }
        // The same one each time the session connects: the app coming back to the front opens it again.
        let pairing = SavedPairing(serverID: share.id, name: share.name, device: "share", key: Data())
        let session = RemoteSession(pairing: pairing, clientName: deviceName) { mac }
        session.onConnected = { [weak session] _, _ in
            if let session { KeptShelf.shared.connected(session) }
        }
        shareMac = mac
        shareStatus = ShareStatus(mac)
        self.session = session
        artwork.session = session
        UserDefaults.standard.set(share.id, forKey: Self.lastMacKey)
        session.connect()
    }

    private func closeShare() {
        shareMac?.onChange = nil
        shareMac = nil
        shareRevisionSeen = 0
        shareStatus = nil
    }

    private func noteShare(_ mac: ShareMac) {
        let status = ShareStatus(mac)
        if status != shareStatus { shareStatus = status }
        if mac.revision != shareRevisionSeen {
            shareRevisionSeen = mac.revision
            libraryRevision += 1
        }
    }

    /// The share that is open, if one is.
    var openShare: SavedShare? {
        guard let id = session?.pairing.serverID else { return nil }
        return shares.first { $0.id == id }
    }

    /// Looks at the open share again for new, changed and removed songs.
    func rescanShare() { shareMac?.rescan() }

    /// Keeps a share that was added or changed (its password in the Keychain, on this device only) and opens it.
    func save(_ share: SavedShare) {
        shareKeychain.upsert(share)
        shares.removeAll { $0.id == share.id }
        shares.append(share)
        shares.sort { $0.addedAt < $1.addedAt }
        choose(share)
    }

    func forget(_ share: SavedShare) {
        if session?.pairing.serverID == share.id { leave() }
        shareKeychain.remove(id: share.id)
        share.store.remove()
        KeptShelf.shared.forget(serverID: share.id)
        PlayTarget.queues.forget(share.id)
        shares.removeAll { $0.id == share.id }
    }

    func isPaired(_ mac: DiscoveredMac) -> Bool {
        pairings.contains { $0.serverID == mac.serverID }
    }

    /// Macs on this network that aren't paired yet. Screenshot runs show a made-up one instead, so a real Mac near the
    /// capture machine (and its owner's name) never ends up in a picture.
    var unpairedMacs: [DiscoveredMac] {
        #if DEBUG
        if LaunchOptions.samplePairing {
            return [DiscoveredMac(name: "Living Room iMac", serverID: "sample-nearby", endpoint: .hostPort(host: "192.168.1.31", port: 52718))]
        }
        #endif
        return discovery.macs.filter { !isPaired($0) }
    }

    /// The search for Macs, or what it found, changed: the wait before "No Macs found" follows it.
    func searchChanged() {
        search.update(looking: discovery.isBrowsing, found: unpairedMacs.count)
    }

    /// "Try Again" under "No Macs found": the search starts afresh, and the spinner turns for a full wait.
    func lookAgain() {
        discovery.stop()
        discovery.start()
        search.lookAgain()
    }

    /// The "Demo: a made-up library" bar. Hidden in App Store captures (-VTScreenshot YES), which still use the demo library.
    nonisolated static func showsDemoNotice(isDemo: Bool, screenshotRun: Bool) -> Bool { isDemo && !screenshotRun }

    var showsDemoNotice: Bool {
        #if DEBUG
        return Self.showsDemoNotice(isDemo: true, screenshotRun: LaunchOptions.screenshot)
        #else
        return true
        #endif
    }

    // MARK: Reaching a Mac

    func pairing(serverID: String) -> SavedPairing? {
        pairings.first { $0.serverID == serverID }
    }

    /// Every way to try a paired Mac now: Bonjour if it's on this network, then its typed and last known addresses.
    func routes(to serverID: String) -> [RemoteRoute] {
        pairing(serverID: serverID)?.routes(nearby: discovery.mac(serverID: serverID)?.endpoint) ?? []
    }

    /// Saves (or with nil, removes) the address the user typed for a Mac, and tries it at once.
    func setAddress(_ address: RemoteAddress?, for serverID: String) {
        guard let index = pairings.firstIndex(where: { $0.serverID == serverID }), pairings[index].address != address else { return }
        pairings[index].address = address
        save(pairings[index])
        if session?.pairing.serverID == serverID { session?.networkChanged() }
    }

    /// Bonjour's list changed. A paired Mac that announces a port (it moved when its usual one was busy) has that port
    /// kept against its saved addresses, so it also works from away; and a paired Mac that just appeared, or moved, is
    /// tried now if the session with it isn't connected, rather than at the next retry.
    private func discovered(_ macs: [DiscoveredMac]) {
        searchChanged()
        var moved = false
        for mac in macs {
            guard let port = mac.port, let index = pairings.firstIndex(where: { $0.serverID == mac.serverID }) else { continue }
            let updated = pairings[index].noting(advertisedPort: port)
            if updated != pairings[index] {
                pairings[index] = updated
                save(updated)
                if session?.pairing.serverID == mac.serverID { moved = true }
            }
        }
        let listed = Set(macs.map(\.serverID)).intersection(pairings.map(\.serverID))
        let appeared = !listed.subtracting(listedPaired).isEmpty
        listedPaired = listed
        if let session, !session.isConnected, moved || (appeared && listed.contains(session.pairing.serverID)) {
            session.networkChanged()
        }
    }

    /// Keeps where a Mac answered and every address it said it has (at home, on Tailscale), for the next time Bonjour
    /// can't say: that is what finds the Mac from away with nothing typed.
    private func remember(_ address: RemoteAddress?, told server: ServerInfo?, for serverID: String) {
        guard let index = pairings.firstIndex(where: { $0.serverID == serverID }) else { return }
        var updated = pairings[index]
        if let address { updated.lastKnown = address }
        if let server { updated = updated.noting(server: server) }
        guard updated != pairings[index] else { return }
        pairings[index] = updated
        save(updated)
    }

    /// Why the chosen Mac can't be reached right now, as far as this device can tell.
    func trouble(reaching serverID: String) -> ReachTrouble {
        guard let pairing = pairing(serverID: serverID) else { return isOnline ? .notAnswering : .offline }
        return pairing.trouble(online: isOnline, nearby: discovery.mac(serverID: serverID) != nil, tailscaleOn: tailscaleOn)
    }

    private func save(_ pairing: SavedPairing) {
        guard !transientPairings.contains(pairing.serverID) else { return }
        keychain.upsert(pairing)
    }

    /// The cellular switch in Settings was changed: applies it to the network in use now.
    func cellularSettingChanged() { networkChanged(online: isOnline, cellular: onCellular) }

    private func networkChanged(online: Bool, cellular: Bool) {
        isOnline = online
        onCellular = cellular
        let tailscale = LocalAddresses.hasTailscale(LocalAddresses.current())
        if tailscale != tailscaleOn { tailscaleOn = tailscale }
        PlayTarget.shared.holdReason = cellular && !settings.cellularPlayback
            ? String(localized: "Playing over cellular data is off. Connect to Wi-Fi, or turn it on in Settings.") : nil
        if online {
            session?.networkChanged()
            shareMac?.lineChanged()
        }
        // Fetching to keep waits out cellular data too, and carries on when Wi-Fi is back.
        if PlayTarget.shared.holdReason == nil, let session { KeptShelf.shared.keeper(for: session)?.resume() }
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
            self.pairingError = String(localized: "Couldn’t find “\(link.name)” on this network. Pair while this device and the Mac are on the same Wi-Fi network; after that, you can reach the Mac from anywhere by its address.")
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
                pairingError = reason.isEmpty ? String(localized: "The Mac didn’t accept this device.") : reason
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
            searchChanged()
            // A connection kept while the app was away may have died without a word: ask, and connect if there is none.
            session?.checkLink()
            session?.connect()
            networkChanged(online: isOnline, cellular: onCellular)
        case .background:
            // iOS may end the app from here without telling it: the queue and the place in the song are written now.
            PlayTarget.shared.saveQueue()
            // Music playing on this device needs its songs from the Mac: the connection stays while it plays.
            if !PlayTarget.shared.isBusy { session?.suspend() }
            discovery.stop()
            searchChanged()
        default:
            break
        }
    }

    // MARK: Screenshots

    #if DEBUG
    /// Sets the app up as the launch arguments ask (see LaunchOptions). True when it chose what to open.
    private func applyLaunchOptions() -> Bool {
        if let vinyl = LaunchOptions.vinyl { settings.vinyl = vinyl }
        startScreen = LaunchOptions.screen
        if startScreen == "coverFlow" { settings.albumsLayout = .coverFlow }
        if startScreen == "albums" || startScreen == "album" { settings.albumsLayout = .grid }
        if LaunchOptions.samplePairing {
            let sample = SavedPairing(serverID: "sample-mac", name: "Studio Mac mini", device: "phone-sample", key: Data(repeating: 1, count: 32),
                                      address: RemoteAddress(host: "studio-mac.tail1a2b3.ts.net"),
                                      lastKnown: RemoteAddress(host: "192.168.1.24", port: 52718))
            transientPairings.insert(sample.serverID)
            pairings.append(sample)
        }
        guard LaunchOptions.demo else { return LaunchOptions.samplePairing }
        tryDemo()
        if LaunchOptions.play, let session {
            Task {
                for _ in 0..<40 where !session.isConnected { try? await Task.sleep(for: .milliseconds(50)) }
                await session.send(.play)
            }
        }
        return true
    }
    #endif
}
