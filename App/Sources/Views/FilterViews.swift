//
// Vespertine — the filter bar of every page: format chips, the Filters panel with every facet, and a token for
// each choice made there.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import VespertineLibrary
import SwiftUI

/// What a page lists, as its filter bar sees it.
struct FilterItems {
    var facts: [FilterFacts]
    /// Whether item `i` is (or, for an album, holds) a favorite.
    var favorite: (Int) -> Bool
    /// "album" or "song", for counts.
    var unit: String
    /// Song pages: the songs, so the panel can offer to analyze the ones without results.
    var tracks: [Track]? = nil
    /// Other things the page shows (search: its albums), so their formats get chips and facets too.
    var alsoOffering: [FilterFacts] = []

    func units(_ n: Int) -> String { "\(n.formatted()) \(unit)\(n == 1 ? "" : "s")" }

    func matching(_ filter: LibraryFilter) -> Int {
        filter.isEmpty ? facts.count : facts.indices.count { filter.matches(facts[$0], favorite: favorite($0)) }
    }
}

extension FilterItems {
    @MainActor static func albums(_ albums: [Album], model: AppModel) -> FilterItems {
        let favorites = model.library.favoriteAlbumKeys
        return FilterItems(facts: albums.map(\.facts), favorite: { favorites.contains(albums[$0].key) }, unit: "album")
    }

    @MainActor static func songs(_ tracks: [Track], facts: [FilterFacts], model: AppModel, alsoOffering: [FilterFacts] = []) -> FilterItems {
        let favorites = model.library.favoriteIDs
        return FilterItems(facts: facts, favorite: { favorites.contains(tracks[$0].id ?? -1) }, unit: "song", tracks: tracks,
                           alsoOffering: alsoOffering)
    }
}

struct FilterBar: View {
    @Environment(AppModel.self) private var model
    let scope: FilterScope
    let items: FilterItems
    @State private var showPanel = false
    @State private var panelFacet: Facet?

    var body: some View {
        let filter = model.filter(scope)
        let available = FilterAvailability(items.facts, favorite: items.favorite)
            .union(FilterAvailability(items.alsoOffering, favorite: { _ in false }))
        let tokens = tokens(filter)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                FiltersButton(count: tokens.count, isOpen: showPanel) { panelFacet = nil; showPanel.toggle() }
                    .popover(isPresented: $showPanel, arrowEdge: .bottom) {
                        FilterPanel(scope: scope, items: items, facet: $panelFacet).environment(model)
                    }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(.all, filter)
                        ForEach(QuickChip.formats.filter { available.offers($0, in: filter) }) { chip($0, filter) }
                        let conditions = QuickChip.conditions.filter { available.offers($0, in: filter) }
                        if !conditions.isEmpty { divider }
                        ForEach(conditions) { chip($0, filter) }
                        if scope.offersFavorites && available.offers(.favorite, in: filter) {
                            divider
                            chip(.favorite, filter)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            if !tokens.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tokens, id: \.facet) { token in
                            FilterToken(title: token.facet.label, values: token.values) {
                                panelFacet = token.facet
                                showPanel = true
                            } remove: {
                                model.updateFilter(scope) { f in
                                    // Formats with chips stay; the token stands only for the ones without.
                                    if token.facet == .format { f[.format].subtract(QuickChip.unchipped.map(\.rawValue)) } else { f[token.facet] = [] }
                                }
                            }
                        }
                        Button("Clear All") { model.setFilter(LibraryFilter(), for: scope) }
                            .buttonStyle(.plain)
                            .font(Typeface.ui(11.5, weight: .medium))
                            .foregroundStyle(Palette.text2)
                            .padding(.leading, 4)
                    }
                    .padding(.vertical, 1)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .animation(.easeOut(duration: 0.15), value: tokens.count)
        .onChange(of: model.filterPanelRequest, initial: true) { _, request in
            guard let request, request.scope == scope else { return }
            panelFacet = request.facet
            showPanel = true
            model.filterPanelRequest = nil
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairlineStrong).frame(width: 1, height: 14).padding(.horizontal, 2)
    }

    private func chip(_ chip: QuickChip, _ filter: LibraryFilter) -> some View {
        Chip(title: chip.label, symbol: chip.symbol, isOn: chip.isOn(filter)) {
            model.updateFilter(scope) { chip.toggle(&$0) }
        }
    }

    /// One token per facet chosen in the panel (formats only for those no chip stands for).
    private func tokens(_ filter: LibraryFilter) -> [(facet: Facet, values: String)] {
        Facet.allCases.compactMap { facet in
            guard !scope.fixedFacets.contains(facet) else { return nil }
            var keys = filter[facet]
            if facet == .format { keys.formIntersection(QuickChip.unchipped.map(\.rawValue)) }
            guard !keys.isEmpty else { return nil }
            let names = model.facetNames(facet)
            // Decades read oldest first here ("1970s, 1980s"); the panel lists them newest first.
            let ordered = facet == .decade ? facet.sorted(keys).reversed() : facet.sorted(keys)
            let list = ordered.map { names[$0] ?? facet.name(of: $0) }
            return (facet, list.count > 3 ? list.prefix(2).joined(separator: ", ") + " +\(list.count - 2)" : list.joined(separator: ", "))
        }
    }
}

