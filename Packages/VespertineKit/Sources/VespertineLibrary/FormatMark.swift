//
// Vespertine — the name a format is known by, for badges: "DOLBY ATMOS", "DTS-HD MASTER AUDIO", "DSD256".
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

/// A format's name for badges. Vespertine never draws Dolby's or DTS's logos or lettering (trademarks licensed
/// only with certified products); it names the format of the file, as any player's format column does.
public struct FormatMark: Sendable, Hashable {
    public enum Family: Sendable, Hashable { case dolby, dts, dsd, hiRes, lossless, notDecoded }

    public var family: Family
    /// The bold half: "DOLBY", "DTS-HD", "DSD", "HI-RES".
    public var brand: String
    /// The light half: "ATMOS", "MASTER AUDIO", "256", "LOSSLESS". Empty for one-word marks.
    public var product: String
    /// What carries it, when that matters: Atmos in TrueHD (lossless) or in Dolby Digital Plus.
    public var carrier: String?

    public init(family: Family, brand: String, product: String, carrier: String? = nil) {
        self.family = family; self.brand = brand; self.product = product; self.carrier = carrier
    }

    public var text: String { product.isEmpty ? brand : "\(brand) \(product)" }

    public static func of(codec: String, lossless: Bool, dsd: Bool, sampleRate: Double, bitDepth: Int?) -> FormatMark? {
        switch codec {
        case "Dolby Atmos (TrueHD)": return .init(family: .dolby, brand: "DOLBY", product: "ATMOS", carrier: "TrueHD bed · lossless")
        case "Dolby Atmos": return .init(family: .dolby, brand: "DOLBY", product: "ATMOS", carrier: "Digital Plus")
        case "Dolby TrueHD": return .init(family: .dolby, brand: "DOLBY", product: "TRUEHD")
        case "Dolby Digital Plus": return .init(family: .dolby, brand: "DOLBY", product: "DIGITAL PLUS")
        case "Dolby Digital": return .init(family: .dolby, brand: "DOLBY", product: "DIGITAL")
        case "MLP Lossless": return .init(family: .lossless, brand: "MLP", product: "LOSSLESS")
        case "DTS:X": return .init(family: .dts, brand: "DTS:X", product: "", carrier: "DTS-HD bed")
        case "DTS-HD Master Audio": return .init(family: .dts, brand: "DTS-HD", product: "MASTER AUDIO")
        case "DTS-HD High Resolution": return .init(family: .dts, brand: "DTS-HD", product: "HIGH RESOLUTION")
        case "DTS Express": return .init(family: .dts, brand: "DTS", product: "EXPRESS")
        case "DTS": return .init(family: .dts, brand: "DTS", product: "DIGITAL SURROUND")
        default: break
        }
        if dsd { return .init(family: .dsd, brand: "DSD", product: String(Int((sampleRate / 44_100).rounded())), carrier: nil) }
        guard lossless else { return nil }
        if (bitDepth ?? 16) > 16 || sampleRate > 48_000 { return .init(family: .hiRes, brand: "HI-RES", product: "LOSSLESS") }
        return .init(family: .lossless, brand: "LOSSLESS", product: "")
    }
}

public extension Track {
    /// A format this track carries that Vespertine doesn't decode: AC-4 and MPEG-H files (which don't play), MQA (by the
    /// file's own tags) and Auro-3D (by the release's name), which play as the PCM they hold.
    var undecodedFormat: UndecodedFormat? {
        if let named = UndecodedFormat.allCases.first(where: { !$0.playsAsPCM && $0.name == codec }) { return named }
        guard isLossless, !isDSD else { return nil }
        if codec == "FLAC", UndecodedFormat.isMQA(tags: extraTags) { return .mqa }
        let words = [(filePath as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? "",
                     (filePath as NSString).lastPathComponent] + Array(extraTags.values)
        return UndecodedFormat.isAuro3DByName(words, channels: channels) ? .auro3D : nil
    }

    var formatMark: FormatMark? {
        // What it is named after: not decoded, so not "Hi-Res" or a lossless badge for what it isn't.
        if let format = undecodedFormat { return .init(family: .notDecoded, brand: format.name.uppercased(), product: "", carrier: format.note) }
        // DSF and DSDIFF side by side are still one DSD album.
        guard codec != Album.mixedCodec || isDSD else { return nil }
        return FormatMark.of(codec: codec, lossless: isLossless, dsd: isDSD, sampleRate: sampleRate, bitDepth: bitDepth)
    }
}

public extension Album {
    static let mixedCodec = "Mixed"

    /// Lossy albums show a bitrate in their summary ("MP3 · 320k"); lossless ones never do.
    var formatMark: FormatMark? {
        // DSF and DSDIFF side by side are still one DSD album.
        guard codec != Album.mixedCodec || isDSD else { return nil }
        return FormatMark.of(codec: codec, lossless: isHiRes || !formatSummary.contains("k ·") && !formatSummary.hasSuffix("k"),
                      dsd: isDSD, sampleRate: maxSampleRate, bitDepth: maxBitDepth)
    }
}
