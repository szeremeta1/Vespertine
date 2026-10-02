//
// Vespertine — how much an Import & Organize would really write, and whether the Mac can hold it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What copying files into the managed folder costs. A file on the same volume as the destination is
/// cloned by APFS and takes no space; a file on another drive (an external disk, a share) is copied in
/// full, so a big selection can fill the Mac's disk before anyone notices.
public struct ImportSpace: Sendable, Equatable {
    /// Bytes that would really be written.
    public var bytesToCopy: Int64
    /// Space available for important data on the destination volume, if macOS reports it.
    public var freeBytes: Int64?

    /// Space left untouched on the destination, so a copy never leaves the Mac with a full disk.
    public static let reserve: Int64 = 2 << 30

    public init(bytesToCopy: Int64, freeBytes: Int64?) {
        self.bytesToCopy = bytesToCopy
        self.freeBytes = freeBytes
    }

    /// Whether the copy fits with the reserve to spare. Nothing to copy, or free space macOS won't report, counts as fitting.
    public var fits: Bool { bytesToCopy == 0 || (freeBytes.map { bytesToCopy + Self.reserve <= $0 } ?? true) }

    /// - Parameters:
    ///   - files: the files to import, with their sizes.
    ///   - destination: the managed folder; it need not exist yet.
    public static func measure(files: [(url: URL, bytes: Int64)], destination: URL) -> ImportSpace {
        let anchor = existingAncestor(of: destination)
        let values = try? anchor.resourceValues(forKeys: [.volumeIdentifierKey, .volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        let destinationVolume = values?.volumeIdentifier as? NSObject
        // "Important usage" counts purgeable space, which is what a copy can really use, but macOS reports 0
        // for it on small volumes that plainly have room; then the plain available figure is the truth.
        let important = values?.volumeAvailableCapacityForImportantUsage
        let free = (important ?? 0) > 0 ? important : values?.volumeAvailableCapacity.map(Int64.init)

        // Files in a folder share a drive, so ask once per folder.
        var sameVolume: [URL: Bool] = [:]
        var bytes: Int64 = 0
        for file in files {
            let folder = file.url.deletingLastPathComponent()
            let same: Bool
            if let known = sameVolume[folder] {
                same = known
            } else {
                let id = (try? folder.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
                same = id != nil && destinationVolume != nil && id!.isEqual(destinationVolume!)
                sameVolume[folder] = same
            }
            if !same { bytes += file.bytes }
        }
        return ImportSpace(bytesToCopy: bytes, freeBytes: free)
    }

    private static func existingAncestor(of url: URL) -> URL {
        var current = url
        while current.path != "/", !FileManager.default.fileExists(atPath: current.path) {
            current = current.deletingLastPathComponent()
        }
        return current
    }
}
