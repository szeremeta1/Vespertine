//
// nocturne-probe — verifies device handling on real hardware.
//   nocturne-probe list
//   nocturne-probe play <device-name-or-uid> <seconds> <file> [file…]   (plays files in sequence, gapless where possible)
//   nocturne-probe watch <seconds>          prints every device's volume and the system output whenever they change
//   nocturne-probe pausetest <device> <file> <volume 0…1> <pause seconds> <release-after seconds>
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import NocturneAudio
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
    print("file\trate\tverdict\tconf\tcliff\tdrop\tconsist\tbelow\tabove\tfloor\text\tslope\tholes\tcontent\tbits\tshelf\tsstep\tsend\tsslope\tsabove\tscons")
    for path in args[2...] {
        let url = URL(fileURLWithPath: path)
        guard let r = try? FileAnalyzer.analyze(url: url, maxSeconds: 120), let f = r.forensics else { print("\(url.lastPathComponent)\terror"); continue }
        print(String(format: "%@\t%.0f\t%@\t%.2f\t%.0f\t%.1f\t%.2f\t%.1f\t%.1f\t%.1f\t%.0f\t%.2f\t%.3f\t%.0f\t%@\t%.0f\t%.1f\t%.0f\t%.2f\t%.1f\t%.2f",
                     url.lastPathComponent, r.sampleRate, r.verdict.rawValue, r.confidence, f.cliffHz ?? 0, f.cliffDropDB, f.cliffConsistency,
                     f.belowDB, f.aboveDB, f.floorDB, f.extensionHz, f.extensionSlope, f.holeRatio, f.contentHz,
                     r.effectiveBitDepth.map(String.init) ?? "-", f.shelfHz ?? 0, f.shelfStepDB, f.shelfEndHz, f.shelfSlope, f.shelfAboveFloorDB, f.shelfConsistency))
    }
    exit(0)
}

if args.count >= 3, args[1] == "analyze-json" {
    // One JSON line per file (compare with `nocturne-analyze file`).
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

/// NOCTURNE_AGGREGATE=uid1,uid2,… makes a private aggregate of those devices (a multichannel output
/// for testing without a receiver); it disappears when the probe exits.
var aggregateID: AudioObjectID = 0
if let list = ProcessInfo.processInfo.environment["NOCTURNE_AGGREGATE"], args.count >= 5, args[1] == "play" {
    let uids = list.split(separator: ",").map(String.init)
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Nocturne Test Aggregate",
        kAudioAggregateDeviceUIDKey: "org.nocturne.test-aggregate.\(getpid())",
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

guard args.count >= 5, args[1] == "play" else { print("usage: nocturne-probe play <device> <seconds> <file>…"); exit(2) }
guard let device = devicesNow.first(where: { $0.uid == args[2] || $0.name.localizedCaseInsensitiveContains(args[2]) }) else {
    print("no device matching \(args[2])"); exit(1)
}
print("device: \(device.name) · \(device.capabilities.outputChannels) output channels · speaker layout \(device.capabilities.speakerLayoutChannels.map(String.init) ?? "none")")
let seconds = Double(args[3]) ?? 3
// NOCTURNE_SPATIAL=off|fixed|headTracked forces the multichannel mode for this device.
let forcedSpatial = ProcessInfo.processInfo.environment["NOCTURNE_SPATIAL"].flatMap(SpatialMode.init(rawValue:))
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
    Thread.sleep(forTimeInterval: max(0, seconds - 1.2))
    let after = engine.snapshot
    print(String(format: "    position %.2fs, state %@, underruns %d", after.position, after.state.rawValue, after.underruns))
}
engine.stop()
Thread.sleep(forTimeInterval: 0.6)
let end = readback(device.id)
print("after stop: rate \(SampleRate.format(end.rate))k · hog released: \(end.hogPID == -1)")
