//
// Vespertine — background file analysis: one pass per file, a couple at a time, results saved to the library.
// Shares whose server runs `vespertine-analyze` get their results from the server's index instead.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineLibrary
import Observation

@Observable
@MainActor
final class AnalysisQueue {
    private let library: LibraryStore
    private let settings: AppSettings
    private let shares: NetworkShareManager

    /// Files waiting their turn, in two lines that drain side by side: files on this Mac (limited by the processor)
    /// and files on network shares (limited by the network, held back while music streams from a share). One line
    /// made a library of both take turns, so a share's slow reads held back the local files queued behind them.
    private var pendingLocal = TrackQueue()
    private var pendingNetwork = TrackQueue()
    /// The paths in both lines, so asking whether a track is queued doesn't walk the queue: done for every track a
    /// scan offers, that was minutes on the main thread with a large library waiting to be analyzed. Kept up to date
    /// by hand (one insert or remove as a track starts), not rebuilt on every change: rebuilding it for each track
    /// taken off a queue of tens of thousands made draining the queue quadratic.
    @ObservationIgnored private var pendingPaths: Set<String> = []
    /// The offline shares the queue was last cleared of, so a pass that has nothing new to clear doesn't walk the
    /// queue (it runs after every finished track). Nil once tracks are added: they haven't been looked at yet.
    @ObservationIgnored private var clearedOffline: Set<Int64>?
    private(set) var active: Set<String> = []     // file paths being analyzed
    /// Analyses in flight that read over the network (a share file with a complete local copy reads from disk).
    private var activeNetwork = 0
    private(set) var completed = 0
    private(set) var batchTotal = 0
    private(set) var failures = 0
    /// Bumped after every saved result so views reload what they show.
    private(set) var revision = 0
    /// Local files are limited by the processor: half its cores (two to six) leaves room for everything else, and two
    /// in Low Power Mode. Each analysis is one thread decoding and measuring, at utility priority.
    private var localWidth: Int {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
    /// Network files: a few reads in flight hide the round trips; playback always comes first.
    private let networkWidth = 3
    /// Set by the app: how much of the network the song playing from a share needs right now.
    var playbackShareClaim: @MainActor () -> PlaybackShareClaim = { .idle }
    /// What `playbackShareClaim` said at the last look, so a change can start the files it lets through.
    @ObservationIgnored private var shareClaim = PlaybackShareClaim.idle
    /// Called with each share's server status after a sync (the app rescans when the server ran after our last scan).
    var onServerStatus: @MainActor (Int64, ServerAnalysisStatus) -> Void = { _, _ in }

    /// Network sources whose server publishes analysis results (`.vespertine/analysis.jsonl`).
    private(set) var serverIndexed: Set<Int64> = []
    /// The server's own progress, per source.
    private(set) var serverStatus: [Int64: ServerAnalysisStatus] = [:]
    /// Results imported from servers this session.
    private(set) var serverImported = 0
    private let importer = ServerAnalysisImporter()
    private var syncing = false
    private var loops: [Task<Void, Never>] = []
    /// Set by Stop: analyses that stood aside for playback aren't queued again. Cleared when analysis is asked for.
    /// Observed, so the sidebar's progress goes at Stop (`isStopping`).
    private var stopped = false
    /// Bumped by Stop, so a library query still running when Stop is pressed doesn't queue its results afterwards.
    @ObservationIgnored private var generation = 0

    /// Read by analysis threads: true while network analysis must stand aside for playback.
    private let gate = AnalysisGate()

    init(library: LibraryStore, settings: AppSettings, shares: NetworkShareManager) {
        self.library = library
        self.settings = settings
        self.shares = shares
    }

    /// Starts the periodic server sync and the playback watch. Call once, after launch.
    func start() {
        guard loops.isEmpty else { return }
        loops.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                // Out of use, the server's index waits: reading it could wake the NAS's disks.
                if self?.shares.isInUse ?? false { await self?.syncServerResults() }
                try? await Task.sleep(for: .seconds(300))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.watchPlayback()
                try? await Task.sleep(for: .milliseconds(500))
            }
        })
    }

    var isRunning: Bool { !active.isEmpty || !pendingLocal.isEmpty || !pendingNetwork.isEmpty }
    var remaining: Int { pendingLocal.count + pendingNetwork.count + active.count }
    /// Stopped, with files already being read left to finish (a share file can take a while).
    var isStopping: Bool { stopped && !active.isEmpty }

    func isAnalyzing(_ track: Track) -> Bool {
        active.contains(track.filePath) || pendingPaths.contains(track.filePath)
    }

    /// Analyzes these tracks next (e.g. the one shown in the inspector), ahead of background work.
    func analyzeNow(_ tracks: [Track]) {
        var seen = Set<String>()
        let files = tracks.filter { $0.isLossless && !$0.isDSD && seen.insert($0.filePath).inserted }
        guard !files.isEmpty else { return }
        // Those already queued move to the front; they're in the batch's count already.
        let added = files.count { !active.contains($0.filePath) && !pendingPaths.contains($0.filePath) }
        pendingLocal.removeAll { seen.contains($0.filePath) }
        pendingNetwork.removeAll { seen.contains($0.filePath) }
        let waiting = files.filter { !active.contains($0.filePath) }
        pendingLocal.prepend(waiting.filter { !shares.isNetwork($0) })
        pendingNetwork.prepend(waiting.filter(shares.isNetwork))
        clearedOffline = nil
        rebuildPendingPaths()
        start(adding: added)
    }

    /// Analyzes the songs of a selection that have no current result, ahead of background work; a selection that is
    /// all analyzed already is analyzed again (it was asked for). A single song is always analyzed again.
    func analyze(_ tracks: [Track]) {
        let files = tracks.filter { $0.isLossless && !$0.isDSD }
        guard files.count > 1 else { analyzeNow(files); return }
        let ids = Set(files.compactMap(\.id)), database = library.database, generation = generation
        Task { [weak self] in
            await self?.library.storedAnalysesJudged()
            let needed = await Task.detached(priority: .userInitiated) {
                (try? database.tracksNeedingAnalysis(among: ids)) ?? []
            }.value
            guard let self, self.generation == generation else { return }
            self.analyzeNow(needed.isEmpty ? files : needed)
        }
    }

    /// Queues everything that has no current analysis (new, changed, or analyzed by an older version). Shares
    /// analyzed by their server are left to the server. `includeNetwork`: nil follows the setting (automatic
    /// analysis); Analyze Library asks for the shares too, since that's what pressing it means.
    func analyzeLibrary(includeNetwork: Bool? = nil) {
        let network = includeNetwork ?? settings.analyzeNetworkShares
        let database = library.database, generation = generation
        Task { [weak self] in
            // Results an analyzer update can judge from their measurements (done at launch) aren't queued to be read again.
            await self?.library.storedAnalysesJudged()
            guard let self, self.generation == generation else { return }
            var excluded = self.serverIndexed
            if !network { excluded.formUnion(self.library.sources.filter(\.isNetwork).compactMap(\.id)) }
            // Off the main thread: on a large library this query and its tens of thousands of rows took seconds.
            let tracks = await Task.detached(priority: .utility) { [excluded] in
                try? database.tracksNeedingAnalysis(excludingSources: excluded)
            }.value
            guard let tracks, self.generation == generation else { return }
            self.enqueue(tracks)
        }
    }

    /// Adds tracks at the back of their lines, skipping any already queued or in flight.
    private func enqueue(_ tracks: [Track]) {
        var fresh: [Track] = []
        for t in tracks where !active.contains(t.filePath) && pendingPaths.insert(t.filePath).inserted { fresh.append(t) }
        guard !fresh.isEmpty else { return }
        pendingLocal.append(fresh.filter { !shares.isNetwork($0) })
        pendingNetwork.append(fresh.filter(shares.isNetwork))
        clearedOffline = nil
        start(adding: fresh.count)
    }

    func cancel() {
        stopped = true
        generation += 1
        pendingLocal.removeAll()
        pendingNetwork.removeAll()
        rebuildPendingPaths()
        if active.isEmpty { batchTotal = 0; completed = 0 }
    }

    /// Imports what's new in each connected share's server index.
    func syncServerResults() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        // What the import looks for is what still needs analyzing: only once stored results are judged anew.
        await library.storedAnalysesJudged()
        let sources = shares.sources.filter { shares.status(of: $0).isConnected }
        let importer = importer, database = library.database
        var indexed: Set<Int64> = [], statuses: [Int64: ServerAnalysisStatus] = [:], imported = 0
        for source in sources {
            guard let id = source.id else { continue }
            // Reads the index over the network: on a GCD thread, so a stalled share can't hold one of the few
            // threads Swift concurrency runs everything else on. A read that outlasts the deadline is skipped.
            let result = await NetworkVolume.blocking(timeout: 120, otherwise: (false, nil, 0)) { () -> (Bool, ServerAnalysisStatus?, Int) in
                guard let root = ServerAnalysisImporter.indexRoot(for: source) else { return (false, nil, 0) }
                let n = (try? importer.importNew(for: source, into: database)) ?? 0
                return (true, ServerAnalysisImporter.status(at: root), n)
            }
            if result.0 { indexed.insert(id) }
            if let status = result.1 { statuses[id] = status }
            imported += result.2
        }
        serverIndexed = indexed
        serverStatus = statuses
        for (id, status) in statuses { onServerStatus(id, status) }
        if imported > 0 {
            serverImported += imported
            revision += 1
            library.analysisSaved()
        }
        // Anything queued for a share its server now covers doesn't need to be read over the network.
        pendingNetwork.removeAll { $0.sourceId.map(indexed.contains) ?? false }
        rebuildPendingPaths()
    }

    private func rebuildPendingPaths() {
        pendingPaths = Set(pendingLocal.elements.map(\.filePath)).union(pendingNetwork.elements.map(\.filePath))
    }

    private func start(adding count: Int) {
        stopped = false
        if !isRunning || batchTotal == 0 { completed = 0; failures = 0; batchTotal = 0 }
        batchTotal += count
        pump()
    }

    /// A song streaming from a share leaves network analysis one file at a time, and stops it (what's in flight
    /// stands aside to be read again later) while the song starts or its buffer runs low. Pausing it for as long as
    /// any share song played left an analysis asked for during an evening's listening at 0 forever.
    private func watchPlayback() {
        let claim = playbackShareClaim()
        guard claim != shareClaim else { return }
        shareClaim = claim
        gate.set(claim == .all)
        if claim != .all { pump() }
    }

    private nonisolated static let analysisThreads = DispatchQueue(label: "org.szeremeta.vespertine.analysis", qos: .utility,
                                                                  attributes: .concurrent)

    private func pump() {
        // Offline shares: skip their tracks for now (the next pass picks them up), all in one go rather than one
        // array shift at a time, which on a large offline share held the main thread for many seconds. The queue is
        // only walked when a share has gone offline since the last pass or tracks were added, not after every track.
        let offline = Set(library.sources.filter { $0.isNetwork && !shares.status(of: $0).isConnected }.compactMap(\.id))
        if !offline.isEmpty, !(clearedOffline.map { offline.isSubset(of: $0) } ?? false) {
            let queued = pendingNetwork.count
            pendingNetwork.removeAll { $0.sourceId.map(offline.contains) ?? false }
            if pendingNetwork.count != queued {
                completed += queued - pendingNetwork.count
                rebuildPendingPaths()
            }
        }
        clearedOffline = offline
        while let next = takeNext() {
            pendingPaths.remove(next.filePath)
            let network = shares.isNetwork(next)
            let url = next.fileURL, path = next.filePath
            let resolved = network ? (shares.cache.localURL(forKey: NetworkCache.key(for: next)) ?? url) : url
            let readsNetwork = network && resolved == url
            active.insert(path)
            if readsNetwork { activeNetwork += 1 }
            let gate = gate, database = library.database
            Task {
                // On a GCD thread rather than the Swift concurrency pool: reading a file over a share can block for as
                // long as the server takes, and blocked pool threads would stall every other task in the app. The
                // result is saved there too, so the main thread only counts it.
                let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Result<FileAnalysis, Error>, Never>) in
                    Self.analysisThreads.async {
                        let result = Result { try FileAnalyzer.analyzeWithProfile(url: resolved, shouldContinue: readsNetwork ? { !gate.isBusy } : nil) }
                        if case .success(let done) = result {
                            try? database.saveAnalysis(done.analysis, filePath: path)
                            // How the song starts and ends, from the same pass (Smart Mix).
                            if let profile = done.profile { try? database.saveTransitionProfiles([(profile, path)]) }
                        }
                        continuation.resume(returning: result.map(\.analysis))
                    }
                }
                active.remove(path)
                if readsNetwork { activeNetwork -= 1 }
                switch outcome {
                case .success:
                    completed += 1
                    revision += 1
                    library.analysisSaved()
                case .failure(AnalysisError.cancelled):
                    // Stood aside for playback: try again later, unless analysis was stopped meanwhile.
                    guard !stopped else { break }
                    pendingNetwork.append([next])
                    pendingPaths.insert(path)
                    clearedOffline = nil
                case .failure:
                    failures += 1
                    completed += 1
                }
                if !isRunning { batchTotal = 0; completed = 0 }
                pump()
            }
        }
    }

    /// How many share files at the front of their line are checked for a cached copy when only local slots are free.
    private static let cachedLookahead = 16

    /// The next track that may start now: local files while local slots are free (then share files with a complete
    /// local copy, which read from disk too), and share files while network slots are free and no music plays from a share.
    private func takeNext() -> Track? {
        if active.count - activeNetwork < localWidth {
            if let t = pendingLocal.popFirst() { return t }
            // Finding a cached copy hashes the track and checks the disk, so only the front of the line is looked at;
            // a line of thousands of share files isn't hashed on the main thread every time a local file finishes.
            if let i = pendingNetwork.elements.prefix(Self.cachedLookahead).firstIndex(where: {
                shares.cache.localURL(forKey: NetworkCache.key(for: $0)) != nil
            }) {
                return pendingNetwork.remove(at: i)
            }
        }
        let width = shareClaim == .streaming ? 1 : networkWidth
        if !gate.isBusy && activeNetwork < width { return pendingNetwork.popFirst() }
        return nil
    }
}

