//
// Vespertine — launch arguments that start a room measurement without a click (so it can be started remotely, with
// `open -a … --args --room-measure <calibration file>`).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct RoomMeasureLaunch: Equatable, Sendable {
    public var calibrationPath: String?
    public var micName: String
    public var positions: Int
    public var simulate: Bool

    public init(calibrationPath: String?, micName: String, positions: Int, simulate: Bool) {
        self.calibrationPath = calibrationPath
        self.micName = micName
        self.positions = positions
        self.simulate = simulate
    }

    public static let maxPositions = 5

    /// Nil unless `--room-measure` is present. Its value (a calibration file) is optional.
    public static func parse(_ arguments: [String]) -> RoomMeasureLaunch? {
        guard let at = arguments.firstIndex(of: "--room-measure") else { return nil }
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else { return nil }
            return arguments[i + 1]
        }
        let path = at + 1 < arguments.count && !arguments[at + 1].hasPrefix("--") ? arguments[at + 1] : nil
        let positions = value(after: "--room-measure-positions").flatMap { Int($0) }.map { min(max($0, 1), maxPositions) } ?? 1
        return RoomMeasureLaunch(calibrationPath: path, micName: value(after: "--room-measure-mic") ?? "UMIK", positions: positions,
                                 simulate: arguments.contains("--room-measure-simulate"))
    }
}
