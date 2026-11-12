//
// Vespertine Remote: the device's tilt, from its motion sensors (gyroscope and accelerometer, fused by Core Motion),
// for Cover Flow's perspective. Runs only while a view asks for it; nothing is recorded or sent anywhere.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import CoreMotion
import Observation
import UIKit

@Observable
final class TiltSensor {
    private(set) var tilt = Tilt.zero
    /// The device has the sensors (the Simulator doesn't).
    let isAvailable: Bool

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var filter = TiltFilter()
    @ObservationIgnored private var lastTime: TimeInterval?
    @ObservationIgnored private var users = 0
    @ObservationIgnored var orientation: TiltFilter.Orientation = .portrait

    init() {
        isAvailable = manager.isDeviceMotionAvailable
        #if DEBUG
        if let fixed = LaunchOptions.tilt { tilt = fixed }
        #endif
    }

    /// Starts reading (each `start` needs its `stop`).
    func start() {
        users += 1
        guard users == 1, isAvailable else { return }
        filter.reset()
        lastTime = nil
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = (motion.gravity.x, motion.gravity.y)
            let time = motion.timestamp
            MainActor.assumeIsolated { self?.received(gravity: gravity, time: time) }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        #if DEBUG
        if LaunchOptions.tilt != nil { return }
        #endif
        tilt = .zero
    }

    private func received(gravity: (Double, Double), time: TimeInterval) {
        let dt = lastTime.map { time - $0 } ?? 0
        lastTime = time
        let next = filter.update(gravityX: gravity.0, gravityY: gravity.1, orientation: orientation, dt: dt)
        // Small changes aren't worth redrawing for.
        if abs(next.x - tilt.x) > 0.004 || abs(next.y - tilt.y) > 0.004 { tilt = next }
    }
}

extension TiltFilter.Orientation {
    init(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: self = .portrait
        }
    }
}
