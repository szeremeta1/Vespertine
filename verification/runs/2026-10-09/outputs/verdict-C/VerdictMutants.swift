//
// Deliberately wrong BIT-PERFECT verdicts (role C). Each mutant decorates a correct verdict that the harness
// supplies and is wrong only where its targets say.
//
// Two shapes are used:
//   * `overlook`: when a failing condition is present, the mutant answers what the correct verdict gives for the
//     input with that condition repaired, but only if that answer is an untouched badge (BIT-PERFECT,
//     NATIVE DSD · DoP or BITSTREAM · …). Everywhere else it answers exactly like the correct verdict, so the
//     mutant differs only by claiming an untouched path that isn't.
//   * `replace`: when the correct verdict gives a particular badge under a particular condition, the mutant gives a
//     different string instead.
//

import Contracts
import SpecKit

// MARK: - Building blocks

/// A verdict that answers through `body`, given the correct verdict `base`.
private struct DecoratedVerdict: BadgeVerdict {
    let base: any BadgeVerdict
    let body: @Sendable (any BadgeVerdict, VerdictInput) -> String

    func verdict(_ input: VerdictInput) -> String { body(base, input) }
}

/// The badges that claim an untouched path.
private func claimsUntouched(_ badge: String) -> Bool {
    badge == Badge.bitPerfect || badge == Badge.nativeDoP || badge.hasPrefix(Badge.bitstreamPrefix)
}

/// Rates further apart than the contract's 0.5 Hz tolerance (false when either is NaN).
private func ratesDiffer(_ a: Double, _ b: Double) -> Bool { abs(a - b) > 0.5 }

/// Rates within the contract's 0.5 Hz tolerance.
private func ratesMatch(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.5 }

/// Overlooks a failing condition: when `condition` holds and the correct verdict gives a reason, answers what the
/// correct verdict gives for the input with `fix` applied, if that is an untouched badge; otherwise the correct
/// answer.
private func overlook(_ base: any BadgeVerdict,
                      when condition: @escaping @Sendable (VerdictInput) -> Bool,
                      fix: @escaping @Sendable (inout VerdictInput) -> Void) -> any BadgeVerdict {
    DecoratedVerdict(base: base) { base, input in
        let answer = base.verdict(input)
        guard !claimsUntouched(answer), condition(input) else { return answer }
        var repaired = input
        fix(&repaired)
        let pretended = base.verdict(repaired)
        return claimsUntouched(pretended) ? pretended : answer
    }
}

/// Gives `replacement` instead of the correct answer when `condition` holds for the input and that answer.
private func replace(_ base: any BadgeVerdict,
                     when condition: @escaping @Sendable (VerdictInput, String) -> Bool,
                     with replacement: String) -> any BadgeVerdict {
    DecoratedVerdict(base: base) { base, input in
        let answer = base.verdict(input)
        return condition(input, answer) ? replacement : answer
    }
}

private extension VerdictInput {
    var inPCM: Bool { plan.mode == .pcm }
    var inDoP: Bool { plan.mode == .dop }
    var inBitstream: Bool { plan.mode == .bitstream }
    /// The digital volume's gain, nil for hardware or fixed volume.
    var digitalGainDB: Double? {
        if case .digital(let dB) = processing.volume { return dB }
        return nil
    }
    /// Digital volume or ReplayGain applies a gain other than 0 dB.
    var appliesGain: Bool {
        if let dB = digitalGainDB, dB != 0 { return true }
        if let gain = processing.replayGainDB, gain != 0 { return true }
        return false
    }
    /// The hog-mode owner read back is the player's own process.
    var holdsDevice: Bool { readback.hogOwnerPID == readback.ownPID }
    var onAirPodsMaxUSBC: Bool { deviceClass == .airPodsMaxUSBC }
    var onBluetooth: Bool { deviceClass == .bluetooth || deviceClass == .airPodsMaxBluetooth }

    /// Removes digital volume and ReplayGain.
    mutating func dropGain() {
        processing.volume = .hardware
        processing.replayGainDB = nil
    }

    /// Another app plays to a device the player doesn't hold (BPV-008 fails).
    var sharedWithOtherApp: Bool { processing.otherAppsPlaying && !holdsDevice }

    /// Turns integer mode on. Integer mode only occurs while the player holds the device (BPV-018), so the device is
    /// marked held too; callers only do this when no other app plays to a device the player doesn't hold, so marking
    /// it held repairs nothing else on a PCM path.
    mutating func turnOnIntegerMode() {
        plan.integerMode = true
        readback.hogOwnerPID = readback.ownPID
    }
}

private let losslessCodecNames: Set<String> = ["FLAC", "ALAC", "WAV", "WAVE", "AIFF", "AIF", "APE", "WAVPACK", "WV"]

// MARK: - The mutants

public enum VerdictMutants {
    public static let all: [Mutant<any BadgeVerdict>] =
        bpv001 + bpv002 + bpv003 + bpv004 + bpv005 + bpv006 + bpv007 + bpv008 + bpv009
        + bpv010 + bpv011 + bpv012 + bpv013 + bpv014 + bpv015 + bpv016 + bpv017

