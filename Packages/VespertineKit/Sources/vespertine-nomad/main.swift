//
// vespertine-nomad — hardware check for the Nomad [E] media widget link.
//
//   vespertine-nomad status                      find the keyboard and ping it
//   vespertine-nomad watch [seconds]             print what the keyboard sends (read-only; default 30 s)
//   vespertine-nomad card --title T --artist A [--elapsed N --duration N --paused] [--art FILE]
//                                                put a test track on the widget
//   vespertine-nomad art FILE OUT.lvgl           encode a cover without touching the keyboard
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineNomad

struct Failure: Error, CustomStringConvertible { let description: String }

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// The link, waited on until it connects (or `seconds` pass).
func connect(timeout seconds: Double = 5) async throws -> NomadLink {
    let connected = Flag()
    var trace: (@Sendable (String) -> Void)?
    if CommandLine.arguments.contains("--trace") {
        trace = { line in print("  " + line) }
    }
    let link = NomadLink(trace: trace) { event in
        switch event {
        case .connected(let name): print("connected: \(name)"); connected.set()
        case .disconnected: print("disconnected")
        case .mediaScreen(let wants): print("media screen \(wants ? "opened" : "closed") (keyboard asks the host to \(wants ? "send" : "stop sending") track data)")
        case .notification(let method): print("notification: \(method)")
        case .problem(let reason): print("problem: \(reason)")
        }
    }
    link.start()
    let deadline = Date().addingTimeInterval(seconds)
    while !connected.isSet, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    guard connected.isSet else {
        link.stop()
        throw Failure(description: "no Nomad found on the vendor HID channel (is it plugged in by USB?)")
    }
    return link
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@main
struct Main {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first {
            case "status":
                let link = try await connect()
                try await link.ping()
                print("answered sys.version: the channel works")
                link.stop()
            case "watch":
                let seconds = args.count > 1 ? Double(args[1]) ?? 30 : 30
                let link = try await connect()
                print("watching for \(Int(seconds)) s: open the media widget on the keyboard…")
                try await Task.sleep(for: .seconds(seconds))
                link.stop()
            case "card":
                guard let title = option("--title", in: args), let artist = option("--artist", in: args) else {
                    throw Failure(description: "card needs --title and --artist")
                }
                let link = try await connect()
                if let path = option("--art", in: args) {
                    guard let encoded = NomadArtwork.encode(imageData: try Data(contentsOf: URL(fileURLWithPath: path))) else {
                        throw Failure(description: "couldn't read an image from \(path)")
                    }
                    try await link.sendArtwork(encoded)
                    print("cover sent (\(encoded.count) bytes)")
                }
                try await link.sendInfo(title: title, artist: artist,
                                        elapsed: option("--elapsed", in: args).flatMap(Int.init) ?? 0,
                                        duration: option("--duration", in: args).flatMap(Int.init) ?? 180,
                                        isPlaying: !args.contains("--paused"))
                print("info sent")
                link.stop()
            case "art":
                guard args.count == 3, let encoded = NomadArtwork.encode(imageData: try Data(contentsOf: URL(fileURLWithPath: args[1]))) else {
                    throw Failure(description: "usage: art FILE OUT.lvgl")
                }
                try encoded.write(to: URL(fileURLWithPath: args[2]))
                print("wrote \(encoded.count) bytes")
            default:
                print("usage: vespertine-nomad status | watch [seconds] | card --title T --artist A [--art FILE] | art FILE OUT")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
