//
// Vespertine — the transitions switch: its glyph, its button and the note shown the first time it's turned on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio
import VespertineLibrary

/// Two of Vespertine's crescents, one passing into the other. Each is the logo's moon: a disc with a disc 0.86 its
/// size cut from it, set 0.42 of its radius right and 0.22 up (docs/brand/logo-mono-ivory.svg). A thin gap keeps the
/// front one apart from the one behind it.
nonisolated struct TransitionsGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let r = side * 0.34
        func crescent(_ cx: CGFloat, _ cy: CGFloat) -> Path {
            let moon = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            let cut = r * 0.86, x = cx + r * 0.42, y = cy - r * 0.22
            return moon.subtracting(Path(ellipseIn: CGRect(x: x - cut, y: y - cut, width: 2 * cut, height: 2 * cut)))
        }
        let back = crescent(rect.midX - side * 0.15, rect.midY + side * 0.05)
        let front = crescent(rect.midX + side * 0.15, rect.midY - side * 0.05)
        let gap = front.strokedPath(StrokeStyle(lineWidth: side * 0.09, lineJoin: .round))
        return back.subtracting(gap).union(front)
    }
}

/// Vespertine's one moon, the brand mark (docs/brand/mark-flat.svg, a 512-unit square): a disc with a smaller disc cut
/// from its upper right.
nonisolated struct VespertineMoon: Shape {
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 512
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var path = Path()
        path.move(to: point(473.82, 390.01))
        path.addCurve(to: point(363.52, 419.84), control1: point(441.48, 409.04), control2: point(403.76, 419.84))
        path.addCurve(to: point(143.36, 199.68), control1: point(241.93, 419.84), control2: point(143.36, 321.27))
        path.addCurve(to: point(269.78, 0.70), control1: point(143.36, 111.66), control2: point(195.01, 35.71))
        path.addCurve(to: point(256, 0), control1: point(265.28, 0.12), control2: point(260.65, 0))
        path.addCurve(to: point(0, 256), control1: point(114.62, 0), control2: point(0, 114.62))
        path.addCurve(to: point(256, 512), control1: point(0, 397.38), control2: point(114.62, 512))
        path.addCurve(to: point(473.82, 390.01), control1: point(348.18, 512), control2: point(428.99, 463.28))
        path.closeSubpath()
        return path
    }
}

/// The master switch as an icon, lit while transitions are on (transport bar, Up Next).
struct TransitionsButton: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 14

    var body: some View {
        // Nothing at all while the feature is off in Settings.
        if model.settings.transitionsFeature {
            let on = model.settings.transitions.enabled
            Button { model.toggleTransitions() } label: {
                TransitionsGlyph().frame(width: size + 3, height: size + 3)
            }
            .buttonStyle(TransportIconStyle(active: on))
            .help("Transitions (⌥⌘X)")
            .contextMenu { TransitionsStyleMenu() }
            .accessibilityLabel("Transitions")
            .accessibilityValue(on ? String(localized: "On", comment: "Transitions state") : String(localized: "Off", comment: "Transitions state"))
        }
    }
}

/// Shown once, the first time transitions are turned on, in the window they were turned on in.
struct TransitionsExplainerSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The note's logo: Vespertine's one moon (the Transitions glyph's two crescents are the switch's icon).
    typealias Logo = VespertineMoon

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Logo()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(Palette.brass)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transitions").font(Typeface.serif(22)).foregroundStyle(Palette.text)
                    Text("Transitions change the sound only during each fade; the rest of every song stays bit-perfect.")
                        .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            Hairline()
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .buttonStyle(BrassButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
        .background(Palette.panel)
    }
}

// MARK: - Names

extension TransitionStyle {
    var label: String {
        switch self {
        case .crossfade: String(localized: "Crossfade", comment: "Transition style: a plain crossfade of a chosen length.")
        case .smartMix: String(localized: "Smart Mix", comment: "Transition style: chosen per pair of songs (silence trimmed, fade-outs followed, loudness matched). Feature name.")
        case .liveSet: String(localized: "Live Set", comment: "Transition style for hosting: Smart Mix everywhere, skips always blend. Feature name.")
        }
    }
}

extension SkipTransition {
    var label: String {
        switch self {
        case .instant: String(localized: "Cut at once", comment: "What a skip does while transitions are on: stop the song at once.")
        case .quickFade: String(localized: "Quick fade", comment: "What a skip does while transitions are on: a short fade out.")
        case .crossfade: String(localized: "Crossfade", comment: "Transition style: a plain crossfade of a chosen length.")
        }
    }
}

