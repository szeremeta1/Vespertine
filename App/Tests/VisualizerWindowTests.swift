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
        view.visualizer = model
        window.contentView = view
        return Rig(model: model, window: window, view: view, counter: counter)
    }

    /// Runs the main loop for `seconds`.
    private func settle(_ seconds: Double = 0.5) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// How many draws the next `seconds` bring.
    private func draws(_ rig: Rig, over seconds: Double = 0.5) async -> Int {
        let before = rig.counter.draws
        await settle(seconds)
        return rig.counter.draws - before
    }

    @Test("Showing draws, closing stops it, and the same window shown again draws and is analysed again")
    func reopenSameWindow() async {
        let rig = makeRig()
        defer { rig.window.close() }
        rig.window.makeKeyAndOrderFront(nil)
        await settle()
        #expect(rig.model.showing == 1)
        #expect(await draws(rig) > 5, "the open window isn't drawing")
        rig.window.close()
        await settle()
        #expect(rig.model.showing == 0)
        #expect(await draws(rig) == 0, "a closed window draws")
        rig.window.makeKeyAndOrderFront(nil)
        await settle()
        #expect(rig.model.showing == 1)
        #expect(await draws(rig) > 5, "the reopened window shows the frame it was closed on: it isn't drawing")
    }

    @Test("Closed and shown again several times, it draws every time")
    func reopenRepeatedly() async {
        let rig = makeRig()
        defer { rig.window.close() }
        for round in 1...4 {
            rig.window.makeKeyAndOrderFront(nil)
            await settle(0.4)
            #expect(rig.model.showing == 1, "round \(round)")
            #expect(await draws(rig, over: 0.4) > 3, "round \(round): not drawing")
            rig.window.close()
            await settle(0.3)
            #expect(rig.model.showing == 0, "round \(round)")
        }
    }

    @Test("A new window and view built after the old one closed (the scene made again) draws too")
    func reopenNewWindow() async {
        let first = makeRig()
        first.window.makeKeyAndOrderFront(nil)
        await settle()
        #expect(first.model.showing == 1)
        first.window.close()
        first.window.contentView = nil
        await settle()
        #expect(first.model.showing == 0)
        let second = makeRig(model: first.model)
        defer { second.window.close() }
        second.window.makeKeyAndOrderFront(nil)
        await settle()
        #expect(second.model.showing == 1)
        #expect(await draws(second) > 5)
    }

    @Test("Two windows showing at once keep the tap on until both are gone")
    func twoWindows() async {
        let a = makeRig()
        let b = makeRig(model: a.model)
        defer { a.window.close(); b.window.close() }
        a.window.makeKeyAndOrderFront(nil)
        b.window.makeKeyAndOrderFront(nil)
        await settle()
        #expect(a.model.showing == 2)
        a.window.close()
        await settle()
        #expect(a.model.showing == 1)
        #expect(await draws(b) > 5)
        b.window.close()
        await settle()
        #expect(a.model.showing == 0)
    }
}
