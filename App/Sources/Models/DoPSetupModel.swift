//
// Vespertine: DoP auto-setup in the app: the hint for unknown DACs, the one-tap test, and the DAC list's refresh.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineAudio

extension AppSettings {
    /// Saves what the DoP test heard in the same two sets as the output's DoP switch, so the engine, the device list and
    /// the UID-change migration treat it exactly like a choice made there.
    func recordDoPTest(_ outcome: DoPTestOutcome, for uid: String) {
        var choices = DoPChoices(on: dopDeviceUIDs, off: dopOffDeviceUIDs)
        choices.record(outcome, for: uid)
        dopDeviceUIDs = choices.on
        dopOffDeviceUIDs = choices.off
    }
}

@Observable
@MainActor
final class DoPSetupModel {
    enum Phase: Equatable {
        case idle
        case starting
        case playing
        case question
        case finished(DoPTestOutcome)
        case aborted(String)
    }

    struct Target: Identifiable {
        let device: OutputDevice
        var id: String { device.uid }
    }

    /// The output being tested; the test sheet is shown while this is set.
    private(set) var target: Target?
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private var session: DoPTestSession?
    @ObservationIgnored private var identities: [String: DoPDeviceIdentity] = [:]
    /// Told when a saved answer or a newer DAC list changes what the engine should be given.
    @ObservationIgnored var onChoicesChanged: (() -> Void)?

    init(settings: AppSettings, player: PlayerController) {
        self.settings = settings
        self.player = player
    }

    // MARK: The DAC list

    /// At launch: pins the update key (the one Sparkle checks updates against), applies the cached list, then looks for a
    /// newer one in the background, at most once a day. Nothing here waits for the network or touches playback; a newer
    /// list reaches the engine the way any DoP choice does.
    /// With "Update the list of DoP DACs" off (Settings › Software Update), nothing is fetched; a list fetched and verified
    /// earlier is still used.
    func start() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String).flatMap { Data(base64Encoded: $0) }
        let store = DoPDACListStore.shared
        if let key { store.pin(publicKey: key) }
        let before = store.list.revision
        store.loadCache()
        if store.list.revision != before { onChoicesChanged?() }
        refreshList()
    }

    /// Looks for a newer DAC list in the background (at most once a day), when the setting allows it. Called at launch and
    /// when the setting is turned on.
    func refreshList() {
        guard settings.dopListUpdates else { return }
        let store = DoPDACListStore.shared
        Task.detached(priority: .utility) { [weak self] in
            let held = store.list.revision
            await store.refresh()
            if store.list.revision != held { await MainActor.run { self?.onChoicesChanged?() } }
        }
    }

    // MARK: The hint

    func identity(for device: OutputDevice) -> DoPDeviceIdentity {
        if let known = identities[device.uid] { return known }
        let identity = USBIdentity.identity(forUID: device.uid)
        identities[device.uid] = identity
        return identity
    }

    func hint(for device: OutputDevice) -> DoPSetupHint {
        DoPSetupHint.decide(identity: identity(for: device), transport: device.transport, capabilities: device.capabilities,
                            on: settings.dopDeviceUIDs, off: settings.dopOffDeviceUIDs, list: DoPDACListStore.shared.list)
    }

    // MARK: The test

    /// Opens the test for `device`: stops playback (the DAC is the test's alone while the clip plays) and starts the clip.
    /// Nothing is saved unless the listener answers after a clip the engine really played as DoP.
    func begin(_ device: OutputDevice) {
        guard session == nil else { return }
        target = Target(device: device)
        phase = .starting
        let session = DoPTestSession(device: device, exclusive: settings.exclusiveMode)
        session.onPhase = { [weak self] phase in Task { @MainActor in self?.handle(phase) } }
        self.session = session
        player.stop()
        let engine = player.engine
        Task.detached {
            engine.stopAndWait(timeout: 2)
            session.start()
        }
    }

    private func handle(_ new: DoPTestSession.Phase) {
        guard session != nil else { return }        // a late word from a test that was closed
        let words = DoPTestConstants.wording
        switch new {
        case .idle, .done: break
        case .starting: phase = .starting
        case .playing: phase = .playing
        case .awaitingAnswer: phase = .question
        case .aborted(let reason):
            switch reason {
            case .cancelled: close()
            case .deviceChanged: phase = .aborted(words.abortedDeviceChanged)
            case .notPlayedAsDoP: phase = .aborted(words.notPlayedAsDoP)
            case .failed: phase = .aborted(words.notPlayedAsDoP)
            }
        }
    }

    func answer(_ outcome: DoPTestOutcome) {
        guard let session, let target else { return }
        guard let accepted = session.answer(outcome) else { phase = .aborted(DoPTestConstants.wording.notPlayedAsDoP); return }
        settings.recordDoPTest(accepted, for: target.device.uid)
        phase = .finished(accepted)
        onChoicesChanged?()
    }

    /// Ends a test in progress (the sheet's Cancel, or it being closed).
    func cancel() { close() }

    /// Closes the sheet.
    func close() {
        session?.cancel()
        session = nil
        target = nil
        phase = .idle
    }
}
