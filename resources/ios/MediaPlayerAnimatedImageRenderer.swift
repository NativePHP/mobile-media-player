import ImageIO
import SwiftUI
import UIKit

/// Renderer for the `animated_image` element type. Registered by the generated
/// `PluginRendererRegistration` via `SwiftUIRendererRegistry.shared.register`
/// (declared under `components[].ios_renderer` in the plugin manifest).
///
/// SwiftUI has no animated-image view, so this drives an ImageIO frame
/// callback and hands each frame to a plain `UIImageView`'s layer. That keeps
/// it dependency-free and, unlike `video_player`, allocates no playback
/// session — so a list can hold many of these at once.
///
/// Layout (width / height / aspect) is applied by core's `NodeView` modifier
/// stack around this view, so the renderer only draws the image surface.
struct MediaPlayerAnimatedImageRenderer: View {
    let node: NativeUINode

    var body: some View {
        let p = node.props

        AnimatedImageSurface(
            src: p.getString("src"),
            fit: p.getInt("fit", default: 1),
            autoplay: p.getBool("autoplay", default: true),
            loop: p.getBool("loop", default: true),
            alt: p.getString("alt")
        )
    }
}

private struct AnimatedImageSurface: UIViewRepresentable {
    let src: String
    let fit: Int
    let autoplay: Bool
    let loop: Bool
    let alt: String

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = Self.contentMode(fit)
        view.clipsToBounds = true
        // The frame source is what actually animates; UIImageView's own
        // animation machinery stays unused.
        view.isUserInteractionEnabled = false
        applyAccessibility(to: view)
        context.coordinator.attach(to: view)
        context.coordinator.load(src: src, autoplay: autoplay, loop: loop)

        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = Self.contentMode(fit)
        applyAccessibility(to: uiView)
        context.coordinator.load(src: src, autoplay: autoplay, loop: loop)
    }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: AnimatedImageCoordinator) {
        coordinator.cancel()
    }

    func makeCoordinator() -> AnimatedImageCoordinator {
        AnimatedImageCoordinator()
    }

    private func applyAccessibility(to view: UIImageView) {
        // Mirrors `image`: a labelled image is meaningful, an unlabelled one
        // is decorative and stays out of the accessibility tree.
        view.isAccessibilityElement = !alt.isEmpty
        view.accessibilityLabel = alt.isEmpty ? nil : alt
        view.accessibilityTraits = alt.isEmpty ? [] : .image
    }

    /// Same mapping `image` uses: 0/1 fit, 2 fill and crop, 3 stretch.
    private static func contentMode(_ fit: Int) -> UIView.ContentMode {
        switch fit {
        case 2: return .scaleAspectFill
        case 3: return .scaleToFill
        default: return .scaleAspectFit
        }
    }
}

/// Owns the download and the ImageIO animation for one surface.
final class AnimatedImageCoordinator {
    private weak var view: UIImageView?
    private var task: URLSessionDataTask?
    private var loadedSource: String = ""
    private var stopAnimation: UnsafeMutablePointer<Bool>?

    func attach(to view: UIImageView) {
        self.view = view
    }

    func load(src: String, autoplay: Bool, loop: Bool) {
        guard !src.isEmpty, src != loadedSource else { return }

        cancel()
        loadedSource = src

        if let data = Self.localData(for: src) {
            animate(data: data, autoplay: autoplay, loop: loop)

            return
        }

        guard let url = URL(string: src), url.scheme != nil else {
            print("🖼️ AnimatedImage: could not resolve source \(src)")

            return
        }

        task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, let data, error == nil else {
                if let error { print("🖼️ AnimatedImage: \(error.localizedDescription)") }

                return
            }

            DispatchQueue.main.async {
                // A newer source may have been requested while this was in
                // flight — drop the stale payload rather than flashing it.
                guard self.loadedSource == src else { return }
                self.animate(data: data, autoplay: autoplay, loop: loop)
            }
        }
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopAnimation?.pointee = true
        stopAnimation?.deallocate()
        stopAnimation = nil
    }

    private func animate(data: Data, autoplay: Bool, loop: Bool) {
        // A still first frame is the right resting state for a paused
        // animation, and the correct fallback for a non-animated payload.
        if let still = UIImage(data: data) {
            view?.image = still
        }

        guard autoplay else { return }

        // CGAnimateImageDataWithBlock honours the file's own frame delays and
        // loops forever; `stop` is how a one-shot play or a teardown ends it.
        let stopFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        stopFlag.initialize(to: false)
        stopAnimation = stopFlag

        CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] index, cgImage, stop in
            guard let self, let view = self.view, !stopFlag.pointee else {
                stop.pointee = true

                return
            }

            view.layer.contents = cgImage

            if !loop, index > 0, self.isFinalFrame(index: index, data: data) {
                stop.pointee = true
            }
        }
    }

    private func isFinalFrame(index: Int, data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return true }

        return index >= CGImageSourceGetCount(source) - 1
    }

    /// Device-local paths arrive as plain filesystem paths or file:// URLs,
    /// matching what `image` and `video_player` already accept.
    private static func localData(for src: String) -> Data? {
        if src.hasPrefix("file://"), let url = URL(string: src) {
            return try? Data(contentsOf: url)
        }

        if src.hasPrefix("/"), FileManager.default.fileExists(atPath: src) {
            return FileManager.default.contents(atPath: src)
        }

        return nil
    }
}
