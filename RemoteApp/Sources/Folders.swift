//
// Vespertine: music stored on this device: folders added from Files (on the device, in iCloud Drive, on a drive plugged
// in) and the app's own folder, where single files opened in Vespertine are put. Each is opened as a share is: the same
// index, screens and player. Here are a folder's words, where its index is kept, and the picker that chooses it again.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import UniformTypeIdentifiers
import VespertineShare

enum FolderWording {
    /// Why a folder can't be used, ending in what to do about it.
    nonisolated static func trouble(_ error: SMBError) -> String {
        switch error {
        case .accessDenied:
            String(localized: "Vespertine can’t open this folder any more. Choose the folder again.", comment: "Shown on the iPhone or iPad when a folder of music the user added from the Files app can no longer be opened (the app's permission to it was lost). “Choose the folder again” must match the button “Choose the Folder Again”.")
        default:
            String(localized: "This folder can’t be found. If it is on a drive, plug the drive in. If it was moved or renamed, choose the folder again.", comment: "Shown on the iPhone or iPad when a folder of music the user added from the Files app isn't there: a USB drive was unplugged, or the folder was moved, renamed or deleted. “choose the folder again” must match the button “Choose the Folder Again”.")
        }
    }

    nonisolated static var sayings: ShareSayings {
        ShareSayings(words: ShareWording.sayings.words,
                     trouble: { trouble($0) },
                     notInLibrary: String(localized: "That file isn’t in the folder any more.", comment: "Shown on the iPhone when a song is played whose file has been deleted from the folder of music it was in."),
                     noPlaylists: String(localized: "Playlists are kept on the Mac. A folder has none.", comment: "Shown on the iPhone when a playlist is asked for while playing from a folder of music on the device, which has no playlists."),
                     changed: String(localized: "That file has changed. Vespertine is reading the folder again.", comment: "Shown on the iPhone when a song's file was replaced since the folder was last read; the app re-reads the folder by itself."))
    }

    /// The name of the app's own folder, where files opened in Vespertine from other apps are put.
    static var ownName: String {
        String(localized: "Opened Files", comment: "On the iPhone or iPad: the name of the app's own library of single music files the user opened in Vespertine from other apps (Files, Mail, AirDrop, the share sheet). Shown in a list next to the folders they added.")
    }

    /// What a file that was opened in Vespertine and can't be played is told.
    static func notPlayable(_ name: String) -> String {
        String(localized: "Vespertine can’t play “\(name)” on this device. It opens FLAC, ALAC, WAV, AIFF, MP3 and AAC files.", comment: "Alert on the iPhone or iPad when a file opened in Vespertine from another app is not a kind of music file the app can play by itself. %@ is the file's name. Keep the format names in Latin letters.")
    }

    static func notCopied(_ name: String) -> String {
        String(localized: "Vespertine couldn’t open “\(name)”.", comment: "Alert on the iPhone or iPad when a music file opened in Vespertine from another app couldn't be read or copied. %@ is the file's name.")
    }
}

extension SavedFolder {
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    /// The list of added folders.
    static var shelf: FolderShelf { FolderShelf(file: support.appendingPathComponent("Folders", isDirectory: true).appendingPathComponent("folders.json")) }

    /// Where this folder's index, favorites and covers are kept (apart from the music, which stays where it is).
    var store: ShareStore {
        ShareStore(directory: Self.support.appendingPathComponent("Folders", isDirectory: true).appendingPathComponent(id, isDirectory: true))
    }

    /// The app's own folder: what Files shows as Vespertine's, under On My iPhone.
    static var ownURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    static var own: SavedFolder { SavedFolder(id: ownID, name: FolderWording.ownName, bookmark: nil, addedAt: .distantPast) }
}

/// A folder in the list of Macs.
struct FolderRow: View {
    let folder: SavedFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.isOwn ? "tray.full" : "folder").foregroundStyle(Palette.brass).frame(width: 28)
            Text(folder.name).font(.serif(.body, weight: .medium)).foregroundStyle(Palette.text)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Opens the Files picker to point an added folder at its place again: the permission to it was lost, or it moved.
/// The folder keeps its index, favorites and queue.
struct ChooseFolderAgainButton: View {
    @Environment(RemoteAppModel.self) private var model
    let folder: SavedFolder
    @State private var choosing = false

    var body: some View {
        Button("Choose the Folder Again") { choosing = true }
            .accessibilityIdentifier("folder-rechoose")
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.rechoose(folder, at: url) }
            }
    }
}
