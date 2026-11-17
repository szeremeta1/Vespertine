//
// Vespertine Remote: first-run setup: where the music is, pairing or adding it, where it plays, how it sounds and a few
// extras, each turned on or off as you go. Shown once to someone new, and again from Settings › Setup Assistant.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VespertinePhonePlayer
import VespertineRemoteClient
import VespertineRemoteProtocol
import VespertineShare

struct SetupFlow: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var step = SetupAssistant.shared.openingStep
    @State private var source = SetupAssistant.shared.openingSource
    @State private var forward = true
    /// The step whose pieces have come into place.
    @State private var revealed: SetupStep?
    @State private var pairing: DiscoveredMac?
    @State private var scanning = false
    @State private var addingShare = false
    @State private var choosingFolder = false
    @Namespace private var progress

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// This device is where the music plays: always for a share or a folder, by choice with a Mac.
    private var playsHere: Bool { source == .share || source == .folder || PlayTarget.shared.onThisDevice }
    private var named: [SetupStep] { SetupPlan.named(source: source, playsHere: playsHere) }
    private var next: SetupStep? { SetupPlan.next(after: step, source: source, playsHere: playsHere) }
    private var previous: SetupStep? { SetupPlan.previous(before: step, source: source, playsHere: playsHere) }
    private func shown(_ page: SetupStep) -> Bool { revealed == page }

    /// What is open is the kind of thing the Music step's chosen card is: the pairing, share or folder is in place.
    private var connected: Bool {
        guard let session = model.session, let source else { return false }
        return SetupSource.of(demo: session.isDemo, share: session.isShare, folder: session.isFolder) == source
    }

    /// The text size setup is drawn at. It follows the system's size up to the second accessibility size, since past it
    /// a step no longer fits a phone; and on an iPad, where the page is a long way off, it starts two sizes up.
    nonisolated static func textSize(system: DynamicTypeSize, pad: Bool) -> DynamicTypeSize {
        min(max(system, pad ? .xxLarge : .xSmall), .accessibility2)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ZStack {
                    ScrollView {
                        page(step)
                            .frame(maxWidth: pad ? 640 : 560)
                            .padding(.horizontal, 22).padding(.vertical, 14)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .id(step)
                    .transition(transition)
                }
            }
            footer
        }
        .environment(\.dynamicTypeSize, SetupFlow.textSize(system: typeSize, pad: pad))
        .background { SetupBackdrop(step: step).ignoresSafeArea() }
        .tint(Palette.brass)
        .accessibilityIdentifier("setup")
        .sheet(item: $pairing) { mac in CodeEntryView(mac: mac) }
        .sheet(isPresented: $scanning) {
            PairingScannerSheet { link in
                scanning = false
                model.pair(link: link)
            }
        }
        .sheet(isPresented: $addingShare) { ShareEditView() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.add(folderAt: url) }
        }
        .task(id: step) {
            // A beat after the step is on the screen, so its pieces rise into place rather than start there.
            try? await Task.sleep(for: .milliseconds(60))
            revealed = step
        }
        .onAppear {
            // Setup opened again from Settings with something already open: its card is the chosen one.
            if source == nil, let session = model.session {
                source = SetupSource.of(demo: session.isDemo, share: session.isShare, folder: session.isFolder)
            }
            if step == .connect, source == .mac { model.lookForMacs() }
        }
        .onChange(of: model.session?.pairing.serverID) { _, opened in sessionChanged(opened) }
    }

    // MARK: Moving

    /// Steps slide the way you're going, with a little blur, and simply cross-fade with Reduce Motion on.
    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = 60
        return .asymmetric(
            insertion: .modifier(active: SetupShift(x: forward ? distance : -distance), identity: SetupShift(x: 0, blur: 0, opacity: 1)),
            removal: .modifier(active: SetupShift(x: forward ? -distance : distance), identity: SetupShift(x: 0, blur: 0, opacity: 1)))
    }

    private func go(to target: SetupStep) {
        forward = target > step
        if target == .connect, source == .mac { model.lookForMacs() }
        // The leaving page takes its direction from this update; the move comes in the next one.
        Task { @MainActor in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.6, dampingFraction: 0.86)) { step = target }
        }
    }

    private func goOn() {
        // The demo needs nothing found or added: choosing it opens it.
        if step == .music, source == .demo, model.session?.isDemo != true { model.tryDemo() }
        if let next { go(to: next) }
    }

    private func finish() {
        model.lookForMacs()
        SetupAssistant.shared.finish()
    }

    /// Something opened while setup is up: a Mac was paired, a share or a folder added, or a file was opened in
    /// Vespertine from another app.
    private func sessionChanged(_ opened: String?) {
        guard opened != nil, let session = model.session else { return }
        let kind = SetupSource.of(demo: session.isDemo, share: session.isShare, folder: session.isFolder)
        switch step {
        case .welcome, .music:
            // Not by way of a step: a pairing code scanned with the Camera app, or a song opened from Files. The song
            // is what was asked for, so setup gets out of its way; a pairing carries on from the step after it.
            if session.pairing.serverID == SavedFolder.ownID {
                finish()
            } else if kind != .demo || source == .demo {
                source = kind
                if let after = SetupPlan.next(after: .connect, source: kind, playsHere: kind != .mac || PlayTarget.shared.onThisDevice) {
                    go(to: after)
                }
            }
        case .connect:
            // What the step asked for is there: a moment to see it, then on.
            source = kind
            Task {
                try? await Task.sleep(for: .milliseconds(1100))
                if step == .connect, connected { goOn() }
            }
        default:
            break
        }
    }

    // MARK: Header and footer

    private func title(_ step: SetupStep) -> LocalizedStringKey {
        switch step {
        case .welcome: "Welcome"
        case .music, .connect: "Music"
        case .output: "Output"
        case .sound: "Sound"
        case .extras: "Extras"
        case .done: "Done"
        }
    }

    private var header: some View {
        let current = SetupPlan.heading(of: step)
        return HStack(spacing: 6) {
            ForEach(named, id: \.self) { item in
                let reached = item <= current
                VStack(spacing: 7) {
                    if !typeSize.isAccessibilitySize {
                        Text(title(item))
                            .font(.caption.weight(item == current ? .semibold : .regular))
                            .foregroundStyle(item == current ? Palette.brassHi : reached ? Palette.text2 : Palette.text3)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    ZStack {
                        Capsule().fill(reached ? Palette.brass.opacity(0.45) : Palette.text.opacity(0.1)).frame(height: 2)
                        if item == current {
                            Capsule().fill(Palette.brassGradient).frame(height: 3)
                                .shadow(color: Palette.brass.opacity(0.8), radius: 5)
                                .matchedGeometryEffect(id: "current", in: progress)
                        }
                    }
                }
                .frame(maxWidth: 110)
                // Read as text, in order, with the step you are on marked as the selected one.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title(item)))
                .accessibilityAddTraits(item == current ? [.isStaticText, .isSelected] : .isStaticText)
            }
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 6)
        .opacity(step == .welcome || step == .done ? 0 : 1)
        .accessibilityHidden(step == .welcome || step == .done)
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.8), value: step)
    }

    @ViewBuilder private var footer: some View {
        // One row at every text size: the buttons stop growing at the largest ordinary size, so the step keeps the screen.
        HStack(spacing: 12) {
            if step != .welcome, step != .done, let previous {
                Button { go(to: previous) } label: {
                    Image(systemName: "chevron.backward").accessibilityLabel(Text("Back"))
                }
                .buttonStyle(SetupQuietButtonStyle())
                .accessibilityIdentifier("setup-back")
            }
            Spacer(minLength: 0)
            if step != .done {
                // Later from the welcome goes straight to the app; from a step, to the summary of what was chosen.
                Button(step == .welcome ? "Set Up Later" : "Skip the Rest") {
                    if step == .welcome { finish() } else { go(to: .done) }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(Palette.text2)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .minimumScaleFactor(0.7)
                .frame(minHeight: 44)
                .accessibilityIdentifier("setup-skip")
            }
            if step != .welcome, step != .done, next != nil {
                Button(action: goOn) {
                    HStack(spacing: 6) {
                        Text("Continue").lineLimit(1).fixedSize()
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                    }
                }
                .buttonStyle(SetupPrimaryButtonStyle())
                .disabled(!canGoOn)
                .accessibilityIdentifier("setup-continue")
            }
        }
        .frame(maxWidth: pad ? 640 : 560)
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .animation(.easeInOut(duration: 0.3), value: step)
        .animation(.easeInOut(duration: 0.2), value: canGoOn)
    }

    /// Music goes on once a card is chosen; pairing or adding, once what it asks for is there.
    private var canGoOn: Bool {
        switch step {
        case .music: source != nil
        case .connect: connected
        default: true
        }
    }

    // MARK: Pages

    @ViewBuilder private func page(_ step: SetupStep) -> some View {
        switch step {
        case .welcome: SetupWelcome(start: { go(to: .music) })
        case .music: music
        case .connect: connect
        case .output: output
        case .sound: sound
        case .extras: extras
        case .done: done
        }
    }

    private var music: some View {
        VStack(spacing: 22) {
            SetupHeading(title: Text("Where is your music?"),
                         detail: Text("Vespertine plays from any of these. Choose one to start with; the others can be added later."),
                         shown: shown(.music))
            VStack(spacing: 10) {
                choice(.mac, symbol: "desktopcomputer", title: String(localized: "A Mac running Vespertine"),
                       detail: String(localized: "Control it from here like a remote, or have it send its library to this device."), delay: 0.12)
                choice(.share, symbol: "externaldrive.connected.to.line.below", title: String(localized: "A NAS or shared folder"),
                       detail: String(localized: "An SMB share on your network, played by this device itself."), delay: 0.18)
                choice(.folder, symbol: "folder", title: String(localized: "A folder in Files"),
                       detail: String(localized: "Music on this device, in iCloud Drive or on a drive plugged in."), delay: 0.24)
                choice(.demo, symbol: "sparkles", title: String(localized: "Just looking"),
                       detail: String(localized: "Try Vespertine with a made-up library."), delay: 0.3)
            }
        }
    }

    private func choice(_ kind: SetupSource, symbol: String, title: String, detail: String, delay: Double) -> some View {
        SetupChoice(symbol: symbol, title: title, detail: detail, selected: source == kind) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) { source = kind }
        }
        .accessibilityIdentifier("setup-source-" + kind.rawValue)
        .setupReveal(shown(.music), delay: delay)
    }

    @ViewBuilder private var connect: some View {
        switch source {
        case .share:
            connectPage(leading: "externaldrive.connected.to.line.below", title: Text("Add an SMB Share"),
                        detail: Text("Music in a shared folder on a NAS or another computer plays on this device by itself, with no Mac running. Away from home, the share is reached over Tailscale or another VPN.")) {
                Button { addingShare = true } label: { Label("Add an SMB Share", systemImage: "externaldrive.badge.plus") }
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .accessibilityIdentifier("setup-add-share")
            }
        case .folder:
            connectPage(leading: "folder", title: Text("Add a Folder from Files"),
                        detail: Text("Music in a folder in the Files app plays on this device by itself: a folder on this device, in iCloud Drive or on a drive plugged in. The music stays where it is.")) {
                Button { choosingFolder = true } label: { Label("Add a Folder from Files", systemImage: "folder.badge.plus") }
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .accessibilityIdentifier("setup-add-folder")
                if let error = model.pairingError { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        default:
            connectPage(leading: "desktopcomputer", title: Text("Pair with a Mac"),
                        detail: Text("On the Mac, open Vespertine › Settings › Remote, turn on “Let phones control Vespertine”, and choose Pair a Phone. Then scan its code, or choose the Mac here and type the 6 digits.")) {
                pairingChoices
            }
        }
    }

    /// A step that pairs or adds something: the picture, what to do, and the buttons; or, once it is there, its name.
    private func connectPage<Actions: View>(leading: String, title: Text, detail: Text, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 22) {
            if !typeSize.isAccessibilitySize {
                SetupFlowPicture(leading: leading, trailing: pad ? "ipad" : "iphone", towardTrailing: true, sounds: nil, searching: !connected)
                    .setupReveal(shown(.connect))
            }
            SetupHeading(title: title, detail: detail, shown: shown(.connect))
            VStack(spacing: 12) {
                if connected, let session = model.session {
                    SetupCard(selected: true) {
                        HStack(spacing: 14) {
                            SetupCheck(size: 40)
                            Text(String(localized: "“\(session.pairing.name)” is ready.", comment: "First-run setup on the iPhone, after pairing with a Mac or adding a share or a folder. %@ is its name."))
                                .font(.body.weight(.semibold)).foregroundStyle(Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("setup-connected")
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                } else {
                    actions()
                }
            }
            .frame(maxWidth: .infinity)
            .setupReveal(shown(.connect), delay: 0.14)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: connected)
        }
    }

    /// The ways to pair: the Mac's code scanned, or a Mac found on the network and its 6 digits typed.
    @ViewBuilder private var pairingChoices: some View {
        let unpaired = model.unpairedMacs
        let blocked = model.discovery.problem?.isEmpty == false
        Button { scanning = true } label: { Label("Scan the Pairing Code", systemImage: "qrcode.viewfinder") }
            .buttonStyle(SetupPrimaryButtonStyle())
            .accessibilityIdentifier("setup-scan")
        ForEach(unpaired) { mac in
            Button { pairing = mac } label: {
                SetupCard {
                    HStack(spacing: 14) {
                        SetupSymbol(name: SavedPairing.symbol(portable: mac.portable))
                        Text(mac.name).font(.serif(.body, weight: .medium)).foregroundStyle(Palette.text)
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(Palette.text3)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("setup-mac")
        }
        switch DiscoveryPatience.row(stage: model.search.stage, unpaired: unpaired.count, discovered: model.discovery.macs.count, blocked: blocked) {
        case .none:
            EmptyView()
        case .spinner:
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for Macs on this network…").font(.footnote).foregroundStyle(Palette.text2)
            }
            .padding(.top, 2)
        case .advice:
            VStack(spacing: 8) {
                Text("No Macs found on this network.").font(.footnote.weight(.semibold)).foregroundStyle(Palette.text)
                Text("Check that this device is on the same Wi-Fi as your Mac, and that Vespertine is open on the Mac with “Let phones control Vespertine” turned on. If the Mac still doesn’t appear, allow Local Network for Vespertine in Settings › Privacy & Security.")
                    .font(.footnote).foregroundStyle(Palette.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.lookAgain() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(SetupQuietButtonStyle())
            }
        }
        if blocked {
            VStack(spacing: 8) {
                Text("Vespertine can’t look for Macs. Allow it in Settings › Privacy & Security › Local Network.")
                    .font(.footnote).foregroundStyle(Palette.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url).font(.footnote.weight(.semibold))
                }
            }
        }
        if let error = model.pairingError {
            Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var output: some View {
        let here = PlayTarget.shared.onThisDevice
        // A Mac whose Vespertine is too old to send songs can only play itself.
        let canPlayHere = model.session.map { PlayTarget.shared.canPlayHere($0) } ?? true
        let mac = model.session.flatMap { $0.isShare ? nil : $0.server?.name ?? $0.pairing.name } ?? String(localized: "Mac")
        return VStack(spacing: 22) {
            if !typeSize.isAccessibilitySize {
                SetupFlowPicture(leading: "desktopcomputer", trailing: pad ? "ipad" : "iphone", towardTrailing: here, sounds: here ? .trailing : .leading)
                    .setupReveal(shown(.output))
            }
            SetupHeading(title: Text("Choose where it plays"),
                         detail: Text("On the Mac’s DAC and speakers, or on this device’s headphones. The switch on Now Playing changes it at any time."),
                         shown: shown(.output))
            VStack(spacing: 10) {
                SetupChoice(symbol: "desktopcomputer", title: mac,
                            detail: String(localized: "This device is the remote. You choose the music here and hear it on the Mac’s outputs."),
                            selected: !here) {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) { PlayTarget.shared.choose(thisDevice: false) }
                }
                .accessibilityIdentifier("setup-plays-mac")
                .setupReveal(shown(.output), delay: 0.12)
                SetupChoice(symbol: pad ? "ipad" : "iphone", title: PlayTarget.deviceName,
                            detail: canPlayHere ? String(localized: "The Mac sends the songs and you listen here: on headphones, the speaker or a DAC, at home or away.")
                                                : String(localized: "Update Vespertine on the Mac to play here."),
                            selected: here, enabled: canPlayHere) {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) { PlayTarget.shared.choose(thisDevice: true) }
                }
                .accessibilityIdentifier("setup-plays-device")
                .setupReveal(shown(.output), delay: 0.18)
            }
        }
    }

    private var sound: some View {
        @Bindable var settings = model.settings
        let target = PlayTarget.shared
        return VStack(spacing: 22) {
            SetupHeading(title: Text("How it should sound"),
                         detail: Text("For music played on this device. Each of these is also on the Output screen."),
                         shown: shown(.sound))
            VStack(spacing: 10) {
                SetupOption(symbol: "dial.medium", title: Text("Volume leveling (ReplayGain)"),
                            detail: Text("Evens out loudness between songs or whole albums, using the ReplayGain values in your files. Off, no sample is changed."),
                            on: target.replayGain != .off, below: true) {
                    Picker("Volume leveling (ReplayGain)", selection: Binding(get: { target.replayGain }, set: { target.replayGain = $0 })) {
                        Text("Off").tag(ReplayGainChoice.off)
                        Text("Track").tag(ReplayGainChoice.track)
                        Text("Album").tag(ReplayGainChoice.album)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("setup-replaygain")
                }
                .setupReveal(shown(.sound), delay: 0.12)
                SetupOption(symbol: "airpods.gen3", title: Text("Surround on Headphones"),
                            detail: Text("Surround songs (5.1, 7.1) play as Spatial Audio on headphones. Off, they are folded to stereo."),
                            on: target.surround != .off) {
                    Toggle("Surround on Headphones", isOn: Binding(get: { target.surround != .off }, set: { target.surround = $0 ? .fixed : .off }))
                        .labelsHidden().tint(Palette.brass)
                        .accessibilityIdentifier("setup-surround")
                }
                .setupReveal(shown(.sound), delay: 0.18)
                // Songs come over the network only from a Mac: a share is read as files, a folder is on the device.
                if source == .mac {
                    SetupOption(symbol: "antenna.radiowaves.left.and.right", title: Text("Play over Cellular Data"),
                                detail: Text("Away from Wi-Fi, songs come from your Mac over cellular data. Lossless albums are large, so this starts off."),
                                on: settings.cellularPlayback) {
                        Toggle("Play over Cellular Data", isOn: Binding(get: { settings.cellularPlayback }, set: { settings.cellularPlayback = $0; model.cellularSettingChanged() }))
                            .labelsHidden().tint(Palette.brass)
                            .accessibilityIdentifier("setup-cellular")
                    }
                    .setupReveal(shown(.sound), delay: 0.24)
                }
            }
            Label {
                Text("A DAC plugged into this device is asked for each song’s own sample rate. The Output screen shows what reaches it, and has the test for playing DSD natively.")
            } icon: {
                Image(systemName: "cable.connector")
            }
            .font(.footnote).foregroundStyle(Palette.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .setupReveal(shown(.sound), delay: 0.3)
        }
    }

    private var extras: some View {
        @Bindable var settings = model.settings
        return VStack(spacing: 22) {
            SetupHeading(title: Text("A few extras"),
                         detail: Text("How Now Playing and your albums look. Both are in Settings too."),
                         shown: shown(.extras))
            VStack(spacing: 10) {
                SetupOption(symbol: "record.circle", title: Text("Show a Record in Now Playing"),
                            detail: Text("The cover becomes the label of a record that turns with the music. It’s a picture of the playback position, not of the sound."),
                            on: settings.vinyl) {
                    Toggle("Show a Record in Now Playing", isOn: $settings.vinyl).labelsHidden().tint(Palette.brass)
                        .accessibilityIdentifier("setup-vinyl")
                }
                .setupReveal(shown(.extras), delay: 0.12)
                SetupOption(symbol: "square.stack.3d.down.forward", title: Text("Albums"),
                            detail: Text("A grid of covers, or Cover Flow: a row of covers you flick through."),
                            on: settings.albumsLayout == .coverFlow, below: true) {
                    Picker("Albums", selection: $settings.albumsLayout) {
                        Text("Grid").tag(AppSettings.AlbumsLayout.grid)
                        Text("Cover Flow").tag(AppSettings.AlbumsLayout.coverFlow)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("setup-albums")
                }
                .setupReveal(shown(.extras), delay: 0.18)
            }
        }
    }

    private var done: some View {
        let session = model.session
        let here = session.map { $0.isShare || PlayTarget.shared.onThisDevice }
        return VStack(spacing: 0) {
            SetupCheck()
            Text("You're all set")
                .font(.system(.largeTitle, design: .serif))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
                .setupReveal(shown(.done), delay: 0.4)
                .accessibilityAddTraits(.isHeader)
            Text("Everything below can be changed later in Settings.")
                .font(.subheadline).foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .setupReveal(shown(.done), delay: 0.48)
            VStack(spacing: 0) {
                summary("music.note.list", Text("Music"), session?.pairing.name ?? String(localized: "Not connected"))
                if let here {
                    Rectangle().fill(Palette.hairlineStrong).frame(height: 0.5)
                    summary("hifispeaker", Text("Music Plays On"), here ? PlayTarget.deviceName : String(localized: "Mac"))
                    if here {
                        Rectangle().fill(Palette.hairlineStrong).frame(height: 0.5)
                        summary("dial.medium", Text("ReplayGain"), replayGainName(PlayTarget.shared.replayGain))
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairlineStrong))
            .padding(.top, 26)
            .setupReveal(shown(.done), delay: 0.6)
            Button(action: finish) {
                HStack(spacing: 8) {
                    Text(session == nil ? "Done" : "Start Listening")
                    if session != nil { Image(systemName: "play.fill").font(.footnote).accessibilityHidden(true) }
                }
            }
            .buttonStyle(SetupPrimaryButtonStyle())
            .padding(.top, 28)
            .setupReveal(shown(.done), delay: 0.8)
            .accessibilityIdentifier("setup-finish")
        }
    }

    private func summary(_ symbol: String, _ title: Text, _ value: String) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                if !stacked { Image(systemName: symbol).foregroundStyle(Palette.brass).frame(width: 24).accessibilityHidden(true) }
                title.font(.subheadline).foregroundStyle(Palette.text2)
            }
            if !stacked { Spacer(minLength: 8) }
            Text(verbatim: value).font(.subheadline.weight(.medium)).foregroundStyle(Palette.text)
                .multilineTextAlignment(stacked ? .leading : .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func replayGainName(_ choice: ReplayGainChoice) -> String {
        switch choice {
        case .off: String(localized: "Off")
        case .track: String(localized: "Track")
        case .album: String(localized: "Album")
        }
    }
}

/// A page sliding in or out.
private struct SetupShift: ViewModifier {
    var x: CGFloat
    var blur: CGFloat = 8
    var opacity: Double = 0

    func body(content: Content) -> some View {
        content.offset(x: x).blur(radius: blur).opacity(opacity)
    }
}

// MARK: - Welcome

private struct SetupWelcome: View {
    let start: () -> Void
    @State private var shown = false
    @State private var glow = false
    @State private var turned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let name = Array("vespertine")

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // A thin ring of light turning slowly round the crescent.
                Circle()
                    .trim(from: 0, to: 0.62)
                    .stroke(AngularGradient(colors: [Palette.brass.opacity(0), Palette.brassHi.opacity(0.7)], center: .center),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(width: 168, height: 168)
                    .rotationEffect(.degrees(turned ? 360 : 0))
                    .opacity(shown ? 1 : 0)
                Crescent()
                    .fill(LinearGradient(colors: [Palette.brassHi, Palette.brass, Palette.brassLo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 104, height: 104)
                    .shadow(color: Palette.brass.opacity(glow ? 0.6 : 0.25), radius: glow ? 38 : 18)
                    .scaleEffect(shown ? 1 : (reduceMotion ? 1 : 0.6))
                    .rotationEffect(.degrees(shown || reduceMotion ? 0 : -50))
                    .opacity(shown ? 1 : 0)
                    .animation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.95, dampingFraction: 0.62), value: shown)
            }
            // The logo is the same way round in every language.
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
            // The name, letter by letter.
            HStack(spacing: 1) {
                ForEach(Array(name.enumerated()), id: \.offset) { index, letter in
                    Text(verbatim: String(letter))
                        .setupReveal(shown, delay: 0.35 + Double(index) * 0.05)
                }
            }
            .font(.system(size: 46, weight: .light, design: .serif))
            .foregroundStyle(Palette.text)
            .minimumScaleFactor(0.6)
            // The name is Latin in every language: keep its letters in order in right-to-left layouts.
            .environment(\.layoutDirection, .leftToRight)
            .padding(.top, 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Vespertine"))
            .accessibilityAddTraits(.isHeader)
            Text("A remote for Vespertine on your Mac, and a player in its own right.")
                .font(.body)
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .setupReveal(shown, delay: 0.95)
            Text("Free and open source. A few choices and you're listening.")
                .font(.footnote)
                .foregroundStyle(Palette.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .setupReveal(shown, delay: 1.05)
            Button(action: start) {
                HStack(spacing: 8) {
                    Text("Get Started")
                    Image(systemName: "arrow.forward").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                }
            }
            .buttonStyle(SetupPrimaryButtonStyle())
            .padding(.top, 34)
            .setupReveal(shown, delay: 1.25)
            .accessibilityIdentifier("setup-start")
        }
        .padding(.bottom, 12)
        .onAppear {
            shown = true
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true).delay(1)) { glow = true }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { turned = true }
        }
    }
}
