//
// Vespertine — room profiles made elsewhere: an Equalizer APO configuration (as REW and other measurement tools
// export it) with each speaker's delay, level and filters, or impulse responses (convolution filters) from WAV, AIFF,
// CAF or FLAC files; and a profile written back out as Equalizer APO text.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

extension RoomProfile {
    /// The most bands a speaker can have (as many as the I/O thread runs).
    public static let maxBands = RoomCorrectionPlayback.maxBandsPerChannel

    /// A profile that wasn't measured here: bound to `deviceUID`, its speakers on outputs in the standard order.
    public static func imported(name: String, deviceUID: String, layout: RoomLayout, source: RoomProfileSource,
                                filters: RoomFilterSet, alignment: [RoomSpeaker: RoomSpeakerAlignment]? = nil,
                                impulses: [RoomSpeaker: RoomImpulse]? = nil, createdAt: Date = Date()) -> RoomProfile {
        var profile = RoomProfile(id: UUID(), name: name, createdAt: createdAt, sessionID: UUID(), deviceUID: deviceUID, layout: layout,
                                  channelMap: .standard(layout), micSerial: "", calibrationSHA256: nil, target: .flat, filters: filters)
        profile.alignment = alignment
        profile.impulses = impulses
        profile.source = source
        return profile
    }
}

// MARK: - Equalizer APO / REW text

public enum RoomAPO {
    /// Equalizer APO's channel names (and the numbers 1–6) for the speakers of a 5.1 layout. Rear and side surrounds
    /// both stand for the 5.1 surrounds.
    static func speaker(_ token: String) -> RoomSpeaker? {
        if let n = Int(token), n >= 1, n <= RoomLayout.surround51.speakers.count { return RoomLayout.surround51.speakers[n - 1] }
        switch token.uppercased() {
        case "L": return .left
        case "R": return .right
        case "C": return .center
        case "LFE", "SUB": return .lfe
        case "RL", "BL", "SL": return .leftSurround
        case "RR", "BR", "SR": return .rightSurround
        default: return nil
        }
    }

    /// The name Equalizer APO uses for `speaker`.
    static func name(_ speaker: RoomSpeaker) -> String {
        switch speaker {
        case .left: "L"
        case .right: "R"
        case .center: "C"
        case .lfe: "LFE"
        case .leftSurround: "SL"
        case .rightSurround: "SR"
        }
    }

    /// One speaker's settings while the file is read.
    private struct Part {
        var delayMs = 0.0
        var levelDB = 0.0
        var bands: [EQBand] = []
    }

