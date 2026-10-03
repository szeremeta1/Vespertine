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

    private var pending: [Track] = []
    /// The paths in `pending`, so asking whether a track is queued doesn't walk the queue: done for every track a
    /// scan offers, that was minutes on the main thread with a large library waiting to be analyzed. Kept up to date
    /// by hand (one insert or remove as a track starts), not rebuilt on every change: rebuilding it for each track
    /// taken off a queue of tens of thousands made draining the queue quadratic.
    @ObservationIgnored private var pendingPaths: Set<String> = []
    private(set) var active: Set<String> = []     // file paths being analyzed
    private var activeNetwork = 0
    private(set) var completed = 0
    private(set) var batchTotal = 0
    private(set) var failures = 0
    /// Bumped after every saved result so views reload what they show.
    private(set) var revision = 0
    /// Local files are limited by the processor; two at a time leaves room for everything else.
    private let localWidth = 2
    /// Network files: a few reads in flight hide the round trips; playback always comes first.
    private let networkWidth = 3
    /// Set by the app: whether playback is playing or starting a track from a network share.
    var isStreamingPlayback: @MainActor () -> Bool = { false }
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

    var isRunning: Bool { !active.isEmpty || !pending.isEmpty }
    var remaining: Int { pending.count + active.count }

    func isAnalyzing(_ track: Track) -> Bool {
        active.contains(track.filePath) || pendingPaths.contains(track.filePath)
    }

    /// Analyzes these tracks next (e.g. the one shown in the inspector), ahead of background work.
    func analyzeNow(_ tracks: [Track]) {
        let files = tracks.filter { $0.isLossless && !$0.isDSD }
        let paths = Set(files.map(\.filePath))
        pending.removeAll { paths.contains($0.filePath) }
        pending.insert(contentsOf: files.filter { !active.contains($0.filePath) }, at: 0)
        rebuildPendingPaths()
        start(adding: files.count)
    }

    /// Queues everything that has no current analysis (new, changed, or analyzed by an older version).
    /// Shares analyzed by their server are left to the server.
    func analyzeLibrary(includeNetwork: Bool? = nil) {
        let network = includeNetwork ?? settings.analyzeNetworkShares
        var excluded = serverIndexed
        if !network { excluded.formUnion(library.sources.filter(\.isNetwork).compactMap(\.id)) }
        guard let tracks = try? library.database.tracksNeedingAnalysis(excludingSources: excluded) else { return }
        let fresh = tracks.filter { t in !isAnalyzing(t) }
        pending.append(contentsOf: fresh)
        rebuildPendingPaths()
        start(adding: fresh.count)
    }

    func cancel() {
        pending.removeAll()
        rebuildPendingPaths()
        if active.isEmpty { batchTotal = 0; completed = 0 }
    }

    /// Imports what's new in each connected share's server index.
    func syncServerResults() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
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
        pending.removeAll { $0.sourceId.map(indexed.contains) ?? false }
        rebuildPendingPaths()
    }

    private func rebuildPendingPaths() { pendingPaths = Set(pending.map(\.filePath)) }

    private func start(adding count: Int) {
        if !isRunning || batchTotal == 0 { completed = 0; failures = 0; batchTotal = 0 }
        batchTotal += count
        pump()
    }

    /// Playback from a share pauses network analysis (and stops what's in flight); it resumes after.
    private func watchPlayback() {
        let busy = isStreamingPlayback()
        guard busy != gate.isBusy else { return }
        gate.set(busy)
        if !busy { pump() }
    }

    private nonisolated static let analysisThreads = DispatchQueue(label: "org.szeremeta.vespertine.analysis", qos: .utility,
                                                                  attributes: .concurrent)

    private func pump() {
        // Offline shares: skip their tracks for now (the next pass picks them up), all in one go rather than one
        // array shift at a time, which on a large offline share held the main thread for many seconds.
        let queued = pending.count
        pending.removeAll { shares.isNetwork($0) && !shares.isReachable($0) }
        if pending.count != queued {
            completed += queued - pending.count
            rebuildPendingPaths()
        }
        while let index = nextStartable() {
            let next = pending.remove(at: index)
            pendingPaths.remove(next.filePath)
            let network = shares.isNetwork(next)
            active.insert(next.filePath)
            if network { activeNetwork += 1 }
            let url = next.fileURL, path = next.filePath
            let resolved = network ? (shares.cache.localURL(forKey: NetworkCache.key(for: next)) ?? url) : url
            let readsNetwork = network && resolved == url
            let gate = gate
            Task {
                // On a GCD thread rather than the Swift concurrency pool: reading a file over a share can block for as
                // long as the server takes, and blocked pool threads would stall every other task in the app.
                let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Result<FileAnalysis, Error>, Never>) in
                    Self.analysisThreads.async {
                        continuation.resume(returning: Result { try FileAnalyzer.analyze(url: resolved, shouldContinue: readsNetwork ? { !gate.isBusy } : nil) })
                    }
                }
                active.remove(path)
                if network { activeNetwork -= 1 }
                switch outcome {
                case .success(let result):
                    try? library.database.saveAnalysis(result, filePath: path)
                    completed += 1
                    revision += 1
                    library.analysisSaved()
                case .failure(AnalysisError.cancelled):
                    pending.append(next)          // stood aside for playback; try again later
                    pendingPaths.insert(next.filePath)
                case .failure:
                    failures += 1
                    completed += 1
                }
                if !isRunning { batchTotal = 0; completed = 0 }
                pump()
            }
        }
    }

    /// The first pending track that may start now: separate limits for local and network files,
    /// and no network reads while music plays from a share.
    private func nextStartable() -> Int? {
        let localActive = active.count - activeNetwork
        let networkFree = !gate.isBusy && activeNetwork < networkWidth, localFree = localActive < localWidth
        guard networkFree || localFree else { return nil }
        return pending.firstIndex { t in
            guard shares.isNetwork(t) else { return localFree }
            // A local cached copy doesn't touch the network.
            if shares.cache.localURL(forKey: NetworkCache.key(for: t)) != nil { return localFree }
            return networkFree
        }
    }
}

/// A flag analysis threads poll between chunks (lock-protected, readable from any thread).
nonisolated final class AnalysisGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    func set(_ value: Bool) { lock.lock(); busy = value; lock.unlock() }
}
