//
// Vespertine Remote: the switch between the app's two ways of working with a Mac: a remote for the Mac, which plays, or a
// player itself, with the Mac sending the songs. Always in sight on Now Playing and Output, and one tap to change.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient

nonisolated enum PlayMode: String, CaseIterable, Sendable {
    /// The Mac plays; this device is its remote.
    case mac
    /// This device plays; the Mac sends the songs.
    case device

    /// A share or a folder has no Mac that could play: there is nothing to switch between.
    static func offersSwitch(share: Bool) -> Bool { !share }

    /// The mode in force: this device's when its own player is the one the screens talk to.
    static func current(playsHere: Bool) -> PlayMode { playsHere ? .device : .mac }

    /// Whether `mode` can be chosen. The Mac can always play; this device only when the Mac can send it songs.
    static func canChoose(_ mode: PlayMode, canPlayHere: Bool) -> Bool { mode == .mac || canPlayHere }

    func symbol(pad: Bool) -> String {
        switch self {
        case .mac: "desktopcomputer"
        case .device: pad ? "ipad" : "iphone"
        }
    }
}

struct PlayModeSwitch: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var pill
    let session: RemoteSession

    private var mode: PlayMode { PlayMode.current(playsHere: session.phone != nil) }

    var body: some View {
        if PlayMode.offersSwitch(share: session.isShare) {
            HStack(spacing: 0) {
                ForEach(PlayMode.allCases, id: \.self) { segment($0) }
            }
            .padding(3)
            .background(Palette.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
            .dynamicTypeSize(...RemoteLayout.bannerLargestText)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Music Plays On"))
            .accessibilityIdentifier("play-mode")
            .sensoryFeedback(.selection, trigger: mode)
        }
    }

    private func segment(_ segment: PlayMode) -> some View {
        let chosen = segment == mode
        let allowed = PlayMode.canChoose(segment, canPlayHere: PlayTarget.shared.canPlayHere(session))
        return Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) {
                PlayTarget.shared.choose(thisDevice: segment == .device)
            }
        } label: {
            HStack(spacing: 6) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: segment.symbol(pad: UIDevice.current.userInterfaceIdiom == .pad))
                        .accessibilityHidden(true)
                }
                Text(segment == .mac ? String(localized: "Mac") : PlayTarget.deviceName)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .font(.subheadline.weight(chosen ? .semibold : .regular))
            .foregroundStyle(chosen ? Palette.onBrass : Palette.text2)
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.horizontal, 6)
            .background {
                if chosen {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.brass)
                        .matchedGeometryEffect(id: "chosen", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .opacity(allowed ? 1 : 0.45)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("play-mode-" + segment.rawValue)
    }

    /// Under the switch on Output: what the chosen mode means, with the Mac named.
    static func explanation(_ mode: PlayMode, mac: String) -> String {
        switch mode {
        case .mac:
            String(localized: "Remote: “\(mac)” plays the music, and this device controls it.", comment: "Under the Mac / This iPhone switch on the iPhone's Output screen, when the Mac is chosen. %@ is the Mac's name.")
        case .device:
            String(localized: "This device plays the music, and “\(mac)” sends it the songs.", comment: "Under the Mac / This iPhone switch on the iPhone's Output screen, when this device is chosen. %@ is the Mac's name.")
        }
    }
}
