import SwiftUI
import MetalKit

/// Hosts the Metal stage in SwiftUI.
struct MetalCanvas: NSViewRepresentable {
    let model: AppModel

    final class Coordinator { var canvas: ThemeCanvas? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return NSHostingView(rootView: Text("This Mac's graphics can't draw the theme.").foregroundStyle(.secondary))
        }
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.043, green: 0.035, blue: 0.027, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        // The canvas picks the drawable size per quality; the screen scales it up smoothly.
        view.autoResizeDrawable = false
        view.layer?.magnificationFilter = .linear
        let canvas = ThemeCanvas(view: view, model: model)
        view.delegate = canvas
        context.coordinator.canvas = canvas
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
