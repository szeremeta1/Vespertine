//
// Vespertine — the visualizer's axes and the song's title, drawn with AppKit into the overlay texture.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit

enum VisualizerOverlay {
    /// The plot's margins in points, as the bar and spectrogram shaders use them.
    static let margins = NSEdgeInsets(top: 36, left: 64, bottom: 40, right: 28)
    static let lowHz = 20.0, highHz = 20_000.0
    static let frequencies: [Double] = [50, 100, 200, 500, 1000, 2000, 5000, 10_000]

    /// Where `hz` falls across the log-frequency axis, 0…1.
    static func position(of hz: Double) -> Double { log(hz / lowHz) / log(highHz / lowHz) }

    static func frequencyLabel(_ hz: Double, _ labels: VisualizerLabels) -> String {
        hz >= 1000 ? labels.kilohertz(hz / 1000) : labels.hertz(Int(hz))
    }

    static let text = NSColor(srgbRed: 0.925, green: 0.902, blue: 0.855, alpha: 1)

    static func draw(in size: CGSize, settings: VisualizerSettings, scene: VisualizerScene, labels: VisualizerLabels) {
        let m = margins
        let plot = CGRect(x: m.left, y: m.top, width: size.width - m.left - m.right, height: size.height - m.top - m.bottom)
        let axis: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: text.withAlphaComponent(0.5),
        ]
        let grid = NSColor.white.withAlphaComponent(0.06)
        switch settings.style {
        case .bars where plot.width > 40 && plot.height > 40:
            let floor = Double(VisualizerAnalyzer.Configuration().floorDB)
            let levels: [(db: Int, height: Double)] = settings.decibelScale
                ? stride(from: 0, through: Int(floor) + 1, by: -12).map { ($0, 1 - Double($0) / floor) }
                : [-12, -18, -24, -30].map { ($0, pow(10, Double($0 + 12) / 20)) }
            for level in levels {
                let y = plot.maxY - level.height * plot.height
                grid.setFill()
                NSRect(x: plot.minX, y: y.rounded() - 0.25, width: plot.width, height: 0.5).fill()
                let s = NSAttributedString(string: labels.decibels(level.db), attributes: axis)
                let bounds = s.size()
                s.draw(at: CGPoint(x: plot.minX - 8 - bounds.width, y: y - bounds.height / 2))
            }
            for hz in frequencies {
                let x = plot.minX + position(of: hz) * plot.width
                let s = NSAttributedString(string: frequencyLabel(hz, labels), attributes: axis)
                s.draw(at: CGPoint(x: x - s.size().width / 2, y: plot.maxY + 12))
            }
        case .spectrogram where plot.width > 40 && plot.height > 40:
            for hz in frequencies + [20_000 * 0.999] where hz < 20_000 {
                let y = plot.maxY - position(of: hz) * plot.height
                grid.setFill()
                NSRect(x: plot.minX - 4, y: y.rounded() - 0.25, width: 4, height: 0.5).fill()
                let s = NSAttributedString(string: frequencyLabel(hz, labels), attributes: axis)
                let bounds = s.size()
                s.draw(at: CGPoint(x: plot.minX - 8 - bounds.width, y: y - bounds.height / 2))
            }
            let seconds = settings.spectrogramSeconds
            let step = seconds > 16 ? 5 : seconds > 8 ? 2 : 1
            for t in stride(from: 0, through: Int(seconds), by: step) {
                let x = plot.maxX - Double(t) / seconds * plot.width
                grid.setFill()
                NSRect(x: x.rounded() - 0.25, y: plot.maxY, width: 0.5, height: 4).fill()
                let s = NSAttributedString(string: labels.secondsAgo(t), attributes: axis)
                let w = s.size().width
                s.draw(at: CGPoint(x: min(max(x - w / 2, plot.minX), plot.maxX - w), y: plot.maxY + 12))
            }
        default:
            break
        }

        guard settings.showsTrackInfo, let title = scene.title, !title.isEmpty else { return }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 6
        let artist = scene.artist ?? ""
        switch settings.style {
        case .bars, .spectrogram:
            let line = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: text.withAlphaComponent(0.85),
            ])
            if !artist.isEmpty {
                line.append(NSAttributedString(string: "  \(artist)", attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .regular), .foregroundColor: text.withAlphaComponent(0.5),
                ]))
            }
            // Clear of the window's close, minimize and zoom buttons at the top left.
            let x = max(m.left, 88)
            line.draw(with: CGRect(x: x, y: 12, width: size.width - x - m.right, height: 18),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        case .vinyl, .club:
            let serif = NSFont.systemFont(ofSize: 24, weight: .regular).fontDescriptor.withDesign(.serif)
                .flatMap { NSFont(descriptor: $0, size: 24) } ?? NSFont.systemFont(ofSize: 24)
            let width = min(size.width * 0.45, 520)
            let titleText = NSAttributedString(string: title, attributes: [.font: serif, .foregroundColor: text, .shadow: shadow])
            let artistText = NSAttributedString(string: artist, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .medium), .foregroundColor: text.withAlphaComponent(0.6), .shadow: shadow,
            ])
            let bottom = size.height - 32
            artistText.draw(with: CGRect(x: 36, y: bottom - 18, width: width, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            titleText.draw(with: CGRect(x: 36, y: bottom - 50, width: width, height: 30), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
