//
// Vespertine Remote: the app's state: the Macs it found, the ones it paired with, and the session with the chosen one.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Network
import Observation
import SwiftUI
import UIKit
import VespertineDecoders
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
    /// The Mac among the libraries that are open together, when there is one: its own connection. `session` is then
    /// all of them as one library.
    private(set) var macSession: RemoteSession?
    /// The Macs, shares and folders the library is made of, by their IDs. Kept between launches.
    private(set) var inUse: [String] = []
    /// The list of libraries is showing over the open library, to choose what it is made of.
    var choosingLibraries = false
    /// The SMB shares this device plays from by itself, without a Mac.
    private(set) var shares: [SavedShare]
    /// The folders of music on this device that were added from Files.
    private(set) var folders: [SavedFolder]
    /// The app's own folder has music in it (files opened in Vespertine from other apps): it is listed with the folders.
    private(set) var ownFolderInUse: Bool
    /// Why a file opened in Vespertine from another app couldn't be played, for an alert.
    var openedFileTrouble: String?
    /// What each open share or folder is doing (scanning, not answering), by its ID, for the screens.
    private(set) var statuses: [String: ShareStatus] = [:]
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
    @ObservationIgnored private let folderShelf = SavedFolder.shelf
    /// The permission to read each open folder, held while it is open.
    @ObservationIgnored private var folderAccesses: [String: FolderAccess] = [:]
    /// Waiting for a file just opened in Vespertine to be indexed, to play it.
    @ObservationIgnored private var playWhenRead: Task<Void, Never>?
    /// The open shares and folders, each answering as a Mac would, by their IDs.
    @ObservationIgnored private var shareMacs: [String: ShareMac] = [:]
    /// The open libraries as one, once more than one has been in use (see `use`).
    @ObservationIgnored private var joined: JoinedLibrary?
    /// Which slot each library has in the joined one (see `JoinedID`): the same for as long as the library is kept.
    @ObservationIgnored private var slots: [String: Int]
    /// More than one library has been in use at once: from then on the library is a joined one, even with one in it,
    /// so that what was queued and kept under its joined names stays.
    @ObservationIgnored private var joinedForGood: Bool
    private static let inUseKey = "librarySources"
    private static let slotsKey = "librarySlots"
    private static let joinedKey = "librariesJoined"
    /// Pairings that are never saved (a made-up one for screenshots).
    @ObservationIgnored private var transientPairings: Set<String> = []
    @ObservationIgnored private var linkWatch: Task<Void, Never>?
    /// The paired Macs Bonjour listed last time, to notice one that just showed up.
    @ObservationIgnored private var listedPaired: Set<String> = []
    @ObservationIgnored private var shareRevisions: [String: Int] = [:]
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    private static let lastMacKey = "lastMac"
    /// First-run setup is showing and hasn't reached pairing yet: the search for Macs, which makes iOS ask about the
    /// local network, hasn't started.
    @ObservationIgnored private var discoveryHeld = false

    init() {
        slots = (UserDefaults.standard.dictionary(forKey: Self.slotsKey) as? [String: Int]) ?? [:]
        joinedForGood = UserDefaults.standard.bool(forKey: Self.joinedKey)
        pairings = keychain.load().sorted { $0.pairedAt < $1.pairedAt }
        shares = shareKeychain.load().sorted { $0.addedAt < $1.addedAt }
        folders = folderShelf.load()
        ownFolderInUse = OpenedFiles.holdsAnything(SavedFolder.ownURL)
        discovery.onChange = { [weak self] macs in self?.discovered(macs) }
        // On a first run the search for Macs waits for the setup step that needs it (see `lookForMacs`).
        discoveryHeld = SetupAssistant.shared.launched(pairings: pairings.count, shares: shares.count, folders: shownFolders.count)
        if !discoveryHeld { discovery.start() }
        searchChanged()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            MainActor.assumeIsolated { self?.networkChanged(online: online, cellular: cellular) }
        }
        pathMonitor.start(queue: .main)
        PlayTarget.shared.onChoice = { [weak self] in self?.whoPlaysChanged() }
        #if DEBUG
        if applyLaunchOptions() { return }
        if let path = LaunchOptions.openFile {
            openFile(URL(fileURLWithPath: path))
            return
        }
        #endif
        // What was in use last time; before libraries could be used together, the one that was open.
        let known = pairings.map(\.serverID) + shares.map(\.id) + shownFolders.map(\.id)
        var start = UserDefaults.standard.stringArray(forKey: Self.inUseKey) ?? [UserDefaults.standard.string(forKey: Self.lastMacKey)].compactMap { $0 }
        start = start.filter(known.contains)
        if start.isEmpty, known.count == 1 { start = known }
        if !start.isEmpty { use(start) }
    }

    /// The name this phone shows in the Mac's list of paired phones.
    var deviceName: String { UIDevice.current.name }

    // MARK: What the library is made of

    func isInUse(_ id: String) -> Bool { inUse.contains(id) }

    /// Several libraries are open as one and the Mac among them is what plays: the lists hold the Mac's music only.
    var showsTheMacsMusicOnly: Bool { macSession != nil && inUse.count > 1 && !PlayTarget.shared.onThisDevice }

    /// The Mac, the share and the folder that are part of the library (the first of each), for setup's cards.
    var macInUse: SavedPairing? { pairings.first { isInUse($0.serverID) } }
    var shareInUse: SavedShare? { shares.first { isInUse($0.id) } }
    var folderInUse: SavedFolder? { shownFolders.first { isInUse($0.id) } }
    /// The names of everything the library is made of.
    var namesInUse: [String] {
        inUse.compactMap { id in pairing(serverID: id)?.name ?? shares.first { $0.id == id }?.name ?? folder(id)?.name }
    }

    /// Setup's Music step was left with these kinds chosen: what is in use of the others is taken out of the library.
    /// Nothing is forgotten; it stays in the list of libraries.
    func keepInUse(mac: Bool, share: Bool, folder: Bool) {
        let kept = inUse.filter { id in
            if isMac(id) { return mac }
            return shares.contains { $0.id == id } ? share : folder
        }
        if kept != inUse { use(kept) }
    }

    /// A library in the list was tapped. While choosing what the library is made of, it is put in or taken out; from
    /// the list with nothing open, it is opened by itself.
    func tap(_ id: String) {
        if choosingLibraries, let session, !session.isDemo {
            use(isInUse(id) ? inUse.filter { $0 != id } : inUse + [id])
        } else {
            use([id], afresh: [id])
        }
    }

    /// Opens a Mac by itself.
    func choose(_ pairing: SavedPairing) { use([pairing.serverID], afresh: [pairing.serverID]) }

    /// A library was added or changed: it joins what is open, or opens by itself when nothing is.
    private func include(_ id: String) {
        if let session, !session.isDemo {
            use(inUse.filter { $0 != id } + [id], afresh: [id])
        } else {
            use([id], afresh: [id])
        }
    }

    private func isMac(_ id: String) -> Bool { pairings.contains { $0.serverID == id } }

    private func folder(_ id: String) -> SavedFolder? {
        id == SavedFolder.ownID ? SavedFolder.own : folders.first { $0.id == id }
    }

    /// Makes the library of these Macs, shares and folders. One by itself is opened as it always was; more than one
    /// are joined as one library. `afresh` are made anew even if they were open (their address or place changed).
    private func use(_ ids: [String], afresh: Set<String> = []) {
        // One Mac at most (there is one "the Mac plays"): the one named last.
        let mac = ids.last(where: isMac)
        var wanted: [String] = []
        for id in ids where !wanted.contains(id) {
            if isMac(id) ? id == mac : shares.contains(where: { $0.id == id }) || folder(id) != nil { wanted.append(id) }
        }
        inUse = wanted
        UserDefaults.standard.set(wanted, forKey: Self.inUseKey)
        if wanted.count > 1, !joinedForGood {
            joinedForGood = true
            UserDefaults.standard.set(true, forKey: Self.joinedKey)
        }
        if session?.isDemo == true { teardown() }
        guard let first = wanted.first else {
            teardown()
            choosingLibraries = false
            return
        }
        if joinedForGood {
            join(wanted, afresh: afresh)
        } else {
            teardown()
            if let pairing = pairing(serverID: first) {
                open(pairing)
            } else if let share = shares.first(where: { $0.id == first }) {
                open(shareMac(for: share), id: share.id, name: share.name, device: "share")
            } else if let folder = folder(first) {
                open(folderMac(for: folder), id: folder.id, name: folder.name, device: "folder")
            }
        }
    }

    /// Everything that is open is closed: the player, the sessions, the shares and folders.
    private func teardown() {
        PlayTarget.shared.leave()
        session?.close()
        macSession?.close()
        macSession = nil
        joined = nil
        playWhenRead?.cancel()
        playWhenRead = nil
        for mac in shareMacs.values { mac.onChange = nil }
        shareMacs = [:]
        shareRevisions = [:]
        if !statuses.isEmpty { statuses = [:] }
        for access in folderAccesses.values { access.letGo() }
        folderAccesses = [:]
        session = nil
        artwork.session = nil
    }

    /// A session with a paired Mac, not yet connecting.
    private func newMacSession(for pairing: SavedPairing) -> RemoteSession {
        let serverID = pairing.serverID
        let session = RemoteSession(pairing: pairing, clientName: deviceName, routes: { [weak self] in
            self?.routes(to: serverID) ?? []
        })
        // The Mac words what it refuses in the language this app is showing.
        session.language = Bundle.main.preferredLocalizations.first
        return session
    }

    /// Opens a Mac by itself as the session.
    private func open(_ pairing: SavedPairing) {
        let serverID = pairing.serverID
        let session = newMacSession(for: pairing)
        session.onConnected = { [weak self, weak session] _, address in
            self?.remember(address, told: session?.server, for: serverID)
            if let session { KeptShelf.shared.connected(session) }
        }
        self.session = session
        artwork.session = session
        session.connect()
    }

    // MARK: Several libraries as one

    /// Opens these libraries as one, or changes what the open one is made of without stopping the music.
    private func join(_ ids: [String], afresh: Set<String>) {
        let library: JoinedLibrary
        let top: RemoteSession
        if let joined, let session {
            library = joined
            top = session
        } else {
            teardown()
            let name = String(localized: "Library")
            library = JoinedLibrary(name: name, sayings: LibraryWording.sayings)
            library.onChange = { [weak self] in self?.libraryRevision += 1 }
            // The same one each time the session connects: the app coming back to the front opens it again.
            let pairing = SavedPairing(serverID: JoinedLibrary.serverID, name: name, device: "library", key: Data())
            top = RemoteSession(pairing: pairing, clientName: deviceName) { library }
            top.onConnected = { [weak top] _, _ in
                if let top { KeptShelf.shared.connected(top) }
            }
            joined = library
            session = top
            artwork.session = top
        }
        // Every library that is kept has its slot, in use or not: put back in later, its songs are called what they were.
        slots = JoinedID.assign(pairings.map(\.serverID) + shares.map(\.id) + [SavedFolder.ownID] + folders.map(\.id), kept: slots)
        UserDefaults.standard.set(slots, forKey: Self.slotsKey)
        let wanted = ids.filter { slots[$0] != nil }
        let wantedSlots = Set(wanted.filter { !afresh.contains($0) }.compactMap { slots[$0] })
        var members = library.members
        // What was taken out, or is to be made anew, is let go.
        for member in members where !wantedSlots.contains(member.slot) {
            if let id = slots.first(where: { $0.value == member.slot })?.key { letGo(id) }
            (member.library as? ChannelMember)?.close()
            if member.kind == .mac {
                macSession?.close()
                macSession = nil
            }
        }
        members.removeAll { !wantedSlots.contains($0.slot) }
        for id in wanted {
            guard let slot = slots[id], !members.contains(where: { $0.slot == slot }) else { continue }
            if let pairing = pairing(serverID: id) {
                members.append(macMember(pairing, slot: slot, in: library))
            } else if let share = shares.first(where: { $0.id == id }) {
                members.append(.init(slot: slot, name: share.name, kind: .share, library: ChannelMember(shareMac(for: share))))
            } else if let folder = folder(id) {
                members.append(.init(slot: slot, name: folder.name, kind: .folder, library: ChannelMember(folderMac(for: folder))))
            }
            // What was kept from it while it was open by itself comes along.
            KeptShelf.shared.adopt(serverID: id, slot: slot, into: top)
        }
        // In the order they were chosen: where two libraries tie in a list, the earlier one's comes first.
        members.sort { a, b in
            (wanted.firstIndex { slots[$0] == a.slot } ?? .max) < (wanted.firstIndex { slots[$0] == b.slot } ?? .max)
        }
        top.mix = RemoteSession.Mix(hasMac: members.contains { $0.kind == .mac }, onlyFolders: members.allSatisfy { $0.kind == .folder })
        library.members = members
        whoPlaysChanged()
        top.connect()
    }

    /// The Mac's place in the joined library: its own session, whose news is passed on to the joined one.
    private func macMember(_ pairing: SavedPairing, slot: Int, in library: JoinedLibrary) -> JoinedLibrary.Member {
        let serverID = pairing.serverID
        let mac = newMacSession(for: pairing)
        mac.onPush = { [weak library] message in library?.macSaid(message) }
        mac.onConnected = { [weak self, weak mac, weak library] _, address in
            guard let self else { return }
            self.remember(address, told: mac?.server, for: serverID)
            // The lists now hold the Mac's music too.
            library?.changed()
            if let top = self.session, top.isJoined { KeptShelf.shared.connected(top) }
        }
        macSession = mac
        mac.connect()
        return .init(slot: slot, name: pairing.name, kind: .mac, library: mac,
                     canStream: { [weak mac] in mac?.canStream ?? false }, server: { [weak mac] in mac?.server })
    }

    /// A share or a folder is no longer open.
    private func letGo(_ id: String) {
        shareMacs[id]?.onChange = nil
        shareMacs[id] = nil
        shareRevisions[id] = nil
        if statuses[id] != nil { statuses[id] = nil }
        folderAccesses[id]?.letGo()
        folderAccesses[id] = nil
    }

    /// Output's choice of who plays changed, or the Mac came or went: while the Mac plays, the lists hold what it can
    /// play, its own library.
    private func whoPlaysChanged() {
        guard let joined else { return }
        let macPlays = macSession != nil && !PlayTarget.shared.onThisDevice
        if joined.macPlays != macPlays { joined.macPlays = macPlays }
    }

    /// The Mac's own session, whether it is open by itself or as one of several libraries.
    private func linkToMac(_ serverID: String) -> RemoteSession? {
        if let macSession, macSession.pairing.serverID == serverID { return macSession }
        if let session, session.pairing.serverID == serverID { return session }
        return nil
    }

    /// Tries the remote on a pretend Mac inside the app (no network, no sound). Not saved as a pairing.
    func tryDemo() {
        teardown()
        choosingLibraries = false
        let pairing = SavedPairing(serverID: DemoMac.serverID, name: String(localized: "Demo Mac"), device: "demo", key: Data())
        // One pretend Mac for the whole demo, so the queue survives the app going to the background and back.
        let mac = DemoMac(name: pairing.name, appVersion: Self.demoVersion(info: Bundle.main.infoDictionary)) { key, size in
            DemoArtwork.png(key: key, size: size)
        }
        #if DEBUG
        if LaunchOptions.testPlaylists {
            mac.addTestPlaylist(name: "Long Mix", songs: 1_200)
            mac.addTestPlaylist(name: "Nothing Yet", songs: 0)
        }
        #endif
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

    /// To the list of libraries. A real library stays open behind it (the music carries on) while what it is made of is
    /// chosen; the demo is left, for the library that was open before it.
    func leave() {
        if session?.isDemo == true {
            teardown()
            use(inUse)
        } else {
            choosingLibraries = true
        }
    }

    /// A library was forgotten: it is taken out of what is open.
    private func drop(_ id: String) {
        slots[id] = nil
        UserDefaults.standard.set(slots, forKey: Self.slotsKey)
        guard inUse.contains(id) else { return }
        if session?.isDemo == true {
            inUse.removeAll { $0 == id }
            UserDefaults.standard.set(inUse, forKey: Self.inUseKey)
        } else {
            use(inUse.filter { $0 != id })
        }
    }

    func forget(_ pairing: SavedPairing) {
        if !transientPairings.contains(pairing.serverID) { keychain.remove(serverID: pairing.serverID) }
        KeptShelf.shared.forget(serverID: pairing.serverID)
        PlayTarget.queues.forget(pairing.serverID)
        pairings.removeAll { $0.serverID == pairing.serverID }
        drop(pairing.serverID)
    }

    // MARK: Shares

    /// Opens a share by itself: this device reads its songs itself and is where they play.
    func choose(_ share: SavedShare) { use([share.id], afresh: [share.id]) }

    /// A share's library, answering as a Mac would; watched while it is open.
    private func shareMac(for share: SavedShare) -> ShareMac {
        // Two connections: a song being played never waits behind a scan or a cover.
        let mac = ShareMac(id: share.id, name: share.name, files: share.files(), playback: share.files(), store: share.store,
                           sayings: ShareWording.sayings, decoders: PhoneDecoders(), shrink: { data, size in ShareCovers.shrink(data, to: size) })
        watch(mac, id: share.id, folder: false)
        return mac
    }

    /// Keeps an eye on a share's or a folder's library while it is open.
    private func watch(_ mac: ShareMac, id: String, folder: Bool) {
        mac.onChange = { [weak self, weak mac] in
            guard let self, let mac, self.shareMacs[id] === mac else { return }
            self.noteShare(mac, id: id, folder: folder)
        }
        mac.combinesVersions = settings.combineVersions
        shareMacs[id] = mac
        shareRevisions[id] = 0
        statuses[id] = ShareStatus(mac, folder: folder)
    }

    /// Opens a share's or a folder's library by itself as the session, in place of a Mac.
    private func open(_ mac: ShareMac, id: String, name: String, device: String) {
        // The same one each time the session connects: the app coming back to the front opens it again.
        let pairing = SavedPairing(serverID: id, name: name, device: device, key: Data())
        let session = RemoteSession(pairing: pairing, clientName: deviceName) { mac }
        session.onConnected = { [weak session] _, _ in
            if let session { KeptShelf.shared.connected(session) }
        }
        self.session = session
        artwork.session = session
        session.connect()
    }

    private func noteShare(_ mac: ShareMac, id: String, folder: Bool) {
        let status = ShareStatus(mac, folder: folder)
        if status != statuses[id] { statuses[id] = status }
        if mac.revision != shareRevisions[id] {
            shareRevisions[id] = mac.revision
            // The lists changed under the screens: joined, every list is put together again.
            if let joined { joined.changed() } else { libraryRevision += 1 }
        }
    }

    /// The shares that are open.
    var openShares: [SavedShare] { shares.filter { statuses[$0.id] != nil } }
    /// The share that is open, when one is.
    var openShare: SavedShare? { openShares.first }
    /// What the open share or folder is doing; with several open, the first one's.
    var shareStatus: ShareStatus? { (openFolders.first?.id ?? openShares.first?.id).flatMap { statuses[$0] } }

    /// Looks at the open share again for new, changed and removed songs.
    func rescanShare() { for mac in shareMacs.values { mac.rescan() } }
    /// Looks at one open share or folder again.
    func rescan(_ id: String) { shareMacs[id]?.rescan() }

    /// Keeps a share that was added or changed (its password in the Keychain, on this device only) and opens it.
    func save(_ share: SavedShare) {
        shareKeychain.upsert(share)
        shares.removeAll { $0.id == share.id }
        shares.append(share)
        shares.sort { $0.addedAt < $1.addedAt }
        include(share.id)
    }

    func forget(_ share: SavedShare) {
        shares.removeAll { $0.id == share.id }
        drop(share.id)
        shareKeychain.remove(id: share.id)
        share.store.remove()
        KeptShelf.shared.forget(serverID: share.id)
        PlayTarget.queues.forget(share.id)
    }

    // MARK: Folders on this device

    /// The folders to list: the app's own (once it holds music) and the ones added from Files.
    var shownFolders: [SavedFolder] { (ownFolderInUse ? [SavedFolder.own] : []) + folders }

    /// The folders that are open.
    var openFolders: [SavedFolder] { shownFolders.filter { statuses[$0.id] != nil } }
    /// The folder that is open, when one is.
    var openFolder: SavedFolder? { openFolders.first }

    /// Opens a folder by itself: this device reads the songs where they are and is where they play.
    func choose(_ folder: SavedFolder) { use([folder.id], afresh: [folder.id]) }

    /// A folder's library, answering as a Mac would; watched while it is open.
    private func folderMac(for folder: SavedFolder) -> ShareMac {
        // A reader for the lists and one for the song playing, so a song never waits behind a scan.
        let files: FolderFiles, playback: FolderFiles
        if let bookmark = folder.bookmark {
            let id = folder.id
            let access = FolderAccess(bookmark: bookmark) { [weak self] fresh in
                Task { @MainActor in self?.keep(bookmark: fresh, for: id) }
            }
            folderAccesses[id] = access
            files = FolderFiles(locate: { try access.url() }, lost: { access.letGo() })
            playback = FolderFiles(locate: { try access.url() }, lost: { access.letGo() })
        } else {
            let own = SavedFolder.ownURL
            try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
            files = FolderFiles(at: own)
            playback = FolderFiles(at: own)
        }
        let mac = ShareMac(id: folder.id, name: folder.name, files: files, playback: playback, store: folder.store,
                           sayings: FolderWording.sayings, decoders: PhoneDecoders(), shrink: { data, size in ShareCovers.shrink(data, to: size) })
        // Looking at a folder on the device costs little: every time it is opened, and when a file turns out changed.
        mac.rescanAfter = 0
        mac.mendsItself = true
        watch(mac, id: folder.id, folder: true)
        return mac
    }

    /// A folder was chosen in the Files picker: keeps the way back to it (a bookmark, on this device only) and opens it.
    func add(folderAt url: URL) {
        guard let bookmark = FolderAccess.bookmark(for: url) else {
            pairingError = FolderWording.trouble(.accessDenied)
            return
        }
        pairingError = nil
        let folder = SavedFolder(name: url.lastPathComponent, bookmark: bookmark)
        folderShelf.upsert(folder)
        folders.append(folder)
        include(folder.id)
    }

    /// An added folder was pointed at its place again (the way back to it was lost, or it moved): it keeps its index,
    /// its favorites and its queue.
    func rechoose(_ folder: SavedFolder, at url: URL) {
        guard !folder.isOwn, let bookmark = FolderAccess.bookmark(for: url) else { return }
        var updated = folder
        updated.bookmark = bookmark
        keep(updated)
        include(updated.id)
    }

    func forget(_ folder: SavedFolder) {
        guard !folder.isOwn else { return }
        folders.removeAll { $0.id == folder.id }
        drop(folder.id)
        folderShelf.remove(id: folder.id)
        folder.store.remove()
        KeptShelf.shared.forget(serverID: folder.id)
        PlayTarget.queues.forget(folder.id)
    }

    private func keep(_ folder: SavedFolder) {
        folderShelf.upsert(folder)
        if let index = folders.firstIndex(where: { $0.id == folder.id }) { folders[index] = folder }
    }

    /// The system said the bookmark was out of date and gave a fresh one.
    private func keep(bookmark: Data, for id: String) {
        guard var folder = folders.first(where: { $0.id == id }) else { return }
        folder.bookmark = bookmark
        keep(folder)
    }

    /// A music file opened in Vespertine from another app ("Open in", the share sheet, Files): copied into the app's own
    /// folder, which is opened, and played from there.
    func openFile(_ url: URL) {
        let name = url.lastPathComponent
        let own = SavedFolder.ownURL
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return OpenedFiles.take(url, into: own, also: PhoneDecoders().extensions)
            }.value
            guard let self else { return }
            switch outcome {
            case .added(let path):
                self.ownFolderInUse = true
                if let mac = self.shareMacs[SavedFolder.ownID] {
                    mac.rescan()
                } else if self.joined != nil {
                    // Several libraries are open as one: the opened files join them.
                    self.use(self.inUse + [SavedFolder.ownID])
                } else {
                    self.choose(SavedFolder.own)
                }
                self.play(openedFile: path)
            case .notPlayable:
                self.openedFileTrouble = FolderWording.notPlayable(name)
            case .failed:
                self.openedFileTrouble = FolderWording.notCopied(name)
            }
        }
    }

    /// Plays the file at `path` in the app's own folder once the folder has been read and lists it.
    private func play(openedFile path: String) {
        playWhenRead?.cancel()
        playWhenRead = Task { [weak self] in
            // The scan of a folder on the device takes a moment; the wait is bounded so a file that never shows is let be.
            var lookedAgain = false
            for _ in 0..<400 {
                guard let self, !Task.isCancelled, let mac = self.shareMacs[SavedFolder.ownID], let session = self.session else { return }
                if session.isConnected, !mac.isScanning, mac.library.scanned != nil {
                    if let song = mac.library.songs.first(where: { $0.path == path }) {
                        // Among several libraries the song goes by its joined name, and plays here: no Mac has it.
                        let id = self.joined == nil ? song.id : self.slots[SavedFolder.ownID].flatMap { JoinedID.join(song.id, slot: $0) }
                        guard let id else { return }
                        if self.joined != nil { PlayTarget.shared.choose(thisDevice: true) }
                        _ = await session.run(.playTracks(ids: [id], startAt: 0, shuffled: false))
                        return
                    }
                    // A scan already under way when the file arrived may have passed its place: one more look.
                    guard !lookedAgain else { return }
                    lookedAgain = true
                    mac.rescan()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
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

    /// Setup reached pairing, or ended: the search for Macs starts if it was waiting.
    func lookForMacs() {
        guard discoveryHeld else { return }
        discoveryHeld = false
        discovery.start()
        searchChanged()
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
        linkToMac(serverID)?.networkChanged()
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
                if linkToMac(mac.serverID) != nil { moved = true }
            }
        }
        let listed = Set(macs.map(\.serverID)).intersection(pairings.map(\.serverID))
        let appeared = !listed.subtracting(listedPaired).isEmpty
        listedPaired = listed
        if let session = macSession ?? session, !session.isConnected, moved || (appeared && listed.contains(session.pairing.serverID)) {
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

    /// The versions switch in Settings was changed: the player picks by the output or not, and a share's lists follow.
    func versionsSettingChanged() {
        PlayTarget.shared.combinesVersions = settings.combineVersions
        for mac in shareMacs.values { mac.combinesVersions = settings.combineVersions }
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
            macSession?.networkChanged()
            for mac in shareMacs.values { mac.lineChanged() }
        }
        // Fetching to keep waits out cellular data too, and carries on when Wi-Fi is back.
        if PlayTarget.shared.holdReason == nil, let session { KeptShelf.shared.keeper(for: session)?.resume() }
    }

    // MARK: Pairing

    /// A `vespertine-remote://pair?…` link, from the Camera app or the in-app scanner.
    func open(_ url: URL) {
        if url.isFileURL {
            openFile(url)
            return
        }
        guard let link = PairingLink(url: url) else { return }
        pair(link: link)
    }

    func pair(link: PairingLink) {
        lookForMacs()
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
            include(pairing.serverID)
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
            if !discoveryHeld { discovery.start() }
            searchChanged()
            // A connection kept while the app was away may have died without a word: ask, and connect if there is none.
            session?.checkLink()
            session?.connect()
            macSession?.checkLink()
            macSession?.connect()
            networkChanged(online: isOnline, cellular: onCellular)
            // Music may have been put into, or taken out of, the app's own folder in Files meanwhile.
            let holds = OpenedFiles.holdsAnything(SavedFolder.ownURL) || shareMacs[SavedFolder.ownID] != nil
            if holds != ownFolderInUse { ownFolderInUse = holds }
        case .background:
            // iOS may end the app from here without telling it: the queue and the place in the song are written now.
            PlayTarget.shared.saveQueue()
            // Music playing on this device needs its songs from the Mac: the connection stays while it plays.
            if !PlayTarget.shared.isBusy {
                session?.suspend()
                macSession?.suspend()
            }
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
