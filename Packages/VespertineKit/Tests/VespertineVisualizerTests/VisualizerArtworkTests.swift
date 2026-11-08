//
// Vespertine — the visualizer's cover: any picture reaches the GPU, and the screen follows the song.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VespertineVisualizer

@Suite("Visualizer cover pictures")
struct VisualizerArtworkImageTests {
    /// Encodes a solid picture in `space` (nil: RGB) as `type`, with `properties` for the encoder.
    private func encode(width: Int, height: Int, space: CGColorSpace? = nil, bitsPerComponent: Int = 8, type: UTType = .jpeg,
                        properties: [CFString: Any] = [:]) -> Data {
        let space = space ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let components = space.numberOfComponents
        let alpha: CGImageAlphaInfo = components == 3 ? (type == .png ? .premultipliedLast : .noneSkipLast) : .none
        var info = alpha.rawValue
        if bitsPerComponent == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: space, bitmapInfo: info)!
        for y in stride(from: 0, to: height, by: 8) {
            var colour = [CGFloat](repeating: 0.3 + 0.4 * CGFloat(y % 5) / 5, count: components); colour.append(1)
            if components == 4 { colour = [0.8, 0.2, 0.1, 0.1, 1] }
            ctx.setFillColor(CGColor(colorSpace: space, components: colour)!)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 4))
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private var formats: [(String, Data)] {
        [
            ("baseline JPEG", encode(width: 600, height: 600)),
            ("progressive JPEG", encode(width: 1400, height: 1400, properties: [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]])),
            ("gray JPEG", encode(width: 500, height: 500, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!)),
            ("CMYK JPEG", encode(width: 500, height: 500, space: CGColorSpace(name: CGColorSpace.genericCMYK)!)),
            ("16-bit PNG", encode(width: 400, height: 400, bitsPerComponent: 16, type: .png)),
            ("PNG", encode(width: 700, height: 700, type: .png)),
            ("TIFF", encode(width: 300, height: 300, type: .tiff)),
            ("HEIC", encode(width: 600, height: 600, type: .heic)),
            ("1 pixel", encode(width: 1, height: 1, type: .png)),
            ("very wide", encode(width: 9000, height: 40, type: .png)),
            ("very large", encode(width: 5200, height: 5200, type: .jpeg)),
        ]
    }

    @Test("Every format of cover decodes to 8-bit sRGB within the size limit")
    func decodesEverything() throws {
        for (name, data) in formats {
            let image = try #require(VisualizerArtworkImage.load(data: data), "\(name)")
            #expect(max(image.width, image.height) <= VisualizerArtworkImage.maximumSide, "\(name)")
            #expect(image.bitsPerComponent == 8 && image.colorSpace?.model == .rgb, "\(name)")
            #expect(image.width > 0 && image.height > 0, "\(name)")
        }
    }

    @Test("A cover is read from a file whatever its name ends in")
    func readsFromAnyFileName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viz-art-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("0123456789ab.img")   // the artwork store's original
        try encode(width: 800, height: 800, type: .png).write(to: url)
        #expect(VisualizerArtworkImage.load(contentsOf: url)?.width == 800)
        #expect(VisualizerArtworkImage.load(contentsOf: dir.appendingPathComponent("absent.img")) == nil)
        try Data(repeating: 7, count: 100).write(to: dir.appendingPathComponent("junk.img"))
        #expect(VisualizerArtworkImage.load(contentsOf: dir.appendingPathComponent("junk.img")) == nil)
    }

    @Test("The renderer takes covers the texture loader alone refuses")
    @MainActor
    func rendererTakesAwkwardCovers() throws {
        guard let renderer = VisualizerRenderer() else { return }   // no Metal device
        for (name, data) in formats {
            // The picture as a plain decode gives it (not yet made safe), the way a caller that did not know would pass it.
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil), "\(name)")
            let raw = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(name)")
            #expect(renderer.setArtwork(raw), "\(name)")
            #expect(renderer.hasArtwork, "\(name)")
        }
        // One side beyond what any GPU holds as a texture.
        let ctx = CGContext(data: nil, width: 20_000, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 20_000, height: 8))
        #expect(renderer.setArtwork(ctx.makeImage()!))
        #expect(!renderer.setArtwork(nil) && !renderer.hasArtwork)
    }
}

@Suite("Visualizer cover follows the song")
@MainActor
struct VisualizerArtworkPresenterTests {
    private func picture(_ red: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: red, green: 0.2, blue: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()!
    }

    /// What reached the renderer, in order: the cover (nil: cleared) and the palette.
    @MainActor final class Screen {
        enum Event: Equatable { case cover(Int?), palette(Bool) }
        var events: [Event] = []
        var accepts = true
        var sink: VisualizerArtworkPresenter.Sink {
            .init(setArtwork: { [self] image in events.append(.cover(image.map { Int($0.width) })); return image == nil ? false : accepts },
                  setPalette: { [self] colours in events.append(.palette(colours != nil)) })
        }
        var covers: [Int?] { events.compactMap { if case .cover(let c) = $0 { c } else { nil } } }
    }

