//
// Vespertine Remote: covers, asked of the Mac once and kept in memory.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import CryptoKit
import SwiftUI
import UIKit
import VespertineRemoteClient
import VespertineRemoteProtocol

final class ArtworkCache {
    weak var session: RemoteSession? {
        didSet { if session !== oldValue { images.removeAllObjects() } }
    }
    private let images = NSCache<NSString, UIImage>()
    private var loading: [String: Task<UIImage?, Never>] = [:]

    init() {
        images.countLimit = 400
    }

    /// Where a cover is kept on disk (the system may clear it when the device runs short of room).
    private static func file(server: String, id: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data("\(server)/\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name)
    }

    func cached(_ key: String, size: Int) -> UIImage? {
        images.object(forKey: "\(key)@\(size)" as NSString)
    }

    func image(_ key: String, size: Int) async -> UIImage? {
        let id = "\(key)@\(size)"
        if let image = images.object(forKey: id as NSString) { return image }
        if let task = loading[id] { return await task.value }
        guard let session else { return nil }
        // Covers also stay on the device, so what is kept here has its cover with the Mac off.
        let file = Self.file(server: session.pairing.serverID, id: id)
        let task = Task { () -> UIImage? in
            if session.isConnected, case .artwork(_, _, _, let data) = await session.send(.artwork(key: key, size: size)), let image = UIImage(data: data) {
                if !session.isDemo, let file { try? data.write(to: file, options: .atomic) }
                return image
            }
            return file.flatMap { try? Data(contentsOf: $0) }.flatMap(UIImage.init(data:))
        }
        loading[id] = task
        let image = await task.value
        loading[id] = nil
        if let image { images.setObject(image, forKey: id as NSString) }
        return image
    }
}

/// A cover from the Mac, or a quiet placeholder.
struct ArtworkView: View {
    @Environment(RemoteAppModel.self) private var model
    let key: String?
    var size: Int = 300
    var cornerRadius: CGFloat = 6
    /// Draw the music-note placeholder while there's no cover (off for backdrops).
    var placeholder = true
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if placeholder {
                Rectangle().fill(Palette.raised)
                Image(systemName: "music.note").font(.title2).foregroundStyle(Palette.text3)
            } else {
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: key) {
            guard let key else { image = nil; return }
            image = model.artwork.cached(key, size: size)
            if image == nil { image = await model.artwork.image(key, size: size) }
        }
        .accessibilityHidden(true)
    }
}
