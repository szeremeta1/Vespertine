//
// Vespertine Remote: a level the user drags (the volume): sent to the Mac while the slider moves, the newest value
// only, and shown where the finger put it until the Mac says the same.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Observation)
import Foundation
import Observation

@MainActor
@Observable
public final class LiveLevel {
    /// Where the user put the level, while the Mac hasn't caught up with it: a slider shows this rather than what the
    /// Mac last reported, so the thumb stays under the finger and doesn't jump back to an older level on the way.
    public private(set) var held: Double?

    /// The least time between two sends (about 25 a second). A send also waits for the reply to the one before it,
    /// so a slow connection is sent fewer levels, never a backlog of them.
    @ObservationIgnored public var interval: Duration = .milliseconds(40)
    /// How long after the last send a level is still shown when the Mac never reports it (an output whose volume
    /// moves in coarse steps settles on a level nearby).
    @ObservationIgnored public var settle: Duration = .milliseconds(1500)
    /// How near the Mac's level has to be to count as the one sent.
    @ObservationIgnored public var tolerance = 0.015

    @ObservationIgnored private let send: @MainActor (Double) async -> Void
    /// The newest level not sent yet: a newer one replaces it.
    @ObservationIgnored private var pending: Double?
    @ObservationIgnored private var dragging = false
    /// The Mac's level as last reported.
    @ObservationIgnored private var lastReported: Double?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var release: Task<Void, Never>?

    public init(send: @escaping @MainActor (Double) async -> Void) {
        self.send = send
    }

    /// What a slider shows when the Mac reports `reported`.
    public func shown(reported: Double) -> Double { held ?? reported }

    /// The slider moved to `level` (called for every movement of a drag).
    public func drag(to level: Double) {
        dragging = true
        release?.cancel()
        release = nil
        held = level
        pending = level
        guard pump == nil else { return }
        pump = Task { [weak self] in await self?.drain() }
    }

    /// The finger lifted. The last level is still sent if it wasn't, and shown until the Mac reports it.
    public func end() {
        guard dragging else { return }
        dragging = false
        if pump == nil { awaitReport() }
    }

    /// The Mac reported its level (with every playback update). Reports during a drag are older than the finger.
    public func reported(_ level: Double?) {
        lastReported = level
        if !dragging, pump == nil { letGoIfReported() }
    }

    /// Shows the Mac's level again now (the connection dropped, the output changed).
    public func reset() {
        pending = nil
        dragging = false
        letGo()
    }

    private func drain() async {
        let clock = ContinuousClock()
        while let level = pending {
            pending = nil
            let started = clock.now
            await send(level)
            let spent = clock.now - started
            // Also after the last one: the next movement of the same drag is a moment away.
            if spent < interval { try? await Task.sleep(for: interval - spent) }
        }
        pump = nil
        if !dragging, held != nil { awaitReport() }
    }

    private func letGoIfReported() {
        guard let held, let lastReported, abs(lastReported - held) <= tolerance else { return }
        letGo()
    }

    /// Everything is sent and the finger is up: the level is shown until the Mac reports it, or for `settle`.
    private func awaitReport() {
        letGoIfReported()
        guard held != nil else { return }
        release?.cancel()
        let settle = settle
        release = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.letGo()
        }
    }

    private func letGo() {
        release?.cancel()
        release = nil
        if held != nil { held = nil }
    }
}
#endif
