//
// Vespertine: decodes a song from a `ByteSource` with Apple's own decoders (FLAC, ALAC, AAC, WAV, AIFF, CAF, MP3), reading the
// bytes through callbacks, so a stream decodes while it is still arriving and a seek reads only the part it lands in.
// The phone has no decoders of its own: what Core Audio can't open, the Mac converts first. Surround (more than two channels)
// comes out on the bed Apple's spatial mixer takes, each channel on the speaker of its own place.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AudioToolbox) && canImport(AVFAudio)
import AVFAudio
import AudioToolbox
import Foundation
import VespertineChannels
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
    /// What `read` fills: 32-bit float, one buffer per channel, at the file's own rate. Stereo and mono keep their channels;
    /// surround has the channels of its bed (`bed`), which can be more than the file's.
    public let processingFormat: AVAudioFormat
    /// For surround: the speakers the song's channels are, as the Mac named them (or the standard order for their count).
    public let speakers: [AudioChannelLabel]?
    /// The file's own format, as Core Audio reports it.
    public let fileFormat: AudioStreamBasicDescription
    /// Sample frames in the song.
    public let length: Int64
    /// The next frame `read` returns.
    public private(set) var position: Int64 = 0

    private let box: SourceBox
    private let audioFile: AudioFileID
    private let extFile: ExtAudioFileRef
    /// Surround only: what ExtAudioFile decodes into (the file's channels, in the file's order) and where each goes on the bed.
    private let decodeFormat: AVAudioFormat?
    private let router: BedRouter?
    private var scratch: AVAudioPCMBuffer?

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
        guard let plan = Self.plan(sampleRate: description.mSampleRate, channels: channels, labels: labels) else {
            throw fail(kAudioFileUnsupportedDataFormatError)
        }
        let processing = plan.processing
        var client = (plan.decode ?? processing).streamDescription.pointee
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
        decodeFormat = plan.decode
        router = plan.router
        speakers = plan.speakers
        length = frames
    }

    deinit {
        ExtAudioFileDispose(extFile)
        AudioFileClose(audioFile)
    }

    /// Fills `buffer` (made with `processingFormat`) and returns the frames read: zero at the end of the song.
    public func read(into buffer: AVAudioPCMBuffer) throws -> Int {
        var frames = buffer.frameCapacity
        box.error = nil
        // Surround is decoded in the file's own order, then each channel is put on its bed speaker.
        var target = buffer
        if let decodeFormat, router != nil {
            if scratch == nil || scratch!.frameCapacity < frames { scratch = AVAudioPCMBuffer(pcmFormat: decodeFormat, frameCapacity: frames) }
            guard let scratch else { throw Failure.cannotRead(Self.words(kAudioFileUnspecifiedError)) }
            target = scratch
        }
        target.frameLength = frames
        let status = ExtAudioFileRead(extFile, &frames, target.mutableAudioBufferList)
        guard status == noErr else {
            buffer.frameLength = 0
            throw box.error ?? Failure.cannotRead(Self.words(status))
        }
        if let router, target !== buffer, let from = target.floatChannelData, let to = buffer.floatChannelData {
            router.route(planes: (0..<Int(target.format.channelCount)).map { UnsafePointer(from[$0]) },
                         into: (0..<Int(buffer.format.channelCount)).map { to[$0] }, frames: Int(frames))
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

    struct Plan {
        var processing: AVAudioFormat
        var decode: AVAudioFormat?
        var router: BedRouter?
        var speakers: [AudioChannelLabel]?
    }

    /// How a song of `channels` channels is decoded. Stereo and mono: as they are. Surround: onto the smallest bed Apple's
    /// spatial mixer takes that has a place for every speaker, with the speakers the Mac named, or, when it named none, the
    /// order FLAC and WAVE files use for that many channels. nil when the speakers can't be known (more than eight, unnamed).
    static func plan(sampleRate: Double, channels: Int, labels: [UInt32]?) -> Plan? {
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)
                .map { Plan(processing: $0) }
        }
        let named = labels.flatMap { $0.count == channels ? ChannelLayouts.speakerLabels($0) : nil }
        guard let speakers = named ?? ChannelLayouts.wavOrderLabels(channels: channels), speakers.count == channels,
              let bed = ChannelLayouts.spatialBed(for: speakers), let layout = AVAudioChannelLayout(layoutTag: bed.tag),
              let router = BedRouter(source: speakers, bed: layout.channelLabels),
              let discrete = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)) else { return nil }
        let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        let decode = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: discrete)
        return Plan(processing: processing, decode: decode, router: router, speakers: speakers)
    }

    /// What `read` fills for a song like this (see `plan`).
    public static func processingFormat(sampleRate: Double, channels: Int, labels: [UInt32]?) -> AVAudioFormat? {
        plan(sampleRate: sampleRate, channels: channels, labels: labels)?.processing
    }

    private static func words(_ status: OSStatus) -> String {
        switch status {
        case kAudioFileUnsupportedFileTypeError, kAudioFileUnsupportedDataFormatError: "This kind of file can’t be played on this device."
        case kAudioFileInvalidFileError, kAudioFileStreamError_InvalidFile: "The file isn’t audio that can be read."
        default: "The audio couldn’t be read (\(status))."
        }
    }
}

#endif