/// Opens the Filters panel; shows how many of its facets are in use.
struct FiltersButton: View {
    let count: Int
    var isOpen = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let active = count > 0
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10.5, weight: .semibold))
                Text("Filters").font(Typeface.ui(11.5, weight: .medium))
                if active {
                    Text("\(count)")
                        .font(Typeface.mono(9.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x1A140A))
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Palette.brass, in: Capsule())
                }
            }
            .foregroundStyle(active || isOpen ? Palette.brassHi : hovering ? Palette.text : Palette.text2)
            .padding(.leading, 10).padding(.trailing, active ? 4 : 10)
            .frame(height: 24)
            .background(active || isOpen ? Palette.brass.opacity(0.08) : Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(active || isOpen ? Palette.brass.opacity(0.45) : Palette.hairlineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Filter by genre, year, artist, format, sample rate, bit depth, channels, analysis and source")
        .accessibilityLabel(active ? "Filters, \(count) in use" : "Filters")
    }
}

/// A choice made in the panel: "GENRE  Jazz, Blues  ×". Clicking it reopens the panel there.
struct FilterToken: View {
    let title: String
    let values: String
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(Typeface.ui(9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Palette.brass.opacity(0.8))
                    Text(values)
                        .font(Typeface.ui(11.5))
                        .foregroundStyle(Palette.brassHi)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this filter")
            .accessibilityLabel("Remove \(title) filter")
        }
        .padding(.trailing, 3)
        .background(Palette.brass.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.brass.opacity(0.45), lineWidth: 1))
        .fixedSize()
    }
}

