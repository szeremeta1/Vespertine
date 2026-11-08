//
// Vespertine — room measurement: finds the microphone and the output, runs the measurement state machine, writes
// everything it learns to ~/Documents/Vespertine Room Measurements/<timestamp>/ (under the data directory in isolated
// QA runs) and designs a room correction profile
// from the result (offered for saving; nothing plays through it until it is saved and switched on).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import Observation
import VespertineAudio

@Observable
@MainActor
final class RoomMeasureModel {
    enum Phase: String { case ready, running, needsAttention, waitingForMic, finished, failed, cancelled }

    struct StepRow: Identifiable {
        enum Status { case pending, active, done, problem }
        let step: RoomMeasurementStep
        var status: Status
        var id: RoomMeasurementStep { step }
    }

    /// Where the calibration file was last chosen from (remembered), else the UMIK-1 folder in Documents.
    static var defaultCalibration: String {
        UserDefaults.standard.string(forKey: "roomCalibrationPath") ?? "~/Documents/UMIK-1/"
    }

    /// Where measurement folders go: Documents, or the data directory of an isolated QA run (`-VespertineDataDirectory`).
    static var measurementsRoot: URL {
        if let data = LaunchArguments().string(forKey: "VespertineDataDirectory") {
            return URL(fileURLWithPath: (data as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("Room Measurements", isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vespertine Room Measurements", isDirectory: true)
    }

    @ObservationIgnored let launch: RoomMeasureLaunch?
    var phase = Phase.ready
    var headline = String(localized: "Ready to measure")
    var detail = String(localized: "Place the UMIK-1 at your listening position pointing up, then start. The speakers will play quiet sweeps that rise only as far as needed.")
    var issues: [String] = []
    var steps: [StepRow] = []
    var recordingProgress = 0.0
    var deviceLines: [String] = []
    var folder: URL?
    var plot: NSImage?
    var calibrationPath: String
    /// Microphone positions around the seat (the first is the seat itself).
    var positions = RoomMeasureLaunch.maxPositions
    /// The speakers measured: stereo, or 5.1 on an output with six channels or more.
    var layout = RoomLayout.stereo
    var simulate = false
    var attempt = 1
    /// The profile designed from a completed run, until it is saved or discarded.
    var draft: RoomProfile?
    /// The output to measure (Vespertine's own); nil or not connected: the Mac's default output.
    @ObservationIgnored var preferredOutputUID: String?
    /// Pauses Vespertine's playback before the measurement takes the output.
    @ObservationIgnored var pausePlayback: (@MainActor () -> Void)?
    /// A speaker group to measure instead of a single output: the group, and its members as Core Audio lists them, in the group's
    /// order. nil for a single output. The layout and channel map then come from the group, not from the picker.
    @ObservationIgnored var groupTarget: (group: SpeakerGroup, members: [OutputDevice])?
    /// Why the group can't be measured now (a member isn't connected), shown when the measurement starts.
    @ObservationIgnored var groupProblem: String?
    /// Seconds of the group's settle left, while it plays before the first sweep.
    var settleRemaining: Int?
    /// Called with the group once its followers' skew and rate have been measured: the app saves it (`SpeakerGroupStore.upsert`).
    @ObservationIgnored var groupMeasured: (@MainActor (SpeakerGroup) -> Void)?
    /// What the skew step found, one line each (what was kept, what could not be measured or checked), shown with the other device lines.
    var skewLines: [String] = []
    @ObservationIgnored private var holdStarted = Date()

    @ObservationIgnored private var controller: RoomMeasurementController?
    @ObservationIgnored private var capture: RoomCaptureSession?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var autoRetries = 0
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var calibration: MicCalibration?
    @ObservationIgnored private var speakers: [RoomSpeaker] = []
    @ObservationIgnored private var outputName = ""
    @ObservationIgnored private var micSerial = ""
    @ObservationIgnored private var groupOutput: GroupMeasurementOutput?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        launch = RoomMeasureLaunch.parse(arguments)
        calibrationPath = launch?.calibrationPath ?? Self.defaultCalibration
        positions = launch?.positions ?? RoomMeasureLaunch.maxPositions
        simulate = launch?.simulate ?? false
    }

    var isBusy: Bool { phase == .running }

    /// Starts a run if, and only if, the app was launched with `--room-measure`. Does nothing the second time.
    func startIfLaunched() {
        guard let launch, !launched else { return }
        launched = true
        NSApp.activate(ignoringOtherApps: true)
        start(micName: launch.micName)
    }

    // MARK: Actions

    func start(micName: String = "UMIK") {
        guard !isBusy else { return }
        issues = []
        plot = nil
        draft = nil
        pausePlayback?()
        phase = .running
        headline = String(localized: "Getting ready")
        detail = ""
        runTask = Task { [weak self] in await self?.setUpAndRun(micName: micName) }
    }

    func retry() {
        guard let controller, phase == .needsAttention || phase == .cancelled else { return }
        issues = []
        phase = .running
        runTask = Task { [weak self] in await self?.drive(controller) }
    }

    func micMoved() {
        guard let controller, phase == .waitingForMic else { return }
        controller.confirmMicMoved()
        phase = .running
        runTask = Task { [weak self] in await self?.drive(controller) }
    }

    func cancel() {
        controller?.cancel()
        // Before the controller exists the group is still settling; stopping that ends the run.
        if controller == nil { runTask?.cancel() }
    }

    /// Lets go of the group's aggregate and its members, if a group is being measured. Safe to call again.
    func releaseGroup() {
        groupOutput?.release()
        groupOutput = nil
        settleRemaining = nil
    }

    /// Back to the start, ready for another measurement (anything running is cancelled first).
    func reset() {
        controller?.cancel()
        runTask?.cancel()
        pollTask?.cancel()
        releaseGroup()
        controller = nil
        capture = nil
        phase = .ready
        headline = String(localized: "Ready to measure")
        detail = ""
        issues = []
        steps = []
        deviceLines = []
        skewLines = []
        folder = nil
        plot = nil
        draft = nil
        attempt = 1
        autoRetries = 0
    }

    func chooseCalibration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.directoryURL = URL(fileURLWithPath: (Self.defaultCalibration as NSString).expandingTildeInPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            calibrationPath = url.path
            UserDefaults.standard.set(url.path, forKey: "roomCalibrationPath")
        }
    }

    func revealFolder() { if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }

    // MARK: Set up

    private func fail(_ message: String) {
        releaseGroup()
        phase = .failed
        headline = String(localized: "Can't measure yet")
        detail = message
        writeStatus(message: message)
    }

    private func setUpAndRun(micName: String) async {
        // Devices.
        let mic: RoomAudioDevice, output: RoomAudioDevice
        var groupSetup: GroupMeasurement.Setup?
        if simulate {
            mic = RoomAudioDevice(id: 1, name: "Simulated microphone", uid: "sim-mic", channels: 1, nominalRate: 48_000)
            output = RoomAudioDevice(id: 2, name: "Simulated speakers", uid: "sim-out", channels: 2, nominalRate: 48_000)
        } else {
            guard let found = RoomDeviceDirectory.inputDevice(named: micName) else {
                return fail(String(localized: "No microphone named “\(micName)” is connected. Plug in the UMIK-1 and try again."))
            }
            mic = found
            if let target = groupTarget {
                // A speaker group: measured as its own layout, on its own outputs, through a private aggregate of its members.
                switch GroupMeasurement.setup(for: target.group) {
                case .failure(let problem): return fail(problem.description)
                case .success(let setup):
                    guard let members = target.members.first else { return fail(groupProblem ?? "The group's outputs aren't all connected.") }
                    let measuringRate: Double
                    do { measuringRate = try CoreAudioRoomDevice.measurementRate(inputDevice: mic.id, outputDevice: members.id) }
                    catch { return fail(String(localized: "\(mic.name) can't be recorded for this measurement: \(error.localizedDescription)")) }
                    do {
                        let opened = try GroupMeasurementOutput.open(group: target.group, devices: target.members, rate: measuringRate)
                        groupOutput = opened
                        try opened.startHold()
                        holdStarted = Date()
                        output = RoomAudioDevice(id: opened.deviceID, name: target.group.name, uid: setup.deviceUID, channels: opened.channels, nominalRate: measuringRate)
                    } catch {
                        return fail("The group couldn't be opened for the measurement: \(error.localizedDescription)")
                    }
                    groupSetup = setup
                    layout = setup.layout
                }
            } else {
                guard let out = preferredOutputUID.flatMap(RoomDeviceDirectory.output(uid:)) ?? RoomDeviceDirectory.defaultOutput() else {
                    return fail(String(localized: "There is no default output device."))
                }
                output = out
            }
        }
        let needed = groupSetup?.outputsNeeded ?? layout.speakers.count
        guard output.channels >= needed else {
            return fail(String(localized: "\(output.name) has \(output.channels) output channel(s); this measurement needs \(needed)."))
        }
        let outputRate = output.nominalRate
        guard outputRate >= 8_000 else { return fail(String(localized: "Couldn't read the sample rate of \(output.name).")) }
        // The measurement runs at a rate the microphone supports (a UMIK-1 only does 48 kHz), not at the output's: the
        // output keeps its rate and the stimulus is converted to it.
        let rate: Double
        if simulate {
            rate = outputRate
        } else if groupSetup != nil {
            rate = outputRate   // the group was opened at the rate the microphone records at
        } else {
            do { rate = try CoreAudioRoomDevice.measurementRate(inputDevice: mic.id, outputDevice: output.id) }
            catch { return fail(String(localized: "\(mic.name) can't be recorded for this measurement: \(error.localizedDescription)")) }
        }

        // Calibration file.
        let path = (calibrationPath as NSString).expandingTildeInPath
        let cal: MicCalibration
        do { cal = try MicCalibration.parse(try Data(contentsOf: URL(fileURLWithPath: path))) }
        catch { return fail(String(localized: "The calibration file at \(path) couldn't be read: \(error.localizedDescription) Choose the UMIK-1's calibration file (90° for a microphone pointing up).")) }
        calibration = cal
        let serial = cal.serial ?? URL(fileURLWithPath: path).lastPathComponent.split(separator: "_").first.map(String.init) ?? "unknown"

        // Folder, session, controller.
        let stamp = Self.timestamp()
        let root = Self.measurementsRoot
        let folder = root.appendingPathComponent(stamp, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return fail(String(localized: "Couldn't create \(folder.path): \(error.localizedDescription)")) }
        self.folder = folder
        try? Data(contentsOf: URL(fileURLWithPath: path)).write(to: folder.appendingPathComponent("microphone-calibration.txt"))

        var settings = RoomMeasurementSettings(inputDevice: mic.id, outputDevice: output.id)
        settings.sampleRate = rate
        settings.positions = positions
        settings.referenceSpeaker = groupSetup?.referenceSpeaker
        let session = RoomSession(id: UUID(), createdAt: Date(), deviceUID: groupSetup?.deviceUID ?? output.uid, layout: layout,
                                  channelMap: groupSetup?.channelMap ?? .standard(layout),
                                  mic: cal.mic(orientation: .upward), target: RoomFilterDesignOptions.default.target.roomTarget)
        outputName = output.name
        micSerial = serial
        speakers = session.channelMap.entries.sorted { $0.output < $1.output }.map(\.speaker)
        let device: RoomCaptureDevice = simulate ? SimulatedRoomDevice() : CoreAudioRoomDevice()
        let permission: MicrophonePermission = simulate ? AlwaysGrantedMicrophone() : SystemMicrophonePermission()
        let captureSession = RoomCaptureSession(device: device, permission: permission, pollInterval: 0.02, stallTimeout: 5)
        capture = captureSession
        let controller = RoomMeasurementController(settings: settings, session: session, capturer: captureSession, folder: folder) { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        self.controller = controller
        steps = Self.plan(speakers: speakers, positions: positions).map { StepRow(step: $0, status: .pending) }
        deviceLines = [
            String(localized: "Microphone: \(mic.name) (serial \(serial), \(Int(cal.points.count)) calibration points, mic pointing up)"),
            groupSetup != nil
                ? "Output: the group \(output.name) at \(Int(outputRate)) Hz, \(needed) channels on its outputs in the group's order; timing tones from \(groupSetup?.referenceSpeaker.rawValue ?? "the leader") on the clock leader"
                : String(localized: "Output: \(output.name) at \(Int(outputRate)) Hz, speakers on channels 1–\(needed) in the standard order (unverified wiring)"),
            String(localized: "Measuring at \(Int(rate)) Hz, the rate the microphone records at; the output keeps its own rate."),
            String(localized: "Saving to \((folder.path as NSString).abbreviatingWithTildeInPath)"),
        ]
        try? "\(folder.path)\n".write(to: root.appendingPathComponent("last-run.txt"), atomically: true, encoding: .utf8)
        startPolling()
        if groupSetup != nil, !(await settle()) { return }
        if groupSetup != nil, !simulate, let target = groupTarget, let held = groupOutput {
            if !(await measureMemberSkew(group: target.group, output: held, outputID: output.id, micID: mic.id, rate: rate)) { return }
        }
        await drive(controller)
    }

    /// The skew step of a group's measurement: each follower's delay against the clock leader and its rate while drift-corrected, from the
    /// timing chirps through the same microphone and aggregate as the sweeps (`GroupSkewMeasurement`). Written into the group and saved
    /// through `groupMeasured`. A follower that can't be timed is left as it was and said so; the sweeps go on. False when stopped meanwhile.
    private func measureMemberSkew(group: SpeakerGroup, output held: GroupMeasurementOutput, outputID: UInt32, micID: UInt32, rate: Double) async -> Bool {
        skewLines = []
        let started = holdStarted
        let capture: GroupSkewMeasurement.Capture = { layout, leaderChannel, followerChannel, span in
            let device = GroupSkewDevice(inner: CoreAudioRoomDevice(), leaderChannel: leaderChannel, followerChannel: followerChannel, control: false, span: span)
            let session = RoomCaptureSession(device: device, permission: SystemMicrophonePermission(), pollInterval: 0.02, stallTimeout: 5)
            let request = RoomCaptureRequest(inputDevice: micID, outputDevice: outputID, inputChannel: 0, outputChannel: followerChannel, referenceChannel: leaderChannel, layout: layout)
            return try await session.record(request).samples
        }
        headline = "Timing the DACs against each other"
        let outcome = await GroupSkewMeasurement.run(group: group, rate: rate, corrected: held.correctedMemberUIDs,
                                                      secondsSinceOutputStarted: { Date().timeIntervalSince(started) }, capture: capture) { [weak self] line in
            Task { @MainActor in self?.detail = line }
        }
        if Task.isCancelled { reset(); return false }
        for done in outcome.outcomes {
            skewLines.append(String(format: "%@ sounds %.2f ms after the leader (%d good captures, spread %.1f frames)%@",
                                    done.followerName, done.group.members.first { $0.name == done.followerName }?.skewMs ?? 0, done.goodRuns, done.spreadFrames,
                                    done.rateTrimPPM.map { String(format: ", and falls behind %+.1f ppm while it plays", $0) } ?? ""))
            skewLines.append(contentsOf: done.notes)
        }
        skewLines.append(contentsOf: outcome.failures)
        if let last = outcome.outcomes.last { groupMeasured?(last.group) }
        return true
    }

    /// The group plays silence for `GroupMeasurement.settleSeconds` before the first sweep, so the followers' drift correction has
    /// settled. False when stopped meanwhile.
    private func settle() async -> Bool {
        let total = Int(GroupMeasurement.settleSeconds)
        for left in stride(from: total, through: 1, by: -1) {
            if Task.isCancelled { break }
            settleRemaining = left
            headline = "Letting the speakers settle"
            detail = "The group plays silence for \(total) seconds so the second DAC is in step with the first. \(left) s left."
            try? await Task.sleep(for: .seconds(1))
        }
        settleRemaining = nil
        if Task.isCancelled {
            // Nothing was captured: back to the start, with the group let go (a retry would play to an aggregate that is gone).
            reset()
            return false
        }
        return true
    }

    static func plan(speakers: [RoomSpeaker], positions: Int) -> [RoomMeasurementStep] {
        [.levelCheck] + speakers.map { .routeCheck($0) } + (0..<positions).flatMap { p in speakers.map { .sweep($0, p) } }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: Run

    private func drive(_ controller: RoomMeasurementController) async {
        var end = await controller.run()
        // Unattended (started from the command line): problems that can pass by themselves get a few more tries.
        while launch != nil, case .needsAttention(_, let found) = end, autoRetries < 4, found.allSatisfy(Self.transient) {
            autoRetries += 1
            try? await Task.sleep(for: .seconds(2))
            end = await controller.run()
        }
        await finish(end)
    }

    private static func transient(_ issue: RoomMeasurementIssue) -> Bool {
        switch issue {
        case .quality(.noisy), .quality(.referenceMissing), .quality(.referenceAmbiguous), .quality(.excessiveDrift): true
        case .capture(.framesLost), .capture(.stalled): true
        default: false
        }
    }

    private func finish(_ end: RoomMeasurementState) async {
        switch end {
        case .completed:
            await publishResults()
        case .needsAttention(_, let found), .failed(_, let found):
            issues = found.map(\.message)
            if case .failed = end { phase = .failed; headline = String(localized: "This step kept failing") }
            else { phase = .needsAttention; headline = String(localized: "Needs a look") }
            detail = String(localized: "Fix the cause, then try again.")
        case .waitingForMic(let p):
            phase = .waitingForMic
            headline = String(localized: "Move the microphone to position \(p + 1)")
            detail = String(localized: "Keep it pointing up, then continue.")
        case .cancelled:
            phase = .cancelled
            headline = String(localized: "Cancelled")
            detail = String(localized: "Nothing from the cancelled capture was kept as a measurement. You can carry on from where it stopped.")
        case .idle, .running:
            break
        }
        recordingProgress = 0
        updateSteps(end)
        writeStatus(message: headline)
    }

    private func stateChanged(_ state: RoomMeasurementState) {
        updateSteps(state)
        if case .running(let step, let n) = state {
            attempt = n
            headline = Self.title(step)
            detail = n > 1 ? String(localized: "Try \(n)") : ""
            writeStatus(message: headline)
        }
    }

    private func updateSteps(_ state: RoomMeasurementState) {
        let done = Set((controller?.log ?? []).filter(\.accepted).map(\.step))
        steps = steps.map { row in
            var r = row
            r.status = done.contains(row.step) ? .done : .pending
            switch state {
            case .running(let s, _) where s == row.step: r.status = .active
            case .needsAttention(let s, _) where s == row.step, .failed(let s, _) where s == row.step: r.status = .problem
            case .cancelled(let s) where s == row.step: r.status = .pending
            case .completed: r.status = .done
            default: break
            }
            return r
        }
    }

    static func title(_ step: RoomMeasurementStep) -> String {
        switch step {
        case .levelCheck: String(localized: "Checking the level")
        case .routeCheck(let s): String(localized: "Checking the \(s.rawValue) speaker reaches the microphone")
        case .sweep(let s, let p): String(localized: "Measuring the \(s.rawValue) speaker, position \(p + 1)")
        }
    }

    static func rowTitle(_ step: RoomMeasurementStep) -> String {
        switch step {
        case .levelCheck: String(localized: "Level check")
        case .routeCheck(let s): String(localized: "Route check, \(s.rawValue)")
        case .sweep(let s, let p): String(localized: "Sweep, \(s.rawValue), position \(p + 1)")
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let capture = self.capture else { continue }
                if case .recording(let n, let total) = capture.state, total > 0 { self.recordingProgress = Double(n) / Double(total) }
            }
        }
    }

    // MARK: Room Portrait

    /// The microphone position being measured (or the next one), 0 = the seat.
    var currentPosition: Int {
        if let active = steps.first(where: { $0.status == .active || $0.status == .problem }), case .sweep(_, let p) = active.step { return p }
        let done = steps.filter { if case .sweep = $0.step { $0.status == .done } else { false } }
        guard let last = done.last, case .sweep(_, let p) = last.step else { return 0 }
        let complete = speakers.allSatisfy { s in done.contains { $0.step == .sweep(s, p) } }
        return complete && phase != .finished ? min(p + 1, positions - 1) : p
    }

    /// The speaker playing now, if any.
    var activeSpeaker: RoomSpeaker? {
        guard phase == .running, let active = steps.first(where: { $0.status == .active }) else { return nil }
        switch active.step {
        case .levelCheck: return speakers.first
        case .routeCheck(let s), .sweep(let s, _): return s
        }
    }

    /// Positions whose sweeps are all done.
    var measuredPositions: Set<Int> {
        Set((0..<positions).filter { p in
            !speakers.isEmpty && speakers.allSatisfy { s in steps.contains { $0.step == .sweep(s, p) && $0.status == .done } }
        })
    }

    // MARK: Results

    private func publishResults() async {
        guard let controller, let folder else { return }
        headline = String(localized: "Computing the responses")
        detail = ""
        let calibration = calibration
        let session = controller.session
        let recordings = controller.acceptedRecordings
        do {
            let name = String(localized: "\(outputName) · \(Date().formatted(date: .abbreviated, time: .shortened))", comment: "Room correction profile name: output name and when it was measured.")
            let serial = micSerial
            let (written, profile): ([RoomResponseFiles.Written], RoomProfile) = try await Task.detached(priority: .userInitiated) {
                let result = try RoomMeasurementResult.make(recordings: recordings, session: session, calibration: calibration, name: name, micSerial: serial)
                let written = try result.responses.keys.sorted().map {
                    try RoomResponseFiles.write(result.responses[$0] ?? [:], to: folder, name: "response-p\($0 + 1)")
                }
                try RoomCorrectionCoding.encode(result.profile).write(to: folder.appendingPathComponent("room-profile.json"), options: .atomic)
                try RoomCorrectionPreview(design: result.design).renderPNG(title: name)
                    .write(to: folder.appendingPathComponent("room-correction-predicted.png"), options: .atomic)
                return (written, result.profile)
            }.value
            if let first = written.first { plot = NSImage(contentsOf: first.plot) }
            draft = profile
            releaseGroup()
            phase = .finished
            headline = String(localized: "Measurement complete")
            detail = String(localized: "Raw captures, the session file, the calibrated responses and the designed profile are in the measurement folder.")
        } catch {
            phase = .failed
            headline = String(localized: "The captures were saved, but the responses couldn't be computed")
            detail = error.localizedDescription
        }
    }

    // MARK: Status file (for whoever started the run remotely)

    private func writeStatus(message: String) {
        guard let folder else { return }
        var files: [String] = []
        files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let object: [String: Any] = [
            "phase": phase.rawValue, "message": message, "issues": issues, "folder": folder.path,
            "updated": ISO8601DateFormatter().string(from: Date()), "files": files, "attempt": attempt,
            "simulated": simulate,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("status.json"), options: .atomic)
        }
    }
}
