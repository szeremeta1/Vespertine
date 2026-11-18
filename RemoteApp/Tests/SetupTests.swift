//
// Vespertine Remote: first-run setup asks only what applies to the music someone has, shows once to someone with
// nothing set up, and comes back from Settings.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemote

@Suite struct SetupSteps {
    @Test func beforeAnythingIsChosenTheStepsAreTheOnesForAMac() {
        #expect(SetupPlan.steps(source: nil, playsHere: false) == [.welcome, .music, .output, .extras, .done])
    }

    @Test func aMacIsPairedAndThenAskedWhereItPlays() {
        #expect(SetupPlan.steps(source: .mac, playsHere: false) == [.welcome, .music, .connect, .output, .extras, .done])
    }

    @Test func howItSoundsIsAskedOnlyWhenThisDevicePlays() {
        #expect(SetupPlan.steps(source: .mac, playsHere: true) == [.welcome, .music, .connect, .output, .sound, .extras, .done])
        #expect(!SetupPlan.steps(source: .demo, playsHere: false).contains(.sound))
        #expect(SetupPlan.steps(source: .demo, playsHere: true).contains(.sound))
    }

    @Test func aShareOrAFolderAlwaysPlaysHereSoNobodyIsAskedWhere() {
        for source in [SetupSource.share, .folder] {
            for playsHere in [false, true] {
                #expect(SetupPlan.steps(source: source, playsHere: playsHere) == [.welcome, .music, .connect, .sound, .extras, .done])
            }
        }
    }

    @Test func theDemoNeedsNothingConnected() {
        #expect(SetupPlan.steps(source: .demo, playsHere: false) == [.welcome, .music, .output, .extras, .done])
    }

    @Test func nextAndPreviousWalkTheSameSteps() {
        for source in [SetupSource?.none, .mac, .share, .folder, .demo] {
            for playsHere in [false, true] {
                let steps = SetupPlan.steps(source: source, playsHere: playsHere)
                for (index, step) in steps.enumerated() {
                    let next = index + 1 < steps.count ? steps[index + 1] : nil
                    let previous = index > 0 ? steps[index - 1] : nil
                    #expect(SetupPlan.next(after: step, source: source, playsHere: playsHere) == next)
                    #expect(SetupPlan.previous(before: step, source: source, playsHere: playsHere) == previous)
                }
            }
        }
    }

    @Test func aStepThatDroppedOutStillLeadsToTheNextOneThatApplies() {
        // On Sound, then the Mac is chosen to play: Sound is no longer a step, and Continue still goes to Extras.
        #expect(SetupPlan.next(after: .sound, source: .mac, playsHere: false) == .extras)
        #expect(SetupPlan.previous(before: .sound, source: .mac, playsHere: false) == .output)
    }

    @Test func theProgressBarNamesTheStepsBetweenTheWelcomeAndTheEnd() {
        #expect(SetupPlan.named(source: .mac, playsHere: true) == [.music, .output, .sound, .extras])
        #expect(SetupPlan.named(source: .share, playsHere: true) == [.music, .sound, .extras])
        #expect(SetupPlan.heading(of: .connect) == .music)
        #expect(SetupPlan.heading(of: .sound) == .sound)
    }

    @Test func stepsAndSourcesAreNamedForLaunchArguments() {
        #expect(SetupStep(name: "connect") == .connect)
        #expect(SetupStep(name: "done") == .done)
        #expect(SetupStep(name: "nowhere") == nil)
        #expect(SetupSource(rawValue: "folder") == .folder)
    }

    @Test func anOpenSessionSaysWhichSourceItIs() {
        #expect(SetupSource.of(demo: true, share: false, folder: false) == .demo)
        #expect(SetupSource.of(demo: false, share: true, folder: true) == .folder)
        #expect(SetupSource.of(demo: false, share: true, folder: false) == .share)
        #expect(SetupSource.of(demo: false, share: false, folder: false) == .mac)
    }
}

@MainActor
@Suite struct SetupShowing {
    private func emptyDefaults() -> UserDefaults {
        let name = "setup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aFirstRunIsSomeoneWithNothingSetUp() {
        #expect(SetupPlan.isFirstRun(done: false, pairings: 0, shares: 0, folders: 0))
        #expect(!SetupPlan.isFirstRun(done: true, pairings: 0, shares: 0, folders: 0))
        #expect(!SetupPlan.isFirstRun(done: false, pairings: 1, shares: 0, folders: 0))
        #expect(!SetupPlan.isFirstRun(done: false, pairings: 0, shares: 1, folders: 0))
        #expect(!SetupPlan.isFirstRun(done: false, pairings: 0, shares: 0, folders: 1))
    }

