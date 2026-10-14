//
// Vespertine — a DVD-Video volume's VIDEO_TS files: a VIDEO_TS folder on disk, or a disc image (.iso) read in place
// through its UDF file system (what DVD players use) or, failing that, its ISO 9660 one. Nothing is mounted or
// extracted. The UDF reader follows ECMA-167 / OSTA UDF 1.02 (the DVD-Video profile); the ISO 9660 reader follows
// ECMA-119. Both are Vespertine's own.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum DVDVideoError: Error, LocalizedError, Equatable {
    /// No VIDEO_TS (or no readable VIDEO_TS.IFO) on the volume.
    case notDVDVideo
    /// A DVD-Audio disc (AUDIO_TS with audio, no DVD-Video title with LPCM): MLP and DVD-Audio PCM aren't supported.
    case dvdAudioOnly
    /// A part of the disc couldn't be read or doesn't follow the DVD-Video layout.
    case damaged(String)
    /// The audio isn't DVD-Video LPCM in a combination Vespertine plays (AC-3, DTS, MPEG, or an LPCM header outside the spec).
    case unsupportedAudio(String)

    public var errorDescription: String? {
        switch self {
        case .notDVDVideo: String(localized: "This isn't a DVD-Video disc or VIDEO_TS folder.")
        case .dvdAudioOnly: String(localized: "This is a DVD-Audio disc. Vespertine plays DVD-Video LPCM, not DVD-Audio (MLP or DVD-Audio PCM).")
        case .damaged(let what): String(localized: "This DVD-Video is damaged (\(what)).", comment: "The damaged part, e.g. “audio packet”.")
        case .unsupportedAudio(let what): String(localized: "This DVD-Video's audio can't be played (\(what)).", comment: "Why, e.g. “AC-3 audio”.")
        }
    }
}

/// The VIDEO_TS files of a DVD-Video, wherever they are stored.
public struct DVDVideoVolume: Sendable {
    /// A run of bytes of one file on disk.
    public struct Extent: Sendable, Hashable {
        public var url: URL
        public var offset: UInt64
        public var length: UInt64
    }

    /// What the library and the player point at: the disc image, or the folder's VIDEO_TS.IFO.
    public let url: URL
    public let isImage: Bool
    /// VIDEO_TS file names (upper case, "VTS_01_1.VOB") → where their bytes are.
    public let files: [String: [Extent]]
    /// The volume also has an AUDIO_TS folder with DVD-Audio files (*.AOB / AUDIO_TS.IFO): reported, never played.
    public let hasDVDAudio: Bool

    public static let sectorSize = 2048

