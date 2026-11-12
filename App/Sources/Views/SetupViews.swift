//
// Vespertine: first-run setup: music, output, sound, a few extras and the phone remote, shown once (and again from the
// Setup Assistant… menu item).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import VespertineAudio
import VespertineLibrary
import SwiftUI
import UniformTypeIdentifiers

/// The main window's content: setup until it's finished, then the library.
struct MainRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.showSetup {
                SetupFlow().transition(.opacity)
            } else {
                MainWindow().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: model.showSetup)
    }
}

nonisolated enum SetupStep: Int, CaseIterable, Comparable {
    case welcome, music, output, sound, extras, remote, done

    static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }

    /// The steps the progress bar names (welcome and done stand outside it).
    static let named: [SetupStep] = [.music, .output, .sound, .extras, .remote]

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Welcome"
        case .music: "Music"
        case .output: "Output"
        case .sound: "Sound"
        case .extras: "Extras"
        case .remote: "Remote"
        case .done: "Done"
        }
    }

    init?(name: String) {
        guard let step = Self.allCases.first(where: { "\($0)" == name }) else { return nil }
        self = step
    }

    var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
}

struct SetupFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `-VespertineSetupStep output` opens on that step, for screenshots.
    @State private var step = LaunchArguments().string(forKey: "VespertineSetupStep").flatMap(SetupStep.init(name:)) ?? .welcome
    @State private var forward = true
    @Namespace private var progress

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
                .opacity(SetupStep.named.contains(step) ? 1 : 0)
                .animation(.easeInOut(duration: 0.35), value: step)
            ZStack {
                page(step)
                    .id(step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(minWidth: 1080, minHeight: 680)
        .background { SetupBackdrop(step: step).ignoresSafeArea() }
        .toolbar(.hidden, for: .windowToolbar)
        .tint(Palette.brass)
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.folder, .audio] + [UTType(filenameExtension: "iso")].compactMap { $0 },
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFolders(urls) }
        }
        .sheet(isPresented: $model.showFindMusic) { FindMusicSheet().environment(model) }
        .sheet(isPresented: $model.showConnectServer) { ConnectServerSheet().environment(model) }
        // The DoP test offered on the Output step, as the main window shows it.
        .sheet(item: Binding(get: { model.dopSetup.target }, set: { if $0 == nil { model.dopSetup.close() } })) { target in
            DoPTestSheet(device: target.device).environment(model)
        }
        .overlay(alignment: .top) { ErrorBanner() }
    }

    @ViewBuilder private func page(_ step: SetupStep) -> some View {
        switch step {
        case .welcome: SetupWelcome { go(to: .music) }
        case .music: SetupMusic()
        case .output: SetupOutput()
        case .sound: SetupSound()
        case .extras: SetupExtras()
        case .remote: SetupRemote()
        case .done: SetupDone { model.completeSetup() }
        }
    }

    /// Steps slide the way you're going, with a little blur, and simply cross-fade with Reduce Motion on.
    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = 70
        return .asymmetric(
            insertion: .modifier(active: StepShift(x: forward ? distance : -distance), identity: StepShift(x: 0, blur: 0, opacity: 1)),
            removal: .modifier(active: StepShift(x: forward ? -distance : distance), identity: StepShift(x: 0, blur: 0, opacity: 1)))
    }

    private func go(to next: SetupStep) {
        forward = next > step
        // The leaving page takes its direction from this update; the move comes in the next one.
        Task { @MainActor in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.62, dampingFraction: 0.86)) { step = next }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(SetupStep.named, id: \.self) { item in
                let reached = item <= step
                VStack(spacing: 7) {
                    Text(item.title)
                        .font(Typeface.ui(11.5, weight: item == step ? .semibold : .regular))
                        .tracking(0.4)
                        .foregroundStyle(item == step ? Palette.brassHi : reached ? Palette.text2 : Palette.text3)
                    ZStack {
                        Capsule().fill(reached ? Palette.brass.opacity(0.45) : Palette.text.opacity(0.08)).frame(height: 2)
                        if item == step {
                            Capsule().fill(Palette.brassGradient).frame(height: 3)
                                .shadow(color: Palette.brass.opacity(0.8), radius: 5)
                                .matchedGeometryEffect(id: "current", in: progress)
                        }
                    }
                }
                .frame(width: 112)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(item == step ? .isSelected : [])
            }
        }
        .padding(.top, 26)
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.8), value: step)
    }

    private var footer: some View {
        HStack {
            if step != .welcome, let previous = step.previous {
                Button { go(to: previous) } label: { Label("Back", systemImage: "chevron.backward") }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut("[", modifiers: .command)
                    .transition(.opacity)
            }
            Spacer()
            if step != .done {
                // Later from the welcome goes straight to the library; from a step, to the summary of what was chosen.
                Button(step == .welcome ? "Set Up Later" : "Skip the Rest") { if step == .welcome { model.completeSetup() } else { go(to: .done) } }
                    .buttonStyle(.plain)
                    .font(Typeface.ui(12))
                    .foregroundStyle(Palette.text3)
                    .help("Keep the defaults for everything left. Setup Assistant in the Vespertine menu brings this back.")
            }
            if SetupStep.named.contains(step), let next = step.next {
                Button { go(to: next) } label: {
                    HStack(spacing: 6) { Text("Continue"); Image(systemName: "chevron.forward").font(.system(size: 11, weight: .semibold)) }
                }
                .buttonStyle(SetupPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 30)
        .frame(height: 88)
        .animation(.easeInOut(duration: 0.3), value: step)
    }
}

/// A page sliding in or out.
private struct StepShift: ViewModifier {
    var x: CGFloat
    var blur: CGFloat = 10
    var opacity: Double = 0

    func body(content: Content) -> some View {
        content.offset(x: x).blur(radius: blur).opacity(opacity)
    }
}

// MARK: - Backdrop

/// Slow brass light and flowing lines behind every step. Still with Reduce Motion on.
private struct SetupBackdrop: View {
    let step: SetupStep
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Palette.window
            // The glow drifts across as you go through the steps.
            GeometryReader { geo in
                let size = max(geo.size.width, geo.size.height)
                RadialGradient(colors: [Palette.brass.opacity(0.20), Palette.copper.opacity(0.06), .clear],
                               center: .center, startRadius: 0, endRadius: size * 0.45)
                    .frame(width: size * 0.9, height: size * 0.9)
                    .position(x: geo.size.width * glowX, y: geo.size.height * (step == .done ? 0.42 : 0.30))
                    .animation(reduceMotion ? nil : .spring(response: 1.6, dampingFraction: 0.9), value: step)
            }
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                let t = reduceMotion ? 12 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
                Canvas { context, size in
                    Self.drawRibbons(in: &context, size: size, time: t)
                    Self.drawMotes(in: &context, size: size, time: t)
                }
            }
            // Keeps the edges dark, so the light sits behind the content.
            RadialGradient(colors: [.clear, Palette.base.opacity(0.75)], center: .center, startRadius: 200, endRadius: 900)
        }
        .accessibilityHidden(true)
    }

    private var glowX: CGFloat {
        switch step {
        case .welcome, .done: 0.5
        default: 0.26 + 0.12 * CGFloat(step.rawValue - 1)
        }
    }

    /// Six sine ribbons across the lower half, each with its own speed, like a slow waveform.
    private static func drawRibbons(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        guard size.width > 0 else { return }
        for i in 0..<6 {
            let k = Double(i)
            let base = size.height * (0.66 + 0.03 * k)
            let amplitude = size.height * (0.045 + 0.012 * k)
            let frequency = 2 * Double.pi / size.width * (1.0 + 0.16 * k)
            let phase = t * (0.22 + 0.05 * k) + k * 1.7
            var path = Path()
            var x = 0.0
            while x <= size.width {
                let envelope = sin(Double.pi * x / size.width)
                let y = base + amplitude * envelope * (sin(x * frequency + phase) + 0.35 * sin(x * frequency * 2.3 - phase * 1.3))
                if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 6
            }
            let opacity = 0.05 + 0.03 * Double((i * 7) % 3)
            context.stroke(path, with: .color(Palette.brassHi.opacity(opacity)), lineWidth: i == 2 ? 1.4 : 1)
        }
    }

    /// Specks of light rising slowly.
    private static func drawMotes(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        for i in 0..<36 {
            let seed = Double(i) * 12.9898
            let rx = (sin(seed) * 43_758.5453).truncatingRemainder(dividingBy: 1).magnitude
            let ry = (sin(seed * 1.7) * 23_421.631).truncatingRemainder(dividingBy: 1).magnitude
            let speed = 6 + 10 * rx
            let y = size.height - ((ry * size.height + t * speed).truncatingRemainder(dividingBy: size.height + 20)) + 10
            let x = rx * size.width + 14 * sin(t * 0.3 + seed)
            let radius = 0.6 + 1.1 * ry
            let twinkle = 0.5 + 0.5 * sin(t * (0.6 + rx) + seed)
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(Palette.brassHi.opacity(0.10 + 0.22 * twinkle * (1 - y / size.height))))
        }
    }
}

