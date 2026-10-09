//
// Vespertine verification: the small kit spec-traced checks are written with.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A check is a function of the thing under test, not a test case: the same check runs against every
// implementation of the contract and against every mutant. Every assertion names the requirement it checks, so a
// failure says which requirement it was, and the registry checker can find every ID used.
// Checks must never trap (no force unwraps, no unchecked indexing): a subject that misbehaves must fail a check,
// not stop the run.

/// One failed assertion.
public struct CheckFailure: Sendable, Hashable, CustomStringConvertible {
    public var requirement: String
    public var message: String
    public var file: String
    public var line: Int

    public var description: String { "[\(requirement)] \(message) (\(file):\(line))" }
}

/// Collects a check's assertions.
public final class Checker {
    public private(set) var failures: [CheckFailure] = []
    /// How many assertions were made per requirement ID.
    public private(set) var assertions: [String: Int] = [:]
    /// Failures beyond this many are counted but not kept (a check over millions of samples stays small).
    public let keep: Int

    public init(keep: Int = 50) { self.keep = keep }

    public private(set) var failureCount = 0

    /// Asserts `condition` for `requirement` (a record ID such as "DOP-002").
    @discardableResult
    public func expect(_ condition: Bool, _ requirement: String, _ message: @autoclosure () -> String = "",
                       file: String = #fileID, line: Int = #line) -> Bool {
        assertions[requirement, default: 0] += 1
        if !condition {
            failureCount += 1
            if failures.count < keep {
                failures.append(CheckFailure(requirement: requirement, message: message(), file: file, line: line))
            }
        }
        return condition
    }

    /// Records a failure without a condition.
    public func fail(_ requirement: String, _ message: String, file: String = #fileID, line: Int = #line) {
        expect(false, requirement, message, file: file, line: line)
    }
}

/// A named check of one or more requirements against a subject of type `Subject`.
public struct SpecCheck<Subject>: Sendable, CustomStringConvertible {
    public var name: String
    /// Every requirement ID the check asserts.
    public var requirements: [String]
    public var body: @Sendable (Subject, Checker) throws -> Void

    public init(_ name: String, requirements: [String], body: @escaping @Sendable (Subject, Checker) throws -> Void) {
        self.name = name
        self.requirements = requirements
        self.body = body
    }

    public var description: String { "\(name) [\(requirements.joined(separator: ", "))]" }

    public func run(on subject: Subject) -> CheckResult {
        let checker = Checker()
        var thrown: String?
        do { try body(subject, checker) } catch { thrown = String(describing: error) }
        return CheckResult(check: name, requirements: requirements, failures: checker.failures,
                           failureCount: checker.failureCount, assertions: checker.assertions, thrown: thrown)
    }
}

public struct CheckResult: Sendable, Hashable {
    public var check: String
    public var requirements: [String]
    public var failures: [CheckFailure]
    public var failureCount: Int
    public var assertions: [String: Int]
    /// An error the check let escape (counts as a failure of every requirement it names).
    public var thrown: String?

    public var passed: Bool { failureCount == 0 && thrown == nil && !assertions.isEmpty }
    /// Requirement IDs with at least one failed assertion (all of the check's IDs when it threw).
    public var failedRequirements: Set<String> {
        thrown != nil ? Set(requirements) : Set(failures.map(\.requirement))
    }
}

/// A deliberately wrong variant of a correct subject, aimed at one or more requirements.
public struct Mutant<Subject>: Sendable, CustomStringConvertible {
    public var id: String
    /// The requirement IDs this mutant violates.
    public var targets: [String]
    public var summary: String
    /// Wraps a correct subject into the mutant.
    public var make: @Sendable (Subject) -> Subject

    public init(_ id: String, targets: [String], summary: String, make: @escaping @Sendable (Subject) -> Subject) {
        self.id = id
        self.targets = targets
        self.summary = summary
        self.make = make
    }

    public var description: String { "\(id) [\(targets.joined(separator: ", "))]" }
}