    @Test func finishingIsRemembered() {
        let defaults = emptyDefaults()
        let setup = SetupAssistant(defaults: defaults)
        #expect(!setup.isDone)
        setup.runAgain()
        #expect(setup.isShowing)
        setup.finish()
        #expect(!setup.isShowing)
        #expect(setup.isDone)
        #expect(SetupAssistant(defaults: defaults).isDone)
    }

    @Test func fromSettingsItOpensOnTheWelcomeEvenWhenDone() {
        let setup = SetupAssistant(defaults: emptyDefaults())
        setup.finish()
        setup.runAgain()
        #expect(setup.isShowing)
        #expect(setup.openingStep == .welcome)
        #expect(setup.openingSource == nil)
    }

    @Test func testAndScreenshotRunsAreNotInterrupted() {
        let defaults = emptyDefaults()
        #expect(SetupAssistant.isArranged(defaults: defaults, environment: ["XCTestConfigurationFilePath": "x"]))
        #expect(!SetupAssistant.isArranged(defaults: defaults, environment: [:]))
        defaults.set(true, forKey: "VTDemo")
        #expect(SetupAssistant.isArranged(defaults: defaults, environment: [:]))
        // The tests run in such an app, so opening it shows no setup and holds no search back.
        let setup = SetupAssistant(defaults: defaults)
        #expect(!setup.launched(pairings: 0, shares: 0, folders: 0))
        #expect(!setup.isShowing)
    }

    @Test func aLaunchArgumentOpensANamedStep() {
        let defaults = emptyDefaults()
        defaults.set("sound", forKey: "VTSetup")
        defaults.set("share", forKey: "VTSetupSource")
        let setup = SetupAssistant(defaults: defaults)
        #expect(!setup.launched(pairings: 2, shares: 0, folders: 0))
        #expect(setup.isShowing)
        #expect(setup.openingStep == .sound)
        #expect(setup.openingSource == .share)
    }
}

@Suite struct SetupTextSize {
    @Test func aPhoneFollowsTheSystemUpToTheSecondAccessibilitySize() {
        #expect(SetupFlow.textSize(system: .small, pad: false) == .small)
        #expect(SetupFlow.textSize(system: .large, pad: false) == .large)
        #expect(SetupFlow.textSize(system: .accessibility1, pad: false) == .accessibility1)
        #expect(SetupFlow.textSize(system: .accessibility5, pad: false) == .accessibility2)
    }

    @Test func anIPadStartsTwoSizesUp() {
        #expect(SetupFlow.textSize(system: .small, pad: true) == .xxLarge)
        #expect(SetupFlow.textSize(system: .large, pad: true) == .xxLarge)
        #expect(SetupFlow.textSize(system: .accessibility1, pad: true) == .accessibility1)
        #expect(SetupFlow.textSize(system: .accessibility5, pad: true) == .accessibility2)
    }
}

@Suite struct SetupPictures {
    @Test func theGlowMovesAcrossThroughTheStepsAndIsCentredAtBothEnds() {
        #expect(SetupBackdrop.glowX(.welcome) == 0.5)
        #expect(SetupBackdrop.glowX(.done) == 0.5)
        let between: [SetupStep] = [.music, .connect, .output, .sound, .extras]
        let places = between.map(SetupBackdrop.glowX)
        #expect(places == places.sorted())
        #expect(places.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func theDotsStayOnTheirWayAndFollowOneAnother() {
        for time in stride(from: -3.0, through: 12.0, by: 0.37) {
            let places = (0..<4).map { SetupFlowPicture.dotPosition(index: $0, of: 4, time: time) }
            #expect(places.allSatisfy { $0 >= 0 && $0 < 1 })
            // Evenly spaced round the loop: a quarter apart.
            let gap = (places[1] - places[0] + 1).truncatingRemainder(dividingBy: 1)
            #expect(abs(gap - 0.25) < 1e-9)
        }
        #expect(SetupFlowPicture.dotPosition(index: 0, of: 0, time: 1) >= 0)
    }
}
