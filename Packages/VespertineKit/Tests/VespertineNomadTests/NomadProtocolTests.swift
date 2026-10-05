//
// Vespertine — Nomad protocol: report framing, JSON-RPC text, notifications, cover art layout.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import Testing
@testable import VespertineNomad

@Suite("Nomad reports")
struct NomadReportTests {
    @Test func shortMessageIsOneReport() {
        let reports = NomadReports.split("{\"a\":1}")
        #expect(reports.count == 1)
        #expect(reports[0].count == 64)
        #expect(Array(reports[0][0..<3]) == [6, 2, 7])
        #expect(String(decoding: reports[0][3..<10], as: UTF8.self) == "{\"a\":1}")
        #expect(reports[0][10...].allSatisfy { $0 == 0 })
    }

    @Test func longMessageSplitsAt61Bytes() {
        let message = String(repeating: "x", count: 130)
        let reports = NomadReports.split(message)
        #expect(reports.count == 3)
        #expect(reports.map { Int($0[2]) } == [61, 61, 8])
        var decoder = NomadReports.LineDecoder()
        var lines: [NomadReports.LineDecoder.Line] = []
        for r in NomadReports.split(message + "\n") { lines += decoder.feed(r) }
        #expect(lines.map(\.text) == [message])
    }

    @Test func decoderAcceptsReportsWithAndWithoutTheID() {
        let withID = NomadReports.split("{\"id\":5,\"result\":0}\n")
        var a = NomadReports.LineDecoder(), b = NomadReports.LineDecoder()
        #expect(a.feed(withID[0]).map(\.text) == ["{\"id\":5,\"result\":0}"])
        #expect(b.feed(Array(withID[0].dropFirst())).map(\.text) == ["{\"id\":5,\"result\":0}"])
    }

    @Test func decoderKeepsChannelsApart() {
        var decoder = NomadReports.LineDecoder()
        _ = decoder.feed(NomadReports.split("log li", channel: .debug)[0])
        let rpc = decoder.feed(NomadReports.split("{\"id\":1,\"result\":1}\n", channel: .rpc)[0])
        #expect(rpc.count == 1 && rpc[0].channel == 2)
        let debug = decoder.feed(NomadReports.split("ne\n", channel: .debug)[0])
        #expect(debug.map(\.text) == ["log line"])
    }

    @Test func decoderIgnoresForeignReports() {
        var decoder = NomadReports.LineDecoder()
        #expect(decoder.feed([1, 0, 0, 0]).isEmpty)
        #expect(decoder.feed([]).isEmpty)
    }
}

@Suite("Nomad JSON-RPC")
struct NomadRPCTests {
    @Test func requestKeepsKeyOrderAndEscapesUnicode() {
        let json = NomadRPC.request(method: "mp.write_info", params: [("song_title", .string("Café \u{1F3B5}")), ("elapsed", .int(12)), ("is_playing", .bool(true))], id: 42)
        #expect(json == "{\"method\":\"mp.write_info\",\"params\":{\"song_title\":\"Caf\\u00e9 \\ud83c\\udfb5\",\"elapsed\":12,\"is_playing\":true},\"id\":42}")
        #expect(json.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F })
    }

    @Test func requestEscapesQuotesAndControls() {
        let json = NomadRPC.request(method: "m", params: [("t", .string("say \"hi\"\\\n"))], id: 1)
        #expect(json.contains("\"say \\\"hi\\\"\\\\\\n\""))
        // And a conforming parser reads it back unchanged.
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect((parsed?["params"] as? [String: Any])?["t"] as? String == "say \"hi\"\\\n")
    }

    @Test func nullParams() {
        #expect(NomadRPC.request(method: "sys.version", params: nil, id: 7) == "{\"method\":\"sys.version\",\"params\":null,\"id\":7}")
    }

