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
    private(set) var completed = 0
    private(set) var batchTotal = 0
    private(set) var failures = 0
    /// Bumped after every saved result so views reload what they show.
    private(set) var revision = 0
    private let width = 2

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
        while active.count < width, let next = pending.first {
            pending.removeFirst()
            // Offline shares: skip for now; they'll be picked up by the next pass.
            if shares.isNetwork(next), !shares.isReachable(next) { completed += 1; continue }
            active.insert(next.filePath)
            let url = next.fileURL, path = next.filePath
            let resolved = shares.isNetwork(next) ? (shares.cache.localURL(forKey: NetworkCache.key(for: next)) ?? url) : url
            Task {
                let result = await Task.detached(priority: .utility) { try? FileAnalyzer.analyze(url: resolved) }.value
                if let result { try? library.database.saveAnalysis(result, filePath: path) } else { failures += 1 }
                active.remove(path)
                completed += 1
                revision += 1
                library.analysisSaved()
                if !isRunning { batchTotal = 0; completed = 0 }
                pump()
            }
        }
    }
}