/// How much of the network a song playing from a share needs, which decides how much analysis may read from shares.
enum PlaybackShareClaim {
    /// Nothing plays from a share, or the song has a complete local copy: analysis reads at full width.
    case idle
    /// The song streams with its buffer in good shape: one analysis read at a time alongside it.
    case streaming
    /// The song is starting or its buffer is low: no analysis reads from shares.
    case all
}

/// A line of tracks: taking from the front is constant time (a plain array shifted every element along each time,
/// which over a queue of tens of thousands added up to minutes of the main thread).
struct TrackQueue {
    private var items: [Track] = []
    private var head = 0

    var isEmpty: Bool { head == items.count }
    var count: Int { items.count - head }
    /// What's waiting, front first. Indices are the array's, as `remove(at:)` takes them.
    var elements: ArraySlice<Track> { items[head...] }

    mutating func popFirst() -> Track? {
        guard head < items.count else { return nil }
        let first = items[head]
        head += 1
        // Drop what's been taken once it's most of the array, so memory follows what's waiting.
        if head > 1024 && head * 2 > items.count { items.removeFirst(head); head = 0 }
        return first
    }

    mutating func remove(at index: Int) -> Track { items.remove(at: index) }
    mutating func append(_ tracks: [Track]) { items.append(contentsOf: tracks) }
    mutating func prepend(_ tracks: [Track]) { items.replaceSubrange(items.startIndex..<head, with: tracks); head = 0 }
    mutating func removeAll(where shouldRemove: (Track) -> Bool) { items = items[head...].filter { !shouldRemove($0) }; head = 0 }
    mutating func removeAll() { items = []; head = 0 }
}

/// A flag analysis threads poll between chunks (lock-protected, readable from any thread).
nonisolated final class AnalysisGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    func set(_ value: Bool) { lock.lock(); busy = value; lock.unlock() }
}
