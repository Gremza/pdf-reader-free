import SwiftUI

@main
struct PDFReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var tabs = TabsModel.shared

    var body: some Scene {
        Window("PDF Reader", id: "main") {
            ContentView()
                .environmentObject(tabs)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Hap…") { tabs.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Mbyll tab-in") { tabs.closeSelected() }
                    .keyboardShortcut("w")
            }
            DocumentCommands(tabs: tabs)
            CommandGroup(before: .windowArrangement) {
                Button("Tab-i tjetër") { tabs.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Tab-i i mëparshëm") { tabs.selectPrevious() }
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
