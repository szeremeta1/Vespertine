import Foundation
import Testing

/// scripts/speaker-groups-qa.sh refuses to run over ssh (macOS refuses the microphone there). It must still run in the Terminal
/// window its own help sends you to: `open -a Terminal` from an ssh shell hands that window the caller's SSH_CONNECTION.
@Suite("Speaker groups QA script")
struct SpeakerGroupsQAScriptTests {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/speaker-groups-qa.sh")

    /// Runs a copy of the script in a scratch tree (so its results land there, not in the repository) with a stand-in probe
    /// that only prints its arguments. Returns the exit status, what it printed and the scratch root.
    ///
    /// The script runs on a thread of its own: a test that waits for it on Swift's cooperative pool (one thread per CPU) holds
    /// that thread, and on a small CI machine a few such tests starve every other suite's timing.
    func run(_ environment: [String: String], steps: [String] = ["info"]) async throws -> (status: Int32, output: String, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vt-qa-\(UUID().uuidString)")
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let copy = scripts.appendingPathComponent("speaker-groups-qa.sh")
        try FileManager.default.copyItem(at: Self.script, to: copy)
        let probe = root.appendingPathComponent("probe")
        try "#!/bin/sh\necho \"probe $*\"\n".write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [copy.path, "--leader", "Lead", "--follower", "Follow", "--mic", "Mic", "--probe", probe.path] + steps
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SSH_") && $0.key != "TERM_PROGRAM" }
        env["TMPDIR"] = root.path + "/"
        env.merge(environment) { $1 }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let (status, data) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, Data), Error>) in
            DispatchQueue.global().async {
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    continuation.resume(returning: (p.terminationStatus, data))
                } catch { continuation.resume(throwing: error) }
            }
        }
        return (status, String(decoding: data, as: UTF8.self), root)
    }

    func infoLog(_ root: URL) -> String? {
        let runs = root.appendingPathComponent("verification/hardware/speaker-groups")
        guard let stamp = try? FileManager.default.contentsOfDirectory(atPath: runs.path).first else { return nil }
        return try? String(contentsOf: runs.appendingPathComponent(stamp).appendingPathComponent("0-info.txt"), encoding: .utf8)
    }

    @Test("A Terminal window opened from an ssh shell (it inherits SSH_CONNECTION) runs the steps")
    func terminalOpenedFromSSH() async throws {
        let r = try await run(["SSH_CONNECTION": "192.0.2.10 53694 192.0.2.20 22", "TERM_PROGRAM": "Apple_Terminal"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.status == 0, "\(r.output)")
        #expect(!r.output.contains("This is an ssh session"))
        #expect(infoLog(r.root)?.contains("probe group-info Lead Follow") == true)
    }

    @Test("Over ssh itself (no terminal app) it still refuses, before running anything")
    func plainSSH() async throws {
        let r = try await run(["SSH_CONNECTION": "192.0.2.10 53694 192.0.2.20 22"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.status == 2)
        #expect(r.output.contains("This is an ssh session"))
        #expect(infoLog(r.root) == nil)
    }

    @Test("Without ssh it runs")
    func local() async throws {
        let r = try await run(["TERM_PROGRAM": "Apple_Terminal"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.status == 0, "\(r.output)")
        #expect(infoLog(r.root)?.contains("probe group-info Lead Follow") == true)
    }

    @Test("The info step needs no test tone, so it doesn't build the 4-channel file (that took the whole script ten seconds)")
    func infoBuildsNoToneFile() async throws {
        let r = try await run(["TERM_PROGRAM": "Apple_Terminal"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.status == 0, "\(r.output)")
        #expect(!FileManager.default.fileExists(atPath: r.root.appendingPathComponent("speaker-groups-quad.wav").path))
    }

    @Test("The quad step plays a 5 s, 4-channel, 24-bit, 48 kHz file, and the script builds it for that step")
    func quadStepBuildsToneFile() async throws {
        let r = try await run(["TERM_PROGRAM": "Apple_Terminal"], steps: ["quad"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.status == 0, "\(r.output)")
        let wav = try Data(contentsOf: r.root.appendingPathComponent("speaker-groups-quad.wav"))
        let expected: Int = 44 + 5 * 48000 * 12   // header + 5 s of 4 x 3-byte samples at 48 kHz
        #expect(wav.count == expected)
        #expect(Array(wav[22..<24]) == [4, 0], "channels")
        #expect(Array(wav[24..<28]) == [0x80, 0xBB, 0, 0], "48000 Hz")
        #expect(Array(wav[34..<36]) == [24, 0], "bits per sample")
    }
}