    @Test func parsesNotificationsAndResponses() {
        #expect(NomadRPC.parse("{\"method\":\"mp.fetch_data\",\"params\":{\"should_fetch\":true}}") == .notification(method: "mp.fetch_data", shouldFetch: true))
        #expect(NomadRPC.parse("{\"m\":\"mp.fetch_data\",\"p\":{\"should_fetch\":false}}") == .notification(method: "mp.fetch_data", shouldFetch: false))
        #expect(NomadRPC.parse("{\"id\":12,\"result\":\"ok\"}") == .response(id: 12, error: nil))
        #expect(NomadRPC.parse("{\"i\":3,\"error\":{\"code\":-1,\"message\":\"bad\"}}") == .response(id: 3, error: "bad"))
        #expect(NomadRPC.parse("noise") == nil)
        #expect(NomadRPC.parse("[LOG] boot {x") == nil)
    }
}

@Suite("Nomad artwork")
struct NomadArtworkTests {
    private func image(side: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side { for x in 0..<side {
            let (r, g, b) = color(x, y)
            pixels[(y * side + x) * 4] = r; pixels[(y * side + x) * 4 + 1] = g; pixels[(y * side + x) * 4 + 2] = b
        } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    @Test func layoutMatchesTheKeyboardsImageFormat() throws {
        let data = try #require(NomadArtwork.encode(image(side: 300) { x, y in (UInt8(x % 256), UInt8(y % 256), 90) }))
        // Header 12 + palette 1024 + 80×80 indices: the 7436 bytes Work Louder's own converter makes for an 80×80 cover.
        #expect(data.count == 7436)
        #expect(Array(data[0..<12]) == [0x19, 0x0A, 0, 0, 80, 0, 80, 0, 80, 0, 0, 0])
        for i in 0..<256 { #expect(data[12 + i * 4 + 3] == 0xFF) }
    }

    @Test func roundTripKeepsAFewColorsExactly() throws {
        let source = image(side: 80) { x, y in
            (x < 40 ? 200 : 20, y < 40 ? 180 : 10, 60)
        }
        let data = try #require(NomadArtwork.encode(source))
        let decoded = try #require(NomadArtwork.decode(data))
        #expect(decoded.side == 80)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(decoded.rgba[(y * 80 + x) * 4..<(y * 80 + x) * 4 + 3]) }
        #expect(pixel(10, 10) == [200, 180, 60])
        #expect(pixel(70, 10) == [20, 180, 60])
        #expect(pixel(10, 70) == [200, 10, 60])
        #expect(pixel(70, 70) == [20, 10, 60])
    }

    @Test func gradientStaysCloseWith256Colors() throws {
        let source = image(side: 80) { x, y in (UInt8(x * 3), UInt8(y * 3), UInt8((x + y) * 3 / 2)) }
        let data = try #require(NomadArtwork.encode(source))
        let decoded = try #require(NomadArtwork.decode(data))
        var worst = 0, total = 0
        for y in 0..<80 { for x in 0..<80 {
            let expect = [x * 3, y * 3, (x + y) * 3 / 2]
            for c in 0..<3 {
                let d = abs(Int(decoded.rgba[(y * 80 + x) * 4 + c]) - expect[c])
                worst = max(worst, d); total += d
            }
        } }
        #expect(total / (80 * 80 * 3) < 6, "mean error per channel")
        #expect(worst < 40)
    }

    @Test func nonSquareCoversAreCroppedFromTheCentre() throws {
        // 200×100: left half red, right half blue → the centre crop shows both halves equally.
        var pixels = [UInt8](repeating: 255, count: 200 * 100 * 4)
        for y in 0..<100 { for x in 0..<200 {
            let o = (y * 200 + x) * 4
            pixels[o] = x < 100 ? 255 : 0; pixels[o + 1] = 0; pixels[o + 2] = x < 100 ? 0 : 255
        } }
        let cg = CGImage(width: 200, height: 100, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 800,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let encoded = try #require(NomadArtwork.encode(cg))
        let decoded = try #require(NomadArtwork.decode(encoded))
        #expect(decoded.rgba[(40 * 80 + 5) * 4] > 200)      // left edge: red
        #expect(decoded.rgba[(40 * 80 + 75) * 4 + 2] > 200)   // right edge: blue
    }
}
