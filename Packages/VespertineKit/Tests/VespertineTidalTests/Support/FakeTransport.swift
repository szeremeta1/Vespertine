//
// Vespertine: a scripted HTTPTransport for the TIDAL tests (records every request, answers with a closure), and a settable clock.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@testable import VespertineTidal

struct FakeResponse: Sendable {
    var status: Int = 200
    var body: Data = Data()
    var headers: [String: String] = [:]

    init(status: Int = 200, json: String, headers: [String: String] = [:]) {
        self.status = status
        self.body = Data(json.utf8)
        self.headers = headers
    }

    init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> FakeResponse
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    /// Answers every request with `response`.
    convenience init(always response: FakeResponse) { self.init { _ in response } }

    var requests: [URLRequest] { lock.withLock { log } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { log.append(request) }
        let response = try await handler(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var callable: @Sendable () -> Date { { [self] in now } }
}

extension URLRequest {
    /// The fields of a form-encoded body.
    var formFields: [String: String] {
        FormEncoding.decode(String(decoding: httpBody ?? Data(), as: UTF8.self))
    }
}

/// Holds callers until the test lets them go.
actor Latch {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false

    var waitingCount: Int { waiting.count }

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func releaseOne() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }

    func releaseAll() {
        open = true
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }
}

/// Spins (yielding) until `condition` holds or about two seconds pass.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// The count before this call.
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
