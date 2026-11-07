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
    func run(_ environment: [String: String]) throws -> (status: Int32, output: String, root: URL) {
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
        p.arguments = [copy.path, "--leader", "Lead", "--follower", "Follow", "--mic", "Mic", "--probe", probe.path, "info"]
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SSH_") && $0.key != "TERM_PROGRAM" }
        env["TMPDIR"] = root.path + "/"
        env.merge(environment) { $1 }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self), root)
    }

    func infoLog(_ root: URL) -> String? {
        let runs = root.appendingPathComponent("verification/hardware/speaker-groups")
        guard let stamp = try? FileManager.default.contentsOfDirectory(atPath: runs.path).first else { return nil }
        return try? String(contentsOf: runs.appendingPathComponent(stamp).appendingPathComponent("0-info.txt"), encoding: .utf8)
    }

    @Test("A Terminal window opened from an ssh shell (it inherits SSH_CONNECTION) runs the steps")
    func terminalOpenedFromSSH() throws {
        let r = try run(["SSH_CONNECTION": "100.74.181.117 53694 100.102.37.56 22", "TERM_PROGRAM": "Apple_Terminal"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.status == 0, "\(r.output)")
        #expect(!r.output.contains("This is an ssh session"))
        #expect(infoLog(r.root)?.contains("probe group-info Lead Follow") == true)
    }

    @Test("Over ssh itself (no terminal app) it still refuses, before running anything")
    func plainSSH() throws {
        let r = try run(["SSH_CONNECTION": "100.74.181.117 53694 100.102.37.56 22"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.status == 2)
        #expect(r.output.contains("This is an ssh session"))
        #expect(infoLog(r.root) == nil)
    }

    @Test("Without ssh it runs")
    func local() throws {
        let r = try run(["TERM_PROGRAM": "Apple_Terminal"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.status == 0, "\(r.output)")
        #expect(infoLog(r.root)?.contains("probe group-info Lead Follow") == true)
    }
}
