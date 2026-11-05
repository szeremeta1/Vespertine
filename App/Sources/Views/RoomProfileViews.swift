//
// Vespertine — Room Correction profile controls: naming and labelling a profile, the strength control and the A/B
// switch every listener gets, and the Advanced section (design target and limits, measured positions, every filter and
// each speaker's trim, the microphone).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers
import VespertineAudio

/// A text field that changes its value when return is pressed or it loses focus, not on every key. `commit` says whether
/// the new text was accepted; if not, the field goes back to the stored value.
struct CommitField: View {
    let title: LocalizedStringKey
    let value: String
    let commit: (String) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onSubmit { if !commit(text) { text = value } }
            .onChange(of: focused) { _, now in if !now, text != value, !commit(text) { text = value } }
            .onChange(of: value, initial: true) { _, new in if !focused { text = new } }
    }
}

// MARK: - Name and labels

/// The name, and the optional speakers, room and position labels, of a profile saved in the library.
struct RoomProfileDetailsForm: View {
    @Environment(AppModel.self) private var model
    let profileID: UUID
    @State private var problem: String?

    var body: some View {
        let settings = model.settings
        if let profile = settings.roomBook.profile(profileID) {
            let tags = profile.tags ?? RoomProfileTags()
            VStack(alignment: .leading, spacing: 8) {
                field("Name", value: profile.name) { name in
                    do { try settings.renameRoomProfile(profileID, to: name); problem = nil; return true }
                    catch { problem = error.localizedDescription; return false }
                }
                field("Speakers", value: tags.speakers, prompt: "e.g. KEF LS50 Meta") { set(\.speakers, $0) }
                field("Room", value: tags.room, prompt: "e.g. Study") { set(\.room, $0) }
                field("Position", value: tags.position, prompt: "e.g. Desk, near field") { set(\.position, $0) }
                if let problem { Text(problem).font(Typeface.ui(11.5)).foregroundStyle(Palette.copper) }
            }
        }
    }

    private func field(_ title: LocalizedStringKey, value: String, prompt: LocalizedStringKey? = nil, commit: @escaping (String) -> Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(Typeface.ui(12)).foregroundStyle(Palette.text2).frame(width: 70, alignment: .trailing)
            CommitField(title: prompt ?? title, value: value, commit: commit)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }

    private func set(_ key: WritableKeyPath<RoomProfileTags, String>, _ text: String) -> Bool {
        do {
            try model.settings.updateRoomProfile(profileID) { p in
                var tags = p.tags ?? RoomProfileTags()
                tags[keyPath: key] = text
                p.tags = tags
            }
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}

struct RoomProfileDetailsSheet: View {
    let profileID: UUID
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name and Labels").font(Typeface.serif(20)).foregroundStyle(Palette.text)
            Text("Name a profile for the speakers, room or desk it's for. The labels are optional and only help you tell profiles apart.")
                .font(Typeface.ui(12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            RoomProfileDetailsForm(profileID: profileID)
            HStack {
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Palette.window)
    }
}

/// After a measurement: name the new profile before it's saved.
struct RoomDraftNaming: View {
    let model: RoomMeasureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Profile name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0 }))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                tag("Speakers (optional)", \.speakers)
                tag("Room (optional)", \.room)
                tag("Position (optional)", \.position)
            }
        }
        .font(Typeface.ui(12))
    }

    private func tag(_ title: LocalizedStringKey, _ key: WritableKeyPath<RoomProfileTags, String>) -> some View {
        TextField(title, text: Binding(get: { model.draft?.tags?[keyPath: key] ?? "" }, set: { text in
            var tags = model.draft?.tags ?? RoomProfileTags()
            tags[keyPath: key] = text
            model.draft?.tags = tags
        }))
        .textFieldStyle(.roundedBorder)
    }
}

// MARK: - Guided: strength and A/B

/// The two controls everyone gets: how much of the correction plays, and a switch between the original music and the
/// corrected music.
struct RoomListeningControls: View {
    @Environment(AppModel.self) private var model
    let profile: RoomProfile
    let device: OutputDevice
    let edit: ((inout RoomProfile) throws -> Void) -> Void
    @State private var strength = 1.0

