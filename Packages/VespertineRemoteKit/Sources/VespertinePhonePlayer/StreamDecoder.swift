//
// Vespertine: decodes a song from a `ByteSource` with Apple's own decoders (FLAC, ALAC, AAC, WAV, AIFF, CAF, MP3), reading the
// bytes through callbacks, so a stream decodes while it is still arriving and a seek reads only the part it lands in.
// The phone has no decoders of its own: what Core Audio can't open, the Mac converts first.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AudioToolbox) && canImport(AVFAudio)
import AVFAudio
import AudioToolbox
import Foundation
import VespertineRemoteProtocol

/// What the C callbacks get: the source, and the error a read ended with (Core Audio only carries a status code).
private final class SourceBox: @unchecked Sendable {
    let source: any ByteSource
    private let lock = NSLock()
    private var _error: Error?
    init(_ source: any ByteSource) { self.source = source }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
}

private let readBytes: AudioFile_ReadProc = { client, position, count, buffer, actual in
    let box = Unmanaged<SourceBox>.fromOpaque(client).takeUnretainedValue()
    do {
        let data = try box.source.read(at: position, length: Int(count))
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress, !bytes.isEmpty { buffer.copyMemory(from: base, byteCount: bytes.count) }
        }
        actual.pointee = UInt32(data.count)
        return noErr
    } catch {
        box.error = error
        actual.pointee = 0
        return kAudioFileUnspecifiedError
    }
}

private let sizeOfBytes: AudioFile_GetSizeProc = { client in
    Unmanaged<SourceBox>.fromOpaque(client).takeUnretainedValue().source.byteSize
}

