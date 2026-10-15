//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

@Suite("Device names")
struct DeviceNameTests {
    @Test("A USB DAC that calls itself \u{201C}Headphone\u{201D} is shown by its product name")
    func genericUSBName() {
        // Read from a UGREEN CM450 (2026-10-15): Core Audio name "Headphone", model UID "<product>:<VID>:<PID>".
        #expect(DeviceQuery.displayName("Headphone", manufacturer: "UGREEN", modelUID: "UGREEN CM450 USB Audio:2B89:D9B6",
                                         transport: .usb) == "UGREEN CM450")
        #expect(DeviceQuery.displayName("Headphones", manufacturer: "Acme", modelUID: "HD-1:1234:ABCD", transport: .usb) == "Acme HD-1")
        // A product name that says nothing either: the manufacturer goes in front.
        #expect(DeviceQuery.displayName("USB Audio", manufacturer: "C-Media", modelUID: "USB Audio Device:0D8C:0014",
                                         transport: .usb) == "C-Media USB Audio")
        #expect(DeviceQuery.displayName("Speaker", manufacturer: "", modelUID: nil, transport: .usb) == "Speaker")
    }

    @Test("Real names and non-USB devices are left alone")
    func specificNames() {
        #expect(DeviceQuery.displayName("FiiO K11", manufacturer: "FIIO", modelUID: "FiiO K11:2972:0077", transport: .usb) == "FiiO K11")
        #expect(DeviceQuery.displayName("Headphones", manufacturer: "Apple Inc.", modelUID: "Codec", transport: .builtIn) == "Headphones")
        #expect(DeviceQuery.displayName("Speakers", manufacturer: "Apple Inc.", modelUID: nil, transport: .bluetooth) == "Speakers")
    }
}
