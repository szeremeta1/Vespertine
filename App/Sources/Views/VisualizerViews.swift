//
// Vespertine — the visualizer window: a Metal view of the music, its controls, and a window that remembers its display.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import MediaAccessibility
import MetalKit
import SwiftUI
import VespertineLibrary
import VespertineVisualizer

extension VisualizerStyle {
    var label: String {
        switch self {
        case .bars: String(localized: "Spectrum", comment: "Visualizer style: bar spectrum analyzer.")
        case .spectrogram: String(localized: "Spectrogram", comment: "Visualizer style: scrolling spectrogram.")
        case .vinyl: String(localized: "Vinyl", comment: "Visualizer style: the album on a spinning record.")
        case .club: String(localized: "Club", comment: "Visualizer style: club lights, rings and lasers pulsing with the beat.")
        case .scope: String(localized: "Scope", comment: "Visualizer style: a stereo goniometer or oscilloscope on a phosphor screen.")
        case .meters: String(localized: "Meters", comment: "Visualizer style: a pair of analogue VU or PPM meters with needles.")
        case .particles: String(localized: "Particles", comment: "Visualizer style: a field of particles moving with the music.")
        case .mirrored: String(localized: "Mirrored", comment: "Visualizer style: the bar spectrum mirrored, around a circle or across a line.")
        }
    }
}

extension VisualizerTheme {
    var label: String {
        switch self {
        case .vespertine: String(localized: "Vespertine", comment: "Visualizer colours: the app's brand colours (obsidian, copper, brass, ivory). Also the app's name.")
        case .brass: String(localized: "Brass", comment: "Visualizer colours: the app's own brass on black.")
        case .neon: String(localized: "Neon", comment: "Visualizer colours: magenta, violet and cyan.")
        case .aurora: String(localized: "Aurora", comment: "Visualizer colours: teal, green and pale violet.")
        case .ember: String(localized: "Ember", comment: "Visualizer colours: red, orange and gold.")
        case .ice: String(localized: "Ice", comment: "Visualizer colours: blues and white.")
        case .mono: String(localized: "Monochrome", comment: "Visualizer colours: white on black.")
        case .albumArt: String(localized: "Album Art", comment: "Visualizer colours: the colours of the cover of whatever is playing.")
        }
    }
}

extension VisualizerLabels {
    static let localized = VisualizerLabels(
        hertz: { String(localized: "\(String($0)) Hz", comment: "Visualizer axis: a frequency in hertz, e.g. 500 Hz.") },
        kilohertz: { String(localized: "\($0.formatted(.number.precision(.fractionLength(0...1)))) kHz", comment: "Visualizer axis: a frequency in kilohertz, e.g. 2 kHz.") },
        decibels: { String(localized: "\(String($0)) dB", comment: "Visualizer axis: a level in decibels, e.g. -24 dB.") },
        secondsAgo: { String(localized: "\(String(-$0)) s", comment: "Visualizer axis: seconds ago on the spectrogram, e.g. -10 s (0 is now).") })
}

extension VisualizerScopeMode {
    var label: String {
        switch self {
        case .goniometer: String(localized: "Goniometer", comment: "Visualizer scope: left against right (a stereo Lissajous figure).")
        case .oscilloscope: String(localized: "Oscilloscope", comment: "Visualizer scope: left and right waveforms against time.")
        }
    }
}

extension VisualizerMirrorLayout {
    var label: String {
        switch self {
        case .circle: String(localized: "Circle", comment: "Visualizer option: mirrored bars around a circle.")
        case .line: String(localized: "Line", comment: "Visualizer option: mirrored bars up and down from a line.")
        }
    }
}

/// The beat strobe's safeguards: it's off by default, turning it on asks first (once), its option says what it can
/// do, and it stays off while Reduce Motion or Dim Flashing Lights is on.
struct StrobeToggle: View {
    @Binding var settings: VisualizerSettings
    @Binding var asking: Bool
    var reduceMotion: Bool
    var dimFlashing: Bool
    var label: LocalizedStringKey = "Beat Strobe"