public final class StreamDecoder: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case cannotOpen(String)
        case cannotRead(String)
    }

    public let source: any ByteSource
    /// What `read` fills: 32-bit float, one buffer per channel, at the file's own rate and channel count.
    public let processingFormat: AVAudioFormat
    /// The file's own format, as Core Audio reports it.
    public let fileFormat: AudioStreamBasicDescription
    /// Sample frames in the song.
    public let length: Int64
    /// The next frame `read` returns.
    public private(set) var position: Int64 = 0

    private let box: SourceBox
    private let audioFile: AudioFileID
    private let extFile: ExtAudioFileRef

    /// Opens the song. Blocks while the first bytes arrive (and, for a file whose index is at its end, those too).
    public init(source: any ByteSource, format: StreamFormat) throws {
        let box = SourceBox(source)
        var file: AudioFileID?
        let opened = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(box).toOpaque(), readBytes, nil, sizeOfBytes, nil,
                                                Self.typeHint(format.container), &file)
        guard opened == noErr, let file else { throw box.error ?? Failure.cannotOpen(Self.words(opened)) }
        var ext: ExtAudioFileRef?
        let wrapped = ExtAudioFileWrapAudioFileID(file, false, &ext)
        guard wrapped == noErr, let ext else {
            AudioFileClose(file)
            throw box.error ?? Failure.cannotOpen(Self.words(wrapped))
        }
        func fail(_ status: OSStatus) -> Error {
            ExtAudioFileDispose(ext)
            AudioFileClose(file)
            return box.error ?? Failure.cannotOpen(Self.words(status))
        }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &size, &description)
        guard status == noErr, description.mSampleRate > 0, description.mChannelsPerFrame > 0 else { throw fail(status) }
        let channels = Int(description.mChannelsPerFrame)
        let labels = format.channels == channels ? format.channelLabels : nil
        guard let processing = Self.processingFormat(sampleRate: description.mSampleRate, channels: channels, labels: labels) else {
            throw fail(kAudioFileUnsupportedDataFormatError)
        }
        var client = processing.streamDescription.pointee
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { throw fail(status) }
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        status = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
        guard status == noErr, frames > 0 else { throw fail(status == noErr ? kAudioFileInvalidFileError : status) }
        self.source = source
        self.box = box
        audioFile = file
        extFile = ext
        fileFormat = description
        processingFormat = processing
        length = frames
    }

    deinit {
        ExtAudioFileDispose(extFile)
        AudioFileClose(audioFile)
    }

    /// Fills `buffer` (made with `processingFormat`) and returns the frames read: zero at the end of the song.
    public func read(into buffer: AVAudioPCMBuffer) throws -> Int {
        var frames = buffer.frameCapacity
        buffer.frameLength = frames
        box.error = nil
        let status = ExtAudioFileRead(extFile, &frames, buffer.mutableAudioBufferList)
        guard status == noErr else {
            buffer.frameLength = 0
            throw box.error ?? Failure.cannotRead(Self.words(status))
        }
        buffer.frameLength = frames
        position += Int64(frames)
        return Int(frames)
    }

    /// Moves to `frame`; the bytes there are fetched when the next `read` asks for them.
    public func seek(to frame: Int64) throws {
        let target = max(0, min(frame, length))
        box.error = nil
        let status = ExtAudioFileSeek(extFile, target)
        guard status == noErr else { throw box.error ?? Failure.cannotRead(Self.words(status)) }
        position = target
    }

    // MARK: Formats

    static func typeHint(_ container: String) -> AudioFileTypeID {
        switch container.lowercased() {
        case "flac": kAudioFileFLACType
        case "m4a", "mp4", "m4b": kAudioFileM4AType
        case "wav", "wave": kAudioFileWAVEType
        case "aiff", "aif": kAudioFileAIFFType
        case "aifc": kAudioFileAIFCType
        case "caf": kAudioFileCAFType
        case "mp3": kAudioFileMP3Type
        default: 0
        }
    }

    /// 32-bit float, deinterleaved. More than two channels need a layout: the speakers the Mac named, or, when it named none,
    /// the standard order for that many channels (the order FLAC and WAVE files use).
    public static func processingFormat(sampleRate: Double, channels: Int, labels: [UInt32]?) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)
        }
        guard let layout = channelLayout(channels: channels, labels: labels) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }

    public static func channelLayout(channels: Int, labels: [UInt32]?) -> AVAudioChannelLayout? {
        if let labels, labels.count == channels, channels > 0 {
            let size = MemoryLayout<AudioChannelLayout>.size + (channels - 1) * MemoryLayout<AudioChannelDescription>.stride
            let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
            let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
            layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            layout.pointee.mNumberChannelDescriptions = UInt32(channels)
            let descriptions = channelDescriptions(layout)
            for (i, label) in labels.enumerated() { descriptions[i].mChannelLabel = label }
            return AVAudioChannelLayout(layout: layout)
        }
        let tag: AudioChannelLayoutTag? = switch channels {
        case 1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        case 3: kAudioChannelLayoutTag_WAVE_3_0
        case 4: kAudioChannelLayoutTag_WAVE_4_0_A
        case 5: kAudioChannelLayoutTag_WAVE_5_0_A
        case 6: kAudioChannelLayoutTag_WAVE_5_1_A
        case 7: kAudioChannelLayoutTag_WAVE_6_1
        case 8: kAudioChannelLayoutTag_WAVE_7_1
        default: nil
        }
        return tag.flatMap { AVAudioChannelLayout(layoutTag: $0) }
    }

    private static func words(_ status: OSStatus) -> String {
        switch status {
        case kAudioFileUnsupportedFileTypeError, kAudioFileUnsupportedDataFormatError: "This kind of file can’t be played on this device."
        case kAudioFileInvalidFileError, kAudioFileStreamError_InvalidFile: "The file isn’t audio that can be read."
        default: "The audio couldn’t be read (\(status))."
        }
    }
}

/// The channel descriptions that follow an `AudioChannelLayout`'s header.
private func channelDescriptions(_ layout: UnsafeMutablePointer<AudioChannelLayout>) -> UnsafeMutableBufferPointer<AudioChannelDescription> {
    let count = Int(layout.pointee.mNumberChannelDescriptions)
    return withUnsafeMutablePointer(to: &layout.pointee.mChannelDescriptions) { first in
        UnsafeMutableBufferPointer(start: first, count: count)
    }
}
#endif
