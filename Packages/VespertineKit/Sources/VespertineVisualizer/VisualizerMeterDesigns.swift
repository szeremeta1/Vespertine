//
// Vespertine — the meter designs modelled on real instruments: where each meter sits in its case, panel and cabinet,
// where its scale puts the needle, and its printing (scales, numbers, legends), drawn with AppKit into a mask that
// the shader lights and colours. The original pair is drawn by VisualizerMeterFace and is untouched by this.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit

/// A design other than the original, as the shader knows it (its number is `m[0].x` there).
enum MeterDesign: Int, Sendable, CaseIterable {
    case broadcast = 1, console, tape, cassette
    case bbc = 11, bbcStereo, ebu, din, nordic

    /// The design the settings ask for, or nil for the original pair.
    init?(_ settings: VisualizerSettings) {
        switch settings.meterKind {
        case .vu:
            switch settings.vuDesign {
            case .original: return nil
            case .broadcast: self = .broadcast
            case .console: self = .console
            case .tape: self = .tape
            case .cassette: self = .cassette
            }
        case .ppm:
            switch settings.ppmDesign {
            case .original: return nil
            case .bbc: self = .bbc
            case .bbcStereo: self = .bbcStereo
            case .ebu: self = .ebu
            case .din: self = .din
            case .nordic: self = .nordic
            }
        }
    }

    var isPPM: Bool { rawValue > 10 }
    /// The four designs on the BBC's Sifam-type movement and case.
    var isSifam: Bool { self == .bbc || self == .bbcStereo || self == .ebu || self == .nordic }
    /// A centre-zero balance meter between the two (the VU designs that sit in a studio panel).
    var hasBalance: Bool { self == .broadcast || self == .console }

    /// The ballistics the design needs besides the VU and Type IIa pair.
    var extras: VisualizerMeters.Extras {
        switch self {
        case .cassette: .wideVU
        case .din, .nordic: .typeI
        case .bbcStereo: .midSide
        default: []
        }
    }
}

/// One instrument in a design: a meter with one or two needles, a light band, or the balance meter.
struct MeterInstrument: Sendable, Equatable {
    enum Kind: Int, Sendable {
        case needle = 0
        /// Two needles on one pivot: red A (left) and green B (right).
        case twinAB = 1
        /// Two needles on one pivot: white M and yellow S.
        case twinMS = 2
        /// A band of light across a straight scale (the DIN light-pointer instrument).
        case band = 3
        /// The centre-zero balance meter.
        case balance = 4
    }
    var kind: Kind
    /// The face behind the glass, and the case round it (points, y down).
    var window: CGRect
    var housing: CGRect
    var pivot: CGPoint
    /// Where the needle shows, from and to (points from the pivot). For a band: the scale's left and right ends (x)
    /// and the band's centre and half height (y).
    var needle: (CGFloat, CGFloat)
    var band: CGRect = .zero
    /// Its peak light, if it has one: centre and radius.
    var led: CGPoint?
    var ledRadius: CGFloat = 0
    /// Which channel's peak light (0 left, 1 right).
    var channel = 0

    static func == (a: MeterInstrument, b: MeterInstrument) -> Bool {
        a.kind == b.kind && a.window == b.window && a.housing == b.housing && a.pivot == b.pivot && a.needle == b.needle
            && a.band == b.band && a.led == b.led && a.ledRadius == b.ledRadius && a.channel == b.channel
    }
}

/// Where everything in a design goes, in points (y down), for one window size.
struct MeterPlan: Sendable, Equatable {
    var design: MeterDesign
    /// The outer cabinet (wood, or the desk the instruments stand on), the front panel, and the unit everything is
    /// measured in (the main meters' face height, in points).
    var cabinet: CGRect
    var panel: CGRect
    var unit: CGFloat
    var instruments: [MeterInstrument]

    // MARK: Layout

    /// The plan for `design` in a window of `size` points: as large as fits in the space the original meters use.
    static func make(_ design: MeterDesign, in size: CGSize) -> MeterPlan {
        let area = CGRect(x: 32, y: VisualizerLayout.top, width: max(40, size.width - 64),
                          height: max(40, size.height - VisualizerLayout.top - VisualizerLayout.titleRoom))
        let wide = area.width / area.height >= 1.35
        var plan = MeterPlan(design: design, cabinet: .zero, panel: .zero, unit: 1, instruments: [])
        switch design {
        case .bbc, .bbcStereo, .ebu, .nordic: plan.layoutSifam(area: area, wide: wide)
        case .broadcast: plan.layoutBroadcast(area: area, wide: wide)
        case .console: plan.layoutConsole(area: area, wide: wide)
        case .tape: plan.layoutTape(area: area, wide: wide)
        case .cassette: plan.layoutCassette(area: area, wide: wide)
        case .din: plan.layoutDIN(area: area)
        }
        return plan
    }

    /// The largest unit for a block `w` by `h` units (with a margin of `pad` units already in it) that fits `area`,
    /// and the block's top left there, centred.
    private static func fit(_ w: CGFloat, _ h: CGFloat, in area: CGRect) -> (u: CGFloat, origin: CGPoint) {
        let u = max(1, min(area.width / w, area.height / h))
        return (u, CGPoint(x: area.midX - w * u / 2, y: area.midY - h * u / 2))
    }

    /// The Sifam-type case of the BBC meter (Type 34A): a window 1.77 wide, matt black bezel, a deep lower lip with the
    /// zero screw. The pivot is under the lip, 1.22 below the window's top.
    private static let sifamWindow = CGSize(width: 1.77, height: 1)
    private static let sifamCase = (left: 0.10 as CGFloat, top: 0.08 as CGFloat, bottom: 0.50 as CGFloat)

    private mutating func layoutSifam(area: CGRect, wide: Bool) {
        let w = Self.sifamWindow.width + 2 * Self.sifamCase.left
        let h = Self.sifamCase.top + 1 + Self.sifamCase.bottom
        let margin: CGFloat = 0.24, gap: CGFloat = 0.34, legend: CGFloat = 0.30
        let blockW = wide ? 2 * w + gap + 2 * margin : w + 2 * margin
        let blockH = wide ? h + legend + 2 * margin : 2 * (h + legend) + gap + 2 * margin
        let (u, o) = Self.fit(blockW, blockH, in: area)
        unit = u
        panel = CGRect(x: o.x, y: o.y, width: blockW * u, height: blockH * u)
        cabinet = panel
        for i in 0..<2 {
            let x = o.x + (margin + (wide ? CGFloat(i) * (w + gap) : 0)) * u
            let y = o.y + (margin + (wide ? 0 : CGFloat(i) * (h + legend + gap))) * u
            let housing = CGRect(x: x, y: y, width: w * u, height: h * u)
            let window = CGRect(x: x + Self.sifamCase.left * u, y: y + Self.sifamCase.top * u,
                                width: Self.sifamWindow.width * u, height: u)
            var kind = MeterInstrument.Kind.needle
            if design == .bbcStereo { kind = i == 0 ? .twinAB : .twinMS }
            instruments.append(MeterInstrument(kind: kind, window: window, housing: housing,
                                               pivot: CGPoint(x: window.midX, y: window.minY + 1.22 * u),
                                               needle: (0.18 * u, 1.075 * u), channel: i))
        }
    }

