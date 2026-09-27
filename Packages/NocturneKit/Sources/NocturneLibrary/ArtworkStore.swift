//
// Nocturne — content-addressed artwork cache with pre-rendered thumbnails.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
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

    /// cover.jpg / folder.png … next to the audio file.
    public static func folderImage(near file: URL) -> Data? {
        let dir = file.deletingLastPathComponent()
        let names = ["cover", "folder", "front", "album", "artwork"]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let images = items.filter { ["jpg", "jpeg", "png", "webp", "heic"].contains($0.pathExtension.lowercased()) }
        for name in names {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return try? Data(contentsOf: match)
            }
        }
        return images.count == 1 ? try? Data(contentsOf: images[0]) : nil
    }
}
