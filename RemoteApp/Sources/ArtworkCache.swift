//
// Vespertine Remote: covers, asked of the Mac once and kept in memory.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

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

    func cached(_ key: String, size: Int) -> UIImage? {
        images.object(forKey: "\(key)@\(size)" as NSString)
    }

    func image(_ key: String, size: Int) async -> UIImage? {
        let id = "\(key)@\(size)"
        if let image = images.object(forKey: id as NSString) { return image }
        if let task = loading[id] { return await task.value }
        guard let session else { return nil }
        let task = Task { () -> UIImage? in
            guard case .artwork(_, _, _, let data) = await session.send(.artwork(key: key, size: size)) else { return nil }
            return UIImage(data: data)
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
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
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