    /// The 1940 volume indicator: a window 1.5 wide in a black moulded case, on a grey panel, with a balance meter.
    private mutating func layoutBroadcast(area: CGRect, wide: Bool) {
        let ww: CGFloat = 1.5, side: CGFloat = 0.17, top: CGFloat = 0.15, bottom: CGFloat = 0.22
        let w = ww + 2 * side, h = top + 1 + bottom
        let bw: CGFloat = 0.66, bh: CGFloat = 0.46   // the balance meter's window
        let margin: CGFloat = 0.3, gap: CGFloat = 0.26, legend: CGFloat = 0.3
        let bal = CGSize(width: bw + 0.2, height: bh + 0.2)
        let blockW = wide ? 2 * w + bal.width + 2 * gap + 2 * margin : w + 2 * margin
        let blockH = wide ? h + legend + 2 * margin : 2 * (h + legend) + bal.height + legend + 2 * gap + 2 * margin
        let (u, o) = Self.fit(blockW, blockH, in: area)
        unit = u
        panel = CGRect(x: o.x, y: o.y, width: blockW * u, height: blockH * u)
        cabinet = panel
        var positions: [CGPoint] = []
        var balanceAt: CGPoint
        if wide {
            positions = [CGPoint(x: margin, y: margin), CGPoint(x: margin + w + 2 * gap + bal.width, y: margin)]
            balanceAt = CGPoint(x: margin + w + gap, y: margin + (h - bal.height) / 2 - 0.06)
        } else {
            positions = [CGPoint(x: margin, y: margin), CGPoint(x: margin, y: margin + h + legend + 2 * gap + bal.height + legend)]
            balanceAt = CGPoint(x: margin + (w - bal.width) / 2, y: margin + h + legend + gap)
        }
        for (i, p) in positions.enumerated() {
            let housing = CGRect(x: o.x + p.x * u, y: o.y + p.y * u, width: w * u, height: h * u)
            let window = CGRect(x: housing.minX + side * u, y: housing.minY + top * u, width: ww * u, height: u)
            instruments.append(MeterInstrument(kind: .needle, window: window, housing: housing,
                                               pivot: CGPoint(x: window.midX, y: window.minY + 1.14 * u),
                                               needle: (0.3 * u, 0.93 * u), channel: i))
        }
        let housing = CGRect(x: o.x + balanceAt.x * u, y: o.y + balanceAt.y * u, width: bal.width * u, height: bal.height * u)
        let window = housing.insetBy(dx: 0.1 * u, dy: 0.1 * u)
        instruments.append(MeterInstrument(kind: .balance, window: window, housing: housing,
                                           pivot: CGPoint(x: window.midX, y: window.minY + 0.6 * u),
                                           needle: (0.16 * u, 0.5 * u)))
    }

    /// Console meters: a window 1.6 wide in a thin black bezel, lit from behind, in a black bridge with legends and a
    /// peak light under each; a small balance meter between.
    private mutating func layoutConsole(area: CGRect, wide: Bool) {
        let ww: CGFloat = 1.6, bezel: CGFloat = 0.075
        let w = ww + 2 * bezel, h = 1 + 2 * bezel
        let bw: CGFloat = 0.7, bh: CGFloat = 0.44
        let margin: CGFloat = 0.26, gap: CGFloat = 0.24, legend: CGFloat = 0.5
        let bal = CGSize(width: bw + 2 * bezel, height: bh + 2 * bezel)
        let blockW = wide ? 2 * w + bal.width + 2 * gap + 2 * margin : w + 2 * margin
        let blockH = wide ? h + legend + 2 * margin : 2 * (h + legend) + bal.height + 2 * gap + 2 * margin
        let (u, o) = Self.fit(blockW, blockH, in: area)
        unit = u
        panel = CGRect(x: o.x, y: o.y, width: blockW * u, height: blockH * u)
        cabinet = panel
        var positions: [CGPoint]
        var balanceAt: CGPoint
        if wide {
            positions = [CGPoint(x: margin, y: margin), CGPoint(x: margin + w + 2 * gap + bal.width, y: margin)]
            balanceAt = CGPoint(x: margin + w + gap, y: margin + (h - bal.height) / 2)
        } else {
            positions = [CGPoint(x: margin, y: margin), CGPoint(x: margin, y: margin + h + legend + 2 * gap + bal.height)]
            balanceAt = CGPoint(x: margin + (w - bal.width) / 2, y: margin + h + legend + gap)
        }
        for (i, p) in positions.enumerated() {
            let housing = CGRect(x: o.x + p.x * u, y: o.y + p.y * u, width: w * u, height: h * u)
            let window = housing.insetBy(dx: bezel * u, dy: bezel * u)
            instruments.append(MeterInstrument(kind: .needle, window: window, housing: housing,
                                               pivot: CGPoint(x: window.midX, y: window.minY + 1.3 * u),
                                               needle: (0.25 * u, 1.13 * u),
                                               led: CGPoint(x: housing.midX + 0.5 * u, y: housing.maxY + 0.27 * u),
                                               ledRadius: 0.045 * u, channel: i))
        }
        let housing = CGRect(x: o.x + balanceAt.x * u, y: o.y + balanceAt.y * u, width: bal.width * u, height: bal.height * u)
        let window = housing.insetBy(dx: bezel * u, dy: bezel * u)
        instruments.append(MeterInstrument(kind: .balance, window: window, housing: housing,
                                           pivot: CGPoint(x: window.midX, y: window.minY + 0.62 * u),
                                           needle: (0.2 * u, 0.53 * u)))
    }

    /// A reel-to-reel recorder's meter panel: two windows side by side behind one chrome-edged opening in an
    /// anthracite panel, a brushed aluminium strip across the top, all in a teak case.
    private mutating func layoutTape(area: CGRect, wide: Bool) {
        let ww: CGFloat = 1.45, gapW: CGFloat = 0.08, rim: CGFloat = 0.06
        let wood: CGFloat = 0.2, strip: CGFloat = 0.42, margin: CGFloat = 0.32, legend: CGFloat = 0.32
        let opening = wide ? CGSize(width: 2 * ww + gapW + 2 * rim, height: 1 + 2 * rim)
                           : CGSize(width: ww + 2 * rim, height: 2 + gapW + 2 * rim)
        let panelW = opening.width + 2 * margin, panelH = strip + legend + opening.height + margin
        let blockW = panelW + 2 * wood, blockH = panelH + 2 * wood
        let (u, o) = Self.fit(blockW, blockH, in: area)
        unit = u
        cabinet = CGRect(x: o.x, y: o.y, width: blockW * u, height: blockH * u)
        panel = cabinet.insetBy(dx: wood * u, dy: wood * u)
        let open = CGRect(x: panel.minX + margin * u, y: panel.minY + (strip + legend) * u,
                          width: opening.width * u, height: opening.height * u)
        for i in 0..<2 {
            let window = wide
                ? CGRect(x: open.minX + (rim + CGFloat(i) * (ww + gapW)) * u, y: open.minY + rim * u, width: ww * u, height: u)
                : CGRect(x: open.minX + rim * u, y: open.minY + (rim + CGFloat(i) * (1 + gapW)) * u, width: ww * u, height: u)
            instruments.append(MeterInstrument(kind: .needle, window: window, housing: window.insetBy(dx: -rim * u, dy: -rim * u),
                                               pivot: CGPoint(x: window.midX, y: window.minY + 1.16 * u),
                                               needle: (0.3 * u, 0.98 * u), channel: i))
        }
    }

