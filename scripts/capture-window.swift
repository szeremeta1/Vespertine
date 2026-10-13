// Captures the largest on-screen window of an app to PNG (used for visual QA).
// Usage: swift scripts/capture-window.swift <AppName|pid> <out.png> [titleContains]
// A number picks the windows of that process, so one copy of an app can be captured while another is open.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let owner = args[1], out = args[2]
let titleFilter = args.count > 3 ? args[3] : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let pid = Int(owner)
let windows = list.filter { w in
    (pid.map { (w[kCGWindowOwnerPID as String] as? Int) == $0 } ?? ((w[kCGWindowOwnerName as String] as? String) == owner))
        && (w[kCGWindowLayer as String] as? Int ?? 1) >= 0
}
    .filter { titleFilter == nil || (($0[kCGWindowName as String] as? String) ?? "").contains(titleFilter!) }
    .sorted {
        let a = $0[kCGWindowBounds as String] as? [String: Double] ?? [:], b = $1[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (a["Width"] ?? 0) * (a["Height"] ?? 0) > (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
for w in windows {
    print(w[kCGWindowNumber as String] ?? "", w[kCGWindowName as String] ?? "", w[kCGWindowLayer as String] ?? "", w[kCGWindowBounds as String] ?? "")
}
guard let id = windows.first?[kCGWindowNumber as String] as? Int else { print("no window"); exit(1) }
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", "-o", "-l", String(id), out]
try p.run(); p.waitUntilExit()
print("captured \(id) → \(out) status \(p.terminationStatus)")
