//
// Vespertine: what a speaker group may play: PCM only, no passthrough, no integer mode.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The format rules for a speaker group (several DACs combined into one multichannel output).
///
/// A group plays through a private aggregate device whose followers are drift-corrected, i.e. resampled by a few millionths.
/// Anything that must reach a DAC untouched cannot go through that: DoP markers and IEC 61937 bursts would turn into loud
/// noise, and integer mode needs a non-mixable device format that an aggregate does not have. So for a group:
/// DSD is converted to PCM, Dolby and DTS are decoded, integer mode and "Match 16-bit sources" are off, and Spatial Audio
/// (a headphone feature) does not apply. These are rules of the code, not only of the settings screen.
public enum GroupFormatRules {
    public static let allowsDoP = false
    public static let allowsBitstream = false
    public static let allowsIntegerMode = false
    public static let allowsSixteenBitMatch = false
    public static let allowsSpatial = false

    /// The plan for `source` on a group whose members' common capabilities are `device` (`GroupCapabilities.combined`).
    /// Always PCM; the mode, spatial and integer fields cannot come out otherwise.
    public static func plan(source: SourceFormat, device: DeviceCapabilities, policy: RatePolicy = .matchSource,
                            spatial: SpatialMode = .off, spatializeStereo: Bool = false) -> OutputPlan {
        // `spatial` and `spatializeStereo` are taken so a caller passes the user's settings straight through; neither
        // applies to a group (see above), so they are not forwarded.
        _ = (spatial, spatializeStereo)
        var plan = FormatPlanner.plan(source: source, device: device, policy: policy, spatial: .off, bitstream: false,
                                      spatializeStereo: false, dsdToPCMForRoom: true, dsdToPCMForTransitions: false)
        if source.encoding == .dsd {
            plan.reason = "\(source.dsdName ?? "DSD") converted to PCM: a speaker group can't send DSD natively"
        }
        return enforced(plan)
    }

    /// Whatever produced `plan`, the group's rules hold afterwards.
    public static func enforced(_ plan: OutputPlan) -> OutputPlan {
        var safe = plan
        safe.mode = .pcm
        safe.integerSamples = false
        safe.sixteenBit = nil
        safe.spatial = .off
        safe.spatialBed = nil
        safe.deviceChannelCount = nil
        return safe
    }
}
