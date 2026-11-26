import SwiftUI

@main
struct RefractApp: App {
    @NSApplicationDelegateAdaptor(RefractLifecycle.self) private var lifecycle
    @StateObject private var models: ModelStore
    @StateObject private var studio: StudioStore
    @StateObject private var fileSelection = StudioFileSelection()
    @StateObject private var modelNavigation = ModelManagerNavigation()

    init() {
        let catalog = ModelStore()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Refract")
        _models = StateObject(wrappedValue: catalog)
        let store = StudioStore(models: catalog, worker: WorkerClient(), directory: support)
        _studio = StateObject(wrappedValue: store)
        lifecycle.studio = store
    }

    var body: some Scene {
        WindowGroup("Refract", id: "studio", for: String.self) { _ in
            StudioView(fileSelection: fileSelection)
                .onOpenURL { fileSelection.openForEnhancement([$0]) }
                .handlesExternalEvents(preferring: ["file:"], allowing: ["file:"])
                .environmentObject(studio)
                .environmentObject(models)
                .environmentObject(modelNavigation)
        } defaultValue: { "main" }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(UnifiedCompactWindowToolbarStyle(showsTitle: false))
        .handlesExternalEvents(matching: ["file:"])
        .commands { OpenImagesCommands(fileSelection: fileSelection) }
        Window("Models", id: "models") {
            ModelManagerView()
                .environmentObject(studio)
                .environmentObject(models)
                .environmentObject(modelNavigation)
        }
        .defaultSize(width: 940, height: 580)
        Settings {
            StudioSettingsView()
                .environmentObject(studio)
                .environmentObject(models)
        }
    }
}

private struct OpenImagesCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var fileSelection: StudioFileSelection

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Images or Folder…") {
                let urls = StudioPanels.choose("Open images or folders", directories: true, multiple: true, types: [.image])
                guard !urls.isEmpty else { return }
                fileSelection.openForEnhancement(urls)
                openWindow(id: "studio", value: "main")
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}

@MainActor private final class RefractLifecycle: NSObject, NSApplicationDelegate {
    weak var studio: StudioStore?

    func applicationWillTerminate(_ notification: Notification) {
        studio?.shutdown()
    }
}
