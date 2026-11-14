//
// Vespertine: an SMB share in the app: how its troubles are worded, what Now Playing says of it, and making covers small.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import UIKit
import VespertineShare
@testable import VespertineRemote

@MainActor
@Suite struct Shares {
    @Test func everyTroubleWithAShareHasWordsOfItsOwn() {
        let troubles: [SMBError] = [.unreachable, .timedOut, .signInFailed, .accessDenied, .noSuchShare, .notFound, .unsupported, .badSignature, .status(0xC000_0022)]
        let words = troubles.map(ShareWording.trouble)
        #expect(Set(words).count == troubles.count)
        #expect(words.allSatisfy { !$0.isEmpty })
        // A dropped line and one that went quiet are the same thing to the person holding the phone.
        #expect(ShareWording.trouble(.closed) == ShareWording.trouble(.timedOut))
        #expect(ShareWording.trouble(.status(0xC000_0022)).contains("C0000022"))
    }

    @Test func nowPlayingSaysTheSongComesFromTheShareOrFromThisDevice() {
        let share = NowPlayingView.source(reach: nil, connected: true, demo: false, share: true)
        let kept = NowPlayingView.source(reach: nil, connected: false, demo: false)
        #expect(share != nil && share != kept)
        #expect(share != NowPlayingView.source(reach: .sameNetwork, connected: true, demo: false))
        // A share that stopped answering: what still plays is what this device kept or had fetched.
        #expect(NowPlayingView.source(reach: nil, connected: true, demo: false, share: false) == kept)
    }

    @Test func aShareThatFailedItsScanOrStoppedAnsweringSaysWhy() {
        var status = ShareStatus()
        #expect(status.trouble == nil)
        status.scan = .failed(.signInFailed)
        #expect(status.trouble == ShareWording.trouble(.signInFailed))
        status.scan = .idle
        status.reachable = false
        #expect(status.trouble == ShareWording.trouble(.unreachable))
        status.reachable = true
        #expect(status.trouble == nil)
    }

    @Test func theNetworkAShareIsOnIsNamedAsAMacsIs() throws {
        let tailscale = try #require(ShareAddress(typed: "smb://nas.tail1a2b3.ts.net/music"))
        let home = try #require(ShareAddress(typed: "smb://192.168.1.20/music"))
        #expect(ShareWording.network(tailscale) == NowPlayingView.reachName(.tailscale))
        #expect(ShareWording.network(home) == NowPlayingView.reachName(.sameNetwork))
    }

    @Test func aCoverIsMadeNoLargerThanAskedAndSomethingThatIsNoPictureIsRefused() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }
        let png = try #require(big.pngData())
        let small = try #require(ShareCovers.shrink(png, to: 300))
        let image = try #require(UIImage(data: small))
        #expect(max(image.size.width * image.scale, image.size.height * image.scale) == 300)
        #expect(small.starts(with: [0xFF, 0xD8]))
        #expect(ShareCovers.shrink(Data("not a picture".utf8), to: 300) == nil)
    }
}