    /// A VIDEO_TS folder (or its VIDEO_TS.IFO, or the folder holding VIDEO_TS), or a .iso image.
    public static func open(_ url: URL) throws -> DVDVideoVolume {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw DVDVideoError.notDVDVideo }
        if !isDir.boolValue && url.pathExtension.lowercased() == "iso" { return try openImage(url) }
        let folder: URL
        if isDir.boolValue {
            folder = url.lastPathComponent.uppercased() == "VIDEO_TS" ? url
                : (try? childNamed("VIDEO_TS", in: url)) ?? url
        } else {
            folder = url.deletingLastPathComponent()
        }
        return try openFolder(folder)
    }

    /// Whether `url` is the entry file of a VIDEO_TS folder (VIDEO_TS.IFO), the file the library lists such a disc by.
    public static func isFolderEntry(_ url: URL) -> Bool { url.lastPathComponent.uppercased() == "VIDEO_TS.IFO" }

    private static func childNamed(_ name: String, in folder: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.uppercased() == name }
    }

    static func openFolder(_ folder: URL) throws -> DVDVideoVolume {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { throw DVDVideoError.notDVDVideo }
        var files: [String: [Extent]] = [:]
        for item in items {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files[item.lastPathComponent.uppercased()] = [Extent(url: item, offset: 0, length: UInt64(values?.fileSize ?? 0))]
        }
        guard files["VIDEO_TS.IFO"] != nil else { throw DVDVideoError.notDVDVideo }
        let audioTS = folder.deletingLastPathComponent().appendingPathComponent("AUDIO_TS")
        let audioFiles = (try? FileManager.default.contentsOfDirectory(atPath: audioTS.path)) ?? []
        return DVDVideoVolume(url: files["VIDEO_TS.IFO"]![0].url, isImage: false,
                              files: files, hasDVDAudio: audioFiles.contains { $0.uppercased().hasSuffix(".AOB") || $0.uppercased() == "AUDIO_TS.IFO" })
    }

    static func openImage(_ url: URL) throws -> DVDVideoVolume {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let image = DiscImage(handle: handle, size: size)
        // UDF is what a DVD player reads; the ISO 9660 bridge is the fallback for images without (or with damaged) UDF.
        let listing = (try? UDFReader(image).listVideoAndAudioTS()) ?? (try? ISO9660Reader(image).listVideoAndAudioTS())
        guard let listing, listing.video["VIDEO_TS.IFO"] != nil else { throw DVDVideoError.notDVDVideo }
        var files: [String: [Extent]] = [:]
        for (name, extents) in listing.video {
            files[name] = extents.map { Extent(url: url, offset: $0.offset, length: $0.length) }
            // A file that runs past the end of the image is a truncated image.
            for e in extents where e.offset + e.length > size {
                throw DVDVideoError.damaged(String(localized: "image ends inside \(name)", comment: "Part of “This DVD-Video is damaged (…).”"))
            }
        }
        return DVDVideoVolume(url: url, isImage: true, files: files,
                              hasDVDAudio: listing.audio.contains { $0.hasSuffix(".AOB") || $0 == "AUDIO_TS.IFO" })
    }

    /// The whole of a (small) file: an IFO.
    public func contents(of name: String, limit: Int = 16 << 20) throws -> [UInt8] {
        guard let extents = files[name.uppercased()] else { throw DVDVideoError.damaged(String(localized: "\(name) missing", comment: "Part of “This DVD-Video is damaged (…).”")) }
        var out: [UInt8] = []
        for e in extents {
            guard out.count < limit else { break }
            let handle = try FileHandle(forReadingFrom: e.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: e.offset)
            let want = Int(min(e.length, UInt64(limit - out.count)))
            let data = try handle.read(upToCount: want) ?? Data()
            guard data.count == want else { throw DVDVideoError.damaged(String(localized: "\(name) is truncated", comment: "Part of “This DVD-Video is damaged (…).”")) }
            out.append(contentsOf: data)
        }
        return out
    }

    /// A title set's title VOBs (VTS_nn_1.VOB … VTS_nn_9.VOB), one sector address space, in order.
    public func titleVOBs(titleSet: Int) -> [Extent] {
        (1...9).flatMap { files[String(format: "VTS_%02d_%d.VOB", titleSet, $0)] ?? [] }
    }
}

// MARK: - Disc images

/// Random access to a disc image's 2048-byte logical sectors.
struct DiscImage {
    let handle: FileHandle
    let size: UInt64

    func sectors(_ first: UInt64, _ count: Int) throws -> [UInt8] {
        let start = first * UInt64(DVDVideoVolume.sectorSize)
        guard start < size else { throw DVDVideoError.damaged(String(localized: "file system", comment: "Part of “This DVD-Video is damaged (…).”")) }
        try handle.seek(toOffset: start)
        let data = [UInt8](try handle.read(upToCount: count * DVDVideoVolume.sectorSize) ?? Data())
        guard data.count == count * DVDVideoVolume.sectorSize else { throw DVDVideoError.damaged(String(localized: "file system", comment: "Part of “This DVD-Video is damaged (…).”")) }
        return data
    }

    func bytes(at offset: UInt64, _ count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let data = [UInt8](try handle.read(upToCount: count) ?? Data())
        guard data.count == count else { throw DVDVideoError.damaged(String(localized: "file system", comment: "Part of “This DVD-Video is damaged (…).”")) }
        return data
    }
}

/// The VIDEO_TS files (name → extents in the image) and the AUDIO_TS file names, from one of the image's file systems.
struct DiscListing {
    struct Extent: Hashable { var offset: UInt64; var length: UInt64 }
    var video: [String: [Extent]] = [:]
    var audio: [String] = []
}

private func le16(_ d: [UInt8], _ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : 0 }
private func le32(_ d: [UInt8], _ o: Int) -> UInt64 { o + 4 <= d.count ? UInt64(d[o]) | UInt64(d[o + 1]) << 8 | UInt64(d[o + 2]) << 16 | UInt64(d[o + 3]) << 24 : 0 }
private func le64(_ d: [UInt8], _ o: Int) -> UInt64 { le32(d, o) | le32(d, o + 4) << 32 }

private func damaged(_ what: String) -> DVDVideoError { .damaged(what) }