    /// A cassette deck's meters: two deep wells with mirrored side walls in a brushed silver front, a row of peak lights
    /// under them, in a walnut case.
    private mutating func layoutCassette(area: CGRect, wide: Bool) {
        let ww: CGFloat = 1.72, wall: CGFloat = 0.09, gap: CGFloat = 0.3
        let wood: CGFloat = 0.22, margin: CGFloat = 0.3, top: CGFloat = 0.46, leds: CGFloat = 0.5
        let w = ww + 2 * wall, h = 1 + 2 * wall
        let panelW = wide ? 2 * w + gap + 2 * margin : w + 2 * margin
        let panelH = wide ? top + h + leds + 0.12 : top + 2 * h + gap + leds + 0.12
        let blockW = panelW + 2 * wood, blockH = panelH + wood
        let (u, o) = Self.fit(blockW, blockH, in: area)
        unit = u
        cabinet = CGRect(x: o.x, y: o.y, width: blockW * u, height: blockH * u)
        panel = CGRect(x: cabinet.minX + wood * u, y: cabinet.minY + wood * u, width: panelW * u, height: panelH * u)
        for i in 0..<2 {
            let x = panel.minX + (margin + (wide ? CGFloat(i) * (w + gap) : 0)) * u
            let y = panel.minY + (top + (wide ? 0 : CGFloat(i) * (h + gap))) * u
            let housing = CGRect(x: x, y: y, width: w * u, height: h * u)
            let window = housing.insetBy(dx: wall * u, dy: wall * u)
            let ledX = wide ? panel.midX + (i == 0 ? -0.2 : 0.2) * u : panel.midX + (i == 0 ? -0.2 : 0.2) * u
            let ledY = wide ? housing.maxY + 0.3 * u : panel.minY + (top + 2 * h + gap + 0.3) * u
            instruments.append(MeterInstrument(kind: .needle, window: window, housing: housing,
                                               pivot: CGPoint(x: window.midX, y: window.minY + 1.2 * u),
                                               needle: (0.15 * u, 1.04 * u),
                                               led: CGPoint(x: ledX, y: ledY), ledRadius: 0.042 * u, channel: i))
        }
    }

    /// Two light-pointer instruments, one above the other, in glossy black moulded cases standing on a wooden desk.
    /// Each window is 4.4 wide; the band runs 0.19 high across its middle.
    private mutating func layoutDIN(area: CGRect) {
        let ww: CGFloat = 4.4, side: CGFloat = 0.3, top: CGFloat = 0.62, bottom: CGFloat = 0.26
        let w = ww + 2 * side, h = top + 1 + bottom, gap: CGFloat = 0.22, desk: CGFloat = 0.5
        let blockW = w + 0.4, blockH = 2 * h + gap + desk
        let (u, o) = Self.fit(blockW, blockH, in: area)
        unit = u
        cabinet = CGRect(x: area.minX, y: o.y + (2 * h + gap) * u, width: area.width, height: desk * u)
        panel = CGRect(x: o.x + 0.2 * u, y: o.y, width: w * u, height: (2 * h + gap) * u)
        for i in 0..<2 {
            let housing = CGRect(x: o.x + 0.2 * u, y: o.y + CGFloat(i) * (h + gap) * u, width: w * u, height: h * u)
            let window = CGRect(x: housing.minX + side * u, y: housing.minY + top * u, width: ww * u, height: u)
            let s0 = window.minX + Self.dinLeft * window.width, s1 = window.minX + Self.dinRight * window.width
            var m = MeterInstrument(kind: .band, window: window, housing: housing, pivot: .zero, needle: (s0, s1), channel: i)
            m.band = CGRect(x: s0, y: window.minY + 0.405 * u, width: s1 - s0, height: 0.19 * u)
            instruments.append(m)
        }
    }

    // MARK: Scales

    /// The DIN light band's scale: where -50 and +5 dB sit across the window.
    static let dinLeft: CGFloat = 0.075, dinRight: CGFloat = 0.93
    /// The DIN scale (DIN 45406, IEC 60268-10 Type I), measured from photographs of two instruments (Siemens & Halske,
    /// 1950; NTP 177-300): dB to the fraction of the way from -50 to +5. It opens out toward the top.
    static let dinKnots: [(db: Double, x: Double)] = [(-60, -0.04), (-50, 0), (-40, 0.052), (-30, 0.166), (-20, 0.345),
                                                      (-10, 0.556), (-5, 0.68), (0, 0.818), (5, 1), (6, 1.035)]

    /// A DIN reading (dB against the permitted maximum, 0) to the fraction of the scale.
    static func dinFraction(_ db: Double) -> Double {
        let k = dinKnots
        if db <= k[0].db { return k[0].x }
        for i in 1..<k.count where db <= k[i].db {
            let t = (db - k[i - 1].db) / (k[i].db - k[i - 1].db)
            return k[i - 1].x + t * (k[i].x - k[i - 1].x)
        }
        return k[k.count - 1].x
    }

    /// Degrees to radians.
    static func deg(_ d: Double) -> Double { d * .pi / 180 }

    /// The Sifam scale: seven marks 13.17° apart from -39.5°, the needle resting at -47° and stopping at +46°.
    static func sifamMarkAngle(_ m: Double) -> Double { deg(-39.5 + (m - 1) * 79.0 / 6) }
    static let sifamRest = deg(-47), sifamStop = deg(46)

    /// A Type II reading (dB against the reference, which reads mark 4 or TEST) to the needle's angle.
    static func sifamAngle(ppm db: Double) -> Double {
        let mark = 4 + db / 4
        if mark >= 1 { return min(sifamStop, sifamMarkAngle(mark)) }
        // Below mark 1 it falls to its rest over another 12 dB.
        return sifamRest + (sifamMarkAngle(1) - sifamRest) * max(0, 1 + (db + 12) / 12)
    }

