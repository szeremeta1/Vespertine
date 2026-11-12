//
// Vespertine: a USB DAC's vendor and product ID, read from the I/O Registry.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import IOKit

/// Core Audio names a USB DAC by its descriptor strings; the stronger identity is the USB vendor and product ID, which
/// the I/O Registry holds on the USB device above the audio engine. This looks it up by the engine's global unique ID
/// (the same string as the Core Audio UID). Any step that doesn't work (a driver that registers differently, a device
/// that isn't USB) gives nil, and matching falls back to the names in the UID; nothing depends on this succeeding.
public enum USBIdentity {
    private static let cache = Locked<[String: DoPDeviceIdentity]>([:])

    /// The identity of the output with Core Audio UID `uid`, with the USB IDs when they could be read.
    public static func identity(forUID uid: String) -> DoPDeviceIdentity {
        if let hit = cache.withLock({ $0[uid] }) { return hit }
        let ids = uid.hasPrefix("AppleUSBAudioEngine:") ? lookup(uid: uid) : nil
        let identity = DoPDeviceIdentity(uid: uid, usbVendorID: ids?.vendor, usbProductID: ids?.product)
        // Kept either way: the engine's UID exists only once its USB device is in the registry, so a miss here is the
        // driver registering differently, not timing, and the DoP switch reads this on every redraw.
        cache.withLock { $0[uid] = identity }
        return identity
    }

    private static func lookup(uid: String) -> (vendor: UInt16, product: UInt16)? {
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let engineID = property(entry, "IOAudioEngineGlobalUniqueID") as? String, engineID == uid else { continue }
            return usbIDs(above: entry)
        }
        return nil
    }

    /// Walks up from the audio engine to the USB device that has `idVendor` and `idProduct`.
    private static func usbIDs(above start: io_registry_entry_t) -> (UInt16, UInt16)? {
        var current = start
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<12 {
            if let vendor = (property(current, "idVendor") as? NSNumber)?.uint16Value,
               let product = (property(current, "idProduct") as? NSNumber)?.uint16Value { return (vendor, product) }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent                                         // owned: released by the next step or the defer above
        }
        return nil
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

extension OutputDevices {
    /// The connected outputs as identities, with USB vendor and product IDs where they could be read.
    public static func connectedIdentities() -> [DoPDeviceIdentity] {
        connectedUIDs().map { USBIdentity.identity(forUID: $0) }
    }
}
