//
// Vespertine verification: acceptance of the blind-written checks, and Vespertine's results.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// For every group:
// - every clean-room implementation (B, and B2 where there is one) passes every check: a check that fails on an
//   implementation written blind from the same contract is either wrong or reads the source differently, and
//   either way it can't be trusted against Vespertine until that is settled;
// - every mutant is killed by a check on one of its target requirements: a mutant that survives, or that only
//   fails checks of other requirements, shows a requirement the checks don't really test. The only exception is a
//   mutant that behaves exactly like the reference it wraps (EquivalentMutants, explained in REPORT.md): no check can
//   tell them apart, so its survival is expected, and if a check ever kills it the run fails until the entry goes;
// - Vespertine's result is reported. A failure is a finding: it is expected (withKnownIssue) only when
//   FINDINGS.md records it, so a new failure, or a recorded one that stops reproducing, fails the run.

import Contracts
import Foundation
import SpecKit
import Testing
import SpecChecks
import CleanRoomB
import CleanRoomB2
import Mutants
import VespertineAdapters

enum Groups {
    static let dopPack = Group(name: "DoP packing", checks: DoPPackChecks.all, references: [("B", BDoPPack.subject)],
                               mutants: DoPPackMutants.all, vespertine: Vespertine.dopPacker)
    static let dopStream = Group(name: "DoP output stream", checks: DoPStreamChecks.all, references: [("B", BDoPStream.subject)],
                                 mutants: DoPStreamMutants.all, vespertine: Vespertine.dopStage)
    static let float = Group(name: "Float output", checks: FloatChecks.all, references: [("B", BFloat.subject)],
                             mutants: FloatMutants.all, vespertine: Vespertine.floatOutput, unavailable: Vespertine.unavailable)
    static let integer = Group(name: "Integer output", checks: IntegerChecks.all, references: [("B", BInteger.subject)],
                               mutants: IntegerMutants.all, vespertine: Vespertine.integerOutput)
    static let rate = Group(name: "Rate planning", checks: RateChecks.all, references: [("B", BRate.subject), ("B2", B2Rate.subject)],
                            mutants: RateMutants.all, vespertine: Vespertine.ratePlanner)
    static let verdict = Group(name: "BIT-PERFECT verdict", checks: VerdictChecks.all,
                               references: [("B", BVerdict.subject), ("B2", B2Verdict.subject)],
                               mutants: VerdictMutants.all, vespertine: Vespertine.verdict)
    static let dst = Group(name: "DST decoding", checks: DSTChecks.all, references: [("reference decoder", ReferenceAnswers())],
                           mutants: DSTMutants.all, vespertine: Vespertine.dstDecoder)
}

// MARK: - Judging

func referencesPass<S>(_ check: SpecCheck<S>, in group: Group<S>) {
    for ref in group.references {
        guard let subject = ref.subject else {
            Issue.record("\(group.name): \(ref.label) hasn't been delivered")
            continue
        }
        let r = check.run(on: subject)
        #expect(r.passed, "\(ref.label) fails “\(check.name)”:\n\(describe(r))")
    }
}