// MARK: - Pieces

struct SetupPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        SetupPrimaryButton(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct SetupPrimaryButton: View {
    let label: ButtonStyleConfiguration.Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        label
            .font(Typeface.ui(14, weight: .semibold))
            .foregroundStyle(Color(hex: 0x1A140A))
            .padding(.horizontal, 24)
            .frame(height: 40)
            .background(Palette.brassGradient, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5).blendMode(.overlay))
            .shadow(color: Palette.brass.opacity(hovering ? 0.55 : 0.25), radius: hovering ? 16 : 8, y: 2)
            .scaleEffect(reduceMotion ? 1 : pressed ? 0.97 : hovering ? 1.03 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7), value: pressed)
            .onHover { hovering = $0 }
    }
}

/// Fades and rises into place, after `delay`.
private struct Reveal: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 16)
            .blur(radius: shown || reduceMotion ? 0 : 5)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.82).delay(delay), value: shown)
    }
}

private extension View {
    func reveal(_ shown: Bool, delay: Double = 0) -> some View { modifier(Reveal(shown: shown, delay: delay)) }
}

/// A step's title and explanation.
private struct SetupHeading: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let shown: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(Typeface.serif(34))
                .foregroundStyle(Palette.text)
                .reveal(shown)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(Typeface.ui(14))
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
                .reveal(shown, delay: 0.06)
        }
    }
}