    var body: some View {
        let blocked = reduceMotion || dimFlashing
        Toggle(label, isOn: Binding(get: { settings.strobe && !blocked }, set: { on in
            if on && !settings.strobeWarningAccepted { asking = true } else { settings.strobe = on }
        }))
        .disabled(blocked)
        .help(Text("May trigger seizures in people with photosensitive epilepsy."))
        if reduceMotion {
            Text("No strobe while Reduce Motion is on.")
        } else if dimFlashing {
            Text("No strobe while Dim Flashing Lights is on.")
        }
    }
}

extension View {
    /// Asks before the strobe is turned on for the first time: a photosensitivity warning that has to be accepted.
    func strobeWarning(isPresented: Binding<Bool>, settings: Binding<VisualizerSettings>) -> some View {
        alert("Photosensitivity Warning", isPresented: isPresented) {
            Button("Turn On Strobe", role: .destructive) {
                settings.wrappedValue.strobeWarningAccepted = true
                settings.wrappedValue.strobe = true
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("The beat strobe flashes the whole screen on strong beats. Flashing lights may trigger seizures in people with photosensitive epilepsy. If you or anyone watching has epilepsy or has ever had a seizure, leave it off. If you feel dizzy or unwell while it flashes, look away and turn it off.")
        }
    }

    /// Keeps `dimmed` in step with Dim Flashing Lights (System Settings > Accessibility > Display).
    func readsDimFlashingLights(_ dimmed: Binding<Bool>) -> some View {
        onAppear { dimmed.wrappedValue = MADimFlashingLightsEnabled() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name(kMADimFlashingLightsChangedNotification as String))) { _ in
                dimmed.wrappedValue = MADimFlashingLightsEnabled()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                dimmed.wrappedValue = MADimFlashingLightsEnabled()
            }
    }
}

/// Holds the renderer, made once per window (it compiles the shaders).
@MainActor
final class VisualizerHolder {
    lazy var renderer: VisualizerRenderer? = VisualizerRenderer()
}

