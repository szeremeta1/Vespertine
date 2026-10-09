//
// Vespertine verification: writes the DST fixtures (verification/fixtures/dst/).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The frames come from the small DST encoder in Vespertine's test support (SACDFixture.swift), driven over its
// variants so they use plain and Rice-coded filters and tables, shared filters and half probability, plus one
// frame per channel count stored uncompressed. The expected DSD is the encoder's input. That alone would be
// circular (Vespertine's tests wrote the encoder), so oracles/dst/check_fixtures.c decodes every frame with the
// MPEG-4 reference decoder (libdstdec) and must get the same DSD; CI runs it on every change.
//
//   ./build.sh <out-dir>     (compiles this file with SACDFixture.swift and runs it)

import Foundation

struct Fixture: Codable {
    var name: String
    var channels: Int
    var coding: String          // "dst" or "uncompressed"
    var variant: Int?
    var dstBytes: Int
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let n = SACDFixture.frameBytes
var index: [Fixture] = []

// (channels, coded frames, modulator seed). Variants 0..<frames: filter lengths (variant % 4), probability tables
// (% 7), half probability and coding methods (% 3), plain or Rice-coded tables (% 2).
for (channels, frames, seed) in [(2, 6, 0.0), (5, 3, 17.0), (6, 3, 29.0)] {
    let planes = SACDFixture.modulate(channels: channels, frames: frames + 1, seed: seed)
    let encoder = DSTEncoder(planes: planes)
    for f in 0...frames {
        var dsd = [UInt8](repeating: 0, count: n * channels)
        for i in 0..<n { for c in 0..<channels { dsd[i * channels + c] = planes[c][f * n + i] } }
        let stored = f == frames
        let dst = stored ? DSTEncoder.uncompressed(dsd) : encoder.encode(dsd, variant: f)
        let name = stored ? "\(channels)ch-stored" : "\(channels)ch-v\(f)"
        try Data(dst).write(to: out.appendingPathComponent(name + ".dst"))
        try Data(dsd).write(to: out.appendingPathComponent(name + ".dsd"))
        index.append(Fixture(name: name, channels: channels, coding: stored ? "uncompressed" : "dst", variant: stored ? nil : f,
                             dstBytes: dst.count))
        print(name, dst.count)
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(index).write(to: out.appendingPathComponent("fixtures.json"))
