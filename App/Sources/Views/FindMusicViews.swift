//
// Vespertine — "Find Music on This Mac" and "Enrich Metadata" sheets.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineAudio
import VespertineLibrary
import SwiftUI

// MARK: - Find Music

enum MusicFilter: String, CaseIterable, Identifiable {
    case hiRes = "Hi-Res", lossless = "Lossless", all = "All Music"
    var id: String { rawValue }
    func includes(_ f: FoundAudioFile) -> Bool {
        switch self { case .hiRes: f.isHiRes; case .lossless: f.isLossless; case .all: true }
    }
}

struct FindMusicSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var folders: [FoundFolder] = []
    @State private var scanning = true
    @State private var progress = MusicFinder.Progress(inspected: 0, total: 0)
    @State private var filter: MusicFilter = .hiRes
    @State private var selected = Set<URL>()
    @State private var expanded = Set<URL>()
    /// Starts as Settings › Library › "When adding music" says (see `onAppear`).
    @State private var mode: ImportMode = .copyAndOrganize
    @State private var enrichAfter = true
    @State private var adding = false

    private var visible: [FoundFolder] { folders.filter { !$0.music.filter(filter.includes).isEmpty } }

    /// Second and later copies of identical files (same size and length), in list order.
    private var duplicates: Set<URL> {
        var seen = Set<String>(), dupes = Set<URL>()
        for file in visible.flatMap({ $0.music.filter(filter.includes) }) {
            if !seen.insert(file.duplicateKey).inserted { dupes.insert(file.url) }
        }
        return dupes
    }
    private var selectedFiles: [URL] {
        visible.flatMap { $0.music.filter(filter.includes).map(\.url) }.filter(selected.contains)
    }
    /// What Import & Organize would write: files on another drive are copied in full, files on the
    /// Mac's own volume are APFS clones that take no space.
    private var space: ImportSpace {
        let files = visible.flatMap { $0.music.filter(filter.includes) }.filter { selected.contains($0.url) }
        return ImportSpace.measure(files: files.map { ($0.url, $0.fileSize) },
                                   destination: URL(fileURLWithPath: model.settings.managedFolderPath, isDirectory: true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Find Music on This Mac").font(Typeface.serif(24)).foregroundStyle(Palette.text)
                Text("Vespertine searched your drives with Spotlight and checked every file's real format. Voice recordings, prompts and short clips are left out.")
                    .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 14)

            if scanning {
                VStack(spacing: 12) {
                    ProgressView(value: progress.total > 0 ? Double(progress.inspected) / Double(progress.total) : 0)
                        .progressViewStyle(.linear).tint(Palette.brass).frame(width: 320)
                    Text(progress.total > 0 ? "Checking \(progress.inspected) of \(progress.total) audio files…" : "Searching…")
                        .font(Typeface.mono(11)).foregroundStyle(Palette.text3)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else if folders.isEmpty {
                Text("No music found outside your library.").font(Typeface.serif(17)).foregroundStyle(Palette.text2)
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                HStack {
                    Picker("", selection: $filter) { ForEach(MusicFilter.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Button(allSelected ? "Select None" : "Select All") { toggleAll() }.buttonStyle(QuietButtonStyle(compact: true))
                }
                .padding(.horizontal, 22).padding(.bottom, 10)
                Hairline()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { folder in folderRow(folder); Hairline() }
                    }
                }
                .frame(minHeight: 340)
            }

            Hairline()
            footer
        }
        .frame(width: 720, height: 600)
        .background(Palette.panel)
        .onAppear { mode = model.settings.defaultImportMode }
        .task { await scan() }
        .onChange(of: filter) { selectDefaults() }
    }

    private var allSelected: Bool { !selectedFiles.isEmpty && selectedFiles.count == visible.flatMap { $0.music.filter(filter.includes) }.count }

    private func folderRow(_ folder: FoundFolder) -> some View {
        let files = folder.music.filter(filter.includes)
        let chosen = files.filter { selected.contains($0.url) }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Tri-state: all, none, or some of this folder's tracks.
                Button {
                    let on = chosen < files.count
                    files.forEach { if on { selected.insert($0.url) } else { selected.remove($0.url) } }
                } label: {
                    Image(systemName: chosen == 0 ? "square" : chosen == files.count ? "checkmark.square.fill" : "minus.square.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(chosen == 0 ? Palette.text3 : Palette.brass)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .help(chosen == files.count ? "Deselect this folder" : "Select every track in this folder")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(folder.url.lastPathComponent).font(Typeface.serif(15)).foregroundStyle(Palette.text).lineLimit(1)
                        if !folder.hiRes.isEmpty { StatusBadge(text: "\(folder.hiRes.count) HI-RES", kind: .perfect) }
                    }
                    Text(folder.displayPath).font(Typeface.mono(10)).foregroundStyle(Palette.text3).lineLimit(1).truncationMode(.middle)
                    Text("\(files.count) track\(files.count == 1 ? "" : "s") · \(FoundFolder.formatSummary(of: files)) · \(files.reduce(0) { $0 + $1.duration }.longDuration)\(folder.excludedCount > 0 ? " · \(folder.excludedCount) recordings/clips skipped" : "")")
                        .font(Typeface.ui(11.5)).foregroundStyle(Palette.text2)
                }
                Spacer()
                Text(chosen == files.count ? "" : "\(chosen) of \(files.count)").font(Typeface.mono(10)).foregroundStyle(Palette.brass)
                Button { toggleExpanded(folder.url) } label: {
                    Image(systemName: expanded.contains(folder.url) ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.text2)
                .help(mode == .reference ? "Folders are added whole when referencing" : "Choose individual files")
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            if expanded.contains(folder.url) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files) { file in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { selected.contains(file.url) },
                                                     set: { if $0 { selected.insert(file.url) } else { selected.remove(file.url) } }))
                                .toggleStyle(.checkbox).labelsHidden()
                            Text(file.url.lastPathComponent).font(Typeface.ui(12)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                            if duplicates.contains(file.url) { StatusBadge(text: "DUPLICATE", kind: .converted) }
                            Spacer()
                            FormatLabel(summary: "\(file.format.codec) · \(file.format.shortDescription)", highlight: file.isHiRes)
                            Text(file.duration.clock).font(Typeface.mono(10)).foregroundStyle(Palette.text3).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                .padding(.leading, 52).padding(.trailing, 22).padding(.bottom, 12)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                Picker("", selection: $mode) {
                    Text("Import & Organize").tag(ImportMode.copyAndOrganize)
                    Text("Reference in Place").tag(ImportMode.reference)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text(mode == .copyAndOrganize
                     ? "Copies the selected files into ~/Music/Vespertine as Artist / Album / Track. On the same drive the copies are APFS clones and take no extra space. Your originals are never changed."
                     : "Adds the folders that contain your selection and reads them where they are. Tags you edit later are written to those files.")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
            if mode == .copyAndOrganize, space.bytesToCopy > 0 {
                Text(copyNote(space))
                    .font(Typeface.ui(11)).foregroundStyle(space.fits ? Palette.text3 : Palette.copper)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Toggle("Look up missing details and cover art on MusicBrainz afterwards", isOn: $enrichAfter)
                    .toggleStyle(.checkbox).font(Typeface.ui(12))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button(adding ? "Adding…" : "Add \(selectedFiles.count) Track\(selectedFiles.count == 1 ? "" : "s")") { add() }
                    .buttonStyle(BrassButtonStyle())
                    .disabled(selectedFiles.isEmpty || adding || scanning || (mode == .copyAndOrganize && !space.fits))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private func copyNote(_ space: ImportSpace) -> String {
        let needed = space.bytesToCopy.byteString
        guard let free = space.freeBytes else { return "Copies \(needed) from other drives." }
        if space.fits { return "Copies \(needed) from other drives. \(free.byteString) is free on this Mac." }
        return "That needs \(needed), but only \(free.byteString) is free on this Mac, and Vespertine keeps 2 GB spare. Choose fewer files, or switch to Reference in Place."
    }

    private func toggleExpanded(_ url: URL) { if expanded.contains(url) { expanded.remove(url) } else { expanded.insert(url) } }

    private func toggleAll() {
        let files = visible.flatMap { $0.music.filter(filter.includes).map(\.url) }
        if allSelected { files.forEach { selected.remove($0) } } else { files.forEach { selected.insert($0) } }
    }

    private func selectDefaults() {
        let dupes = duplicates
        selected = Set(visible.flatMap { $0.music.filter(filter.includes).map(\.url) }.filter { !dupes.contains($0) })
    }

    private func scan() async {
        scanning = true
        folders = await model.library.findMusic { p in Task { @MainActor in progress = p } }
        if !folders.contains(where: { !$0.hiRes.isEmpty }) { filter = .lossless }
        if !folders.contains(where: { !$0.lossless.isEmpty }) { filter = .all }
        selectDefaults()
        scanning = false
    }

    private func add() {
        adding = true
        let files = selectedFiles
        let root = URL(fileURLWithPath: model.settings.managedFolderPath, isDirectory: true)
        Task {
            let added = await model.library.add(found: files, mode: mode, managedRoot: root)
            adding = false
            dismiss()
            if enrichAfter && !added.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                model.enrichAlbumKeys = added
            }
        }
    }
}

// MARK: - Enrich Metadata

struct EnrichSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let albumKeys: [String]

    @State private var proposals: [EnrichmentProposal] = []
    @State private var complete = 0
    @State private var chosen = Set<String>()
    @State private var expanded = Set<String>()
    @State private var loading = true
    @State private var progress = (0, 0)
    @State private var correctExisting = false
    @State private var applying = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Enrich Metadata").font(Typeface.serif(24)).foregroundStyle(Palette.text)
                Text("Fills in missing titles, artists, albums, years, track numbers and cover art from file names and MusicBrainz. Changes are written to the files; each file is backed up first, and edits can be reverted.")
                    .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                Toggle("Also correct existing tags when MusicBrainz is certain", isOn: $correctExisting)
                    .toggleStyle(.checkbox).font(Typeface.ui(12)).padding(.top, 4)
                    .onChange(of: correctExisting) { Task { await load() } }
            }
            .padding([.horizontal, .top], 22).padding(.bottom, 14)
            Hairline()

            if loading {
                VStack(spacing: 12) {
                    ProgressView(value: progress.1 > 0 ? Double(progress.0) / Double(progress.1) : 0)
                        .progressViewStyle(.linear).tint(Palette.brass).frame(width: 320)
                    Text("Looking up \(min(progress.0 + 1, max(progress.1, 1))) of \(progress.1) albums…").font(Typeface.mono(11)).foregroundStyle(Palette.text3)
                    Text("MusicBrainz allows one request per second.").font(Typeface.ui(11)).foregroundStyle(Palette.text3)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else if proposals.isEmpty {
                VStack(spacing: 6) {
                    Text("Everything looks complete.").font(Typeface.serif(18)).foregroundStyle(Palette.text2)
                    Text("\(complete) album\(complete == 1 ? "" : "s") checked").font(Typeface.mono(10.5)).foregroundStyle(Palette.text3)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(proposals) { p in row(p); Hairline() }
                    }
                }
                .frame(minHeight: 360)
            }

            Hairline()
            HStack {
                Text(result ?? (loading ? "" : "\(proposals.count) to review · \(complete) already complete"))
                    .font(Typeface.ui(11.5)).foregroundStyle(Palette.text3)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button(applying ? "Applying…" : "Apply \(chosen.count)") { apply() }
                    .buttonStyle(BrassButtonStyle()).disabled(chosen.isEmpty || applying || loading)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
        }
        .frame(width: 720, height: 600)
        .background(Palette.panel)
        .task { await load() }
    }

    private func row(_ p: EnrichmentProposal) -> some View {
        let current = model.library.album(key: p.albumKey)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Toggle("", isOn: Binding(get: { chosen.contains(p.id) }, set: { if $0 { chosen.insert(p.id) } else { chosen.remove(p.id) } }))
                    .toggleStyle(.checkbox).labelsHidden().padding(.top, 2)
                Group {
                    if let data = p.cover, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ArtworkView(key: current?.artworkKey, size: 160, cornerRadius: 0)
                    }
                }
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(p.cover != nil ? Palette.brass.opacity(0.7) : .white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(p.title).font(Typeface.serif(15)).foregroundStyle(Palette.text).lineLimit(1)
                        if let y = p.year { Text(String(y.prefix(4))).font(Typeface.mono(10.5)).foregroundStyle(Palette.text3) }
                    }
                    Text(p.artist).font(Typeface.ui(12)).foregroundStyle(Palette.brassHi)
                    if let current, current.title != p.title || current.artist != p.artist {
                        Text("was: \(current.artist) — \(current.title)").font(Typeface.ui(11)).foregroundStyle(Palette.text3).lineLimit(1)
                    }
                    Text(p.summary).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2)
                    HStack(spacing: 6) {
                        ForEach(Array(p.sources.enumerated()), id: \.offset) { _, s in
                            switch s {
                            case .fileNames: StatusBadge(text: "FILE NAMES")
                            case .musicBrainz(let score, _): StatusBadge(text: "MUSICBRAINZ \(score)%", kind: score >= 95 ? .perfect : .neutral)
                            }
                        }
                        if !p.isHighConfidence { StatusBadge(text: "REVIEW", kind: .converted) }
                    }
                    .padding(.top, 2)
                }
                Spacer()
                Button { if expanded.contains(p.id) { expanded.remove(p.id) } else { expanded.insert(p.id) } } label: {
                    Text(expanded.contains(p.id) ? "Hide" : "\(p.changeCount) changes")
                }
                .buttonStyle(QuietButtonStyle(compact: true))
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            if expanded.contains(p.id) {
                let tracks = model.library.tracks(albumKey: p.albumKey)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(tracks.filter { p.edits[$0.id ?? -1] != nil }) { t in
                        let e = p.edits[t.id!]!
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(Typeface.ui(12)).foregroundStyle(Palette.text)
                            Text(e.fields.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.label): \($0.value ?? "—")" }.joined(separator: " · "))
                                .font(Typeface.mono(10)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 92).padding(.trailing, 22).padding(.bottom, 12)
            }
        }
    }

    private func load() async {
        loading = true
        result = nil
        let keys = albumKeys.isEmpty ? nil : albumKeys
        let r = await model.library.enrichmentProposals(albumKeys: keys, correctExisting: correctExisting) { done, total in progress = (done, total) }
        proposals = r.proposals
        complete = r.complete
        chosen = Set(r.proposals.filter(\.isHighConfidence).map(\.id))
        loading = false
    }

    private func apply() {
        applying = true
        let selected = proposals.filter { chosen.contains($0.id) }
        Task {
            let r = await model.library.apply(selected)
            applying = false
            result = "Updated \(r.written) track\(r.written == 1 ? "" : "s")\(r.failed > 0 ? " · \(r.failed) failed" : "")"
            proposals.removeAll { chosen.contains($0.id) }
            chosen.removeAll()
        }
    }
}
