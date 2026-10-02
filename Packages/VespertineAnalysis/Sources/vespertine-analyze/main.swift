//
// vespertine-analyze — runs Vespertine's file analysis next to the music (e.g. on the server behind a
// network share) and writes the results where Vespertine picks them up, so the Mac never has to
// read every file over the network.
//
//   vespertine-analyze index <folder> [--jobs N] [--max-seconds S] [--limit N]
//       Analyzes every lossless file under <folder> that is new or changed since the last run and
//       writes <folder>/.vespertine/analysis.jsonl (one JSON record per line; later lines win).
//   vespertine-analyze file [--portable] <file>…
//       Prints the analysis of single files as JSON lines (for checking results against the app).
//
// Decoding uses ffmpeg/ffprobe (must be on PATH). The music itself is only ever read.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAnalysisCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

let indexFormat = 1

struct IndexRecord: Codable {
    var path: String          // relative to the indexed folder, NFC
    var size: Int64
    var mtime: Double         // seconds since 1970
    var analysis: FileAnalysis
}

struct Status: Codable {
    var format = indexFormat
    var analysisVersion = FileAnalysis.currentVersion
    var state: String         // "running", "finished"
    var started: Date
    var updated: Date
    var total: Int
    var done: Int
    var failures: Int
}

enum Failure: Error, CustomStringConvertible {
    case probe(String), decode(String), unsupported(String)
    var description: String {
        switch self {
        case .probe(let s): "probe failed: \(s)"
        case .decode(let s): "decode failed: \(s)"
        case .unsupported(let s): "unsupported: \(s)"
        }
    }
}

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - Decoding with ffmpeg

struct Probe {
    var codec: String
    var sampleRate: Double
    var channels: Int
    var claimedBits: Int?
    var isFloat: Bool
    var isLossless: Bool
    var isDSD: Bool
}

let losslessCodecs: Set<String> = ["flac", "alac", "ape", "wavpack", "tta", "tak", "mlp", "truehd", "shorten", "als", "mp4als"]
let audioExtensions: Set<String> = ["flac", "wav", "wave", "aif", "aiff", "aifc", "m4a", "mp4", "caf", "ape", "wv", "tta", "tak", "shn", "dsf", "dff"]

func run(_ tool: String, _ args: [String]) throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [tool] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure.probe("\(tool) exited \(p.terminationStatus)") }
    return data
}

func probe(_ path: String) throws -> Probe {
    let data = try run("ffprobe", ["-v", "error", "-select_streams", "a:0", "-show_entries",
                                   "stream=codec_name,sample_rate,channels,bits_per_raw_sample,bits_per_sample,sample_fmt",
                                   "-of", "json", path])
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let s = (root["streams"] as? [[String: Any]])?.first,
          let codec = s["codec_name"] as? String else { throw Failure.probe("no audio stream") }
    func int(_ key: String) -> Int? {
        if let i = s[key] as? Int { return i }
        if let t = s[key] as? String, let i = Int(t) { return i }
        return nil
    }
    let sampleFmt = s["sample_fmt"] as? String ?? ""
    let isFloat = codec.hasPrefix("pcm_f") || ((sampleFmt.hasPrefix("flt") || sampleFmt.hasPrefix("dbl")) && codec.hasPrefix("pcm"))
    let isPCM = codec.hasPrefix("pcm_")
    let isDSD = codec.hasPrefix("dsd_")
    var bits = [int("bits_per_raw_sample"), int("bits_per_sample")].compactMap { $0 }.first { $0 > 0 }
    if isFloat { bits = 32 }
    return Probe(codec: codec, sampleRate: Double(int("sample_rate") ?? 0), channels: int("channels") ?? 0,
                 claimedBits: bits, isFloat: isFloat, isLossless: isPCM || losslessCodecs.contains(codec), isDSD: isDSD)
}

/// Frees autoreleased Foundation objects each time round a loop (Apple platforms; Linux has none).
func drained<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

