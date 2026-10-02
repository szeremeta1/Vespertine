//
// vespertine-probe — verifies device handling on real hardware.
//   vespertine-probe list
//   vespertine-probe play <device-name-or-uid> <seconds> <file> [file…]   (plays files in sequence, gapless where possible)
//   vespertine-probe watch <seconds>          prints every device's volume and the system output whenever they change
//   vespertine-probe pausetest <device> <file> <volume 0…1> <pause seconds> <release-after seconds>
//   vespertine-probe doptest <device> [a.dsf b.dsf]   DoP through pause, seek and skip, narrated (writes test files if none)
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import VespertineAudio
import Synchronization

func readback(_ id: AudioObjectID) -> (rate: Double, physical: String, hogPID: pid_t) {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var rate = Float64(0); var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
    addr.mSelector = kAudioDevicePropertyStreams; addr.mScope = kAudioObjectPropertyScopeOutput
    var stream = AudioStreamID(0); size = UInt32(MemoryLayout<AudioStreamID>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &stream)
    var asbd = AudioStreamBasicDescription(); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var paddr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(stream, &paddr, 0, nil, &size, &asbd)
    let kind = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "int"
    var hog = pid_t(-1); size = UInt32(MemoryLayout<pid_t>.size)
    var haddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyHogMode, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(id, &haddr, 0, nil, &size, &hog)
    return (rate, "\(kind)\(asbd.mBitsPerChannel) \(asbd.mChannelsPerFrame)ch @ \(SampleRate.format(asbd.mSampleRate))k", hog)
}

let args = CommandLine.arguments
let devices = OutputDevices.list()

if args.count < 2 || args[1] == "list" {
    for d in devices {
        print("■ \(d.name)  [\(d.uid)]")
        print("   transport \(d.transport.label) · profile \(d.profile.kind.rawValue) (\(d.profile.tag)) · bit-perfect capable: \(d.profile.canBeBitPerfect)")
        print("   rates: \(d.capabilities.sampleRates.map { SampleRate.format($0) }.joined(separator: " "))  current \(SampleRate.format(d.nominalSampleRate))k")
        let formats = d.capabilities.physicalFormats
            .sorted { ($0.bitDepth, $0.minRate) < ($1.bitDepth, $1.minRate) }
            .map { "\($0.isInteger ? "int" : "float")\($0.bitDepth)\($0.isMixable ? "" : "(non-mix)") \($0.channels)ch \(SampleRate.format($0.minRate))–\(SampleRate.format($0.maxRate))" }
        print("   physical: \(Set(formats).sorted().joined(separator: " | "))")
        print("   hw volume: \(d.hasHardwareVolume) \(DeviceControl.hardwareVolume(d.id).map { String(format: "(%.2f)", $0) } ?? "") · default: \(d.isDefault) · hog owner: \(DeviceControl.hogOwner(d.id))")
        if let note = d.profile.note { print("   note: \(note)") }
    }
    exit(0)
}

