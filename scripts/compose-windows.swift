// Lays one window capture over another, as the windows sat on screen, for a scene that shows two windows at once.
// The pixels of each window are untouched; only a drop shadow is drawn around the top one.
// Usage: swift scripts/compose-windows.swift <out.png> <bottom.png> <top.png> <x> <y>   (top's offset in pixels from bottom's top-left)
import AppKit

let a = CommandLine.arguments
func load(_ p: String) -> CGImage { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!, 0, nil)! }
let bottom = load(a[2]), top = load(a[3])
let x = CGFloat(Double(a[4])!), y = CGFloat(Double(a[5])!)
let w = bottom.width, h = bottom.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: w, height: h))
let rect = CGRect(x: x, y: CGFloat(h) - y - CGFloat(top.height), width: CGFloat(top.width), height: CGFloat(top.height))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 80, color: CGColor(gray: 0, alpha: 0.55))
ctx.draw(top, in: rect)
ctx.restoreGState()
ctx.draw(top, in: rect)
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
