//
// Vespertine — rich metadata editing (single and batch), MusicBrainz lookup, smart playlist rules.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineAudio
import VespertineLibrary
import SwiftUI
import UniformTypeIdentifiers

struct TagEditorView: View {
    @Environment(AppModel.self) private var model

    @State private var tracks: [Track] = []
    /// The selection `tracks` was loaded for; reloads of the same selection keep what you've typed.
    @State private var loadedIDs: Set<Int64>?
    @State private var draft: [TagField: String] = [:]
    @State private var mixed: Set<TagField> = []
    @State private var edited: Set<TagField> = []
    @State private var custom: [CustomTag] = []
    @State private var artwork: TagEdit.ArtworkChange?
    @State private var saving = false
    @State private var status: String?
    @State private var showArtworkPicker = false
    /// Whether the selection's files can't be rewritten: checked once per selection, off the main thread (asking a
    /// dead share hangs until it times out).
    @State private var readOnlyFiles = false

    struct CustomTag: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
        var original: String?
    }

    private static let mainFields: [TagField] = [.title, .artist, .album, .albumArtist, .composer, .genre, .releaseDate, .label]
    private static let sortFields: [TagField] = [.titleSort, .artistSort, .albumSort, .albumArtistSort]

    var body: some View {
        let ids = model.selectedTrackIDs.isEmpty ? (model.player.current?.track.id.map { Set([$0]) } ?? []) : model.selectedTrackIDs
        VStack(spacing: 0) {
            if tracks.isEmpty {
                Text("Select one or more tracks to view and edit their tags.")
                    .font(Typeface.ui(12)).foregroundStyle(Palette.text3).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        musicBrainzRow.padding(.vertical, 14)
                        ForEach(Self.mainFields, id: \.self) { field($0) }
                        pairRow("Track", .trackNumber, .trackTotal)
                        pairRow("Disc", .discNumber, .discTotal)
                        DisclosureGroup("More") {
                            VStack(spacing: 0) {
                                field(.grouping)
                                field(.comment)
                                field(.isrc)
                                field(.bpm)
                                ForEach(Self.sortFields, id: \.self) { field($0) }
                                field(.musicBrainzReleaseID)
                                field(.musicBrainzRecordingID)
                            }
                            .padding(.top, 8)
                        }
                        .font(Typeface.ui(12)).foregroundStyle(Palette.text2)
                        .padding(.vertical, 6)
                        if tracks.count == 1 { lyrics }
                        customTags
                        technical
                    }
                    .padding(20)
                }
                .scrollContentBackground(.hidden)
                footer
            }
        }
        // Cheap to compare on every update, unlike the sorted list of a large selection.
        .task(id: [ids.hashValue, ids.count, model.library.revision]) { load(ids) }
        .fileImporter(isPresented: $showArtworkPicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let data = try? Data(contentsOf: url) { artwork = .replace(data) }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            artworkWell
            VStack(alignment: .leading, spacing: 3) {
                Text(tracks.count == 1 ? tracks[0].title : "\(tracks.count) tracks selected")
                    .font(Typeface.mono(11)).foregroundStyle(Palette.text).lineLimit(2)
                Text(formatLine).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2)
                if !mixed.isEmpty { Text("Mixed values shown in italics").font(Typeface.ui(11.5)).foregroundStyle(Palette.text3) }
                HStack(spacing: 6) {
                    Button("Choose…") { showArtworkPicker = true }.buttonStyle(QuietButtonStyle(compact: true))
                    Button("Remove") { artwork = .remove }.buttonStyle(QuietButtonStyle(compact: true))
                }
                .padding(.top, 4)
            }
        }
    }

    private var artworkWell: some View {
        ZStack {
            switch artwork {
            case .replace(let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            case .remove:
                Palette.surface.overlay(Image(systemName: "photo").foregroundStyle(Palette.text3))
            case nil:
                ArtworkView(key: commonArtworkKey, size: 160, cornerRadius: 5)
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(artwork == nil ? Palette.hairlineStrong : Palette.brass, lineWidth: 1))
        .dropDestination(for: Data.self) { items, _ in
            guard let data = items.first, NSImage(data: data) != nil else { return false }
            artwork = .replace(data)
            return true
        }
        .help("Drop an image to replace the front cover")
    }

    private var musicBrainzRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tracks.first?.musicBrainzReleaseID != nil ? "Linked to MusicBrainz" : "Look up on MusicBrainz")
                    .font(Typeface.ui(12)).foregroundStyle(Palette.text)
                Text("Correct tags and fetch cover art from the open music database")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3)
            }
            Spacer()
            Button(tracks.first?.musicBrainzReleaseID != nil ? "Review" : "Search") { model.lookupTracks = tracks }
                .buttonStyle(QuietButtonStyle(compact: true))
        }
        .padding(10)
        .background(Palette.brass.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.brass.opacity(0.22)))
    }

    private func field(_ f: TagField) -> some View {
        HStack(spacing: 10) {
            Text(f.label).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3).frame(width: 92, alignment: .trailing)
                .accessibilityHidden(true)
            input(f)
        }
        .padding(.bottom, 7)
    }

    private func pairRow(_ label: String, _ a: TagField, _ b: TagField) -> some View {
        HStack(spacing: 10) {
            Text(label).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3).frame(width: 92, alignment: .trailing)
                .accessibilityHidden(true)
            input(a)
            Text("of").font(Typeface.ui(11.5)).foregroundStyle(Palette.text3).accessibilityHidden(true)
            input(b)
        }
        .padding(.bottom, 7)
    }

    private func input(_ f: TagField) -> some View {
        let isMixed = mixed.contains(f) && !edited.contains(f)
        return TextField(isMixed ? "Mixed" : "", text: Binding(
            get: { draft[f] ?? "" },
            set: { draft[f] = $0; edited.insert(f) }))
            .textFieldStyle(.plain)
            .font(isMixed ? Typeface.ui(12.5).italic() : Typeface.ui(12.5))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(edited.contains(f) ? Palette.brass.opacity(0.6) : Palette.hairline))
            .accessibilityLabel(f.label)   // "Track Total" for the second of "Track … of …"
    }

    private var lyrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Lyrics")
            TextEditor(text: Binding(get: { draft[.lyrics] ?? "" }, set: { draft[.lyrics] = $0; edited.insert(.lyrics) }))
                .font(Typeface.ui(12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 80, maxHeight: 180)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(edited.contains(.lyrics) ? Palette.brass.opacity(0.6) : Palette.hairline))
                .accessibilityLabel("Lyrics")
        }
        .padding(.top, 10)
    }

    private var customTags: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "Custom tags")
                Spacer()
                Button { custom.append(CustomTag(key: "", value: "", original: nil)) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Palette.text2)
                    .accessibilityLabel("Add custom tag")
            }
            ForEach($custom) { $tag in
                HStack(spacing: 6) {
                    TextField("KEY", text: $tag.key).font(Typeface.mono(11))
                    Text("=").foregroundStyle(Palette.text3)
                    TextField("value", text: $tag.value).font(Typeface.mono(11))
                    Button { tag.value = ""; tag.key = tag.key.isEmpty ? "" : tag.key } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.text3).help("Clear value (removes the tag on save)")
                        .accessibilityLabel("Clear value")
                }
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).frame(height: 26)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.top, 14)
    }

    private var technical: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "File")
            if tracks.count == 1, let t = tracks.first {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    row("Format", t.formatSummary)
                    row("Channels", "\(t.channels)")
                    row("Duration", t.duration.clock)
                    if let b = t.bitrate { row("Bitrate", "\(Int(b)) kbps") }
                    row("Size", t.fileSize.byteString)
                    if let g = t.rgTrackGain { row("ReplayGain", String(format: "track %+.2f dB%@", g, t.rgAlbumGain.map { String(format: " · album %+.2f dB", $0) } ?? "")) }
                    if let area = t.sacdArea { row("SACD", "\(area == .stereo ? "Stereo" : "Multichannel") area of a disc image; edits stay in the library") }
                    else if t.cueStartFrame != nil { row("CUE", "Virtual track; edits stay in the library") }
                    row("Plays", "\(t.playCount)")
                }
                Text(model.library.displayPath(t.filePath)).font(Typeface.mono(10)).foregroundStyle(Palette.text3).textSelection(.enabled).lineLimit(3)
            } else {
                Text("\(tracks.count) files · \(tracks.reduce(Int64(0)) { $0 + $1.fileSize }.byteString)")
                    .font(Typeface.mono(11)).foregroundStyle(Palette.text2)
            }
        }
        .padding(.top, 16)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3)
            Text(v).font(Typeface.mono(11)).foregroundStyle(Palette.text2)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(status ?? footerNote).font(Typeface.ui(11)).foregroundStyle(Palette.text3).lineLimit(2)
            Spacer()
            Button("Revert") { revert() }.buttonStyle(QuietButtonStyle(compact: true)).disabled(saving)
                .help(hasChanges ? "Discard unsaved changes" : "Restore the tags from before the last save")
            Button(saving ? "Saving…" : "Save") { save() }.buttonStyle(BrassButtonStyle()).disabled(!hasChanges || saving)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: Logic

    private var hasChanges: Bool {
        !edited.isEmpty || artwork != nil || custom.contains { $0.value != ($0.original ?? "") && !$0.key.isEmpty }
    }

    private var formatLine: String {
        let formats = Set(tracks.map(\.formatSummary))
        return formats.count == 1 ? formats.first! : "\(formats.count) formats"
    }

    private var commonArtworkKey: String? {
        let keys = Set(tracks.map(\.artworkKey))
        return keys.count == 1 ? keys.first! : tracks.first?.artworkKey
    }

    private var footerNote: String {
        let files = Set(tracks.filter { $0.cueStartFrame == nil }.map(\.filePath)).count
        if readOnlyFiles { return "Read-only location · saved in Vespertine's library; the files aren't changed" }
        let kind: String = switch Set(tracks.map(\.codec)).first ?? "" {
        case "FLAC", "Vorbis", "Opus": "Vorbis comments"
        case "MP3", "AIFF", "WAV", "DSF": "ID3v2 tags"
        case "ALAC", "AAC": "MP4 atoms"
        case "APE", "WavPack", "Musepack": "APEv2 tags"
        default: "tags"
        }
        return "Writes \(kind) to \(files) file\(files == 1 ? "" : "s") · backup retained for undo"
    }

    /// Shows the tags of the selection. The library changes under a selection all the time (a scan, an analysis,
    /// this editor's own save), so a reload of the same tracks keeps what you've typed and the last save's result;
    /// only the fields you haven't touched show the fresh values. A new selection, or `discardingEdits`, starts over.
    private func load(_ ids: Set<Int64>, discardingEdits: Bool = false) {
        let previous = tracks
        tracks = model.library.tracks(ids: Array(ids)).sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
        let fresh = discardingEdits || ids != loadedIDs
        loadedIDs = ids
        if fresh { draft = [:]; mixed = []; edited = []; artwork = nil; status = nil; checkWritable() }
        for f in TagField.allCases where !edited.contains(f) {
            let values = Set(tracks.map { f.value(in: $0) ?? "" })
            if values.count == 1 { draft[f] = values.first!; mixed.remove(f) } else { draft[f] = nil; mixed.insert(f) }
        }
        // Custom tags are refreshed only while they're as loaded (a new row or a changed one is yours).
        let untouched = custom.elementsEqual(Self.customTagRows(previous)) { $0.key == $1.key && $0.value == $1.value && $0.original == $1.original }
        if fresh || untouched { custom = Self.customTagRows(tracks) }
    }

    /// One file answers for the lot: they share a source, and each check is a round trip on a share. A share added
    /// read-only needs no check; otherwise the file is asked on a GCD thread, and one that doesn't answer in time
    /// (a dead share) counts as read-only.
    private func checkWritable() {
        guard let first = tracks.first(where: { $0.cueStartFrame == nil }) else { readOnlyFiles = false; return }
        if first.sourceId.map(TagWriter.readOnlyShares(model.library.sources).contains) == true { readOnlyFiles = true; return }
        readOnlyFiles = false
        let url = first.fileURL, selection = loadedIDs
        Task {
            let writable = await NetworkVolume.blocking(timeout: 5, otherwise: false) { TagWriter.isWritable(url) }
            guard loadedIDs == selection else { return }
            readOnlyFiles = !writable
        }
    }

    private static func customTagRows(_ tracks: [Track]) -> [CustomTag] {
        let keys = Set(tracks.flatMap { $0.extraTags.keys }).subtracting(["LABEL", "ORGANIZATION", "PUBLISHER"]).sorted()
        return keys.map { key in
            let values = Set(tracks.map { $0.extraTags[key] ?? "" })
            return CustomTag(key: key, value: values.count == 1 ? values.first! : "", original: values.count == 1 ? values.first! : nil)
        }
    }

    private func save() {
        var fields: [TagField: String?] = [:]
        for f in edited { fields.updateValue(draft[f].flatMap { $0.isEmpty ? nil : $0 }, forKey: f) }
        var customEdits: [String: String?] = [:]
        for tag in custom where !tag.key.isEmpty && tag.value != (tag.original ?? "") {
            customEdits.updateValue(tag.value.isEmpty ? nil : tag.value, forKey: tag.key)
        }
        let edit = TagEdit(fields: fields, custom: customEdits, artwork: artwork)
        let targets = tracks
        let selection = loadedIDs
        saving = true
        Task {
            let result = await model.library.apply(edit, to: targets)
            saving = false
            // Another selection is on screen now: its draft isn't this save's to clear.
            guard loadedIDs == selection else { return }
            if let result {
                var parts = ["Saved \(result.written) file\(result.written == 1 ? "" : "s")"]
                if result.databaseOnly > 0 { parts.append("\(result.databaseOnly) CUE track(s) in library") }
                if !result.failures.isEmpty { parts.append("\(result.failures.count) failed: \(result.failures[0].message)") }
                status = parts.joined(separator: " · ")
            }
            // Saved: the reload the save brings shows what was written. A failure keeps the draft to try again.
            if let result, result.failures.isEmpty {
                edited = []
                artwork = nil
                custom = Self.customTagRows(tracks)
            }
        }
    }

    private func revert() {
        if hasChanges {
            load(loadedIDs ?? Set(tracks.compactMap(\.id)), discardingEdits: true)
        } else {
            let targets = tracks
            Task {
                let restored = await model.library.revert(targets)
                status = "Restored previous tags for \(restored) track(s)"
            }
        }
    }
}

