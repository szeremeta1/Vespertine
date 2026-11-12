//
// Vespertine Remote: controls Vespertine on a Mac over the local network (the Mac's Settings › Remote).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

@main
struct VespertineRemoteApp: App {
    @State private var model = RemoteAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in model.open(url) }
                .tint(Color.accentColor)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