/// A card that lifts a little under the pointer and glows when it's the chosen one.
private struct SetupCard<Content: View>: View {
    var selected = false
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Palette.brass.opacity(0.09) : Palette.surface.opacity(hovering ? 0.95 : 0.78))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Palette.brass.opacity(0.7) : hovering ? Palette.text.opacity(0.18) : Palette.hairlineStrong,
                                  lineWidth: selected ? 1.5 : 1)
            }
            .shadow(color: selected ? Palette.brass.opacity(0.28) : .black.opacity(0.35), radius: selected ? 18 : 10, y: 4)
            .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: hovering)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: selected)
            .onHover { hovering = $0 }
    }
}

/// A round symbol in brass, for the cards.
private struct SetupSymbol: View {
    let name: String
    var selected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(selected ? Palette.brassHi : Palette.brass)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Palette.brass.opacity(selected ? 0.18 : 0.08)))
            .overlay(Circle().strokeBorder(Palette.brass.opacity(selected ? 0.5 : 0.2), lineWidth: 1))
            .symbolEffect(.bounce, value: reduceMotion ? false : selected)
    }
}

/// One choice on the Sound and Extras pages: what it is, what it does, and its control.
private struct SetupOption<Control: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var on = false
    @ViewBuilder var control: Control

    var body: some View {
        SetupCard(selected: on) {
            HStack(alignment: .center, spacing: 14) {
                SetupSymbol(name: symbol, selected: on)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(detail).font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                control
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Welcome

private struct SetupWelcome: View {
    let start: () -> Void
    @State private var shown = false
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let name = Array("Vespertine")

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 136, height: 136)
                .shadow(color: Palette.brass.opacity(glow ? 0.55 : 0.2), radius: glow ? 40 : 20)
                .scaleEffect(shown ? 1 : (reduceMotion ? 1 : 0.7))
                .opacity(shown ? 1 : 0)
                .animation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.9, dampingFraction: 0.65), value: shown)
                .accessibilityHidden(true)
            // The name, letter by letter.
            HStack(spacing: 1) {
                ForEach(Array(name.enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .reveal(shown, delay: 0.35 + Double(index) * 0.05)
                }
            }
            .font(Typeface.serif(64, weight: .light))
            .foregroundStyle(Palette.text)
            // The name is Latin in every language: keep its letters in order in right-to-left layouts.
            .environment(\.layoutDirection, .leftToRight)
            .padding(.top, 26)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Vespertine"))
            .accessibilityAddTraits(.isHeader)
            Text("Bit-perfect, high-resolution playback for every format and every DAC.")
                .font(Typeface.ui(16))
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .reveal(shown, delay: 0.95)
            Text("Free and open source. A minute of setup and you're listening.")
                .font(Typeface.ui(13))
                .foregroundStyle(Palette.text3)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .reveal(shown, delay: 1.05)
            Button(action: start) {
                HStack(spacing: 8) { Text("Get Started"); Image(systemName: "arrow.forward").font(.system(size: 12, weight: .semibold)) }
            }
            .buttonStyle(SetupPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.top, 38)
            .reveal(shown, delay: 1.25)
            HStack(spacing: 18) {
                feature("waveform", "Bit-perfect")
                feature("hifispeaker", "Hi-res and DSD")
                feature("checkmark.seal", "Checks real quality")
                feature("heart", "Free forever")
            }
            .padding(.top, 44)
            .reveal(shown, delay: 1.45)
        }
        .padding(.bottom, 20)
        .onAppear {
            shown = true
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true).delay(1)) { glow = true }
        }
    }

    private func feature(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.brass)
            Text(text).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3)
        }
    }
}

