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
                .modifier(TestWindowWidth())
                .environment(model)
                .onOpenURL { url in model.open(url) }
                .tint(Color.accentColor)
                .foregroundStyle(Palette.text)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

// Debug-only width harness for UI tests. Production uses the real system window unchanged.
private struct TestWindowWidth: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        let requested = UserDefaults.standard.double(forKey: "VTTestWindowWidth")
        if requested >= 300 {
            GeometryReader { geometry in
                content.frame(width: min(requested, geometry.size.width))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
