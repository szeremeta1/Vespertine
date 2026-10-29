//
// Vespertine — the measurement audit: a simulated two-speaker room under noise, measured end to end through the
// capture session, the measurement state machine, the response analysis, the filter fit and the alignment. The
// speakers sit at different distances and levels and the left one has a bass mode; all of it has to come back.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Room measurement audit")
struct RoomMeasureAuditTests {
    private static let rate = 48_000.0

    /// Runs the whole measurement on the simulated room and turns it into a profile.
    private func measure(_ room: SimulatedRoomDevice, timeAgainstReference: Bool = true) async throws -> RoomMeasurementResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("room-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = RoomMeasurementSettings(inputDevice: 1, outputDevice: 2)
        settings.sampleRate = Self.rate
        settings.sweepSeconds = 2
        settings.timeAgainstReference = timeAgainstReference
        let session = RoomSession(id: UUID(), createdAt: Date(), deviceUID: "sim-out", layout: .stereo, channelMap: .standard(.stereo),
                                  mic: RoomMic(serial: "0000001", orientation: .upward, calibrationSHA256: nil), target: .flat)
        let capture = RoomCaptureSession(device: room, permission: AlwaysGrantedMicrophone(), pollInterval: 0.001, stallTimeout: 5)
        let controller = RoomMeasurementController(settings: settings, session: session, capturer: capture, folder: folder)
        let end = await controller.run()
        #expect(end == .completed)
        return try RoomMeasurementResult.make(recordings: controller.acceptedRecordings, session: controller.session, calibration: nil,
                                              name: "Audit", micSerial: "0000001")
    }

    @Test("Delays, levels and the bass mode of a simulated two-speaker room come back, and the profile lines the speakers up")
    func twoSpeakerRoom() async throws {
        let room = SimulatedRoomDevice()
        room.gain = [0: 0.05, 1: 0.04]                 // left 1.9 dB louder
        room.delaySeconds = [0: 0.0081, 1: 0.0094]     // left nearer: 389 and 451 samples
        let result = try await measure(room)

        // Arrivals against the left speaker's timing tones, to a fraction of a sample.
        let left = try #require(result.responses[0]?[.left]), right = try #require(result.responses[0]?[.right])
        let gap: Double = (451.0 - 389.0) / Self.rate * 1000
        #expect(abs((right.arrivalMs - left.arrivalMs) - gap) < 0.25 / Self.rate * 1000, "arrival gap \(right.arrivalMs - left.arrivalMs) ms")
        #expect(abs((left.levelDB - right.levelDB) - 20 * log10(0.05 / 0.04)) < 0.15, "level gap \(left.levelDB - right.levelDB) dB")

        // The profile: the nearer, louder left speaker waits for the right one and comes down to its level.
        let alignment = try #require(result.profile.alignment)
        #expect(abs((alignment[.left]?.delayMs ?? 0) - gap) < 0.011 && alignment[.right]?.delayMs == 0)
        #expect(abs((alignment[.left]?.levelDB ?? 0) - 20 * log10(0.04 / 0.05)) < 0.2 && alignment[.right]?.levelDB == 0)

        // The left speaker's +7 dB mode at 63 Hz is cut, and the fit gets much closer to the target there.
        let design = try #require(result.design.channels[.left])
        #expect(design.bands.contains { abs($0.frequency - 63) < 8 && $0.gainDB < -3 })
        let band: ClosedRange<Double> = 40...120
        #expect(design.rmsErrorDB(in: band, corrected: true) < design.rmsErrorDB(in: band, corrected: false) / 2)

        // It plays as measured: the left output held back and turned down, the right untouched but for the preamp.
        let playback = RoomCorrectionPlayback(profile: result.profile)
        #expect(abs(playback.channels[0].delayMs - gap) < 0.011 && playback.channels[1].delayMs == 0)
        let rendered = playback.renderChannels(sampleRate: Self.rate, channelCount: 2)
        #expect(abs(Double(rendered[0].delayFrames) - 62) <= 1 && rendered[1].delayFrames == 0)
    }

    @Test("Captures each timed by their own speaker can't be lined up in time: levels only")
    func untimedCaptures() async throws {
        let room = SimulatedRoomDevice()
        let result = try await measure(room, timeAgainstReference: false)
        let alignment = try #require(result.profile.alignment)
        #expect(alignment.values.allSatisfy { $0.delayMs == 0 })
        #expect(alignment.values.contains { $0.levelDB < -1 })
    }
}
