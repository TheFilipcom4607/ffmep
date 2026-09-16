import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Running unbundled (`swift run`) needs a regular activation policy to get a Dock icon and menu bar.
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `--args -FFMEPAppearance light` to screenshot either theme without touching system settings.
        if let name = UserDefaults.standard.string(forKey: "FFMEPAppearance") {
            NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        }
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppState.shared.add(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        guard state.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A conversion is still running"
        alert.informativeText = "Quitting cancels it and removes unfinished files."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Converting")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        state.terminateWhenFinished = true
        state.cancel()
        return .terminateLater
    }
}

@main
struct FfmepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        Window("ffmep", id: "main") {
            MainView()
                .environment(state)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 700)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { state.showAddPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Quick Look") { state.toggleQuickLook() }
                    .keyboardShortcut("y")
                    .disabled(state.selection.isEmpty)
                Button("Show in Finder") { state.reveal(state.selectedJobs) }
                    .keyboardShortcut("r")
                    .disabled(state.selection.isEmpty)
            }
            CommandMenu("Convert") {
                Button("Convert") { state.convert() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.isRunning || state.pendingJobs.isEmpty || state.tools == nil)
                Button("Stop") { state.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!state.isRunning)
                Divider()
                Button("Choose Save Folder…") { state.chooseOutputFolder() }
                    .disabled(state.isRunning)
                Divider()
                Button("Remove Converted Files") { state.clearCompleted() }
                    .disabled(!state.jobs.contains { $0.status.isDone })
                Button("Remove All Files") { state.clearAll() }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(state.jobs.isEmpty)
            }
            CommandGroup(before: .sidebar) {
                Button(state.showInspector ? "Hide Inspector" : "Show Inspector") { state.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}
