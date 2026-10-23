import SwiftUI

@main
struct PDFReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var tabs = TabsModel.shared

    init() {
        // View ▸ Full Screen Mode replaces the "Enter Full Screen" item AppKit adds on its own
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
    }

    var body: some Scene {
        Window("PDF Gremza", id: "main") {
            ContentView()
                .environmentObject(tabs)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                UpdateMenuItems(updater: UpdateChecker.shared)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { tabs.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { tabs.closeSelected() }
                    .keyboardShortcut("w")
            }
            DocumentCommands(tabs: tabs)
            CommandGroup(before: .windowArrangement) {
                Button("Next Tab") { tabs.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { tabs.selectPrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tabs are drawn by the app itself, not by AppKit
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { UpdateChecker.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { UpdateChecker.shared.relaunchIfNeeded() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { TabsModel.shared.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { TabsModel.shared.confirmDiscardChanges() } ? .terminateNow : .terminateCancel
    }
}
