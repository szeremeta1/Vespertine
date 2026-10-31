//
// Vespertine — the visualizer window's choices, and where the window goes.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation

public enum VisualizerStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Classic bar spectrum analyzer: log-spaced bands, held peaks.
    case bars
    /// Scrolling spectrogram: frequency up, time across, level as colour.
    case spectrogram
    /// The album on a spinning record: grooves, a tonearm, a platter rim lit by the music.
    case vinyl
    /// Club: rings and lasers pulsing with the beat.
    case club

    public var id: String { rawValue }
}

public enum VisualizerTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The app's own obsidian and brass.
    case brass
    /// Magenta, violet and cyan.
    case neon
    /// Green, teal and violet.
    case aurora
    /// Red, orange and gold.
    case ember
    /// Blues and white.
    case ice
    /// White on black.
    case mono

    public var id: String { rawValue }

    /// Four colours from dark to bright (linear-ish sRGB, 0…1), for gradients and the spectrogram's colour map.
    public var stops: [SIMD3<Float>] {
        switch self {
        case .brass: [Self.rgb(0x16110A), Self.rgb(0x7C6541), Self.rgb(0xC8A66A), Self.rgb(0xF6E7C4)]
        case .neon: [Self.rgb(0x12021F), Self.rgb(0x7A1FD6), Self.rgb(0xFF2D95), Self.rgb(0x4CF2FF)]
        case .aurora: [Self.rgb(0x03141A), Self.rgb(0x0F7B6C), Self.rgb(0x3FE0A0), Self.rgb(0xB89CFF)]
        case .ember: [Self.rgb(0x1A0503), Self.rgb(0x9C1C0E), Self.rgb(0xFF6A1A), Self.rgb(0xFFE08A)]
        case .ice: [Self.rgb(0x020A1C), Self.rgb(0x1D4ED8), Self.rgb(0x5CC8FF), Self.rgb(0xF0FAFF)]
        case .mono: [Self.rgb(0x050505), Self.rgb(0x4A4A4A), Self.rgb(0xB5B5B5), Self.rgb(0xFFFFFF)]
        }
    }

    static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
    }
}

/// Everything the visualizer window remembers about how it draws. Stored as JSON; a missing or unknown value falls
/// back to its default, so settings from another version still load.
public struct VisualizerSettings: Codable, Sendable, Equatable {
    public var style: VisualizerStyle = .bars
    public var theme: VisualizerTheme = .brass
    /// Display gain, 0.25…4 (1: as measured).
    public var sensitivity: Double = 1
    /// Bars: in dB (true) or linear amplitude.
    public var decibelScale = true
    public var bandCount = 64
    public var peakCaps = true
    /// Seconds of history across the spectrogram.
    public var spectrogramSeconds: Double = 12
    public var tonearm = true
    /// Record speed: 33⅓ or 45.
    public var rpm: Double = 100.0 / 3
    /// Full-window flashes on strong beats (club). Off by default, and never while Reduce Motion is on.
    public var strobe = false
    /// The song's title and artist in a corner of the window.
    public var showsTrackInfo = true

