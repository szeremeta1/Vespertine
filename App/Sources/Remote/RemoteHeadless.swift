//
// Vespertine: the remote's options for a Mac without a screen (a Mac mini by the hi-fi): open at login, stay awake while the
// remote is on, and wake for network access. Each is its own switch in Settings › Remote, off by default.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import IOKit.pwr_mgt
import ServiceManagement

/// Opening Vespertine when the user logs in (a login item, listed in System Settings › General › Login Items).
enum RemoteLoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    /// macOS wants the user to allow it in System Settings › General › Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Turns the login item on or off. Returns the error to show, or nil.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Holds off idle sleep (not display sleep) while the remote server runs with "Keep this Mac awake" on, so a paused Mac
/// doesn't drop off the network. Playing audio already keeps a Mac awake; this covers the pauses.
final class RemoteKeepAwake {
    private var assertion: IOPMAssertionID = 0
    private(set) var isHolding = false

    func hold(_ on: Bool) {
        if on, !isHolding {
            let reason = "Vespertine’s remote is on, so a phone can reach this Mac" as CFString
            isHolding = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess
        } else if !on, isHolding {
            IOPMAssertionRelease(assertion)
            isHolding = false
        }
    }

    deinit { if isHolding { IOPMAssertionRelease(assertion) } }
}

/// macOS's "Wake for network access" (`pmset womp`): with it, and an Apple TV or HomePod on the network acting as Bonjour
/// Sleep Proxy, a phone looking for the Mac can wake it. Changing it needs an administrator's password.
nonisolated enum RemoteWakeForNetwork {
    /// The current setting, read from `pmset -g` (nil when it couldn't be read).
    static func current() async -> Bool? {
        await Task.detached {
            guard let output = run("/usr/bin/pmset", ["-g"]) else { return nil }
            return parse(output)
        }.value
    }

    /// `pmset -g`'s "womp" line: " womp                 1".
    static func parse(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "womp" { return fields[1] == "1" }
        }
        return nil
    }

    /// Sets Wake for network access for every power source, asking for an administrator's password. Returns whether it
    /// was set (false: the password was refused or the prompt was cancelled).
    static func set(_ on: Bool) async -> Bool {
        await Task.detached {
            let script = "do shell script \"/usr/bin/pmset -a womp \(on ? 1 : 0)\" with administrator privileges"
            return run("/usr/bin/osascript", ["-e", script]) != nil
        }.value
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
