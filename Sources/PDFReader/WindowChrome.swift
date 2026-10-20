import SwiftUI
import AppKit

/// Configures the hosting window: hidden title, traffic lights centered in the top bar.
struct WindowChrome: NSViewRepresentable {
    let tabs: TabsModel

    func makeNSView(context: Context) -> NSView { ChromeView(tabs: tabs) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        let tabs: TabsModel
        private var observers: [NSObjectProtocol] = []

        init(tabs: TabsModel) {
            self.tabs = tabs
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }

            MainActor.assumeIsolated { tabs.window = window }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.tabbingMode = .disallowed
            // The close button asks about unsaved changes first
            if let close = window.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(closeWindow)
            }

            let center = NotificationCenter.default
            let relayout: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            ]
            for name in relayout {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.positionTrafficLights() }
                })
            }
            for (name, entered) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.tabs.isFullScreen = entered
                        self?.positionTrafficLights()
                    }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.positionTrafficLights() }
        }

        @objc private func closeWindow() {
            guard MainActor.assumeIsolated({ tabs.confirmDiscardChanges() }) else { return }
            window?.close()
        }

        private func positionTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type), let titlebar = button.superview else { continue }
                // Center vertically in the top bar (titlebar view is not flipped)
                let y = titlebar.bounds.height - TopBar.height / 2 - button.frame.height / 2
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: max(0, y.rounded())))
            }
        }
    }
}

/// Empty bar space drags the window; double-click zooms it.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