    // BPV-001: in PCM mode, not BIT-PERFECT for a lossy or DSD source, a converted rate, or DSD converted to PCM.
    static let bpv001: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-001-a", targets: ["BPV-001"],
               summary: "PCM mode: a lossy source is treated as lossless PCM") { base in
            overlook(base, when: { $0.inPCM && $0.source.encoding == .lossy }, fix: { i in
                i.source.encoding = .pcm
                if i.source.bitDepth == nil { i.source.bitDepth = 16 }
            })
        },
        Mutant("C-BPV-001-b", targets: ["BPV-001"],
               summary: "PCM mode: the resampling flag is ignored") { base in
            overlook(base, when: { $0.inPCM && $0.plan.resampling }, fix: { i in i.plan.resampling = false })
        },
        Mutant("C-BPV-001-c", targets: ["BPV-001"],
               summary: "PCM mode: a DSD source and DSD-to-PCM conversion are ignored") { base in
            overlook(base, when: { $0.inPCM && ($0.source.encoding == .dsd || $0.plan.dsdConvertedToPCM) }, fix: { i in
                if i.source.encoding == .dsd {
                    i.source.encoding = .pcm
                    if i.source.bitDepth == nil { i.source.bitDepth = 16 }
                }
                i.plan.dsdConvertedToPCM = false
            })
        },
        Mutant("C-BPV-001-d", targets: ["BPV-001"],
               summary: "PCM mode: trusts a lossless codec name (FLAC, ALAC, WAV, AIFF…) over a lossy encoding") { base in
            overlook(base, when: { i in
                i.inPCM && i.source.encoding == .lossy && losslessCodecNames.contains(i.source.codec.uppercased())
            }, fix: { i in
                i.source.encoding = .pcm
                if i.source.bitDepth == nil { i.source.bitDepth = 16 }
            })
        },
        Mutant("C-BPV-001-e", targets: ["BPV-001", "BPV-002"],
               summary: "PCM mode: DSD converted to PCM is judged as a PCM file at the device's read-back rate") { base in
            overlook(base, when: { i in
                i.inPCM && i.source.encoding == .dsd && i.plan.dsdConvertedToPCM && i.readback.nominalRate != nil
            }, fix: { i in
                i.source.encoding = .pcm
                i.source.sampleRate = i.readback.nominalRate ?? i.source.sampleRate
                if i.source.bitDepth == nil { i.source.bitDepth = 16 }
                i.plan.dsdConvertedToPCM = false
                i.plan.resampling = false
            })
        },
    ]

    // BPV-002: in PCM mode, BIT-PERFECT needs the nominal rate read back to equal the source rate.
    static let bpv002: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-002-a", targets: ["BPV-002"],
               summary: "PCM mode: compares the requested rate, not the nominal rate read back, with the source rate") { base in
            overlook(base, when: { i in
                guard i.inPCM, let nominal = i.readback.nominalRate else { return false }
                return ratesDiffer(nominal, i.source.sampleRate) && ratesMatch(i.plan.requestedRate, i.source.sampleRate)
            }, fix: { i in i.readback.nominalRate = i.source.sampleRate })
        },
        Mutant("C-BPV-002-b", targets: ["BPV-002"],
               summary: "PCM mode: a device rate that is a whole multiple of the source rate (88.2 kHz for 44.1 kHz) passes") { base in
            overlook(base, when: { i in
                guard i.inPCM, let nominal = i.readback.nominalRate else { return false }
                let rate = i.source.sampleRate
                guard rate > 0, rate.isFinite, nominal.isFinite, nominal > rate + 0.5 else { return false }
                let ratio = nominal / rate
                guard ratio >= 1.5, ratio < 64.5 else { return false }
                let multiple = Double(Int(ratio + 0.5))
                return ratesMatch(nominal, multiple * rate)
            }, fix: { i in i.readback.nominalRate = i.source.sampleRate })
        },
        Mutant("C-BPV-002-c", targets: ["BPV-002"],
               summary: "PCM mode: the rate check is skipped for sources above 192 kHz") { base in
            overlook(base, when: { i in
                guard i.inPCM, let nominal = i.readback.nominalRate else { return false }
                return i.source.sampleRate > 192_000.5 && ratesDiffer(nominal, i.source.sampleRate)
            }, fix: { i in i.readback.nominalRate = i.source.sampleRate })
        },
        Mutant("C-BPV-002-d", targets: ["BPV-002", "BPV-015"],
               summary: "PCM mode: the requested rate must also equal the source rate, so a matching read-back is not enough") { base in
            replace(base, when: { i, answer in
                answer == Badge.bitPerfect && !i.onAirPodsMaxUSBC && ratesDiffer(i.plan.requestedRate, i.source.sampleRate)
            }, with: "RATE REQUEST MISMATCH")
        },
    ]

    // BPV-003: an unread nominal rate or physical format rules out every untouched badge.
    static let bpv003: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-003-a", targets: ["BPV-003", "BPV-002"],
               summary: "PCM mode: an unread nominal rate falls back to the requested rate") { base in
            overlook(base, when: { $0.inPCM && $0.readback.nominalRate == nil },
                     fix: { i in i.readback.nominalRate = i.plan.requestedRate })
        },
        Mutant("C-BPV-003-b", targets: ["BPV-003"],
               summary: "PCM mode: an unread physical bit depth is assumed to be 32 bits") { base in
            overlook(base, when: { $0.inPCM && $0.readback.physicalBitDepth == nil },
                     fix: { i in i.readback.physicalBitDepth = 32 })
        },
        Mutant("C-BPV-003-c", targets: ["BPV-003"],
               summary: "PCM mode: an unread integer/float flag is assumed to mean integer") { base in
            overlook(base, when: { $0.inPCM && $0.readback.physicalIsInteger == nil },
                     fix: { i in i.readback.physicalIsInteger = true })
        },
        Mutant("C-BPV-003-d", targets: ["BPV-003", "BPV-016"],
               summary: "DoP mode: an unread nominal rate falls back to the planned carrier rate") { base in
            overlook(base, when: { $0.inDoP && $0.readback.nominalRate == nil },
                     fix: { i in i.readback.nominalRate = i.plan.requestedRate })
        },
        Mutant("C-BPV-003-e", targets: ["BPV-003", "BPV-017"],
               summary: "bitstream mode: an unread nominal rate or physical format is filled in from the plan") { base in
            overlook(base, when: { i in
                i.inBitstream && (i.readback.nominalRate == nil || i.readback.physicalBitDepth == nil
                    || i.readback.physicalIsInteger == nil)
            }, fix: { i in
                if i.readback.nominalRate == nil { i.readback.nominalRate = i.plan.requestedRate }
                if i.readback.physicalBitDepth == nil { i.readback.physicalBitDepth = max(i.plan.requestedBitDepth, 16) }
                if i.readback.physicalIsInteger == nil { i.readback.physicalIsInteger = true }
            })
        },
    ]

    // BPV-004: in PCM mode, not BIT-PERFECT on an integer format narrower than the source or a float format under 32 bits.
    static let bpv004: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-004-a", targets: ["BPV-004"],
               summary: "PCM mode: compares the source with the requested bit depth instead of the physical one read back") { base in
            overlook(base, when: { i in
                guard i.inPCM, i.readback.physicalIsInteger == true, let physical = i.readback.physicalBitDepth,
                      let bits = i.source.bitDepth else { return false }
                return physical < bits && i.plan.requestedBitDepth >= bits
            }, fix: { i in i.readback.physicalBitDepth = i.plan.requestedBitDepth })
        },
        Mutant("C-BPV-004-b", targets: ["BPV-004"],
               summary: "PCM mode: a floating-point physical format passes whatever its width") { base in
            overlook(base, when: { i in
                guard i.inPCM, i.source.bitDepth != nil, i.readback.physicalIsInteger == false,
                      let physical = i.readback.physicalBitDepth else { return false }
                return physical < 32
            }, fix: { i in i.readback.physicalBitDepth = 32 })
        },
        Mutant("C-BPV-004-c", targets: ["BPV-004"],
               summary: "PCM mode: a 24-to-31-bit floating-point physical format passes (threshold 24 instead of 32)") { base in
            overlook(base, when: { i in
                guard i.inPCM, i.source.bitDepth != nil, i.readback.physicalIsInteger == false,
                      let physical = i.readback.physicalBitDepth else { return false }
                return physical >= 24 && physical < 32
            }, fix: { i in i.readback.physicalBitDepth = 32 })
        },
        Mutant("C-BPV-004-d", targets: ["BPV-004"],
               summary: "PCM mode: the integer bit-depth comparison is skipped when integer mode is on") { base in
            overlook(base, when: { i in
                guard i.inPCM, i.plan.integerMode, i.readback.physicalIsInteger == true,
                      let physical = i.readback.physicalBitDepth, let bits = i.source.bitDepth else { return false }
                return physical < bits
            }, fix: { i in i.readback.physicalBitDepth = i.source.bitDepth })
        },
        Mutant("C-BPV-004-e", targets: ["BPV-004"],
               summary: "PCM mode: compares whole bytes, not bits, so a 24-bit source passes on a 20-bit integer format") { base in
            overlook(base, when: { i in
                guard i.inPCM, i.readback.physicalIsInteger == true, let physical = i.readback.physicalBitDepth,
                      let bits = i.source.bitDepth, (1...1024).contains(physical), (1...1024).contains(bits)
                else { return false }
                return physical < bits && (physical + 7) / 8 >= (bits + 7) / 8
            }, fix: { i in i.readback.physicalBitDepth = i.source.bitDepth })
        },
    ]

    // BPV-005: in PCM mode, a source deeper than 24 bits needs integer mode.
    static let bpv005: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-005-a", targets: ["BPV-005"],
               summary: "PCM mode: integer mode is ignored, so a source deeper than 24 bits passes without it (held or shared)") { base in
            overlook(base, when: { i in
                guard i.inPCM, !i.plan.integerMode, !i.sharedWithOtherApp, let bits = i.source.bitDepth else { return false }
                return bits > 24
            }, fix: { i in i.turnOnIntegerMode() })
        },
        Mutant("C-BPV-005-b", targets: ["BPV-005"],
               summary: "PCM mode: a source deeper than 24 bits passes without integer mode on a 32-bit float physical format") { base in
            overlook(base, when: { i in
                guard i.inPCM, !i.plan.integerMode, !i.sharedWithOtherApp, let bits = i.source.bitDepth, bits > 24,
                      i.readback.physicalIsInteger == false, let physical = i.readback.physicalBitDepth else { return false }
                return physical >= 32
            }, fix: { i in
                i.turnOnIntegerMode()
                i.readback.physicalIsInteger = true
                i.readback.physicalBitDepth = max(i.readback.physicalBitDepth ?? 32, i.source.bitDepth ?? 32)
            })
        },
        Mutant("C-BPV-005-c", targets: ["BPV-005"],
               summary: "PCM mode: exclusive (hog-mode) access is taken for integer mode with sources deeper than 24 bits") { base in
            overlook(base, when: { i in
                guard i.inPCM, !i.plan.integerMode, i.holdsDevice, let bits = i.source.bitDepth else { return false }
                return bits > 24
            }, fix: { i in i.plan.integerMode = true })
        },
    ]

    // BPV-006: digital volume or ReplayGain other than exactly 0 dB rules out every untouched badge.
    static let bpv006: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-006-a", targets: ["BPV-006"],
               summary: "PCM mode: digital volume is ignored") { base in
            overlook(base, when: { i in
                guard i.inPCM, let dB = i.digitalGainDB else { return false }
                return dB != 0
            }, fix: { i in i.processing.volume = .hardware })
        },
        Mutant("C-BPV-006-b", targets: ["BPV-006"],
               summary: "PCM mode: ReplayGain is ignored") { base in
            overlook(base, when: { i in
                guard i.inPCM, let gain = i.processing.replayGainDB else { return false }
                return gain != 0
            }, fix: { i in i.processing.replayGainDB = nil })
        },
        Mutant("C-BPV-006-c", targets: ["BPV-006"],
               summary: "PCM mode: digital volume and ReplayGain within ±0.5 dB count as 0 dB") { base in
            overlook(base, when: { i in
                guard i.inPCM else { return false }
                if let dB = i.digitalGainDB, dB != 0, abs(dB) < 0.5 { return true }
                if let gain = i.processing.replayGainDB, gain != 0, abs(gain) < 0.5 { return true }
                return false
            }, fix: { i in
                if let dB = i.digitalGainDB, abs(dB) < 0.5 { i.processing.volume = .hardware }
                if let gain = i.processing.replayGainDB, abs(gain) < 0.5 { i.processing.replayGainDB = nil }
            })
        },
        Mutant("C-BPV-006-d", targets: ["BPV-006"],
               summary: "PCM mode: a positive ReplayGain (boost) is ignored; only attenuation counts") { base in
            overlook(base, when: { i in
                guard i.inPCM, let gain = i.processing.replayGainDB else { return false }
                return gain > 0
            }, fix: { i in i.processing.replayGainDB = nil })
        },
        Mutant("C-BPV-006-e", targets: ["BPV-006", "BPV-016"],
               summary: "DoP mode: digital volume and ReplayGain are ignored") { base in
            overlook(base, when: { $0.inDoP && $0.appliesGain }, fix: { i in i.dropGain() })
        },
        Mutant("C-BPV-006-f", targets: ["BPV-006", "BPV-017"],
               summary: "bitstream mode: digital volume and ReplayGain are ignored") { base in
            overlook(base, when: { $0.inBitstream && $0.appliesGain }, fix: { i in i.dropGain() })
        },
        Mutant("C-BPV-006-g", targets: ["BPV-006", "BPV-015"],
               summary: "PCM mode: digital volume or ReplayGain at exactly 0 dB still rules out BIT-PERFECT") { base in
            replace(base, when: { i, answer in
                answer == Badge.bitPerfect && !i.onAirPodsMaxUSBC
                    && (i.digitalGainDB != nil || i.processing.replayGainDB != nil)
            }, with: "DIGITAL VOLUME")
        },
    ]

    // BPV-007: spatial audio, sent channels differing from the file, or a device with fewer channels rule out every
    // untouched badge.
    static let bpv007: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-007-a", targets: ["BPV-007"],
               summary: "PCM mode: spatial audio is ignored") { base in
            overlook(base, when: { $0.inPCM && $0.plan.spatial != .off }, fix: { i in i.plan.spatial = .off })
        },
        Mutant("C-BPV-007-b", targets: ["BPV-007"],
               summary: "PCM mode: only head-tracked spatial audio counts; fixed spatial rendering passes") { base in
            overlook(base, when: { $0.inPCM && $0.plan.spatial == .fixed }, fix: { i in i.plan.spatial = .off })
        },
        Mutant("C-BPV-007-c", targets: ["BPV-007"],
               summary: "PCM mode: sending more channels than the file has (upmixing) passes") { base in
            overlook(base, when: { $0.inPCM && $0.plan.channels > $0.source.channels },
                     fix: { i in i.plan.channels = i.source.channels })
        },
        Mutant("C-BPV-007-d", targets: ["BPV-007"],
               summary: "PCM mode: the device's channel count is checked only for files with more than two channels") { base in
            overlook(base, when: { i in
                i.inPCM && i.source.channels <= 2 && i.readback.deviceChannels < i.source.channels
            }, fix: { i in i.readback.deviceChannels = i.source.channels })
        },
        Mutant("C-BPV-007-e", targets: ["BPV-007", "BPV-016"],
               summary: "DoP mode: spatial audio is ignored") { base in
            overlook(base, when: { $0.inDoP && $0.plan.spatial != .off }, fix: { i in i.plan.spatial = .off })
        },
        Mutant("C-BPV-007-f", targets: ["BPV-007", "BPV-017"],
               summary: "bitstream mode: the channel checks are skipped") { base in
            overlook(base, when: { i in
                i.inBitstream && (i.plan.channels != i.source.channels || i.readback.deviceChannels < i.source.channels)
            }, fix: { i in
                i.plan.channels = i.source.channels
                i.readback.deviceChannels = max(i.readback.deviceChannels, i.source.channels)
            })
        },
    ]

    // BPV-008: another app playing rules out every untouched badge unless the player holds the device.
    static let bpv008: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-008-a", targets: ["BPV-008"],
               summary: "PCM mode: another app playing to the device is ignored") { base in
            overlook(base, when: { $0.inPCM && $0.processing.otherAppsPlaying },
                     fix: { i in i.processing.otherAppsPlaying = false })
        },
        Mutant("C-BPV-008-b", targets: ["BPV-008"],
               summary: "PCM mode: another app playing is ignored for sources of 16 bits or fewer (shared mixer assumed transparent)") { base in
            overlook(base, when: { i in
                guard i.inPCM, i.processing.otherAppsPlaying, let bits = i.source.bitDepth else { return false }
                return bits <= 16
            }, fix: { i in i.processing.otherAppsPlaying = false })
        },
        Mutant("C-BPV-008-c", targets: ["BPV-008", "BPV-016"],
               summary: "DoP mode: another app playing to a device the player doesn't hold is ignored (taken as held)") { base in
            overlook(base, when: { $0.inDoP && $0.sharedWithOtherApp }, fix: { i in
                i.processing.otherAppsPlaying = false
                i.readback.hogOwnerPID = i.readback.ownPID
            })
        },
        Mutant("C-BPV-008-d", targets: ["BPV-008", "BPV-017"],
               summary: "bitstream mode: another app playing to a device the player doesn't hold is ignored") { base in
            overlook(base, when: { $0.inBitstream && $0.processing.otherAppsPlaying && !$0.holdsDevice }, fix: { i in
                i.processing.otherAppsPlaying = false
                i.readback.hogOwnerPID = i.readback.ownPID
            })
        },
    ]

    // BPV-009: holding the device exclusively means the hog-mode owner read back is the player's own PID.
    static let bpv009: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-009-a", targets: ["BPV-009", "BPV-008"],
               summary: "PCM mode: any hog-mode owner other than −1 counts as the player holding the device") { base in
            overlook(base, when: { i in
                guard i.inPCM, i.processing.otherAppsPlaying, let owner = i.readback.hogOwnerPID else { return false }
                return owner != -1 && owner != i.readback.ownPID
            }, fix: { i in i.readback.hogOwnerPID = i.readback.ownPID })
        },
        Mutant("C-BPV-009-b", targets: ["BPV-009", "BPV-008"],
               summary: "PCM mode: an unreadable hog-mode owner (nil) counts as the player holding the device") { base in
            overlook(base, when: { $0.inPCM && $0.processing.otherAppsPlaying && $0.readback.hogOwnerPID == nil },
                     fix: { i in i.readback.hogOwnerPID = i.readback.ownPID })
        },
        Mutant("C-BPV-009-c", targets: ["BPV-009", "BPV-015"],
               summary: "PCM mode: the player's own hog-mode PID isn't recognised, so another app playing still blocks BIT-PERFECT") { base in
            replace(base, when: { i, answer in
                answer == Badge.bitPerfect && !i.onAirPodsMaxUSBC && i.processing.otherAppsPlaying && i.holdsDevice
            }, with: "SHARED DEVICE")
        },
        Mutant("C-BPV-009-d", targets: ["BPV-009", "BPV-008"],
               summary: "PCM mode: a hog-mode owner of −1 (nobody) counts as the player holding the device") { base in
            overlook(base, when: { $0.inPCM && $0.processing.otherAppsPlaying && $0.readback.hogOwnerPID == -1 },
                     fix: { i in i.readback.hogOwnerPID = i.readback.ownPID })
        },
    ]

    // BPV-010: Bluetooth (AirPods Max over Bluetooth included) and AirPlay never get an untouched badge.
    static let bpv010: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-010-a", targets: ["BPV-010"],
               summary: "PCM mode: AirPods Max over Bluetooth are treated like AirPods Max on the USB-C cable") { base in
            overlook(base, when: { $0.inPCM && $0.deviceClass == .airPodsMaxBluetooth },
                     fix: { i in i.deviceClass = .airPodsMaxUSBC })
        },
        Mutant("C-BPV-010-b", targets: ["BPV-010"],
               summary: "PCM mode: AirPlay devices can be BIT-PERFECT") { base in
            overlook(base, when: { $0.inPCM && $0.deviceClass == .airPlay }, fix: { i in i.deviceClass = .usbDAC })
        },
        Mutant("C-BPV-010-c", targets: ["BPV-010"],
               summary: "PCM mode: Bluetooth devices can be BIT-PERFECT") { base in
            overlook(base, when: { $0.inPCM && $0.deviceClass == .bluetooth }, fix: { i in i.deviceClass = .usbDAC })
        },
        Mutant("C-BPV-010-d", targets: ["BPV-010", "BPV-016"],
               summary: "DoP mode: AirPlay devices can get NATIVE DSD · DoP") { base in
            overlook(base, when: { $0.inDoP && $0.deviceClass == .airPlay }, fix: { i in i.deviceClass = .usbDAC })
        },
        Mutant("C-BPV-010-e", targets: ["BPV-010", "BPV-017"],
               summary: "bitstream mode: Bluetooth devices (AirPods Max over Bluetooth included) can get BITSTREAM") { base in
            overlook(base, when: { $0.inBitstream && $0.onBluetooth }, fix: { i in i.deviceClass = .other })
        },
    ]

    // BPV-011: built-in speakers, virtual and aggregate devices never get BIT-PERFECT.
    static let bpv011: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-011-a", targets: ["BPV-011"],
               summary: "PCM mode: an aggregate device can be BIT-PERFECT") { base in
            overlook(base, when: { $0.inPCM && $0.deviceClass == .aggregate }, fix: { i in i.deviceClass = .usbDAC })
        },
        Mutant("C-BPV-011-b", targets: ["BPV-011"],
               summary: "PCM mode: a virtual device can be BIT-PERFECT") { base in
            overlook(base, when: { $0.inPCM && $0.deviceClass == .virtual }, fix: { i in i.deviceClass = .usbDAC })
        },
        Mutant("C-BPV-011-c", targets: ["BPV-011"],
               summary: "PCM mode: the built-in speakers are treated like the headphone jack") { base in
            overlook(base, when: { $0.inPCM && $0.deviceClass == .builtInSpeakers },
                     fix: { i in i.deviceClass = .builtInHeadphones })
        },
    ]

    // BPV-012: AirPods Max on the USB-C cable can be BIT-PERFECT.
    static let bpv012: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-012-a", targets: ["BPV-012", "BPV-015"],
               summary: "AirPods Max on USB-C are never BIT-PERFECT (treated like Bluetooth)") { base in
            replace(base, when: { i, answer in answer == Badge.bitPerfect && i.onAirPodsMaxUSBC }, with: "AIRPODS MAX")
        },
        Mutant("C-BPV-012-b", targets: ["BPV-012", "BPV-015"],
               summary: "AirPods Max on USB-C: a source deeper than 16 bits is rejected (device assumed 16-bit)") { base in
            replace(base, when: { i, answer in
                answer == Badge.bitPerfect && i.onAirPodsMaxUSBC && (i.source.bitDepth ?? 0) > 16
            }, with: "AIRPODS MAX 16-BIT")
        },
        Mutant("C-BPV-012-c", targets: ["BPV-012", "BPV-015"],
               summary: "AirPods Max on USB-C: BIT-PERFECT only while the player holds the device in hog mode") { base in
            replace(base, when: { i, answer in
                answer == Badge.bitPerfect && i.onAirPodsMaxUSBC && !i.holdsDevice
            }, with: "AIRPODS MAX SHARED")
        },
    ]

    // BPV-013: any concealed frame gives exactly "DAMAGED FRAMES SILENCED" and no untouched badge.
    static let bpv013: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-013-a", targets: ["BPV-013"],
               summary: "PCM mode: concealed frames are ignored") { base in
            overlook(base, when: { $0.inPCM && $0.processing.concealedFrames > 0 },
                     fix: { i in i.processing.concealedFrames = 0 })
        },
        Mutant("C-BPV-013-b", targets: ["BPV-013"],
               summary: "PCM mode: a single concealed frame is ignored (needs more than one)") { base in
            overlook(base, when: { $0.inPCM && $0.processing.concealedFrames == 1 },
                     fix: { i in i.processing.concealedFrames = 0 })
        },
        Mutant("C-BPV-013-c", targets: ["BPV-013"],
               summary: "the damage label reads \"DAMAGED FRAMES\" instead of \"DAMAGED FRAMES SILENCED\"") { base in
            replace(base, when: { _, answer in answer == Badge.damagedFrames }, with: "DAMAGED FRAMES")
        },
        Mutant("C-BPV-013-d", targets: ["BPV-013", "BPV-016"],
               summary: "DoP mode: concealed frames are ignored") { base in
            overlook(base, when: { $0.inDoP && $0.processing.concealedFrames > 0 },
                     fix: { i in i.processing.concealedFrames = 0 })
        },
        Mutant("C-BPV-013-e", targets: ["BPV-013"],
               summary: "PCM mode: the concealed-frame count is kept in 16 bits, so large counts that wrap to ≤ 0 are ignored") { base in
            overlook(base, when: { i in
                i.inPCM && i.processing.concealedFrames > 0 && Int16(truncatingIfNeeded: i.processing.concealedFrames) <= 0
            }, fix: { i in i.processing.concealedFrames = 0 })
        },
        Mutant("C-BPV-013-f", targets: ["BPV-013", "BPV-017"],
               summary: "bitstream mode: concealed frames are ignored") { base in
            overlook(base, when: { $0.inBitstream && $0.processing.concealedFrames > 0 },
                     fix: { i in i.processing.concealedFrames = 0 })
        },
    ]

    // BPV-014: on an otherwise BIT-PERFECT PCM path, an active equalizer gives exactly "EQUALIZER".
    static let bpv014: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-014-a", targets: ["BPV-014"],
               summary: "PCM mode: an active equalizer is ignored") { base in
            overlook(base, when: { $0.inPCM && $0.processing.equalizerActive },
                     fix: { i in i.processing.equalizerActive = false })
        },
        Mutant("C-BPV-014-b", targets: ["BPV-014"],
               summary: "the equalizer label reads \"EQ ACTIVE\"") { base in
            replace(base, when: { _, answer in answer == Badge.equalizer }, with: "EQ ACTIVE")
        },
        Mutant("C-BPV-014-c", targets: ["BPV-014"],
               summary: "the equalizer label has a trailing space: \"EQUALIZER \"") { base in
            replace(base, when: { _, answer in answer == Badge.equalizer }, with: Badge.equalizer + " ")
        },
        Mutant("C-BPV-014-d", targets: ["BPV-014"],
               summary: "PCM mode: an active equalizer is ignored while integer mode is on") { base in
            overlook(base, when: { $0.inPCM && $0.plan.integerMode && $0.processing.equalizerActive },
                     fix: { i in i.processing.equalizerActive = false })
        },
    ]

    // BPV-015: a lossless PCM file meeting BPV-001 to BPV-011 with no concealed frames gets exactly "BIT-PERFECT".
    static let bpv015: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-015-a", targets: ["BPV-015"],
               summary: "the badge is spelt \"BIT PERFECT\" (no hyphen)") { base in
            replace(base, when: { i, answer in answer == Badge.bitPerfect && !i.onAirPodsMaxUSBC }, with: "BIT PERFECT")
        },
        Mutant("C-BPV-015-b", targets: ["BPV-015"],
               summary: "an integer physical format deeper than the source is rejected (exact bit-depth match required)") { base in
            replace(base, when: { i, answer in
                guard answer == Badge.bitPerfect, !i.onAirPodsMaxUSBC, i.readback.physicalIsInteger == true,
                      let physical = i.readback.physicalBitDepth, let bits = i.source.bitDepth else { return false }
                return physical > bits
            }, with: "BIT DEPTH MISMATCH")
        },
        Mutant("C-BPV-015-c", targets: ["BPV-015"],
               summary: "a 24-bit source is rejected without integer mode (threshold 24 bits and up instead of above 24)") { base in
            replace(base, when: { i, answer in
                answer == Badge.bitPerfect && !i.onAirPodsMaxUSBC && i.source.bitDepth == 24 && !i.plan.integerMode
            }, with: "FLOAT PATH")
        },
        Mutant("C-BPV-015-d", targets: ["BPV-015"],
               summary: "shared mode with no other app playing is rejected (hog-mode ownership required)") { base in
            replace(base, when: { i, answer in
                answer == Badge.bitPerfect && !i.onAirPodsMaxUSBC && !i.holdsDevice
            }, with: "SHARED MODE")
        },
        Mutant("C-BPV-015-e", targets: ["BPV-015"],
               summary: "a device carrying more channels than the file is rejected") { base in
            replace(base, when: { i, answer in
                answer == Badge.bitPerfect && !i.onAirPodsMaxUSBC && i.readback.deviceChannels > i.source.channels
            }, with: "CHANNEL MAP")
        },
    ]

    // BPV-016: in DoP mode, "NATIVE DSD · DoP" exactly when the player holds the device, the read-back rate is the
    // carrier rate, the physical format has at least 24 bits, and BPV-006 to BPV-011 and BPV-013 hold.
    static let bpv016: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-016-a", targets: ["BPV-016"],
               summary: "the DoP badge uses U+2022 BULLET instead of U+00B7 MIDDLE DOT") { base in
            replace(base, when: { _, answer in answer == Badge.nativeDoP }, with: "NATIVE DSD \u{2022} DoP")
        },
        Mutant("C-BPV-016-b", targets: ["BPV-016"],
               summary: "DoP mode: trusts the planned carrier rate instead of the nominal rate read back") { base in
            overlook(base, when: { i in
                guard i.inDoP, let nominal = i.readback.nominalRate else { return false }
                return ratesDiffer(nominal, i.plan.requestedRate)
            }, fix: { i in i.readback.nominalRate = i.plan.requestedRate })
        },
        Mutant("C-BPV-016-c", targets: ["BPV-016"],
               summary: "DoP mode: a 16-to-23-bit integer physical format is accepted") { base in
            overlook(base, when: { i in
                guard i.inDoP, i.readback.physicalIsInteger == true, let physical = i.readback.physicalBitDepth
                else { return false }
                return physical >= 16 && physical < 24
            }, fix: { i in i.readback.physicalBitDepth = 24 })
        },
        Mutant("C-BPV-016-d", targets: ["BPV-016"],
               summary: "DoP mode: exactly 24 bits required, so a 32-bit integer physical format is rejected") { base in
            replace(base, when: { i, answer in
                answer == Badge.nativeDoP && i.readback.physicalIsInteger == true && (i.readback.physicalBitDepth ?? 0) > 24
            }, with: "DoP NEEDS 24-BIT")
        },
        Mutant("C-BPV-016-e", targets: ["BPV-016"],
               summary: "DoP mode: multichannel DSD (more than two channels) is rejected") { base in
            replace(base, when: { i, answer in answer == Badge.nativeDoP && i.source.channels > 2 },
                    with: "DoP MULTICHANNEL")
        },
        Mutant("C-BPV-016-f", targets: ["BPV-016"],
               summary: "DoP mode: only the DSD64 carrier rate (176.4 kHz) gets the DoP badge") { base in
            replace(base, when: { i, answer in answer == Badge.nativeDoP && i.plan.requestedRate > 176_400.5 },
                    with: "DoP RATE")
        },
        Mutant("C-BPV-016-g", targets: ["BPV-016"],
               summary: "DoP mode: holding the device isn't required; shared mode with no other app playing gets the DoP badge") { base in
            overlook(base, when: { $0.inDoP && !$0.holdsDevice && !$0.processing.otherAppsPlaying },
                     fix: { i in i.readback.hogOwnerPID = i.readback.ownPID })
        },
        Mutant("C-BPV-016-h", targets: ["BPV-016", "BPV-009"],
               summary: "DoP mode: a hog-mode owner that is another process (not −1) counts as the player holding the device") { base in
            overlook(base, when: { i in
                guard i.inDoP, !i.processing.otherAppsPlaying, let owner = i.readback.hogOwnerPID else { return false }
                return owner != -1 && owner != i.readback.ownPID
            }, fix: { i in i.readback.hogOwnerPID = i.readback.ownPID })
        },
        Mutant("C-BPV-016-i", targets: ["BPV-016", "BPV-009"],
               summary: "DoP mode: an unreadable hog-mode owner (nil) counts as the player holding the device") { base in
            overlook(base, when: { $0.inDoP && !$0.processing.otherAppsPlaying && $0.readback.hogOwnerPID == nil },
                     fix: { i in i.readback.hogOwnerPID = i.readback.ownPID })
        },
    ]

    // BPV-017: in bitstream mode, a "BITSTREAM · " badge only when the player holds the device, the read-back rate is
    // the planned rate, the physical format is integer with at least 16 bits, and the shared conditions hold.
    static let bpv017: [Mutant<any BadgeVerdict>] = [
        Mutant("C-BPV-017-a", targets: ["BPV-017"],
               summary: "bitstream mode: trusts the planned rate instead of the nominal rate read back") { base in
            overlook(base, when: { i in
                guard i.inBitstream, let nominal = i.readback.nominalRate else { return false }
                return ratesDiffer(nominal, i.plan.requestedRate)
            }, fix: { i in i.readback.nominalRate = i.plan.requestedRate })
        },
        Mutant("C-BPV-017-b", targets: ["BPV-017"],
               summary: "bitstream mode: a floating-point physical format of 16 bits or more is accepted") { base in
            overlook(base, when: { i in
                guard i.inBitstream, i.readback.physicalIsInteger == false, let physical = i.readback.physicalBitDepth
                else { return false }
                return physical >= 16
            }, fix: { i in i.readback.physicalIsInteger = true })
        },
        Mutant("C-BPV-017-c", targets: ["BPV-017"],
               summary: "bitstream mode: an integer physical format narrower than 16 bits is accepted") { base in
            overlook(base, when: { i in
                guard i.inBitstream, i.readback.physicalIsInteger == true, let physical = i.readback.physicalBitDepth
                else { return false }
                return physical < 16
            }, fix: { i in i.readback.physicalBitDepth = 16 })
        },
        Mutant("C-BPV-017-d", targets: ["BPV-017"],
               summary: "bitstream mode: compares the read-back rate with the source's rate instead of the planned rate") { base in
            overlook(base, when: { i in
                guard i.inBitstream, let nominal = i.readback.nominalRate else { return false }
                return ratesDiffer(nominal, i.plan.requestedRate) && ratesMatch(nominal, i.source.sampleRate)
            }, fix: { i in i.readback.nominalRate = i.plan.requestedRate })
        },
        Mutant("C-BPV-017-e", targets: ["BPV-017"],
               summary: "bitstream mode: holding the device isn't required; shared mode with no other app playing gets BITSTREAM") { base in
            overlook(base, when: { $0.inBitstream && !$0.holdsDevice && !$0.processing.otherAppsPlaying },
                     fix: { i in i.readback.hogOwnerPID = i.readback.ownPID })
        },
        Mutant("C-BPV-017-f", targets: ["BPV-017", "BPV-009"],
               summary: "bitstream mode: a hog-mode owner that is another process (not −1) counts as the player holding the device") { base in
            overlook(base, when: { i in
                guard i.inBitstream, !i.processing.otherAppsPlaying, let owner = i.readback.hogOwnerPID else { return false }
                return owner != -1 && owner != i.readback.ownPID
            }, fix: { i in i.readback.hogOwnerPID = i.readback.ownPID })
        },
        Mutant("C-BPV-017-g", targets: ["BPV-017", "BPV-009"],
               summary: "bitstream mode: an unreadable hog-mode owner (nil) counts as the player holding the device") { base in
            overlook(base, when: { $0.inBitstream && !$0.processing.otherAppsPlaying && $0.readback.hogOwnerPID == nil },
                     fix: { i in i.readback.hogOwnerPID = i.readback.ownPID })
        },
    ]
}
