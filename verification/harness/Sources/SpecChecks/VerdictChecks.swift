//
// Checks for the BIT-PERFECT verdict contract, traced to the BPV-* requirement records.
//
// Each scenario starts from a path the records say gets a known badge (a clean PCM path, a clean DoP path), or,
// for bitstream, from a path that meets every condition BPV-017 names, and changes one thing. Every assertion
// names the one record it checks. Nothing here indexes into anything the subject returns, and every loop is bounded.
//

import Contracts
import SpecKit

private typealias Check = SpecCheck<any BadgeVerdict>
private typealias Device = VerdictInput.DeviceClass
private typealias Volume = VerdictInput.Volume

public enum VerdictChecks {
    public static let all: [SpecCheck<any BadgeVerdict>] = [

        // REQ: BPV-015
        Check("PCM: a clean lossless path at the file's own rate is exactly BIT-PERFECT",
              requirements: ["BPV-015"]) { subject, checker in
            for x in cleanPCMPaths() {
                let badge = subject.verdict(x)
                checker.expect(isExactly(badge, Badge.bitPerfect), "BPV-015",
                               "lossless PCM at its own rate, every condition of BPV-001…011 met: \(report(badge, x))")
            }
        },

        // REQ: BPV-015
        Check("PCM: a requested rate that differs from a matching readback doesn't stop BIT-PERFECT",
              requirements: ["BPV-015"]) { subject, checker in
            for x0 in cleanPCMPaths() {
                for requested in clearlyDifferentRates(from: x0.source.sampleRate) {
                    var x = x0
                    x.plan.requestedRate = requested
                    let badge = subject.verdict(x)
                    checker.expect(isExactly(badge, Badge.bitPerfect), "BPV-015",
                                   "device reads back the file's rate, no resampling (the requested rate doesn't count): \(report(badge, x))")
                }
            }
        },

        // REQ: BPV-012, BPV-015
        Check("PCM: shared mode with no other app playing is BIT-PERFECT for a file of at most 24 bits",
              requirements: ["BPV-012", "BPV-015"]) { subject, checker in
            // Without the device held the player uses the float path (integer mode off), so only files of at most
            // 24 bits qualify (BPV-005).
            for x0 in cleanPCMPaths() {
                guard let bits = x0.source.bitDepth, bits <= 24 else { continue }
                var x = withHogOwner(x0, -1)
                x.processing.otherAppsPlaying = false
                let badge = subject.verdict(x)
                checker.expect(isExactly(badge, Badge.bitPerfect), "BPV-015",
                               "no process holds the device and no other app plays (BPV-008 met): \(report(badge, x))")
            }
            for x0 in airPodsMaxUSBCPaths() {
                var x = withHogOwner(x0, -1)
                x.processing.otherAppsPlaying = false
                let badge = subject.verdict(x)
                checker.expect(isExactly(badge, Badge.bitPerfect), "BPV-012",
                               "AirPods Max on USB-C, 48 kHz file, nobody holds the device, no other app plays (BPV-008 met): \(report(badge, x))")
            }
        },

        // REQ: BPV-016
        Check("DoP: NATIVE DSD · DoP needs the player to hold the device, even with no other app playing",
              requirements: ["BPV-016"]) { subject, checker in
            for x0 in cleanDoPPaths() {
                for hog in foreignHogOwners(own: x0.readback.ownPID) {
                    for othersPlaying in [false, true] {
                        var x = withHogOwner(x0, hog)
                        x.processing.otherAppsPlaying = othersPlaying
                        let badge = subject.verdict(x)
                        checker.expect(!looksNativeDoP(badge), "BPV-016",
                                       "hog owner \(hog.map { String($0) } ?? "unread") is not the player (\(x.readback.ownPID)): \(report(badge, x))")
                    }
                }
            }
        },

        // REQ: BPV-017
        Check("bitstream: a BITSTREAM badge needs the player to hold the device, even with no other app playing",
              requirements: ["BPV-017"]) { subject, checker in
            for x0 in bitstreamPaths() {
                for hog in foreignHogOwners(own: x0.readback.ownPID) {
                    for othersPlaying in [false, true] {
                        var x = withHogOwner(x0, hog)
                        x.processing.otherAppsPlaying = othersPlaying
                        let badge = subject.verdict(x)
                        checker.expect(!looksBitstream(badge), "BPV-017",
                                       "hog owner \(hog.map { String($0) } ?? "unread") is not the player (\(x.readback.ownPID)): \(report(badge, x))")
                    }
                }
            }
        },

        // REQ: BPV-001
        Check("PCM: a lossy or DSD source is never BIT-PERFECT", requirements: ["BPV-001"]) { subject, checker in
            for x0 in pcmBases() {
                // The encoding decides, whatever the codec string says.
                for codec in [x0.source.codec, "MP3", "AAC", "Opus"] {
                    var lossy = x0
                    lossy.source.encoding = .lossy
                    lossy.source.codec = codec
                    var b = subject.verdict(lossy)
                    checker.expect(!looksBitPerfect(b), "BPV-001", "lossy source (bit depth kept): \(report(b, lossy))")

                    lossy.source.bitDepth = nil
                    b = subject.verdict(lossy)
                    checker.expect(!looksBitPerfect(b), "BPV-001", "lossy source: \(report(b, lossy))")
                }

                for codec in [x0.source.codec, "DSF", "DSDIFF"] {
                    var dsd = x0
                    dsd.source.encoding = .dsd
                    dsd.source.codec = codec
                    var b = subject.verdict(dsd)
                    checker.expect(!looksBitPerfect(b), "BPV-001", "DSD source in PCM mode (bit depth kept): \(report(b, dsd))")

                    dsd.source.bitDepth = nil
                    b = subject.verdict(dsd)
                    checker.expect(!looksBitPerfect(b), "BPV-001", "DSD source in PCM mode: \(report(b, dsd))")

                    dsd.plan.dsdConvertedToPCM = true
                    b = subject.verdict(dsd)
                    checker.expect(!looksBitPerfect(b), "BPV-001", "DSD source converted to PCM: \(report(b, dsd))")
                }
            }
            // DSD files converted to PCM at the rates a player would pick.
            for dsdRate in dsdRates {
                for divisor in [8.0, 16.0, 32.0] {
                    for physical in [24, 32] {
                        let pcmRate = dsdRate / divisor
                        let x = VerdictInput(
                            source: .init(encoding: .dsd, codec: "DSDIFF", sampleRate: dsdRate, bitDepth: nil, channels: 2),
                            plan: .init(mode: .pcm, requestedRate: pcmRate, requestedBitDepth: physical, channels: 2,
                                        resampling: false, dsdConvertedToPCM: true, spatial: .off, integerMode: false),
                            readback: .init(nominalRate: pcmRate, physicalBitDepth: physical, physicalIsInteger: true,
                                            deviceChannels: 2, hogOwnerPID: defaultPID, ownPID: defaultPID),
                            deviceClass: .usbDAC, processing: untouchedProcessing())
                        let b = subject.verdict(x)
                        checker.expect(!looksBitPerfect(b), "BPV-001", "DSD converted to PCM: \(report(b, x))")
                    }
                }
            }
        },

        // REQ: BPV-001
        Check("PCM: rate conversion or DSD-to-PCM conversion is never BIT-PERFECT",
              requirements: ["BPV-001"]) { subject, checker in
            for x0 in pcmBases() {
                var resampled = x0
                resampled.plan.resampling = true
                var b = subject.verdict(resampled)
                checker.expect(!looksBitPerfect(b), "BPV-001",
                               "the player converts the sample rate (all rates still equal): \(report(b, resampled))")

                var converted = x0
                converted.plan.dsdConvertedToPCM = true
                b = subject.verdict(converted)
                checker.expect(!looksBitPerfect(b), "BPV-001", "DSD is converted to PCM: \(report(b, converted))")

                var both = resampled
                both.plan.dsdConvertedToPCM = true
                b = subject.verdict(both)
                checker.expect(!looksBitPerfect(b), "BPV-001",
                               "rate converted and DSD converted to PCM: \(report(b, both))")
            }
        },

        // REQ: BPV-002
        Check("PCM: the device's read-back rate must equal the file's rate; the requested rate doesn't count",
              requirements: ["BPV-002"]) { subject, checker in
            for x0 in pcmBases() {
                for nominal in clearlyDifferentRates(from: x0.source.sampleRate) {
                    var x = x0
                    x.readback.nominalRate = nominal
                    var b = subject.verdict(x)
                    checker.expect(!looksBitPerfect(b), "BPV-002",
                                   "requested rate equals the file's, read-back rate doesn't: \(report(b, x))")

                    x.plan.requestedRate = nominal
                    b = subject.verdict(x)
                    checker.expect(!looksBitPerfect(b), "BPV-002",
                                   "request and read-back agree with each other, not with the file: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-003
        Check("PCM: a rate or physical format that couldn't be read back is not trusted",
              requirements: ["BPV-003"]) { subject, checker in
            for x0 in pcmBases() {
                for x in unreadVariants(of: x0) {
                    let b = subject.verdict(x)
                    checker.expect(!claimsUntouched(b), "BPV-003", "readback failed: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-003
        Check("DoP: a rate or physical format that couldn't be read back is not trusted",
              requirements: ["BPV-003"]) { subject, checker in
            for x0 in cleanDoPPaths() {
                for x in unreadVariants(of: x0) {
                    let b = subject.verdict(x)
                    checker.expect(!claimsUntouched(b), "BPV-003", "readback failed: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-003
        Check("bitstream: a rate or physical format that couldn't be read back is not trusted",
              requirements: ["BPV-003"]) { subject, checker in
            for x0 in bitstreamPaths() {
                for x in unreadVariants(of: x0) {
                    let b = subject.verdict(x)
                    checker.expect(!claimsUntouched(b), "BPV-003", "readback failed: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-004
        Check("PCM: an integer physical format with fewer bits than the file is not BIT-PERFECT",
              requirements: ["BPV-004"]) { subject, checker in
            for x0 in pcmBases() {
                guard let sourceBits = x0.source.bitDepth else { continue }
                for physical in [8, 12, 16, 20, 24, 28] where physical < sourceBits {
                    var x = x0
                    x.readback.physicalBitDepth = physical
                    x.readback.physicalIsInteger = true
                    // The plan still asks for a deep enough format; only the read-back format is short.
                    x.plan.requestedBitDepth = max(x0.plan.requestedBitDepth, sourceBits)
                    let b = subject.verdict(x)
                    checker.expect(!looksBitPerfect(b), "BPV-004",
                                   "\(physical)-bit integer device for a \(sourceBits)-bit file: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-004
        Check("PCM: a floating-point physical format under 32 bits is not BIT-PERFECT",
              requirements: ["BPV-004"]) { subject, checker in
            for x0 in pcmBases() {
                for physical in [16, 20, 24] {
                    var x = x0
                    x.readback.physicalBitDepth = physical
                    x.readback.physicalIsInteger = false
                    let b = subject.verdict(x)
                    checker.expect(!looksBitPerfect(b), "BPV-004",
                                   "\(physical)-bit floating-point physical format: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-005, BPV-015
        Check("PCM: a file deeper than 24 bits needs integer mode", requirements: ["BPV-005", "BPV-015"]) { subject, checker in
            for x0 in cleanPCMPaths() {
                for sourceBits in [25, 28, 32] {
                    var x = x0
                    x.source.bitDepth = sourceBits
                    x.readback.physicalBitDepth = 32
                    x.readback.physicalIsInteger = true
                    x.plan.requestedBitDepth = 32
                    x.plan.integerMode = false
                    var b = subject.verdict(x)
                    checker.expect(!looksBitPerfect(b), "BPV-005",
                                   "\(sourceBits)-bit file without integer mode (32-bit integer device): \(report(b, x))")

                    x.readback.physicalIsInteger = false
                    b = subject.verdict(x)
                    checker.expect(!looksBitPerfect(b), "BPV-005",
                                   "\(sourceBits)-bit file without integer mode (32-bit float device): \(report(b, x))")

                    // Shared mode, nobody else playing: the player can't use integer mode (contract, BPV-018).
                    var shared = withHogOwner(x, -1)
                    shared.readback.physicalIsInteger = true
                    shared.processing.otherAppsPlaying = false
                    b = subject.verdict(shared)
                    checker.expect(!looksBitPerfect(b), "BPV-005",
                                   "\(sourceBits)-bit file in shared mode, so without integer mode: \(report(b, shared))")
                }
                var deep = x0
                deep.source.bitDepth = 32
                deep.readback.physicalBitDepth = 32
                deep.readback.physicalIsInteger = true
                deep.plan.requestedBitDepth = 32
                deep.plan.integerMode = true
                let b = subject.verdict(deep)
                checker.expect(isExactly(b, Badge.bitPerfect), "BPV-015",
                               "32-bit file, integer mode, 32-bit integer device, every condition met: \(report(b, deep))")
            }
        },

        // REQ: BPV-006
        Check("any digital volume or ReplayGain gain other than 0 dB rules out every untouched badge",
              requirements: ["BPV-006"]) { subject, checker in
            for x0 in everyModeBases() {
                for gain in nonZeroGains {
                    var digital = x0
                    digital.processing.volume = .digital(dB: gain)
                    var b = subject.verdict(digital)
                    checker.expect(!claimsUntouched(b), "BPV-006", "digital volume \(gain) dB: \(report(b, digital))")

                    digital.processing.replayGainDB = 0
                    b = subject.verdict(digital)
                    checker.expect(!claimsUntouched(b), "BPV-006",
                                   "digital volume \(gain) dB, ReplayGain 0 dB: \(report(b, digital))")

                    var replayGain = x0
                    replayGain.processing.replayGainDB = gain
                    b = subject.verdict(replayGain)
                    checker.expect(!claimsUntouched(b), "BPV-006", "ReplayGain \(gain) dB: \(report(b, replayGain))")

                    replayGain.processing.volume = .digital(dB: 0)
                    b = subject.verdict(replayGain)
                    checker.expect(!claimsUntouched(b), "BPV-006",
                                   "ReplayGain \(gain) dB, digital volume 0 dB: \(report(b, replayGain))")
                }
            }
        },

        // REQ: BPV-006
        Check("hardware or fixed volume, and digital volume or ReplayGain at 0 dB, are allowed",
              requirements: ["BPV-006"]) { subject, checker in
            let settings: [(Volume, Double?)] = [
                (.hardware, nil), (.fixed, nil), (.digital(dB: 0), nil),
                (.hardware, 0), (.fixed, 0), (.digital(dB: 0), 0),
            ]
            for x0 in pcmBases() {
                for (volume, replayGain) in settings {
                    var x = x0
                    x.processing.volume = volume
                    x.processing.replayGainDB = replayGain
                    let b = subject.verdict(x)
                    checker.expect(isExactly(b, Badge.bitPerfect), "BPV-006", "allowed volume setting: \(report(b, x))")
                }
            }
            for x0 in cleanDoPPaths() {
                for (volume, replayGain) in settings {
                    var x = x0
                    x.processing.volume = volume
                    x.processing.replayGainDB = replayGain
                    let b = subject.verdict(x)
                    checker.expect(isExactly(b, Badge.nativeDoP), "BPV-006", "allowed volume setting: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-006
        Check("a gain of negative zero is exactly 0 dB", requirements: ["BPV-006"]) { subject, checker in
            let negativeZero = -0.0
            for x0 in cleanPCMPaths() + cleanDoPPaths() {
                let expected = x0.plan.mode == .dop ? Badge.nativeDoP : Badge.bitPerfect
                var digital = x0
                digital.processing.volume = .digital(dB: negativeZero)
                var b = subject.verdict(digital)
                checker.expect(isExactly(b, expected), "BPV-006", "digital volume -0.0 dB: \(report(b, digital))")

                var replayGain = x0
                replayGain.processing.replayGainDB = negativeZero
                b = subject.verdict(replayGain)
                checker.expect(isExactly(b, expected), "BPV-006", "ReplayGain -0.0 dB: \(report(b, replayGain))")
            }
        },

        // REQ: BPV-007
        Check("spatial audio rules out every untouched badge", requirements: ["BPV-007"]) { subject, checker in
            for x0 in everyModeBases() {
                for spatial in [VerdictInput.Spatial.fixed, .headTracked] {
                    var x = x0
                    x.plan.spatial = spatial
                    let b = subject.verdict(x)
                    checker.expect(!claimsUntouched(b), "BPV-007", "spatial audio \(spatial): \(report(b, x))")
                }
            }
        },

        // REQ: BPV-007
        Check("sending a different number of channels than the file has rules out every untouched badge",
              requirements: ["BPV-007"]) { subject, checker in
            for x0 in everyModeBases() {
                let fileChannels = x0.source.channels
                var sent = [fileChannels - 1, fileChannels + 1, 1, 2, 6, 8].filter { $0 >= 1 && $0 != fileChannels }
                sent = sent.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
                for planChannels in sent {
                    var x = x0
                    x.plan.channels = planChannels
                    // The device carries at least as many channels as either side, so only the mismatch fails.
                    x.readback.deviceChannels = max(x0.readback.deviceChannels, planChannels, fileChannels)
                    let b = subject.verdict(x)
                    checker.expect(!claimsUntouched(b), "BPV-007",
                                   "\(planChannels) channels sent for a \(fileChannels)-channel file: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-007
        Check("a device carrying fewer channels than the file rules out every untouched badge",
              requirements: ["BPV-007"]) { subject, checker in
            for x0 in everyModeBases() {
                var base = x0
                if base.source.channels < 2 {
                    base.source.channels = 2
                    base.plan.channels = 2
                }
                let fileChannels = base.source.channels
                var carried = [fileChannels - 1, 1, 2].filter { $0 >= 1 && $0 < fileChannels }
                carried = carried.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
                for deviceChannels in carried {
                    var x = base
                    x.readback.deviceChannels = deviceChannels
                    let b = subject.verdict(x)
                    checker.expect(!claimsUntouched(b), "BPV-007",
                                   "device carries \(deviceChannels) channels for a \(fileChannels)-channel file: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-008
        Check("another app playing to a device nobody holds exclusively rules out every untouched badge",
              requirements: ["BPV-008"]) { subject, checker in
            for x0 in everyModeBases() {
                var x = withHogOwner(x0, -1)
                x.processing.otherAppsPlaying = true
                let b = subject.verdict(x)
                checker.expect(!claimsUntouched(b), "BPV-008", "another app plays, no hog owner: \(report(b, x))")
            }
        },

        // REQ: BPV-009
        Check("exclusive means the read-back hog owner is the player's own PID",
              requirements: ["BPV-009"]) { subject, checker in
            for x0 in everyModeBases() {
                let own = x0.readback.ownPID
                for hog in foreignHogOwners(own: own) {
                    var x = withHogOwner(x0, hog)
                    x.processing.otherAppsPlaying = true
                    let b = subject.verdict(x)
                    checker.expect(!claimsUntouched(b), "BPV-009",
                                   "another app plays, hog owner \(hog.map { String($0) } ?? "unread") is not the player (\(own)): \(report(b, x))")
                }
            }
            let ownPIDs: [Int32] = [1, 77, 501, 4_242, 31_337, 99_998, Int32.max]
            for x0 in pcmBases() + cleanDoPPaths() {
                let expected = x0.plan.mode == .dop ? Badge.nativeDoP : Badge.bitPerfect
                for own in ownPIDs {
                    var x = x0
                    x.processing.otherAppsPlaying = true
                    x.readback.ownPID = own
                    x.readback.hogOwnerPID = own
                    let b = subject.verdict(x)
                    checker.expect(isExactly(b, expected), "BPV-009",
                                   "another app plays but the player (\(own)) holds the device: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-010
        Check("Bluetooth, AirPods Max over Bluetooth and AirPlay never get an untouched badge",
              requirements: ["BPV-010"]) { subject, checker in
            for x0 in everyModeBases() {
                for device in [Device.bluetooth, .airPodsMaxBluetooth, .airPlay] {
                    var x = x0
                    x.deviceClass = device
                    let b = subject.verdict(x)
                    checker.expect(!claimsUntouched(b), "BPV-010", "\(device): \(report(b, x))")
                }
            }
        },

        // REQ: BPV-011
        Check("built-in speakers, virtual and aggregate devices are never BIT-PERFECT",
              requirements: ["BPV-011"]) { subject, checker in
            for x0 in everyModeBases() {
                for device in [Device.builtInSpeakers, .virtual, .aggregate] {
                    var x = x0
                    x.deviceClass = device
                    let b = subject.verdict(x)
                    checker.expect(!looksBitPerfect(b), "BPV-011", "\(device): \(report(b, x))")
                }
            }
        },

        // REQ: BPV-012
        Check("AirPods Max on USB-C: a clean 48 kHz file is BIT-PERFECT", requirements: ["BPV-012"]) { subject, checker in
            for x in airPodsMaxUSBCPaths() {
                let b = subject.verdict(x)
                checker.expect(isExactly(b, Badge.bitPerfect), "BPV-012",
                               "48 kHz file, 24-bit integer 48 kHz readback, every other condition met: \(report(b, x))")
            }
        },

        // REQ: BPV-013
        Check("concealed frames make the badge DAMAGED FRAMES SILENCED", requirements: ["BPV-013"]) { subject, checker in
            let counts = [1, 2, 3, 64, 1_024, 44_100, 1_000_000]
            for x0 in pcmBases() + cleanDoPPaths() {
                for count in counts {
                    var x = x0
                    x.processing.concealedFrames = count
                    let b = subject.verdict(x)
                    checker.expect(isExactly(b, Badge.damagedFrames), "BPV-013",
                                   "\(count) frame(s) concealed on an otherwise untouched path: \(report(b, x))")
                }
            }
            for x0 in bitstreamPaths() {
                for count in counts {
                    var x = x0
                    x.processing.concealedFrames = count
                    let b = subject.verdict(x)
                    checker.expect(!claimsUntouched(b), "BPV-013", "\(count) frame(s) concealed: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-014
        Check("an active equalizer on an otherwise BIT-PERFECT path makes the badge EQUALIZER",
              requirements: ["BPV-014"]) { subject, checker in
            for x0 in pcmBases() {
                var x = x0
                x.processing.equalizerActive = true
                let b = subject.verdict(x)
                checker.expect(isExactly(b, Badge.equalizer), "BPV-014", "equalizer on: \(report(b, x))")
            }
        },

        // REQ: BPV-016
        Check("DoP: a clean path is exactly NATIVE DSD · DoP", requirements: ["BPV-016"]) { subject, checker in
            for x in cleanDoPPaths() {
                let b = subject.verdict(x)
                checker.expect(isExactly(b, Badge.nativeDoP), "BPV-016",
                               "read-back rate equals the carrier, ≥24-bit device, every shared condition holds: \(report(b, x))")
            }
        },

        // REQ: BPV-016
        Check("DoP: the read-back rate must equal the planned carrier rate", requirements: ["BPV-016"]) { subject, checker in
            for x0 in cleanDoPPaths() {
                let carrier = x0.plan.requestedRate
                for other in clearlyDifferentRates(from: carrier) + [x0.source.sampleRate, 44_100, 48_000] where other != carrier {
                    var x = x0
                    x.readback.nominalRate = other
                    var b = subject.verdict(x)
                    checker.expect(!looksNativeDoP(b), "BPV-016",
                                   "carrier \(carrier) Hz planned, device reads back \(other) Hz: \(report(b, x))")

                    // The device runs at the file's natural carrier, but that's not what was planned.
                    x = x0
                    x.plan.requestedRate = other
                    b = subject.verdict(x)
                    checker.expect(!looksNativeDoP(b), "BPV-016",
                                   "carrier \(other) Hz planned, device reads back \(carrier) Hz: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-016
        Check("DoP: a physical format under 24 bits is not NATIVE DSD · DoP", requirements: ["BPV-016"]) { subject, checker in
            for x0 in cleanDoPPaths() {
                for (bits, integer) in [(8, true), (16, true), (20, true), (16, false), (20, false)] {
                    var x = x0
                    x.readback.physicalBitDepth = bits
                    x.readback.physicalIsInteger = integer
                    let b = subject.verdict(x)
                    checker.expect(!looksNativeDoP(b), "BPV-016",
                                   "\(bits)-bit \(integer ? "integer" : "float") physical format: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-017
        Check("bitstream: the read-back rate must equal the planned rate", requirements: ["BPV-017"]) { subject, checker in
            for x0 in bitstreamPaths() {
                let planned = x0.plan.requestedRate
                var others = clearlyDifferentRates(from: planned)
                if x0.source.sampleRate != planned { others.append(x0.source.sampleRate) }
                for other in others where other != planned {
                    var x = x0
                    x.readback.nominalRate = other
                    var b = subject.verdict(x)
                    checker.expect(!looksBitstream(b), "BPV-017",
                                   "\(planned) Hz planned, device reads back \(other) Hz: \(report(b, x))")

                    x = x0
                    x.plan.requestedRate = other
                    b = subject.verdict(x)
                    checker.expect(!looksBitstream(b), "BPV-017",
                                   "\(other) Hz planned, device reads back \(planned) Hz: \(report(b, x))")
                }
            }
        },

        // REQ: BPV-017
        Check("bitstream: the physical format must be integer with at least 16 bits", requirements: ["BPV-017"]) { subject, checker in
            for x0 in bitstreamPaths() {
                for (bits, integer) in [(32, false), (24, false), (16, false), (8, true), (12, true)] {
                    var x = x0
                    x.readback.physicalBitDepth = bits
                    x.readback.physicalIsInteger = integer
                    let b = subject.verdict(x)
                    checker.expect(!looksBitstream(b), "BPV-017",
                                   "\(bits)-bit \(integer ? "integer" : "float") physical format: \(report(b, x))")
                }
            }
        },
    ]
}

// MARK: - Badge predicates

/// Scalar-for-scalar equality. Swift's `==` also accepts canonically equivalent strings (U+0387 for U+00B7, say),
/// which the contract's exact strings don't allow.
private func isExactly(_ badge: String, _ expected: String) -> Bool {
    badge.unicodeScalars.elementsEqual(expected.unicodeScalars)
}

private func looksBitPerfect(_ badge: String) -> Bool {
    isExactly(badge, Badge.bitPerfect) || badge == Badge.bitPerfect
}

private func looksNativeDoP(_ badge: String) -> Bool {
    isExactly(badge, Badge.nativeDoP) || badge == Badge.nativeDoP
}

private func looksBitstream(_ badge: String) -> Bool {
    badge.unicodeScalars.starts(with: Badge.bitstreamPrefix.unicodeScalars) || badge.hasPrefix(Badge.bitstreamPrefix)
}

/// BIT-PERFECT, NATIVE DSD · DoP or a BITSTREAM · badge.
private func claimsUntouched(_ badge: String) -> Bool {
    looksBitPerfect(badge) || looksNativeDoP(badge) || looksBitstream(badge)
}

private func report(_ badge: String, _ x: VerdictInput) -> String {
    "got \(badge.debugDescription) for \(describe(x))"
}

private func describe(_ x: VerdictInput) -> String {
    func text<T>(_ value: T?) -> String { value.map { "\($0)" } ?? "nil" }
    let s = x.source, p = x.plan, r = x.readback, q = x.processing
    return "source(\(s.encoding) \(s.codec) \(s.sampleRate) Hz \(text(s.bitDepth))-bit \(s.channels)ch) "
        + "plan(\(p.mode) \(p.requestedRate) Hz \(p.requestedBitDepth)-bit \(p.channels)ch resampling=\(p.resampling) "
        + "dsdToPCM=\(p.dsdConvertedToPCM) spatial=\(p.spatial) integerMode=\(p.integerMode)) "
        + "readback(\(text(r.nominalRate)) Hz \(text(r.physicalBitDepth))-bit integer=\(text(r.physicalIsInteger)) "
        + "\(r.deviceChannels)ch hog=\(text(r.hogOwnerPID)) own=\(r.ownPID)) device=\(x.deviceClass) "
        + "processing(volume=\(q.volume) replayGain=\(text(q.replayGainDB)) eq=\(q.equalizerActive) "
        + "others=\(q.otherAppsPlaying) concealed=\(q.concealedFrames))"
}

// MARK: - Deterministic pseudo-random data

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< n (0 when n ≤ 0).
    mutating func below(_ n: Int) -> Int { n > 0 ? Int(next() % UInt64(n)) : 0 }

    mutating func chance(_ k: Int, in n: Int) -> Bool { below(n) < k }

    mutating func pick<T>(_ values: [T]) -> T? { values.isEmpty ? nil : values[below(values.count)] }
}

// MARK: - Scenario data

private let defaultPID: Int32 = 4_242

private let pcmRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000]

/// DSD64, DSD64 (48 kHz family), DSD128, DSD128 (48 kHz family), DSD256.
private let dsdRates: [Double] = [2_822_400, 3_072_000, 5_644_800, 6_144_000, 11_289_600]

private let allowedVolumes: [Volume] = [.hardware, .fixed, .digital(dB: 0)]

private let nonZeroGains: [Double] = [-0.0001, 0.0001, -0.001, 0.001, -0.1, 0.5, -1, 1, -3, 3, -6, 6, -20, 12, -60]

private func untouchedProcessing() -> VerdictInput.Processing {
    .init(volume: .hardware, replayGainDB: nil, equalizerActive: false, otherAppsPlaying: false, concealedFrames: 0)
}

/// Rates that clearly differ from `rate`: double, half, the other rate family, and offsets of 100 Hz and 1 kHz.
private func clearlyDifferentRates(from rate: Double) -> [Double] {
    let sibling = rate.truncatingRemainder(dividingBy: 11_025) == 0 ? rate / 44_100 * 48_000 : rate / 48_000 * 44_100
    return [rate * 2, rate / 2, sibling, rate + 100, rate - 100, rate + 1_000].filter { abs($0 - rate) >= 100 }
}

/// The scenario with the nominal rate, the physical bit depth or the integer flag unread, alone and together.
private func unreadVariants(of x: VerdictInput) -> [VerdictInput] {
    var rate = x
    rate.readback.nominalRate = nil
    var depth = x
    depth.readback.physicalBitDepth = nil
    var integer = x
    integer.readback.physicalIsInteger = nil
    var format = depth
    format.readback.physicalIsInteger = nil
    var everything = format
    everything.readback.nominalRate = nil
    return [rate, depth, integer, format, everything]
}

/// The scenario with `hog` read back as the hog owner. Integer mode is only ever on while the player holds the
/// device (contract, BPV-018), so it is switched off whenever `hog` isn't the player's own PID.
private func withHogOwner(_ x: VerdictInput, _ hog: Int32?) -> VerdictInput {
    var y = x
    y.readback.hogOwnerPID = hog
    if hog != y.readback.ownPID {
        y.plan.integerMode = false
    }
    return y
}

/// Hog owners that aren't the player: unread, nobody, and other processes.
private func foreignHogOwners(own: Int32) -> [Int32?] {
    let candidates: [Int32?] = [nil, -1, own &+ 1, own &- 1, 0, 1, 99_999, Int32.max]
    return candidates.filter { $0 != own }
}

/// A PCM path held exclusively by the player, with the read-back format equal to the plan.
private func pcmPath(rate: Double, bits: Int, channels: Int = 2, physicalBits: Int, physicalInteger: Bool = true,
                     integerMode: Bool = false, deviceChannels: Int? = nil, device: Device = .usbDAC,
                     codec: String = "FLAC", ownPID: Int32 = defaultPID, othersPlaying: Bool = false,
                     volume: Volume = .hardware, replayGain: Double? = nil) -> VerdictInput {
    VerdictInput(
        source: .init(encoding: .pcm, codec: codec, sampleRate: rate, bitDepth: bits, channels: channels),
        plan: .init(mode: .pcm, requestedRate: rate, requestedBitDepth: physicalBits, channels: channels,
                    resampling: false, dsdConvertedToPCM: false, spatial: .off, integerMode: integerMode),
        readback: .init(nominalRate: rate, physicalBitDepth: physicalBits, physicalIsInteger: physicalInteger,
                        deviceChannels: deviceChannels ?? channels, hogOwnerPID: ownPID, ownPID: ownPID),
        deviceClass: device,
        processing: .init(volume: volume, replayGainDB: replayGain, equalizerActive: false,
                          otherAppsPlaying: othersPlaying, concealedFrames: 0))
}

/// A DoP path held exclusively by the player, carrier = DSD rate / 16, read-back integer format.
private func dopPath(dsdRate: Double, channels: Int = 2, physicalBits: Int = 24, deviceChannels: Int? = nil,
                     codec: String = "DSF", ownPID: Int32 = defaultPID, othersPlaying: Bool = false,
                     volume: Volume = .hardware, replayGain: Double? = nil) -> VerdictInput {
    let carrier = dsdRate / 16
    return VerdictInput(
        source: .init(encoding: .dsd, codec: codec, sampleRate: dsdRate, bitDepth: nil, channels: channels),
        plan: .init(mode: .dop, requestedRate: carrier, requestedBitDepth: physicalBits, channels: channels,
                    resampling: false, dsdConvertedToPCM: false, spatial: .off, integerMode: false),
        readback: .init(nominalRate: carrier, physicalBitDepth: physicalBits, physicalIsInteger: true,
                        deviceChannels: deviceChannels ?? channels, hogOwnerPID: ownPID, ownPID: ownPID),
        deviceClass: .usbDAC,
        processing: .init(volume: volume, replayGainDB: replayGain, equalizerActive: false,
                          otherAppsPlaying: othersPlaying, concealedFrames: 0))
}

/// A bitstream path held exclusively by the player that meets every condition BPV-017 names.
private func bitstreamPath(codec: String, encoding: VerdictInput.Encoding = .lossy, sourceRate: Double,
                           plannedRate: Double, channels: Int, physicalBits: Int = 16, deviceChannels: Int? = nil,
                           device: Device = .other, ownPID: Int32 = defaultPID, othersPlaying: Bool = false,
                           volume: Volume = .hardware, replayGain: Double? = nil) -> VerdictInput {
    VerdictInput(
        source: .init(encoding: encoding, codec: codec, sampleRate: sourceRate, bitDepth: nil, channels: channels),
        plan: .init(mode: .bitstream, requestedRate: plannedRate, requestedBitDepth: physicalBits, channels: channels,
                    resampling: false, dsdConvertedToPCM: false, spatial: .off, integerMode: false),
        readback: .init(nominalRate: plannedRate, physicalBitDepth: physicalBits, physicalIsInteger: true,
                        deviceChannels: deviceChannels ?? channels, hogOwnerPID: ownPID, ownPID: ownPID),
        deviceClass: device,
        processing: .init(volume: volume, replayGainDB: replayGain, equalizerActive: false,
                          otherAppsPlaying: othersPlaying, concealedFrames: 0))
}

/// Lossless PCM on a USB DAC, at its own rate, meeting every condition of BPV-001…011.
private func cleanPCMPaths() -> [VerdictInput] {
    var paths: [VerdictInput] = [
        pcmPath(rate: 44_100, bits: 16, physicalBits: 24),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 16),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 32),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 32, physicalInteger: false),
        pcmPath(rate: 48_000, bits: 24, physicalBits: 24),
        pcmPath(rate: 48_000, bits: 24, physicalBits: 32, physicalInteger: false),
        pcmPath(rate: 88_200, bits: 24, physicalBits: 32),
        pcmPath(rate: 96_000, bits: 24, physicalBits: 24, codec: "ALAC"),
        pcmPath(rate: 96_000, bits: 20, physicalBits: 24),
        pcmPath(rate: 176_400, bits: 24, physicalBits: 32, codec: "WAV"),
        pcmPath(rate: 192_000, bits: 24, physicalBits: 24, codec: "AIFF"),
        pcmPath(rate: 352_800, bits: 24, physicalBits: 32),
        pcmPath(rate: 384_000, bits: 32, physicalBits: 32, integerMode: true),
        pcmPath(rate: 705_600, bits: 32, physicalBits: 32, integerMode: true),
        pcmPath(rate: 768_000, bits: 32, physicalBits: 32, integerMode: true, codec: "WAV"),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 32, integerMode: true),
        pcmPath(rate: 96_000, bits: 24, physicalBits: 32, integerMode: true),
        pcmPath(rate: 44_100, bits: 16, channels: 1, physicalBits: 24, deviceChannels: 2),
        pcmPath(rate: 48_000, bits: 24, channels: 6, physicalBits: 24, deviceChannels: 8),
        pcmPath(rate: 96_000, bits: 24, channels: 8, physicalBits: 32),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 24, deviceChannels: 4),
        pcmPath(rate: 48_000, bits: 24, physicalBits: 24, othersPlaying: true),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 24, volume: .fixed),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 24, volume: .digital(dB: 0)),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 24, replayGain: 0),
        pcmPath(rate: 96_000, bits: 24, physicalBits: 24, volume: .digital(dB: 0), replayGain: 0),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 24, ownPID: 1),
        pcmPath(rate: 44_100, bits: 16, physicalBits: 24, ownPID: 99_998),
    ]
    var g = SplitMix64(seed: 0xB1_7FEC_7001)
    for _ in 0..<150 {
        paths.append(randomCleanPCM(&g))
    }
    return paths
}

private func randomCleanPCM(_ g: inout SplitMix64) -> VerdictInput {
    let rate = g.pick(pcmRates) ?? 44_100
    let bits = g.pick([16, 16, 20, 24, 24, 32]) ?? 16
    var physicalBits = 32
    var physicalInteger = true
    var integerMode = false
    if bits > 24 {
        integerMode = true
    } else if g.chance(1, in: 4) {
        integerMode = true
    } else if g.chance(1, in: 4) {
        physicalInteger = false
    } else {
        physicalBits = g.pick([16, 20, 24, 32].filter { $0 >= bits }) ?? 32
    }
    let channels = g.pick([1, 2, 2, 2, 4, 6, 8]) ?? 2
    return pcmPath(rate: rate, bits: bits, channels: channels, physicalBits: physicalBits,
                   physicalInteger: physicalInteger, integerMode: integerMode,
                   deviceChannels: channels + g.below(3), codec: g.pick(["FLAC", "ALAC", "WAV", "AIFF"]) ?? "FLAC",
                   ownPID: Int32(100 + g.below(90_000)), othersPlaying: g.chance(1, in: 3),
                   volume: g.pick(allowedVolumes) ?? .hardware, replayGain: g.chance(1, in: 3) ? 0 : nil)
}

/// AirPods Max on USB-C with a 48 kHz file, read back as 24-bit integer at 48 kHz, every other condition met.
private func airPodsMaxUSBCPaths() -> [VerdictInput] {
    var paths: [VerdictInput] = []
    let codecs = ["FLAC", "ALAC", "WAV"]
    var n = 0
    for bits in [16, 24] {
        for volume in allowedVolumes {
            for replayGain in [nil, 0.0] as [Double?] {
                for othersPlaying in [false, true] {
                    n += 1
                    paths.append(pcmPath(rate: 48_000, bits: bits, physicalBits: 24, device: .airPodsMaxUSBC,
                                         codec: codecs[n % codecs.count], ownPID: Int32(300 + 17 * n),
                                         othersPlaying: othersPlaying, volume: volume, replayGain: replayGain))
                }
            }
        }
    }
    return paths
}

/// Every PCM path the records say is BIT-PERFECT.
private func pcmBases() -> [VerdictInput] { cleanPCMPaths() + airPodsMaxUSBCPaths() }

/// DSD sent as DoP to a USB DAC, meeting every condition of BPV-016.
private func cleanDoPPaths() -> [VerdictInput] {
    var paths: [VerdictInput] = []
    for rate in dsdRates {
        for physical in [24, 32] {
            paths.append(dopPath(dsdRate: rate, physicalBits: physical))
        }
    }
    paths += [
        dopPath(dsdRate: 2_822_400, codec: "DSDIFF"),
        dopPath(dsdRate: 2_822_400, channels: 6, deviceChannels: 8),
        dopPath(dsdRate: 5_644_800, channels: 5, physicalBits: 32),
        dopPath(dsdRate: 2_822_400, deviceChannels: 4),
        dopPath(dsdRate: 2_822_400, othersPlaying: true),
        dopPath(dsdRate: 5_644_800, volume: .fixed),
        dopPath(dsdRate: 2_822_400, volume: .digital(dB: 0)),
        dopPath(dsdRate: 11_289_600, replayGain: 0),
    ]
    var g = SplitMix64(seed: 0xD0_9D0_9D0)
    for _ in 0..<40 {
        let channels = g.pick([1, 2, 2, 2, 5, 6]) ?? 2
        paths.append(dopPath(dsdRate: g.pick(dsdRates) ?? 2_822_400, channels: channels,
                             physicalBits: g.pick([24, 24, 32]) ?? 24, deviceChannels: channels + g.below(3),
                             codec: g.pick(["DSF", "DSDIFF"]) ?? "DSF", ownPID: Int32(100 + g.below(90_000)),
                             othersPlaying: g.chance(1, in: 3), volume: g.pick(allowedVolumes) ?? .hardware,
                             replayGain: g.chance(1, in: 3) ? 0 : nil))
    }
    return paths
}

/// Bitstream paths that meet every condition BPV-017 names, held exclusively (the records don't say which
/// badge these get; they are only starting points for changes that rule BITSTREAM out).
private func bitstreamPaths() -> [VerdictInput] {
    var paths: [VerdictInput] = [
        bitstreamPath(codec: "AC3", sourceRate: 48_000, plannedRate: 48_000, channels: 6),
        bitstreamPath(codec: "AC3", sourceRate: 48_000, plannedRate: 48_000, channels: 2, device: .usbDAC),
        bitstreamPath(codec: "AC3", sourceRate: 44_100, plannedRate: 44_100, channels: 6, physicalBits: 24),
        bitstreamPath(codec: "DTS", sourceRate: 48_000, plannedRate: 48_000, channels: 6, deviceChannels: 8),
        bitstreamPath(codec: "DTS", encoding: .pcm, sourceRate: 44_100, plannedRate: 44_100, channels: 6,
                      device: .builtInHeadphones),
        bitstreamPath(codec: "E-AC3", sourceRate: 48_000, plannedRate: 192_000, channels: 8, physicalBits: 32),
        bitstreamPath(codec: "AC3", sourceRate: 48_000, plannedRate: 48_000, channels: 6, othersPlaying: true),
        bitstreamPath(codec: "DTS", sourceRate: 48_000, plannedRate: 48_000, channels: 6, volume: .fixed),
        bitstreamPath(codec: "AC3", sourceRate: 48_000, plannedRate: 48_000, channels: 6,
                      volume: .digital(dB: 0), replayGain: 0),
    ]
    let formats: [(codec: String, sourceRate: Double, plannedRate: Double, channels: Int)] = [
        ("AC3", 48_000, 48_000, 6), ("AC3", 48_000, 48_000, 2), ("DTS", 48_000, 48_000, 6),
        ("DTS", 44_100, 44_100, 6), ("E-AC3", 48_000, 192_000, 8),
    ]
    var g = SplitMix64(seed: 0xB175_7EA4)
    for _ in 0..<30 {
        guard let f = g.pick(formats) else { break }
        paths.append(bitstreamPath(codec: f.codec, sourceRate: f.sourceRate, plannedRate: f.plannedRate,
                                   channels: f.channels, physicalBits: g.pick([16, 24, 32]) ?? 16,
                                   deviceChannels: f.channels + g.below(3),
                                   device: g.pick([Device.other, .usbDAC, .builtInHeadphones]) ?? .other,
                                   ownPID: Int32(100 + g.below(90_000)), othersPlaying: g.chance(1, in: 3),
                                   volume: g.pick(allowedVolumes) ?? .hardware,
                                   replayGain: g.chance(1, in: 3) ? 0 : nil))
    }
    return paths
}

/// Starting points in every mode.
private func everyModeBases() -> [VerdictInput] { pcmBases() + cleanDoPPaths() + bitstreamPaths() }
