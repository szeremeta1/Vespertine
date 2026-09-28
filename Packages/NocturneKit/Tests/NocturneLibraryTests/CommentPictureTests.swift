//
// Nocturne — cover art stored as a METADATA_BLOCK_PICTURE comment is found.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import NocturneLibrary

@Suite("Pictures in Vorbis comments")
struct CommentPictureTests {
    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { be32(v).reversed() }

    private func picture(type: Int, image: [UInt8]) -> [UInt8] {
        let mime = Array("image/jpeg".utf8)
        return be32(type) + be32(mime.count) + mime + be32(0) + be32(600) + be32(600) + be32(24) + be32(0) + be32(image.count) + image
    }

    private func commentBlock(_ comments: [String]) -> Data {
        let vendor = Array("test".utf8)
        var out = le32(vendor.count) + vendor + le32(comments.count)
        for c in comments { let u = Array(c.utf8); out += le32(u.count) + u }
        return Data(out)
    }

    @Test("The front cover is decoded from a METADATA_BLOCK_PICTURE comment")
    func frontCover() {
        let back: [UInt8] = [1, 2, 3], front: [UInt8] = [9, 8, 7, 6]
        let block = commentBlock([
            "TITLE=Song",
            "METADATA_BLOCK_PICTURE=" + Data(picture(type: 4, image: back)).base64EncodedString(),
            "metadata_block_picture=" + Data(picture(type: 3, image: front)).base64EncodedString(),
        ])
        #expect(CommentPictures.cover(inVorbisComment: block) == Data(front))
    }

    @Test("Any picture is used when there's no front cover, and junk is ignored")
    func fallbacks() {
        let other: [UInt8] = [5, 5, 5]
        #expect(CommentPictures.cover(inVorbisComment: commentBlock([
            "METADATA_BLOCK_PICTURE=not base64 !!", "METADATA_BLOCK_PICTURE=" + Data(picture(type: 0, image: other)).base64EncodedString(),
        ])) == Data(other))
        #expect(CommentPictures.cover(inVorbisComment: commentBlock(["TITLE=x"])) == nil)
        #expect(CommentPictures.cover(inVorbisComment: Data([1, 2])) == nil)
    }

    @Test("A FLAC file's comment block is found and its picture read")
    func flacFile() throws {
        let image: [UInt8] = Array(repeating: 0xAB, count: 300)
        let comments = commentBlock(["METADATA_BLOCK_PICTURE=" + Data(picture(type: 3, image: image)).base64EncodedString()])
        var file = Array("fLaC".utf8)
        file += [0x00, 0x00, 0x00, 34] + Array(repeating: 0, count: 34)                            // STREAMINFO
        file += [0x84] + [UInt8(comments.count >> 16 & 0xFF), UInt8(comments.count >> 8 & 0xFF), UInt8(comments.count & 0xFF)]
        file += Array(comments)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comment-picture-\(UUID()).flac")
        try Data(file).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CommentPictures.flacCover(at: url) == Data(image))
    }
}

@Suite("Folder art")
struct FolderArtTests {
    @Test("Disc folders are recognized, album folders aren't")
    func discFolders() {
        for name in ["CD 01", "cd1", "Disc 2", "Disk 3", "Digital Media 01", "12 Vinyl 02", "12\" Vinyl 1", "Vinyl 1", "SACD 01", "DVD-Audio 1", "Side A"] {
            #expect(ArtworkStore.isDiscFolder(name), "\(name)")
        }
        for name in ["Goodbye Yellow Brick Road (1973)", "CDs", "Discovery", "Sidewinder", "The Disc Jockeys"] {
            #expect(!ArtworkStore.isDiscFolder(name), "\(name)")
        }
    }

    @Test("A multi-disc album's cover next to its disc folders is found")
    func parentCover() throws {
        let album = FileManager.default.temporaryDirectory.appendingPathComponent("folder-art-\(UUID())")
        let disc = album.appendingPathComponent("CD 01")
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: album) }
        try Data([1, 2, 3]).write(to: album.appendingPathComponent("cover.jpg"))
        #expect(ArtworkStore.folderImage(near: disc.appendingPathComponent("01 Song.flac")) == Data([1, 2, 3]))
        #expect(ArtworkStore.folderImage(near: album.appendingPathComponent("Loose.flac")) == Data([1, 2, 3]))
        let other = album.appendingPathComponent("Bonus Material")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(ArtworkStore.folderImage(near: other.appendingPathComponent("x.flac")) == nil)
    }
}
