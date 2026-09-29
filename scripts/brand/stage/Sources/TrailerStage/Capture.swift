// SPDX-License-Identifier: GPL-3.0-or-later
// Streamed capture of the stage window.
//
// A screenshot per frame means waiting for the window server to composite and then paying for a one-off
// capture: about 85 ms a frame. A stream hands over each composited frame as soon as it exists. To know
// which frame an image shows, the window carries the frame number as a strip of blocks under the stage;
// an image is accepted only when its strip shows the frame that was asked for, and the strip is cropped
// off before the frame is written.
import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// The frame number as black and white blocks: a guard pair (white, black), then 16 bits, most significant first.
/// Plain values and a reader usable from the capture queue; `FrameStamp` draws it.
enum Stamp {
    static let height: CGFloat = 4
    static let blocks = 18
    /// Shown before the first frame; never a frame number.
    static let none = 0xFFFF

    static func bits(_ n: Int) -> [Bool] { [true, false] + (0..<16).map { (n >> (15 - $0)) & 1 == 1 } }

    /// Reads the number from a captured window image whose stage is `stageRows` pixels tall.
    static func read(_ buffer: CVPixelBuffer, stageRows: Int) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer)
        let y = stageRows + Int(height)            // the middle of the strip, in pixels at 2×
        guard y < CVPixelBufferGetHeight(buffer) else { return nil }
        let bits = (0..<blocks).map { i -> Bool in
            let x = Int((Double(i) + 0.5) * Double(width) / Double(blocks))
            return base[y * rowBytes + x * 4 + 1] > 128   // BGRA: green
        }
        guard bits[0], !bits[1] else { return nil }
        return bits[2...].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
    }
}

struct FrameStamp: View {
    @ObservedObject var frame: Frame
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Stamp.bits(frame.stamp).enumerated()), id: \.offset) { _, on in
                (on ? Color.white : Color.black).frame(width: width / CGFloat(Stamp.blocks), height: Stamp.height)
            }
        }
        .frame(width: width, height: Stamp.height)
    }
}

/// Streams the stage window and hands back the first complete image that shows a given frame number.
final class StreamCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let queue = DispatchQueue(label: "trailer-stage.capture", qos: .userInteractive)
    private let lock = NSLock()
    private let stageRows: Int
    private var target = -1
    private var generation = 0
    private var waiter: CheckedContinuation<CVPixelBuffer, Error>?
    private var arrived: CVPixelBuffer?

    struct TimedOut: Error { let frame: Int }

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, stageRows: Int) throws {
        self.stageRows = stageRows
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws { try await stream.startCapture() }
    func stop() async { try? await stream.stopCapture() }

    /// Call before the stage changes to frame `n`, so an image that arrives quickly isn't missed.
    func expect(_ n: Int) {
        lock.withLock { target = n; arrived = nil; generation += 1 }
    }

    /// The first image showing the expected frame. Throws if none arrives in time rather than reusing an old one.
    func image(timeout: Double = 3) async throws -> CVPixelBuffer {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let buffer = arrived {
                arrived = nil
                lock.unlock()
                continuation.resume(returning: buffer)
                return
            }
            waiter = continuation
            let (frame, gen) = (target, generation)
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard self.generation == gen, let waiter = self.waiter else { self.lock.unlock(); return }
                self.waiter = nil
                self.lock.unlock()
                waiter.resume(throwing: TimedOut(frame: frame))
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sample),
              let n = Stamp.read(buffer, stageRows: stageRows) else { return }
        lock.lock()
        guard n == target else { lock.unlock(); return }
        target = -1
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: buffer)
        } else {
            arrived = buffer
            lock.unlock()
        }
    }
}