    public static let bandCounts = [32, 48, 64, 96, 128]
    public static let sensitivityRange = 0.25...4.0
    public static let spectrogramRange = 4.0...30.0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case style, theme, sensitivity, decibelScale, bandCount, peakCaps, spectrogramSeconds, tonearm, rpm, strobe, showsTrackInfo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VisualizerSettings()
        style = (try? c.decodeIfPresent(VisualizerStyle.self, forKey: .style)) ?? d.style
        theme = (try? c.decodeIfPresent(VisualizerTheme.self, forKey: .theme)) ?? d.theme
        sensitivity = (try? c.decodeIfPresent(Double.self, forKey: .sensitivity)) ?? d.sensitivity
        decibelScale = (try? c.decodeIfPresent(Bool.self, forKey: .decibelScale)) ?? d.decibelScale
        bandCount = (try? c.decodeIfPresent(Int.self, forKey: .bandCount)) ?? d.bandCount
        peakCaps = (try? c.decodeIfPresent(Bool.self, forKey: .peakCaps)) ?? d.peakCaps
        spectrogramSeconds = (try? c.decodeIfPresent(Double.self, forKey: .spectrogramSeconds)) ?? d.spectrogramSeconds
        tonearm = (try? c.decodeIfPresent(Bool.self, forKey: .tonearm)) ?? d.tonearm
        rpm = (try? c.decodeIfPresent(Double.self, forKey: .rpm)) ?? d.rpm
        strobe = (try? c.decodeIfPresent(Bool.self, forKey: .strobe)) ?? d.strobe
        showsTrackInfo = (try? c.decodeIfPresent(Bool.self, forKey: .showsTrackInfo)) ?? d.showsTrackInfo
        self = normalized
    }

    /// Values pulled into range (a hand-edited or older file can hold anything).
    public var normalized: VisualizerSettings {
        var s = self
        if !s.sensitivity.isFinite { s.sensitivity = 1 }
        s.sensitivity = min(max(s.sensitivity, Self.sensitivityRange.lowerBound), Self.sensitivityRange.upperBound)
        if !Self.bandCounts.contains(s.bandCount) {
            s.bandCount = Self.bandCounts.min { abs($0 - s.bandCount) < abs($1 - s.bandCount) } ?? 64
        }
        if !s.spectrogramSeconds.isFinite { s.spectrogramSeconds = 12 }
        s.spectrogramSeconds = min(max(s.spectrogramSeconds, Self.spectrogramRange.lowerBound), Self.spectrogramRange.upperBound)
        s.rpm = s.rpm > 40 ? 45 : 100.0 / 3
        return s
    }

    public static let defaultsKey = "visualizer"

    public static func load(from defaults: UserDefaults) -> VisualizerSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(VisualizerSettings.self, from: data) else { return VisualizerSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(normalized), forKey: Self.defaultsKey)
    }
}

/// Where the visualizer window was, and how to put it back: on the same display if it's still connected, else on
/// the main one, always on screen.
public struct VisualizerWindowState: Codable, Sendable, Equatable {
    public var frame: CGRect
    /// The display it was on: its Core Graphics display ID and name (the ID can change between connections; the name
    /// usually doesn't).
    public var displayID: UInt32?
    public var displayName: String?
    public var fullScreen: Bool

    public init(frame: CGRect, displayID: UInt32?, displayName: String?, fullScreen: Bool) {
        self.frame = frame
        self.displayID = displayID
        self.displayName = displayName
        self.fullScreen = fullScreen
    }

    public struct Display: Sendable, Equatable {
        public var id: UInt32
        public var name: String
        /// The display's whole frame and the part windows may use (without the menu bar and Dock), in global
        /// coordinates.
        public var frame: CGRect
        public var visibleFrame: CGRect
        public init(id: UInt32, name: String, frame: CGRect, visibleFrame: CGRect) {
            self.id = id
            self.name = name
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    public static let defaultsKey = "visualizerWindow"
    public static let defaultSize = CGSize(width: 1280, height: 720)
    public static let minimumSize = CGSize(width: 480, height: 300)

    /// The display to use: the one it was on (by ID, then by name), else the first (the main display).
    public func display(among displays: [Display]) -> Display? {
        displays.first { $0.id == displayID } ?? displays.first { displayName != nil && $0.name == displayName } ?? displays.first
    }

    /// The frame to open with. On its own display, the saved frame, moved and shrunk as needed to fit what's visible;
    /// on another display (its own is gone), the same size centred there.
    public func placement(among displays: [Display]) -> (frame: CGRect, display: Display)? {
        guard let display = display(among: displays) else { return nil }
        let area = display.visibleFrame
        let own = display.id == displayID || (displayName != nil && display.name == displayName)
        var size = frame.size
        if !(size.width.isFinite && size.height.isFinite) || size.width < 1 || size.height < 1 { size = Self.defaultSize }
        size.width = min(max(size.width, Self.minimumSize.width), area.width)
        size.height = min(max(size.height, Self.minimumSize.height), area.height)
        var origin: CGPoint
        if own, frame.origin.x.isFinite, frame.origin.y.isFinite {
            origin = frame.origin
        } else {
            origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return (CGRect(origin: origin, size: size), display)
    }

    public static func load(from defaults: UserDefaults) -> VisualizerWindowState? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(VisualizerWindowState.self, from: $0) }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