func killed<S>(_ mutant: Mutant<S>, in group: Group<S>) {
    let outcome = group.outcome(of: mutant)
    #expect(outcome.ran, "\(group.name): no reference implementation to make mutant \(mutant.id) from")
    let message: Comment = """
        mutant \(mutant.id) [\(mutant.targets.joined(separator: ", "))] survived: \(mutant.summary)
        failed only elsewhere: \(outcome.failedElsewhere.isEmpty ? "nothing" : outcome.failedElsewhere.joined(separator: "; "))
        """
    if let reason = EquivalentMutants.byID[mutant.id] {
        withKnownIssue("equivalent mutant (REPORT.md): \(reason)") { #expect(outcome.killed, message) }
    } else {
        #expect(outcome.killed, message)
    }
}

func vespertineResult<S>(_ check: SpecCheck<S>, in group: Group<S>) {
    guard let subject = group.vespertine, group.notRunHere(check) == nil else { return }
    let r = check.run(on: subject)
    if let finding = KnownFindings.finding(group: group.name, check: check.name) {
        withKnownIssue("\(finding) (FINDINGS.md)") {
            #expect(r.passed, "Vespertine fails “\(check.name)”:\n\(describe(r))")
        }
    } else {
        #expect(r.passed, "Vespertine fails “\(check.name)”:\n\(describe(r))")
    }
}

// MARK: - Suites

@Suite("DoP packing") struct DoPPackAcceptance {
    @Test("Clean-room implementations pass", arguments: DoPPackChecks.all) func references(_ c: SpecCheck<any DoPPacker>) { referencesPass(c, in: Groups.dopPack) }
    @Test("Mutant is killed", arguments: DoPPackMutants.all) func mutant(_ m: Mutant<any DoPPacker>) { killed(m, in: Groups.dopPack) }
    @Test("Vespertine", .enabled(if: Vespertine.dopPacker != nil, "Vespertine's DoP packer is macOS-only"), arguments: DoPPackChecks.all)
    func vespertine(_ c: SpecCheck<any DoPPacker>) { vespertineResult(c, in: Groups.dopPack) }
}

@Suite("DoP output stream") struct DoPStreamAcceptance {
    @Test("Clean-room implementations pass", arguments: DoPStreamChecks.all) func references(_ c: SpecCheck<any DoPStageMaker>) { referencesPass(c, in: Groups.dopStream) }
    @Test("Mutant is killed", arguments: DoPStreamMutants.all) func mutant(_ m: Mutant<any DoPStageMaker>) { killed(m, in: Groups.dopStream) }
    @Test("Vespertine", arguments: DoPStreamChecks.all) func vespertine(_ c: SpecCheck<any DoPStageMaker>) { vespertineResult(c, in: Groups.dopStream) }
}

@Suite("Float output") struct FloatAcceptance {
    @Test("Clean-room implementations pass", arguments: FloatChecks.all) func references(_ c: SpecCheck<any FloatOutput>) { referencesPass(c, in: Groups.float) }
    @Test("Mutant is killed", arguments: FloatMutants.all) func mutant(_ m: Mutant<any FloatOutput>) { killed(m, in: Groups.float) }
    @Test("Vespertine", arguments: FloatChecks.all) func vespertine(_ c: SpecCheck<any FloatOutput>) { vespertineResult(c, in: Groups.float) }
}

@Suite("Integer output") struct IntegerAcceptance {
    @Test("Clean-room implementations pass", arguments: IntegerChecks.all) func references(_ c: SpecCheck<any IntegerOutput>) { referencesPass(c, in: Groups.integer) }
    @Test("Mutant is killed", arguments: IntegerMutants.all) func mutant(_ m: Mutant<any IntegerOutput>) { killed(m, in: Groups.integer) }
    @Test("Vespertine", arguments: IntegerChecks.all) func vespertine(_ c: SpecCheck<any IntegerOutput>) { vespertineResult(c, in: Groups.integer) }
}

@Suite("Rate planning") struct RateAcceptance {
    @Test("Clean-room implementations pass", arguments: RateChecks.all) func references(_ c: SpecCheck<any RatePlanner>) { referencesPass(c, in: Groups.rate) }
    @Test("Mutant is killed", arguments: RateMutants.all) func mutant(_ m: Mutant<any RatePlanner>) { killed(m, in: Groups.rate) }
    @Test("Vespertine", .enabled(if: Vespertine.ratePlanner != nil, "Vespertine's planner is macOS-only"), arguments: RateChecks.all)
    func vespertine(_ c: SpecCheck<any RatePlanner>) { vespertineResult(c, in: Groups.rate) }
}

@Suite("BIT-PERFECT verdict") struct VerdictAcceptance {
    @Test("Clean-room implementations pass", arguments: VerdictChecks.all) func references(_ c: SpecCheck<any BadgeVerdict>) { referencesPass(c, in: Groups.verdict) }
    @Test("Mutant is killed", arguments: VerdictMutants.all) func mutant(_ m: Mutant<any BadgeVerdict>) { killed(m, in: Groups.verdict) }
    @Test("Vespertine", .enabled(if: Vespertine.verdict != nil, "Vespertine's verdict is macOS-only"), arguments: VerdictChecks.all)
    func vespertine(_ c: SpecCheck<any BadgeVerdict>) { vespertineResult(c, in: Groups.verdict) }
}

@Suite("DST decoding") struct DSTAcceptance {
    @Test("The fixtures load") func fixtures() { #expect(DSTFixtures.all.count == 15, "\(DSTFixtures.directory.path)") }
    @Test("The reference answers pass", arguments: DSTChecks.all) func references(_ c: SpecCheck<any DSTDecoderMaker>) { referencesPass(c, in: Groups.dst) }
    @Test("Mutant is killed", arguments: DSTMutants.all) func mutant(_ m: Mutant<any DSTDecoderMaker>) { killed(m, in: Groups.dst) }
    @Test("Vespertine", arguments: DSTChecks.all) func vespertine(_ c: SpecCheck<any DSTDecoderMaker>) { vespertineResult(c, in: Groups.dst) }
}

// MARK: - Scoreboard

/// Writes every result as JSON for tools/scoreboard.py (REPORT.md) when VERIFICATION_RESULTS names a file.
@Test("Scoreboard", .enabled(if: ProcessInfo.processInfo.environment["VERIFICATION_RESULTS"] != nil))
func scoreboard() throws {
    let path = try #require(ProcessInfo.processInfo.environment["VERIFICATION_RESULTS"])
    #if os(macOS)
    let platform = "macOS"
    #else
    let platform = "Linux"
    #endif
    struct Scoreboard: Codable { var platform: String; var groups: [GroupReport] }
    let board = Scoreboard(platform: platform, groups: [
        Groups.dopPack.report(), Groups.dopStream.report(), Groups.float.report(), Groups.integer.report(),
        Groups.rate.report(), Groups.verdict.report(), Groups.dst.report(),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(board).write(to: URL(fileURLWithPath: path))
}
