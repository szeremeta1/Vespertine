//
// Vespertine: what is kept on this iPhone. Albums and playlists chosen with "Keep on This iPhone", each with its songs as the
// Mac listed them, and the song files that have arrived. One folder per Mac: a small index beside the files, so what is kept
// is listed and plays with the Mac off.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Observation
import VespertineRemoteClient
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
    /// The song's ReplayGain values as the Mac gave them, so they are here with the Mac off. nil: it has none, or it was
    /// kept before they were.
    public var replayGain: ReplayGain?
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
        var replayGain: ReplayGain?
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
        songs[song].map { KeptSong(song: song, file: directory.appendingPathComponent($0.name), descriptor: $0.descriptor, replayGain: $0.replayGain) }
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
    func arrived(_ song: Int64, descriptor: StreamDescriptor, replayGain: ReplayGain? = nil) throws {
        let name = "\(song)-\(descriptor.tag.prefix(16).filter { $0.isLetter || $0.isNumber || $0 == "-" }).\(descriptor.format.container)"
        let place = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: place)
        try FileManager.default.moveItem(at: partFile(for: song), to: place)
        if let old = songs[song] {
            bytes -= old.descriptor.byteSize
            if old.name != name { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.name)) }
        }
        songs[song] = Record(name: name, descriptor: descriptor, replayGain: replayGain)
        bytes += descriptor.byteSize
        prune()
        save()
    }

    /// The Mac said what a kept song's ReplayGain values are (a song kept before they were kept gets them this way).
    public func noteReplayGain(_ values: ReplayGain?, of song: Int64) {
        guard var record = songs[song], record.replayGain != values else { return }
        record.replayGain = values
        songs[song] = record
        save()
    }

    /// Takes in what was kept from one library by itself (the folder at `other`), now that the library is one of several
    /// joined as one: its lists and songs are known here by their joined names (see `JoinedID`), the song files are moved,
    /// not fetched again, and the old folder goes. A list already here under its joined name is left as it is.
    public func adopt(_ other: URL, slot: Int) {
        defer { try? FileManager.default.removeItem(at: other) }
        guard other.standardizedFileURL != directory.standardizedFileURL,
              let data = try? Data(contentsOf: other.appendingPathComponent("index.json")),
              let index = try? RemoteProtocol.decoder().decode(Index.self, from: data) else { return }
        for var list in index.lists {
            switch list.kind {
            case .album:
                list.reference = JoinedID.join(list.reference, slot: slot)
                list.id = KeptList.albumID(list.reference)
            case .playlist:
                break
            }
            guard self.list(list.id) == nil else { continue }
            list.artworkKey = list.artworkKey.map { JoinedID.join($0, slot: slot) }
            list.tracks = list.tracks.map { JoinedLibrary.joined($0, slot) }
            lists.append(list)
        }
        for (key, record) in index.songs {
            guard let old = Int64(key), let id = JoinedID.join(old, slot: slot), songs[id] == nil else { continue }
            // Two libraries number their songs alike: the slot in the name keeps their files apart.
            let name = "s\(slot)-\(record.name)"
            do {
                try FileManager.default.moveItem(at: other.appendingPathComponent(record.name), to: directory.appendingPathComponent(name))
            } catch {
                continue
            }
            songs[id] = Record(name: name, descriptor: record.descriptor, replayGain: record.replayGain)
            bytes += record.descriptor.byteSize
        }
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
