//
// Vespertine: Bluetooth outputs, whose rate and codec belong to macOS and the headset.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

extension OutputDevice {
    /// The rates a plan may choose from. Stub: not yet limited to the link's own rate.
    public var planningCapabilities: DeviceCapabilities { capabilities }
}

extension SignalPath {
    public var isBluetoothCallMode: Bool { false }
    public var bluetoothNote: String? { nil }
}
