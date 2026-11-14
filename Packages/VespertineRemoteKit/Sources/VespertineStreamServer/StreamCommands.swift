//
// Vespertine: the stream commands as the Mac's remote server answers them. The server calls `handle` for any command and sends
// what comes back: a JSON reply, or a binary frame for a read.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public enum StreamAnswer: Sendable, Equatable {
    case reply(RemoteReply)
    case frame(StreamFrame)
}

extension StreamPreparer {
    public static func isStreamCommand(_ command: RemoteCommand) -> Bool {
        switch command {
        case .streamInfo, .streamOpen, .streamRead, .streamClose: true
        default: false
        }
    }

    /// What a phone is told while Stream to Phones is off (the server answers with it without making a preparer).
    public static var refusalWhenOff: String { StreamWords.say(.streamingOff) }
    public static var refusalForOlderPhones: String { StreamWords.say(.olderPhone) }

    /// nil when `command` isn't a stream command. `protocolVersion` is what the connection negotiated; `allowed` is the Mac's
    /// "Stream to phones" switch (and this phone's own permission).
    public func handle(_ command: RemoteCommand, id: Int, client: String, protocolVersion: Int, allowed: Bool) async -> StreamAnswer? {
        guard Self.isStreamCommand(command) else { return nil }
        guard protocolVersion >= RemoteProtocol.streamVersion else {
            return .reply(.failed(reason: Self.refusalForOlderPhones))
        }
        guard allowed else {
            return .reply(.failed(reason: Self.refusalWhenOff))
        }
        switch command {
        case .streamInfo(let ids, let maxSampleRate):
            return .reply(.streamInfo(items: await info(ids: ids, maxSampleRate: maxSampleRate)))
        case .streamOpen(let song, let maxSampleRate, let smaller):
            switch await open(client: client, id: song, maxSampleRate: maxSampleRate, smaller: smaller ?? false) {
            case .ready(let descriptor): return .reply(.streamOpened(descriptor))
            case .preparing(let progress): return .reply(.streamPreparing(progress: progress))
            case .failed(let reason): return .reply(.failed(reason: reason))
            }
        case .streamRead(let stream, let offset, let length):
            switch await read(client: client, request: id, stream: stream, offset: offset, length: length) {
            case .chunk(let frame): return .frame(frame)
            case .failed(let reason): return .reply(.failed(reason: reason))
            }
        case .streamClose(let stream):
            close(client: client, stream: stream)
            return .reply(.ok)
        default:
            return nil
        }
    }
}

/// Who is told when the Mac stops sending songs.
public enum StreamNotice {
    /// A phone that speaks the stream protocol; an older one never played songs itself and doesn't know the message.
    public static func tells(protocolVersion: Int) -> Bool { protocolVersion >= RemoteProtocol.streamVersion }
}