    var body: some View {
        let settings = model.settings
        let on = settings.roomProfile(for: device.uid)?.id == profile.id
        let playing = profile.atStrength
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Strength").font(Typeface.ui(12.5)).foregroundStyle(Palette.text).frame(width: 70, alignment: .leading)
                Slider(value: $strength, in: 0...1) { editing in
                    if !editing { commit() }
                }
                .disabled(!profile.supportsStrength)
                .accessibilityLabel("Strength")
                .accessibilityValue(String(localized: "\(Int((strength * 100).rounded())) percent"))
                Text("\(Int((strength * 100).rounded()))%").font(Typeface.mono(11.5)).foregroundStyle(Palette.text2).frame(width: 44, alignment: .trailing)
            }
            // The percentages are arguments, so each language writes them its own way (and the catalog's format check
            // doesn't read "0% le…" as a placeholder).
            Text(profile.supportsStrength
                 ? String(localized: "\(0.0.formatted(.percent)) leaves the music as it is, \(1.0.formatted(.percent)) is the full correction. Delays and levels stay as they are.")
                 : String(localized: "This profile is made of measured filters, which play at full strength."))
                .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text("Compare").font(Typeface.ui(12.5)).foregroundStyle(Palette.text).frame(width: 70, alignment: .leading)
                Picker("Compare", selection: Binding(get: { on }, set: { new in
                    settings.chooseRoomProfile(profile.id, for: device.uid)
                    settings.setRoomProfile(new ? profile.id : nil, for: device.uid)
                    model.syncEngine()
                })) {
                    Text("Original", comment: "Room correction A/B switch: the music without correction").tag(false)
                    Text("Corrected", comment: "Room correction A/B switch: the music with correction").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Compare the original music with the corrected music")
            }
            if on, playing.filters.preampDB < -0.05 {
                Text("Corrected plays \(abs(playing.filters.preampDB).formatted(.number.precision(.fractionLength(1)))) dB quieter, so it can't clip. Match the level by ear before judging.")
                    .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
        .onChange(of: profile.effectiveStrength, initial: true) { _, new in strength = new }
        .onChange(of: profile.id) { strength = profile.effectiveStrength }
    }

    private func commit() {
        let value = (strength * 100).rounded() / 100
        guard value != profile.effectiveStrength else { return }
        edit { $0.strength = value >= 1 ? nil : value }
    }
}

// MARK: - Advanced

struct RoomAdvancedControls: View {
    let profile: RoomProfile
    let redesigning: Bool
    let edit: ((inout RoomProfile) throws -> Void) -> Void
    let redesign: (RoomFilterDesignOptions?, Set<Int>?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section(String(localized: "Profile", comment: "Room correction section: name and labels")) { RoomProfileDetailsForm(profileID: profile.id) }
            if profile.measured != nil {
                section(String(localized: "Target and limits")) {
                    RoomDesignControls(profile: profile, redesigning: redesigning, redesign: redesign)
                        .id(profile.id)
                }
            }
            if profile.positionCount > 1 {
                section(String(localized: "Measured positions")) { RoomPositionControls(profile: profile, redesigning: redesigning, redesign: redesign) }
            }
            section(String(localized: "Speakers", comment: "Room correction section")) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(profile.channelMap.entries.sorted { $0.output < $1.output }, id: \.speaker) { entry in
                        RoomSpeakerEditor(profile: profile, speaker: entry.speaker, edit: edit)
                    }
                    Text("The preamp is set from the filters so the corrected music can't clip: \(profile.filters.preampDB.formatted(.number.precision(.fractionLength(1)))) dB now.")
                        .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            if profile.origin == .measured { section(String(localized: "Microphone")) { micInfo } }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }

    private var micInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Microphone \(profile.micSerial)").font(Typeface.mono(11.5)).foregroundStyle(Palette.text2)
            Text(profile.calibrationSHA256.map { String(localized: "Calibration file checksum \(String($0.prefix(12)))…") }
                 ?? String(localized: "Measured without a calibration file."))
                .font(Typeface.mono(11.5)).foregroundStyle(Palette.text2)
            Text("The calibration file is chosen when you measure (Measure New…), and is applied to every response before the filters are fitted.")
                .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Target curve, limits and cutoffs. Nothing changes until Apply: then the filters are fitted again from the measurement.
struct RoomDesignControls: View {
    let profile: RoomProfile
    let redesigning: Bool
    let redesign: (RoomFilterDesignOptions?, Set<Int>?) -> Void
    @State private var options = RoomFilterDesignOptions.default
    @State private var confirm = false
    @State private var importing = false
    @State private var problem: String?

