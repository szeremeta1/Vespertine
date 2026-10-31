//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// Stands in for macOS's Atmos renderer: a steady 1 kHz tone in the bed, read at a playhead that moves.
private final class FakeAtmosRender: SystemRenderTap, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var tapping = false
    private var playhead: UInt64 = 0
    let rate = 48_000.0

    func setTapping(_ on: Bool) { lock.lock(); tapping = on; lock.unlock() }
    func advance(by frames: UInt64) { lock.lock(); playhead += frames; lock.unlock() }

    func copy(left: inout [Float], right: inout [Float]) -> PlaybackEngine.VisualizerTapRead? {
        lock.lock(); defer { lock.unlock() }
        guard tapping else { return nil }
        let n = left.count
        for i in 0..<n {
            let t = Double(Int(playhead) - n + i)
            left[i] = Float(0.5 * sin(2 * .pi * 1000 * t / rate))
            right[i] = left[i]
        }
        return .init(frames: n, position: playhead, sampleRate: rate, isDSD: false)
    }
}

@Suite("Visualizer while macOS renders Dolby Atmos")
struct AtmosVisualizerTests {
    @Test("The engine's visualizer tap reads the Atmos render's samples instead of reporting nothing")
    func engineReadsAtmosRender() {
        let engine = PlaybackEngine()
        let render = FakeAtmosRender()
        engine.attachSystemTapForTesting(render)
        engine.setVisualizerTap(true)
        render.advance(by: 48_000)
        var l = [Float](repeating: 0, count: 4096), r = l
        let read = engine.copyVisualizerTap(left: &l, right: &r)
        #expect(read != nil)
        #expect(read?.frames == 4096)
        #expect(read?.sampleRate == 48_000)
        #expect(l.contains { abs($0) > 0.4 })
    }
}
