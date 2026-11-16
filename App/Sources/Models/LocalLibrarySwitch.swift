//
// Vespertine: the Settings › Library switch for the local library: the music in folders, on drives and on network shares. On by
// default. Off, for a listener who plays only from a music server or from other apps, none of it is in the app: not listed,
// scanned, watched, connected to or analyzed. Nothing is deleted, so on brings it all back. Its words and what Settings shows
// under it, kept apart from the views so they can be tested; the switching itself is `AppModel.setLocalLibrary`.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

@MainActor
enum LocalLibrarySwitch {
    /// Where the choice is kept.
    nonisolated static let key = "localLibrary"

    static var title: String {
        String(localized: "Local Library", comment: "Settings › Library: the switch that makes the music files in the listener’s folders, on their drives and on their network shares part of the app. It is on by default.")
    }

    static var explanation: String {
        String(localized: "The music in your folders, on your drives and on your network shares. Off, Vespertine shows none of it and scans, watches and connects to none of it. Nothing is deleted.", comment: "Settings › Library: the caption under the Local Library switch.")
    }

    /// What the main window says instead of “add some music” when the local library is off and there is no other music to show.
    static var emptyExplanation: String {
        String(localized: "The local library is off, so the music in your folders and on your network shares isn’t shown. Turn it back on in Settings › Library, or add a music server there.", comment: "Main window, when the Local Library switch is off and no music server is set up. “Settings › Library” is the Library tab of the Settings window.")
    }

    /// Turns the local library on or off. Off: a file that is playing stops and the files leave the queue, analysis stops, and
    /// the library answers without them (`LibraryStore.setFilesOn`), which also leaves the shares alone. On: everything is
    /// listed again, the shares are connected to, and automatic scanning and analysis carry on if they are switched on.
    static func apply(_ on: Bool, to settings: AppSettings, library: LibraryStore, player: PlayerController, analysis: AnalysisQueue,
                      shares: NetworkShareManager) {
        guard settings.localLibrary != on || library.filesOn != on else { return }
        settings.localLibrary = on
        if !on {
            player.localLibraryTurnedOff()
            analysis.cancel()
        }
        library.setFilesOn(on)
        if on {
            Task { await shares.reconnectAll() }
            if settings.autoAnalyze { analysis.analyzeLibrary() }
        }
    }

    /// What Settings › Library shows, top to bottom.
    enum Row: Hashable { case toggle, explanation, sources, servers, importing, analysis, data }

    /// The switch and its line always; the folders, importing and analysis only while it is on. Music servers have their own switch.
    static func rows(on: Bool) -> [Row] {
        on ? [.toggle, .explanation, .sources, .servers, .importing, .analysis, .data] : [.toggle, .explanation, .servers, .data]
    }
}