    /// Reads an Equalizer APO configuration with per-speaker sections:
    ///
    ///     Preamp: -4 dB
    ///     Channel: L
    ///     Delay: 1.2 ms
    ///     Filter 1: ON PK Fc 42 Hz Gain -9.5 dB Q 6.0
    ///     Channel: R
    ///     Preamp: -1.5 dB
    ///     Filter 1: ON PK Fc 45 Hz Gain -7 dB Q 5.2
    ///
    /// `Channel:` takes APO's names (L R C LFE/SUB, RL RR or SL SR for the surrounds), the numbers 1–6, or ALL. Filters
    /// and delays before any `Channel:` apply to every speaker. A `Preamp:` there is the profile's preamp; under
    /// `Channel:` it's that speaker's level. A file with no `Channel:` lines corrects left and right alike. A file that
    /// names the centre, LFE or surrounds is a 5.1 profile.
    public static func profile(_ text: String, name: String, deviceUID: String) throws -> RoomProfile {
        var shared = Part()
        var own: [RoomSpeaker: Part] = [:]
        var scope: [RoomSpeaker]? = nil   // nil: every speaker
        var preampDB = 0.0
        var anyFilter = false
        var lineNumber = 0

        func update(_ change: (inout Part) -> Void) {
            if let scope { for s in scope { change(&own[s, default: Part()]) } } else { change(&shared) }
        }

        for raw in text.components(separatedBy: .newlines) {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";"), let colon = line.firstIndex(of: ":") else { continue }
            let command = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let tokens = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)
            switch command {
            case "channel":
                guard !tokens.isEmpty else { throw EQImportError.unreadable(line: lineNumber) }
                if tokens.contains(where: { $0.uppercased() == "ALL" }) { scope = nil; continue }
                scope = try tokens.map { token in
                    guard let s = speaker(token) else { throw EQImportError.unsupportedChannel(line: lineNumber, name: token) }
                    return s
                }
            case "preamp":
                guard let db = tokens.first.flatMap(EQPreset.number) else { throw EQImportError.unreadable(line: lineNumber) }
                if scope == nil { preampDB += db } else { update { $0.levelDB += db } }
            case "delay":
                guard let value = tokens.first.flatMap(EQPreset.number), value >= 0 else { throw EQImportError.unreadable(line: lineNumber) }
                guard tokens.count < 2 || tokens[1].lowercased() == "ms" else { throw EQImportError.delayInSamples(line: lineNumber) }
                update { $0.delayMs += value }
            case "graphiceq":
                throw EQImportError.graphicEQ
            case "copy", "convolution":
                throw EQImportError.unsupportedCommand(line: lineNumber, command: String(line[..<colon]))
            default:
                // Device:, Include:, Eval: … say nothing about the sound.
                let numbered = command.hasPrefix("filter") && Int(command.dropFirst(6).trimmingCharacters(in: .whitespaces)) != nil
                guard command == "filter" || numbered else { continue }
                let band = try EQPreset.band(tokens, line: lineNumber)
                anyFilter = true
                update { $0.bands.append(band) }
            }
        }

        let surround = own.keys.contains { !RoomLayout.stereo.speakers.contains($0) }
        let layout: RoomLayout = surround ? .surround51 : .stereo
        var bands: [RoomSpeaker: [EQBand]] = [:]
        var alignment: [RoomSpeaker: RoomSpeakerAlignment] = [:]
        for speaker in layout.speakers {
            let mine = own[speaker] ?? Part()
            bands[speaker] = shared.bands + mine.bands
            alignment[speaker] = RoomSpeakerAlignment(delayMs: shared.delayMs + mine.delayMs, levelDB: shared.levelDB + mine.levelDB).clamped
        }
        guard anyFilter || alignment.values.contains(where: \.isActive) else { throw EQImportError.noFilters }
        if let crowded = bands.values.first(where: { $0.count > RoomProfile.maxBands }) {
            throw EQImportError.tooManyRoomFilters(crowded.count)
        }
        let preamp = min(max(preampDB, EQPreset.preampRange.lowerBound), 0)
        let filters = RoomFilterSet(version: 1, channels: bands, preampDB: preamp)
        return RoomProfile.imported(name: name, deviceUID: deviceUID, layout: layout, source: .equalizerAPO, filters: filters,
                                    alignment: alignment.values.contains(where: \.isActive) ? alignment : nil)
    }

    /// `profile` as Equalizer APO text, which `profile(_:name:deviceUID:)` reads back. Measured filters (impulse
    /// responses) can't be written as text; a comment names them.
    public static func text(_ profile: RoomProfile) -> String {
        var lines = ["# \(profile.name)", String(format: "Preamp: %.1f dB", profile.filters.preampDB)]
        for entry in profile.channelMap.entries.sorted(by: { $0.output < $1.output }) {
            let speaker = entry.speaker
            let alignment = profile.alignment(for: speaker)
            lines.append("Channel: " + name(speaker))
            if alignment.levelDB != 0 { lines.append(String(format: "Preamp: %.1f dB", alignment.levelDB)) }
            if alignment.delayMs > 0 { lines.append(String(format: "Delay: %.2f ms", alignment.delayMs)) }
            if let impulse = profile.impulses?[speaker] { lines.append("# Convolution: \(impulse.name) (impulse responses aren't exported)") }
            let bands = profile.filters.channels[speaker] ?? []
            let filters = EQPreset(name: profile.name, bands: bands).apoText.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
            lines.append(contentsOf: filters)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Impulse responses

public enum RoomImpulseImport {
    /// The speaker a file's name points to ("Left.wav", "filter_R.wav", "SL 48k.flac"…), if any.
    public static func speakerHint(_ fileName: String) -> RoomSpeaker? {
        let words = fileName.lowercased().split { !$0.isLetter }.map(String.init)
        let names: [(RoomSpeaker, Set<String>)] = [
            (.left, ["l", "left", "fl"]), (.right, ["r", "right", "fr"]), (.center, ["c", "center", "centre", "fc"]),
            (.lfe, ["lfe", "sub", "subwoofer"]), (.leftSurround, ["sl", "ls", "rl", "bl", "surroundleft"]),
            (.rightSurround, ["sr", "rs", "rr", "br", "surroundright"]),
        ]
        for word in words.reversed() {
            if let match = names.first(where: { $0.1.contains(word) }) { return match.0 }
        }
        return nil
    }

    /// Imports `files` as one profile: a file with several channels gives its channels to the speakers in order
    /// (L R C LFE SL SR); single-channel files go to the speaker their names point to, or else in order. Two to six
    /// filters in all; a single one corrects left and right alike.
    public static func profile(files: [URL], name: String, deviceUID: String, directory: URL = RoomImpulse.defaultDirectory) throws -> RoomProfile {
        var named: [RoomSpeaker: RoomImpulse] = [:]
        var unnamed: [RoomImpulse] = []
        var stored: [RoomImpulse] = []
        do {
            for url in files {
                let impulses = try RoomImpulse.importFile(url, into: directory)
                stored += impulses
                if impulses.count == 1, let hint = speakerHint(url.deletingPathExtension().lastPathComponent), named[hint] == nil {
                    named[hint] = impulses[0]
                } else {
                    unnamed += impulses
                }
            }
            guard !stored.isEmpty else { throw RoomImpulseError.empty }
            guard stored.count <= RoomLayout.surround51.speakers.count else { throw RoomImpulseError.tooManyChannels(stored.count) }
        } catch {
            stored.forEach { $0.delete(in: directory) }
            throw error
        }
        if stored.count == 1 {
            // One filter: both speakers alike.
            let only = stored[0]
            named = [.left: only, .right: only]
            unnamed = []
        }
        let layout: RoomLayout = named.count + unnamed.count > 2 || named.keys.contains { !RoomLayout.stereo.speakers.contains($0) }
            ? .surround51 : .stereo
        for speaker in layout.speakers where named[speaker] == nil && !unnamed.isEmpty {
            named[speaker] = unnamed.removeFirst()
        }
        let filters = RoomFilterSet(version: 1, channels: Dictionary(uniqueKeysWithValues: layout.speakers.map { ($0, [EQBand]()) }))
        return RoomProfile.imported(name: name, deviceUID: deviceUID, layout: layout, source: .impulseResponse, filters: filters, impulses: named)
    }
}
