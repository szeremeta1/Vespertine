//
// Nocturne — background file analysis: one pass per file, a couple at a time, results saved to the library.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NocturneAudio
import NocturneLibrary
import Observation

@Observable
@MainActor
final class AnalysisQueue {
    private let library: LibraryStore
    private let settings: AppSettings
    private let shares: NetworkShareManager

    private var pending: [Track] = []
    private(set) var active: Set<String> = []     // file paths being analyzed
    private var activeNetwork = 0
    private(set) var completed = 0
    private(set) var batchTotal = 0
    private(set) var failures = 0
    /// Bumped after every saved result so views reload what they show.
    private(set) var revision = 0
    /// Local files are limited by the processor; two at a time leaves room for everything else.
    private let localWidth = 2
    /// Network reads are limited by round trips, so more of them in flight finish sooner (about 1.5×
    /// faster at 6 than at 2 over a remote share). Back to 2 while music streams from a share.
    private let networkWidth = 6
    private let busyNetworkWidth = 2
    /// Set by the app: whether playback is currently streaming from a network share.
    var isStreamingPlayback: @MainActor () -> Bool = { false }

    init(library: LibraryStore, settings: AppSettings, shares: NetworkShareManager) {
        self.library = library
        self.settings = settings
        self.shares = shares
    }

    var isRunning: Bool { !active.isEmpty || !pending.isEmpty }
    var remaining: Int { pending.count + active.count }

    func isAnalyzing(_ track: Track) -> Bool {
        active.contains(track.filePath) || pending.contains { $0.filePath == track.filePath }
    }

    /// Analyzes these tracks next (e.g. the one shown in the inspector), ahead of background work.
    func analyzeNow(_ tracks: [Track]) {
        let files = tracks.filter { $0.isLossless && !$0.isDSD }
        pending.removeAll { t in files.contains { $0.filePath == t.filePath } }
        pending.insert(contentsOf: files.filter { !active.contains($0.filePath) }, at: 0)
        start(adding: files.count)
    }

    /// Queues everything that has no current analysis (new, changed, or analyzed by an older version).
    func analyzeLibrary(includeNetwork: Bool? = nil) {
        let network = includeNetwork ?? settings.analyzeNetworkShares
        let excluded = network ? [] : Set(library.sources.filter(\.isNetwork).compactMap(\.id))
        guard let tracks = try? library.database.tracksNeedingAnalysis(excludingSources: excluded) else { return }
        let fresh = tracks.filter { t in !isAnalyzing(t) }
        pending.append(contentsOf: fresh)
        start(adding: fresh.count)
    }

    func cancel() {
        pending.removeAll()
        if active.isEmpty { batchTotal = 0; completed = 0 }
    }

    private func start(adding count: Int) {
        if !isRunning || batchTotal == 0 { completed = 0; failures = 0; batchTotal = 0 }
        batchTotal += count
        pump()
    }

    private func pump() {
        while let index = nextStartable() {
            let next = pending.remove(at: index)
            let network = shares.isNetwork(next)
            // Offline shares: skip for now; they'll be picked up by the next pass.
            if network, !shares.isReachable(next) { completed += 1; continue }
            active.insert(next.filePath)
            if network { activeNetwork += 1 }
            let url = next.fileURL, path = next.filePath
            let resolved = network ? (shares.cache.localURL(forKey: NetworkCache.key(for: next)) ?? url) : url
            Task {
                let result = await Task.detached(priority: .utility) { try? FileAnalyzer.analyze(url: resolved) }.value
                if let result { try? library.database.saveAnalysis(result, filePath: path) } else { failures += 1 }
                active.remove(path)
                if network { activeNetwork -= 1 }
                completed += 1
                revision += 1
                library.analysisSaved()
                if !isRunning { batchTotal = 0; completed = 0 }
                pump()
            }
        }
    }

    /// The first pending track that fits: network and local files have separate limits.
    private func nextStartable() -> Int? {
        let localActive = active.count - activeNetwork
        let networkLimit = isStreamingPlayback() ? busyNetworkWidth : networkWidth
        let networkFree = activeNetwork < networkLimit, localFree = localActive < localWidth
        guard networkFree || localFree else { return nil }
        return pending.firstIndex { shares.isNetwork($0) ? networkFree : localFree }
    }
}
