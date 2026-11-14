//
// Vespertine Remote: what's playing, the transport, the position, and the volume (as the Mac allows it).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct NowPlayingView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: RemoteSession
    @State private var feedback = CommandFeedback()
    @State private var scrubbing: Double?

    private var player: PlayerState? { session.shownPlayer }

    var body: some View {
        GeometryReader { geometry in
            let wide = RemoteLayout.playerColumns(width: geometry.size.width, height: geometry.size.height, accessibilityText: typeSize.isAccessibilitySize)
            let side = RemoteLayout.coverSide(width: geometry.size.width, height: geometry.size.height, columns: wide)
            ScrollView {
                Group {
                    if wide {
                        HStack(alignment: .center, spacing: 32) {
                            cover.frame(width: side, height: side)
                            controls
                        }
                    } else {
                        VStack(spacing: 22) {
                            cover.frame(width: side, height: side)
                            controls
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: 1160)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(backdrop)
        .accessibilityIdentifier("now-playing")
        .feedback(feedback)
        .sensoryFeedback(.impact(weight: .light), trigger: player?.playback)
        .sensoryFeedback(.selection, trigger: player?.nowPlaying?.entry)
    }

    /// The cover's colours, far out of focus, over obsidian.
    private var backdrop: some View {
        ZStack {
            Palette.base
            ArtworkView(key: player?.nowPlaying?.track.artworkKey, size: 160, cornerRadius: 0, placeholder: false)
                .scaleEffect(1.6)
                .blur(radius: 70)
                .opacity(0.24)
            LinearGradient(colors: [Palette.base.opacity(0.15), Palette.base.opacity(0.9)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: player?.nowPlaying?.track.artworkKey)
        .accessibilityHidden(true)
    }

    private var cover: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if model.settings.vinyl {
                    VinylView(session: session)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                } else {
                    ArtworkView(key: player?.nowPlaying?.track.artworkKey, size: 1000, cornerRadius: 10)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.55), radius: 24, y: 14)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                }
            }
            Button {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.45)) { model.settings.vinyl.toggle() }
            } label: {
                Image(systemName: model.settings.vinyl ? "photo" : "record.circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.text)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(model.settings.vinyl ? 0 : 10)
            .accessibilityLabel(model.settings.vinyl ? Text("Show the Cover") : Text("Show a Record"))
            .sensoryFeedback(.selection, trigger: model.settings.vinyl)
        }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            titles
            scrubber
            transport
            modes
            volume
            if let converting = session.phone?.playback.preparing {
                Label(Self.converting(progress: converting.progress), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(Palette.brass)
                    .accessibilityIdentifier("converting")
            }
            if let waiting = player?.waitingFor {
                Text("Waiting for “\(waiting)” to connect").font(.caption).foregroundStyle(Palette.copper)
            }
            if let error = player?.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 560)
    }

    @ViewBuilder private var titles: some View {
        if let track = player?.nowPlaying?.track {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(track.title).font(.serif(.title2, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(2)
                    Spacer()
                    if let id = track.id {
                        Button {
                            feedback.run(session, .setFavorite(ids: [id], on: !track.favorite))
                        } label: {
                            Image(systemName: track.favorite ? "heart.fill" : "heart")
                                .font(.title3)
                                .foregroundStyle(track.favorite ? Palette.brass : Palette.text2)
                                .frame(width: 44, height: 44, alignment: .trailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(track.favorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
                        .sensoryFeedback(.success, trigger: track.favorite)
                    }
                }
                Text("\(track.artist) · \(track.album)").font(.subheadline).foregroundStyle(Palette.text2).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                signalPath(track)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Text("Nothing playing").font(.serif(.title3)).foregroundStyle(Palette.text2)
                Text("Choose something in the Library.").font(.footnote).foregroundStyle(Palette.text3)
            }
        }
    }

    /// The signal path, as the Mac's badge says it: what the file is, what the DAC receives, and where it plays.
    private func signalPath(_ track: TrackSummary) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) { signalChips(track, output: true) }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func signalChips(_ track: TrackSummary, output: Bool) -> some View {
        Chip(text: track.format)
        if let signal = player?.signal {
            Chip(text: signal.badge, highlighted: signal.bitPerfect)
            if !signal.deviceFormat.isEmpty, !track.format.hasSuffix(signal.deviceFormat) {
                Chip(text: "→ " + signal.deviceFormat)
            }
        }
        if output, let name = player?.output {
            Label(name, systemImage: "hifispeaker").font(.caption2).foregroundStyle(Palette.text3).lineLimit(1)
        }
        // Where this device's songs come from right now: the Mac over the home network or Tailscale, or this device itself.
        if output, session.phone != nil, let source = Self.source(reach: session.reach, connected: session.isConnected, demo: session.isDemo) {
            Label(source, systemImage: "arrow.down.left.circle").font(.caption2).foregroundStyle(Palette.text3).lineLimit(1)
                .accessibilityLabel(Text("Songs arrive over: \(source)"))
        }
    }

    private var scrubber: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(player?.duration ?? 0, 0)
            let position = scrubbing ?? player?.expectedPosition(at: context.date) ?? 0
            VStack(spacing: 2) {
                Slider(value: Binding(get: { min(position, duration) }, set: { scrubbing = $0 }),
                       in: 0...max(duration, 1), onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        feedback.run(session, .seek(seconds: target))
                        // Keep showing the target until the Mac's next update.
                        Task { try? await Task.sleep(for: .seconds(1)); scrubbing = nil }
                    }
                })
                .tint(Palette.brass)
                .disabled(duration <= 0 || !session.canControl)
                .accessibilityLabel(Text("Position"))
                .accessibilityValue(Text("\(formatTime(position)) of \(formatTime(duration))"))
                HStack {
                    Text(formatTime(position))
                    Spacer()
                    Text("-" + formatTime(max(duration - position, 0)))
                }
                .font(.signal(.caption2)).foregroundStyle(Palette.text2)
                .accessibilityHidden(true)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 24) {
            Button { feedback.run(session, .previous) } label: {
                Image(systemName: "backward.fill").frame(width: 56, height: 56).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Previous"))
            Button { feedback.run(session, .playPause) } label: {
                PlayPauseFace(playing: player?.playback == .playing, loading: player?.loading == true)
            }
            .accessibilityLabel(player?.playback == .playing ? Text("Pause") : Text("Play"))
            Button { feedback.run(session, .next) } label: {
                Image(systemName: "forward.fill").frame(width: 56, height: 56).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Next"))
        }
        .font(.title)
        .foregroundStyle(Palette.text)
        .buttonStyle(.plain)
        .disabled(!session.canControl)
        .opacity(session.canControl ? 1 : 0.5)
    }

    private var modes: some View {
        HStack(spacing: 0) {
            modeButton("shuffle", on: player?.shuffle == true, label: Text("Shuffle")) {
                .setShuffle(on: !(player?.shuffle ?? false))
            }
            modeButton(player?.repeatMode == .one ? "repeat.1" : "repeat", on: !(player?.repeatMode == .off || player == nil), label: Text("Repeat"),
                       value: Self.repeatValue(player?.repeatMode ?? .off)) {
                .setRepeat(mode: Self.nextRepeat(after: player?.repeatMode ?? .off))
            }
            if let transitions = player?.transitions {
                modeButton("arrow.triangle.merge", on: transitions, label: Text("Transitions")) { .setTransitions(on: !transitions) }
            }
            Button { feedback.run(session, .stop) } label: {
                Image(systemName: "stop.fill").foregroundStyle(Palette.text2).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Stop"))
        }
        .font(.body)
        .buttonStyle(.plain)
        .disabled(!session.canControl)
    }

    private func modeButton(_ symbol: String, on: Bool, label: Text, value: Text? = nil, command: @escaping () -> RemoteCommand) -> some View {
        Button { feedback.run(session, command()) } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(on ? Palette.brass : Palette.text2)
                Circle().fill(on ? Palette.brass : .clear).frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(value ?? (on ? Text("On") : Text("Off")))
    }

    /// The volume line when music plays on this device: its level (below 100% the samples are scaled by iOS) and how to set it.
    static func deviceVolume(_ level: Double?) -> String {
        guard let level else { return String(localized: "Use the volume buttons on this device.") }
        let percent = level.formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Volume \(percent). Use the volume buttons on this device.", comment: "Now Playing on the iPhone: %@ is the device's volume as a percentage, e.g. “62%”.")
    }

    /// What Now Playing says while the Mac turns a song into a form this device can play (DSD, WavPack, Vorbis and the like),
    /// with how far along it is when the Mac knows.
    static func converting(progress: Double?) -> String {
        guard let progress, progress > 0 else { return String(localized: "Converting on the Mac…", comment: "Now Playing on the iPhone: the Mac is converting the song before it can send it.") }
        let percent = min(max(progress, 0), 1).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Converting on the Mac… \(percent)", comment: "Now Playing on the iPhone: the Mac is converting the song; %@ is how far along, e.g. “42%”.")
    }

    /// The network this device's songs arrive over, in a word or two; nil for the demo.
    static func source(reach: RemoteSession.Reach?, connected: Bool, demo: Bool) -> String? {
        if demo { return nil }
        guard connected, let reach else { return String(localized: "On this device", comment: "Now Playing on the iPhone: the song plays from a copy kept on the device; the Mac isn't connected.") }
        return reachName(reach)
    }

    static func reachName(_ reach: RemoteSession.Reach) -> String {
        switch reach {
        case .sameNetwork: String(localized: "Home network", comment: "How the iPhone reaches the Mac: on the Mac's own network.")
        case .tailscale: String(localized: "Tailscale", comment: "How the iPhone reaches the Mac: over Tailscale, a VPN. A product name.")
        case .elsewhere: String(localized: "Another network", comment: "How the iPhone reaches the Mac: over some other address or VPN.")
        }
    }

    static func nextRepeat(after mode: RepeatModeValue) -> RepeatModeValue {
        switch mode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    static func repeatValue(_ mode: RepeatModeValue) -> Text {
        switch mode {
        case .off: Text("Off")
        case .all: Text("All")
        case .one: Text("One Song")
        }
    }

    @ViewBuilder private var volume: some View {
        if let volume = player?.volume {
            switch volume.route {
            case .fixed where session.phone != nil:
                Label(Self.deviceVolume(volume.level), systemImage: "speaker.wave.2")
                    .font(.caption).foregroundStyle(Palette.text2)
            case .fixed:
                Label("Fixed volume: set the level on your amplifier or DAC", systemImage: "speaker.slash")
                    .font(.caption).foregroundStyle(Palette.text2)
            case .hardware, .software:
                HStack(spacing: 12) {
                    Button { feedback.run(session, .volume(action: .mute)) } label: {
                        Image(systemName: volume.muted ? "speaker.slash.fill" : "speaker.fill")
                            .frame(width: 36, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel(volume.muted ? Text("Unmute") : Text("Mute"))
                    if let level = volume.level {
                        // Sent while it moves (the newest level only), and shown where the finger put it until the Mac agrees.
                        Slider(value: Binding(get: { session.volume.shown(reported: level) }, set: { session.volume.drag(to: $0) }), in: 0...1,
                               onEditingChanged: { editing in if !editing { session.volume.end() } })
                        .tint(Palette.text2)
                        .accessibilityLabel(Text("Volume"))
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(Palette.text3).accessibilityHidden(true)
                    } else {
                        Spacer()
                        Button { feedback.run(session, .volume(action: .down)) } label: {
                            Image(systemName: "minus").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Volume Down"))
                        Button { feedback.run(session, .volume(action: .up)) } label: {
                            Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Volume Up"))
                    }
                }
                .font(.footnote)
                .foregroundStyle(Palette.text2)
                .buttonStyle(.plain)
                .disabled(!session.isConnected)
            }
        }
    }
}
