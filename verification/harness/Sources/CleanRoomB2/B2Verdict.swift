import Contracts

public enum B2Verdict {
    public static let subject: (any BadgeVerdict)? = B2BadgeVerdict()
}

/// A pure function from what the player knows about one track to the badge it shows.
struct B2BadgeVerdict: BadgeVerdict {
    /// Two rates are the same when they are within 0.5 Hz of each other. NaN and infinities never match.
    private static func ratesEqual(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= 0.5
    }

    func verdict(_ input: VerdictInput) -> String {
        let source = input.source
        let plan = input.plan
        let readback = input.readback
        let processing = input.processing

        // BPV-013: any silenced frame decides the badge.
        if processing.concealedFrames > 0 {
            return Badge.damagedFrames
        }

        // Conditions shared by every bit-perfect path.
        if let reason = sharedFailure(input) {
            return reason
        }

        // BPV-003: the nominal rate and the physical format must have been read back.
        guard let nominalRate = readback.nominalRate,
              let physicalDepth = readback.physicalBitDepth,
              let physicalIsInteger = readback.physicalIsInteger
        else {
            return "Device format could not be confirmed"
        }

        switch plan.mode {
        case .pcm:
            // BPV-001
            switch source.encoding {
            case .pcm: break
            case .lossy: return "Lossy source"
            case .dsd: return "DSD source in PCM mode"
            }
            if plan.resampling { return "Sample rate is converted" }
            if plan.dsdConvertedToPCM { return "DSD is converted to PCM" }

            // BPV-002
            if !Self.ratesEqual(nominalRate, source.sampleRate) {
                return "Device rate differs from the source rate"
            }

            // BPV-004
            if physicalIsInteger {
                if let sourceDepth = source.bitDepth, physicalDepth < sourceDepth {
                    return "Device bit depth is below the source bit depth"
                }
            } else if physicalDepth < 32 {
                return "Device floating-point format is below 32 bits"
            }

            // BPV-005
            if let sourceDepth = source.bitDepth, sourceDepth > 24, !plan.integerMode {
                return "Source deeper than 24 bits without integer mode"
            }

            // BPV-014
            if processing.equalizerActive {
                return Badge.equalizer
            }
            return Badge.bitPerfect

        case .dop:
            // BPV-016
            if !Self.ratesEqual(nominalRate, plan.requestedRate) {
                return "Device rate differs from the DoP carrier rate"
            }
            if physicalDepth < 24 {
                return "Device bit depth is below 24 bits for DoP"
            }
            return Badge.nativeDoP

        case .bitstream:
            // BPV-017
            if !Self.ratesEqual(nominalRate, plan.requestedRate) {
                return "Device rate differs from the bitstream rate"
            }
            if !physicalIsInteger || physicalDepth < 16 {
                return "Device format is not integer with at least 16 bits for bitstream"
            }
            return Badge.bitstreamPrefix + source.codec
        }
    }

    /// The reasons that rule out every kind of bit-perfect badge (BPV-006 to BPV-011).
    /// Returns nil when none of them applies.
    private func sharedFailure(_ input: VerdictInput) -> String? {
        let source = input.source
        let plan = input.plan
        let readback = input.readback
        let processing = input.processing

        // BPV-010 and BPV-011: the device class.
        switch input.deviceClass {
        case .bluetooth, .airPlay, .airPodsMaxBluetooth:
            return "Wireless device"
        case .builtInSpeakers, .virtual, .aggregate:
            return "Device cannot be bit-perfect"
        case .usbDAC, .builtInHeadphones, .airPodsMaxUSBC, .other:
            break
        }

        // BPV-006: any gain other than exactly 0 dB.
        if case .digital(let dB) = processing.volume, dB != 0 {
            return "Digital volume applies gain"
        }
        if let gain = processing.replayGainDB, gain != 0 {
            return "ReplayGain applies gain"
        }

        // BPV-007: spatial audio and channel layout.
        if plan.spatial != .off {
            return "Spatial audio is on"
        }
        if plan.channels != source.channels {
            return "Channels sent differ from the file"
        }
        if readback.deviceChannels < source.channels {
            return "Device carries fewer channels than the file"
        }

        // BPV-008 and BPV-009: another app playing, unless the device is held exclusively.
        if processing.otherAppsPlaying {
            let heldByPlayer: Bool
            if let owner = readback.hogOwnerPID, owner != -1, owner == readback.ownPID {
                heldByPlayer = true
            } else {
                heldByPlayer = false
            }
            if !heldByPlayer {
                return "Another app is playing to the device"
            }
        }

        return nil
    }
}
