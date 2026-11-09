//
// Vespertine: Dolby AC-4 (immersive stereo and Atmos Music masters in MP4).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// AC-4 is Dolby's newer codec, used for its 2024 immersive-stereo masters ('ac-4' in an MP4 with the `dby1` brand).
// macOS reads the container and names the codec, but ships no AC-4 decoder (AVURLAsset.isPlayable is false and Core
// Audio's file readers return 'wht?'), and FFmpeg has none either. Vespertine can't play these files; it can say what
// they are, so the library doesn't label them a lossless 16-bit "MP4" and the player doesn't call them unrecognized.
//

import AVFoundation
import CoreMedia
import Foundation

public enum DolbyAC4 {
    public static let codecName = "Dolby AC-4"
    /// Core Audio's format ID: 'ac-4'.
    static let formatID: AudioFormatID = 0x6163_2D34
    static let containerExtensions: Set<String> = ["mp4", "m4a", "m4b", "m4v", "mov"]

    /// The format of the file's first audio track when it is AC-4, else nil. Reads only the container's description of
    /// the track: the sample entry's bit depth (always 16 in an AC-4 entry) says nothing, so none is reported.
    public static func format(of url: URL) -> SourceFormat? {
        guard containerExtensions.contains(url.pathExtension.lowercased()), isMP4(url) else { return nil }
        guard let track = LoadedAudioTrack(AVURLAsset(url: url)), let description = track.format,
              CMFormatDescriptionGetMediaSubType(description) == formatID,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        return SourceFormat(encoding: .lossy, codec: codecName, sampleRate: asbd.mSampleRate, bitDepth: nil,
                            channels: Int(asbd.mChannelsPerFrame))
    }

    /// An ISO base media file starts with an `ftyp` box: a cheap look before asking AVFoundation to open anything.
    private static func isMP4(_ url: URL) -> Bool {
        guard let file = try? PlaybackFile(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 8), head.count == 8 else { return false }
        return String(decoding: head[4..<8], as: UTF8.self) == "ftyp"
    }
}