/// Every facet of a page, each a list of values with how many items each would leave.
struct FilterPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: FilterScope
    let items: FilterItems
    @Binding var facet: Facet?
    @State private var search = ""

    var body: some View {
        let filter = model.filter(scope)
        let facets = offered(filter)
        let current = facet.flatMap { facets.contains($0) ? $0 : nil } ?? facets.first
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(facets) { f in facetRow(f, selected: f == current, count: filter[f].count) }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: 176)
                .background(Palette.panel)
                Hairline(vertical: true)
                if let current {
                    values(current, filter)
                } else {
                    Text("Everything here is alike: nothing to filter by.")
                        .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Hairline()
            HStack(spacing: 10) {
                let matching = items.matching(filter)
                Text(filter.isEmpty ? "All \(items.units(items.facts.count))" : "\(matching.formatted()) of \(items.units(items.facts.count))")
                    .font(Typeface.mono(10.5))
                    .foregroundStyle(matching == 0 ? Palette.copper : Palette.text3)
                Spacer()
                Button("Clear All") { model.setFilter(LibraryFilter(), for: scope) }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(filter.isEmpty)
                Button("Done") { dismiss() }
                    .buttonStyle(BrassButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 580, height: 440)
        .background(Palette.surface)
        .onChange(of: current) { search = "" }
    }

    /// Facets worth offering here: not fixed by the page, and with a choice to make (two values or more) or
    /// something already chosen.
    private func offered(_ filter: LibraryFilter) -> [Facet] {
        Facet.allCases.filter { f in
            guard !scope.fixedFacets.contains(f) else { return false }
            if !filter[f].isEmpty { return true }
            var seen = Set<String>()
            for facts in items.facts + items.alsoOffering {
                seen.formUnion(facts.keys(f))
                if seen.count > 1 { return true }
            }
            return false
        }
    }

    private static func symbol(_ f: Facet) -> String {
        switch f {
        case .genre: "guitars"
        case .decade: "calendar"
        case .artist: "person"
        case .format: "doc.text"
        case .sampleRate: "waveform"
        case .bitDepth: "square.3.layers.3d"
        case .channels: "hifispeaker.2"
        case .analysis: "waveform.badge.magnifyingglass"
        case .source: "externaldrive"
        }
    }

    private func facetRow(_ f: Facet, selected: Bool, count: Int) -> some View {
        Button { facet = f } label: {
            HStack(spacing: 9) {
                Image(systemName: Self.symbol(f))
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected || count > 0 ? Palette.brassHi : Palette.text3)
                    .frame(width: 18)
                Text(f.label)
                    .font(Typeface.ui(12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Palette.text : Palette.text2)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(Typeface.mono(9.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x1A140A))
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Palette.brass, in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func values(_ f: Facet, _ filter: LibraryFilter) -> some View {
        let counts = filter.counts(of: f, in: items.facts, favorite: items.favorite)
        let names = model.facetNames(f)
        func name(_ key: String) -> String { names[key] ?? f.name(of: key) }
        var keys = filter.values(of: f, in: items.facts + items.alsoOffering)
        // Names people read alphabetically (genres, artists, sources) sort by the name shown.
        if [.genre, .artist, .source].contains(f) {
            keys.sort { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        }
        let long = keys.count > 14
        let chosen = filter[f]
        // Long lists leave out what nothing would match (unless chosen); short ones keep their shape and dim it.
        let shown = keys.filter { key in
            (!long || counts[key, default: 0] > 0 || chosen.contains(key))
                && (search.isEmpty || name(key).localizedStandardContains(search))
        }
        let numeric = [.sampleRate, .bitDepth, .channels, .decade].contains(f)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(f.label).font(Typeface.serif(17)).foregroundStyle(Palette.text)
                Spacer()
                if !chosen.isEmpty {
                    Button("Clear") { model.updateFilter(scope) { $0[f] = [] } }
                        .buttonStyle(.plain)
                        .font(Typeface.ui(11.5, weight: .medium))
                        .foregroundStyle(Palette.brassHi)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            if long || f == .genre || f == .artist {
                SearchField(prompt: "Search \(f.label.lowercased())s", text: $search)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown, id: \.self) { key in
                        valueRow(f, key: key, name: name(key), count: counts[key, default: 0], on: chosen.contains(key), numeric: numeric)
                    }
                    if shown.isEmpty {
                        Text(search.isEmpty ? "Nothing to choose with the other filters as they are." : "No \(f.label.lowercased()) matches “\(search)”.")
                            .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                            .padding(16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            if f == .analysis, let tracks = items.tracks {
                let pending = tracks.filter { $0.analysisVerdict == nil && $0.isLossless && !$0.isDSD }
                if !pending.isEmpty {
                    Hairline()
                    Button("Analyze \(pending.count.formatted()) \(pending.count == 1 ? "Song" : "Songs") Without Results") {
                        model.analysis.analyzeNow(pending)
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func valueRow(_ f: Facet, key: String, name: String, count: Int, on: Bool, numeric: Bool) -> some View {
        Button { model.updateFilter(scope) { $0.toggle(key, in: f) } } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Palette.brass : Palette.text3)
                Text(name)
                    .font(numeric ? Typeface.mono(12) : Typeface.ui(12.5))
                    .foregroundStyle(on ? Palette.brassHi : count == 0 ? Palette.text3 : Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(count.formatted())
                    .font(Typeface.mono(10.5))
                    .foregroundStyle(Palette.text3)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(on ? Palette.brass.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? "Selected" : "")
        .accessibilityHint("\(count) \(items.unit)\(count == 1 ? "" : "s")")
    }
}

/// A small search field in the app's style.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.text3)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Typeface.ui(12.5))
                .foregroundStyle(Palette.text)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.text3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.hairlineStrong, lineWidth: 1))
    }
}

/// Shown when a page's filter leaves nothing.
struct NoMatchesView: View {
    let unit: String
    let clear: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(Palette.brass)
            Text("No \(unit)s match these filters").font(Typeface.serif(18)).foregroundStyle(Palette.text2)
            Button("Clear Filters", action: clear).buttonStyle(QuietButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// Play and Shuffle for a page header.
struct PlayShuffleButtons: View {
    var showsPlay = true
    let disabled: Bool
    let play: (_ shuffled: Bool) -> Void

    var body: some View {
        Button { play(true) } label: { Label("Shuffle", systemImage: "shuffle") }
            .buttonStyle(QuietButtonStyle())
            .disabled(disabled)
        if showsPlay {
            Button { play(false) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(BrassButtonStyle())
                .disabled(disabled)
        }
    }
}
