//
// Role B implementation of the BIT-PERFECT verdict contract (records BPV-001 to BPV-017).
//

import Contracts

public enum BVerdict {
    public static let subject: (any BadgeVerdict)? = BitPerfectVerdict()
}

/// Pure badge decision. Checks run in a fixed order; the first failing condition names the badge.
struct BitPerfectVerdict: BadgeVerdict {

    // Reasons shown when the path is not bit-perfect. None of them equals, contains or starts with a named badge.
    enum Reason {
        static let bluetooth = "BLUETOOTH"
        static let airPlay = "AIRPLAY"
        static let builtInSpeakers = "BUILT-IN SPEAKERS"
        static let virtualDevice = "VIRTUAL DEVICE"
        static let aggregateDevice = "AGGREGATE DEVICE"
        static let formatUnconfirmed = "FORMAT NOT CONFIRMED"
        static let spatial = "SPATIAL AUDIO"
        static let channelsChanged = "CHANNELS CHANGED"
        static let deviceChannels = "DEVICE HAS FEWER CHANNELS"
        static let digitalVolume = "DIGITAL VOLUME"
        static let replayGain = "REPLAYGAIN"
        static let sharedDevice = "SHARED DEVICE"
        static let lossySource = "LOSSY SOURCE"
        static let dsdSource = "DSD SOURCE"
        static let dsdConverted = "DSD CONVERTED TO PCM"
        static let resampled = "RESAMPLED"
        static let rateMismatch = "RATE MISMATCH"
        static let bitDepthReduced = "BIT DEPTH REDUCED"
        static let floatOutput = "FLOAT OUTPUT"
        static let needsIntegerMode = "NEEDS INTEGER MODE"
    }

    func verdict(_ input: VerdictInput) -> String {
        // BPV-013: concealed frames override every other badge.
        if input.processing.concealedFrames > 0 {
            return Badge.damagedFrames
        }

        // BPV-010 (all badges) and BPV-011 (applied to every badge, see BPV-016).
        if let reason = Self.deviceReason(input.deviceClass) {
            return reason
        }

        // BPV-003: a rate or physical format that wasn't read back is not trusted.
        let readback = input.readback
        guard let nominalRate = readback.nominalRate,
              let physicalBits = readback.physicalBitDepth,
              let physicalIsInteger = readback.physicalIsInteger
        else {
            return Reason.formatUnconfirmed
        }

        // BPV-006 to BPV-009: conditions every path shares.
        if let reason = Self.sharedReason(input) {
            return reason
        }

        switch input.plan.mode {
        case .pcm:
            return Self.pcmVerdict(input, nominalRate: nominalRate, physicalBits: physicalBits,
                                   physicalIsInteger: physicalIsInteger)
        case .dop:
            // BPV-016
            guard Self.ratesEqual(nominalRate, input.plan.requestedRate) else { return Reason.rateMismatch }
            guard physicalBits >= 24 else { return Reason.bitDepthReduced }
            return Badge.nativeDoP
        case .bitstream:
            // BPV-017
            guard Self.ratesEqual(nominalRate, input.plan.requestedRate) else { return Reason.rateMismatch }
            guard physicalIsInteger else { return Reason.floatOutput }
            guard physicalBits >= 16 else { return Reason.bitDepthReduced }
            return Badge.bitstreamPrefix + input.source.codec
        }
    }

    // MARK: - Checks

    static func deviceReason(_ deviceClass: VerdictInput.DeviceClass) -> String? {
        switch deviceClass {
        case .bluetooth, .airPodsMaxBluetooth: return Reason.bluetooth
        case .airPlay: return Reason.airPlay
        case .builtInSpeakers: return Reason.builtInSpeakers
        case .virtual: return Reason.virtualDevice
        case .aggregate: return Reason.aggregateDevice
        case .usbDAC, .builtInHeadphones, .airPodsMaxUSBC, .other: return nil
        }
    }

    static func sharedReason(_ input: VerdictInput) -> String? {
        // BPV-007
        if input.plan.spatial != .off { return Reason.spatial }
        if input.plan.channels != input.source.channels { return Reason.channelsChanged }
        if input.readback.deviceChannels < input.source.channels { return Reason.deviceChannels }

        // BPV-006: only an exact 0 dB gain is allowed.
        if case .digital(let dB) = input.processing.volume, dB != 0 { return Reason.digitalVolume }
        if let gain = input.processing.replayGainDB, gain != 0 { return Reason.replayGain }

        // BPV-008 / BPV-009: another app may play only while the player holds the device in hog mode.
        if input.processing.otherAppsPlaying && !holdsDeviceExclusively(input.readback) {
            return Reason.sharedDevice
        }
        return nil
    }

    static func pcmVerdict(_ input: VerdictInput, nominalRate: Double, physicalBits: Int,
                           physicalIsInteger: Bool) -> String {
        let source = input.source
        let plan = input.plan

        // BPV-001
        if plan.dsdConvertedToPCM { return Reason.dsdConverted }
        switch source.encoding {
        case .pcm: break
        case .lossy: return Reason.lossySource
        case .dsd: return Reason.dsdSource
        }
        if plan.resampling { return Reason.resampled }

        // BPV-002: the read-back rate, not the requested one, must match the file.
        guard ratesEqual(nominalRate, source.sampleRate) else { return Reason.rateMismatch }

        // BPV-004
        if physicalIsInteger {
            if let sourceBits = source.bitDepth, physicalBits < sourceBits { return Reason.bitDepthReduced }
        } else if physicalBits < 32 {
            return Reason.bitDepthReduced
        }

        // BPV-005
        if let sourceBits = source.bitDepth, sourceBits > 24, !plan.integerMode { return Reason.needsIntegerMode }

        // BPV-014: only on a path that is otherwise bit-perfect.
        if input.processing.equalizerActive { return Badge.equalizer }

        // BPV-015
        return Badge.bitPerfect
    }

    /// BPV-009: exclusive means the read-back hog owner is the player's own PID (−1 means nobody holds it).
    static func holdsDeviceExclusively(_ readback: VerdictInput.Readback) -> Bool {
        guard let owner = readback.hogOwnerPID, owner != -1 else { return false }
        return owner == readback.ownPID
    }

    /// BPV-002: rates within 0.5 Hz are equal. NaN never equals anything.
    static func ratesEqual(_ a: Double, _ b: Double) -> Bool {
        let difference = a - b
        return difference.magnitude <= 0.5
    }
}
