import AppKit
import AVFoundation
import CoreAudioKit

/// Shows an instrument plugin's own window (e.g. Splice INSTRUMENT's preset browser).
@MainActor
final class PluginWindowController: NSObject, NSWindowDelegate {
    static let shared = PluginWindowController()
    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private var requesting = false

    func show(audioUnit: AUAudioUnit, title: String, onClose: @escaping () -> Void) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        guard !requesting else { return }
        requesting = true
        self.onClose = onClose
        audioUnit.requestViewController { controller in
            Task { @MainActor in
                self.requesting = false
                self.present(controller, title: title)
            }
        }
    }

    /// True if `window` is the plugin's window.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === self.window }

    /// Closes the plugin window (before its plugin is replaced).
    func close() {
        guard let w = window else { return }
        w.delegate = nil
        onClose?()
        w.close()
        w.contentViewController = nil
        window = nil
        onClose = nil
    }

    private func present(_ controller: NSViewController?, title: String) {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "\(title) has no window to show."
            alert.runModal()
            return
        }
        var size = controller.preferredContentSize
        if size.width < 100 || size.height < 100 { size = controller.view.frame.size }
        if size.width < 100 || size.height < 100 { size = NSSize(width: 900, height: 600) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.contentViewController = controller
        w.setContentSize(size)
        w.title = title
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.onClose?()
            self.window?.contentViewController = nil
            self.window = nil
        }
    }
}
