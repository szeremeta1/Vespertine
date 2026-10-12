//
// Vespertine verification: dumps what Vespertine reads from a real SACD image, for the comparison with sacd_extract
// (hardware/SACD-ORACLE.md). Opt-in: VERIFICATION_SACD_ISO names the image, VERIFICATION_SACD_OUT the output folder.
// SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import Foundation
import Testing
import VespertineAdapters

@Test("SACD image dump for the sacd_extract comparison",
      .enabled(if: ProcessInfo.processInfo.environment["VERIFICATION_SACD_ISO"] != nil))
func dumpSACDImage() throws {
    let env = ProcessInfo.processInfo.environment
    let image = URL(fileURLWithPath: try #require(env["VERIFICATION_SACD_ISO"]))
    let out = URL(fileURLWithPath: try #require(env["VERIFICATION_SACD_OUT"], "set VERIFICATION_SACD_OUT to an output folder"))
    let concealed = try Vespertine.writeSACDAreas(image: image, to: out)
    #expect(concealed == 0, "\(concealed) frames were missing or damaged and played as silence")
}
#endif
