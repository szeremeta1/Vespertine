//
// Vespertine: a folder of music on the device in the app: how its troubles are worded, and what the screens say of it.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineShare
@testable import VespertineRemote

@MainActor
@Suite struct Folders {
    @Test func aFolderThatCantBeOpenedSaysToChooseItAgainInPlainWords() {
        // The way back to the folder was lost.
        #expect(FolderWording.trouble(.accessDenied) == "Vespertine can’t open this folder any more. Choose the folder again.")
        // Its drive was pulled out, or it was moved.
        let gone = FolderWording.trouble(.unreachable)
        #expect(gone.contains("plug the drive in") && gone.contains("choose the folder again"))
        #expect(gone != FolderWording.trouble(.accessDenied))
        // Nothing a server would say is ever said of a folder.
        for error in [SMBError.timedOut, .closed, .signInFailed, .noSuchShare, .unsupported, .status(0xC000_0022)] {
            #expect(FolderWording.trouble(error) == gone)
        }
    }

    @Test func theScreensWordAFoldersTroubleAsAFoldersNotAServers() {
        var status = ShareStatus()
        status.folder = true
        #expect(status.trouble == nil)
        status.scan = .failed(.accessDenied)
        #expect(status.trouble == FolderWording.trouble(.accessDenied))
        status.scan = .idle
        status.reachable = false
        #expect(status.trouble == FolderWording.trouble(.unreachable))
        #expect(status.trouble != ShareWording.trouble(.unreachable))
    }

    @Test func aFoldersSayingsAreItsOwn() {
        let folder = FolderWording.sayings, share = ShareWording.sayings
        #expect(folder.notInLibrary != share.notInLibrary && folder.changed != share.changed && folder.noPlaylists != share.noPlaylists)
        #expect(folder.words == share.words)
        #expect(FolderWording.notPlayable("sacd.dsf").contains("sacd.dsf") && FolderWording.notCopied("a.flac").contains("a.flac"))
    }

    @Test func nowPlayingSaysTheSongComesFromAFolder() {
        let folder = NowPlayingView.source(reach: nil, connected: true, demo: false, share: true, folder: true)
        #expect(folder != nil && folder != NowPlayingView.source(reach: nil, connected: true, demo: false, share: true))
        // A folder that stopped answering: what still plays is what this device kept or had fetched.
        #expect(NowPlayingView.source(reach: nil, connected: true, demo: false, share: false, folder: true)
                == NowPlayingView.source(reach: nil, connected: false, demo: false))
    }

    @Test func theAppsOwnFolderIsAFolderWithNoBookmarkAndAnIndexApartFromTheMusic() {
        let own = SavedFolder.own
        #expect(own.isOwn && own.bookmark == nil && own.id.hasPrefix(ShareMac.prefix) && !own.name.isEmpty)
        #expect(!own.store.directory.path.hasPrefix(SavedFolder.ownURL.path))
        let added = SavedFolder(name: "Music", bookmark: Data([1]))
        #expect(!added.isOwn && added.store.directory != own.store.directory)
    }

    @Test func musicFilesOpenInVespertine() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        #expect(types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.audio") == true })
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool == true)
    }
}
