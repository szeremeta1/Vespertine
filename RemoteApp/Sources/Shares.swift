//
// Vespertine: SMB shares in the app: the words a share's troubles are said in, what the screens show of a share that is
// open, and making its covers small.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import VespertineRemoteClient
import VespertineRemoteProtocol
import VespertineShare

extension ShareMac.Scan {
    var isRunning: Bool { if case .scanning = self { true } else { false } }
}

/// What the screens show of the share that is open.
struct ShareStatus: Equatable {
    var scan: ShareMac.Scan = .idle
    /// Whether the share answered the last time it was asked; nil before the first time.
    var reachable: Bool?
    var songs = 0
    var needTheMac = 0
    var unreadable = 0
    /// When the last whole scan ended; nil until one has.
    var scanned: Date?
    /// It is a folder on this device, not a share on a server: its troubles are worded as a folder's.
    var folder = false

    init() {}

    init(_ mac: ShareMac, folder: Bool = false) {
        self.folder = folder
        scan = mac.scan
        reachable = mac.reachable
        songs = mac.library.songs.count
        needTheMac = mac.library.needTheMac
        unreadable = mac.library.unreadable
        scanned = mac.library.scanned
    }

    /// The share can't be used right now: the reason, for showing.
    var trouble: String? {
        func words(_ error: SMBError) -> String { folder ? FolderWording.trouble(error) : ShareWording.trouble(error) }
        if case .failed(let error) = scan { return words(error) }
        return reachable == false ? words(.unreachable) : nil
    }
}

enum ShareWording {
    /// Why a share can't be used, in a sentence that says what to look at.
    nonisolated static func trouble(_ error: SMBError) -> String {
        switch error {
        case .unreachable:
            String(localized: "The server can’t be reached. Check that this device is on its network, or that Tailscale is connected.", comment: "Shown on the iPhone or iPad when an SMB share (a network folder of music) doesn't answer at its address.")
        case .timedOut, .closed:
            String(localized: "The server stopped answering.", comment: "Shown on the iPhone or iPad when the connection to an SMB share was lost.")
        case .signInFailed:
            String(localized: "The account name or password isn’t right.", comment: "Shown on the iPhone or iPad when an SMB share refuses the sign-in.")
        case .accessDenied:
            String(localized: "This account isn’t allowed to open that share.", comment: "Shown on the iPhone or iPad when an SMB share refuses access to the signed-in account.")
        case .noSuchShare:
            String(localized: "The server has no share with that name.", comment: "Shown on the iPhone or iPad when the server answers but the share name typed doesn't exist on it.")
        case .notFound:
            String(localized: "That folder isn’t on the share.", comment: "Shown on the iPhone or iPad when the folder typed after the share's name doesn't exist.")
        case .malformed, .unsupported:
            String(localized: "Vespertine can’t talk to this server. It needs SMB 2 or SMB 3.", comment: "Shown on the iPhone or iPad when a file server only offers SMB versions the app doesn't support. “SMB” is the file-sharing protocol; keep it.")
        case .badSignature:
            String(localized: "The server’s answers couldn’t be verified, so Vespertine stopped.", comment: "Shown on the iPhone or iPad when the signature on a file server's reply is wrong (the connection may have been tampered with).")
        case .status(let code):
            String(localized: "The server refused (error \(String(code, radix: 16, uppercase: true))).", comment: "Shown on the iPhone or iPad when a file server answers with an error the app has no words for. %@ is the error's number in hexadecimal, e.g. C0000022.")
        }
    }

    nonisolated static var sayings: ShareSayings {
        ShareSayings(words: ShareWords(unknownArtist: String(localized: "Unknown Artist", comment: "Library on the iPhone: the artist of songs whose files don't name one."),
                                       unknownAlbum: String(localized: "Unknown Album", comment: "Library on the iPhone: the album of songs whose files don't name one."),
                                       variousArtists: String(localized: "Various Artists", comment: "Library on the iPhone: the artist of a compilation album.")),
                     trouble: { trouble($0) },
                     notInLibrary: String(localized: "That isn’t on the share any more.", comment: "Shown on the iPhone when a song or album asked for is no longer in the share's index."),
                     noPlaylists: String(localized: "Playlists are kept on the Mac. A share has none.", comment: "Shown on the iPhone when a playlist is asked for while playing from an SMB share, which has no playlists."),
                     changed: String(localized: "That file has changed on the share. Scan the share again.", comment: "Shown on the iPhone when a song's file was replaced on the SMB share since the share was last scanned."))
    }

    /// The network a share is on, as far as its address says, in the words used for a Mac.
    static func network(_ address: ShareAddress) -> String {
        switch RemoteAddress(host: address.host).kind {
        case .tailscale: NowPlayingView.reachName(.tailscale)
        case .localNetwork: NowPlayingView.reachName(.sameNetwork)
        case .other: NowPlayingView.reachName(.elsewhere)
        }
    }
}

enum ShareCovers {
    /// A picture no larger than `size` pixels on its long side, as JPEG; nil when it isn't a picture.
    nonisolated static func shrink(_ data: Data, to size: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(32, size)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

extension SavedShare {
    /// Where this share's index, favorites and covers are kept on the phone.
    var store: ShareStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return ShareStore(directory: support.appendingPathComponent("Shares", isDirectory: true).appendingPathComponent(id, isDirectory: true))
    }

    /// Signs in and opens the music folder once. nil when it worked.
    nonisolated func check() async -> SMBError? {
        let share = self.files(timeout: 10)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { share.rest() }
                do {
                    _ = try share.list("")
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error as? SMBError ?? .closed)
                }
            }
        }
    }
}
