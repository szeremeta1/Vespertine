import AppKit
import AVFoundation
import Foundation
import Testing
import VespertineLibrary
import VespertineVisualizer
@testable import Vespertine

/// The cover the visualizer window shows, from the library and the artwork cache the app really uses.
@Suite("Visualizer cover in the app", .serialized) @MainActor
struct VisualizerArtworkAppTests {
    private func png(_ side: Int, red: CGFloat = 0.8) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<side { for y in 0..<side { rep.setColor(NSColor(srgbRed: red, green: CGFloat(x % 9) / 12, blue: CGFloat(y % 7) / 9, alpha: 1), atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-viz-art-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("The picture for a key is not remembered as missing: it shows once its file is there")
    func pictureAppearsLater() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtworkStore(directory: root.appendingPathComponent("Artwork"))
        let cache = ArtworkCache()
        cache.store = store
        let data = png(600)
        let key = ArtworkStore.key(for: data)
        #expect(await cache.visualizerPicture(key) == nil)                 // not stored yet
        #expect(cache.cachedVisualizerPicture(key) == nil)
        #expect(store.store(data) == key)
        let picture = try #require(await cache.visualizerPicture(key))
        #expect(picture.width == 600)
        #expect(cache.cachedVisualizerPicture(key) != nil)
    }

    @Test("A cover that lost its original still reaches the visualizer from its thumbnails")
    func fallsBackToThumbnails() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtworkStore(directory: root.appendingPathComponent("Artwork"))
        let cache = ArtworkCache()
        cache.store = store
        let key = try #require(store.store(png(1600)))
        try FileManager.default.removeItem(at: store.originalURL(key))
        let picture = try #require(await cache.visualizerPicture(key))
        #expect(picture.width == 600)
    }

    @Test("The library resolves a cover for a song its scan found none for, from the folder added since")
    func libraryResolvesAtPlayTime() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Music/Artist/Album")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let wav = music.appendingPathComponent("01 One.wav")
        let file = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0,
                                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4410))
        buffer.frameLength = 4410
        try file.write(from: buffer)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("database"))
        let read = try MetadataReader.read(url: wav, artwork: nil)
        #expect(read.artworkKey == nil)
        let cover = png(500)
        try cover.write(to: music.appendingPathComponent("Folder.PNG"))
        let key = await library.resolveArtwork(for: read)
        #expect(key == ArtworkStore.key(for: cover))
        let found = try #require(key)
        let picture = try #require(await ArtworkCache.shared.visualizerPicture(found))
        #expect(picture.width == 500)
    }
}
