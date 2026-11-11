// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Fill the room on the current song", .serialized)
struct RoomRenderSwitchTests {
    @Test("On and off rebuild the current song, preserving its position and transport state", arguments: [false, true])
    func currentSong(paused: Bool) async throws {
        let rig = try PlayPauseRig()
        try await rig.runScript { rig in
            var group = GroupFixtures.quad()
            let devices = group.members.enumerated().map { index, member in
                OutputDevice(id: UInt32(5000 + index), uid: member.deviceUID, name: member.name,
                             manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: PlayPauseRig.rate,
                             capabilities: rig.device.capabilities, hasHardwareVolume: false, isDefault: false)
            }
            rig.engine.outputListing = { devices }
            var settings = EngineSettings()
            settings.deviceUID = group.outputUID
            settings.speakerGroups = [group, GroupFixtures.quad(name: "Inactive")]
            settings.releaseExclusiveAfterPause = 600
            rig.engine.update(settings: settings)
            // Hold the simulated clock, not the engine: opens and decoding still run, but CI scheduling cannot drain the song.
            rig.holdOutput(true)
            rig.engine.play(rig.item())
            try #require(rig.scriptWait(timeout: 120) { $0.state == .playing && $0.signalPath != nil })
            rig.engine.seek(to: 5)
            try #require(rig.scriptWait(timeout: 120) { $0.position >= 5 })
            if paused {
                rig.engine.pause()
                try #require(rig.scriptWait(timeout: 120) { $0.state == .paused })
            }
            let position = rig.engine.snapshot.position
            let state = rig.engine.snapshot.state
            let item = rig.engine.snapshot.item?.id
            for enabled in [true, false] {
                let opens = rig.opens.withLock { $0 }
                group = GroupPolicies.setRoomRender(enabled, in: group)
                settings.speakerGroups[0] = group
                rig.engine.update(settings: settings)
                let applied = rig.scriptWait(timeout: 120) {
                    rig.opens.withLock { $0 } > opens && $0.signalPath?.plan.reason.contains("rendered for the room") == enabled
                        && $0.state == state && abs($0.position - position) < 0.01
                }
                try #require(applied, "Fill the room = \(enabled) must reach the current output")
                let snapshot = rig.engine.snapshot
                #expect(snapshot.item?.id == item)
                #expect(snapshot.state == state)
                #expect(abs(snapshot.position - position) < 0.01)
                #expect(rig.opens.withLock { $0 } == opens + 1)
                let readback = try #require(snapshot.signalPath?.group)
                #expect((readback.render != nil) == enabled)
                #expect(readback.badges.contains("ROOM RENDER") == enabled)
                if enabled {
                    let beforeEdit = rig.opens.withLock { $0 }
                    group.roomRender?.fillDB = 99
                    settings.speakerGroups[0] = group
                    rig.engine.update(settings: settings)
                    try #require(rig.scriptWait(timeout: 120) {
                        rig.opens.withLock { $0 } == beforeEdit + 1 && $0.signalPath != nil && $0.state == state
                    }, "an active render parameter change also rebuilds decoding")
                    group.roomRender?.fillDB = 100  // both clamp to 0 dB: no audible change
                    settings.speakerGroups[0] = group
                    rig.engine.update(settings: settings)
                    if paused {
                        rig.engine.resume()
                        try #require(rig.scriptWait(timeout: 120) { $0.state == .playing })
                        rig.engine.pause()
                        try #require(rig.scriptWait(timeout: 120) { $0.state == .paused })
                    } else {
                        rig.engine.pause()
                        try #require(rig.scriptWait(timeout: 120) { $0.state == .paused })
                        rig.engine.resume()
                        try #require(rig.scriptWait(timeout: 120) { $0.state == .playing })
                    }
                    #expect(rig.opens.withLock { $0 } == beforeEdit + 1)
                }
            }
            // An inactive group's switch must leave this decoder and output alone.
            let session = rig.engine.currentSessionForTesting
            let opens = rig.opens.withLock { $0 }
            settings.speakerGroups[1].roomRender = RoomRenderSettings()
            rig.engine.update(settings: settings)
            // A transport command after settings gives an observable acknowledgement on the engine's command queue.
            if paused {
                rig.engine.resume()
                try #require(rig.scriptWait(timeout: 120) { $0.state == .playing })
            } else {
                rig.engine.pause()
                try #require(rig.scriptWait(timeout: 120) { $0.state == .paused })
            }
            #expect(rig.engine.currentSessionForTesting === session)
            #expect(rig.opens.withLock { $0 } == opens)
            #expect(abs(rig.engine.snapshot.position - position) < 0.01)
        }
    }
}
