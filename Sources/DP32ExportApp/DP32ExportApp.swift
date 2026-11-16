import SwiftUI
import DP32Core

@main
struct DP32ExportApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DP-32 Export") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 440)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.openFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
