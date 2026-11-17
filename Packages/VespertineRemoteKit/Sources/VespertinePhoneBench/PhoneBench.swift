//
// Vespertine: the phone bench. Plays test songs from a folder on the phone through the phone's own player, the very
// way a folder chosen in Files is played (the folder is read as a share, its tags are read, the queue opens each song
// and lines up the next), keeps what the player puts out, and measures it: the silence and the roughness where one song
// meets the next, and how many decibels ReplayGain moves a song. No ear and no microphone: a person with neither can
// run it and read the numbers.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// What to put in the folder: one folder for each album. Songs of a folder are played in the order of their names, two
// at a time, and each pair gives one line. They should be one steady tone cut into songs (a join that is right is then
// one unbroken tone); a tone with silence put between the songs on purpose shows what the meter says about a gap. Any
// song whose file carries ReplayGain values is played alone instead, with ReplayGain off, by track and by album: a
// steady tone of seven seconds or more.
//
// What it doesn't measure: anything after the app's own mixer. iOS's mixing, a Bluetooth link and a DAC are not in the
// capture.
//

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import Foundation
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol
import VespertineShare

@MainActor
public final class PhoneBench {
    public struct Timing: Sendable {
        /// Seconds of the first song kept before a join: a longer song is entered this far from its end.
        public var lead = 3.0
        /// Seconds of the second song kept after a join.
        public var tail = 2.0
        /// Seconds let go by after a seek or a change of ReplayGain before anything is kept.
        public var settle = 0.5
        /// Seconds a level is measured over.
        public var window = 1.0

        public init() {}
    }

    public let player: PhonePlayer
    public let capture: OutputCapture
    public var timing = Timing()
    /// Lets time go by. On a phone it sleeps; a test renders that much audio into `capture` instead.
    public var pause: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Each capture is written beside the report as a WAV file.
    public var keepsCaptures = true
    /// A line about what is being done now.
    public var progress: @MainActor (String) -> Void = { _ in }

    private let folder: URL
    private let results: URL
    private let engine: AVAudioEngine
    private let taps: Bool
    private var playback: PhonePlayback?
    private var captures = 0

    /// - Parameters:
    ///   - folder: where the test songs are. `results`: where the report and the captures go (emptied first).
    ///   - taps: the bench taps the engine's mixer itself. false when whoever renders the engine feeds `capture`.
    public init(folder: URL, results: URL, engine: AVAudioEngine = AVAudioEngine(), taps: Bool = true) {
        self.folder = folder
        self.results = results
        self.engine = engine
        self.taps = taps
        player = PhonePlayer(engine: engine)
        capture = OutputCapture()
    }

    // MARK: Waiting

    /// Looks every hundredth of a second until `condition` holds; false when it never did. Counted, so a machine that
    /// stood still for a while only makes it take longer.
    private func wait(looks: Int = 2_000, _ condition: () -> Bool) async -> Bool {
        var left = looks
        while !condition() {
            if left == 0 { return false }
            left -= 1
            await pause(.milliseconds(10))
            playback?.tick()
        }
        return true
    }

    private func pass(_ seconds: Double) async {
        var left = Int((seconds * 100).rounded())
        while left > 0 {
            await pause(.milliseconds(10))
            playback?.tick()
            left -= 1
        }
    }

    // MARK: The run