/// Decodes up to `maxSeconds` with ffmpeg and feeds the accumulator.
func analyze(path: String, maxSeconds: Double, portable: Bool) throws -> FileAnalysis {
    let info = try probe(path)
    guard !info.isDSD else {
        return .notApplicable(claimedBitDepth: nil, sampleRate: info.sampleRate, summary: "DSD source: bit depth analysis doesn't apply.")
    }
    guard info.isLossless else {
        return .notApplicable(claimedBitDepth: info.claimedBits, sampleRate: info.sampleRate, summary: "Lossy source: analysis doesn't apply.")
    }
    guard info.sampleRate > 0, info.channels > 0, info.channels <= 64 else { throw Failure.unsupported("\(info.codec) \(info.channels) ch") }

    let accumulator = AnalysisAccumulator(sampleRate: info.sampleRate, channels: info.channels, claimedBitDepth: info.claimedBits,
                                          maxSeconds: maxSeconds, forcePortableFFT: portable)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // Integers as s32 (exact for every word length up to 32 bits), floats as f32.
    let (format, codec) = info.isFloat ? ("f32le", "pcm_f32le") : ("s32le", "pcm_s32le")
    p.arguments = ["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-map", "0:a:0", "-t", String(maxSeconds),
                   "-f", format, "-acodec", codec, "-"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let frameBytes = 4 * info.channels
    var pending = Data()
    var floats = [Float]()
    var failure: Error?
    let reader = out.fileHandleForReading
    while true {
        let chunk = drained { reader.readData(ofLength: 1 << 20) }
        if chunk.isEmpty { break }
        guard failure == nil else { continue } // keep draining so ffmpeg can exit
        pending.append(chunk)
        let frames = pending.count / frameBytes
        guard frames > 0 else { continue }
        let count = frames * info.channels
        if floats.count < count { floats = [Float](repeating: 0, count: count) }
        pending.withUnsafeBytes { raw in
            if info.isFloat {
                for i in 0..<count { floats[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))) }
            } else {
                for i in 0..<count {
                    let v = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int32.self))
                    floats[i] = Float(Double(v) / 2_147_483_648.0)
                }
            }
        }
        // Keep only the partial frame left over, in fresh storage (Data.removeFirst keeps the whole
        // buffer alive, so memory would grow with the length of the file).
        pending = Data(pending[(pending.startIndex + frames * frameBytes)...])
        do {
            try floats.withUnsafeBufferPointer { try accumulator.add(interleaved: UnsafeBufferPointer(rebasing: $0[0..<count]), frames: frames) }
        } catch { failure = error }
    }
    p.waitUntilExit()
    if let failure { throw failure }
    guard p.terminationStatus == 0 || accumulator.framesDone > 0 else { throw Failure.decode("ffmpeg exited \(p.terminationStatus)") }
    return accumulator.finish()
}

/// Rounds the stored spectrum to 0.1 dB (plenty for display; keeps the index small).
func compact(_ a: FileAnalysis) -> FileAnalysis {
    var a = a
    a.spectrum = a.spectrum.map { ($0 * 10).rounded() / 10 }
    return a
}

// MARK: - Index

/// A file in the index folder that can't be used safely (or at all).
struct IndexError: Error, CustomStringConvertible {
    var path: String
    /// nil: it's there, but isn't a plain file of its own.
    var code: Int32?
    var description: String {
        switch code {
        case nil: "\(path) isn't a plain file (a hard link, a folder…); refusing to use it"
        case ELOOP?: "\(path) is a symbolic link; refusing to use it"
        case ENOTDIR?: "\(path) isn't a folder (a symbolic link to one is refused too)"
        case let code?: "\(path): \(String(cString: strerror(code)))"
        }
    }
}

/// The index lives in `<folder>/.vespertine`, inside a tree that whoever adds music can usually write to, while this
/// tool often runs as root. So the folder is held open and every file in it is opened relative to it, never through
/// a symbolic link: a link planted there (to /etc/shadow, say) can't turn a write or a chmod into one on another file.
final class Index: @unchecked Sendable {
    let root: URL
    let dir: URL
    private let dirFD: Int32
    private let lock = NSLock()
    private var records: [String: IndexRecord] = [:]
    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()

