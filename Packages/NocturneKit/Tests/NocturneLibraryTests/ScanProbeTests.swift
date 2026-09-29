import Foundation
import Testing
@testable import NocturneLibrary

/// Diagnostic: NOCTURNE_SCAN_FILE — reads one file as the scanner does (directly and through the network shadow).
@Test(.enabled(if: ProcessInfo.processInfo.environment["NOCTURNE_SCAN_FILE"] != nil))
func scanProbe() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOCTURNE_SCAN_FILE"]!)
    do { let t = try MetadataReader.read(url: url, artwork: nil); print("direct: \(t.codec) \(t.channels)ch \(t.sampleRate) \(t.title) dur \(t.duration) year \(String(describing: t.year)) date \(String(describing: t.releaseDate))") }
    catch { print("direct FAILED: \(error)") }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanprobe-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let shadow = dir.appendingPathComponent(url.lastPathComponent)
    let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    let n = try RemoteMetadata.makeShadow(of: url, size: size, at: shadow)
    do { let t = try MetadataReader.read(url: shadow, artwork: nil, original: url); print("shadow (\(n) reads): \(t.codec) \(t.channels)ch \(t.sampleRate) \(t.title) dur \(t.duration) year \(String(describing: t.year))") }
    catch { print("shadow FAILED: \(error)") }
    print("supported:", LibraryScanner.audioExtensions.contains("dsf"))
}
