//
// Vespertine verification: contracts/bit-perfect-verdict.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// What a music player knows about one playing track.
public struct VerdictInput: Sendable, Hashable {
    public enum Encoding: Sendable, Hashable { case pcm, lossy, dsd }
    public enum Mode: Sendable, Hashable { case pcm, dop, bitstream }
    public enum Spatial: Sendable, Hashable { case off, fixed, headTracked }
    public enum DeviceClass: Sendable, Hashable, CaseIterable {
        case usbDAC, builtInHeadphones, builtInSpeakers, bluetooth, airPlay, virtual, aggregate
        case airPodsMaxUSBC, airPodsMaxBluetooth, other
    }
    public enum Volume: Sendable, Hashable {
        case hardware
        case fixed
        case digital(dB: Double)
    }

    /// The file being played.
    public struct Source: Sendable, Hashable {
        /// `pcm` is lossless PCM (FLAC, ALAC, WAV, …); `lossy` is MP3, AAC, …; `dsd` is DSF or DSDIFF.
        public var encoding: Encoding
        /// e.g. "FLAC", "AC3", "DTS".
        public var codec: String
        /// Hz; for DSD the 1-bit rate.
        public var sampleRate: Double
        /// Bits per sample for integer PCM; nil when the file doesn't have one (lossy, float, DSD).
        public var bitDepth: Int?
        public var channels: Int

        public init(encoding: Encoding, codec: String, sampleRate: Double, bitDepth: Int?, channels: Int) {
            self.encoding = encoding
            self.codec = codec
            self.sampleRate = sampleRate
            self.bitDepth = bitDepth
            self.channels = channels
        }
    }

    /// What the player set out to do.
    public struct Plan: Sendable, Hashable {
        /// `dop`: DSD sent as DoP; `bitstream`: Dolby/DTS frames sent for a receiver to decode.
        public var mode: Mode
        /// The device rate the player asked for (Hz).
        public var requestedRate: Double
        /// The physical bit depth the player asked for.
        public var requestedBitDepth: Int
        /// Channels the player sends to the device.
        public var channels: Int
        /// The player converts the sample rate.
        public var resampling: Bool
        /// DSD is converted to PCM.
        public var dsdConvertedToPCM: Bool
        public var spatial: Spatial
        /// The player sends 32-bit integers straight to the device, with no 32-bit float step. Only ever true while
        /// the player holds the device exclusively (`readback.hogOwnerPID == readback.ownPID`; BPV-018): inputs
        /// with `integerMode` true and the device not held don't occur.
        public var integerMode: Bool

        public init(mode: Mode, requestedRate: Double, requestedBitDepth: Int, channels: Int, resampling: Bool,
                    dsdConvertedToPCM: Bool, spatial: Spatial, integerMode: Bool) {
            self.mode = mode
            self.requestedRate = requestedRate
            self.requestedBitDepth = requestedBitDepth
            self.channels = channels
            self.resampling = resampling
            self.dsdConvertedToPCM = dsdConvertedToPCM
            self.spatial = spatial
            self.integerMode = integerMode
        }
    }

    /// What the operating system reported about the device after the player configured it. A field is nil when
    /// reading it failed.
    public struct Readback: Sendable, Hashable {
        /// The device's current nominal sample rate (Hz).
        public var nominalRate: Double?
        /// Bits per sample of the device's physical format.
        public var physicalBitDepth: Int?
        /// Whether that physical format is integer (false: floating point).
        public var physicalIsInteger: Bool?
        /// Channels the device's output streams carry.
        public var deviceChannels: Int
        /// The process that owns the device exclusively (hog mode), or −1 when no process does.
        public var hogOwnerPID: Int32?
        /// The player's own process ID.
        public var ownPID: Int32

        public init(nominalRate: Double?, physicalBitDepth: Int?, physicalIsInteger: Bool?, deviceChannels: Int,
                    hogOwnerPID: Int32?, ownPID: Int32) {
            self.nominalRate = nominalRate
            self.physicalBitDepth = physicalBitDepth
            self.physicalIsInteger = physicalIsInteger
            self.deviceChannels = deviceChannels
            self.hogOwnerPID = hogOwnerPID
            self.ownPID = ownPID
        }
    }

    /// What else touches the samples.
    public struct Processing: Sendable, Hashable {
        /// Where volume is controlled; `digital` is the player's software volume.
        public var volume: Volume
        /// ReplayGain applied, nil when off.
        public var replayGainDB: Double?
        /// An equalizer preset that changes samples is applied.
        public var equalizerActive: Bool
        /// Another process is currently playing to the same device.
        public var otherAppsPlaying: Bool
        /// Frames of this track the decoder replaced with silence because the file is damaged there.
        public var concealedFrames: Int

        public init(volume: Volume, replayGainDB: Double?, equalizerActive: Bool, otherAppsPlaying: Bool, concealedFrames: Int) {
            self.volume = volume
            self.replayGainDB = replayGainDB
            self.equalizerActive = equalizerActive
            self.otherAppsPlaying = otherAppsPlaying
            self.concealedFrames = concealedFrames
        }
    }

    public var source: Source
    public var plan: Plan
    public var readback: Readback
    /// The class of output device: `builtInHeadphones` is the headphone jack, `builtInSpeakers` the computer's own
    /// speakers, `airPodsMaxUSBC` AirPods Max with the USB-C cable connected, `other` HDMI, DisplayPort, ….
    public var deviceClass: DeviceClass
    public var processing: Processing

    public init(source: Source, plan: Plan, readback: Readback, deviceClass: DeviceClass, processing: Processing) {
        self.source = source
        self.plan = plan
        self.readback = readback
        self.deviceClass = deviceClass
        self.processing = processing
    }
}

/// The strings the records name. Any other string is a reason the path isn't bit-perfect.
public enum Badge {
    public static let bitPerfect = "BIT-PERFECT"
    /// The middle character is U+00B7 MIDDLE DOT, with a space on each side.
    public static let nativeDoP = "NATIVE DSD \u{00B7} DoP"
    /// Bitstream badges start with this.
    public static let bitstreamPrefix = "BITSTREAM \u{00B7} "
    public static let equalizer = "EQUALIZER"
    public static let damagedFrames = "DAMAGED FRAMES SILENCED"
}

public protocol BadgeVerdict: Sendable {
    /// The one-line badge for one playing track.
    func verdict(_ input: VerdictInput) -> String
}