    init(root: URL) throws {
        self.root = root
        dir = root.appendingPathComponent(".vespertine", isDirectory: true)
        // An index written before the rename (`.nocturne/`) is taken over as is, so nothing is analyzed twice.
        let legacy = root.appendingPathComponent(".nocturne", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.moveItem(at: legacy, to: dir)
        }
        let created = mkdir(dir.path, 0o755) == 0
        let mkdirError = errno
        guard created || mkdirError == EEXIST else { throw IndexError(path: dir.path, code: mkdirError) }
        dirFD = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let openError = errno
        guard dirFD >= 0 else { throw IndexError(path: dir.path, code: openError) }
        if created { fchmod(dirFD, 0o755) } // readable by the Mac whatever the umask
        if let data = try readExisting("analysis.jsonl") {
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let r = try? Self.decoder.decode(IndexRecord.self, from: line) { records[r.path] = r }
            }
        }
    }

    deinit { close(dirFD) }

    /// Opens `name` in the index folder: never through a symbolic link, and only a plain file with no other name.
    private func openFile(_ name: String, _ flags: Int32) throws -> Int32 {
        let fd = openat(dirFD, name, flags | O_NOFOLLOW | O_CLOEXEC, 0o644)
        let code = errno
        guard fd >= 0 else { throw IndexError(path: dir.path + "/" + name, code: code) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), st.st_nlink == 1 else {
            close(fd)
            throw IndexError(path: dir.path + "/" + name, code: nil)
        }
        return fd
    }

    private func readExisting(_ name: String) throws -> Data? {
        let fd: Int32
        do { fd = try openFile(name, O_RDONLY) } catch let error as IndexError where error.code == ENOENT { return nil }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd()
    }

    /// Writes `data` to a new file beside `name`, then renames it over `name`: the Mac never reads a half-written
    /// file, and a link planted at either name is replaced, not followed.
    private func replace(_ name: String, with data: Data) throws {
        let temporary = ".\(name).tmp"
        unlinkat(dirFD, temporary, 0) // left by an interrupted run
        let fd = openat(dirFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        let code = errno
        guard fd >= 0 else { throw IndexError(path: dir.path + "/" + temporary, code: code) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            fchmod(fd, 0o644)
            try file.close()
        } catch {
            unlinkat(dirFD, temporary, 0)
            throw error
        }
        guard renameat(dirFD, temporary, dirFD, name) == 0 else {
            let code = errno
            unlinkat(dirFD, temporary, 0)
            throw IndexError(path: dir.path + "/" + name, code: code)
        }
    }

    /// The lock file that keeps runs from overlapping.
    func openLock() throws -> Int32 { try openFile(".lock", O_RDWR | O_CREAT) }

    /// The file's record is up to date, or one an analyzer update judges anew from its measurements (as Vespertine
    /// does on import), so after an update only the files that need reading again are analyzed again.
    func current(_ path: String, size: Int64, mtime: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let r = records[path] else { return false }
        return r.size == size && abs(r.mtime - mtime) < 1 && FileAnalyzer.rejudged(r.analysis).version >= FileAnalysis.currentVersion
    }

    func append(_ record: IndexRecord) throws {
        let line = try encoder.encode(record) + Data("\n".utf8)
        lock.lock(); defer { lock.unlock() }
        if handle == nil {
            let fd = try openFile("analysis.jsonl", O_WRONLY | O_CREAT | O_APPEND)
            fchmod(fd, 0o644)
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        try handle?.write(contentsOf: line)
        records[record.path] = record
    }

    /// Rewrites the index with one record per existing file (atomically).
    func compact(keeping present: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        try handle?.close()
        handle = nil
        var out = Data()
        for path in records.keys.sorted() where present.contains(path) {
            out += try encoder.encode(records[path]!) + Data("\n".utf8)
        }
        try replace("analysis.jsonl", with: out)
    }

    func writeStatus(_ status: Status) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(status) else { return }
        lock.lock(); defer { lock.unlock() } // workers report at once; they share the temporary file's name
        try? replace("status.json", with: data)
    }
}

func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

func stat(_ path: String) -> (size: Int64, mtime: Double)? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    #if canImport(Darwin)
    let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    #else
    let m = Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9
    #endif
    return (Int64(st.st_size), m)
}

func listAudio(under root: URL) -> [String] {
    var out: [String] = []
    let root = root.resolvingSymlinksInPath()
    let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
    for case let url as URL in e {
        let name = url.lastPathComponent
        if name.hasPrefix("._") || name == "@eaDir" || name == "#recycle" { e.skipDescendants(); continue }
        guard audioExtensions.contains(url.pathExtension.lowercased()),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        let full = url.resolvingSymlinksInPath().path
        if full.hasPrefix(base) { out.append(String(full.dropFirst(base.count))) }
    }
    return out.sorted()
}

