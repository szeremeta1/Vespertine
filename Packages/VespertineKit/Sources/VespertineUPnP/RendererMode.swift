//
// Vespertine: pass-through or processed. A song goes to a renderer as its original file's bytes only when nothing would
// change its samples and the renderer takes the file as it is; otherwise Vespertine decodes it, runs its own chain and
// sends 24-bit FLAC at the source rate.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

/// What Vespertine applies for a renderer.
public struct RendererSettings: Sendable, Equatable {
    public var equalizer: EQPreset?
    public var roomCorrection: RoomCorrectionPlayback?
    /// nil: the volume is locked at 100% (the renderer's own volume is left alone).
    public var digitalVolumeDB: Double?

    public init(equalizer: EQPreset? = nil, roomCorrection: RoomCorrectionPlayback? = nil, digitalVolumeDB: Double? = nil) {
        self.equalizer = equalizer
        self.roomCorrection = roomCorrection
        self.digitalVolumeDB = digitalVolumeDB
    }

    /// The equalizer that changes something; nil otherwise.
    public var activeEqualizer: EQPreset? { equalizer.flatMap { $0.isFlat ? nil : $0 } }
    public var activeRoomCorrection: RoomCorrectionPlayback? { roomCorrection.flatMap { $0.isFlat ? nil : $0 } }
    public var activeVolumeDB: Double? { digitalVolumeDB.flatMap { $0 == 0 ? nil : $0 } }
}

public enum RendererModeDecision: Sendable, Equatable {
    /// The original bytes, as `mime`.
    case passThrough(mime: String)
    /// Decoded, processed, sent as 24-bit FLAC; why.
    case processed([SignalPath.RendererStage.Processing])
    /// Neither can be sent: the reason.
    case unplayable(String)
}

public enum RendererMode {
    /// `renderer` capabilities with no entries (GetProtocolInfo failed or answered nothing) accept everything: the renderer
    /// is left to refuse what it can't play.
    public static func decide(item: PlayableItem, url: URL, source: SourceFormat?, settings: RendererSettings,
                              capabilities: RendererCapabilities) -> RendererModeDecision {
        var reasons: [SignalPath.RendererStage.Processing] = []
        if settings.activeRoomCorrection != nil { reasons.append(.roomCorrection) }
        if settings.activeEqualizer != nil { reasons.append(.equalizer) }
        if settings.activeVolumeDB != nil { reasons.append(.volume) }
        if let gain = item.replayGainDB, gain != 0 { reasons.append(.replayGain) }
        let accepts: (String) -> Bool = { capabilities.entries.isEmpty || capabilities.accepts(mime: $0) }
        let wholeFile = item.regionStartFrame == nil && item.regionFrameLength == nil && item.sacdArea == nil && item.dvd == nil
            && item.audioStream == nil && url.isFileURL
        let mime = MediaType.mime(forExtension: url.pathExtension)
        // DSD is passed through only as a file the renderer lists; it can't be processed into FLAC without becoming PCM.
        if reasons.isEmpty, wholeFile, let mime, accepts(mime) { return .passThrough(mime: mime) }
        if reasons.isEmpty { reasons.append(.format) }
        guard accepts("audio/flac") else {
            return .unplayable(String(localized: "The renderer doesn't take FLAC, so this song can't be sent to it processed.", comment: "Error for a network renderer."))
        }
        return .processed(reasons)
    }
}
