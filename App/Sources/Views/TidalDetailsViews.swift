//
// Vespertine: the inspector's TIDAL group for a TIDAL song: its IDs, what TIDAL lists and what was delivered, release facts,
// ReplayGain, credits and lyrics (both fetched when it opens), and its download.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import SwiftUI
import VespertineLibrary
import VespertineTidal

struct TidalDetailsSection: View {
    @Environment(AppModel.self) private var model
    let track: Track
    @State private var credits: [TidalCredit] = []
    @State private var lyrics: String?
    @State private var upc: String?
    @State private var loadedFor: Int?

    private var record: TidalTrackRecord? { track.id.flatMap { model.library.tidalRecords[$0] } }
    private var tidalId: Int? { record?.tidalId ?? URL(string: track.location).flatMap(TidalPlayback.trackId(from:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "TIDAL")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                if let tidalId { copyable("Track ID", String(tidalId)) }
                if let album = record?.albumId { copyable("Album ID", String(album)) }
                if let listed = record?.listedQuality { row("Listed", Self.listed(listed, tags: record?.mediaTags ?? [])) }
                if record?.formatIsProbed == true { row("Delivered", track.formatSummary) }
                else if record != nil { row("Delivered", String(localized: "Not played yet", comment: "TIDAL details: the stream's real format is known once played")) }
                if let isrc = track.isrc { copyable("ISRC", isrc) }
                if let upc { copyable("UPC", upc) }
                if let copyright = record?.copyright { row("Copyright", copyright) }
                if let date = track.releaseDate { row("Released", date) }
                if record?.explicit == true { row("Explicit", String(localized: "Yes")) }
                if let popularity = record?.popularity { row("Popularity", "\(popularity)") }
                if let gain = track.rgTrackGain {
                    row("ReplayGain", gain.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always())) + " dB")
                }
                if let reason = record?.unavailableReason {
                    row("Streaming", reason == TidalTrackRecord.notInFavorites
                        ? String(localized: "No longer in your TIDAL favorites; the download stays")
                        : Playability.notAvailableHere)
                }
            }
            download
            if !credits.isEmpty {
                SectionLabel(text: String(localized: "Credits")).padding(.top, 10)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    ForEach(credits, id: \.type) { credit in
                        GridRow {
                            Text(verbatim: credit.type).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3)
                            Text(verbatim: credit.contributors.map(\.name).joined(separator: ", "))
                                .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).textSelection(.enabled)
                        }
                    }
                }
            }
            if let lyrics {
                SectionLabel(text: String(localized: "Lyrics")).padding(.top, 10)
                ScrollView {
                    Text(verbatim: lyrics).font(Typeface.ui(12)).foregroundStyle(Palette.text2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(6)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.top, 16)
        .task(id: tidalId) { await load() }
    }

    @ViewBuilder private var download: some View {
        if let path = record?.downloadPath {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Downloaded at", comment: "TIDAL details: followed by the downloaded file's path").font(Typeface.ui(11.5)).foregroundStyle(Palette.text3)
                Button(model.library.displayPath(path)) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .buttonStyle(.link).font(Typeface.mono(10)).lineLimit(2)
            }
            .padding(.top, 6)
        } else if track.id != nil {
            Button("Download") { model.download(libraryTracks: [track]) }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled(!model.tidal.state.isSignedIn)
                .padding(.top, 6)
        }
    }

    /// "Hi-Res Lossless · HIRES_LOSSLESS, LOSSLESS".
    static func listed(_ quality: String, tags: [String]) -> String {
        let name = switch quality {
        case "HI_RES_LOSSLESS", "HI_RES": String(localized: "Hi-Res Lossless")
        case "LOSSLESS": String(localized: "Lossless")
        case "HIGH": String(localized: "High (AAC 320)")
        case "LOW": String(localized: "Low (AAC 96)")
        default: quality
        }
        let readable = tags.map { tag in
            switch tag {
            case "HIRES_LOSSLESS": String(localized: "Hi-Res Lossless")
            case "LOSSLESS": String(localized: "Lossless")
            case "DOLBY_ATMOS": "Dolby Atmos"
            case "SONY_360RA": "360 Reality Audio"
            default: tag
            }
        }.filter { $0 != name }
        return ([name] + readable).joined(separator: " · ")
    }

    /// Credits, lyrics and the album's UPC, asked of TIDAL when the group opens (interactive priority; nothing while offline).
    private func load() async {
        guard let tidalId, loadedFor != tidalId else { return }
        loadedFor = tidalId
        credits = []; lyrics = nil; upc = nil
        guard model.tidal.isOnline, let catalog = model.tidal.catalog else { return }
        async let credits = try? catalog.credits(tidalId)
        async let lyrics = try? catalog.lyrics(tidalId)
        let album = record?.albumId
        self.credits = await credits ?? []
        self.lyrics = await lyrics ?? nil
        if let album { upc = (try? await catalog.album(album))?.upc }
    }

    private func row(_ k: LocalizedStringKey, _ v: String) -> some View {
        GridRow {
            Text(k).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3)
            Text(verbatim: v).font(Typeface.mono(11)).foregroundStyle(Palette.text2)
        }
    }

    private func copyable(_ k: LocalizedStringKey, _ v: String) -> some View {
        GridRow {
            Text(k).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3)
            Text(verbatim: v).font(Typeface.mono(11)).foregroundStyle(Palette.text2).textSelection(.enabled)
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(v, forType: .string)
                    }
                }
        }
    }
}

/// The TIDAL part of a song's or album's context menu (only while TIDAL is on, and only for TIDAL songs): Download or Remove
/// Download, Show on TIDAL, Refresh from TIDAL.
struct TidalRowsMenu: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        let tidal = model.library.includesTidal ? tracks.filter(\.isTidalTrack) : []
        if !tidal.isEmpty {
            let downloaded = tidal.filter { $0.id.flatMap { model.library.tidalRecords[$0]?.downloadPath } != nil }
            Divider()
            if downloaded.count < tidal.count {
                Button("Download") { model.download(libraryTracks: tidal.filter { !downloaded.contains($0) }) }
                    .disabled(!model.tidal.state.isSignedIn)
            }
            if !downloaded.isEmpty { Button("Remove Download") { model.removeDownload(downloaded) } }
            if let id = URL(string: tidal[0].location).flatMap(TidalPlayback.trackId(from:)) {
                Button("Show on TIDAL") { NSWorkspace.shared.open(URL(string: "https://tidal.com/browse/track/\(id)")!) }
            }
            Button("Refresh from TIDAL") { model.refreshFromTidal(tidal) }
                .disabled(!model.tidal.isOnline)
        }
    }
}
