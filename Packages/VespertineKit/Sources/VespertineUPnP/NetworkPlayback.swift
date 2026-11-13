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
}

extension RendererPlayback: NetworkPlayback {
    public var outputName: String { renderer.name }
}