// MARK: - Commands

// A closed output pipe must never kill a run before it compacts the index.
signal(SIGPIPE, SIG_IGN)

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let usage = """
usage: vespertine-analyze index <folder> [--jobs N] [--max-seconds S] [--limit N]
       vespertine-analyze file [--portable] <file>…
"""

switch args.first {
case "file":
    args.removeFirst()
    let portable = flag("--portable")
    let maxSeconds = option("--max-seconds").flatMap(Double.init) ?? 600
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    var failed = false
    for path in args {
        do {
            let a = try analyze(path: path, maxSeconds: maxSeconds, portable: portable)
            print(String(decoding: try encoder.encode(IndexRecord(path: path, size: stat(path)?.size ?? 0, mtime: stat(path)?.mtime ?? 0, analysis: a)), as: UTF8.self))
        } catch {
            stderr("\(path): \(error)"); failed = true
        }
    }
    exit(failed ? 1 : 0)

case "index":
    args.removeFirst()
    let jobs = max(1, option("--jobs").flatMap(Int.init) ?? ProcessInfo.processInfo.activeProcessorCount)
    let maxSeconds = option("--max-seconds").flatMap(Double.init) ?? 600
    let limit = option("--limit").flatMap(Int.init)
    guard let folder = args.first else { stderr(usage); exit(2) }
    let root = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let index: Index
    do { index = try Index(root: root) } catch { stderr("can't open index: \(error)"); exit(1) }

    // One run at a time.
    let lockFD: Int32
    do { lockFD = try index.openLock() } catch { stderr("can't open index lock: \(error)"); exit(1) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { stderr("another vespertine-analyze is running"); exit(0) }

    let all = listAudio(under: root)
    let present = Set(all.map(nfc))
    var todo: [(rel: String, key: String, size: Int64, mtime: Double)] = []
    for rel in all {
        guard let st = stat(root.appendingPathComponent(rel).path) else { continue }
        let key = nfc(rel)
        if !index.current(key, size: st.size, mtime: st.mtime) { todo.append((rel, key, st.size, st.mtime)) }
    }
    if let limit { todo = Array(todo.prefix(limit)) }
    let started = Date()
    stderr("vespertine-analyze: \(all.count) audio files, \(todo.count) to analyze, \(jobs) at a time")

    final class Progress: @unchecked Sendable {
        let lock = NSLock()
        var next = 0, done = 0, failures = 0
        var lastStatus = Date.distantPast
    }
    let progress = Progress()
    index.writeStatus(Status(state: "running", started: started, updated: Date(), total: todo.count, done: 0, failures: 0))
    let items = todo
    DispatchQueue.concurrentPerform(iterations: jobs) { _ in
        while true {
            progress.lock.lock()
            guard progress.next < items.count else { progress.lock.unlock(); return }
            let item = items[progress.next]
            progress.next += 1
            progress.lock.unlock()

            var ok = true
            do {
                let a = try analyze(path: root.appendingPathComponent(item.rel).path, maxSeconds: maxSeconds, portable: false)
                try index.append(IndexRecord(path: item.key, size: item.size, mtime: item.mtime, analysis: compact(a)))
            } catch {
                ok = false
                stderr("\(item.rel): \(error)")
            }
            progress.lock.lock()
            progress.done += 1
            if !ok { progress.failures += 1 }
            let (done, failures) = (progress.done, progress.failures)
            let report = Date().timeIntervalSince(progress.lastStatus) > 30 || done == items.count
            if report { progress.lastStatus = Date() }
            progress.lock.unlock()
            if report {
                index.writeStatus(Status(state: "running", started: started, updated: Date(), total: items.count, done: done, failures: failures))
                let rate = Double(done) / max(1, Date().timeIntervalSince(started)) * 60
                stderr(String(format: "  %d/%d (%.0f files/min, %d failed)", done, items.count, rate, failures))
            }
        }
    }
    do { try index.compact(keeping: present) } catch { stderr("can't compact index: \(error)") }
    index.writeStatus(Status(state: "finished", started: started, updated: Date(), total: todo.count, done: progress.done, failures: progress.failures))
    stderr("vespertine-analyze: done in \(Int(Date().timeIntervalSince(started))) s, \(progress.failures) failed")
    exit(0)

default:
    stderr(usage)
    exit(2)
}
