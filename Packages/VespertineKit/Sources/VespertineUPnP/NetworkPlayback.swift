//
// Vespertine: what the player drives while a network output plays in place of the engine (a UPnP renderer, an AirPlay
// receiver): the engine's commands, its snapshot and events. The "chosen output isn't answering" handling, carrying a song
// over at its position and the event handling in the app work the same for every one of them.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public protocol NetworkPlayback: AnyObject, Sendable {
    /// The output's name, as the listener sees it.
    var outputName: String { get }
    /// Called when a song is playing: the one after it, as for gapless playback.
    var nextItemProvider: (@Sendable (PlayableItem) -> PlayableItem?)? { get set }
    /// The file to open for an item (a local copy of a network file).
    var urlResolver: (@Sendable (PlayableItem) -> URL)? { get set }
    /// Title, artist and album for the output's display.
    var metadataProvider: (@Sendable (PlayableItem) -> RendererTrackInfo?)? { get set }
    var eventHandler: (@Sendable @MainActor (EngineEvent) -> Void)? { get set }
    var snapshot: EngineSnapshot { get }
    /// Plays `item` from `seconds` in.
    func play(_ item: PlayableItem, at seconds: TimeInterval)
    func pause()
    func resume()
    func seek(to seconds: TimeInterval)
    func stop()
    func queueChanged()
    /// Stops and lets go of the output (the output changed).
    func shutdown()
    /// A song is loaded on the output and it is answering. While it is, the output is there, whatever a search of the
    /// network says: a missed search or an expired Bonjour record doesn't end the music.
    var isEngaged: Bool { get }
    /// Vespertine is quitting: the player is told to stop, and this returns once it has been (or `timeout` has passed).
    /// Left alone it would play on to the end of the song, reading from a server that is gone. Blocks: not for the
    /// main thread's ordinary work, only the quit sequence.
    func stopAndWait(timeout: TimeInterval)
}

/// Keeps the Mac from idle sleep while a network output is meant to be playing. Nothing plays through Core Audio then, so
/// macOS holds no assertion of its own: without this the Mac sleeps in the middle of an album, and the output loses the
/// stream it gets from this Mac. The display may still sleep.
public final class PlaybackActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private let reason: String

    public init(reason: String) { self.reason = reason }

    public var isHeld: Bool { lock.withLock { token != nil } }

    public func set(_ active: Bool) {
        lock.withLock {
            if active, token == nil {
                token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
            } else if !active, let held = token {
                ProcessInfo.processInfo.endActivity(held)
                token = nil
            }
        }
    }

    deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}

extension RendererPlayback: NetworkPlayback {
    public var outputName: String { renderer.name }
}
