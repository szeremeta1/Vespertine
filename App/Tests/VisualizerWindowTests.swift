import AppKit
import Foundation
import MetalKit
import Testing
import VespertineAudio
@testable import Vespertine

/// The visualizer window through close and reopen: the view must go on drawing (a window that came back showed the last
/// frame it drew before it was closed: the old song's title, no motion), and the engine's tap and the analysis follow it.
@Suite("Visualizer window", .serialized) @MainActor
struct VisualizerWindowTests {
    /// Counts the draws the view asks its delegate for.
    private final class Counter: NSObject, MTKViewDelegate {
        nonisolated(unsafe) private(set) var draws = 0
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) { draws += 1 }
    }

    private struct Rig {
        let model: VisualizerModel
        let window: NSWindow
        let view: VisualizerMTKView
        let counter: Counter
    }

    private func makeRig(model: VisualizerModel? = nil) -> Rig {
        let model = model ?? VisualizerModel(engine: PlaybackEngine())
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 480, height: 320), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = VisualizerMTKView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), device: MTLCreateSystemDefaultDevice())
        let counter = Counter()
        view.delegate = counter
        view.windowIsSeen = { $0.isVisible && !$0.isMiniaturized }
        view.visualizer = model
        window.contentView = view
        return Rig(model: model, window: window, view: view, counter: counter)
    }

    /// Orders the window in and tells the view what the system tells it when a window shows. Whether the system calls the window
    /// uncovered depends on what else is on the screen (a locked session or another app's full-screen window covers it), so the
    /// rig's views take "on screen and not miniaturized" as seen (`windowIsSeen`) and the test sends the notification itself.
    private func show(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    /// Runs the main loop for `seconds`.
    private func settle(_ seconds: Double = 0.5) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// Runs the main loop until `condition` holds: polled every 50 ms for up to 10 s, a bound for a hang and not a measure of
    /// anything (a busy machine delivers the window's notifications and the display link's ticks late). The expectation that
    /// follows still decides.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; await settle(0.05) }
    }

    /// Whether the view draws `count` more times (waits for them, up to `until`'s bound).
    private func drew(_ rig: Rig, atLeast count: Int) async -> Bool {
        let before = rig.counter.draws
        await until { rig.counter.draws - before >= count }
        return rig.counter.draws - before >= count
    }

    /// How many draws the next `seconds` bring (for "it does not draw": a stretch of time can only miss a late draw, never invent one).
    private func draws(_ rig: Rig, over seconds: Double = 0.5) async -> Int {
        let before = rig.counter.draws
        await settle(seconds)
        return rig.counter.draws - before
    }

    @Test("Showing draws, closing stops it, and the same window shown again draws and is analysed again")
    func reopenSameWindow() async {
        let rig = makeRig()
        defer { rig.window.close() }
        show(rig.window)
        await until { rig.model.showing == 1 }
        #expect(rig.model.showing == 1)
        #expect(await drew(rig, atLeast: 6), "the open window isn't drawing")
        rig.window.close()
        await until { rig.model.showing == 0 }
        #expect(rig.model.showing == 0)
        #expect(await draws(rig) == 0, "a closed window draws")
        show(rig.window)
        await until { rig.model.showing == 1 }
        #expect(rig.model.showing == 1)
        #expect(await drew(rig, atLeast: 6), "the reopened window shows the frame it was closed on: it isn't drawing")
    }

    @Test("Closed and shown again several times, it draws every time")
    func reopenRepeatedly() async {
        let rig = makeRig()
        defer { rig.window.close() }
        for round in 1...4 {
            show(rig.window)
            await until { rig.model.showing == 1 }
            #expect(rig.model.showing == 1, "round \(round)")
            #expect(await drew(rig, atLeast: 4), "round \(round): not drawing")
            rig.window.close()
            await until { rig.model.showing == 0 }
            #expect(rig.model.showing == 0, "round \(round)")
        }
    }

    @Test("A new window and view built after the old one closed (the scene made again) draws too")
    func reopenNewWindow() async {
        let first = makeRig()
        show(first.window)
        await until { first.model.showing == 1 }
        #expect(first.model.showing == 1)
        first.window.close()
        first.window.contentView = nil
        await until { first.model.showing == 0 }
        #expect(first.model.showing == 0)
        let second = makeRig(model: first.model)
        defer { second.window.close() }
        show(second.window)
        await until { second.model.showing == 1 }
        #expect(second.model.showing == 1)
        #expect(await drew(second, atLeast: 6))
    }

    @Test("Two windows showing at once keep the tap on until both are gone")
    func twoWindows() async {
        let a = makeRig()
        let b = makeRig(model: a.model)
        defer { a.window.close(); b.window.close() }
        show(a.window)
        show(b.window)
        await until { a.model.showing == 2 }
        #expect(a.model.showing == 2)
        a.window.close()
        await until { a.model.showing == 1 }
        #expect(a.model.showing == 1)
        #expect(await drew(b, atLeast: 6))
        b.window.close()
        await until { a.model.showing == 0 }
        #expect(a.model.showing == 0)
    }

    @Test("Moved from a 60 Hz display to a 120 Hz one, it draws up to 120 a second, not still at the old display's rate")
    func followsTheDisplayRate() async {
        let rig = makeRig()
        defer { rig.window.close() }
        rig.view.screenRate = { 60 }
        show(rig.window)
        await until { rig.view.drawingRate == 60 }
        #expect(rig.view.drawingRate == 60)
        rig.view.screenRate = { 120 }
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: rig.window)
        await until { rig.view.drawingRate == 120 }
        #expect(rig.view.drawingRate == 120, "the display link is still held to the old display's rate")
        #expect(rig.view.preferredFramesPerSecond == 120)
        rig.view.screenRate = { 60 }
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: rig.window)
        await until { rig.view.drawingRate == 60 }
        #expect(rig.view.drawingRate == 60)
    }
}
