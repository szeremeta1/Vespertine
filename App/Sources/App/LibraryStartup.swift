import AppKit
import Observation
import SwiftUI

@Observable @MainActor
final class LibraryStartup {
    var model: AppModel?
    var error: String?
    private var selectedDirectory: URL?

    init() {
        LegacyMigration.runIfNeeded()
        open()
    }

    func open(at directory: URL? = nil) {
        if let directory { selectedDirectory = directory }
        do { model = try AppModel(dataDirectory: selectedDirectory); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a folder for a Vespertine library. Your existing library will be preserved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "LibraryDataDirectory")
        open(at: url)
    }
}

struct LibraryRecoveryView: View {
    let startup: LibraryStartup
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Couldn’t open the library").font(.title)
            Text(startup.error ?? "An unexpected library error occurred.").textSelection(.enabled)
            Text("Your existing files have been preserved. Retry after reconnecting the drive or choose another library folder.")
            HStack {
                Button("Retry") { startup.open() }
                Button("Choose Library…") { startup.chooseLibrary() }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }.padding(32).frame(minWidth: 560, minHeight: 240)
    }
}

struct LibraryContent<Content: View>: View {
    let startup: LibraryStartup
    @ViewBuilder let content: (AppModel) -> Content
    var body: some View {
        if let model = startup.model { content(model) }
        else { LibraryRecoveryView(startup: startup) }
    }
}
