//
// Vespertine: what is kept on this iPhone. Albums and playlists chosen with "Keep on This iPhone", each with its songs as the
// Mac listed them, and the song files that have arrived. One folder per Mac: a small index beside the files, so what is kept
// is listed and plays with the Mac off.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Observation
import VespertineRemoteProtocol

/// An album or a playlist kept on this device.
public struct KeptList: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case album, playlist }

    /// "album:<key>" or "playlist:<id>".
    public var id: String
    public var kind: Kind
    /// The album's key or the playlist's ID on the Mac, for asking what it holds now.
    public var reference: String
    public var title: String
    public var subtitle: String
    public var artworkKey: String?
    /// Its songs in order, as the Mac listed them last.
    public var tracks: [TrackSummary]
    /// Kept "smaller for this device": the Mac keeps what it sends to 48 kHz.
    public var smaller: Bool
    public var keptAt: Date

    public init(id: String, kind: Kind, reference: String, title: String, subtitle: String, artworkKey: String?, tracks: [TrackSummary],
                smaller: Bool, keptAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.reference = reference
        self.title = title
        self.subtitle = subtitle
        self.artworkKey = artworkKey
        self.tracks = tracks
        self.smaller = smaller
        self.keptAt = keptAt
    }

    public static func albumID(_ key: String) -> String { "album:\(key)" }
    public static func playlistID(_ id: Int64) -> String { "playlist:\(id)" }
}

/// A song whose file is on this device.
public struct KeptSong: Sendable, Equatable {
    public var song: Int64
    public var file: URL
    /// What the Mac sent: the format, and whether it is the original file.
    public var descriptor: StreamDescriptor
}

public struct KeptProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public var isComplete: Bool { done >= total }

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

@MainActor
@Observable
public final class KeptStore {
    private struct Record: Codable {
        var name: String
        var descriptor: StreamDescriptor
    }

    private struct Index: Codable {
        var lists: [KeptList] = []
        var songs: [String: Record] = [:]
    }

    public let directory: URL
    public private(set) var lists: [KeptList] = []
    private var songs: [Int64: Record] = [:]
    /// The bytes of every kept song file.
    public private(set) var bytes: Int64 = 0

    private var indexFile: URL { directory.appendingPathComponent("index.json") }

    /// Opens (or starts) the folder. Song files the index doesn't know, and half-made ones, are cleared out.
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexFile), let index = try? RemoteProtocol.decoder().decode(Index.self, from: data) {
            lists = index.lists
            for (key, record) in index.songs {
                guard let id = Int64(key), FileManager.default.fileExists(atPath: directory.appendingPathComponent(record.name).path) else { continue }
                songs[id] = record
            }
        }
        let known = Set(songs.values.map(\.name) + ["index.json"])
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where !known.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        bytes = songs.values.reduce(0) { $0 + $1.descriptor.byteSize }
    }

    public func list(_ id: String) -> KeptList? { lists.first { $0.id == id } }

    public func kept(_ song: Int64) -> KeptSong? {
        songs[song].map { KeptSong(song: song, file: directory.appendingPathComponent($0.name), descriptor: $0.descriptor) }
    }

    public func progress(of id: String) -> KeptProgress {
        guard let list = list(id) else { return KeptProgress(done: 0, total: 0) }
        return KeptProgress(done: list.tracks.filter { $0.id.map { songs[$0] != nil } ?? false }.count, total: list.tracks.count)
    }

    /// Whether a list's songs really are smaller copies: it was kept that way, and the Mac brought at least one of them down.
    /// A list whose songs needed nothing done to them is not, whatever was asked.
    public func madeSmaller(_ id: String) -> Bool {
        guard let list = list(id), list.smaller else { return false }
        return list.tracks.contains { $0.id.flatMap { songs[$0]?.descriptor.reduced } == true }
    }

    /// The songs of kept lists whose files aren't here yet, in the order they were asked for, each with whether its list
    /// asked for the smaller form.
    public var missing: [(track: TrackSummary, smaller: Bool)] {
        var seen = Set<Int64>()
        var result: [(TrackSummary, Bool)] = []
        for list in lists {
            for track in list.tracks {
                guard let id = track.id, songs[id] == nil, seen.insert(id).inserted else { continue }
                result.append((track, list.smaller))
            }
        }
        return result
    }

    /// Adds a list, or replaces the one with its ID. Files of songs no list holds any more are deleted.
    public func put(_ list: KeptList) {
        if let index = lists.firstIndex(where: { $0.id == list.id }) { lists[index] = list } else { lists.append(list) }
        prune()
        save()
    }

    public func remove(_ id: String) {
        lists.removeAll { $0.id == id }
        prune()
        save()
    }

    /// Where a song's file goes while it arrives, and its place once it is whole.
    func partFile(for song: Int64) -> URL { directory.appendingPathComponent("\(song).part") }

    /// The file at `partFile(for:)` arrived whole: it becomes the kept song.
    func arrived(_ song: Int64, descriptor: StreamDescriptor) throws {
        let name = "\(song)-\(descriptor.tag.prefix(16).filter { $0.isLetter || $0.isNumber || $0 == "-" }).\(descriptor.format.container)"
        let place = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: place)
        try FileManager.default.moveItem(at: partFile(for: song), to: place)
        if let old = songs[song] {
            bytes -= old.descriptor.byteSize
            if old.name != name { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.name)) }
        }
        songs[song] = Record(name: name, descriptor: descriptor)
        bytes += descriptor.byteSize
        prune()
        save()
    }

    private func prune() {
        let wanted = Set(lists.flatMap { $0.tracks.compactMap(\.id) })
        for (id, record) in songs where !wanted.contains(id) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.name))
            bytes -= record.descriptor.byteSize
            songs[id] = nil
        }
    }

    private func save() {
        let index = Index(lists: lists, songs: Dictionary(uniqueKeysWithValues: songs.map { (String($0.key), $0.value) }))
        guard let data = try? RemoteProtocol.encoder().encode(index) else { return }
        try? data.write(to: indexFile, options: .atomic)
    }
}
