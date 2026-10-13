//
// Vespertine — runs the loopback self-test from the app: pauses playback, plays the test signal through a virtual
// loopback device with a separate engine, and keeps the results. A software-path check; it never changes the
// BIT-PERFECT badge.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import VespertineAudio

@Observable
@MainActor
final class LoopbackTest {
    enum Phase: Equatable { case setup, running, finished }

    var phase: Phase = .setup
    var mode: LoopbackMode = .quick
    /// The chosen output's UID; nil picks "Vespertine Loopback" when it's there.
    var outputUID: String?
    private(set) var total = 0
    private(set) var currentCase: String?
    private(set) var done: [LoopbackCaseResult] = []
    private(set) var report: LoopbackReport?
    private(set) var error: String?
    private(set) var saved: [LoopbackSavedResult]

    @ObservationIgnored private let store: LoopbackResultStore
    let appVersion: String
    let macOS: String

    init(dataDirectory: URL) {
        store = LoopbackResultStore(url: dataDirectory.appendingPathComponent("loopback-results.json"))
        saved = store.load()
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    /// Outputs the test may play to: virtual devices only, since it plays full-scale noise.
    static func candidates(_ devices: [OutputDevice]) -> [OutputDevice] {
        devices.filter { LoopbackGuard.refusal($0) == nil }
    }

    func output(in devices: [OutputDevice]) -> OutputDevice? {
        let candidates = Self.candidates(devices)
        if let outputUID, let chosen = candidates.first(where: { $0.uid == outputUID }) { return chosen }
        return LoopbackGuard.dedicatedDevice(in: candidates)
    }

    var progress: Double { total == 0 ? 0 : Double(done.count) / Double(total) }

    func reset() {
        guard phase != .running else { return }
        phase = .setup
        done = []
        report = nil
        error = nil
        currentCase = nil
    }

    /// Pauses the player (and lets go of the device when it's playing to the test's own), then runs every case
    /// off the main thread.
    func run(on output: OutputDevice, player: PlayerController) async {
        guard phase != .running else { return }
        reset()
        guard await LoopbackPermission.ensure() else {
            error = LoopbackError.permissionDenied.localizedDescription
            phase = .finished
            return
        }
        if player.outputDevice?.uid == output.uid { player.stop() } else if player.isPlaying { player.togglePlayPause() }
        let cases = LoopbackPlan.cases(rates: output.capabilities.sampleRates, mode: mode)
        guard !cases.isEmpty else {
            error = "\(output.name) offers none of the test's sample rates (44.1 to 384 kHz)."
            phase = .finished
            return
        }
        total = cases.count
        phase = .running
        let mode = mode, appVersion = appVersion
        let result: Result<LoopbackReport, any Error> = await Task.detached(priority: .userInitiated) {
            Result {
                let runner = try LoopbackRunner(output: output)
                return try runner.run(cases, mode: mode, appVersion: appVersion) { _, c in
                    Task { @MainActor [weak self] in if self?.report == nil { self?.currentCase = c.name } }
                } caseDone: { r in
                    Task { @MainActor [weak self] in if let self, self.report == nil { self.done.append(r) } }
                }
            }
        }.value
        switch result {
        case .success(let report):
            self.report = report
            done = report.cases
            do { saved = try store.save(report) } catch { self.error = "The results couldn't be saved: \(error.localizedDescription)" }
        case .failure(let error):
            self.error = error.localizedDescription
        }
        currentCase = nil
        phase = .finished
    }

    func copyReport() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.markdown, forType: .string)
    }

    /// The saved result for what's playing, when its source format was checked on this macOS and Vespertine version.
    /// Only for paths that leave the samples alone: the test forces every processing step off.
    func result(for path: SignalPath) -> LoopbackSavedResult? {
        guard path.plan.mode == .pcm, !path.modifiesSamples, !path.isResampling, !path.plan.dsdConvertedToPCM,
              let bits = path.source.bitDepth else { return nil }
        return LoopbackResultStore.latest(in: saved, sampleRate: path.source.sampleRate, bits: bits,
                                          matchSixteenBit: path.plan.sixteenBit != nil, integerMode: path.applied.integerMode,
                                          macOS: macOS, appVersion: appVersion)
    }
}
