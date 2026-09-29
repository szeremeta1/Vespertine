//
// Vespertine — switching outputs while playing (diagnostic, real hardware).
//   VESPERTINE_SWITCH_DEVICES="FiiO|AirPods" VESPERTINE_SWITCH_FILE=<audio file> swift test --filter DeviceSwitch
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import Foundation
import Testing
@testable import VespertineAudio

@Suite(.serialized) struct DeviceSwitchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_SWITCH_DEVICES"] != nil))
    func switchBackAndForth() async throws {
        let env = ProcessInfo.processInfo.environment
        let names = env["VESPERTINE_SWITCH_DEVICES"]!.split(separator: "|").map(String.init)
        let url = URL(fileURLWithPath: env["VESPERTINE_SWITCH_FILE"]!)
        let rounds = Int(env["VESPERTINE_SWITCH_ROUNDS"] ?? "6") ?? 6
        let interval = Double(env["VESPERTINE_SWITCH_INTERVAL"] ?? "3") ?? 3
        func find(_ name: String) -> OutputDevice? { OutputDevices.list().first { $0.name.localizedCaseInsensitiveContains(name) } }
        let devices = try names.map { try #require(find($0), "no device named \($0)") }
        let t0 = Date()
        func stamp() -> String { String(format: "%6.2f", Date().timeIntervalSince(t0)) }
        let events = LockedLog()
        let engine = PlaybackEngine()
        defer { engine.stop() }
        engine.eventHandler = { event in events.add("\(stamp()) event \(event)") }
        var settings = EngineSettings()
        settings.exclusive = true; settings.integerMode = true
        settings.dopDeviceUIDs = Set(devices.filter { $0.name.contains("FiiO") }.map(\.uid))
        settings.deviceUID = devices[0].uid
        engine.update(settings: settings)
        engine.play(PlayableItem(url: url))
        for round in 0..<rounds {
            let target = devices[(round + (round == 0 ? 0 : 1)) % devices.count]
            if round > 0 {
                settings.deviceUID = target.uid
                engine.update(settings: settings)
                events.add("\(stamp()) switch → \(target.name) (listed ids: \(OutputDevices.list().filter { names.contains(where: $0.name.contains) }.map { "\($0.name)#\($0.id)" }))")
            }
            let start = Date()
            var reached: Double?
            var lastPos = engine.snapshot.position
            while Date().timeIntervalSince(start) < interval {
                try await Task.sleep(for: .milliseconds(50))
                let s = engine.snapshot
                if reached == nil, s.state == .playing, s.signalPath?.deviceUID == target.uid, s.position > lastPos + 0.05 {
                    reached = Date().timeIntervalSince(start)
                }
                lastPos = max(lastPos, s.position)
            }
            let s = engine.snapshot
            events.add("\(stamp()) round \(round) \(target.name): playing after \(reached.map { String(format: "%.2fs", $0) } ?? "NEVER") state \(s.state) on \(s.signalPath?.deviceName ?? "-") pos \(String(format: "%.1f", s.position)) underruns \(s.underruns) waiting \(s.waitingForDevice ?? "-") error \(s.lastError ?? "-")")
        }
        print(events.lines.joined(separator: "\n"))
    }
}

private final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite struct DeviceListTimingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_SWITCH_DEVICES"] != nil))
    func listTiming() {
        for i in 0..<5 {
            let t = Date()
            let list = OutputDevices.list()
            let ms = Date().timeIntervalSince(t) * 1000
            let per = list.map { d -> String in
                let t = Date(); _ = d.profile; _ = DeviceQuery.outputDevices(dopEnabledUIDs: []).first { $0.id == d.id }
                return "\(d.name) \(String(format: "%.0f", Date().timeIntervalSince(t) * 1000))ms"
            }
            print("list #\(i): \(String(format: "%.1f", ms)) ms for \(list.count) devices; \(per)")
        }
    }
}

@Suite struct SkipLatencyTests {
    /// VESPERTINE_SKIP_FROM (local, long) then VESPERTINE_SKIP_TO (e.g. on a share) on VESPERTINE_SWITCH_DEVICES' first device.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_SKIP_TO"] != nil))
    func oldSongStopsAtOnce() async throws {
        let env = ProcessInfo.processInfo.environment
        let device = try #require(OutputDevices.list().first { $0.name.localizedCaseInsensitiveContains(env["VESPERTINE_SWITCH_DEVICES"] ?? "") })
        let engine = PlaybackEngine()
        defer { engine.stop() }
        var settings = EngineSettings(); settings.deviceUID = device.uid; settings.exclusive = true
        engine.update(settings: settings)
        engine.play(PlayableItem(url: URL(fileURLWithPath: env["VESPERTINE_SKIP_FROM"]!)))
        try await Task.sleep(for: .seconds(3))
        _ = engine.takePeaks()
        try await Task.sleep(for: .milliseconds(200))
        let before = engine.takePeaks()
        let next = PlayableItem(url: URL(fileURLWithPath: env["VESPERTINE_SKIP_TO"]!))
        let t = Date()
        engine.play(next)
        var silentAfter: Double?, startedAfter: Double?
        while Date().timeIntervalSince(t) < 30, startedAfter == nil {
            try await Task.sleep(for: .milliseconds(20))
            let p = engine.takePeaks()
            if silentAfter == nil, max(p.left, p.right) == 0 { silentAfter = Date().timeIntervalSince(t) }
            let s = engine.snapshot
            if s.item?.id == next.id, s.state == .playing, s.position > 0.05 { startedAfter = Date().timeIntervalSince(t) }
        }
        print("skip: old peak before \(before), silent after \(silentAfter.map { String(format: "%.3f s", $0) } ?? "never"), new song playing after \(startedAfter.map { String(format: "%.2f s", $0) } ?? "never")")
        #expect((silentAfter ?? 99) < 0.15)
    }
}
