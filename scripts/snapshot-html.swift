// Renders a local HTML file to a PNG with WebKit (used for design-mockup review).
// Usage: swift scripts/snapshot-html.swift <input.html> <output.png> [width] [scale] [clipY clipH]
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: snapshot-html <in.html> <out.png> [width] [scale] [clipY clipH]"); exit(2) }
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let width = args.count > 3 ? Double(args[3])! : 1520
let scale = args.count > 4 ? Double(args[4])! : 1
let clipY = args.count > 6 ? Double(args[5]) : nil
let clipH = args.count > 6 ? Double(args[6]) : nil

final class Snapper: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
    func start() {
        web.navigationDelegate = self
        web.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Wait for web fonts, so a page is never captured in its fallback font.
        webView.callAsyncJavaScript("await document.fonts.ready; return document.documentElement.scrollHeight",
                                    arguments: [:], in: nil, in: .page) { result in
            let height = (try? result.get() as? Double) ?? 1000
            webView.setFrameSize(NSSize(width: width, height: height))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let cfg = WKSnapshotConfiguration()
                cfg.rect = NSRect(x: 0, y: clipY ?? 0, width: width, height: clipH ?? height)
                cfg.snapshotWidth = NSNumber(value: width * scale)
                webView.takeSnapshot(with: cfg) { image, error in
                    guard let image, let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else {
                        print("snapshot failed: \(String(describing: error))"); exit(1)
                    }
                    try! png.write(to: output)
                    print("wrote \(output.path) \(Int(rep.pixelsWide))x\(Int(rep.pixelsHigh))")
                    exit(0)
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let snapper = Snapper()
snapper.start()
app.run()
