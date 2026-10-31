//
// Vespertine — what the visualizer reads while macOS renders Dolby Atmos.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The visualizer's view of an Atmos track that macOS renders: Vespertine's own output isn't involved then, so the
/// samples come from here instead (`SystemBedTap`; tests use a fake).
protocol SystemRenderTap: AnyObject, Sendable {
    /// Switches the decoding behind the tap on or off (it runs only while a visualizer window is showing).
    func setTapping(_ on: Bool)
    /// Copies the newest `left.count` frames up to what is playing now (`PlaybackEngine.copyVisualizerTap`'s contract).
    func copy(left: inout [Float], right: inout [Float]) -> PlaybackEngine.VisualizerTapRead?
}