// MARK: - Music

private struct SetupMusic: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            SetupHeading(title: "Bring in your music",
                         detail: "Point Vespertine at your music, wherever it lives: this Mac, an external drive or a server on your network.",
                         shown: shown)
            HStack(spacing: 14) {
                modeCard(.reference, symbol: "folder", title: "Leave files where they are",
                         detail: "Vespertine plays your music in place. Nothing is moved or copied.")
                modeCard(.copyAndOrganize, symbol: "tray.full", title: "Copy and organize",
                         detail: "Copies music into one folder, sorted by artist and album. Your originals stay as they are.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 700)
            .padding(.top, 30)
            .reveal(shown, delay: 0.12)
            HStack(spacing: 14) {
                actionTile("sparkle.magnifyingglass", "Find Music on This Mac", "Searches your drives and checks every file's real format.",
                           recommended: true) { model.showFindMusic = true }
                actionTile("folder.badge.plus", "Add a Folder", "Choose a folder or drive yourself.") {
                    model.presentImporter(settings.defaultImportMode)
                }
                actionTile("server.rack", "Connect to a Server", "Music on a NAS or another Mac, over SMB.") {
                    model.showConnectServer = true
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 700)
            .padding(.top, 14)
            .reveal(shown, delay: 0.2)
            status
                .frame(height: 46)
                .padding(.top, 18)
                .reveal(shown, delay: 0.28)
        }
        .padding(.horizontal, 40)
        .onAppear { shown = true }
    }

    private func modeCard(_ mode: ImportMode, symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        let selected = model.settings.defaultImportMode == mode
        return Button { model.settings.defaultImportMode = mode } label: {
            SetupCard(selected: selected, padding: 14) {
                HStack(alignment: .top, spacing: 12) {
                    SetupSymbol(name: symbol, selected: selected)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(Typeface.ui(13.5, weight: .semibold)).foregroundStyle(Palette.text)
                        Text(detail).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .foregroundStyle(selected ? Palette.brassHi : Palette.text3)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func actionTile(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, recommended: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SetupCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SetupSymbol(name: symbol)
                        Spacer()
                        if recommended { StatusBadge(text: String(localized: "RECOMMENDED"), kind: .perfect) }
                    }
                    // Titles wrap (some languages run long); the row's tiles keep one height.
                    Text(title).font(Typeface.ui(13.5, weight: .semibold)).foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(Typeface.ui(11.5)).foregroundStyle(Palette.text2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 128, maxHeight: .infinity, alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What's in the library so far, live while it's scanned.
    @ViewBuilder private var status: some View {
        let stats = model.library.stats
        if let scan = model.library.scanProgress {
            VStack(spacing: 8) {
                ProgressView(value: scan.total > 0 ? Double(scan.processed) / Double(scan.total) : 0)
                    .progressViewStyle(.linear).tint(Palette.brass).frame(width: 300)
                Text(scan.total > 0 ? "Checking \(scan.processed) of \(scan.total) audio files…" : "Looking for music…")
                    .font(Typeface.mono(11)).foregroundStyle(Palette.text3).monospacedDigit()
            }
            .transition(.opacity)
        } else if stats.tracks > 0 {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brassHi)
                    .symbolEffect(.bounce, value: reduceMotion ? 0 : stats.tracks)   // never fires with Reduce Motion
                Text("\(stats.albums) albums · \(stats.tracks) tracks")
                    .contentTransition(.numericText(value: Double(stats.tracks)))
                    .font(Typeface.ui(13, weight: .medium)).foregroundStyle(Palette.text)
                Text("You can add more at any time.").font(Typeface.ui(12)).foregroundStyle(Palette.text3)
            }
            .animation(reduceMotion ? nil : .spring, value: stats.tracks)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
        } else {
            Text("You can skip this and add music later from the File menu.")
                .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                .transition(.opacity)
        }
    }
}

// MARK: - Output

private struct SetupOutput: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var settings = model.settings
        let devices = model.devices.devices
        let recommended = OutputChoice.best(among: devices).flatMap { $0.transport == .builtIn || devices.count == 1 ? nil : $0.uid }
        let dopDevice = dopCandidate
        VStack(spacing: 0) {
            SetupHeading(title: "Choose where it plays",
                         detail: "Pick your DAC, headphones or speakers. Vespertine remembers your choice and goes back to it whenever it's connected.",
                         shown: shown)
            ScrollView {
                VStack(spacing: 10) {
                    row(nil, name: String(localized: "System Default"), detail: String(localized: "Follows System Settings › Sound"),
                        symbol: "gearshape", index: 0)
                    ForEach(Array(devices.enumerated()), id: \.element.uid) { index, device in
                        row(device.uid, name: device.name, detail: "\(device.profile.tag) · \(device.rangeSummary)",
                            symbol: device.profile.symbol, recommended: device.uid == recommended, index: index + 1)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: devices.map(\.uid))
            }
            .scrollIndicators(.never)
            // The list gives up some room while the DoP card is shown under it.
            .frame(maxWidth: 620, maxHeight: dopDevice == nil ? 300 : 210)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 26)
            HStack(spacing: 8) {
                Circle().fill(Palette.brassHi).frame(width: 6, height: 6)
                    .shadow(color: Palette.brass, radius: pulse ? 6 : 1)
                    .opacity(pulse ? 1 : 0.45)
                Text("Plug in a DAC at any time and it appears here.")
                    .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
            }
            .padding(.top, 16)
            .reveal(shown, delay: 0.3)
            HStack(spacing: 10) {
                Text("When it isn't connected, play on").font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                Picker("When it isn't connected, play on", selection: $settings.outputFallback) {
                    ForEach(OutputFallback.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.top, 12)
            .opacity(settings.selectedDeviceUID == nil ? 0 : 1)
            .offset(y: settings.selectedDeviceUID == nil ? -6 : 0)
            .disabled(settings.selectedDeviceUID == nil)
            .accessibilityHidden(settings.selectedDeviceUID == nil)
            .animation(.easeInOut(duration: 0.25), value: settings.selectedDeviceUID)
            .reveal(shown, delay: 0.36)
            if let dopDevice {
                SetupDoPCard(device: dopDevice)
                    .frame(maxWidth: 620)
                    .padding(.top, 14)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: dopDevice?.uid)
        .padding(.horizontal, 40)
        .onAppear {
            shown = true
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: settings.outputFallback) { model.syncEngine() }
    }

    /// The chosen DAC, when it may take DSD over PCM (DoP) and hasn't been tested or set either way: the same offer the
    /// signal path shows the first time DSD is converted for it, made here, where the DAC was just picked.
    private var dopCandidate: OutputDevice? {
        guard let uid = model.settings.selectedDeviceUID, let device = model.devices.devices.first(where: { $0.uid == uid }),
              model.dopSetup.hint(for: device) != .none else { return nil }
        return device
    }

    private func row(_ uid: String?, name: String, detail: String, symbol: String, recommended: Bool = false, index: Int) -> some View {
        let selected = model.settings.selectedDeviceUID == uid
        return Button { withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75)) { model.selectDevice(uid) } } label: {
            SetupCard(selected: selected, padding: 12) {
                HStack(spacing: 14) {
                    SetupSymbol(name: symbol, selected: selected)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(name).font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                            if recommended { StatusBadge(text: String(localized: "BEST HERE"), kind: .perfect) }
                        }
                        Text(detail).font(Typeface.mono(10.5)).foregroundStyle(Palette.text3).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selected ? Palette.brassHi : Palette.text3)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .reveal(shown, delay: 0.12 + 0.05 * Double(min(index, 8)))
    }
}

/// "Play DSD natively?" for the DAC just chosen, and the one-tap test (DoPTestConstants: a short, quiet clip, the DAC's
/// own volume lowered to 20% for it). The words are the test card's, so they read the same here and under the signal path.
private struct SetupDoPCard: View {
    @Environment(AppModel.self) private var model
    let device: OutputDevice

    var body: some View {
        let words = DoPTestConstants.wording
        let hint = model.dopSetup.hint(for: device)
        SetupCard(padding: 14) {
            HStack(alignment: .center, spacing: 14) {
                SetupSymbol(name: "waveform.path")
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: words.offerTitle).font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(verbatim: explanation(hint, words))
                        .font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button(action: { model.dopSetup.begin(device) }) { Text(verbatim: words.testButton) }
                    .buttonStyle(QuietButtonStyle())
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func explanation(_ hint: DoPSetupHint, _ words: DoPTestConstants.Wording) -> String {
        if case .suggestTest(let maker) = hint { return words.suggestBody(maker: maker) }
        return words.offerBody
    }
}

// MARK: - Sound

private struct SetupSound: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            SetupHeading(title: "How it should sound",
                         detail: "Vespertine plays every file bit-perfect, exactly as recorded, and tells you when anything changes that. Choose how it shares your DAC and handles volume.",
                         shown: shown)
            VStack(spacing: 12) {
                SetupOption(symbol: "lock.shield", title: "Exclusive access",
                            detail: "Vespertine takes sole control of your DAC while it plays, so no other app can mix in or change its format. Other apps are silent on that device. Best for a dedicated DAC.",
                            on: settings.exclusiveMode) {
                    Toggle("Exclusive access", isOn: $settings.exclusiveMode).labelsHidden().toggleStyle(.switch).tint(Palette.brass)
                }
                .reveal(shown, delay: 0.12)
                SetupOption(symbol: "dial.medium", title: "Volume leveling (ReplayGain)",
                            detail: "Evens out loudness between songs or whole albums, using the ReplayGain tags in your files. Off keeps playback bit-perfect.",
                            on: settings.replayGain != .off) {
                    Picker("Volume leveling (ReplayGain)", selection: $settings.replayGain) {
                        Text("Off").tag(ReplayGainMode.off)
                        Text("Track").tag(ReplayGainMode.track)
                        Text("Album").tag(ReplayGainMode.album)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .reveal(shown, delay: 0.2)
                // With exclusive access the DAC can't be the Mac's sound output; the switch then turns on the volume relay.
                SetupOption(symbol: "speaker.wave.2", title: "Volume keys follow Vespertine",
                            detail: settings.exclusiveMode
                                ? "While Vespertine holds your DAC, the volume keys and headphone controls adjust it by way of another output, which then plays other apps' sounds at the DAC's level."
                                : "While Vespertine plays, the Mac's volume keys and headphone controls adjust the device it's playing to.",
                            on: settings.exclusiveMode ? settings.relayVolumeKeys : settings.systemOutputFollowsPlayback) {
                    Toggle("Volume keys follow Vespertine",
                           isOn: settings.exclusiveMode ? $settings.relayVolumeKeys : $settings.systemOutputFollowsPlayback)
                        .labelsHidden().toggleStyle(.switch).tint(Palette.brass)
                }
                .reveal(shown, delay: 0.28)
            }
            .frame(maxWidth: 680)
            .padding(.top, 28)
            Text("Sample rates, DSD, surround and every other detail are in Settings › Playback.")
                .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                .padding(.top, 18)
                .reveal(shown, delay: 0.36)
        }
        .padding(.horizontal, 40)
        .onAppear { shown = true }
        .onChange(of: settings.exclusiveMode) { model.syncEngine() }
        .onChange(of: settings.replayGain) { model.player.refreshReplayGain() }
    }
}

// MARK: - Extras

private struct SetupExtras: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUpdater.self) private var updater
    @State private var shown = false

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var updater = updater
        VStack(spacing: 0) {
            SetupHeading(title: "A few extras",
                         detail: "Vespertine sends nothing in the background unless it’s switched on, here or in Settings.",
                         shown: shown)
            VStack(spacing: 12) {
                SetupOption(symbol: "checkmark.seal", title: "Check each file's real quality",
                            detail: "Analyzes new music in the background for upsampling, padded bits and lossy sources sold as hi-res. Results are saved, so nothing is analyzed twice.",
                            on: settings.autoAnalyze) {
                    Toggle("Check each file's real quality", isOn: $settings.autoAnalyze).labelsHidden().toggleStyle(.switch).tint(Palette.brass)
                        // As in Settings: music already scanned at the Music step starts being checked now, not at the next scan.
                        .onChange(of: settings.autoAnalyze) { if settings.autoAnalyze { model.analysis.analyzeLibrary() } }
                }
                .reveal(shown, delay: 0.12)
                SetupOption(symbol: "photo.on.rectangle", title: "Cover art from the Cover Art Archive",
                            detail: "Finds missing album covers when you look an album up on MusicBrainz. Only when you ask for a lookup.",
                            on: settings.fetchArtworkOnline) {
                    Toggle("Cover art from the Cover Art Archive", isOn: $settings.fetchArtworkOnline).labelsHidden().toggleStyle(.switch).tint(Palette.brass)
                }
                .reveal(shown, delay: 0.2)
                if updater.isEnabled {
                    SetupOption(symbol: "arrow.down.circle", title: "Automatic updates",
                                detail: "Checks Vespertine's GitHub releases now and then. Every update is signed and verified before it's installed.",
                                on: updater.automaticallyChecks) {
                        Toggle("Automatic updates", isOn: $updater.automaticallyChecks).labelsHidden().toggleStyle(.switch).tint(Palette.brass)
                    }
                    .reveal(shown, delay: 0.28)
                }
                // On by default, so it's shown with the other things that reach the network on their own.
                SetupOption(symbol: "list.bullet.rectangle", title: "Update the list of DoP DACs",
                            detail: "Once a day, downloads the signed list of DACs known to play DSD natively, so a newly confirmed DAC needs no app update. Nothing about you is sent.",
                            on: settings.dopListUpdates) {
                    Toggle("Update the list of DoP DACs", isOn: $settings.dopListUpdates).labelsHidden().toggleStyle(.switch).tint(Palette.brass)
                        .onChange(of: settings.dopListUpdates) { if settings.dopListUpdates { model.dopSetup.refreshList() } }
                }
                .reveal(shown, delay: 0.36)
            }
            .frame(maxWidth: 680)
            .padding(.top, 28)
        }
        .padding(.horizontal, 40)
        .onAppear { shown = true }
    }
}

// MARK: - Remote

/// The phone remote, the options for a Mac without a screen, and Mac Sound Output (beta). Everything here is off until
/// turned on; the remote's switch is the one in Settings › Remote.
private struct SetupRemote: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var shown = false
    @State private var pairing = false

    private var server: RemoteServer { model.remote }

    var body: some View {
        let store = server.store
        VStack(spacing: 0) {
            SetupHeading(title: "Control it from your phone",
                         detail: "Play, queue and browse your music from an iPhone or iPad across the room, over your own network.",
                         shown: shown)
            VStack(spacing: 12) {
                SetupCard(selected: store.enabled) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 14) {
                            SetupSymbol(name: "iphone", selected: store.enabled)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Let phones control Vespertine").font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
                                Text("Phones connect over your local network only, encrypted, and only after you pair them. Volume follows the same rules as on this Mac.")
                                    .font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 16)
                            Toggle("Let phones control Vespertine", isOn: Binding(get: { store.enabled }, set: { store.enabled = $0; server.apply() }))
                                .labelsHidden().toggleStyle(.switch).tint(Palette.brass)
                        }
                        if store.enabled {
                            HStack(spacing: 12) {
                                Button("Pair a Phone…") {
                                    server.beginPairing()
                                    pairing = true
                                }
                                .buttonStyle(QuietButtonStyle())
                                .disabled(!server.isRunning)
                                Text(status).font(Typeface.ui(11.5)).foregroundStyle(Palette.text3).lineLimit(2)
                            }
                            .padding(.leading, 54)
                            .transition(.opacity)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: store.enabled)
                .reveal(shown, delay: 0.12)
                settingsCard(symbol: "macmini", title: "Mac without a screen",
                             detail: "For a Mac mini by the hi-fi: open Vespertine at login, keep the Mac awake and let a phone wake it. Each is its own switch in Settings › Remote, off until you turn it on.",
                             tab: .remote)
                    .reveal(shown, delay: 0.2)
                if model.settings.speakerGroupsFeature, let groups = model.speakerGroups?.groups, !groups.isEmpty {
                    settingsCard(symbol: "hifispeaker.2", title: "Mac Sound Output (beta)",
                                 detail: "Your speaker groups can be outputs of the Mac, for a browser, the TV app or a video player to play to. The first time one plays, macOS asks whether Vespertine Sound Helper may use the microphone: it only receives what your apps play there and never records. Allow it, or the group stays silent.",
                                 tab: .playback)
                        .reveal(shown, delay: 0.28)
                }
            }
            .frame(maxWidth: 680)
            .padding(.top, 28)
            if !(model.settings.speakerGroupsFeature && !(model.speakerGroups?.groups.isEmpty ?? true)) {
                Text("Two or more DACs? Speaker Groups (beta) in Settings › Playback play them as one surround system, and Mac Sound Output (beta) lets any app play to it.")
                    .font(Typeface.ui(12)).foregroundStyle(Palette.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    .reveal(shown, delay: 0.28)
            }
        }
        .padding(.horizontal, 40)
        .onAppear { shown = true }
        .sheet(isPresented: $pairing, onDismiss: { server.endPairing() }) {
            RemotePairingSheet(server: server) { pairing = false }
        }
    }

    private var status: String {
        switch server.status {
        case .off, .starting: String(localized: "Starting…")
        case .running: String(localized: "On. Phones on this network see this Mac as “\(RemoteServer.computerName)”.", comment: "Settings › Remote: %@ is the Mac's name.")
        case .failed(let reason): String(localized: "The remote couldn’t start: \(reason)", comment: "Settings › Remote: %@ is macOS's reason.")
        }
    }

    /// A feature set up in Settings, with a button that opens Settings on its tab.
    private func settingsCard(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey, tab: SettingsTab) -> some View {
        SetupCard {
            HStack(alignment: .center, spacing: 14) {
                SetupSymbol(name: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Typeface.ui(14, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(detail).font(Typeface.ui(12)).foregroundStyle(Palette.text2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("Open Settings") {
                    model.settingsTab = tab
                    openSettings()
                }
                .buttonStyle(QuietButtonStyle())
                .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Done

private struct SetupDone: View {
    @Environment(AppModel.self) private var model
    let finish: () -> Void
    @State private var ring: CGFloat = 0
    @State private var check: CGFloat = 0
    @State private var burst: Double = 0
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(0..<16, id: \.self) { i in
                    Circle()
                        .fill(i.isMultiple(of: 3) ? Palette.copper : Palette.brassHi)
                        .frame(width: i.isMultiple(of: 2) ? 5 : 3.5, height: i.isMultiple(of: 2) ? 5 : 3.5)
                        .modifier(BurstParticle(progress: burst, angle: Double(i) / 16 * 2 * .pi + 0.2, distance: i.isMultiple(of: 2) ? 48 : 32))
                }
                Circle().stroke(Palette.hairlineStrong, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(Palette.brassGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Palette.brass.opacity(0.7), radius: 8)
                CheckShape()
                    .trim(from: 0, to: check)
                    .stroke(Palette.brassHi, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 40, height: 30)
            }
            .frame(width: 104, height: 104)
            // A check mark reads the same in every language; don't mirror it.
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
            Text("You're all set")
                .font(Typeface.serif(40))
                .foregroundStyle(Palette.text)
                .padding(.top, 30)
                .reveal(shown, delay: 0.5)
                .accessibilityAddTraits(.isHeader)
            Text(model.library.stats.tracks == 0 && model.library.scanProgress == nil
                 ? "Add music whenever you're ready, from the File menu or the empty library."
                 : "Everything below can be changed later in Settings.")
                .font(Typeface.ui(14)).foregroundStyle(Palette.text2)
                .padding(.top, 8)
                .reveal(shown, delay: 0.58)
            VStack(spacing: 0) {
                summary("music.note.list", "Music", musicSummary, index: 0)
                Hairline()
                summary("hifispeaker", "Output", outputSummary, index: 1)
                Hairline()
                summary("lock.shield", "Exclusive access", model.settings.exclusiveMode ? String(localized: "On") : String(localized: "Off"), index: 2)
                Hairline()
                summary("dial.medium", "Volume leveling", model.settings.replayGain.localizedName, index: 3)
                Hairline()
                summary("iphone", "Phone remote", model.remote.store.enabled ? String(localized: "On") : String(localized: "Off"), index: 4)
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairlineStrong))
            .frame(maxWidth: 460)
            .padding(.top, 28)
            Button(action: finish) {
                HStack(spacing: 8) { Text("Start Listening"); Image(systemName: "play.fill").font(.system(size: 11)) }
            }
            .buttonStyle(SetupPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.top, 30)
            .reveal(shown, delay: 1.0)
        }
        .padding(.horizontal, 40)
        .task {
            shown = true
            guard !reduceMotion else { ring = 1; check = 1; return }
            withAnimation(.easeOut(duration: 0.8)) { ring = 1 }
            try? await Task.sleep(for: .milliseconds(520))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) { check = 1 }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.easeOut(duration: 1.2)) { burst = 1 }
        }
    }

    private var musicSummary: String {
        let stats = model.library.stats
        if model.library.scanProgress != nil { return String(localized: "Adding…") }
        return stats.tracks == 0 ? String(localized: "Not added yet") : String(localized: "\(stats.tracks) songs")
    }

    private var outputSummary: String {
        guard model.settings.selectedDeviceUID != nil else { return String(localized: "System Default") }
        return model.missingChosenOutput ?? model.plannedDevice?.name ?? String(localized: "System Default")
    }

    private func summary(_ symbol: String, _ title: LocalizedStringKey, _ value: String, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Palette.brass).frame(width: 20)
            Text(title).font(Typeface.ui(13)).foregroundStyle(Palette.text2)
            Spacer()
            Text(value).font(Typeface.ui(13, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .reveal(shown, delay: 0.66 + 0.06 * Double(index))
    }
}

/// A speck flying out from the ring and fading as it goes.
private struct BurstParticle: ViewModifier, Animatable {
    var progress: Double
    let angle: Double
    let distance: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // From the ring's edge outwards.
        let travel = 54 + distance * (1 - pow(1 - progress, 3))
        content
            .offset(x: cos(angle) * travel, y: sin(angle) * travel)
            .opacity(progress <= 0 || progress >= 1 ? 0 : sin(.pi * progress))
            .scaleEffect(1 - 0.5 * progress)
    }
}

private nonisolated struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private extension ReplayGainMode {
    var localizedName: String {
        switch self {
        case .off: String(localized: "Off")
        case .track: String(localized: "Track")
        case .album: String(localized: "Album")
        }
    }
}