struct VisualizerWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holder = VisualizerHolder()
    @State private var controlsShown = true
    @State private var hovering = false
    @State private var hide: Task<Void, Never>?
    @State private var fullScreen = false
    @State private var window: NSWindow?
    @State private var dimFlashing = false
    @State private var askingStrobe = false

    var body: some View {
        @Bindable var settings = model.settings
        ZStack(alignment: .bottom) {
            if let renderer = holder.renderer {
                VisualizerMetalView(renderer: renderer, model: model)
                    .accessibilityLabel(Text("Visualizer"))
                    .accessibilityValue(Text(model.settings.visualizer.style.label))
            } else {
                Text("This Mac can't draw the visualizer: Metal isn't available.")
                    .font(Typeface.ui(13)).foregroundStyle(Palette.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if controlsShown {
                VisualizerControls(settings: $settings.visualizer, askingStrobe: $askingStrobe, fullScreen: fullScreen,
                                   reduceMotion: reduceMotion, dimFlashing: dimFlashing) {
                    if let window { VisualizerWindowAccessor.allowFullScreen(window); window.toggleFullScreen(nil) }
                }
                .padding(.bottom, 22)
                .onHover { hovering = $0; if !$0 { scheduleHide() } }
                .transition(.opacity)
            }
        }
        .frame(minWidth: VisualizerWindowState.minimumSize.width, minHeight: VisualizerWindowState.minimumSize.height)
        .background(Color.black)
        .ignoresSafeArea()
        .background(VisualizerWindowAccessor(model: model, fullScreen: $fullScreen, window: $window))
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .onAppear { scheduleHide() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { model.player.togglePlayPause(); return .handled }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), (1...VisualizerStyle.allCases.count).contains(n) else { return .ignored }
            model.settings.visualizer.style = VisualizerStyle.allCases[n - 1]
            showControls()
            return .handled
        }
        .onChange(of: model.settings.visualizer, initial: true) { _, new in
            holder.renderer?.settings = new
            model.visualizer.apply(new)
        }
        .onChange(of: reduceMotion, initial: true) { _, new in holder.renderer?.reduceMotion = new }
        .readsDimFlashingLights($dimFlashing)
        .onChange(of: dimFlashing, initial: true) { _, new in holder.renderer?.reduceFlashing = new }
        .strobeWarning(isPresented: $askingStrobe, settings: $settings.visualizer)
        .onChange(of: askingStrobe) { _, asking in if asking { showControls() } }
        .onChange(of: model.settings.visualizerEnabled) { _, on in if !on { dismissWindow(id: "visualizer") } }
        .task(id: model.artworkKey(model.player.current?.track)) {
            holder.renderer?.labels = .localized
            guard let key = model.artworkKey(model.player.current?.track) else { holder.renderer?.setArtwork(nil); return }
            let image = await ArtworkCache.shared.image(key, size: 1200)
            guard !Task.isCancelled else { return }
            holder.renderer?.setArtwork(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
        .task(id: model.artworkKey(model.player.current?.track)) {
            // The Album Art colours: worked out in the background, then faded to (the old song's stay until then).
            guard let key = model.artworkKey(model.player.current?.track) else { holder.renderer?.setAlbumPalette(nil); return }
            let palette = await ArtworkCache.shared.albumPalette(key)
            guard !Task.isCancelled else { return }
            holder.renderer?.setAlbumPalette(palette)
        }
        .animation(.easeInOut(duration: 0.25), value: controlsShown)
        .task {
            // QA: -VespertineVisualizerAsk strobe shows the strobe's warning, as turning it on the first time does.
            guard LaunchArguments().string(forKey: "VespertineVisualizerAsk") == "strobe" else { return }
            try? await Task.sleep(for: .seconds(1.5))
            askingStrobe = true
        }
        .task {
            // QA: -VespertineVisualizerStats YES logs what the analysis and drawing cost, every 10 s.
            guard LaunchArguments().bool(forKey: "VespertineVisualizerStats") else { return }
            while !Task.isCancelled {
                holder.renderer?.resetStats()
                try? await Task.sleep(for: .seconds(10))
                let feed = model.visualizer.feed.stats, gpu = holder.renderer?.gpuStats ?? .init()
                print(String(format: "visualizer %@: analysis %.1f µs/frame (%d frames, %d dropped), GPU %.2f ms/frame, %.0f frames/s",
                             model.settings.visualizer.style.rawValue, feed.averageMicroseconds, feed.frames, feed.dropped,
                             gpu.averageMilliseconds, Double(gpu.frames) / 10))
            }
        }
    }

    private func showControls() {
        if !controlsShown { controlsShown = true }
        scheduleHide()
    }

    /// The controls fade out after a few seconds without the pointer moving (and, in full screen, so does the pointer).
    private func scheduleHide() {
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !hovering else { return }
            controlsShown = false
            if fullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
}

/// The controls along the bottom of the visualizer: style, colours, sensitivity, options and full screen.
struct VisualizerControls: View {
    @Binding var settings: VisualizerSettings
    @Binding var askingStrobe: Bool
    var fullScreen: Bool
    var reduceMotion: Bool
    var dimFlashing: Bool
    var toggleFullScreen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Picker("Style", selection: $settings.style) {
                ForEach(VisualizerStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            Menu {
                Picker("Colors", selection: $settings.theme) {
                    ForEach(VisualizerTheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "paintpalette")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Colors")
            .accessibilityLabel(Text("Colors"))
            HStack(spacing: 6) {
                Image(systemName: "dial.low").foregroundStyle(Palette.text2)
                // Logarithmic: the middle is 1 (as measured), the ends a quarter and four times.
                Slider(value: Binding(get: { log2(settings.sensitivity) }, set: { settings.sensitivity = pow(2, $0) }), in: -2...2)
                    .frame(width: 110)
                    .accessibilityLabel(Text("Sensitivity"))
            }
            .help("Sensitivity")
            Menu {
                options
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Options")
            .accessibilityLabel(Text("Options"))
            Button(action: toggleFullScreen) {
                Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help(fullScreen ? String(localized: "Exit Full Screen") : String(localized: "Enter Full Screen"))
            .accessibilityLabel(fullScreen ? Text("Exit Full Screen") : Text("Enter Full Screen"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var options: some View {
        switch settings.style {
        case .bars:
            Toggle("Decibel Scale", isOn: $settings.decibelScale)
            Toggle("Peak Caps", isOn: $settings.peakCaps)
            Picker("Bands", selection: $settings.bandCount) {
                ForEach(VisualizerSettings.bandCounts, id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
        case .spectrogram:
            Picker("Time Span", selection: $settings.spectrogramSeconds) {
                ForEach([6.0, 12, 20, 30], id: \.self) { Text("\(String(Int($0))) s", comment: "Spectrogram history length, e.g. 12 s").tag($0) }
            }
        case .vinyl:
            Toggle("Tonearm", isOn: $settings.tonearm)
            Picker("Speed", selection: $settings.rpm) {
                Text("33⅓ RPM").tag(100.0 / 3)
                Text("45 RPM").tag(45.0)
            }
        case .club:
            StrobeToggle(settings: $settings, asking: $askingStrobe, reduceMotion: reduceMotion, dimFlashing: dimFlashing)
            Text("May trigger seizures in people with photosensitive epilepsy.")
        case .scope:
            Picker("Display", selection: $settings.scopeMode) {
                ForEach(VisualizerScopeMode.allCases) { Text($0.label).tag($0) }
            }
        case .meters:
            Picker("Meter", selection: $settings.meterKind) {
                Text(verbatim: "VU").tag(VisualizerMeterKind.vu)
                Text(verbatim: "PPM").tag(VisualizerMeterKind.ppm)
            }
            Picker("Reference Level", selection: $settings.meterReference) {
                Text("Automatic").tag(Double?.none)
                ForEach(VisualizerSettings.meterReferences, id: \.self) { Text("\(String(Int($0))) dBFS").tag(Double?.some($0)) }
            }
        case .particles:
            Toggle("Trails", isOn: $settings.particleTrails)
        case .mirrored:
            Picker("Shape", selection: $settings.mirrorLayout) {
                ForEach(VisualizerMirrorLayout.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Peak Caps", isOn: $settings.peakCaps)
            Picker("Bands", selection: $settings.bandCount) {
                ForEach(VisualizerSettings.bandCounts, id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
        }
        Divider()
        Toggle("Show Song Title", isOn: $settings.showsTrackInfo)
    }
}

/// The Metal view: drawn at the display's refresh rate (120 Hz on ProMotion) while the window is on screen, and not at
/// all while it's closed, minimized or covered.
struct VisualizerMetalView: NSViewRepresentable {
    let renderer: VisualizerRenderer
    let model: AppModel

    func makeNSView(context: Context) -> VisualizerMTKView {
        let view = VisualizerMTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.delegate = renderer
        view.visualizer = model.visualizer
        renderer.frameSource = { [weak model] in
            guard let model else { return (.silent(bands: 64, fine: 512), VisualizerScene()) }
            let player = model.player
            let track = player.current?.track
            let duration = player.duration > 0 ? player.duration : (track?.duration ?? 0)
            let scene = VisualizerScene(title: track?.title, artist: track?.displayArtist.libraryDisplayName,
                                        progress: track == nil ? nil : duration > 0 ? player.position / duration : 0,
                                        isPlaying: player.isPlaying)
            return (model.visualizer.feed.frame, scene)
        }
        return view
    }

    func updateNSView(_ view: VisualizerMTKView, context: Context) {}

    static func dismantleNSView(_ view: VisualizerMTKView, coordinator: ()) {
        view.setShowing(false)
    }
}

final class VisualizerMTKView: MTKView {
    weak var visualizer: VisualizerModel?
    private var showing = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { setShowing(false); return }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
                                          NSWindow.willCloseNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated {
                    if closing { self?.setShowing(false) } else { self?.refresh() }
                }
            })
        }
        refresh()
    }

    /// The display's own refresh rate: 120 on ProMotion, 60 on most others.
    private var displayRate: Int { max(30, window?.screen?.maximumFramesPerSecond ?? 60) }

    private func refresh() {
        guard let window else { return }
        let rate = displayRate
        if preferredFramesPerSecond != rate {
            preferredFramesPerSecond = rate
            if showing { visualizer?.rateChanged(Double(rate)) }
        }
        setShowing(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }

    func setShowing(_ on: Bool) {
        guard on != showing else { return }
        showing = on
        isPaused = !on
        if on { visualizer?.began(rate: Double(displayRate)) } else { visualizer?.ended() }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Configures the visualizer's window: full screen on any display, black behind the picture, and back where it was
/// (display, size, full screen) each time it opens.
struct VisualizerWindowAccessor: NSViewRepresentable {
    let model: AppModel
    @Binding var fullScreen: Bool
    @Binding var window: NSWindow?

    final class Probe: NSView {
        var configure: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure?(window) }
        }
    }

    final class Coordinator {
        nonisolated(unsafe) var observers: [NSObjectProtocol] = []
        var configured: NSWindow?
        /// The frame before full screen: what to come back to.
        var windowedFrame: CGRect?
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        let coordinator = context.coordinator
        probe.configure = { window in
            MainActor.assumeIsolated { configure(window, coordinator) }
        }
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {}

    @MainActor
    private func configure(_ window: NSWindow, _ c: Coordinator) {
        guard c.configured !== window else { return }
        c.configured = window
        self.window = window
        Self.allowFullScreen(window)
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isRestorable = false   // placed from its own saved state below
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = VisualizerWindowState.minimumSize

        let saved = model.settings.visualizerWindow
        if let saved, let placed = saved.placement(among: Self.displays()) {
            window.setFrame(placed.frame, display: true)
            if saved.fullScreen {
                // Full screen only takes once the window is on screen, which is a moment after it's configured.
                Task { @MainActor [weak window] in
                    for _ in 0..<40 {
                        guard let window else { return }
                        if window.isVisible {
                            Self.allowFullScreen(window)
                            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
        }
        let center = NotificationCenter.default
        let save: @Sendable (Notification) -> Void = { [weak window] note in
            let name = note.name
            MainActor.assumeIsolated {
                guard let window else { return }
                switch name {
                case NSWindow.willEnterFullScreenNotification: c.windowedFrame = window.frame
                case NSWindow.didEnterFullScreenNotification: fullScreen = true
                case NSWindow.didExitFullScreenNotification: fullScreen = false; c.windowedFrame = nil
                default: break
                }
                // While closing, it's still in or out of full screen as the person left it.
                let inFullScreen = window.styleMask.contains(.fullScreen)
                let screen = window.screen
                let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                model.settings.visualizerWindow = VisualizerWindowState(
                    frame: inFullScreen ? (c.windowedFrame ?? model.settings.visualizerWindow?.frame ?? window.frame) : window.frame,
                    displayID: id, displayName: screen?.localizedName, fullScreen: inFullScreen)
            }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.willEnterFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.willCloseNotification] {
            c.observers.append(center.addObserver(forName: name, object: window, queue: .main, using: save))
        }
        fullScreen = window.styleMask.contains(.fullScreen)
    }

    /// SwiftUI makes a secondary `Window` scene's window an auxiliary one, which can only join another window's full
    /// screen. The visualizer goes full screen on a display of its own.
    @MainActor
    static func allowFullScreen(_ window: NSWindow) {
        window.collectionBehavior.remove([.auxiliary, .fullScreenAuxiliary, .fullScreenNone])
        window.collectionBehavior.insert([.primary, .fullScreenPrimary])
    }

    /// The connected displays, the main one (with the menu bar) first.
    @MainActor
    static func displays() -> [VisualizerWindowState.Display] {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return VisualizerWindowState.Display(id: id, name: screen.localizedName, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
}
