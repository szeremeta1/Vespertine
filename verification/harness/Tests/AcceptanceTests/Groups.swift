//
// Vespertine verification: one requirement group's checks, implementations, mutants and Vespertine, and how
// they are judged.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Contracts
import Foundation
import SpecKit

struct Group<Subject: Sendable>: Sendable {
    var name: String
    var checks: [SpecCheck<Subject>]
    /// The clean-room implementations every check must pass: B, and B2 where another model wrote one.
    var references: [(label: String, subject: Subject?)]
    var mutants: [Mutant<Subject>]
    var vespertine: Subject?
    /// Requirement IDs that can't run against Vespertine on this platform, with the reason.
    var unavailable: [String: String] = [:]

    /// The implementation mutants are made from: the first reference delivered.
    var base: Subject? { references.lazy.compactMap(\.subject).first }

    func outcome(of mutant: Mutant<Subject>) -> MutantOutcome {
        guard let base else { return MutantOutcome(id: mutant.id, targets: mutant.targets, summary: mutant.summary, killedBy: [], failedElsewhere: [], ran: false) }
        let mutated = mutant.make(base)
        var killedBy: [String] = [], elsewhere: [String] = []
        for check in checks {
            let failed = check.run(on: mutated).failedRequirements
            if !failed.isDisjoint(with: mutant.targets) { killedBy.append(check.name) }
            else if !failed.isEmpty { elsewhere.append("\(check.name) (\(failed.sorted().joined(separator: ", ")))") }
        }
        return MutantOutcome(id: mutant.id, targets: mutant.targets, summary: mutant.summary, killedBy: killedBy, failedElsewhere: elsewhere, ran: true)
    }

    func notRunHere(_ check: SpecCheck<Subject>) -> String? {
        check.requirements.lazy.compactMap { unavailable[$0] }.first
    }

    func report() -> GroupReport {
        GroupReport(
            name: name,
            checks: checks.map { check in
                CheckReport(
                    name: check.name, requirements: check.requirements,
                    references: references.map { ref in
                        SubjectResult(label: ref.label, result: ref.subject.map { check.run(on: $0) }.map(SubjectResult.Result.init) ?? nil)
                    },
                    vespertine: notRunHere(check).map { SubjectResult(label: "Vespertine", result: nil, notRun: $0) }
                        ?? SubjectResult(label: "Vespertine", result: vespertine.map { SubjectResult.Result(check.run(on: $0)) },
                                         notRun: vespertine == nil ? "not on this platform" : nil))
            },
            mutants: mutants.map(outcome))
    }
}

struct MutantOutcome: Codable, Sendable {
    var id: String
    var targets: [String]
    var summary: String
    /// Checks that failed on one of the mutant's target requirements.
    var killedBy: [String]
    /// Checks that failed only on other requirements.
    var failedElsewhere: [String]
    var ran: Bool
    var killed: Bool { !killedBy.isEmpty }
}

struct SubjectResult: Codable, Sendable {
    struct Result: Codable, Sendable {
        var passed: Bool
        var failedRequirements: [String]
        var failures: [String]
        var thrown: String?
        init(_ r: CheckResult) {
            passed = r.passed
            failedRequirements = r.failedRequirements.sorted()
            failures = r.failures.prefix(5).map(\.description)
            thrown = r.thrown
            if r.assertions.isEmpty && r.thrown == nil { failures.append("the check made no assertion") }
        }
    }
    var label: String
    var result: Result?
    var notRun: String? = nil
}

struct CheckReport: Codable, Sendable {
    var name: String
    var requirements: [String]
    var references: [SubjectResult]
    var vespertine: SubjectResult
}

struct GroupReport: Codable, Sendable {
    var name: String
    var checks: [CheckReport]
    var mutants: [MutantOutcome]
}

/// A failed check result in a few lines, for test output.
func describe(_ r: CheckResult) -> String {
    var lines = r.failures.prefix(5).map(\.description)
    if r.failureCount > lines.count { lines.append("… \(r.failureCount - lines.count) more") }
    if let thrown = r.thrown { lines.append("threw \(thrown)") }
    if r.assertions.isEmpty && r.thrown == nil { lines.append("made no assertion") }
    return lines.joined(separator: "\n")
}