extension TransitionPolicy {
    var label: String {
        switch self {
        case .bitPerfectFirst: String(localized: "Bit-perfect first", comment: "Transitions setting: never change the output format to make a transition happen.")
        case .transitionsFirst: String(localized: "Transitions first", comment: "Transitions setting: resample, convert DSD and leave integer modes so songs can blend.")
        }
    }
}

// MARK: - Settings › Playback › Transitions

struct TransitionsSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var genres = ""

    var body: some View {
        @Bindable var s = model.settings
        let t = s.transitions
        Section("Transitions") {
            Toggle("Transitions", isOn: Binding(get: { model.settings.transitionsFeature }, set: { model.setTransitionsFeature($0) }))
                // The first-time note comes up on this window, where the switch was turned on, not on the main window
                // (which would be raised over Settings).
                .sheet(isPresented: Binding(get: { model.transitionsNote.isShown(in: .settings) }, set: { if !$0 { model.transitionsNote.dismiss() } })) {
                    TransitionsExplainerSheet()
                }
            Text("Adds Crossfade, Smart Mix and Live Set, with controls in the transport bar and menus. Off, none of it is in the app and every song plays as before.")
                .font(.caption).foregroundStyle(.secondary)
            if s.transitionsFeature {
                Picker("Style", selection: $s.transitions.style) {
                    ForEach(TransitionStyle.allCases) { Text($0.label).tag($0) }
                }
                Text(styleNote(t.style)).font(.caption).foregroundStyle(.secondary)
                Slider(value: $s.transitions.crossfadeSeconds, in: TransitionSettings.crossfadeRange, step: TransitionSettings.crossfadeStep) {
                    Text("Crossfade length: \(Self.seconds(t.crossfadeSeconds)) s")
                }
                Picker("Curve", selection: $s.transitions.curve) {
                    ForEach(TransitionCurve.allCases) { Text($0.name).tag($0) }
                }
                Picker("Skipping to another song", selection: $s.transitions.skip) {
                    ForEach(SkipTransition.allCases) { Text($0.label).tag($0) }
                }
                .disabled(t.style == .liveSet)
                Toggle("Trim silence at the ends of songs", isOn: $s.transitions.trimSilence)
                    .disabled(t.isSmart)
                Slider(value: $s.transitions.gapSeconds, in: TransitionSettings.gapRange, step: TransitionSettings.crossfadeStep) {
                    Text(t.gapSeconds > 0 ? String(localized: "Gap between songs: \(Self.seconds(t.gapSeconds)) s", comment: "Transitions setting: seconds of silence between songs instead of a crossfade.")
                                          : String(localized: "Gap between songs: none", comment: "Transitions setting: no silence is put between songs."))
                }
                if t.style == .liveSet {
                    Picker("Live Set output rate", selection: $s.transitions.liveSetRate) {
                        ForEach(TransitionSettings.liveSetRates, id: \.self) { rate in
                            Text("\((rate / 1000).formatted(.number.precision(.fractionLength(0)))) kHz").tag(rate)
                        }
                    }
                    Toggle("Beat-matched blends", isOn: $s.transitions.beatBlends)
                    Toggle("Bass swap in beat-matched blends", isOn: $s.transitions.bassSwap)
                        .disabled(!t.beatBlends)
                    Text("Live Set plays every song at one output rate, so a change of rate never gaps. Songs with steady, matching beats in the library’s analysis blend beat on beat, over 16 or 8 beats; the others blend as in Smart Mix.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("When a transition needs a change to the signal", selection: $s.transitions.policy) {
                    ForEach(TransitionPolicy.allCases) { Text($0.label).tag($0) }
                }
                Text("Bit-perfect first never changes the output format: songs at another rate fade out and in, and DSD, integer and 16-bit output play without transitions. Transitions first resamples, plays DSD as PCM and turns integer and 16-bit output off while transitions are on.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Genres that play without transitions") {
                    TextField("Genres that play without transitions", text: $genres)
                        .labelsHidden()
                        .onSubmit { applyGenres() }
                }
                Text("Separate genres with commas. Albums, CUE sheets and SACDs always play gaplessly. A playlist can have its own transitions, in its menu in the sidebar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { genres = model.settings.transitions.excludedGenres.joined(separator: ", ") }
        .onDisappear { applyGenres() }
        .onChange(of: model.settings.transitions) { model.syncEngine() }
    }

    private func applyGenres() {
        let list = genres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.settings.transitions.excludedGenres = list
        model.settings.transitions = model.settings.transitions.normalized
        genres = model.settings.transitions.excludedGenres.joined(separator: ", ")
    }

    static func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }

    private func styleNote(_ style: TransitionStyle) -> String {
        switch style {
        case .crossfade:
            String(localized: "Each song fades into the next over the length and curve below.")
        case .smartMix:
            String(localized: "Chosen for each pair of songs: silence trimmed, fade-outs followed, quick cuts between cold endings and starts, loudness matched in the blend. When unsure, a plain crossfade.")
        case .liveSet:
            String(localized: "Smart Mix at every song, for hosting. Skips always blend.")
        }
    }
}

// MARK: - Menus

/// The transport button's menu: the style and the crossfade length.
struct TransitionsStyleMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Toggle("Transitions", isOn: Binding(get: { model.settings.transitions.enabled }, set: { model.setTransitions($0) }))
        Picker("Style", selection: $s.transitions.style) {
            ForEach(TransitionStyle.allCases) { Text($0.label).tag($0) }
        }
        Picker("Crossfade length", selection: $s.transitions.crossfadeSeconds) {
            ForEach([2.0, 4, 6, 8, 10, 12], id: \.self) { Text("\(TransitionsSettingsSection.seconds($0)) s").tag($0) }
            if ![2.0, 4, 6, 8, 10, 12].contains(s.transitions.crossfadeSeconds) {
                Text("\(TransitionsSettingsSection.seconds(s.transitions.crossfadeSeconds)) s").tag(s.transitions.crossfadeSeconds)
            }
        }
    }
}