    private let fast: [Duration] = [.milliseconds(5)]

    @Test("The last song's cover is gone at once when the next one's isn't in memory, before anything is looked up")
    func clearsFirst() async {
        let screen = Screen()
        var lookedUp = false
        let gate = AsyncGate()
        let task = Task { @MainActor in
            await VisualizerArtworkPresenter.present(knownKey: "B", cached: { _ in nil },
                                                     resolve: { lookedUp = true; await gate.wait(); return "B" },
                                                     load: { _ in self.picture(0.9) }, palette: { _ in nil }, retryDelays: fast, into: screen.sink)
        }
        await Task.yield(); await Task.yield()
        #expect(screen.events.first == .cover(nil))
        #expect(lookedUp)
        gate.open()
        await task.value
        #expect(screen.covers == [nil, 64])
    }

    @Test("A cover already in memory is shown with no blank in between")
    func cachedShowsAtOnce() async {
        let screen = Screen()
        await VisualizerArtworkPresenter.present(knownKey: "A", cached: { _ in self.picture(0.5) }, resolve: { "A" },
                                                 load: { _ in nil }, palette: { _ in nil }, retryDelays: fast, into: screen.sink)
        #expect(screen.covers == [64, 64])    // shown from memory, then confirmed by the lookup; never cleared
        #expect(!screen.covers.contains { $0 == nil })
    }

    @Test("A song with no cover yet is asked about again until it has one")
    func retriesUntilThereIsACover() async {
        let screen = Screen()
        var asked = 0
        await VisualizerArtworkPresenter.present(knownKey: nil, cached: { _ in nil },
                                                 resolve: { asked += 1; return asked < 4 ? nil : "K" },
                                                 load: { _ in self.picture(0.7) }, palette: { _ in nil }, retryDelays: fast, into: screen.sink)
        #expect(asked == 4)
        #expect(screen.covers.last == 64)
        #expect(screen.events.contains(.palette(false)), "default colours while there is none")
    }

    @Test("A picture that won't load, or that the GPU refuses, is tried again")
    func retriesFailedLoads() async {
        let screen = Screen()
        var loads = 0
        screen.accepts = false
        await VisualizerArtworkPresenter.present(knownKey: "K", cached: { _ in nil }, resolve: { "K" },
                                                 load: { _ in loads += 1; if loads == 3 { screen.accepts = true }; return loads < 2 ? nil : self.picture(0.3) },
                                                 palette: { _ in nil }, retryDelays: fast, into: screen.sink)
        #expect(loads == 3)
        #expect(screen.covers.last == 64)
    }

    @Test("The colours of the cover follow it")
    func paletteFollows() async {
        let screen = Screen()
        await VisualizerArtworkPresenter.present(knownKey: nil, cached: { _ in nil }, resolve: { "K" }, load: { _ in self.picture(0.8) },
                                                 palette: { image in AlbumArtPalette.extract(from: image) }, retryDelays: fast, into: screen.sink)
        #expect(screen.events.suffix(2) == [.cover(64), .palette(true)])
    }

    @Test("A song that changed while its cover loaded never puts the old cover up")
    func staleLoadIsDropped() async {
        let screen = Screen()
        let gate = AsyncGate()
        let old = Task { @MainActor in
            await VisualizerArtworkPresenter.present(knownKey: "OLD", cached: { _ in nil }, resolve: { "OLD" },
                                                     load: { _ in await gate.wait(); return self.picture(0.1) }, palette: { _ in nil },
                                                     retryDelays: fast, into: screen.sink)
        }
        await Task.yield(); await Task.yield()
        old.cancel()                                              // the next song started
        let eventsAtChange = screen.events.count
        gate.open()                                               // the old cover finishes loading after that
        await old.value
        #expect(screen.events.count == eventsAtChange, "\(screen.events)")
    }

    @Test("With no cover anywhere it keeps asking, and stops when the song does")
    func keepsAskingUntilCancelled() async {
        let screen = Screen()
        var asked = 0
        let task = Task { @MainActor in
            await VisualizerArtworkPresenter.present(knownKey: nil, cached: { _ in nil }, resolve: { asked += 1; return nil },
                                                     load: { _ in nil }, palette: { _ in nil }, retryDelays: fast, into: screen.sink)
        }
        // However loaded the machine is: wait for the third ask rather than a fixed time.
        for _ in 0..<600 where asked < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await task.value
        let after = asked
        #expect(after >= 3)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(asked == after)
        #expect(screen.covers.allSatisfy { $0 == nil })
    }
}

/// Holds a task until the test lets it go.
@MainActor
final class AsyncGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() { isOpen = true; waiting.forEach { $0.resume() }; waiting = [] }
}
