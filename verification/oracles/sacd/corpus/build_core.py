#!/usr/bin/env python3
"""Build the production SACD reader/DST core without macOS output-device APIs.

Only imports, the RawDSDSource protocol conformance, and its unused InputSource
property are removed. The parser, sector reader, seeking, frame assembly and DST
implementation are copied verbatim. Full SourceOpener/PCM/DoP checks run on Mac
with SACDCorpusTests. This runner never edits an image.
"""
# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import json
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[4]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
src = repo / 'Packages/VespertineKit/Sources'
image = (src/'VespertineAudio/SACDImage.swift').read_text()
decoder = (src/'VespertineAudio/SACDDecoder.swift').read_text().split('/// One stretch of an SACD area')[0]
decoder = decoder.replace('import AVFAudio\n', '').replace('import SFBAudioEngine\n', '').replace('import CVespertineDTS\n', 'import DSTCore\n')
decoder = decoder.replace('final class SACDSource: InterleavedDSDSource {', 'final class SACDSource {')
decoder = '\n'.join(line for line in decoder.splitlines() if 'var inputSource: InputSource' not in line)
shim = '''import Foundation
import CoreFoundation
#if os(Linux)
extension String {
    init(localized: String, comment: String = "") { self = localized }
}
#endif
'''
(out/'SACDImage.swift').write_text(shim + image)
(out/'SACDCore.swift').write_text(decoder)
dff = (src/'VespertineAudio/DSTDSDIFF.swift').read_text()
dff = 'import Foundation\nimport DSTCore\nenum DTSError: Error { case decoding }\n' + dff[dff.index('struct DSTDSDIFFInfo:'):]
dff = dff.replace('final class DSTDSDIFFSource: InterleavedDSDSource {', 'final class DSTDSDIFFSource {')
dff = '\n'.join(line for line in dff.splitlines() if 'var inputSource: InputSource' not in line)
(out/'DSTDSDIFF.swift').write_text(dff)
for name in ['vespertine_dst.c', 'include/CVespertineDST.h']:
    p = src/'CVespertineDTS'/name
    (out/p.name).write_bytes(p.read_bytes())
(out/'module.modulemap').write_text('module DSTCore { header "CVespertineDST.h" export * }\n')
(out/'main.swift').write_text(r'''import Foundation
let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[2])
func stream(channels: Int, read: (UnsafeMutablePointer<UInt8>, Int) throws -> Int) throws {
    var buffer = [UInt8](repeating: 0, count: 65536 * channels)
    while true {
        let n = try buffer.withUnsafeMutableBufferPointer { try read($0.baseAddress!, 65536) }
        if n == 0 { break }
        try FileHandle.standardOutput.write(contentsOf: buffer.prefix(n * channels))
    }
}
if args[1].hasPrefix("dff-") {
    guard let info = try DSTDSDIFFInfo.read(url) else { fatalError("not DST DSDIFF") }
    if args[1] == "dff-toc" {
        let areas: [[String: Any]] = [["area": info.channels == 2 ? "2ch" : "mch", "channels": info.channels,
            "dst": true, "stride": 0, "format": "DSDIFF", "frameBytes": info.frameBytes,
            "tracks": [["number": 1, "startFrame": 0, "frameCount": info.frameCount, "title": ""]]]]
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: areas))
    } else {
        let source = try DSTDSDIFFSource(url: url, info: info)
        try stream(channels: info.channels) { try source.readInterleaved(into: $0, bytes: $1) }
        try FileHandle.standardError.write(contentsOf: Data("concealed=0\n".utf8))
    }
} else {
    let image = try SACDImage.read(url)
    if args[1] == "toc" {
        let areas: [[String: Any]] = image.areas.map { a in
            ["area": a.kind.rawValue, "channels": a.channels, "dst": a.isDST, "stride": a.layout.stride, "frameBytes": a.frameBytes,
             "tracks": a.tracks.map { ["number": $0.number, "startFrame": $0.startFrame,
                                         "frameCount": $0.frameCount, "title": $0.title ?? ""] as [String: Any] }]
        }
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: areas))
    } else {
        let area = image.areas.first { $0.kind.rawValue == args[3] }!
        var frames = area.frameRange
        if args[1] == "track" {
            let track = area.tracks.first { $0.number == Int(args[4])! }!
            let count = Int(args[5])!
            guard count > 0, count <= track.frameCount else { fatalError("invalid comparison range") }
            frames = track.startFrame..<(track.startFrame + count)
        }
        let source = try SACDSource(url: url, area: area, frames: frames)
        try stream(channels: area.channels) { try source.readInterleaved(into: $0, bytes: $1) }
        try FileHandle.standardError.write(contentsOf: Data("concealed=\(source.concealedFrames)\n".utf8))
        if source.concealedFrames != 0 { exit(2) }
    }
}
''')
subprocess.run(['clang', '-O2', '-c', str(out/'vespertine_dst.c'), '-o', str(out/'dst.o')], check=True)
subprocess.run(['swiftc', '-O', '-I', str(out), str(out/'SACDImage.swift'), str(out/'SACDCore.swift'), str(out/'DSTDSDIFF.swift'), str(out/'main.swift'), str(out/'dst.o'), '-o', str(out/'sacd-core')], check=True)
files = ['VespertineAudio/SACDImage.swift', 'VespertineAudio/SACDDecoder.swift', 'VespertineAudio/DSTDSDIFF.swift', 'CVespertineDTS/vespertine_dst.c']
(out/'source-hashes.json').write_text(json.dumps({n: hashlib.sha256((src/n).read_bytes()).hexdigest() for n in files}, indent=2))