    /// The Nordic scale: -36 to +12 dB evenly across ±40° (6 dB a mark), so TEST (the reference) sits at +20°.
    static func nordicAngle(_ db: Double) -> Double {
        if db >= -36 { return min(sifamStop, deg(-40 + (db + 36) / 48 * 80)) }
        // Below -36 it falls to its rest over another 6 dB.
        return sifamRest + (deg(-40) - sifamRest) * max(0, 1 + (db + 36) / 6)
    }

    /// The VU designs: the needle's travel (0…1.08, +3 VU at 1; for the cassette deck +6 VU at 1) to its angle.
    static func swing(_ design: MeterDesign) -> Double {
        switch design {
        case .broadcast: deg(45)
        case .console: deg(41)
        case .tape: deg(42)
        case .cassette: deg(41)
        default: deg(42)
        }
    }

    static func vuAngle(_ design: MeterDesign, travel: Double) -> Double { -swing(design) + 2 * swing(design) * travel }

    /// The balance meter: ±6 dB across ±36°.
    static let balanceSwing = deg(36), balanceRange = 6.0
}

// MARK: Printing

/// Draws the designs' printing into the four channels of a mask: red is the ink (dark on a light face, light on a
/// dark one), green the red ink, blue a second colour (the cassette deck's blue scale, the console's labels, the
/// twin meters' green and yellow), alpha the panel's legends.
enum VisualizerMeterPrinting {
    enum Layer: CaseIterable { case ink, red, second, legend }

    static func render(width w: Int, height h: Int, scale: CGFloat, plan: MeterPlan) -> [UInt8]? {
        var layers: [CGContext] = []
        for layer in Layer.allCases {
            guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            c.translateBy(x: 0, y: CGFloat(h))
            c.scaleBy(x: scale, y: -scale)
            c.setLineCap(.butt)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
            var pen = Pen(context: c, layer: layer, unit: plan.unit)
            draw(plan, with: &pen)
            NSGraphicsContext.restoreGraphicsState()
            layers.append(c)
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for (k, c) in layers.enumerated() {
            guard let data = c.data else { return nil }
            let p = data.bindMemory(to: UInt8.self, capacity: w * h)
            for i in 0..<(w * h) { bytes[4 * i + k] = p[i] }
        }
        return bytes
    }

    /// Draws on one layer only: everything asked of another layer is skipped.
    struct Pen {
        let context: CGContext
        let layer: Layer
        let unit: CGFloat

        func on(_ l: Layer, _ strength: CGFloat = 1) -> Bool {
            guard l == layer else { return false }
            context.setFillColor(gray: strength, alpha: 1)
            context.setStrokeColor(gray: strength, alpha: 1)
            return true
        }

        static func point(_ pivot: CGPoint, _ angle: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: pivot.x + r * CGFloat(sin(angle)), y: pivot.y - r * CGFloat(cos(angle)))
        }

        /// A mark along the radius at `angle` (radians from upright, clockwise), from `r0` to `r1` points.
        func tick(_ l: Layer, _ pivot: CGPoint, _ angle: Double, _ r0: CGFloat, _ r1: CGFloat, width: CGFloat, strength: CGFloat = 1) {
            guard on(l, strength) else { return }
            context.setLineWidth(width)
            context.move(to: Self.point(pivot, angle, r0))
            context.addLine(to: Self.point(pivot, angle, r1))
            context.strokePath()
        }

        /// An arc of radius `r` from `a0` to `a1`.
        func arc(_ l: Layer, _ pivot: CGPoint, _ a0: Double, _ a1: Double, _ r: CGFloat, width: CGFloat, strength: CGFloat = 1) {
            guard on(l, strength) else { return }
            context.setLineWidth(width)
            let n = max(8, Int(abs(a1 - a0) * 120))
            for i in 0...n {
                let p = Self.point(pivot, a0 + (a1 - a0) * Double(i) / Double(n), r)
                if i == 0 { context.move(to: p) } else { context.addLine(to: p) }
            }
            context.strokePath()
        }

        /// A band between radii `r0` and `r1` from `a0` to `a1`; its outer edge can widen to `r1End` (the VU's red zone).
        func band(_ l: Layer, _ pivot: CGPoint, _ a0: Double, _ a1: Double, _ r0: CGFloat, _ r1: CGFloat, r1End: CGFloat? = nil) {
            guard on(l) else { return }
            let n = max(8, Int(abs(a1 - a0) * 120))
            let outerEnd = r1End ?? r1
            for i in 0...n {
                let t = Double(i) / Double(n)
                let p = Self.point(pivot, a0 + (a1 - a0) * t, r1 + (outerEnd - r1) * CGFloat(t))
                if i == 0 { context.move(to: p) } else { context.addLine(to: p) }
            }
            for i in stride(from: n, through: 0, by: -1) {
                context.addLine(to: Self.point(pivot, a0 + (a1 - a0) * Double(i) / Double(n), r0))
            }
            context.closePath()
            context.fillPath()
        }

        /// Text centred on `p`.
        func text(_ l: Layer, _ s: String, at p: CGPoint, font: NSFont, strength: CGFloat = 1, kern: CGFloat = 0) {
            guard on(l, strength) else { return }
            let t = NSAttributedString(string: s, attributes: [.font: font, .kern: kern,
                                                               .foregroundColor: NSColor(white: strength, alpha: 1)])
            let b = t.size()
            t.draw(at: CGPoint(x: p.x - b.width / 2, y: p.y - b.height / 2))
        }

        func text(_ l: Layer, _ s: String, pivot: CGPoint, angle: Double, radius: CGFloat, font: NSFont, strength: CGFloat = 1) {
            text(l, s, at: Self.point(pivot, angle, radius), font: font, strength: strength)
        }

        func rect(_ l: Layer, _ r: CGRect, radius: CGFloat = 0, strength: CGFloat = 1) {
            guard on(l, strength) else { return }
            context.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }

        func circle(_ l: Layer, _ c: CGPoint, _ r: CGFloat, strength: CGFloat = 1) {
            guard on(l, strength) else { return }
            context.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }

        /// Vespertine's crescent, `r` points across its circle: a disc with a second one taken out of it.
        func crescent(_ l: Layer, _ c: CGPoint, _ r: CGFloat, strength: CGFloat = 1) {
            guard on(l, strength) else { return }
            context.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.setFillColor(gray: 0, alpha: 1)
            context.fillEllipse(in: CGRect(x: c.x - r * 0.55, y: c.y - r * 1.15, width: 2 * r, height: 2 * r))
        }
    }

