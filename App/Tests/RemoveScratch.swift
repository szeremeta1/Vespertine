//
// Vespertine: deleting a test's scratch folder.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineLibrary

/// Deletes a test's scratch folder, closing first every library database still open in it. A library's observations hold
/// its database open after the test is done with it, and SQLite logs "vnode unlinked while in use" for files deleted
/// under an open database: hundreds of lines a run, in CI's log and in the Mac's.
func removeScratch(_ folder: URL) {
    LibraryDatabase.closeAll(under: folder)
    try? FileManager.default.removeItem(at: folder)
}
