//
// Vespertine — getting the playing song's cover onto the visualizer, reliably: decoding any picture into something the
// GPU takes, and following the song (clear the old cover at once, show the new one the moment it can be had, keep asking
// while there is none).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import ImageIO

/// Turns a stored cover into a picture the renderer can always use.
public enum VisualizerArtworkImage {
    /// The longest side the renderer is given: far more than a window shows, well under any GPU's texture limit.
    public static let maximumSide = 2048

    /// The picture in `url`, decoded now (call it off the main thread) at no more than `maximumSide`, as 8-bit sRGB.
    /// Progressive JPEGs, PNGs of any depth, palette and gray images, CMYK, WebP, HEIC and TIFF all come out the same;
    /// a picture too big for the GPU comes out smaller; nil only when it isn't an image.
    public static func load(contentsOf url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(from: source)
    }

    public static func load(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(from: source)
    }

    private static func load(from source: CGImageSource) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return normalized(decoded)
    }

    /// `image` redrawn as 8-bit sRGB with alpha, no larger than `maximumSide` on its long side.
    public static func normalized(_ image: CGImage) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = longest > maximumSide ? Double(maximumSide) / Double(longest) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

/// Follows the playing song's cover for the visualizer. Run it in a task keyed to the song (and anything that can change its
/// cover): the task is cancelled and run again when the song changes, and a cancelled run never touches the renderer.
public enum VisualizerArtworkPresenter {
    /// Where the cover and its colours go.
    public struct Sink {
        /// Shows a cover (nil: none); returns whether a cover is showing, so a picture the GPU refused is asked for again.
        public var setArtwork: (CGImage?) -> Bool
        public var setPalette: (AlbumArtPalette?) -> Void

        public init(setArtwork: @escaping (CGImage?) -> Bool, setPalette: @escaping (AlbumArtPalette?) -> Void) {
            self.setArtwork = setArtwork
            self.setPalette = setPalette
        }
    }

    /// How long to wait before asking again when there is no cover to show (or it would not load), then the last one on.
    public static let retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10), .seconds(30), .seconds(120)]

    /// - Parameters:
    ///   - knownKey: the song's cover key as far as the library knows it, to show at once if that picture is in memory.
    ///   - cached: the decoded picture for a key when it is in memory already.
    ///   - resolve: the key of the song's cover (library, tags, folder, album), or nil when it has none *yet*.
    ///   - load: decodes the picture for a key (off the main thread), nil when it can't be had.
    ///   - palette: the cover's colours for the Album Art theme (default: worked out in the background).
    ///   - retryDelays: waits between attempts while there is nothing to show.
    @MainActor
    public static func present(
        knownKey: String?,
        cached: @MainActor (String) -> CGImage?,
        resolve: @MainActor () async -> String?,
        load: @MainActor (String) async -> CGImage?,
        palette: @MainActor (CGImage) async -> AlbumArtPalette? = { image in
            await Task.detached(priority: .utility) { AlbumArtPalette.extract(from: image) }.value
        },
        retryDelays: [Duration] = VisualizerArtworkPresenter.retryDelays,
        into sink: Sink
    ) async {
        guard !Task.isCancelled else { return }
        // The song's own cover if it is already in memory; otherwise no cover at all until this one is ready, never the
        // previous song's.
        var shown = false
        if let knownKey, let image = cached(knownKey) {
            shown = sink.setArtwork(image)
        } else {
            _ = sink.setArtwork(nil)
        }
        var attempt = 0
        while !Task.isCancelled {
            if let key = await resolve(), !Task.isCancelled {
                var image = cached(key)
                if image == nil { image = await load(key) }
                if let image {
                    guard !Task.isCancelled else { return }
                    if sink.setArtwork(image) {
                        let colours = await palette(image)
                        guard !Task.isCancelled else { return }
                        sink.setPalette(colours)
                        return
                    }
                }
            }
            guard !Task.isCancelled else { return }
            // Nothing to show (yet): the default colours rather than the last song's, and ask again.
            if !shown { sink.setPalette(nil) }
            let delay = retryDelays.isEmpty ? .seconds(60) : retryDelays[min(attempt, retryDelays.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }
}
