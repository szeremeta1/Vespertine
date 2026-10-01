//
// Vespertine — content-addressed artwork cache with pre-rendered thumbnails.
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

    /// Stores the original and thumbnails; returns the key. Idempotent.
    @discardableResult
    public func store(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let key = Self.key(for: data)
        let original = originalURL(key)
        if FileManager.default.fileExists(atPath: thumbnailURL(key, size: Self.thumbnailSizes[0]).path) { return key }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        try? data.write(to: original, options: .atomic)
        for size in Self.thumbnailSizes {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let dest = CGImageDestinationCreateWithURL(thumbnailURL(key, size: size) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return key
    }

    public func originalURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).img") }

    public func thumbnailURL(_ key: String, size: Int) -> URL { directory.appendingPathComponent("\(key)_\(size).jpg") }

    /// Best thumbnail at least `size` pixels, falling back to the original.
    public func url(for key: String, minimumSize size: Int) -> URL {
        if let s = Self.thumbnailSizes.first(where: { $0 >= size }) {
            let url = thumbnailURL(key, size: s)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return originalURL(key)
    }

    public func originalData(_ key: String) -> Data? { try? Data(contentsOf: originalURL(key)) }

    /// True when the file carries an embedded picture.
    public static func hasEmbeddedArt(_ url: URL) -> Bool {
        guard let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) else { return false }
        return !file.metadata.attachedPictures.isEmpty
    }

    /// cover.jpg / folder.png … next to the audio file.
    public static func folderImage(near file: URL) -> Data? {
        let dir = file.deletingLastPathComponent()
        if let data = image(in: dir) { return data }
        // Multi-disc albums keep their cover next to the disc folders ("Album (1973)/CD 01/…").
        return isDiscFolder(dir.lastPathComponent) ? image(in: dir.deletingLastPathComponent()) : nil
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

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]

    private static func image(in dir: URL) -> Data? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return pickCover(items.filter { imageExtensions.contains($0.pathExtension.lowercased()) }).flatMap { try? Data(contentsOf: $0) }
    }

    /// The folder's cover among its images: cover/folder/front/album/artwork, or the only image there is.
    static func pickCover(_ images: [URL]) -> URL? {
        for name in ["cover", "folder", "front", "album", "artwork"] {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) { return match }
        }
        return images.count == 1 ? images[0] : nil
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
        let key = ArtworkStore.folderImage(near: file).map { store.store($0) } ?? nil
        lock.lock(); keys[dir] = .some(key); lock.unlock()
        return key
    }
}
