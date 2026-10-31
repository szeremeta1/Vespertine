//
// Vespertine — runs the visualizer's analysis on its own thread, at the display's rate, while a window shows it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import os

/// One read of the samples a visualizer looks at (the engine's visualizer tap).
public struct VisualizerTapRead: Sendable, Equatable {
    /// Frames copied (0: the copy was overtaken; try again next frame).
    public var frames: Int
    /// Frames tapped so far. It stands still while nothing plays.
    public var position: UInt64
    public var sampleRate: Double
    /// Levels read from DSD bits (DoP), good to about 20 kHz.
    public var isDSD: Bool

    public init(frames: Int, position: UInt64, sampleRate: Double, isDSD: Bool) {
        self.frames = frames
        self.position = position
        self.sampleRate = sampleRate
        self.isDSD = isDSD
    }
}

/// Reads the tap and analyzes it on a utility thread of its own, never the main thread or the audio thread, and keeps
/// the newest `VisualizerFrame` for the renderer. Runs only between `start` and `stop`: with no window open it costs
/// nothing.
public final class VisualizerFeed: @unchecked Sendable {
    /// Copies the newest `left.count` frames into `left` and `right`; nil when there's nothing to read.
    public typealias Source = @Sendable (_ left: inout [Float], _ right: inout [Float]) -> VisualizerTapRead?

    private let source: Source
    private let queue = DispatchQueue(label: "Vespertine Visualizer", qos: .userInteractive)
    private let state: OSAllocatedUnfairLock<Shared>

    private struct Shared {
        var frame: VisualizerFrame
        var configuration: VisualizerAnalyzer.Configuration
        var rate: Double
        var stats = Stats()
    }

    /// What the analysis costs, averaged since `start`.
    public struct Stats: Sendable, Equatable {
        public var frames = 0
        public var dropped = 0
        public var seconds: Double = 0
        public var averageMicroseconds: Double { frames > 0 ? seconds / Double(frames) * 1e6 : 0 }
        public init() {}
    }

    // Analysis thread only.
    private var timer: DispatchSourceTimer?
    private var analyzer: VisualizerAnalyzer
    private var left: [Float] = []
    private var right: [Float] = []
    private var lastPosition: UInt64 = .max
    private var lastRate: Double = 48_000
    private var lastTick: UInt64 = 0
    private var running = false

    public init(configuration: VisualizerAnalyzer.Configuration = .init(), source: @escaping Source) {
        self.source = source
        analyzer = VisualizerAnalyzer(configuration: configuration)
        state = OSAllocatedUnfairLock(initialState: Shared(
            frame: .silent(bands: configuration.bandCount, fine: configuration.fineCount),
            configuration: configuration, rate: 60))
    }

    /// The newest analysis. Any thread.
    public var frame: VisualizerFrame { state.withLock { $0.frame } }
    public var stats: Stats { state.withLock { $0.stats } }

    /// Takes effect on the next frame. Any thread.
    public func update(configuration: VisualizerAnalyzer.Configuration) { state.withLock { $0.configuration = configuration } }

    /// Starts analyzing `rate` times a second (the display's refresh rate). Any thread.
    public func start(rate: Double) {
        let rate = min(max(rate, 15), 240)
        state.withLock { $0.rate = rate; $0.stats = Stats() }
        queue.async { [self] in
            timer?.cancel()
            running = true
            lastTick = DispatchTime.now().uptimeNanoseconds
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            let interval = 1 / rate
            t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    /// Stops the analysis thread's timer. Any thread.
    public func stop() {
        queue.async { [self] in
            running = false
            timer?.cancel()
            timer = nil
            lastPosition = .max
        }
    }

    /// Lets tests call `tick()` without the timer.
    func prepareForTesting() {
        running = true
        lastTick = DispatchTime.now().uptimeNanoseconds
    }

    /// One analysis, on the feed's thread. Public for offline rendering and tests, which call it directly.
    func tick() {
        guard running else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now - lastTick) / 1e9
        lastTick = now
        let configuration = state.withLock { $0.configuration }
        if analyzer.configuration != configuration { analyzer.configuration = configuration }
        let n = VisualizerAnalyzer.fftSize(for: lastRate)
        if left.count != n {
            left = .init(repeating: 0, count: n)
            right = .init(repeating: 0, count: n)
        }
        let read = source(&left, &right)
        var fresh = false
        var dropped = false
        if let read {
            if read.sampleRate > 0, VisualizerAnalyzer.fftSize(for: read.sampleRate) != n {
                lastRate = read.sampleRate   // the next frame copies the right length
            } else if read.frames == 0 {
                dropped = true
            } else {
                fresh = read.position != lastPosition
                lastPosition = read.position
                if read.sampleRate > 0 { lastRate = read.sampleRate }
            }
        }
        if dropped {
            state.withLock { $0.stats.dropped += 1 }
            return
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let frame = analyzer.process(left: left, right: right, sampleRate: lastRate, fresh: fresh, dt: dt)
        let took = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        state.withLock {
            $0.frame = frame
            $0.stats.frames += 1
            $0.stats.seconds += took
        }
    }
}