// MARK: - MusicBrainz

struct MusicBrainzSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]

    @State private var artist = ""
    @State private var album = ""
    @State private var results: [MBReleaseSummary] = []
    @State private var selected: MBReleaseSummary.ID?
    @State private var release: MBRelease?
    @State private var cover: Data?
    @State private var useCover = true
    @State private var busy = false
    @State private var progress: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MusicBrainz Lookup").font(Typeface.serif(22))
            HStack {
                TextField("Artist", text: $artist)
                TextField("Album", text: $album)
                Button("Search") { search() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 16) {
                List(results, selection: $selected) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.title).font(Typeface.ui(12.5, weight: .medium))
                            Spacer()
                            Text("\(r.score)%").font(Typeface.mono(10)).foregroundStyle(r.score > 90 ? Palette.brass : Palette.text3)
                        }
                        Text(r.artist).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2)
                        Text([r.date, r.country, r.format, r.label, "\(r.trackCount) tracks"].compactMap { $0 }.joined(separator: " · "))
                            .font(Typeface.mono(9.5)).foregroundStyle(Palette.text3)
                    }
                    .padding(.vertical, 2)
                    .tag(r.id)
                }
                .frame(width: 300)
                VStack(alignment: .leading, spacing: 8) {
                    if let release {
                        HStack(alignment: .top, spacing: 12) {
                            if let cover, let image = NSImage(data: cover) {
                                Image(nsImage: image).resizable().frame(width: 90, height: 90).clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(release.title).font(Typeface.serif(17))
                                Text(release.artist).foregroundStyle(Palette.brassHi)
                                Text([release.date, release.label, release.genre].compactMap { $0 }.joined(separator: " · "))
                                    .font(Typeface.mono(10)).foregroundStyle(Palette.text3)
                                if cover != nil { Toggle("Embed cover art", isOn: $useCover).controlSize(.small) }
                            }
                        }
                        Table(mapping(release)) {
                            TableColumn("Current") { Text($0.current).foregroundStyle(Palette.text2) }
                            TableColumn("MusicBrainz") { Text($0.proposed) }
                        }
                    } else if busy {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(results.isEmpty ? "Search to find matching releases." : "Choose a release to preview changes.")
                            .foregroundStyle(Palette.text3).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 380)
            }
            .frame(height: 360)
            if let error { Text(error).foregroundStyle(Palette.copper).font(Typeface.ui(11.5)) }
            HStack {
                Text("Data from MusicBrainz and the Cover Art Archive (open, community-maintained).")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                if let progress {
                    ProgressView(value: Double(progress), total: Double(max(tracks.count, 1))).frame(width: 120)
                    Text("\(progress + 1) of \(tracks.count)").font(Typeface.mono(11)).foregroundStyle(Palette.text2)
                }
                Button("Apply to \(tracks.count) Track\(tracks.count == 1 ? "" : "s")") { apply() }
                    .buttonStyle(BrassButtonStyle()).disabled(release == nil || busy)
            }
        }
        .padding(22)
        .frame(width: 780)
        .background(Palette.panel)
        .onAppear {
            artist = tracks.first?.displayAlbumArtist ?? ""
            album = tracks.first?.album ?? ""
            search()
        }
        .onChange(of: selected) { _, id in if let id { load(id) } }
    }

    struct MappingRow: Identifiable {
        let id: Int
        let current: String
        let proposed: String
    }

    private func mapping(_ r: MBRelease) -> [MappingRow] {
        tracks.enumerated().map { i, t in
            let e = r.edit(for: t, index: i)
            let new = e?.fields[.title].flatMap { $0 } ?? "—"
            let number = e?.fields[.trackNumber].flatMap { $0 }.map { "\($0). " } ?? ""
            return MappingRow(id: i, current: "\(t.trackNumber.map { "\($0). " } ?? "")\(t.title)", proposed: number + new)
        }
    }

    private func search() {
        busy = true; error = nil; release = nil; selected = nil
        Task {
            do {
                results = try await MusicBrainzClient.shared.searchReleases(artist: artist, album: album)
                if let best = results.first, best.score >= 95 { selected = best.id }
            } catch { self.error = "Search failed: \(error.localizedDescription)" }
            busy = false
        }
    }

    private func load(_ id: String) {
        busy = true; release = nil; cover = nil
        Task {
            do {
                let loaded = try await MusicBrainzClient.shared.release(id: id)
                guard selected == id else { return }
                release = loaded
                if model.settings.fetchArtworkOnline {
                    let artwork = try? await MusicBrainzClient.shared.frontCover(releaseID: id, releaseGroupID: loaded.releaseGroupID)
                    guard selected == id else { return }
                    cover = artwork
                }
            } catch {
                guard selected == id else { return }
                self.error = "Couldn't load the release: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func apply() {
        guard let release else { return }
        busy = true
        progress = 0
        Task {
            var failures = 0
            for (i, t) in tracks.enumerated() {
                progress = i
                guard var edit = release.edit(for: t, index: i) else { continue }
                if useCover, let cover { edit.artwork = .replace(cover) }
                if let result = await model.library.apply(edit, to: [t]) { failures += result.failures.count }
                else { failures += 1 }
            }
            busy = false
            progress = nil
            if failures == 0 { dismiss() }
            else { error = "Could not update \(failures) track(s): \(model.library.lastError ?? "unknown error")" }
        }
    }
}

// MARK: - Smart playlist editor

struct SmartPlaylistEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @State private var name = ""
    @State private var rules = SmartRules(rules: [])
    @State private var limitOn = false
    @State private var limit = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Smart Playlist").font(Typeface.serif(22))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Text("Match")
                Picker("Match", selection: $rules.match) {
                    Text("all").tag(SmartRules.Match.all)
                    Text("any").tag(SmartRules.Match.any)
                }
                .labelsHidden().fixedSize()
                Text("of the following rules:")
            }
            ForEach($rules.rules) { $rule in
                HStack {
                    Picker("Field", selection: $rule.field) { ForEach(SmartRule.Field.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .labelsHidden().frame(width: 170)
                        .onChange(of: rule.field) {
                            // Keep the comparison valid for the new field (e.g. no "contains" for a sample rate).
                            if !rule.field.operators.contains(rule.op) { rule.op = rule.field.operators[0] }
                            if rule.field == .verdict, FileAnalysis.Verdict(rawValue: rule.value) == nil { rule.value = FileAnalysis.Verdict.upsampled.rawValue }
                        }
                    Picker("Condition", selection: $rule.op) { ForEach(rule.field.operators, id: \.self) { Text($0.label).tag($0) } }
                        .labelsHidden().frame(width: 140)
                    if rule.field == .verdict {
                        Picker("Value", selection: $rule.value) {
                            ForEach([FileAnalysis.Verdict.genuine, .possibleLossyOrigin, .upsampled, .paddedBitDepth, .bandwidthExtended, .notApplicable], id: \.self) {
                                Text(AnalysisVerdictText.badge($0).capitalized).tag($0.rawValue)
                            }
                        }
                        .labelsHidden()
                    } else if rule.op != .isTrue && rule.op != .isFalse {
                        TextField(rule.field.placeholder, text: $rule.value).textFieldStyle(.roundedBorder)
                    } else { Spacer() }
                    Button { rules.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        .accessibilityLabel("Remove rule")
                }
            }
            Button { rules.rules.append(SmartRule(field: .artist, op: .contains)) } label: { Label("Add Rule", systemImage: "plus") }
                .buttonStyle(QuietButtonStyle(compact: true))
            HStack {
                Toggle("Limit to", isOn: $limitOn)
                TextField("", value: $limit, format: .number).frame(width: 60).textFieldStyle(.roundedBorder).disabled(!limitOn)
                Text("tracks, sorted by")
                Picker("Sort by", selection: $rules.sort) {
                    Text("Album").tag(SmartRules.Sort.album)
                    Text("Recently Added").tag(SmartRules.Sort.recentlyAdded)
                    Text("Most Played").tag(SmartRules.Sort.mostPlayed)
                    Text("Recently Played").tag(SmartRules.Sort.recentlyPlayed)
                    Text("Random").tag(SmartRules.Sort.random)
                }
                .labelsHidden().fixedSize()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button("Save") {
                    rules.limit = limitOn ? limit : nil
                    model.library.renamePlaylist(playlist, to: name)
                    model.library.updateRules(playlist, rules)
                    dismiss()
                }
                .buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(Palette.panel)
        .onAppear {
            name = playlist.name
            rules = playlist.smartRules ?? SmartRules(rules: [])
            limitOn = rules.limit != nil
            limit = rules.limit ?? 100
        }
    }
}
