//
// Vespertine — from a finished measurement to a room correction profile: each speaker's calibrated response at each
// position, the positions averaged per speaker, the fitted filters, and the speakers' delays and levels lined up at the
// seat. Offline; nothing here touches playback.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct RoomMeasurementResult: Sendable {
    /// Each position's responses, per speaker (position 0 is the listening seat).
    public let responses: [Int: [RoomSpeaker: RoomMagnitudeResponse]]
    /// Each speaker's positions averaged in power.
    public let curves: [RoomSpeaker: RoomCurve]
    public let design: RoomCorrectionDesign
    public let profile: RoomProfile

    /// `recordings` are the accepted sweeps of `session` (matched to its captures by start time). Delays are lined up
    /// from the seat (position 0), and only when every speaker there was timed against the same reference speaker;
    /// levels from every position.
    public static func make(recordings: [RoomRecording], session: RoomSession, calibration: MicCalibration?, name: String,
                            micSerial: String, options: RoomFilterDesignOptions = .default, createdAt: Date = Date()) throws -> RoomMeasurementResult {
        let map = session.channelMap
        let positionOf: [Date: Int] = Dictionary(session.captures.map { ($0.recordedAt, $0.position) }, uniquingKeysWith: { a, _ in a })
        var responses: [Int: [RoomSpeaker: RoomMagnitudeResponse]] = [:]
        var timedAt: [Int: [RoomSpeaker: Int]] = [:]   // position → speaker → the output that played its references
        for recording in recordings {
            let output = recording.request.outputChannel
            guard let speaker = map.entries.first(where: { $0.output == output })?.speaker else { continue }
            let position = positionOf[recording.startedAt] ?? 0
            responses[position, default: [:]][speaker] = try RoomMagnitudeResponse.compute(recording: recording, calibration: calibration)
            timedAt[position, default: [:]][speaker] = recording.request.referenceChannel ?? output
        }
        // Each speaker on its own: its positions averaged in power, never mixed with another speaker.
        var curves: [RoomSpeaker: RoomCurve] = [:]
        var levels: [RoomSpeaker: Double] = [:]
        for speaker in map.entries.map(\.speaker) {
            let measured = responses.keys.sorted().compactMap { responses[$0]?[speaker] }
            guard !measured.isEmpty else { continue }
            curves[speaker] = try RoomCurve.powerAverage(measured.map { try RoomCurve($0) })
            let power: Double = measured.map { pow(10, $0.levelDB / 10) }.reduce(0, +) / Double(measured.count)
            levels[speaker] = 10 * log10(power)
        }
        let design = try RoomFilterDesigner.design(channels: curves, options: options)
        var profile = design.profile(name: name, sessionID: session.id, deviceUID: session.deviceUID, channelMap: map, micSerial: micSerial,
                                     calibrationSHA256: session.mic.calibrationSHA256, createdAt: createdAt)
        profile.measured = curves
        profile.designOptions = options
        profile.source = .measured
        if curves.count > 1 {
            profile.alignment = RoomSpeakerAlignment.align(arrivalMs: arrivals(responses[0] ?? [:], timedBy: timedAt[0] ?? [:]), levelDB: levels)
        }
        return RoomMeasurementResult(responses: responses, curves: curves, design: design, profile: profile)
    }

    /// The speakers' arrivals at the seat, when they were all timed against the same speaker; none otherwise (each
    /// timed by itself says nothing about the others).
    static func arrivals(_ seat: [RoomSpeaker: RoomMagnitudeResponse], timedBy: [RoomSpeaker: Int]) -> [RoomSpeaker: Double] {
        guard seat.count > 1, Set(timedBy.values).count == 1 else { return [:] }
        return seat.mapValues(\.arrivalMs)
    }
}
