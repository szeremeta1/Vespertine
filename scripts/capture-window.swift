// Captures the largest on-screen window of an app to PNG (used for visual QA).
// Usage: swift scripts/capture-window.swift <AppName> <out.png> [titleContains]
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let owner = args[1], out = args[2]
let titleFilter = args.count > 3 ? args[3] : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int ?? 1) >= 0 }
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
