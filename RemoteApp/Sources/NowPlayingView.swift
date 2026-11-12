//
// Vespertine Remote: what's playing, the transport, the position, and the volume (as the Mac allows it).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct NowPlayingView: View {
    let session: RemoteSession
    @State private var feedback = CommandFeedback()
    @State private var scrubbing: Double?
    @State private var volumeDrag: Double?

    private var player: PlayerState? { session.player }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            ScrollView {
                Group {
                    if wide {
                        HStack(alignment: .center, spacing: 32) {
                            cover.frame(maxWidth: min(geometry.size.height - 80, 520))
                            controls
                        }
                    } else {
                        VStack(spacing: 24) {
                            cover.frame(maxWidth: 520)
                            controls
                        }
                    }
                }
                .padding()
                .frame(minHeight: geometry.size.height)
            }
        }
        .feedback(feedback)
    }

    private var cover: some View {
        ArtworkView(key: player?.nowPlaying?.track.artworkKey, size: 1000, cornerRadius: 12)
            .shadow(radius: 12)
    }

    private var controls: some View {
        VStack(spacing: 20) {
            titles
            scrubber
            transport
            modes
            volume
            if let output = player?.output {
                Label(output, systemImage: "hifispeaker").font(.caption).foregroundStyle(.secondary)
            }
            if let waiting = player?.waitingFor {
                Text("Waiting for “\(waiting)” to connect").font(.caption).foregroundStyle(.orange)
            }
            if let error = player?.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 560)
    }

    @ViewBuilder private var titles: some View {
        if let track = player?.nowPlaying?.track {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(track.title).font(.title2.bold()).lineLimit(2)
                    Spacer()
                    if let id = track.id {
                        Button {
                            feedback.run(session, .setFavorite(ids: [id], on: !track.favorite))
                        } label: {
                            Image(systemName: track.favorite ? "heart.fill" : "heart")
                        }
                        .accessibilityLabel(track.favorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
                    }
                }
                HStack {
                    Text("\(track.artist) — \(track.album)").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text(track.format)
                    if let signal = player?.signal {
                        Text(signal.badge)
                            .foregroundStyle(signal.bitPerfect ? Color.accentColor : Color.secondary)
                    }
                    Spacer()
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        } else {
            Text("Nothing playing").font(.title3).foregroundStyle(.secondary)
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
                .disabled(duration <= 0)
                .accessibilityLabel(Text("Position"))
                HStack {
                    Text(formatTime(position))
                    Spacer()
                    Text("-" + formatTime(max(duration - position, 0)))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button { feedback.run(session, .previous) } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel(Text("Previous"))
            Button { feedback.run(session, .playPause) } label: {
                Image(systemName: player?.playback == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .accessibilityLabel(player?.playback == .playing ? Text("Pause") : Text("Play"))
            Button { feedback.run(session, .next) } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel(Text("Next"))
        }
        .font(.title)
        .buttonStyle(.plain)
        .disabled(!session.isConnected)
    }

    private var modes: some View {
        HStack(spacing: 28) {
            Button {
                feedback.run(session, .setShuffle(on: !(player?.shuffle ?? false)))
            } label: {
                Image(systemName: "shuffle").foregroundStyle(player?.shuffle == true ? Color.accentColor : Color.secondary)
            }
            .accessibilityLabel(Text("Shuffle"))
            .accessibilityValue(player?.shuffle == true ? Text("On") : Text("Off"))
            Button {
                feedback.run(session, .setRepeat(mode: Self.nextRepeat(after: player?.repeatMode ?? .off)))
            } label: {
                Image(systemName: player?.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player?.repeatMode == .off || player == nil ? Color.secondary : Color.accentColor)
            }
            .accessibilityLabel(Text("Repeat"))
            if let transitions = player?.transitions {
                Button {
                    feedback.run(session, .setTransitions(on: !transitions))
                } label: {
                    Image(systemName: "arrow.triangle.merge").foregroundStyle(transitions ? Color.accentColor : Color.secondary)
                }
                .accessibilityLabel(Text("Transitions"))
                .accessibilityValue(transitions ? Text("On") : Text("Off"))
            }
            Button { feedback.run(session, .stop) } label: { Image(systemName: "stop.fill").foregroundStyle(.secondary) }
                .accessibilityLabel(Text("Stop"))
        }
        .font(.title3)
        .buttonStyle(.plain)
        .disabled(!session.isConnected)
    }

    static func nextRepeat(after mode: RepeatModeValue) -> RepeatModeValue {
        switch mode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    @ViewBuilder private var volume: some View {
        if let volume = player?.volume {
            switch volume.route {
            case .fixed:
                Label("Fixed volume: set the level on your amplifier or DAC", systemImage: "speaker.slash")
                    .font(.caption).foregroundStyle(.secondary)
            case .hardware, .software:
                HStack(spacing: 12) {
                    Button { feedback.run(session, .volume(action: .mute)) } label: {
                        Image(systemName: volume.muted ? "speaker.slash.fill" : "speaker.fill")
                    }
                    .accessibilityLabel(volume.muted ? Text("Unmute") : Text("Mute"))
                    if let level = volume.level {
                        Slider(value: Binding(get: { volumeDrag ?? level }, set: { volumeDrag = $0 }), in: 0...1, onEditingChanged: { editing in
                            if !editing, let target = volumeDrag {
                                feedback.run(session, .setVolume(level: target))
                                Task { try? await Task.sleep(for: .seconds(1)); volumeDrag = nil }
                            }
                        })
                        .accessibilityLabel(Text("Volume"))
                    } else {
                        Spacer()
                        Button { feedback.run(session, .volume(action: .down)) } label: { Image(systemName: "minus") }
                            .accessibilityLabel(Text("Volume Down"))
                        Button { feedback.run(session, .volume(action: .up)) } label: { Image(systemName: "plus") }
                            .accessibilityLabel(Text("Volume Up"))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!session.isConnected)
            }
        }
    }
}
