//
// Vespertine — room correction chains: headroom for boosts. A speaker's level trim can be up to +12 dB, and a band can boost; either
// lets a loud song rise past full scale in the chain, and a DAC clips there. The chain's preamp is shared by every channel, so
// it is lowered by the largest boost any channel can reach (its level plus the top of its bands): every channel then peaks at 0 dB
// or below, and the balance between channels, which the trims ask for, holds.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

extension RoomCorrectionPlayback {
    /// How far above the input channel `index` can rise, in dB, ahead of the shared preamp: its level (held to what the chain takes;
    /// a number that is not one is no level) plus the highest point of its bands over the usual sample rates. The design margin is
    /// added where bands boost, as the profile's own preamp does. A measured filter is not counted (its taps are not known here).
    func boostDB(ofChannel index: Int) -> Double {
        guard index < channels.count else { return 0 }
        let channel = channels[index]
        let level = channel.levelDB.isFinite ? RoomSpeakerAlignment(delayMs: 0, levelDB: channel.levelDB).clamped.levelDB : 0
        guard channel.bands.contains(where: \.isActive) else { return level }
        let preset = EQPreset(name: "", bands: channel.bands)
        let peak = RoomFilterDesigner.checkRates.map { preset.peakDB(sampleRate: $0) }.max() ?? 0
        return level + peak + (peak > 0.001 ? RoomFilterDesigner.headroomMarginDB : 0)
    }

    /// This chain with its preamp lowered, if it has to be, so that no channel can rise above 0 dB: never raised, and the
    /// channels' own levels, delays and bands are left as they are. Unchanged when the preamp already leaves enough room.
    public func withHeadroom() -> RoomCorrectionPlayback {
        let need = channels.indices.map { boostDB(ofChannel: $0) }.max() ?? 0
        guard need > 0.001 else { return self }
        let needed = max(-(need * 10).rounded(.up) / 10, EQPreset.preampRange.lowerBound)
        guard needed < preampDB else { return self }
        var out = self
        out.preampDB = needed
        return out
    }
}
