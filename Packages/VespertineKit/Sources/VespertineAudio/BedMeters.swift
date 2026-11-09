//
// Vespertine: the channels the built-in meters show for a bed Vespertine decodes beside the output.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dolby Atmos rendered by macOS and Dolby/DTS sent to a receiver untouched reach the output as compressed frames, so
// the meters can't read them there. A second decode of the same file gives the bed's channels (5.1, 7.1 …), named
// as for any other surround track, without touching what reaches the output.
//

import AudioToolbox
import Foundation

/// The speakers of a decoded bed, as the channel meters label them.
public struct BedMeterLayout: Sendable, Equatable {
    /// `AudioChannelLabel` of each channel, in the bed's order.
    public var labels: [UInt32]
    /// "L R C LFE Ls Rs", one per channel.
    public var names: [String]
    /// "5.1", "7.1", "7.1.4", "Stereo" …
    public var layout: String

    public init(labels: [UInt32]) {
        self.labels = labels
        names = labels.map(ChannelLayouts.shortName)
        layout = ChannelLayouts.name(labels: labels, channels: labels.count)
    }
}

extension ChannelLayouts {
    /// The order the meters show a bed's channels in, whatever order the decoder produced them in (Core Audio gives a
    /// Dolby bed as L C R Ls Rs LFE): the one the other surround tracks use, L R C LFE, then the surround pairs, the wide
    /// and centre-side speakers, then the heights front to back. `order[i]` is the decoder's channel shown `i`-th; channels
    /// without a place keep their relative order, last.
    static func meterOrder(_ labels: [AudioChannelLabel]) -> [Int] {
        func rank(_ label: AudioChannelLabel) -> Int {
            let places: [[AudioChannelLabel]] = [
                [kAudioChannelLabel_Left], [kAudioChannelLabel_Right], [kAudioChannelLabel_Center, kAudioChannelLabel_Mono],
                [kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2, kAudioChannelLabel_LFE3],
                [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect], [kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect],
                [kAudioChannelLabel_RearSurroundLeft], [kAudioChannelLabel_RearSurroundRight], [kAudioChannelLabel_CenterSurround],
                [kAudioChannelLabel_LeftCenter], [kAudioChannelLabel_RightCenter], [kAudioChannelLabel_LeftWide], [kAudioChannelLabel_RightWide],
                [kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_LeftTopFront], [kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_RightTopFront],
                [kAudioChannelLabel_VerticalHeightCenter, kAudioChannelLabel_CenterTopFront],
                [kAudioChannelLabel_LeftTopMiddle], [kAudioChannelLabel_RightTopMiddle], [kAudioChannelLabel_CenterTopMiddle, kAudioChannelLabel_TopCenterSurround],
                [kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_LeftTopRear], [kAudioChannelLabel_TopBackRight, kAudioChannelLabel_RightTopRear],
                [kAudioChannelLabel_TopBackCenter, kAudioChannelLabel_CenterTopRear],
            ]
            return places.firstIndex { $0.contains(label) } ?? places.count
        }
        return labels.indices.sorted { (rank(labels[$0]), $0) < (rank(labels[$1]), $1) }
    }
}