    private var stored: RoomFilterDesignOptions { (profile.designOptions ?? .default).clamped }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Target").font(Typeface.ui(12)).foregroundStyle(Palette.text2).frame(width: 90, alignment: .trailing)
                Picker("Target", selection: $options.target) {
                    ForEach(choices) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize()
                Button("Load House Curve…") { importing = true }.controlSize(.small)
                    .help("A text file with a frequency (Hz) and a level (dB) on each line, as REW exports a target")
            }
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("Correct from")
                    number($options.range.lowOrZero, unit: "Hz", digits: 0)
                    label("to")
                    number($options.range.highOrZero, unit: "Hz", digits: 0)
                }
                GridRow {
                    label("Largest cut")
                    number($options.maxCutDB, unit: "dB", digits: 1)
                    label("Largest boost")
                    number($options.maxBoostDB, unit: "dB", digits: 1)
                }
                GridRow {
                    label("Filters per speaker")
                    Stepper(value: $options.maxBands, in: 1...RoomCorrectionPlayback.maxBandsPerChannel) { Text("\(options.maxBands)").font(Typeface.mono(11.5)) }
                        .gridColumnAlignment(.leading)
                }
            }
            Text("Nothing is boosted below where the speaker rolls off, and the preamp keeps the result from clipping, whatever the limits say.")
                .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            if profile.filtersEdited == true {
                Text("You have edited this profile's filters. Applying fits them again and replaces your edits.")
                    .font(Typeface.ui(11.5)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { Text(problem).font(Typeface.ui(11.5)).foregroundStyle(Palette.copper) }
            HStack {
                Button("Apply") { if profile.filtersEdited == true { confirm = true } else { apply() } }
                    .disabled(redesigning || options.clamped == stored && profile.filtersEdited != true)
                Button("Reset to Defaults") { options = RoomFilterDesignOptions.default }
                    .disabled(redesigning || options == .default)
                if redesigning { ProgressView().controlSize(.small) }
            }
        }
        .onChange(of: profile.designOptions, initial: true) { _, new in options = (new ?? .default).clamped }
        .confirmationDialog("Replace your edited filters?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { apply() }
        } message: {
            Text("The filters are fitted again from the measurement.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .commaSeparatedText]) { result in
            guard case .success(let url) = result else { return }
            load(url)
        }
        .disabled(redesigning)
    }

    private var choices: [RoomTargetCurve] {
        var all = RoomTargetCurve.presets
        if options.target.isHouseCurve, !all.contains(options.target) { all.append(options.target) }
        if stored.target.isHouseCurve, !all.contains(stored.target) { all.append(stored.target) }
        return all
    }

    private func apply() {
        problem = nil
        redesign(options.clamped, nil)
    }

    private func load(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            options.target = try RoomTargetCurve.house(text: text, name: url.deletingPathExtension().lastPathComponent)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Typeface.ui(12)).foregroundStyle(Palette.text2).gridColumnAlignment(.trailing)
    }

    private func number(_ value: Binding<Double>, unit: String, digits: Int) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...digits)))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
            Text(unit).font(Typeface.ui(11)).foregroundStyle(Palette.text3)
        }
        .gridColumnAlignment(.leading)
    }
}

private extension ClosedRange where Bound == Double {
    /// The ends as plain numbers to edit; setting one keeps the range ordered.
    var lowOrZero: Double {
        get { lowerBound }
        set { if newValue.isFinite { self = newValue...Swift.max(upperBound, newValue * 1.1) } }
    }

    var highOrZero: Double {
        get { upperBound }
        set { if newValue.isFinite { self = Swift.min(lowerBound, newValue / 1.1)...newValue } }
    }
}

/// Which measured positions go into the average. The filters are fitted again when one is left out or brought back.
struct RoomPositionControls: View {
    let profile: RoomProfile
    let redesigning: Bool
    let redesign: (RoomFilterDesignOptions?, Set<Int>?) -> Void