/// ECMA-119 (ISO 9660): the primary volume descriptor's root directory, then VIDEO_TS and AUDIO_TS. Names are
/// compared without their ";1" version suffix, upper case.
struct ISO9660Reader {
    let image: DiscImage
    init(_ image: DiscImage) { self.image = image }

    func listVideoAndAudioTS() throws -> DiscListing {
        // Volume descriptors from sector 16 until the terminator (type 255).
        var root: (lba: UInt64, size: UInt64)?
        for sector in UInt64(16)..<UInt64(64) {
            let d = try image.sectors(sector, 1)
            guard d[1...5].elementsEqual(Array("CD001".utf8)) else { throw damaged("ISO 9660") }
            if d[0] == 1 { root = (le32(d, 156 + 2), le32(d, 156 + 10)); break }
            if d[0] == 255 { break }
        }
        guard let root else { throw damaged("ISO 9660") }
        let top = try directory(lba: root.lba, size: root.size)
        var listing = DiscListing()
        if let v = top.first(where: { $0.name == "VIDEO_TS" && $0.isDirectory }) {
            for f in try directory(lba: v.lba, size: v.size) where !f.isDirectory {
                // A file larger than 4 GB has several directory records (multi-extent): their extents in order.
                listing.video[f.name, default: []].append(.init(offset: f.lba * 2048, length: f.size))
            }
        }
        if let a = top.first(where: { $0.name == "AUDIO_TS" && $0.isDirectory }) {
            listing.audio = try directory(lba: a.lba, size: a.size).filter { !$0.isDirectory }.map(\.name)
        }
        return listing
    }

    struct Record { var name: String; var lba: UInt64; var size: UInt64; var isDirectory: Bool }

    func directory(lba: UInt64, size: UInt64) throws -> [Record] {
        guard size > 0, size < 16 << 20 else { throw damaged("ISO 9660 directory") }
        let d = try image.sectors(lba, Int((size + 2047) / 2048))
        var out: [Record] = []
        var p = 0
        while p < Int(size) {
            let length = Int(d[p])
            if length == 0 { p = (p / 2048 + 1) * 2048; continue }     // records never cross a sector
            guard length >= 34, p + length <= d.count else { throw damaged("ISO 9660 directory") }
            let nameLength = Int(d[p + 32])
            guard 33 + nameLength <= length else { throw damaged("ISO 9660 directory") }
            let raw = Array(d[p + 33..<p + 33 + nameLength])
            if !(nameLength == 1 && raw[0] <= 1) {                     // "." and ".."
                var name = String(decoding: raw, as: UTF8.self).uppercased()
                if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
                if name.hasSuffix(".") { name.removeLast() }
                out.append(Record(name: name, lba: le32(d, p + 2), size: le32(d, p + 10), isDirectory: d[p + 25] & 0x02 != 0))
            }
            p += length
        }
        return out
    }
}

/// ECMA-167 / OSTA UDF: anchor (sector 256) → volume descriptors (partition, logical volume) → file set
/// descriptor → root directory → VIDEO_TS / AUDIO_TS. Short and long allocation descriptors and embedded data are
/// read; files with several extents keep them in order.
struct UDFReader {
    let image: DiscImage
    init(_ image: DiscImage) { self.image = image }

    private func tag(_ d: [UInt8], _ o: Int = 0) -> Int { le16(d, o) }

    func listVideoAndAudioTS() throws -> DiscListing {
        let anchor = try image.sectors(256, 1)
        guard tag(anchor) == 2 else { throw damaged("UDF") }
        let vdsLength = le32(anchor, 16), vdsLocation = le32(anchor, 20)
        var partitionStart: UInt64?, fsd: (lbn: UInt64, partition: Int)?
        for i in 0..<min(Int(vdsLength / 2048), 64) {
            let d = try image.sectors(vdsLocation + UInt64(i), 1)
            switch tag(d) {
            case 5: partitionStart = partitionStart ?? le32(d, 188)                     // partition descriptor
            case 6:                                                                      // logical volume descriptor
                guard le32(d, 212) == 2048 else { throw damaged("UDF block size") }
                fsd = (le32(d, 248 + 4), le16(d, 248 + 8))
            case 8: break                                                                // terminating descriptor
            default: continue
            }
            if tag(d) == 8 { break }
        }
        guard let partitionStart, let fsd else { throw damaged("UDF") }
        let set = try image.sectors(partitionStart + fsd.lbn, 1)
        guard tag(set) == 256 else { throw damaged("UDF file set") }
        let rootICB = le32(set, 400 + 4)
        let root = try entries(ofDirectoryAt: rootICB, partitionStart: partitionStart)
        var listing = DiscListing()
        if let v = root.first(where: { $0.name == "VIDEO_TS" && $0.isDirectory }) {
            for f in try entries(ofDirectoryAt: v.icb, partitionStart: partitionStart) where !f.isDirectory {
                let entry = try fileEntry(at: f.icb, partitionStart: partitionStart)
                listing.video[f.name] = entry.extents.map { .init(offset: $0.offset, length: $0.length) }
            }
        }
        if let a = root.first(where: { $0.name == "AUDIO_TS" && $0.isDirectory }) {
            listing.audio = try entries(ofDirectoryAt: a.icb, partitionStart: partitionStart).filter { !$0.isDirectory }.map(\.name)
        }
        return listing
    }

