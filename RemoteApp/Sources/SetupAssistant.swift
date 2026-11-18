//
// Vespertine Remote: first-run setup: which steps it has for the music someone has, and whether it shows. Shown once, to
// someone with no Mac, share or folder yet, and again from Settings.
//   -VTSetup <step>            (debug builds) opens setup on welcome | music | connect | output | sound | extras | done
//   -VTSetupSource <source>    with it: mac | share | folder | demo, as if that card had been chosen
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Observation

/// Where someone's music is: what the Music step's cards choose between.
nonisolated enum SetupSource: String, CaseIterable, Sendable {
    case mac, share, folder, demo

    /// The source an open session is.
    static func of(demo: Bool, share: Bool, folder: Bool) -> SetupSource {
        if demo { return .demo }
        if folder { return .folder }
        return share ? .share : .mac
    }
}

nonisolated enum SetupStep: Int, CaseIterable, Comparable, Sendable {
    case welcome, music, connect, output, sound, extras, done

    static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }

    init?(name: String) {
        guard let step = Self.allCases.first(where: { "\($0)" == name }) else { return nil }
        self = step
    }
}

nonisolated enum SetupPlan {
    /// The steps for someone whose music is at `source`, in order. Pairing, adding a share or choosing a folder is its
    /// own step (the demo needs none). Where the music plays is asked only when a Mac could play it; how it sounds only
    /// when this device plays.
    static func steps(source: SetupSource?, playsHere: Bool) -> [SetupStep] {
        var steps: [SetupStep] = [.welcome, .music]
        let hasMac = source == nil || source == .mac || source == .demo
        if let source, source != .demo { steps.append(.connect) }
        if hasMac { steps.append(.output) }
        if !hasMac || playsHere { steps.append(.sound) }
        return steps + [.extras, .done]
    }

    static func next(after step: SetupStep, source: SetupSource?, playsHere: Bool) -> SetupStep? {
        steps(source: source, playsHere: playsHere).first { $0 > step }
    }

    static func previous(before step: SetupStep, source: SetupSource?, playsHere: Bool) -> SetupStep? {
        steps(source: source, playsHere: playsHere).last { $0 < step }
    }

    /// The steps the progress bar names. Connecting is part of Music; the welcome and the end stand outside it.
    static func named(source: SetupSource?, playsHere: Bool) -> [SetupStep] {
        steps(source: source, playsHere: playsHere).filter { $0 != .welcome && $0 != .connect && $0 != .done }
    }

    /// The named step a step belongs to.
    static func heading(of step: SetupStep) -> SetupStep { step == .connect ? .music : step }

    /// Setup shows by itself only to someone who has nothing set up: no paired Mac, no share, no folder, and nothing open.
    static func isFirstRun(done: Bool, pairings: Int, shares: Int, folders: Int) -> Bool {
        !done && pairings == 0 && shares == 0 && folders == 0
    }
}

@Observable
final class SetupAssistant {
    static let shared = SetupAssistant()
    static let doneKey = "setupDone"

    private(set) var isShowing = false
    /// The step setup opens on: the welcome, unless a launch argument names another (debug builds).
    @ObservationIgnored private(set) var openingStep = SetupStep.welcome
    @ObservationIgnored private(set) var openingSource: SetupSource?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isDone: Bool { defaults.bool(forKey: Self.doneKey) }

    /// The app opened. True when setup shows because this is a first run: the search for Macs then waits for the step
    /// that needs it, so iOS asks about the local network when the reason is on the screen.
    @discardableResult
    func launched(pairings: Int, shares: Int, folders: Int) -> Bool {
        #if DEBUG
        if let step = defaults.string(forKey: "VTSetup").flatMap(SetupStep.init(name:)) {
            openingStep = step
            openingSource = defaults.string(forKey: "VTSetupSource").flatMap(SetupSource.init(rawValue:))
            isShowing = true
            return false
        }
        // Screenshot and test runs open what their arguments name, and tests run in an app nobody set up.
        if Self.isArranged(defaults: defaults, environment: ProcessInfo.processInfo.environment) { return false }
        #endif
        guard SetupPlan.isFirstRun(done: isDone, pairings: pairings, shares: shares, folders: folders) else {
            // Someone who set the app up before setup existed is never asked.
            if !isDone, pairings + shares + folders > 0 { defaults.set(true, forKey: Self.doneKey) }
            return false
        }
        isShowing = true
        return true
    }

    /// From Settings: setup again, from its welcome.
    func runAgain() {
        openingStep = .welcome
        openingSource = nil
        isShowing = true
    }

    func finish() {
        defaults.set(true, forKey: Self.doneKey)
        isShowing = false
    }

    #if DEBUG
    nonisolated static func isArranged(defaults: UserDefaults, environment: [String: String]) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        return ["VTDemo", "VTScreen", "VTSamplePairing", "VTOpenFile", "VTBench", "VTScreenshot"].contains { defaults.object(forKey: $0) != nil }
    }
    #endif
}