    var body: some View {
        let excluded = Set(profile.excludedPositions ?? [])
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<profile.positionCount, id: \.self) { i in
                Toggle(i == 0 ? String(localized: "Position 1 · your seat") : String(localized: "Position \(i + 1)"),
                       isOn: Binding(get: { !excluded.contains(i) }, set: { include in
                    var next = excluded
                    if include { next.remove(i) } else { next.insert(i) }
                    guard next.count < profile.positionCount else { return }
                    redesign(nil, next)
                }))
                .toggleStyle(.checkbox)
                .font(Typeface.ui(12))
                .disabled(redesigning)
            }
            Text("The positions are averaged in power for each speaker. Leave one out if the microphone moved or was knocked; the filters are fitted again.")
                .font(Typeface.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One speaker: its delay and level trim, and every filter as numbers.
struct RoomSpeakerEditor: View {
    let profile: RoomProfile
    let speaker: RoomSpeaker
    let edit: ((inout RoomProfile) throws -> Void) -> Void

    var body: some View {
        let bands = profile.filters.channels[speaker] ?? []
        let trim = profile.alignment(for: speaker)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(speaker.colour).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(speaker.displayName).font(Typeface.ui(12.5, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                Button("Add Filter") { add(to: bands) }
                    .controlSize(.small)
                    .disabled(bands.count >= RoomCorrectionPlayback.maxBandsPerChannel)
            }
            HStack(spacing: 18) {
                unit("Delay", value: Binding(get: { trim.delayMs }, set: { new in
                    edit { $0.setAlignment(RoomSpeakerAlignment(delayMs: new, levelDB: $0.alignment(for: speaker).levelDB), for: speaker) }
                }), unit: "ms", digits: 2)
                unit("Level", value: Binding(get: { trim.levelDB }, set: { new in
                    edit { $0.setAlignment(RoomSpeakerAlignment(delayMs: $0.alignment(for: speaker).delayMs, levelDB: new), for: speaker) }
                }), unit: "dB", digits: 1)
            }
            if let impulse = profile.impulses?[speaker] {
                Text("Filter: \(impulse.name) · \(impulse.frames) taps at \(Int(impulse.sampleRate)) Hz")
                    .font(Typeface.mono(11)).foregroundStyle(Palette.text2)
            }
            if bands.isEmpty {
                Text("No filters").font(Typeface.mono(11)).foregroundStyle(Palette.text3)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("On", comment: "Column header: whether an equalizer band is enabled"); Text("Type"); Text("Frequency"); Text("Gain")
                        Text("Q", comment: "Column header: the Q (bandwidth) of an equalizer band"); Text(verbatim: "")
                    }
                    .font(Typeface.ui(10.5)).foregroundStyle(Palette.text3)
                    ForEach(bands) { band in
                        GridRow {
                            Toggle("Filter on", isOn: Binding(get: { band.enabled }, set: { v in update(band, in: bands) { $0.enabled = v } })).labelsHidden().toggleStyle(.checkbox)
                            Picker("Type", selection: Binding(get: { band.kind }, set: { v in update(band, in: bands) { $0.kind = v } })) {
                                ForEach(EQBand.Kind.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().frame(width: 110)
                            field("Frequency", Binding(get: { band.frequency }, set: { v in update(band, in: bands) { $0.frequency = v } }), unit: "Hz", digits: 1)
                            field("Gain", Binding(get: { band.gainDB }, set: { v in update(band, in: bands) { $0.gainDB = v } }), unit: "dB", digits: 1)
                                .disabled(!band.kind.hasGain)
                            field("Q", Binding(get: { band.q }, set: { v in update(band, in: bands) { $0.q = v } }), unit: "", digits: 2)
                            Button { remove(band, from: bands) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove filter").accessibilityLabel("Remove filter")
                        }
                        .opacity(band.enabled ? 1 : 0.5)
                    }
                }
            }
        }
    }

    /// Changes one property of one band and stores the speaker's list.
    private func update(_ band: EQBand, in bands: [EQBand], _ change: (inout EQBand) -> Void) {
        var next = bands
        guard let i = next.firstIndex(where: { $0.id == band.id }) else { return }
        change(&next[i])
        edit { try $0.setBands(next, for: speaker) }
    }

    private func add(to bands: [EQBand]) {
        let next = bands + [EQBand(kind: .peak, frequency: 100, gainDB: 0, q: 2)]
        edit { try $0.setBands(next, for: speaker) }
    }

    private func remove(_ band: EQBand, from bands: [EQBand]) {
        let next = bands.filter { $0.id != band.id }
        edit { try $0.setBands(next, for: speaker) }
    }

    private func unit(_ label: LocalizedStringKey, value: Binding<Double>, unit: String, digits: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2)
            field(label, value, unit: unit, digits: digits)
        }
    }

    private func field(_ label: LocalizedStringKey, _ value: Binding<Double>, unit: String, digits: Int) -> some View {
        HStack(spacing: 4) {
            TextField(label, value: value, format: .number.precision(.fractionLength(0...digits)))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
                .accessibilityLabel(label)
            if !unit.isEmpty { Text(unit).font(Typeface.ui(11)).foregroundStyle(Palette.text3) }
        }
    }
}
