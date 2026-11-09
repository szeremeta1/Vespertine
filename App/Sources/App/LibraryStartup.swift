import AppKit
import Observation
import SwiftUI
import VespertineLibrary

@Observable @MainActor
final class LibraryStartup {
    var model: AppModel?
    var error: String?
    private var selectedDirectory: URL?
    /// The app's one startup, for what runs outside its windows (Shortcuts' actions).
    private(set) static weak var current: LibraryStartup?

    init() {
        Self.current = self
        // Vespertine is drawn dark only. Without this, whatever SwiftUI's preferredColorScheme doesn't reach (the menu
        // bar window, popovers, alerts, open and save panels, menus, the About panel) followed the Mac's Light Mode and
        // could show dark text on Vespertine's dark backgrounds (issue #68). Set before the migration alerts can appear.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        LegacyMigration.runIfNeeded()
        open()
    }

    func open(at directory: URL? = nil) {
        if let directory { selectedDirectory = directory }
        do {
            let opened = try AppModel(dataDirectory: selectedDirectory)
            model = opened
            error = nil
            if let recovery = opened.library.database.recovery { Self.tellLibraryWasDamaged(recovery) }
        } catch { self.error = error.localizedDescription }
    }

    /// The library file couldn't be read, so a new empty one was started and the old file kept beside it
    /// (`LibraryDatabase.init(url:)`). Said once, so nobody wonders where their library went.
    private static func tellLibraryWasDamaged(_ recovery: LibraryDatabase.Recovery) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Your library file was damaged")
        alert.informativeText = String(localized: "Vespertine started a new, empty library. The damaged file was kept in the same folder as “\(recovery.backup.lastPathComponent)”. Your music files weren’t touched. Add your music folders again to rebuild the library.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([recovery.backup]) }
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose a folder for a Vespertine library. Your existing library will be preserved.")
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
            (startup.error.map { Text($0) } ?? Text("An unexpected library error occurred.")).textSelection(.enabled)
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
