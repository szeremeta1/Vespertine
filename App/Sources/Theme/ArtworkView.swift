//
// Nocturne — artwork loading with an in-memory cache.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import NocturneLibrary
import SwiftUI

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()
    private var colors: [String: Color] = [:]
    var store: ArtworkStore?

    init() { cache.countLimit = 600 }

    func cached(_ key: String, size: Int) -> NSImage? { cache.object(forKey: "\(key)_\(size)" as NSString) }

    func image(_ key: String, size: Int) async -> NSImage? {
        if let hit = cached(key, size: size) { return hit }
        guard let store else { return nil }
        let url = store.url(for: key, minimumSize: size)
        let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if let image { cache.setObject(image, forKey: "\(key)_\(size)" as NSString) }
        return image
    }

    /// Average colour of the artwork (for the ambient glow behind Now Playing).
    func averageColor(_ key: String) async -> Color? {
        if let c = colors[key] { return c }
        guard let image = await image(key, size: 160),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .medium
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = Color(.sRGB, red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
        colors[key] = color
        return color
    }
}

struct ArtworkView: View {
    let key: String?
    var size: Int = 600
    var cornerRadius: CGFloat = 6
    var placeholderTitle: String? = nil

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .task(id: key) {
            guard let key else { image = nil; return }
            image = ArtworkCache.shared.cached(key, size: size)
            if image == nil {
                let loaded = await ArtworkCache.shared.image(key, size: size)
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Palette.raised, Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(Palette.text3)
        }
    }
}
