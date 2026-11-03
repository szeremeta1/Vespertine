//
// Vespertine — a CUE sheet carried inside the audio file (FLAC's CUESHEET block, or a CUESHEET tag), which splits a
// single-file album into tracks as a .cue file beside it does.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

enum EmbeddedCue {
    /// The sheet inside `url`: a CUESHEET tag (foobar2000, EAC and others write the whole sheet as text, with titles), else
    /// a FLAC CUESHEET block (track offsets only). nil unless it names more than one track of audio.
    static func sheet(for url: URL, tags: [String: String]) -> CueSheet? {
        for (key, value) in tags where key.uppercased() == "CUESHEET" {
            let sheet = CueSheet.parse(value)
            if let usable = single(sheet) { return usable }
        }
        if url.pathExtension.lowercased() == "flac", let block = flacBlock(url), let usable = single(block) { return usable }
        return nil
    }

    /// A sheet that splits this one file: one file, more than one track, starts strictly increasing. (A sheet that
    /// names no file, as a tag's often doesn't, is taken to be about the file it is in.)
    private static func single(_ parsed: CueSheet) -> CueSheet? {
        var sheet = parsed
        if sheet.files.isEmpty { return nil }
        guard sheet.files.count == 1, let file = sheet.files.first, file.tracks.count > 1,
              Set(file.tracks.map(\.number)).count == file.tracks.count, file.tracks.allSatisfy({ $0.number > 0 }) else { return nil }
        let starts = file.tracks.map(\.startCDFrames)
        guard zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        sheet.files = [file]
        return sheet
    }

    /// FLAC's CUESHEET metadata block (type 5): CD-DA tracks with offsets in samples, ending with a lead-out (track 170).
    static func flacBlock(_ url: URL) -> CueSheet? {
        guard let file = try? FileHandle(forReadingFrom: url), let magic = try? file.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        defer { try? file.close() }
        var rate = 0.0
        while let header = try? file.read(upToCount: 4), header.count == 4 {
            let first = header[header.startIndex]
            let last = first & 0x80 != 0, type = first & 0x7F
            let length = Int(header[header.startIndex + 1]) << 16 | Int(header[header.startIndex + 2]) << 8 | Int(header[header.startIndex + 3])
            guard length < 1 << 24, let body = try? file.read(upToCount: length), body.count == length else { return nil }
            let b = [UInt8](body)
            if type == 0, b.count >= 18 {
                // STREAMINFO: the sample rate is 20 bits at byte 10.
                rate = Double(Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4)
            } else if type == 5, rate > 0, b.count >= 396 {
                func u64(_ at: Int) -> UInt64 { b[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) } }
                let count = Int(b[395])
                var p = 396, entries: [CueSheet.Entry] = []
                for _ in 0..<count {
                    guard p + 36 <= b.count else { return nil }
                    let offset = u64(p), number = Int(b[p + 8]), isAudio = b[p + 21] & 0x80 == 0, indices = Int(b[p + 35])
                    guard p + 36 + indices * 12 <= b.count else { return nil }
                    // The start of the track is its index 01 (index 00 is the pregap); a track with none starts at its offset.
                    var start = offset
                    for i in 0..<indices {
                        let at = p + 36 + i * 12
                        if b[at + 8] == 1 { start = offset + u64(at) }
                    }
                    if number != 170, number >= 1, number <= 99, isAudio {
                        let frames = (Double(start) / rate * 75).rounded()
                        guard frames.isFinite, frames >= 0, frames < Double(Int32.max) else { return nil }
                        entries.append(CueSheet.Entry(number: number, title: nil, performer: nil, isrc: nil, startCDFrames: Int(frames), startSample: Int64(start)))
                    }
                    p += 36 + indices * 12
                }
                return CueSheet(title: nil, performer: nil, genre: nil, date: nil, files: [.init(name: url.lastPathComponent, tracks: entries)])
            }
            if last { break }
        }
        return nil
    }
}

/// The tracks of a Matroska or WebM file with several audio streams: one library track per stream, listed once as versions
/// of the same song where their channel counts differ (as an SACD's stereo and multichannel areas are).
enum ContainerStreamTracks {
    static func split(_ base: Track, url: URL, streams: [ContainerAudioStream]) -> [Track] {
        guard streams.count > 1 else { return [base] }
        let counts = Dictionary(grouping: streams, by: \.channels).mapValues(\.count)
        return streams.map { stream in
            var t = base
            t.location = AudioStreamRef.location(path: url.path, index: stream.index)
            t.codec = stream.codec
            t.isLossless = stream.lossless
            t.sampleRate = stream.sampleRate > 0 ? stream.sampleRate : base.sampleRate
            t.bitDepth = stream.lossless ? stream.bits : nil
            t.channels = stream.channels
            // Two streams with the same layout (a second language, a commentary) must be told apart; a different layout already is.
            if counts[stream.channels, default: 0] > 1 {
                let label = stream.title ?? stream.language.map { $0.uppercased() } ?? "stream \(stream.index)"
                t.title = "\(base.title) (\(label))"
            }
            return t
        }
    }
}