    struct FileEntry { var extents: [(offset: UInt64, length: UInt64)]; var embedded: [UInt8]?; var length: UInt64 }

    /// A file entry (tag 261) or extended file entry (tag 266): its data's extents in the image.
    func fileEntry(at lbn: UInt64, partitionStart: UInt64) throws -> FileEntry {
        let d = try image.sectors(partitionStart + lbn, 1)
        let t = tag(d)
        guard t == 261 || t == 266 else { throw damaged("UDF file entry") }
        let infoLength = le64(d, 56)
        let (eaLength, adLength, adStart) = t == 261 ? (Int(le32(d, 168)), Int(le32(d, 172)), 176) : (Int(le32(d, 208)), Int(le32(d, 212)), 216)
        let start = adStart + eaLength
        guard start + adLength <= d.count else { throw damaged("UDF file entry") }
        let kind = le16(d, 16 + 18) & 7
        switch kind {
        case 3:                                                         // data embedded in the entry
            return FileEntry(extents: [], embedded: Array(d[start..<start + adLength]), length: infoLength)
        case 0, 1:
            let size = kind == 0 ? 8 : 16
            var extents: [(UInt64, UInt64)] = []
            var p = start, remaining = infoLength
            while p + size <= start + adLength, remaining > 0 {
                let raw = le32(d, p), length = raw & 0x3FFF_FFFF, type = raw >> 30
                let position = le32(d, p + 4)
                p += size
                guard length > 0 else { break }
                guard type == 0 else { throw damaged("UDF extent") }    // unrecorded or continuation: not on DVD-Video
                let used = min(length, remaining)
                extents.append(((partitionStart + position) * 2048, used))
                remaining -= used
            }
            guard remaining == 0 else { throw damaged("UDF extents") }
            return FileEntry(extents: extents, embedded: nil, length: infoLength)
        default:
            throw damaged("UDF allocation")
        }
    }

    struct Item { var name: String; var icb: UInt64; var isDirectory: Bool }

    func entries(ofDirectoryAt icb: UInt64, partitionStart: UInt64) throws -> [Item] {
        let entry = try fileEntry(at: icb, partitionStart: partitionStart)
        var data: [UInt8]
        if let embedded = entry.embedded { data = embedded } else {
            data = []
            for e in entry.extents {
                guard e.length < 16 << 20 else { throw damaged("UDF directory") }
                data += try image.bytes(at: e.offset, Int(e.length))
            }
        }
        var out: [Item] = []
        var p = 0
        while p + 38 <= data.count {
            guard tag(data, p) == 257 else { throw damaged("UDF directory") }
            let characteristics = data[p + 18], nameLength = Int(data[p + 19])
            let icbLBN = le32(data, p + 20 + 4)
            let iuLength = le16(data, p + 36)
            let nameStart = p + 38 + iuLength
            guard nameStart + nameLength <= data.count else { throw damaged("UDF directory") }
            if characteristics & 0x08 == 0, nameLength > 0 {          // not the parent entry
                out.append(Item(name: Self.dstring(Array(data[nameStart..<nameStart + nameLength])).uppercased(),
                                icb: icbLBN, isDirectory: characteristics & 0x02 != 0))
            }
            p += (38 + iuLength + nameLength + 3) & ~3
        }
        return out
    }

    /// An OSTA compressed Unicode name: 8 bits per character (id 8) or 16 (id 16).
    static func dstring(_ bytes: [UInt8]) -> String {
        guard let id = bytes.first else { return "" }
        if id == 16 {
            var units: [UInt16] = []
            var i = 1
            while i + 1 < bytes.count { units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        return String(String.UnicodeScalarView(bytes.dropFirst().map { Unicode.Scalar($0) }))   // Latin-1 code points
    }
}
