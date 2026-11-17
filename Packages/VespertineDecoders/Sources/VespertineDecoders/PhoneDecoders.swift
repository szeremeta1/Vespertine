//
// Vespertine: the decoders the iPhone and iPad app brings for a share's APE, WavPack, Ogg Vorbis and Opus files.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import CVespertineDecoders
import Foundation
import VespertineShare

/// Decoding stopped: the file is damaged past where it could be opened.
public struct DecodingFailed: Error, Equatable {
    public init() {}
}

public struct PhoneDecoders: ShareDecoders {
    public init() {}

    public let extensions: Set<String> = ["ape", "wv", "ogg", "oga", "opus"]

    public func open(type: String, size: Int64, read: @escaping (Int64, Int) throws -> Data) throws -> DecoderOpening {
        let source = FileSource(size: size, read: read)
        let kind: Int32
        let codec: String
        switch type {
        case "ape": (kind, codec) = (Int32(VSP_APE), "APE")
        case "wv": (kind, codec) = (Int32(VSP_WAVPACK), "WavPack")
        case "opus": (kind, codec) = (Int32(VSP_OPUS), "Opus")
        case "ogg", "oga":
            // An Ogg file says what it holds in its first page.
            let head = source.bytes(0, 128)
            if let error = source.takeError() { throw error }
            guard head.starts(with: Array("OggS".utf8)) else { return .unreadable }
            if contains(head, Array("OpusHead".utf8)) { (kind, codec) = (Int32(VSP_OPUS), "Opus") }
            else if contains(head, [1] + Array("vorbis".utf8)) { (kind, codec) = (Int32(VSP_VORBIS), "Vorbis") }
            else { return .needsTheMac }    // FLAC or Speex in Ogg
        default: return .unreadable
        }
        var handle: OpaquePointer?
        let result = vsp_open(kind, source.cSource, &handle)
        if let error = source.takeError() {
            if let handle { vsp_close(handle) }
            throw error
        }
        switch result {
        case Int32(VSP_OPENED):
            guard let handle else { return .unreadable }
            return .opened(LibraryDecoder(handle: handle, source: source, codec: codec))
        case Int32(VSP_NEEDS_THE_MAC): return .needsTheMac
        default: return .unreadable
        }
    }

    private func contains(_ bytes: [UInt8], _ pattern: [UInt8]) -> Bool {
        guard bytes.count >= pattern.count else { return false }
        return (0...(bytes.count - pattern.count)).contains { bytes[$0..<($0 + pattern.count)].elementsEqual(pattern) }
    }
}

/// The file as the libraries read it: ranges of it, a good piece at a time (a share is on the far side of a network, and
/// the libraries ask for a little at once).
final class FileSource {
    let size: Int64
    private let read: (Int64, Int) throws -> Data
    private var start: Int64 = 0
    private var held = Data()
    private var error: Error?
    /// How much is read at once.
    static let stride = 256 << 10

    init(size: Int64, read: @escaping (Int64, Int) throws -> Data) {
        self.size = size
        self.read = read
    }

    /// The error the last reads ended with, once.
    func takeError() -> Error? {
        defer { error = nil }
        return error
    }

    /// Copies up to `count` bytes at `offset` into `buffer`. Returns the bytes copied, or -1 when the file couldn't be read.
    func copy(_ offset: Int64, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        guard offset >= 0, offset < size, count > 0 else { return 0 }
        let count = Int(min(Int64(count), size - offset))
        if offset < start || offset >= start + Int64(held.count) {
            do {
                held = try read(offset, Int(min(Int64(max(count, Self.stride)), size - offset)))
                start = offset
            } catch {
                self.error = error
                held = Data()
                return -1
            }
        }
        let from = Int(offset - start)
        let available = min(count, held.count - from)
        guard available > 0 else { return 0 }
        held.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + from, byteCount: available) }
        return available
    }

    func bytes(_ offset: Int64, _ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        let got = out.withUnsafeMutableBytes { copy(offset, $0.baseAddress!, count) }
        return Array(out.prefix(max(0, got)))
    }

    /// The file for the C side. The source has to outlive the decoder that reads it.
    var cSource: vsp_source {
        vsp_source(context: Unmanaged.passUnretained(self).toOpaque(), size: size) { context, offset, buffer, count in
            guard let context, let buffer else { return -1 }
            return Int64(Unmanaged<FileSource>.fromOpaque(context).takeUnretainedValue().copy(offset, buffer, Int(min(count, Int64(Int32.max)))))
        }
    }
}

final class LibraryDecoder: ShareDecoder {
    let info: DecodedInfo
    private let handle: OpaquePointer
    private let source: FileSource
    private let frameBytes: Int

    init(handle: OpaquePointer, source: FileSource, codec: String) {
        self.handle = handle
        self.source = source
        let found = vsp_get_info(handle)
        var text: [String: String] = [:]
        for index in 0..<vsp_tag_count(handle) {
            let name = String(cString: vsp_tag_name(handle, index)).lowercased()
            // The first of a name is the one kept (a file can name several artists).
            if text[name] == nil { text[name] = String(cString: vsp_tag_text(handle, index)) }
        }
        info = DecodedInfo(codec: codec, sampleRate: found.sample_rate, channels: Int(found.channels), bitDepth: found.bit_depth > 0 ? Int(found.bit_depth) : nil,
                           sampleBytes: Int(found.sample_bytes), frames: found.frames, text: text)
        frameBytes = Int(found.channels) * (found.sample_bytes == 0 ? 4 : Int(found.sample_bytes))
    }

    deinit { vsp_close(handle) }

    func read(frame: Int64, count: Int) throws -> Data {
        guard count > 0, frame >= 0, frame < info.frames else { return Data() }
        let count = Int(min(Int64(count), info.frames - frame))
        var out = Data(count: count * frameBytes)
        let got = out.withUnsafeMutableBytes { vsp_read(handle, frame, Int64(count), $0.bindMemory(to: UInt8.self).baseAddress) }
        if let error = source.takeError() { throw error }
        guard got >= 0 else { throw DecodingFailed() }
        out.count = Int(got) * frameBytes
        return out
    }
}
