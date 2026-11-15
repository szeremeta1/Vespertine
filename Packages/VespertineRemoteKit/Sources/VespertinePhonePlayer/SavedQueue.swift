//
// Vespertine: the phone's queue, kept between launches. iOS ends an app that isn't playing whenever it wants the memory, so
// without this the queue would be gone each time. What was playing comes back paused at its place; nothing is fetched
// until Play. The queue and the place in the song are two files: the place is written often and is tiny, the queue can be
// thousands of songs and is written only when it changes.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// A queue as it was left, and where in its song.
public struct SavedQueue: Sendable, Equatable {
    public var queue: PhoneQueue
    /// Seconds into the song that was playing.
    public var position: Double

    public init(queue: PhoneQueue, position: Double) {
        self.queue = queue
        self.position = position
    }

    /// Where Play picks up: the place it was left at, or the start for a song left within its last two seconds (its last
    /// half, for a song shorter than four), or one whose place makes no sense.
    public var resumePosition: Double {
        guard let length = queue.current?.track.duration, position.isFinite, position > 0 else { return 0 }
        return length > 0 && position > length - min(2, length / 2) ? 0 : position
    }
}

/// Where queues are kept: one per Mac or share, by its ID.
public struct QueueShelf: Sendable {
    /// The place in a song: which queue entry, and how far in.
    struct Place: Codable, Equatable {
        var entry: String
        var position: Double
    }
    /// The file's own shape, with a number that changes when the shape does: a file from another shape is left unread.
    private struct Kept: Codable {
        static let shape = 1
        var shape = Kept.shape
        var queue: PhoneQueue
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// A file name from an ID that may hold anything (a share's has slashes and colons).
    private func name(_ owner: String) -> String {
        owner.utf8.map { byte in
            let scalar = Unicode.Scalar(byte)
            return (byte < 128 && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")) ? String(scalar) : String(format: "_%02x", byte)
        }.joined()
    }
    func queueFile(_ owner: String) -> URL { directory.appendingPathComponent(name(owner) + ".queue.json") }
    func placeFile(_ owner: String) -> URL { directory.appendingPathComponent(name(owner) + ".place.json") }

    /// The queue left for `owner`, when there is one with a song to come back to. A file that can't be read (damaged,
    /// written by a later version in another shape) is no queue, never an error.
    public func load(_ owner: String) -> SavedQueue? {
        guard let data = try? Data(contentsOf: queueFile(owner)), let kept = try? JSONDecoder().decode(Kept.self, from: data),
              kept.shape == Kept.shape, let current = kept.queue.current else { return nil }
        let place = (try? Data(contentsOf: placeFile(owner))).flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        // A place written for another song (the app ended between the two files) says nothing about this one.
        return SavedQueue(queue: kept.queue, position: place?.entry == current.id ? place?.position ?? 0 : 0)
    }

    /// Keeps `queue` for `owner`. One with nothing playing is nothing to come back to: the files go.
    public func save(queue: PhoneQueue, for owner: String) {
        guard queue.current != nil else { forget(owner); return }
        write(Kept(queue: queue), to: queueFile(owner))
    }

    /// Keeps the place in the song that is playing.
    public func save(entry: String, position: Double, for owner: String) {
        write(Place(entry: entry, position: position), to: placeFile(owner))
    }

    public func forget(_ owner: String) {
        try? FileManager.default.removeItem(at: queueFile(owner))
        try? FileManager.default.removeItem(at: placeFile(owner))
    }

    private func write(_ value: some Encodable, to file: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // In one piece or not at all: a half-written queue would be unreadable next time.
        try? data.write(to: file, options: .atomic)
    }
}
