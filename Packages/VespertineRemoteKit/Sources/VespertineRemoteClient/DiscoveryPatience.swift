//
// Vespertine Remote: how long "Looking for Macs" keeps turning. After a while with nothing found, the app says so
// and says what to try, rather than leaving a spinner that never ends.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Observation)
import Foundation
import Observation

@MainActor
@Observable
public final class DiscoveryPatience {
    public enum Stage: Sendable, Equatable {
        /// Still inside the wait: a Mac on the network normally shows up within a second or two.
        case looking
        /// The wait ran out with no Mac to pair with. The search itself carries on, so a Mac that turns up later
        /// still appears.
        case nothingFound
    }

    /// What the list shows where the Macs to pair with would be.
    public enum Row: Sendable, Equatable {
        /// There are Macs to show, or something else on the screen already says what's wrong.
        case none
        case spinner
        /// "No Macs found", what to try, and a way to look again.
        case advice
    }

    /// How long the spinner turns before the app gives its advice.
    public nonisolated static let standardWait: Duration = .seconds(10)

    public private(set) var stage: Stage = .looking

    @ObservationIgnored private let wait: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Goes up with every new wait, so a wait that was given up can't end a later one.
    @ObservationIgnored private var round = 0

    /// `sleep` is how the wait is spent (tests pass one they end by hand).
    public init(wait: Duration = DiscoveryPatience.standardWait,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.wait = wait
        self.sleep = sleep
    }

    /// Tell it whenever the search or its result changed. `looking`: the app is browsing now (not while it's in the
    /// background). `found`: how many Macs there are to pair with.
    public func update(looking: Bool, found: Int) {
        guard looking, found == 0 else {
            // Nothing to wait for. The next empty search starts with a fresh spinner and a full wait.
            reset()
            return
        }
        if stage == .looking, timer == nil { begin() }
    }

    /// The person asked to look again: the spinner comes back for a full wait.
    public func lookAgain() {
        reset()
        begin()
    }

    /// What to show where the Macs to pair with would be. `unpaired`: Macs found that aren't paired yet.
    /// `discovered`: every Mac found, paired or not. `blocked`: the search itself can't run (Local Network access is
    /// off), which the list explains in a place of its own.
    public nonisolated static func row(stage: Stage, unpaired: Int, discovered: Int, blocked: Bool) -> Row {
        if unpaired > 0 || blocked { return .none }
        switch stage {
        case .looking: return .spinner
        // Macs were found and all of them are paired already: the search works, and there is nothing to advise.
        case .nothingFound: return discovered == 0 ? .advice : .none
        }
    }

    private func reset() {
        round += 1
        timer?.cancel()
        timer = nil
        stage = .looking
    }

    private func begin() {
        round += 1
        let mine = round
        let wait = self.wait
        let sleep = self.sleep
        timer = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            guard let self, self.round == mine else { return }
            self.timer = nil
            self.stage = .nothingFound
        }
    }
}
#endif
