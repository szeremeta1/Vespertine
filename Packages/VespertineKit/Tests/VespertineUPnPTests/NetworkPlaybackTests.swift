//
// Vespertine: a renderer's playback is one of the network outputs the player drives through `NetworkPlayback`.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

private struct IdleTransport: RendererTransport {
    var gapless: Bool { true }
    func load(current: RendererTrack, next: RendererTrack?) async throws {}
    func replaceNext(_ next: RendererTrack?) async throws {}
    func play() async throws {}
    func pause() async throws {}
    func stop() async throws {}
    func seek(to seconds: TimeInterval) async throws {}
    func status() async throws -> RendererStatus { RendererStatus(state: .stopped, position: 0, duration: nil, currentURI: nil) }
}

@Suite("Network playback")
struct NetworkPlaybackTests {
    @Test("A renderer's playback is a NetworkPlayback named after the renderer")
    func rendererConforms() {
        let description = DeviceDescription(udn: "uuid:x", friendlyName: "moOde UPNP", location: URL(string: "http://127.0.0.1:9/d.xml")!, services: [])
        let playback: any NetworkPlayback = RendererPlayback(renderer: RendererDevice(description: description, kind: .openHome, capabilities: RendererCapabilities()),
                                                             transport: IdleTransport(), media: MediaServer())
        #expect(playback.outputName == "moOde UPNP")
        #expect(playback.snapshot.state == .stopped)
        playback.shutdown()
    }
}
