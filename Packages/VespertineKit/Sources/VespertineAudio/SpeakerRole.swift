//
// Vespertine — speaker groups: the places a loudspeaker can stand in a room, named after the speakers of a surround
// layout, and how they line up with Core Audio's channel labels.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

/// A point in the room, in metres: x to the right, y forward (towards the top of the room drawing).
public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }
}

/// What a speaker is in the layout: a front left, a rear right, a ceiling speaker. The role says which channel of a
/// surround file it carries; where it really stands is the speaker's position.
public enum SpeakerRole: String, Codable, CaseIterable, Sendable, Hashable {
    case frontLeft = "FL", frontRight = "FR", center = "C", lfe = "LFE"
    case sideLeft = "SL", sideRight = "SR"
    case backLeft = "BL", backRight = "BR", backCenter = "BC"
    case wideLeft = "WL", wideRight = "WR"
    case topFrontLeft = "TFL", topFrontRight = "TFR"
    case topMiddleLeft = "TML", topMiddleRight = "TMR"
    case topBackLeft = "TBL", topBackRight = "TBR"

    /// The Core Audio label for this place, in the convention Spatial.swift settles on: the side pair is Ls/Rs and the back
    /// pair Rls/Rrs, and each ceiling speaker has the one name `ChannelLayouts.canonical` keeps.
    public var channelLabel: AudioChannelLabel {
        switch self {
        case .frontLeft: kAudioChannelLabel_Left
        case .frontRight: kAudioChannelLabel_Right
        case .center: kAudioChannelLabel_Center
        case .lfe: kAudioChannelLabel_LFEScreen
        case .sideLeft: kAudioChannelLabel_LeftSurround
        case .sideRight: kAudioChannelLabel_RightSurround
        case .backLeft: kAudioChannelLabel_RearSurroundLeft
        case .backRight: kAudioChannelLabel_RearSurroundRight
        case .backCenter: kAudioChannelLabel_CenterSurround
        case .wideLeft: kAudioChannelLabel_LeftWide
        case .wideRight: kAudioChannelLabel_RightWide
        case .topFrontLeft: kAudioChannelLabel_VerticalHeightLeft
        case .topFrontRight: kAudioChannelLabel_VerticalHeightRight
        case .topMiddleLeft: kAudioChannelLabel_LeftTopMiddle
        case .topMiddleRight: kAudioChannelLabel_RightTopMiddle
        case .topBackLeft: kAudioChannelLabel_LeftTopRear
        case .topBackRight: kAudioChannelLabel_RightTopRear
        }
    }

    /// The role of a file's channel label. Names for the same place are one role (the older "vertical height" and "top back"
    /// labels, the WAVE side pair, a mono channel as a centre). nil for labels that name no speaker.
    public init?(label: AudioChannelLabel) {
        switch ChannelLayouts.canonical(label) {
        case kAudioChannelLabel_Left: self = .frontLeft
        case kAudioChannelLabel_Right: self = .frontRight
        case kAudioChannelLabel_Center: self = .center
        case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2, kAudioChannelLabel_LFE3: self = .lfe
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect: self = .sideLeft
        case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect: self = .sideRight
        case kAudioChannelLabel_RearSurroundLeft: self = .backLeft
        case kAudioChannelLabel_RearSurroundRight: self = .backRight
        case kAudioChannelLabel_CenterSurround: self = .backCenter
        case kAudioChannelLabel_LeftWide: self = .wideLeft
        case kAudioChannelLabel_RightWide: self = .wideRight
        case kAudioChannelLabel_VerticalHeightLeft: self = .topFrontLeft
        case kAudioChannelLabel_VerticalHeightRight: self = .topFrontRight
        case kAudioChannelLabel_LeftTopMiddle: self = .topMiddleLeft
        case kAudioChannelLabel_RightTopMiddle: self = .topMiddleRight
        case kAudioChannelLabel_LeftTopRear: self = .topBackLeft
        case kAudioChannelLabel_RightTopRear: self = .topBackRight
        default: return nil
        }
    }

    /// The angle this speaker stands at in the usual layouts, in degrees from straight ahead, positive to the right
    /// (ITU-R BS.775 and BS.2051; a 5.1 setup puts its surrounds at ±110° rather than the ±90° given here). nil for the LFE,
    /// which has no place.
    public var defaultAzimuth: Double? {
        switch self {
        case .lfe: nil
        case .center: 0
        case .frontLeft, .topFrontLeft: -30
        case .frontRight, .topFrontRight: 30
        case .wideLeft: -60
        case .wideRight: 60
        case .sideLeft, .topMiddleLeft: -90
        case .sideRight, .topMiddleRight: 90
        case .backLeft, .topBackLeft: -135
        case .backRight, .topBackRight: 135
        case .backCenter: 180
        }
    }

    /// A ceiling speaker.
    public var isHeight: Bool {
        switch self {
        case .topFrontLeft, .topFrontRight, .topMiddleLeft, .topMiddleRight, .topBackLeft, .topBackRight: true
        default: false
        }
    }
}
