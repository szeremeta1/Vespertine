//
// Vespertine: one song's stream from the Mac, kept alive across connections. The Mac forgets a phone's streams when its
// connection ends (Wi-Fi to cellular, a tunnel that dropped, the Mac restarted); the bytes are still the same bytes, so the
// phone waits for the connection, opens the song again and reads on from where it was. Reads only fail when the Mac stays
// away longer than `patience`, or the song is no longer the same bytes.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import Foundation
import VespertineRemoteProtocol

actor StreamLine {
    private let client: PhoneStreamClient
    private let song: Int64
    private let tag: String
    private let byteSize: Int64
    private let maxSampleRate: Double?
    private let patience: Duration
    private let pause: Duration
    /// The stream's number on the Mac for the connection it was last opened on.
    private(set) var number: Int
    private var reopening: Task<Void, Error>?
    private var waiting: (@Sendable (Bool) -> Void)?
    private var closed = false
    /// Bytes read from the Mac over this line (for the data counter).
    private(set) var bytesRead: Int64 = 0

    /// `patience`: how long a read waits for the Mac to come back. `pause`: between looks at the connection.
    init(client: PhoneStreamClient, song: Int64, descriptor: StreamDescriptor, maxSampleRate: Double?,
         patience: Duration = .seconds(120), pause: Duration = .milliseconds(300)) {
        self.client = client
        self.song = song
        tag = descriptor.tag
        byteSize = descriptor.byteSize
        number = descriptor.stream
        self.maxSampleRate = maxSampleRate
        self.patience = patience
        self.pause = pause
    }

    /// Called with true when a read starts waiting for the Mac, and false when the stream is open again (or given up on).
    func onWaiting(_ handler: (@Sendable (Bool) -> Void)?) { waiting = handler }

    func read(offset: Int64, length: Int) async throws -> StreamFrame {
        while true {
            try Task.checkCancellation()
            if closed { throw StreamSource.Failure.closed }
            let asked = number
            do {
                let frame = try await client.read(asked, offset, length)
                bytesRead += Int64(frame.payload.count)
                return frame
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Another read may have opened it again while this one was failing.
                if number == asked { try await reopen(after: error) }
            }
        }
    }

    /// Gives the stream back to the Mac.
    func close() async {
        closed = true
        reopening?.cancel()
        await client.close(number)
    }

    private func reopen(after error: Error) async throws {
        if let reopening { return try await reopening.value }
        let task = Task { try await self.openAgain(after: error) }
        reopening = task
        defer { reopening = nil }
        try await task.value
    }

    private func openAgain(after error: Error) async throws {
        waiting?(true)
        defer { waiting?(false) }
        let deadline = ContinuousClock.now + patience
        let last = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        while true {
            try Task.checkCancellation()
            if closed { throw StreamSource.Failure.closed }
            if await client.isConnected() {
                switch await client.open(song, maxSampleRate) {
                case .streamOpened(let descriptor):
                    guard descriptor.tag == tag, descriptor.byteSize == byteSize else {
                        Task { [client] in await client.close(descriptor.stream) }
                        throw StreamSource.Failure.brokenStream("The song changed on the Mac while it was playing.")
                    }
                    number = descriptor.stream
                    return
                case .failed(let reason) where !reason.isEmpty && ContinuousClock.now >= deadline:
                    throw StreamSource.Failure.unreachable(reason)
                default:
                    break   // still converting, or the connection went again: ask once more
                }
            }
            guard ContinuousClock.now < deadline else { throw StreamSource.Failure.unreachable(last) }
            try await Task.sleep(for: pause)
        }
    }
}
#endif
