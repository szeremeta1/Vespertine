//
// Vespertine: a bit-perfect audio player for macOS.
// Copyright © 2026 Vespertine contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

#if DEBUG
/// CI also runs on Macs that are in use: one may be playing music, another carrying a call. A runner there starts
/// every test process with no way to talk to macOS's audio system. It can't do that for this app when it hosts the
/// app's tests, because Xcode starts the app through launchd, outside anything the runner wraps around its own
/// processes. So the debug app does it to itself: told `VESPERTINE_CI_NO_AUDIO=1`, it puts a sandbox on its own
/// process that cannot reach the audio system (coreaudiod), the system-sound server or speech, before it does
/// anything else, and quits if it can't. From then on macOS reports no audio devices to it at all.
/// Debug builds only: nothing in a release build reads the variable.
enum CIQuiet {
    /// True once this process has shut itself off from audio; false when it was not asked to.
    static let applied: Bool = {
        guard ProcessInfo.processInfo.environment["VESPERTINE_CI_NO_AUDIO"] == "1" else { return false }
        let rules = """
            (version 1)(allow default)(deny mach-lookup \
            (global-name "com.apple.audio.audiohald") (global-name "com.apple.audio.coreaudiod") \
            (global-name "com.apple.audio.SystemSoundServer-OSX") (global-name "com.apple.audio.systemsoundserverd") \
            (global-name-regex #"^com\\.apple\\.speech\\."))
            """
        // sandbox_init is deprecated in the SDK's headers, so it is looked up by name (RTLD_DEFAULT).
        typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        var message: UnsafeMutablePointer<CChar>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_init"),
              unsafeBitCast(symbol, to: SandboxInit.self)(rules, 0, &message) == 0 else {
            fputs("CIQuiet: could not shut this process off from audio: \(message.map { String(cString: $0) } ?? "?")\n", stderr)
            exit(97)
        }
        return true
    }()
}
#endif
