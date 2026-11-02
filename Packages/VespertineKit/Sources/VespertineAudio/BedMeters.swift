//
// Vespertine — the channels the built-in meters show for a bed Vespertine decodes beside the output.
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