if args.count >= 3, args[1] == "channels" {
    // Decoder format and channel layout per file.
    for path in args[2...] {
        let url = URL(fileURLWithPath: path)
        do {
            let (format, decoder) = try SourceInspector.inspect(url)
            let layout = try SourceInspector.probeLayout(url)
            print("\(url.lastPathComponent): \(format.channels) ch · \(decoder) · layout \(layout)")
        } catch { print("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
    exit(0)
}

if args.count >= 3, args[1] == "forensics" {
    // Tab-separated measurements for calibration: one row per file.
    print("file\trate\tverdict\tconf\tcliff\tdrop\tconsist\tbelow\tabove\tfloor\text\tslope\tholes\tcontent\tbits\tshelf\tsstep\tsend\tsslope\tsabove\tscons\tstrack\tmirror\tmcorr\tmframes")
    for path in args[2...] {
        let url = URL(fileURLWithPath: path)
        guard let r = try? FileAnalyzer.analyze(url: url, maxSeconds: 120), let f = r.forensics else { print("\(url.lastPathComponent)\terror"); continue }
        let tracking = f.shelfTracking.map { String(format: "%.2f", $0) } ?? "-"
        let mirror = [f.mirrorHz.map { String(format: "%.0f", $0) } ?? "-", f.mirrorCorrelation.map { String(format: "%.2f", $0) } ?? "-",
                      f.mirrorFrames.map(String.init) ?? "-"].joined(separator: "\t")
        print(String(format: "%@\t%.0f\t%@\t%.2f\t%.0f\t%.1f\t%.2f\t%.1f\t%.1f\t%.1f\t%.0f\t%.2f\t%.3f\t%.0f\t%@\t%.0f\t%.1f\t%.0f\t%.2f\t%.1f\t%.2f",
                     url.lastPathComponent, r.sampleRate, r.verdict.rawValue, r.confidence, f.cliffHz ?? 0, f.cliffDropDB, f.cliffConsistency,
                     f.belowDB, f.aboveDB, f.floorDB, f.extensionHz, f.extensionSlope, f.holeRatio, f.contentHz,
                     r.effectiveBitDepth.map(String.init) ?? "-", f.shelfHz ?? 0, f.shelfStepDB, f.shelfEndHz, f.shelfSlope, f.shelfAboveFloorDB, f.shelfConsistency)
              + "\t" + tracking + "\t" + mirror)
    }
    exit(0)
}

if args.count >= 3, args[1] == "restore-test" {
    // restore-test <device name>: switches the device the way playback does (no audio), then checks
    // each quit option (44.1/16, 48/24, restore) puts it where it should.
    guard let d = OutputDevices.list(dopEnabledUIDs: []).first(where: { $0.name.localizedCaseInsensitiveContains(args[2]) }) else { print("no such device"); exit(1) }
    let steps = DeviceRestore.exercise(d)
    for s in steps { print("\(d.name): \(s.step) → \(s.rate) Hz / \(s.bits)-bit") }
    exit(steps.first?.rate == steps.last?.rate && steps.first?.bits == steps.last?.bits ? 0 : 1)
}

if args.count >= 3, args[1] == "analyze-json" {
    // One JSON line per file (compare with `vespertine-analyze file`).
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    for path in args[2...] {
        do {
            let r = try FileAnalyzer.analyze(url: URL(fileURLWithPath: path))
            print("{\"path\":" + String(decoding: try encoder.encode(path), as: UTF8.self) + ",\"analysis\":" + String(decoding: try encoder.encode(r), as: UTF8.self) + "}")
        } catch { FileHandle.standardError.write(Data("\(path): \(error)\n".utf8)) }
    }
    exit(0)
}

if args.count >= 3, args[1] == "analyze" {
    for path in args[2...] {
        let url = URL(fileURLWithPath: path)
        do {
            let r = try FileAnalyzer.analyze(url: url)
            print("\(url.lastPathComponent)")
            print(String(format: "   %@ · claimed %@ · effective %@ · bandwidth %.1f kHz of %@ · peak %.2f dBFS · clipped %d",
                         r.verdict.rawValue, r.claimedBitDepth.map { "\($0)-bit" } ?? "–", r.effectiveBitDepth.map { "\($0)-bit" } ?? "–",
                         r.bandwidthHz / 1000, SampleRate.format(r.sampleRate / 2), r.peakDBFS, r.clippedSamples))
            print("   \(r.summary) [decoded \(String(format: "%.1f", r.secondsAnalyzed)) s]")
        } catch { print("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
    exit(0)
}

if args.count >= 4, args[1] == "gapless", let device = devices.first(where: { $0.uid == args[2] || $0.name.localizedCaseInsensitiveContains(args[2]) }) {
    // Plays the files as a queue and lets the engine hand off by itself; reports transitions and underruns.
    let items = args[3...].map { PlayableItem(url: URL(fileURLWithPath: $0)) }
    let engine = PlaybackEngine()
    var settings = EngineSettings()
    settings.deviceUID = device.uid
    engine.update(settings: settings)
    engine.nextItemProvider = { finished in
        guard let i = items.firstIndex(where: { $0.id == finished.id }), i + 1 < items.count else { return nil }
        return items[i + 1]
    }
    let start = Date()
    let ended = Mutex(false)
    engine.eventHandler = { event in
        let t = String(format: "%6.2fs", Date().timeIntervalSince(start))
        switch event {
        case .trackStarted(let item):
            let snap = engine.snapshot
            let hw = readback(device.id)
            print("\(t) ▶ \(item.url.lastPathComponent) · device \(SampleRate.format(hw.rate))k \(hw.physical) · underruns so far \(snap.underruns)")
        case .queueEnded: print("\(t) ■ queue ended · underruns \(engine.snapshot.underruns)"); ended.withLock { $0 = true }
        case .failed(_, let m): print("\(t) ✗ \(m)")
        case .deviceLost(let n): print("\(t) device lost \(n)")
        case .waitingForDevice(let n): print("\(t) waiting for \(n)")
        case .deviceUnavailable(let n): print("\(t) \(n) unavailable")
        case .deviceNotResponding(let n): print("\(t) \(n) not responding")
        }
    }
    engine.play(items[0])
    while !ended.withLock({ $0 }) && Date().timeIntervalSince(start) < 600 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    engine.stop()
    exit(0)
}

func volumes() -> String {
    OutputDevices.list().map { d in
        let v = DeviceControl.hardwareVolume(d.id).map { String(format: "%.3f", $0) } ?? "-"
        return "\(d.name)=\(v)\(d.isDefault ? "*" : "")"
    }.joined(separator: "  ")
}

if args.count >= 3, args[1] == "watch" {
    let end = Date().addingTimeInterval(Double(args[2]) ?? 30)
    var last = ""
    let start = Date()
    while Date() < end {
        let now = volumes()
        if now != last { print(String(format: "%6.2fs  ", Date().timeIntervalSince(start)) + now + "   (* = Mac's sound output)"); last = now }
        Thread.sleep(forTimeInterval: 0.1)
    }
    exit(0)
}

if args.count >= 7, args[1] == "pausetest" {
    guard let device = devices.first(where: { $0.uid == args[2] || $0.name.localizedCaseInsensitiveContains(args[2]) }) else { print("no device"); exit(1) }
    let target = Float(args[4]) ?? 0.3, pause = Double(args[5]) ?? 10, release = Double(args[6]) ?? 5
    let engine = PlaybackEngine()
    var settings = EngineSettings()
    settings.deviceUID = device.uid
    settings.exclusive = true
    settings.releaseExclusiveAfterPause = release
    engine.update(settings: settings)
    func report(_ label: String) {
        let hw = readback(device.id)
        print(String(format: "%-28@ volume %@  hog=%@  state=%@", label, DeviceControl.hardwareVolume(device.id).map { String(format: "%.3f", $0) } ?? "-",
                     hw.hogPID == getpid() ? "us" : String(hw.hogPID), engine.snapshot.state.rawValue))
    }
    report("before")
    engine.play(PlayableItem(url: URL(fileURLWithPath: args[3])))
    Thread.sleep(forTimeInterval: 1.5)
    report("playing")
    DeviceControl.setHardwareVolume(device.id, target)
    Thread.sleep(forTimeInterval: 0.5)
    report("set to \(target)")
    Thread.sleep(forTimeInterval: 2)
    engine.pause()
    Thread.sleep(forTimeInterval: 0.5)
    report("paused")
    var t = 0.0
    while t < pause { Thread.sleep(forTimeInterval: 1); t += 1; if Int(t) % 3 == 0 { report(String(format: "paused %.0fs", t)) } }
    engine.resume()
    Thread.sleep(forTimeInterval: 1.5)
    report("resumed")
    Thread.sleep(forTimeInterval: 2)
    report("resumed +2s")
    engine.stop()
    Thread.sleep(forTimeInterval: 0.6)
    report("stopped")
    exit(0)
}

/// Whether the device's I/O is running (for any process).
func isRunning(_ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var running = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr && running != 0
}

/// A DSD64 DSF of soft pings at `hz`, one on every whole second, with DSD silence between. One second of the modulator's
/// output (a second-order sigma-delta, as vespertine-demo uses), repeated; the same bits in both channels.
func writePingDSF(to url: URL, hz: Double, seconds: Int) throws {
    let rate = 2_822_400, blockSize = 4096
    var second = [UInt8](repeating: 0, count: rate / 8)
    var v1 = 0.0, v2 = 0.0, y = 0.0
    for pass in 0..<2 {                                   // the kept pass starts where a whole second leaves the loop
        for i in 0..<rate {
            let t = Double(i) / Double(rate)
            var x = 0.0
            if t < 0.5 {                                  // a 3 ms attack, a 60 ms decay, about -14 dB
                let envelope = exp(-t / 0.06) * min(1, t / 0.003)
                x = 0.1 * envelope * sin(2 * Double.pi * hz * t)
            }
            v1 += x - y
            v2 += v1 - y
            y = v2 >= 0 ? 1 : -1
            if pass == 1, y > 0 { second[i >> 3] |= UInt8(1 << (i & 7)) }   // LSB first
        }
    }
    let bytesPerChannel = rate / 8 * seconds
    let blocks = (bytesPerChannel + blockSize - 1) / blockSize
    var channel = [UInt8]()
    channel.reserveCapacity(blocks * blockSize)
    while channel.count < bytesPerChannel { channel += second.prefix(bytesPerChannel - channel.count) }
    channel += [UInt8](repeating: 0x69, count: blocks * blockSize - channel.count)
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let dataBytes = UInt64(blocks * blockSize * 2)
    data.append(contentsOf: Array("DSD ".utf8)); u64(28); u64(28 + 52 + 12 + dataBytes); u64(0)
    data.append(contentsOf: Array("fmt ".utf8)); u64(52); u32(1); u32(0); u32(2); u32(2); u32(UInt32(rate)); u32(1)
    u64(UInt64(rate * seconds)); u32(UInt32(blockSize)); u32(0)
    data.append(contentsOf: Array("data".utf8)); u64(12 + dataBytes)
    for b in 0..<blocks {
        let block = channel[b * blockSize ..< (b + 1) * blockSize]
        data.append(contentsOf: block); data.append(contentsOf: block)
    }
    try data.write(to: url)
}

if args.count >= 3, args[1] == "doptest" {
    // doptest <device> [a.dsf b.dsf]: plays DSD over DoP and pauses, seeks and skips on a schedule, saying what to listen
    // for at each step. Without files it writes two DSD64 ping files (a ping on every whole second, silence between: each
    // step lands in the silence, so a click is the DAC dropping out of DSD, not the music being cut).
    // VESPERTINE_RELEASE_AFTER=<seconds> (default 15): the pause after which the device is let go (the last step).
    guard let device = devices.first(where: { $0.uid == args[2] || $0.name.localizedCaseInsensitiveContains(args[2]) }) else {
        print("no device matching \(args[2])"); exit(1)
    }
    var files = args.dropFirst(3).map { URL(fileURLWithPath: $0) }
    if files.isEmpty {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-doptest", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        files = [folder.appendingPathComponent("ping-880Hz.dsf"), folder.appendingPathComponent("ping-660Hz.dsf")]
        print("Writing two DSD64 test files to \(folder.path) …")
        do {
            try writePingDSF(to: files[0], hz: 880, seconds: 40)
            try writePingDSF(to: files[1], hz: 660, seconds: 20)
        } catch { print("couldn't write the test files: \(error)"); exit(1) }
    }
    if files.count == 1 { files.append(files[0]) }
    let release = Double(ProcessInfo.processInfo.environment["VESPERTINE_RELEASE_AFTER"] ?? "") ?? 15
    let a = PlayableItem(url: files[0]), b = PlayableItem(url: files[1])
    let engine = PlaybackEngine()
    var settings = EngineSettings()
    settings.deviceUID = device.uid
    settings.exclusive = true
    settings.dopDeviceUIDs = [device.uid]
    settings.releaseExclusiveAfterPause = release
    engine.update(settings: settings)
    engine.nextItemProvider = { $0.id == a.id ? b : nil }
    let t0 = Date()
    func stamp() -> String { String(format: "%6.1fs", Date().timeIntervalSince(t0)) }
    engine.eventHandler = { event in
        let t = String(format: "%6.1fs", Date().timeIntervalSince(t0))
        switch event {
        case .trackStarted(let item): print("\(t)    (now playing \(item.url.lastPathComponent))")
        case .failed(_, let m): print("\(t)    ✗ \(m)")
        default: print("\(t)    event \(event)")
        }
    }
    var failures: [String] = []
    func state() -> String {
        let s = engine.snapshot, hw = readback(device.id)
        return String(format: "position %.2fs · device running: %@ · hog: %@ · underruns %ld", s.position, isRunning(device.id) ? "yes" : "no",
                      hw.hogPID == getpid() ? "us" : hw.hogPID == -1 ? "none" : String(hw.hogPID), s.underruns)
    }
    func step(_ what: String, listen: String) { print("\n\(stamp()) ▶ \(what)\n           listen: \(listen)") }
    func note(_ text: String) { print("\(stamp())    \(text)") }
    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    /// Plays on until `item` reaches `position` (track time), or `timeout` passes.
    func playUntil(_ position: Double, of item: PlayableItem, timeout: Double = 20) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let s = engine.snapshot
            if s.state == .playing, s.item?.id == item.id, s.position >= position { return }
            pump(0.01)
        }
        note("(didn't reach \(position) s in \(Int(timeout)) s: \(state()))")
    }
    func expectRunning(_ running: Bool, _ why: String) {
        let now = isRunning(device.id)
        note("device running: \(now ? "yes" : "no") (expected \(running ? "yes" : "no"): \(why))")
        if now != running { failures.append("\(why): device running \(now ? "yes" : "no")") }
    }

    print("Device: \(device.name). Turn its volume down first: DoP can't be made quieter digitally (the pings are soft).")
    step("Play \(files[0].lastPathComponent)", listen: "a soft ping on every second, nothing else")
    engine.play(a)
    playUntil(2.6, of: a)
    guard let path = engine.snapshot.signalPath, path.plan.mode == .dop else {
        print("Not playing as DoP (\(engine.snapshot.signalPath?.statusLine ?? engine.snapshot.lastError ?? "no signal path")). Check the DAC takes DoP at \(SampleRate.format(176_400)) kHz.")
        engine.stop(); pump(0.6); exit(1)
    }
    note("\(path.statusLine) · \(SampleRate.format(path.applied.sampleRate)) kHz · \(state())")

    step("Pause for 2 s, then resume", listen: "no click at the pause or the resume; the next ping arrives on time")
    engine.pause(); pump(1)
    expectRunning(true, "paused DoP keeps sending DSD silence")
    pump(1); engine.resume()
    playUntil(5.6, of: a)

    step("Pause for 8 s, then resume", listen: "the same: silence, no click, no missing ping after the resume")
    engine.pause(); pump(4); note(state()); pump(4); engine.resume()
    playUntil(8.6, of: a)

    step("Seek forward to 20.6 s while playing", listen: "no click; the pings go on")
    engine.seek(to: 20.6); pump(0.3)
    expectRunning(true, "a DoP seek keeps the device running")
    playUntil(23.6, of: a)

    step("Pause, seek back to 5.6 s while paused, then resume", listen: "no click at any of the three")
    engine.pause(); pump(1); engine.seek(to: 5.6); pump(1.5)
    expectRunning(true, "seeking while paused keeps the DoP device running")
    engine.resume()
    playUntil(8.6, of: a)

    step("Skip to \(files[1].lastPathComponent)", listen: "the ping changes pitch (lower) with no click")
    engine.play(b); pump(0.3)
    expectRunning(true, "a skip between DoP tracks of the same rate keeps the device running")
    playUntil(3.6, of: b)

    step("Skip back to \(files[0].lastPathComponent)", listen: "back to the higher ping, no click")
    engine.play(a)
    playUntil(2.6, of: a)

    step("Five quick pauses, one between each ping", listen: "no clicks, no stutter, every ping")
    for k in 0..<5 { engine.pause(); pump(0.4); engine.resume(); playUntil(3.6 + Double(k), of: a) }

    let duration = engine.snapshot.duration
    if duration > 8 {
        step("Let \(files[0].lastPathComponent) run out into \(files[1].lastPathComponent) (gapless)", listen: "no click where the track changes")
        engine.seek(to: duration - 3.4)
        playUntil(2.6, of: b, timeout: 15)
    }

    step("Pause for \(Int(release)) s + 4 s, past the release time", listen: "silence; the device is let go after \(Int(release)) s, so ONE click or a short delay on this resume is expected")
    engine.pause(); pump(min(5, release / 2))
    expectRunning(true, "still within the release time")
    pump(release - min(5, release / 2) + 4)
    let owner = readback(device.id).hogPID
    note("hog: \(owner == getpid() ? "us" : owner == -1 ? "none" : String(owner)) (expected none: let go after \(Int(release)) s) · \(state())")
    if owner == getpid() { failures.append("still holding the device \(Int(release) + 4) s into a pause") }
    engine.resume()
    pump(3)
    note(state())

    step("Stop", listen: "one click here is fine (DoP ends)")
    engine.stop(); pump(0.8)
    note(state())
    print(failures.isEmpty ? "\nDevice checks passed. Underruns: \(engine.snapshot.underruns). Anything you heard besides the expected click(s) is a finding."
                           : "\nDevice checks FAILED:\n" + failures.map { "  - \($0)" }.joined(separator: "\n"))
    exit(failures.isEmpty ? 0 : 1)
}

/// VESPERTINE_AGGREGATE=uid1,uid2,… makes a private aggregate of those devices (a multichannel output
/// for testing without a receiver); it disappears when the probe exits.
var aggregateID: AudioObjectID = 0
if let list = ProcessInfo.processInfo.environment["VESPERTINE_AGGREGATE"], args.count >= 5, args[1] == "play" {
    let uids = list.split(separator: ",").map(String.init)
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Vespertine Test Aggregate",
        kAudioAggregateDeviceUIDKey: "org.szeremeta.vespertine.test-aggregate.\(getpid())",
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceMainSubDeviceKey: uids[0],
        kAudioAggregateDeviceSubDeviceListKey: uids.enumerated().map { i, uid in
            [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: i == 0 ? 0 : 1] as [String: Any]
        },
    ]
    let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID)
    print("aggregate: status \(status) id \(aggregateID)")
    Thread.sleep(forTimeInterval: 1.5)
    atexit { if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) } }
}
let devicesNow = aggregateID != 0 ? OutputDevices.list() : devices