/// A playlist's own transitions (its menu in the sidebar).
struct PlaylistTransitionsMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    var body: some View {
        if model.settings.transitionsFeature { menu }
    }

    @ViewBuilder private var menu: some View {
        let chosen = playlist.id.flatMap { model.library.playlistTransitions[$0] }
        let length = model.settings.transitions.crossfadeSeconds
        Picker("Transitions", selection: Binding(get: { Choice(chosen) }, set: { model.library.setTransitions($0.override(length: length), for: playlist) })) {
            Text("Use the App’s Setting").tag(Choice.inherit)
            Text("Off").tag(Choice.off)
            if case .crossfade(let seconds) = chosen, seconds != length {
                Text("Crossfade, \(TransitionsSettingsSection.seconds(seconds)) s").tag(Choice.crossfade(seconds))
            }
            Text("Crossfade, \(TransitionsSettingsSection.seconds(length)) s").tag(Choice.crossfade(length))
            Text(TransitionStyle.smartMix.label).tag(Choice.smartMix)
            Text(TransitionStyle.liveSet.label).tag(Choice.liveSet)
        }
    }

    enum Choice: Hashable {
        case inherit, off, crossfade(Double), smartMix, liveSet
        init(_ o: TransitionOverride?) {
            switch o {
            case nil: self = .inherit
            case .off: self = .off
            case .crossfade(let s): self = .crossfade(s)
            case .smartMix: self = .smartMix
            case .liveSet: self = .liveSet
            }
        }
        func override(length: Double) -> TransitionOverride? {
            switch self {
            case .inherit: nil
            case .off: .off
            case .crossfade(let s): .crossfade(seconds: s)
            case .smartMix: .smartMix
            case .liveSet: .liveSet
            }
        }
    }
}

// MARK: - Up Next

/// How a song in Up Next joins the one before it, while transitions are on: blended, gapless, a gap, or no transition.
struct BoundaryGlyph: View {
    let decision: TransitionDecision

    var body: some View {
        Group {
            switch decision {
            case .overlap, .mix, .dip:
                TransitionsGlyph().frame(width: 10, height: 10)
            case .gapless:
                Image(systemName: "link").font(.system(size: 8, weight: .semibold))
            case .gap:
                Image(systemName: "ellipsis").font(.system(size: 8, weight: .semibold))
            case .cut:
                Image(systemName: "scissors").font(.system(size: 8, weight: .semibold))
            }
        }
        .foregroundStyle(Palette.text3)
        .frame(width: 10)
        .help(decision.summary)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        switch decision {
        case .overlap, .mix, .dip: String(localized: "Blends from the song before", comment: "Up Next, VoiceOver: this song crossfades from the one before it.")
        case .gapless: String(localized: "Follows the song before without a gap", comment: "Up Next, VoiceOver: this song joins the one before it gaplessly.")
        case .gap: String(localized: "Silence before this song", comment: "Up Next, VoiceOver: a gap of silence is put before this song.")
        case .cut: String(localized: "No transition from the song before", comment: "Up Next, VoiceOver: this song can't blend with the one before it.")
        }
    }
}
