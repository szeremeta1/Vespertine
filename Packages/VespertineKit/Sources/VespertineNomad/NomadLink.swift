//
// Vespertine — talks to a Nomad [E] over its vendor HID interface.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@preconcurrency import IOKit.hid
import os

let log = Logger(subsystem: "org.szeremeta.vespertine.nomad", category: "link")

public enum NomadError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConnected
    case timeout
    case writeFailed(Int32)
    case rejected(String)

    public var description: String {
        switch self {
        case .notConnected: "no Nomad connected"
        case .timeout: "the keyboard didn't answer"
        case .writeFailed(let code): "HID write failed (0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case .rejected(let message): "the keyboard refused: \(message)"
        }
    }
}

/// One open Nomad: delivers its notifications and answers to calls, one call in flight at a time as the firmware wants.
///
/// IOKit's callbacks run on a run-loop thread of the link's own (the classic arrangement `hidapi` uses; the
/// dispatch-queue flavour of IOHIDManager refuses per-device callbacks). Everything the link keeps is touched only on
/// `queue`; the run-loop thread just hands reports over.
public final class NomadLink: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case connected(name: String)
        case disconnected
        /// The keyboard opened (true) or left (false) its media screen.
        case mediaScreen(wantsData: Bool)
        /// A notification this build doesn't act on, for diagnostics.
        case notification(method: String)
        /// The keyboard is there but the link couldn't be set up (the reason).
        case problem(String)
    }

    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.nomad")
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?

    // Touched on `queue` only.
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var decoder = NomadReports.LineDecoder()
    private var nextID = Int.random(in: 0..<999)

    private struct Call {
        let id: Int
        let reports: [[UInt8]]
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiting: [Call] = []
    private var inFlight: (call: Call, timeout: DispatchWorkItem)?

    private let onEvent: @Sendable (Event) -> Void
    private let callTimeout: TimeInterval
    /// Every report in both directions as hex, for diagnosing the channel (the CLI's `--trace`).
    private let trace: (@Sendable (String) -> Void)?

    public init(callTimeout: TimeInterval = 5, trace: (@Sendable (String) -> Void)? = nil, onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
        self.callTimeout = callTimeout
        self.trace = trace
    }

    deinit { shutDown() }

    // MARK: Lifecycle

    /// Starts watching for a Nomad (already plugged in counts) and keeps the link up across unplug and replug.
    public func start() {
        // Claim the slot under the queue, but wait for the thread outside it: the thread's first step uses the queue.
        let ready = DispatchSemaphore(value: 0)
        let thread: Thread? = queue.sync {
            guard self.thread == nil else { return nil }
            let thread = Thread { [self] in
                queue.sync { runLoop = CFRunLoopGetCurrent() }
                // A source keeps the loop alive until it's stopped on purpose.
                var context = CFRunLoopSourceContext()
                let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
                setUpManager()
                ready.signal()
                CFRunLoopRun()
                tearDownManager()
            }
            thread.name = "org.szeremeta.vespertine.nomad.runloop"
            thread.qualityOfService = .userInitiated
            self.thread = thread
            return thread
        }
        guard let thread else { return }
        thread.start()
        ready.wait()
    }

    public func stop() { shutDown() }

    private func shutDown() {
        let (loop, thread): (CFRunLoop?, Thread?) = queue.sync {
            let pair = (runLoop, self.thread)
            self.thread = nil
            return pair
        }
        guard let loop, let thread else { return }
        CFRunLoopStop(loop)
        // The loop thread tears the manager down as it exits; wait for that so nothing is released mid-callback.
        while !thread.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        queue.sync {
            runLoop = nil
            device = nil
            reportBuffer?.deallocate(); reportBuffer = nil
            drop(error: .notConnected)
        }
    }

    public var isConnected: Bool { queue.sync { device != nil } }

    // MARK: Calls

    /// Sends a JSON-RPC call and waits for the keyboard's answer. Calls run strictly one after another.
    public func call(_ method: String, _ params: [(String, JSONValue)]?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard device != nil else { continuation.resume(throwing: NomadError.notConnected); return }
                nextID = (nextID + 1) % 999
                let id = nextID
                let reports = NomadReports.split(NomadRPC.request(method: method, params: params, id: id))
                waiting.append(Call(id: id, reports: reports, continuation: continuation))
                pump()
            }
        }
    }

    // MARK: IOKit, on the run-loop thread

    private func setUpManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: NomadProtocol.vendorID, kIOHIDPrimaryUsagePageKey: NomadProtocol.usagePage]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<NomadLink>.fromOpaque(context).takeUnretainedValue().matched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<NomadLink>.fromOpaque(context).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if status != kIOReturnSuccess {
            log.error("IOHIDManagerOpen failed: 0x\(String(UInt32(bitPattern: status), radix: 16), privacy: .public)")
            onEvent(.problem("couldn't open the HID manager (IOReturn 0x\(String(UInt32(bitPattern: status), radix: 16)))"))
        }
        self.manager = manager
    }

    private func tearDownManager() {
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        if let device = queue.sync(execute: { self.device }), let buffer = queue.sync(execute: { self.reportBuffer }) {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 0, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private func matched(_ device: IOHIDDevice) {
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        guard NomadProtocol.productIDs.contains(product) else { return }
        let alreadyHave = queue.sync { self.device != nil }
        guard !alreadyHave else { return }

        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            log.error("Couldn't open the Nomad: 0x\(String(UInt32(bitPattern: opened), radix: 16), privacy: .public)")
            onEvent(.problem("couldn't open the vendor channel (IOReturn 0x\(String(UInt32(bitPattern: opened), radix: 16)))"))
            return
        }
        let maxInput = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? NomadProtocol.reportSize
        let capacity = max(maxInput, NomadProtocol.reportSize) + 1
        nonisolated(unsafe) let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, capacity, { context, _, _, _, _, report, length in
            guard let context else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<NomadLink>.fromOpaque(context).takeUnretainedValue().received(bytes)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Nomad"
        queue.async { [self] in
            self.device = device
            reportBuffer?.deallocate()
            reportBuffer = buffer
            decoder = NomadReports.LineDecoder()
            log.notice("Nomad connected: \(name, privacy: .public)")
            onEvent(.connected(name: name))
        }
    }

    private func removed(_ gone: IOHIDDevice) {
        queue.async { [self] in
            guard let device, CFEqual(device, gone) else { return }
            self.device = nil
            drop(error: .notConnected)
            log.notice("Nomad disconnected")
            onEvent(.disconnected)
        }
    }

    // MARK: On the queue

    private func received(_ report: [UInt8]) {
        queue.async { [self] in
            trace?("<- \(report.count)B \(Self.hex(report))")
            for line in decoder.feed(report) where line.channel == NomadProtocol.Channel.rpc.rawValue {
                guard let message = NomadRPC.parse(line.text) else { continue }
                switch message {
                case .notification(let method, let shouldFetch):
                    if method == NomadProtocol.Method.fetchData { onEvent(.mediaScreen(wantsData: shouldFetch ?? false)) }
                    else { onEvent(.notification(method: method)) }
                case .response(let id, let error):
                    guard let current = inFlight, current.call.id == id else { continue }
                    current.timeout.cancel()
                    inFlight = nil
                    if let error { current.call.continuation.resume(throwing: NomadError.rejected(error)) }
                    else { current.call.continuation.resume() }
                    pump()
                }
            }
        }
    }

    private func pump() {
        guard inFlight == nil, !waiting.isEmpty, let device else { return }
        let call = waiting.removeFirst()
        log.notice("→ call \(call.id, privacy: .public) (\(call.reports.count, privacy: .public) reports)")
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let current = inFlight, current.call.id == call.id else { return }
            inFlight = nil
            current.call.continuation.resume(throwing: NomadError.timeout)
            pump()
        }
        inFlight = (call, timeout)
        queue.asyncAfter(deadline: .now() + callTimeout, execute: timeout)
        for report in call.reports {
            trace?("-> \(report.count)B \(Self.hex(report))")
            let status = report.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), $0.baseAddress!, report.count)
            }
            if status != kIOReturnSuccess {
                timeout.cancel()
                inFlight = nil
                call.continuation.resume(throwing: NomadError.writeFailed(status))
                pump()
                return
            }
        }
    }

    private func drop(error: NomadError) {
        if let current = inFlight {
            current.timeout.cancel()
            current.call.continuation.resume(throwing: error)
            inFlight = nil
        }
        for call in waiting { call.continuation.resume(throwing: error) }
        waiting = []
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        // Only the part that carries data: the rest of a 64-byte report is padding.
        let used = bytes.count > 3 ? min(bytes.count, Int(bytes[0] == NomadProtocol.reportID ? bytes[2] : bytes[1]) + 3) : bytes.count
        return bytes.prefix(used).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - The media widget's calls

extension NomadLink {
    /// Title, artist and time. Fields left nil stay as the keyboard has them.
    public func sendInfo(title: String? = nil, artist: String? = nil, elapsed: Int? = nil, duration: Int? = nil, isPlaying: Bool? = nil) async throws {
        var params: [(String, JSONValue)] = []
        if let title { params.append(("song_title", .string(title))) }
        if let artist { params.append(("artist", .string(artist))) }
        if let elapsed { params.append(("elapsed", .int(elapsed))) }
        if let duration { params.append(("total_duration", .int(duration))) }
        if let isPlaying { params.append(("is_playing", .bool(isPlaying))) }
        try await call(NomadProtocol.Method.writeInfo, params)
    }

    /// Cover art, already in the keyboard's image layout (`NomadArtwork.encode`), in the chunks it takes.
    public func sendArtwork(_ image: Data) async throws {
        let size = NomadProtocol.artworkChunkBytes
        var offset = 0
        while offset < image.count {
            let chunk = image[offset..<min(offset + size, image.count)]
            try await call(NomadProtocol.Method.writeArtwork, [
                ("data", .string(chunk.base64EncodedString())), ("offset", .int(offset)), ("size", .int(image.count)),
            ])
            offset += size
            // Input paces the chunks 50 ms apart; the firmware writes each to flash.
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Asks the firmware for its version; a cheap check that the channel works.
    public func ping() async throws {
        try await call(NomadProtocol.Method.version, nil)
    }
}