guard args.count >= 5, args[1] == "play" else { print("usage: vespertine-probe play <device> <seconds> <file>…"); exit(2) }
guard let device = devicesNow.first(where: { $0.uid == args[2] || $0.name.localizedCaseInsensitiveContains(args[2]) }) else {
    print("no device matching \(args[2])"); exit(1)
}
print("device: \(device.name) · \(device.capabilities.outputChannels) output channels · speaker layout \(device.capabilities.speakerLayoutChannels.map(String.init) ?? "none")")
let seconds = Double(args[3]) ?? 3
// VESPERTINE_SPATIAL=off|fixed|headTracked forces the multichannel mode for this device.
let forcedSpatial = ProcessInfo.processInfo.environment["VESPERTINE_SPATIAL"].flatMap(SpatialMode.init(rawValue:))
let items = args[4...].map { PlayableItem(url: URL(fileURLWithPath: $0)) }
let engine = PlaybackEngine()
var settings = EngineSettings()
settings.deviceUID = device.uid
settings.exclusive = true
if let forcedSpatial { settings.spatialModes[device.uid] = forcedSpatial }
engine.update(settings: settings)
let queue = items
engine.nextItemProvider = { finished in
    guard let i = queue.firstIndex(where: { $0.id == finished.id }), i + 1 < queue.count else { return nil }
    return queue[i + 1]
}
print("device: \(device.name) · before: \(readback(device.id))")