    static func font(_ name: String, _ size: CGFloat, fallback weight: NSFont.Weight = .medium) -> NSFont {
        NSFont(name: name, size: size) ?? NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func draw(_ plan: MeterPlan, with pen: inout Pen) {
        switch plan.design {
        case .bbc, .bbcStereo, .ebu, .nordic: drawSifam(plan, pen)
        case .broadcast: drawBroadcast(plan, pen)
        case .console: drawConsole(plan, pen)
        case .tape: drawTape(plan, pen)
        case .cassette: drawCassette(plan, pen)
        case .din: drawDIN(plan, pen)
        }
    }

    // MARK: BBC, EBU, Nordic (Sifam-type)

    private static func drawSifam(_ plan: MeterPlan, _ pen: Pen) {
        let u = plan.unit
        for (i, m) in plan.instruments.enumerated() {
            let p = m.pivot
            let bar = 0.021 * u
            let numerals = font("Helvetica", 0.092 * u)
            switch plan.design {
            case .nordic:
                for k in 0...8 {
                    let db = Double(k * 6 - 36)
                    let a = MeterPlan.nordicAngle(db)
                    pen.tick(.ink, p, a, 0.96 * u, 1.085 * u, width: bar)
                    let label = db == 0 ? "TEST" : (db > 0 ? "+\(Int(db))" : "\(Int(db))".replacingOccurrences(of: "-", with: "−"))
                    pen.text(.ink, label, pivot: p, angle: a, radius: 1.155 * u, font: font("Helvetica", (db == 0 ? 0.062 : 0.074) * u))
                    if k < 8 { pen.tick(.ink, p, MeterPlan.nordicAngle(db + 3), 0.985 * u, 1.055 * u, width: bar * 0.8) }
                }
            case .ebu:
                let labels = ["−12", "−8", "−4", "TEST", "+4", "+8", "+12"]
                for mark in 1...7 {
                    let a = MeterPlan.sifamMarkAngle(Double(mark))
                    pen.tick(.ink, p, a, 0.96 * u, 1.085 * u, width: bar)
                    pen.text(.ink, labels[mark - 1], pivot: p, angle: a, radius: 1.155 * u,
                             font: font("Helvetica", (mark == 4 ? 0.062 : 0.078) * u))
                    if mark < 7 { pen.tick(.ink, p, MeterPlan.sifamMarkAngle(Double(mark) + 0.5), 0.985 * u, 1.055 * u, width: bar * 0.8) }
                }
            default:
                for mark in 1...7 {
                    let a = MeterPlan.sifamMarkAngle(Double(mark))
                    pen.tick(.ink, p, a, 0.96 * u, 1.085 * u, width: bar)
                    pen.text(.ink, "\(mark)", pivot: p, angle: a, radius: 1.16 * u, font: numerals)
                }
            }
            // The short mark at the stop, past the top of the scale.
            pen.tick(.ink, p, MeterPlan.sifamStop, 0.99 * u, 1.06 * u, width: bar)
            // Maker's corner: the crescent and the type, small and grey, as the real one carries its maker's mark.
            let w = m.window
            pen.crescent(.ink, CGPoint(x: w.minX + 0.12 * u, y: w.maxY - 0.13 * u), 0.035 * u, strength: 0.75)
            let type = plan.design.isPPM && plan.design == .nordic ? "TYPE I" : (plan.design == .ebu ? "TYPE IIb" : "TYPE IIa")
            pen.text(.ink, type, at: CGPoint(x: w.minX + 0.27 * u, y: w.maxY - 0.13 * u), font: font("Helvetica-Bold", 0.034 * u), strength: 0.75)
            if m.kind == .needle || m.kind == .twinAB || m.kind == .twinMS {
                pen.text(.ink, "PPM", at: CGPoint(x: w.maxX - 0.17 * u, y: w.maxY - 0.13 * u), font: font("Helvetica-Bold", 0.036 * u), strength: 0.75)
            }

            // The panel's legend under each meter, with the colour of its needle where it has two.
            let y = m.housing.maxY + 0.17 * u
            let legend = font("Helvetica-Bold", 0.075 * u)
            let swatch = CGSize(width: 0.13 * u, height: 0.075 * u)
            func key(_ layer: Layer, _ text: String, at x: CGFloat, strength: CGFloat = 1) {
                pen.rect(layer, CGRect(x: x - swatch.width / 2, y: y - swatch.height / 2, width: swatch.width, height: swatch.height),
                         radius: 0.012 * u, strength: strength)
                pen.text(.legend, text, at: CGPoint(x: x + swatch.width / 2 + 0.03 * u + text.size(legend) / 2, y: y), font: legend, kern: 0.006 * u)
            }
            switch m.kind {
            case .twinAB:
                key(.red, "A  LEFT", at: m.housing.midX - 0.62 * u)
                key(.second, "B  RIGHT", at: m.housing.midX + 0.12 * u)
            case .twinMS:
                key(.legend, "M  A+B", at: m.housing.midX - 0.58 * u)
                key(.second, "S  A−B", at: m.housing.midX + 0.16 * u)
            default:
                let text = i == 0 ? "LEFT" : "RIGHT"
                key(i == 0 ? .red : .second, text, at: m.housing.midX - (text.size(legend) + 0.17 * u) / 2 + 0.065 * u)
            }
        }
    }

    // MARK: Broadcast (the 1940 Type A card)

    /// The VU marks with numbers and the minor ones, as the 1940 card has them.
    static let vuNumbered: [Double] = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
    static let vuMinor: [Double] = [-6, -4]

    private static func drawBroadcast(_ plan: MeterPlan, _ pen: Pen) {
        let u = plan.unit, d = plan.design
        let angle = { (db: Double) in MeterPlan.vuAngle(d, travel: VisualizerMeters.vuTravel(decibels: db)) }
        for m in plan.instruments where m.kind == .needle {
            let p = m.pivot
            let r: CGFloat = 0.80 * u, line = 0.009 * u
            let numerals = font("Futura-Medium", 0.082 * u)
            pen.arc(.ink, p, angle(-20), angle(0), r, width: line)
            for db in vuNumbered {
                let a = angle(db), layer: Layer = db > 0 ? .red : .ink
                pen.tick(layer, p, a, r - line / 2, r + 0.075 * u, width: 0.012 * u)
                pen.text(layer, db == 0 ? "0" : "\(Int(abs(db)))", pivot: p, angle: a, radius: r + 0.135 * u, font: numerals)
            }
            for db in vuMinor { pen.tick(.ink, p, angle(db), r - line / 2, r + 0.045 * u, width: 0.009 * u) }
            for db in [0.5, 1.5, 2.5, -0.5] { pen.tick(db > 0 ? .red : .ink, p, angle(db), r, r + 0.04 * u, width: 0.008 * u) }
            // The red warning band past 100 per cent, on the arc.
            pen.band(.red, p, angle(0), angle(3), r - line / 2, r + 0.03 * u, r1End: r + 0.045 * u)
            pen.text(.ink, "−", pivot: p, angle: angle(-20) - MeterPlan.deg(5), radius: r + 0.06 * u, font: font("Futura-Medium", 0.1 * u))
            pen.text(.red, "+", pivot: p, angle: angle(3) + MeterPlan.deg(5), radius: r + 0.06 * u, font: font("Futura-Medium", 0.1 * u))
            // Type A: the per-cent scale under the arc, small and inconspicuous.
            let rp: CGFloat = 0.69 * u
            pen.arc(.ink, p, angle(-40), angle(0), rp, width: line * 0.7, strength: 0.85)
            for pct in stride(from: 0.0, through: 100, by: 10) {
                let a = MeterPlan.vuAngle(d, travel: VisualizerMeters.zeroVU * pct / 100)
                let major = Int(pct) % 20 == 0
                pen.tick(.ink, p, a, rp, rp - (major ? 0.04 : 0.025) * u, width: line * 0.8, strength: 0.85)
                if major { pen.text(.ink, "\(Int(pct))", pivot: p, angle: a, radius: rp - 0.085 * u, font: font("Futura-Medium", 0.042 * u), strength: 0.85) }
            }
            pen.text(.ink, "VU", at: CGPoint(x: m.window.midX, y: m.window.minY + 0.715 * u), font: font("Futura-Bold", 0.13 * u))
            pen.crescent(.ink, CGPoint(x: m.window.minX + 0.11 * u, y: m.window.maxY - 0.1 * u), 0.03 * u, strength: 0.7)
            pen.text(.ink, "vespertine", at: CGPoint(x: m.window.minX + 0.29 * u, y: m.window.maxY - 0.1 * u),
                     font: font("Futura-Medium", 0.035 * u), strength: 0.7)
            // The panel's engraved legend.
            pen.text(.legend, m.channel == 0 ? "LEFT  CHANNEL" : "RIGHT  CHANNEL",
                     at: CGPoint(x: m.housing.midX, y: m.housing.maxY + 0.16 * u), font: font("Futura-Medium", 0.07 * u), kern: 0.01 * u)
        }
        if let b = plan.instruments.first(where: { $0.kind == .balance }) { drawBalance(b, plan: plan, pen, faceFont: "Futura-Medium") }
    }

    /// The centre-zero balance meter: which side is louder, ±6 dB.
    private static func drawBalance(_ m: MeterInstrument, plan: MeterPlan, _ pen: Pen, faceFont: String) {
        let u = plan.unit, p = m.pivot
        let r: CGFloat = 0.42 * u
        let s = MeterPlan.balanceSwing
        pen.arc(.ink, p, -s, s, r, width: 0.007 * u)
        for k in -3...3 {
            let a = s * Double(k) / 3
            pen.tick(.ink, p, a, r, r + (k == 0 ? 0.055 : 0.04) * u, width: (k == 0 ? 0.011 : 0.008) * u)
            pen.text(.ink, "\(abs(k) * 2)", pivot: p, angle: a, radius: r + 0.09 * u, font: font(faceFont, 0.048 * u))
        }
        pen.text(.red, "L", pivot: p, angle: -s - MeterPlan.deg(9), radius: r + 0.02 * u, font: font(faceFont, 0.06 * u))
        pen.text(.second, "R", pivot: p, angle: s + MeterPlan.deg(9), radius: r + 0.02 * u, font: font(faceFont, 0.06 * u))
        pen.text(.ink, "dB", at: CGPoint(x: m.window.midX, y: m.window.minY + 0.31 * u), font: font(faceFont, 0.04 * u))
        pen.text(.legend, "BALANCE", at: CGPoint(x: m.housing.midX, y: m.housing.maxY + 0.12 * u),
                 font: font(faceFont == "Futura-Medium" ? faceFont : "Helvetica-Bold", 0.055 * u), kern: 0.008 * u)
    }

    // MARK: Console

    private static func drawConsole(_ plan: MeterPlan, _ pen: Pen) {
        let u = plan.unit, d = plan.design
        let angle = { (db: Double) in MeterPlan.vuAngle(d, travel: VisualizerMeters.vuTravel(decibels: db)) }
        for m in plan.instruments where m.kind == .needle {
            let p = m.pivot
            let r: CGFloat = 1.0 * u, line = 0.008 * u
            let numerals = font("Helvetica", 0.075 * u)
            pen.arc(.ink, p, angle(-20), angle(0), r, width: line)
            pen.band(.red, p, angle(0), angle(3), r - line / 2, r + 0.022 * u)
            for db in vuNumbered {
                let layer: Layer = db > 0 ? .red : .ink
                pen.tick(layer, p, angle(db), r, r + 0.07 * u, width: 0.01 * u)
                pen.text(layer, db == 0 ? "0" : "\(Int(abs(db)))", pivot: p, angle: angle(db), radius: r + 0.125 * u, font: numerals)
            }
            for db in [-15.0, -6, -4, -0.5, 0.5, 1.5, 2.5] {
                pen.tick(db > 0 ? .red : .ink, p, angle(db), r, r + 0.04 * u, width: 0.007 * u)
            }
            pen.text(.ink, "−", pivot: p, angle: angle(-20) - MeterPlan.deg(4), radius: r + 0.02 * u, font: font("Helvetica", 0.09 * u))
            pen.text(.red, "+", pivot: p, angle: angle(3) + MeterPlan.deg(4), radius: r + 0.02 * u, font: font("Helvetica", 0.09 * u))
            pen.text(.ink, "VU", at: CGPoint(x: m.window.midX, y: m.window.minY + 0.66 * u), font: font("Helvetica", 0.1 * u))
            pen.crescent(.ink, CGPoint(x: m.window.minX + 0.11 * u, y: m.window.minY + 0.12 * u), 0.04 * u, strength: 0.8)
            // The bridge's legend: the channel, large, the name under it in blue, and the peak light's.
            let label = CGPoint(x: m.housing.midX, y: m.housing.maxY + 0.2 * u)
            pen.text(.legend, m.channel == 0 ? "L" : "R", at: CGPoint(x: label.x - 0.38 * u, y: label.y + 0.06 * u), font: font("Helvetica-Bold", 0.17 * u))
            pen.text(.second, m.channel == 0 ? "LEFT" : "RIGHT", at: CGPoint(x: label.x - 0.04 * u, y: label.y + 0.08 * u),
                     font: font("Helvetica-Bold", 0.085 * u))
            if let led = m.led {
                pen.text(.legend, "PEAK", at: CGPoint(x: led.x + 0.17 * u, y: led.y), font: font("Helvetica", 0.05 * u), kern: 0.004 * u)
            }
        }
        if let b = plan.instruments.first(where: { $0.kind == .balance }) { drawBalance(b, plan: plan, pen, faceFont: "Helvetica") }
    }

    // MARK: Tape recorder

    private static func drawTape(_ plan: MeterPlan, _ pen: Pen) {
        let u = plan.unit, d = plan.design
        let angle = { (db: Double) in MeterPlan.vuAngle(d, travel: VisualizerMeters.vuTravel(decibels: db)) }
        for m in plan.instruments {
            let p = m.pivot
            let r: CGFloat = 0.8 * u, line = 0.008 * u
            let numerals = font("Helvetica", 0.072 * u)
            pen.arc(.ink, p, angle(-20), angle(0), r, width: line)
            pen.band(.red, p, angle(0), angle(3), r - line / 2, r + 0.028 * u)
            for db in [-20.0, -10, -7, -5, -3, -1, 0, 1, 2, 3] {
                let layer: Layer = db > 0 ? .red : .ink
                pen.tick(layer, p, angle(db), r, r + 0.065 * u, width: 0.011 * u)
                pen.text(layer, db == 0 ? "0" : "\(Int(abs(db)))", pivot: p, angle: angle(db), radius: r + 0.12 * u, font: numerals)
            }
            for db in [-15.0, -6, -4, -2, -0.5] { pen.tick(.ink, p, angle(db), r, r + 0.035 * u, width: 0.007 * u) }
            // Per cent under the arc.
            for pct in [0.0, 50, 100] {
                let a = MeterPlan.vuAngle(d, travel: VisualizerMeters.zeroVU * pct / 100)
                pen.tick(.ink, p, a, r, r - 0.04 * u, width: 0.007 * u, strength: 0.8)
                pen.text(.ink, "\(Int(pct))", pivot: p, angle: a, radius: r - 0.085 * u, font: font("Helvetica", 0.042 * u), strength: 0.8)
            }
            pen.text(.ink, "%", pivot: p, angle: angle(1.5), radius: r - 0.085 * u, font: font("Helvetica", 0.042 * u), strength: 0.8)
            pen.text(.ink, "VU", at: CGPoint(x: m.window.midX, y: m.window.minY + 0.62 * u), font: font("Helvetica-Bold", 0.11 * u))
            // The legend over each meter, engraved white in the panel.
            let x = m.window.midX, y = m.housing.minY - 0.16 * u
            pen.text(.legend, m.channel == 0 ? "CHANNEL  I" : "CHANNEL  II", at: CGPoint(x: x, y: y), font: font("Helvetica-Bold", 0.062 * u),
                     kern: 0.006 * u)
        }
        // The aluminium strip: the name, in blue, and what it is, engraved.
        let strip = CGRect(x: plan.panel.minX, y: plan.panel.minY, width: plan.panel.width, height: 0.42 * u)
        pen.crescent(.second, CGPoint(x: strip.maxX - 1.12 * u, y: strip.midY - 0.02 * u), 0.06 * u)
        pen.text(.second, "vespertine", at: CGPoint(x: strip.maxX - 0.62 * u, y: strip.midY - 0.02 * u), font: font("Futura-Medium", 0.13 * u))
        pen.text(.ink, "STEREO  ·  VU", at: CGPoint(x: strip.minX + 0.75 * u, y: strip.midY), font: font("Helvetica", 0.05 * u),
                 strength: 0.85, kern: 0.01 * u)
    }

    // MARK: Cassette deck

    private static func drawCassette(_ plan: MeterPlan, _ pen: Pen) {
        let u = plan.unit, d = plan.design
        // The +6 scale: 0 VU at half the travel.
        let angle = { (db: Double) in MeterPlan.vuAngle(d, travel: VisualizerMeters.wideZeroVU * pow(10, db / 20)) }
        for m in plan.instruments {
            let p = m.pivot
            let r: CGFloat = 0.86 * u, line = 0.011 * u
            let numerals = font("Helvetica", 0.072 * u)
            pen.arc(.second, p, angle(-20), angle(0) - 0.004, r, width: line)
            pen.arc(.red, p, angle(0) + 0.004, angle(6), r, width: line)
            for db in [-20.0, -10, -7, -5, -3, -1] {
                pen.tick(.second, p, angle(db), r, r + 0.07 * u, width: 0.011 * u)
                pen.text(.second, "\(Int(abs(db)))", pivot: p, angle: angle(db), radius: r + 0.125 * u, font: numerals)
            }
            for db in [-15.0, -6, -4, -2] { pen.tick(.second, p, angle(db), r, r + 0.045 * u, width: 0.008 * u) }
            for db in [0.0, 1, 2, 3, 4, 5, 6] {
                pen.tick(.red, p, angle(db), r, r + (db == 3 || db == 5 ? 0.045 : 0.07) * u, width: (db == 3 || db == 5 ? 0.008 : 0.011) * u)
                if db != 3 && db != 5 {
                    pen.text(.red, db == 6 ? "+6" : "\(Int(db))", pivot: p, angle: angle(db), radius: r + 0.125 * u, font: numerals)
                }
            }
            pen.text(.second, "VU", at: Pen.point(p, angle(-20), r + 0.27 * u), font: font("Helvetica", 0.065 * u))
            pen.text(.red, "VU", at: Pen.point(p, angle(6), r + 0.27 * u), font: font("Helvetica", 0.065 * u))
            // Per cent, under the blue arc.
            for pct in [0.0, 20, 40, 60, 80, 100] {
                let a = angle(20 * log10(max(pct, 0.1) / 100))
                pen.tick(.second, p, a, r - line / 2, r - 0.04 * u, width: 0.008 * u)
                pen.text(.second, "\(Int(pct))", pivot: p, angle: a, radius: r - 0.09 * u, font: font("Helvetica", 0.043 * u))
            }
            pen.text(.second, "dB", at: CGPoint(x: m.window.midX, y: m.window.minY + 0.62 * u), font: font("Helvetica", 0.06 * u))
            pen.crescent(.ink, CGPoint(x: m.window.midX - 0.36 * u, y: m.window.minY + 0.76 * u), 0.04 * u)
            pen.text(.ink, "vespertine", at: CGPoint(x: m.window.midX + 0.03 * u, y: m.window.minY + 0.76 * u),
                     font: font("Futura-Bold", 0.085 * u))
        }
        // The panel's printing: what it is, top right, and the peak lights' legend.
        let pf = font("Helvetica", 0.065 * u)
        pen.text(.ink, "STEREO METERS", at: CGPoint(x: plan.panel.maxX - 0.95 * u, y: plan.panel.minY + 0.22 * u),
                 font: font("Futura-MediumItalic", 0.1 * u), strength: 0.9)
        let leds = plan.instruments.compactMap(\.led)
        if leds.count == 2 {
            let y = leds[0].y - 0.13 * u, mid = (leds[0].x + leds[1].x) / 2
            pen.text(.ink, "PEAK", at: CGPoint(x: mid, y: y - 0.02 * u), font: pf, strength: 0.9)
            pen.text(.ink, "L", at: CGPoint(x: leds[0].x - 0.12 * u, y: leds[0].y), font: pf, strength: 0.9)
            pen.text(.ink, "R", at: CGPoint(x: leds[1].x + 0.12 * u, y: leds[1].y), font: pf, strength: 0.9)
            // The bracket over the two lights.
            if pen.on(.ink, 0.9) {
                pen.context.setLineWidth(0.008 * u)
                pen.context.move(to: CGPoint(x: leds[0].x, y: y + 0.05 * u))
                pen.context.addLine(to: CGPoint(x: leds[0].x, y: y - 0.02 * u))
                pen.context.addLine(to: CGPoint(x: mid - 0.17 * u, y: y - 0.02 * u))
                pen.context.move(to: CGPoint(x: mid + 0.17 * u, y: y - 0.02 * u))
                pen.context.addLine(to: CGPoint(x: leds[1].x, y: y - 0.02 * u))
                pen.context.addLine(to: CGPoint(x: leds[1].x, y: y + 0.05 * u))
                pen.context.strokePath()
            }
        }
    }

    // MARK: DIN light-pointer

    private static func drawDIN(_ plan: MeterPlan, _ pen: Pen) {
        let u = plan.unit
        for m in plan.instruments {
            let band = m.band
            let x = { (db: Double) in band.minX + band.width * CGFloat(MeterPlan.dinFraction(db)) }
            let top = band.minY - 0.12 * u, bottom = band.maxY + 0.12 * u
            let small = font("DINAlternate-Bold", 0.075 * u), tiny = font("DINAlternate-Bold", 0.052 * u)
            // Per cent above the band, dB below; the marks run across the band.
            let percents: [(Double, String)] = [(0.316, ".3"), (0.5, ".5"), (1, "1"), (2, "2"), (3, "3"), (5, "5"), (10, "10"),
                                                (20, "20"), (30, "30"), (50, "50"), (100, "100"), (180, "180")]
            for (pct, label) in percents {
                let db = 20 * log10(pct / 100)
                let red = db > 0.01
                pen.tick(red ? .red : .ink, CGPoint(x: x(db), y: top - 0.0), 0, 0, -(band.height + 0.24 * u), width: 0.01 * u)
                pen.text(red ? .red : .ink, label, at: CGPoint(x: x(db), y: top - 0.08 * u), font: small)
            }
            pen.text(.ink, "0", at: CGPoint(x: band.minX - 0.12 * u, y: top - 0.08 * u), font: tiny)
            pen.text(.ink, "%", at: CGPoint(x: m.window.minX + 0.12 * u, y: top + 0.02 * u), font: font("DINAlternate-Bold", 0.1 * u))
            pen.text(.ink, "dB", at: CGPoint(x: m.window.minX + 0.14 * u, y: bottom + 0.1 * u), font: font("DINAlternate-Bold", 0.09 * u))
            for db in [-50.0, -40, -30, -20, -10, 0, 5] {
                let red = db > 0
                pen.tick(red ? .red : .ink, CGPoint(x: x(db), y: band.maxY), 0, 0, -0.1 * u, width: 0.012 * u)
                let label = db > 0 ? "+5" : (db == 0 ? "0" : "−\(Int(-db))")
                pen.text(red ? .red : .ink, label, at: CGPoint(x: x(db), y: bottom + 0.1 * u), font: small)
            }
            for db in [-45.0, -35, -25, -15, -5, -4, -3, -2, -1] {
                pen.tick(.ink, CGPoint(x: x(db), y: band.maxY), 0, 0, -0.06 * u, width: 0.008 * u)
            }
            for db in [1.0, 2, 3, 4] { pen.tick(.red, CGPoint(x: x(db), y: band.maxY), 0, 0, -0.06 * u, width: 0.008 * u) }
            // The alignment mark at -9 (the reference tone reads here), and the red tick at -40 (1 %).
            pen.rect(.red, CGRect(x: x(-9) - 0.045 * u, y: band.minY - 0.035 * u, width: 0.09 * u, height: 0.03 * u))
            pen.rect(.red, CGRect(x: x(-9) - 0.045 * u, y: band.maxY + 0.005 * u, width: 0.09 * u, height: 0.03 * u))
            pen.text(.red, "−9", at: CGPoint(x: x(-9) + 0.01 * u, y: band.maxY + 0.075 * u), font: tiny)
            pen.tick(.red, CGPoint(x: x(-40), y: band.maxY + 0.1 * u), 0, 0, band.height + 0.3 * u, width: 0.012 * u)
            // The red zone, printed on the band's track above 0 dB.
            pen.rect(.red, CGRect(x: x(0), y: band.minY, width: x(5.6) - x(0), height: band.height), radius: 0.02 * u)
            // Maker's line, bottom right, and the channel on the case.
            pen.crescent(.ink, CGPoint(x: m.window.maxX - 0.95 * u, y: m.window.maxY - 0.09 * u), 0.026 * u, strength: 0.6)
            pen.text(.ink, "vespertine  ·  DIN 45406", at: CGPoint(x: m.window.maxX - 0.52 * u, y: m.window.maxY - 0.09 * u),
                     font: font("DINAlternate-Bold", 0.04 * u), strength: 0.6)
            pen.text(.legend, m.channel == 0 ? "L" : "R", at: CGPoint(x: m.housing.minX + 0.16 * u, y: m.window.midY),
                     font: font("DINAlternate-Bold", 0.16 * u))
        }
    }
}

private extension String {
    func size(_ font: NSFont) -> CGFloat { (self as NSString).size(withAttributes: [.font: font]).width }
}

/// The balance meter between two VU meters: a centre-zero needle on a VU movement of its own (damping 0.81,
/// 13.42 rad/s, as `VisualizerMeters`), driven by how many dB the left VU reads over the right, ±6 dB across the scale.
/// It reads the two VU needles and never changes them, so they keep the standard's ballistics; with both under about
/// -20 VU (nothing much to compare) it settles at the centre.
struct VisualizerBalanceNeedle: Sendable, Equatable {
    /// -1 (left louder by 6 dB) … +1 (right louder by 6 dB), a little past either end at the stops.
    private(set) var position = 0.0
    private var speed = 0.0

