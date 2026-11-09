//
// Vespertine: content-addressed artwork cache with pre-rendered thumbnails.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import SFBAudioEngine
import ImageIO
import UniformTypeIdentifiers

public final class ArtworkStore: Sendable {
    public let directory: URL
    public static let thumbnailSizes = [160, 600]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        LibraryDatabase.defaultURL.deletingLastPathComponent().appendingPathComponent("Artwork", isDirectory: true)
    }

    public static func key(for data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Stores the original and thumbnails; returns the key. Idempotent. Nil when the data isn't an image that decodes.
    ///
    /// Safe to call from several threads for the same cover (a scan reads an album's tracks side by side): every file is
    /// written whole under a temporary name and moved into place, and a cover counts as stored only when the original and
    /// every thumbnail are there, so a reader never meets a half-written thumbnail and a cover that lost a file is rebuilt.
    @discardableResult
    public func store(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let key = Self.key(for: data)
        if isStored(key) { return key }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        var thumbnails: [(size: Int, data: Data)] = []
        for size in Self.thumbnailSizes {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            let encoded = NSMutableData()
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let dest = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            if CGImageDestinationFinalize(dest) { thumbnails.append((size, encoded as Data)) }
        }
        // Data that makes no thumbnail and doesn't decode either (junk with an image's header, a cut-off file) is no cover.
        guard !thumbnails.isEmpty || CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        guard write(data, to: originalURL(key)) else { return nil }
        for thumbnail in thumbnails { _ = write(thumbnail.data, to: thumbnailURL(key, size: thumbnail.size)) }
        return key
    }

    /// Whether the original and every thumbnail of `key` are on disk.
    public func isStored(_ key: String) -> Bool {
        let fm = FileManager.default
        return ([originalURL(key)] + Self.thumbnailSizes.map { thumbnailURL(key, size: $0) }).allSatisfy { url in
            ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0 > 0
        }
    }

    /// Whether something can be shown for `key`: any of its files is on disk (a cover whose original was lost still has thumbnails).
    public func hasImage(_ key: String) -> Bool {
        let fm = FileManager.default
        return ([originalURL(key)] + Self.thumbnailSizes.map { thumbnailURL(key, size: $0) }).contains { fm.fileExists(atPath: $0.path) }
    }

    private func write(_ data: Data, to url: URL) -> Bool {
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    public func originalURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).img") }

    public func thumbnailURL(_ key: String, size: Int) -> URL { directory.appendingPathComponent("\(key)_\(size).jpg") }

    /// Best thumbnail at least `size` pixels, falling back to the original, then to a smaller thumbnail, so a cover that
    /// lost one of its files still shows (what's on disk, not what should be).
    public func url(for key: String, minimumSize size: Int) -> URL {
        let fm = FileManager.default
        for s in Self.thumbnailSizes where s >= size {
            let url = thumbnailURL(key, size: s)
            if fm.fileExists(atPath: url.path) { return url }
        }
        if fm.fileExists(atPath: originalURL(key).path) { return originalURL(key) }
        for s in Self.thumbnailSizes.reversed() where s < size {
            let url = thumbnailURL(key, size: s)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return originalURL(key)
    }

    public func originalData(_ key: String) -> Data? { try? Data(contentsOf: originalURL(key)) }

    /// True when the file carries an embedded picture.
    public static func hasEmbeddedArt(_ url: URL) -> Bool {
        guard let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) else { return false }
        return !file.metadata.attachedPictures.isEmpty
    }

    /// cover.jpg / folder.png … next to the audio file: the first of `folderImages(near:)` that can be read.
    public static func folderImage(near file: URL) -> Data? {
        for url in folderImages(near: file) {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        return nil
    }

    /// The images that can stand for the album of `file`, best first: those in its folder, then (for a disc folder, "CD 01")
    /// those next to the disc folders ("Album (1973)/CD 01/…"). A caller whose first pick won't decode goes on to the next.
    public static func folderImages(near file: URL) -> [URL] {
        let dir = file.deletingLastPathComponent()
        var found = rankedImages(in: dir)
        if isDiscFolder(dir.lastPathComponent) { found += rankedImages(in: dir.deletingLastPathComponent()) }
        return found
    }

    /// The key of the first folder image near `file` that is an image, stored in `store`.
    public static func folderArtKey(near file: URL, store: ArtworkStore) -> String? {
        for url in folderImages(near: file) {
            if let data = try? Data(contentsOf: url), let key = store.store(data) { return key }
        }
        return nil
    }

    /// The cover to show for a file: the first of its embedded pictures (`embedded`, best first, read only when reached) that
    /// is a whole image of a usable size; failing that the folder's (`folder`: stores the best image there and returns its
    /// key); failing that the best embedded one there was (cut off, or a stand-in of a few pixels). So a picture that
    /// won't decode, or a 1-pixel placeholder, never hides a good `cover.jpg`, and nothing at all is the only blank.
    public func coverKey(embedded: [() -> Data?], folder: () -> String?) -> String? {
        var fallback: String?
        for candidate in embedded {
            guard let data = candidate(), let key = store(data) else { continue }
            if !Self.looksCutOff(data), Self.longestSide(of: data) >= Self.minimumCoverSide { return key }
            fallback = fallback ?? key
        }
        return folder() ?? fallback
    }

    /// Smaller than this, a picture is a stand-in rather than a cover.
    static let minimumCoverSide = 64

    static func longestSide(of data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        return max((props[kCGImagePropertyPixelWidth] as? Int) ?? 0, (props[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }

    /// A JPEG without its end marker or a PNG without its IEND chunk: the file was cut off (a failed copy, a bad tagger),
    /// and the decoder fills the rest with gray.
    static func looksCutOff(_ data: Data) -> Bool {
        let tail = data.suffix(2048)
        if data.starts(with: [0xFF, 0xD8]) { return tail.firstRange(of: [0xFF, 0xD9]) == nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return tail.firstRange(of: Array("IEND".utf8)) == nil }
        return false
    }

    /// "CD 01", "Disc 2", "Disk1", "Digital Media 01", "12\" Vinyl 02", "Vinyl 1", "SACD 01", "DVD 01", "Side A"…
    /// and an SACD's layers: "Multichannel 5.1", "Stereo", "SACD Surround", "5.1".
    static func isDiscFolder(_ name: String) -> Bool {
        name.range(of: #"^((cd|disc|disk|digital media|(\d+"? ?)?vinyl|sacd|dvd(-audio)?|blu-ray)\s*\d{1,3}|side\s*[a-z0-9])$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
            || name.range(of: #"^((sacd|dsd)\s+)?(multi-?channel|stereo|surround|2ch|mch)(\s*[2-7]\.[01])?$|^[2-7]\.[01]$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The disc a numbered disc folder stands for: "CD 01" → 1, "Disc 2" → 2, "SHM-CD 02" → 2, "12\" Vinyl 03" → 3.
    /// Layer folders ("Stereo", "Multichannel 5.1") and sides aren't numbered discs.
    static func discNumber(fromFolder name: String) -> Int? {
        guard let r = name.range(of: #"^((shm-|blu-spec |hq)?cd|disc|disk|digital media|(\d+"? ?)?vinyl|sacd|dvd(-audio)?|blu-ray)\s*(\d{1,3})$"#,
                                 options: [.regularExpression, .caseInsensitive]),
              let digits = name[r].split(whereSeparator: { !$0.isNumber }).last, let n = Int(digits), n > 0 else { return nil }
        return n
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "bmp"]

    private static func rankedImages(in dir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return rankCovers(items.filter { imageExtensions.contains($0.pathExtension.lowercased()) })
    }

    /// The folder's cover among its images: cover/folder/front/album/artwork, or the only image there is.
    static func pickCover(_ images: [URL]) -> URL? { rankCovers(images).first }

    /// Names that are a cover outright, in order of preference.
    private static let coverNames = ["cover", "folder", "front", "album", "artwork", "albumart", "front cover", "cover art",
                                     "folder art", "albumartlarge", "large", "poster"]
    /// A name containing one of these is a cover when no name above is there ("Cover Art.jpg", "AlbumArt_{GUID}_Large.jpg", "front-1.jpg").
    private static let coverWords = ["cover", "front", "folder", "albumart", "artwork", "album art"]
    /// Images of the same release that aren't its front.
    private static let notFront = ["back", "rear", "inlay", "booklet", "disc", "cd", "tray", "inside", "spine", "small", "thumb", "scan"]

    /// The images that can be the album's cover, best first. Hidden files are left out (the `._cover.jpg` that macOS writes
    /// beside a file on a network share is a resource fork, not an image), and so are empty ones. A folder with no image
    /// named like a cover but exactly one image has that one as its cover.
    static func rankCovers(_ images: [URL]) -> [URL] {
        let visible = images.filter { !$0.lastPathComponent.hasPrefix(".") }
        func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        func byName(_ a: URL, _ b: URL) -> Bool { a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending }
        var ranked: [URL] = []
        for wanted in coverNames {
            ranked += visible.filter { name($0) == wanted && !ranked.contains($0) }.sorted(by: byName)
        }
        let fuzzy = visible.filter { url in
            let n = name(url)
            return !ranked.contains(url) && coverWords.contains { n.contains($0) } && !notFront.contains { n.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
        }
        ranked += fuzzy.sorted(by: byName)
        if ranked.isEmpty, visible.count == 1 { ranked = visible }
        return ranked
    }
}

/// Remembers each folder's cover during a scan, so an album's folder image is listed and read once,
/// not once per track (which matters on a network share).
public final class FolderArtCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String?] = [:]

    public init() {}

    func artworkKey(near file: URL, store: ArtworkStore) -> String? {
        let dir = file.deletingLastPathComponent().path
        lock.lock()
        if let cached = keys[dir] { lock.unlock(); return cached }
        lock.unlock()
        let key = ArtworkStore.folderArtKey(near: file, store: store)
        lock.lock(); keys[dir] = .some(key); lock.unlock()
        return key
    }
}