// Play each file for `seconds` (by seeking the next one in), reporting what the hardware actually does.
for (index, item) in items.enumerated() {
    engine.play(item)
    Thread.sleep(forTimeInterval: min(1.2, seconds))
    let snap = engine.snapshot
    let hw = readback(device.id)
    let path = snap.signalPath
    let name = item.url.lastPathComponent
    print(String(format: "%2d. %@", index + 1, name))
    if let path {
        print("    source \(path.source.codec) \(path.source.shortDescription) → plan \(SampleRate.format(path.plan.deviceSampleRate))k/\(path.plan.physicalBitDepth)b \(path.plan.mode.rawValue)\(path.plan.resamples ? " SRC" : "")\(path.plan.dsdConvertedToPCM ? " DSD→PCM" : "")")
        print("    applied \(path.deviceFormatShort) excl=\(path.applied.exclusive) · HW readback rate \(SampleRate.format(hw.rate))k phys \(hw.physical) hog=\(hw.hogPID == getpid() ? "us" : String(hw.hogPID))")
        print("    verdict: \(path.statusLine)\(path.isBitPerfect ? " ✓" : "") · \(path.plan.reason)")
    } else {
        print("    no signal path (state \(snap.state.rawValue)) error: \(snap.lastError ?? "-")")
    }
    if forcedSpatial != nil, let path, path.plan.spatial != .off {
        // Which speaker of the bed each decoded channel reached (meters sit before the spatial mixer).
        _ = engine.takeChannelPeaks()
        Thread.sleep(forTimeInterval: 0.5)
        let peaks = engine.takeChannelPeaks()
        let names = path.applied.channelNames
        let lit = peaks.enumerated().filter { $0.element > 0.003 }.map { "\($0.offset < names.count ? names[$0.offset] : "\($0.offset + 1)") \(String(format: "%.0f", 20 * log10($0.element))) dB" }
        print("    bed \(names.joined(separator: " ")) · sounding: \(lit.isEmpty ? "nothing" : lit.joined(separator: ", "))")
    }
    Thread.sleep(forTimeInterval: max(0, seconds - 1.7))
    let after = engine.snapshot
    print(String(format: "    position %.2fs, state %@, underruns %d", after.position, after.state.rawValue, after.underruns))
}
engine.stop()
Thread.sleep(forTimeInterval: 0.6)
let end = readback(device.id)
print("after stop: rate \(SampleRate.format(end.rate))k · hog released: \(end.hogPID == -1)")
