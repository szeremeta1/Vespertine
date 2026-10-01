//
// Vespertine — skipping quickly while the engine is busy (a file opening on a slow share): only the
// last song asked for is opened, and the commands that still matter keep their order.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Skipping while busy")
struct SkipTests {
    typealias Command = PlaybackEngine.Command

    /// A readable summary of a command list, to compare.
    private func names(_ commands: [Command], _ items: [PlayableItem]) -> [String] {
        commands.map { command in
            switch command {
            case .play(let item): "play \(items.firstIndex(of: item) ?? -1)"
            case .pause: "pause"
            case .resume: "resume"
            case .stop: "stop"
            case .seek(let s): "seek \(Int(s))"
            case .settingsChanged: "settings"
            case .devicesChanged: "devices"
            case .queueChanged(let reload): reload ? "queue reload" : "queue"
            case .barrier: "barrier"
            }
        }
    }

    @Test("Eight quick skips open only the last song")
    func skips() {
        let items = (0..<8).map { PlayableItem(url: URL(fileURLWithPath: "/tmp/\($0).flac")) }
        let commands = items.map(Command.play)
        #expect(names(PlaybackEngine.coalesce(commands), items) == ["play 7"])
    }

    @Test("A play or stop makes earlier seeks, pauses and plays moot; later ones stay, in order")
    func order() {
        let items = (0..<3).map { PlayableItem(url: URL(fileURLWithPath: "/tmp/\($0).flac")) }
        let commands: [Command] = [.seek(10), .play(items[0]), .pause, .queueChanged(reloadCurrent: false), .resume,
                                   .play(items[1]), .devicesChanged, .seek(20), .pause, .seek(30)]
        #expect(names(PlaybackEngine.coalesce(commands), items) == ["queue", "play 1", "devices", "pause", "seek 30"])
        let stopped: [Command] = [.play(items[2]), .seek(5), .stop, .resume]
        #expect(names(PlaybackEngine.coalesce(stopped), items) == ["stop", "resume"])
    }

    @Test("Output changes and queue updates still collapse into one each")
    func settings() {
        let commands: [Command] = [.settingsChanged(EngineSettings()), .queueChanged(reloadCurrent: true),
                                   .settingsChanged(EngineSettings()), .queueChanged(reloadCurrent: false)]
        #expect(names(PlaybackEngine.coalesce(commands), []) == ["settings", "queue reload"])
    }
}