    public func run() async -> BenchReport {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? manager.removeItem(at: results)
        try? manager.createDirectory(at: results, withIntermediateDirectories: true)
        let scratch = manager.temporaryDirectory.appendingPathComponent("vtbench-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: scratch) }

        var report = BenchReport(device: Self.device(), system: ProcessInfo.processInfo.operatingSystemVersionString, output: "unknown", folder: folder.lastPathComponent)

        // The folder, read the way the app reads a folder chosen in Files.
        let id = SavedFolder.prefix + "bench"
        let mac = ShareMac(id: id, name: "Bench", files: FolderFiles(at: folder), playback: FolderFiles(at: folder),
                           store: ShareStore(directory: scratch.appendingPathComponent("index", isDirectory: true)), sayings: .englishFolder)
        mac.rescanAfter = 0
        let session = RemoteSession(pairing: SavedPairing(serverID: id, name: "Bench", device: "folder", key: Data()), clientName: "Bench") { mac }
        session.connect()
        progress("reading \(folder.path)")
        let read = await wait {
            if case .failed = mac.scan { return true }
            return session.isConnected && !mac.isScanning && mac.library.scanned != nil
        }
        if case .failed(let error) = mac.scan { report.notes.append("The folder couldn't be read: \(error).") }
        guard read, mac.library.scanned != nil else {
            if report.notes.isEmpty { report.notes.append("The folder was never read.") }
            session.close()
            return finish(report)
        }
        let songs = mac.library.songs.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        report.songs = songs.count
        if songs.isEmpty { report.notes.append("No songs in \(folder.path): put a folder for each album in it.") }

        let playback = PhonePlayback(session: session, player: player, cacheDirectory: scratch.appendingPathComponent("streams", isDirectory: true))
        playback.tickInterval = .milliseconds(20)
        self.playback = playback
        if taps { capture.install(on: engine.mainMixerNode) }

        // Joins: each pair of neighbours in each folder.
        var folders: [String] = []
        var byFolder: [String: [ShareSong]] = [:]
        for song in songs {
            if byFolder[song.folder] == nil { folders.append(song.folder) }
            byFolder[song.folder, default: []].append(song)
        }
        for name in folders {
            // A song with ReplayGain values is there to be levelled, not joined.
            let album = (byFolder[name] ?? []).filter { $0.tags.replayGain == nil }
            guard album.count > 1 else { continue }
            for index in 0..<(album.count - 1) {
                guard let first = mac.catalog.tracks[album[index].id], let second = mac.catalog.tracks[album[index + 1].id] else { continue }
                progress("join \(album[index].path) > \(album[index + 1].fileName)")
                let lossy = [album[index], album[index + 1]].contains { ["MP3", "AAC"].contains($0.tags.codec.uppercased()) }
                report.joins.append(await join(first, second, folder: name.isEmpty ? "." : name, names: (album[index].fileName, album[index + 1].fileName),
                                               lossy: lossy, playback))
            }
        }

        // ReplayGain: each song that has values.
        for song in songs {
            guard let values = song.tags.replayGain, let track = mac.catalog.tracks[song.id] else { continue }
            progress("gain \(song.path)")
            report.gains.append(await gain(track, values, file: song.path, playback))
        }

        playback.replayGain = .off
        playback.stop()
        if taps { capture.remove(from: engine.mainMixerNode) }
        player.rest()
        self.playback = nil
        session.close()
        report.captureRate = capture.take().rate
        report.output = Self.output()
        return finish(report)
    }

    private func finish(_ report: BenchReport) -> BenchReport {
        try? report.json().write(to: results.appendingPathComponent("report.json"))
        try? Data(report.text.utf8).write(to: results.appendingPathComponent("report.txt"))
        return report
    }

    // MARK: A join

    private func join(_ first: TrackSummary, _ second: TrackSummary, folder: String, names: (String, String), lossy: Bool,
                      _ playback: PhonePlayback) async -> BenchReport.Join {
        var result = BenchReport.Join(folder: folder, first: names.0, second: names.1, verdict: .inconclusive, gapMilliseconds: 0, lossy: lossy, gapsElsewhere: [],
                                      captureBreaks: 0, captureSeconds: 0)
        playback.replayGain = .off
        playback.stop()
        capture.restart()
        playback.play([first, second], startAt: 0, shuffled: false)
        guard await wait({ self.player.state == .playing && self.player.duration > 0 }), let playing = playback.nowPlaying?.id else {
            result.note = playback.notice ?? "The first song never started."
            playback.stop()
            return result
        }
        // A long song is entered near its end, and what is kept starts after that.
        let length = player.duration
        if length > timing.lead + 1.5 {
            let target = length - timing.lead
            playback.seek(to: target)
            _ = await wait(looks: 500) { self.player.state == .playing && !self.player.isBuffering && self.player.position >= target && self.player.decodedAhead > 0.2 }
            await pass(timing.settle)
            capture.restart()
        }
        // The second song is the one being heard.
        let met = await wait(looks: Int((timing.lead + 30) * 100)) { playback.nowPlaying.map { $0.id != playing } ?? false }
        let joinAt = met ? capture.seconds : nil
        if met {
            let hold = min(timing.tail, max(0.3, second.duration - 0.5))
            _ = await wait(looks: Int((hold + 20) * 100)) { self.player.state == .playing && self.player.position >= hold }
            // The tap hands audio over a little after it was rendered.
            if taps { await pass(0.15) }
        } else {
            result.note = playback.notice ?? "The second song never started."
        }
        let take = capture.take()
        playback.stop()
        await pass(0.1)

        result.joinAt = joinAt
        result.captureBreaks = take.breaks.count
        result.captureSeconds = take.seconds
        result.capture = keep(take, named: "\(names.0)--\(names.1)")
        guard let joinAt else { return result }
        // Where the songs met in the capture is known to within the looks above and the tap's delay.
        let zone = max(0, joinAt - 0.75)...(joinAt + 0.5)
        guard let reading = worst(take, join: zone) else {
            result.note = "Nothing but silence was captured."
            return result
        }
        let atJoin = reading.gaps.filter { zone.contains($0.at) || zone.contains($0.at + $0.milliseconds / 1000) }
        result.gapsElsewhere = reading.gaps.filter { !atJoin.contains($0) }
        result.gapMilliseconds = atJoin.map(\.milliseconds).max() ?? 0
        result.joinResidual = reading.joinResidual
        result.elsewhereResidual = reading.elsewhereResidual
        result.toneHz = reading.toneHz
        result.joinSlip = reading.joinSlip
        result.levelStep = reading.levelStep
        let outOfStep = abs(reading.joinSlip ?? 0) > BenchReport.slipTolerance || abs(reading.levelStep ?? 0) > BenchReport.stepTolerance
        // Between lossless songs the join must be as clean as the rest. A lossy song brings its encoder's edge with it.
        let rough = lossy ? (reading.joinResidual ?? -200) > BenchReport.hardClick : reading.click
        if !atJoin.isEmpty {
            result.verdict = take.breaks.contains(where: zone.contains) ? .inconclusive : .gap
            if result.verdict == .inconclusive { result.note = "The capture skipped at the join." }
        } else if outOfStep || rough {
            result.verdict = .click
        } else if !result.gapsElsewhere.isEmpty || !take.breaks.isEmpty {
            result.note = "Silence away from the join: the song waited for its bytes, the capture skipped, or the files have it."
        } else {
            result.verdict = .gapless
        }
        return result
    }

    /// The channel that came off worst.
    private func worst(_ take: OutputCapture.Take, join: ClosedRange<Double>?) -> ToneMeter.Reading? {
        func badness(_ reading: ToneMeter.Reading) -> Double {
            reading.gaps.reduce(0) { $0 + $1.milliseconds } * 1_000 + (reading.joinResidual ?? -200) - reading.elsewhereResidual
        }
        var found: ToneMeter.Reading?
        for channel in take.channels {
            guard let reading = ToneMeter.read(channel, rate: take.rate, join: join) else { continue }
            if let have = found, badness(have) >= badness(reading) { continue }
            found = reading
        }
        return found
    }

    private func keep(_ take: OutputCapture.Take, named name: String) -> String? {
        guard keepsCaptures, take.rate > 0, !take.channels.isEmpty else { return nil }
        captures += 1
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        let file = String(format: "%02d-", captures) + safe + ".wav"
        let directory = results.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try BenchReport.wave(take.channels, rate: take.rate).write(to: directory.appendingPathComponent(file)) } catch { return nil }
        return "captures/" + file
    }

