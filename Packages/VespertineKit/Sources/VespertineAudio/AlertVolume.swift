//
// Vespertine — the Mac's alert volume, kept at the loudness alerts had while the volume relay raises the sound output.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The alert volume (System Settings › Sound › Alert volume) is a share of the volume of the device alerts play on:
/// alerts and Notification Center sounds play at both. While the volume relay gives the sound output the held device's
/// level, often far above its own, it moves the alert volume by as much the other way, so they keep their loudness.
///
/// There is no API for it. Standard Additions' `set volume alert volume` (0–100) runs inside `osascript` itself, so it
/// sends no Apple Event to another app and needs no Automation permission.
enum AlertVolume {
    /// The alert volume, 0–100 (nil: it couldn't be read).
    static func get() -> Int? {
        run(["alert volume of (get volume settings)"])
    }

    /// Sets the alert volume unless it is no longer `expected` (someone changed it since), and returns what it was.
    @discardableResult
    static func set(_ value: Int, ifStill expected: Int) -> Int? {
        run(["set alertBefore to alert volume of (get volume settings)",
             "if alertBefore is \(expected) then set volume alert volume \(value)",
             "alertBefore"])
    }

    /// The alert volume that plays alerts as loud as `alert` did on a device at `before` dB, now that it is at `now` dB.
    /// It is taken to scale the alert's amplitude, so it moves by the device's change in amplitude. An alert volume that
    /// isn't 0 stays at least 1, so alerts that could be heard still can. (Clamped before rounding: a silenced device
    /// is -∞ dB.)
    static func compensated(_ alert: Int, before: Float32, now: Float32) -> Int {
        guard alert > 0 else { return 0 }
        let share = Double(alert) * pow(10, Double(before - now) / 20)
        return Int(min(100, max(1, share)).rounded())
    }

    /// A volume level in decibels for a device that can't convert its own: roughly how volume curves taper.
    static func decibels(_ level: Float32) -> Float32 {
        40 * log10(max(level, 0.001))
    }

    /// Runs AppleScript lines through `osascript` and reads the number it prints. Bounded: a stuck `osascript` is ended.
    private static func run(_ lines: [String]) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        guard done.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite ? Int($0.rounded()) : nil }
    }
}
