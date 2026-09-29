// SPDX-License-Identifier: GPL-3.0-or-later
// Musical time and motion curves. Everything in the trailer is a pure function of time, so every
// frame can be rendered on its own and the result is identical on every run.
import Foundation
import CoreGraphics

/// "Starlight Lounge" (iMovie jingle): 65 BPM, measured with a spectral-flux fit over the whole bed.
/// The first downbeat after the one-bar intro is at 3.657 s; the strongest onsets all land on bar lines.
enum Music {
    static let beat = 60.0 / 65.0            // 0.923 s
    static let bar = beat * 4                // 3.692 s
    static let firstDownbeat = 3.657
    static let duration = 36.633
    /// Start of bar `k` (bar 0 is the intro, which begins at 0).
    static func bar(_ k: Int) -> Double { k == 0 ? 0 : firstDownbeat + Double(k - 1) * bar }
    /// Beat `n` counted from the first downbeat (fractional beats allowed).
    static func beat(_ n: Double) -> Double { firstDownbeat + n * beat }
}

/// The trailer's scenes, one per bar except the two-bar opening shot and the end card.
enum Scene: CaseIterable {
    case intro, bitPerfect, dsd, versions, spatial, analysis, library, end

    var range: ClosedRange<Double> {
        switch self {
        case .intro: return 0...Music.bar(1)
        case .bitPerfect: return Music.bar(1)...Music.bar(3)
        case .dsd: return Music.bar(3)...Music.bar(4)
        case .versions: return Music.bar(4)...Music.bar(5)
        case .spatial: return Music.bar(5)...Music.bar(6)
        case .analysis: return Music.bar(6)...Music.bar(7)
        case .library: return Music.bar(7)...Music.bar(8)
        case .end: return Music.bar(8)...Music.duration
        }
    }
}

// MARK: - Curves

@inline(__always) func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

/// Linear progress of `t` between `a` and `b`, clamped to 0…1.
@inline(__always) func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }

func smooth(_ x: Double) -> Double { let x = clamp01(x); return x * x * (3 - 2 * x) }
func easeOutCubic(_ x: Double) -> Double { let x = clamp01(x); return 1 - pow(1 - x, 3) }
func easeInCubic(_ x: Double) -> Double { let x = clamp01(x); return x * x * x }
func easeInOutCubic(_ x: Double) -> Double { let x = clamp01(x); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOutExpo(_ x: Double) -> Double { let x = clamp01(x); return x >= 1 ? 1 : 1 - pow(2, -10 * x) }
func easeInOutQuint(_ x: Double) -> Double { let x = clamp01(x); return x < 0.5 ? 16 * pow(x, 5) : 1 - pow(-2 * x + 2, 5) / 2 }

/// SwiftUI's `spring(response:dampingFraction:)` step response: 0 at `start`, settling at 1.
func spring(_ t: Double, start: Double, response: Double = 0.55, damping: Double = 0.82) -> Double {
    let x = t - start
    guard x > 0 else { return 0 }
    let w = 2 * Double.pi / response
    if damping >= 1 { return 1 - exp(-w * x) * (1 + w * x) }
    let wd = w * sqrt(1 - damping * damping)
    return 1 - exp(-damping * w * x) * (cos(wd * x) + (damping * w / wd) * sin(wd * x))
}

@_disfavoredOverload func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }
func mix(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, p), y: mix(a.y, b.y, p)) }

/// 1 while `t` is inside `a…b`, fading in over `fadeIn` and out over `fadeOut`.
func window(_ t: Double, _ a: Double, _ b: Double, fadeIn: Double = 0.2, fadeOut: Double = 0.2) -> Double {
    smooth(progress(t, a, a + fadeIn)) * (1 - smooth(progress(t, b - fadeOut, b)))
}