    var angle: Double { MeterPlan.balanceSwing * position }

    /// Where the needle settles for a pair of VU readings (travel, as `VisualizerMeters.vu`).
    static func target(vu: SIMD2<Double>) -> Double {
        let floor = VisualizerMeters.vuTravel(decibels: -20)
        let l = max(vu.x, 1e-6), r = max(vu.y, 1e-6)
        let difference = 20 * log10(r / l)   // right over left, dB
        let loudest = max(vu.x, vu.y)
        let weight = min(1, max(0, (loudest - floor / 2) / (floor / 2)))   // 0 at -26 VU, 1 at -20 VU and up
        return max(-1.12, min(1.12, difference / MeterPlan.balanceRange * weight))
    }

    mutating func advance(vu: SIMD2<Double>, dt: Double) {
        let target = Self.target(vu: vu)
        let w = VisualizerMeters.vuNaturalFrequency, z = VisualizerMeters.vuDamping
        // Millisecond steps, so it moves the same at any frame rate.
        let steps = max(1, Int((dt * 1000).rounded())), h = dt / Double(steps)
        for _ in 0..<steps {
            speed += (w * w * (target - position) - 2 * z * w * speed) * h
            position += speed * h
            if abs(position) > 1.12 { position = position > 0 ? 1.12 : -1.12; speed = 0 }
        }
    }
}

extension VisualizerSettings {
    /// The ballistics the chosen meter design needs besides the VU and Type IIa pair (for the analyzer).
    public var meterExtras: VisualizerMeters.Extras {
        guard style == .meters, let design = MeterDesign(self) else { return [] }
        return design.extras
    }
}
