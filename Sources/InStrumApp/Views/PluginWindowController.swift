import AppKit
import AVFoundation

/// Shows an instrument plugin's own window (e.g. Splice INSTRUMENT's preset browser).
@MainActor
final class PluginWindowController: NSObject, NSWindowDelegate {
    static let shared = PluginWindowController()
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(audioUnit: AUAudioUnit, title: String, onClose: @escaping () -> Void) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        self.onClose = onClose
        audioUnit.requestViewController { controller in
            Task { @MainActor in self.present(controller, title: title) }
        }
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
