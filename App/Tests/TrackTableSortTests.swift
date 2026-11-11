// Vespertine: tests for sorting the songs table of a large library (the real table, in a window).
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
import VespertineLibrary
@testable import Vespertine

/// A made-up library for table tests: albums of twelve songs, in the order the Songs page lists them.
enum SortFixture {
    static func library(_ count: Int) throws -> [Track] {
        // Track's memberwise initializer belongs to the library package: decode one and fill in the rest.
        let template = try JSONDecoder().decode(Track.self, from: Data("""
            {"location": "", "filePath": "", "fileSize": 30000000, "modifiedAt": 720000000, "addedAt": 720000000, "codec": "FLAC",
             "isLossless": true, "isDSD": false, "sampleRate": 44100, "channels": 2, "duration": 0, "title": "", "compilation": false,
             "extraTags": {}, "playCount": 0, "isMissing": false}
            """.utf8))
        let formats: [(String, Double, Int)] = [("FLAC", 44_100, 16), ("FLAC", 96_000, 24), ("ALAC", 48_000, 24), ("FLAC", 192_000, 24)]
        return (0..<count).map { i in
            let album = i / 12, artist = album / 4, number = i % 12 + 1
            var track = template
            track.id = Int64(i + 1)
            track.location = "/Volumes/Music Share/Artist \(artist)/Album \(album)/\(number).flac"
            track.filePath = track.location
            (track.codec, track.sampleRate, track.bitDepth) = formats[album % formats.count]
            track.duration = Double(120 + (i * 37) % 400)
            track.title = "Song \((i * 7919) % count) of the Vesper Quartet"
            track.artist = "Artist \(artist)"
            track.albumArtist = track.artist
            track.album = "Album \(album)"
            track.trackNumber = number
            track.discNumber = 1
            return track
        }
    }
}

@Suite("Sorting a large song table", .serialized) @MainActor
struct TrackTableSortTests {
    /// The main thread's longest stretch of work without going back to its run loop: how long a click would wait.
    final class BusyWatch {
        private var worst = 0.0
        private var woke = CFAbsoluteTimeGetCurrent()
        private var observer: CFRunLoopObserver?

        init() {
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { [unowned self] _, activity in
                MainActor.assumeIsolated {
                    if activity == .afterWaiting || activity == .entry { self.woke = CFAbsoluteTimeGetCurrent() }
                    if activity == .beforeWaiting || activity == .exit { self.worst = max(self.worst, CFAbsoluteTimeGetCurrent() - self.woke) }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        /// The longest stretch since the last call.
        func takeWorst() -> Double { defer { worst = 0 }; return worst }
        func stop() { if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) } }
    }

    private struct Rig {
        let window: NSWindow
        let table: NSTableView
    }

    private func settle(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// Runs the main loop until `condition` holds: polled for up to 30 s, a bound for a hang and not a measure of
    /// anything. The expectation that follows still decides.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<600 { if condition() { return }; await settle(0.05) }
    }

    private func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let found = tableView(in: child) { return found } }
        return nil
    }

    private func makeRig(_ tracks: [Track]) async throws -> Rig {
        await until { LibraryStartup.current?.model != nil }
        let model = try #require(LibraryStartup.current?.model, "the host app has its library open")
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1100, height: 720), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TrackTable(tracks: tracks).environment(model))
        window.orderFront(nil)
        await until { window.contentView.flatMap(tableView(in:))?.numberOfRows == tracks.count }
        let table = try #require(window.contentView.flatMap(tableView(in:)), "the songs table is on screen")
        try #require(table.numberOfRows == tracks.count)
        return Rig(window: window, table: table)
    }

    /// The first row of the table as it is drawn now.
    private func topRow(_ table: NSTableView) -> Data? {
        guard let view = table.rowView(atRow: 0, makeIfNecessary: false), let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func rowViews(_ table: NSTableView) -> Int {
        var count = 0
        table.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }

    /// Sorting a library used to be handed to AppKit as every row moving: seconds of the main thread for 20,000 songs
    /// (2.5 s on the machine this was written on), and minutes when AppKit also built a view for each row (the hang
    /// that had Vespertine force quit). The rows on screen now stay the rows they are and show other songs.
    ///
    /// The time a sort keeps the main thread is compared with what selecting a row of the same table costs, not with a
    /// number of milliseconds: both scale with the machine. Set `VESPERTINE_SORT_BUDGET_MS` to hold it to one as well.
    @Test("Sorting 20,000 songs by any column keeps the rows on screen and never holds up the main thread")
    func sortingALibrary() async throws {
        let count = 20_000
        let rig = try await makeRig(try SortFixture.library(count))
        defer { rig.window.close() }
        let table = rig.table
        await settle(1)
        let unsorted = try #require(topRow(table))
        let firstRowView = try #require(table.rowView(atRow: 0, makeIfNecessary: false))
        let onScreen = rowViews(table)
        let busy = BusyWatch()
        defer { busy.stop() }

        var worstSort = 0.0, report: [String] = []
        let sortable = table.tableColumns.filter { $0.sortDescriptorPrototype != nil }
        #expect(sortable.count == 6, "number, title, artist, album, format and time sort")
        for column in sortable {
            let prototype = try #require(column.sortDescriptorPrototype)
            let backward = try #require(prototype.reversedSortDescriptor as? NSSortDescriptor)
            // Each sort twice, and the quicker one counts: a stall that is the sort's happens every time.
            var stalls: [Bool: [Double]] = [:]
            for descriptor in [backward, prototype, backward, prototype] {
                let before = topRow(table)
                _ = busy.takeWorst()
                table.sortDescriptors = [descriptor]
                await until { topRow(table) != before }
                await settle(0.3)
                #expect(topRow(table) != before, "\(column.title): the first row shows another song")
                stalls[descriptor.ascending, default: []].append(busy.takeWorst())
            }
            for (ascending, times) in stalls.sorted(by: { $0.key && !$1.key }) {
                let stall = times.min() ?? 0
                worstSort = max(worstSort, stall)
                report.append("\(column.title) \(ascending ? "ascending" : "descending") \(Int((stall * 1000).rounded())) ms")
            }
            #expect(table.rowView(atRow: 0, makeIfNecessary: false) === firstRowView, "\(column.title): the rows on screen stay, and show other songs")
            #expect(rowViews(table) <= onScreen + 8, "\(column.title): no views are built for rows out of sight")
        }

        // Back in the list's own order, the table shows what it showed at first.
        table.sortDescriptors = [try #require(sortable.first?.sortDescriptorPrototype)]
        await until { topRow(table) == unsorted }
        #expect(topRow(table) == unsorted)

        var selecting: [Double] = []
        for row in [2, 7, 11] {
            _ = busy.takeWorst()
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await settle(0.5)
            selecting.append(busy.takeWorst())
        }
        let select = try #require(selecting.min())
        print("Sorting \(count) songs, longest main-thread stretch: \(report.joined(separator: ", ")); selecting a row \(Int((select * 1000).rounded())) ms")
        #expect(worstSort < max(select, 0.01) * 4, "a sort costs the main thread about what a click does, not time that grows with the sort")
        if let budget = Double(ProcessInfo.processInfo.environment["VESPERTINE_SORT_BUDGET_MS"] ?? "") {
            #expect(worstSort * 1000 < budget)
        }
    }
}