    // MARK: ReplayGain

    private func gain(_ track: TrackSummary, _ values: ReplayGain, file: String, _ playback: PhonePlayback) async -> BenchReport.Gain {
        var result = BenchReport.Gain(file: file, verdict: .skipped, trackGain: values.trackGain, trackPeak: values.trackPeak,
                                      albumGain: values.albumGain, albumPeak: values.albumPeak)
        let needed = 3 * (timing.settle + timing.window + 0.3) + 1
        playback.replayGain = .off
        playback.stop()
        playback.play([track], startAt: 0, shuffled: false)
        guard await wait({ self.player.state == .playing && self.player.duration > 0 }) else {
            result.note = playback.notice ?? "The song never started."
            playback.stop()
            return result
        }
        guard player.duration >= needed else {
            result.note = String(format: "The song is %.1f s long: %.1f s or more are needed.", player.duration, needed)
            playback.stop()
            return result
        }
        var levels: [ReplayGainChoice: (level: Double, applied: AppliedGain?)] = [:]
        for choice in [ReplayGainChoice.off, .track, .album] {
            if choice != .off {
                // The song starts again where it is, with its new gain.
                playback.replayGain = choice
                guard await wait(looks: 1_000, { self.player.state == .playing && !self.player.isBuffering && (playback.appliedGain != nil || playback.replayGainHasNothing) }) else {
                    result.note = playback.notice ?? "The song didn't carry on after ReplayGain was changed."
                    break
                }
            }
            await pass(timing.settle)
            capture.restart()
            await pass(timing.window + (taps ? 0.15 : 0))
            let take = capture.take()
            _ = keep(take, named: "\(track.title)-\(choice.rawValue)")
            guard player.state == .playing, let reading = worst(take, join: nil) else {
                result.note = "The song ended, or nothing was captured, while \(choice.rawValue) was measured."
                break
            }
            levels[choice] = (reading.level, choice == .off ? nil : playback.appliedGain)
        }
        playback.replayGain = .off
        playback.stop()
        await pass(0.1)

        guard let off = levels[.off] else { return result }
        result.offLevel = off.level
        func level(_ choice: ReplayGainChoice) -> BenchReport.Level? {
            levels[choice].map { BenchReport.Level(expected: $0.applied?.decibels ?? 0, measured: $0.level - off.level, heldByPeak: $0.applied?.heldByPeak ?? false) }
        }
        result.track = level(.track)
        result.album = level(.album)
        if let track = result.track, let album = result.album {
            let close = abs(track.measured - track.expected) <= BenchReport.gainTolerance && abs(album.measured - album.expected) <= BenchReport.gainTolerance
            result.verdict = close ? .matches : .differs
        }
        return result
    }

    // MARK: The device

    private static func device() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: system.machine) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.isEmpty ? "unknown" : machine
    }

    private static func output() -> String {
        #if os(iOS)
        if let route = PhoneAudioSession.currentRoute() { return "\(route.outputName) (\(route.portType)) at \(Int(route.sampleRate)) Hz" }
        #endif
        return "unknown"
    }
}
#endif
