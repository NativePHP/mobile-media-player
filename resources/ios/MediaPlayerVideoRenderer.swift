import AVFoundation
import AVKit
import SwiftUI

/// Renderer for the `video_player` element type. Registered by the generated
/// `PluginRendererRegistration` via `SwiftUIRendererRegistry.shared.register`
/// (declared under `components[].ios_renderer` in the plugin manifest).
///
/// Layout (width / height / aspect) is applied by core's `NodeView` modifier
/// stack around this view, so the renderer only draws the video surface.
///
/// The surface adopts the shared `MediaPlayerManager` player for its source,
/// so the PHP `MediaPlayer` facade (pause / resume / seek / volume / status)
/// drives on-screen playback and PlaybackEnded / PlaybackError events fire
/// for element playback too.
struct MediaPlayerVideoRenderer: View {
    let node: NativeUINode

    @StateObject private var model = MediaPlayerSurfaceModel()

    var body: some View {
        let p = node.props
        let src = p.getString("src")
        let controls = p.getBool("controls", default: true)
        let autoplay = p.getBool("autoplay")
        let loop = p.getBool("loop")
        let muted = p.getBool("muted")

        Group {
            if let player = model.player {
                if controls {
                    VideoPlayer(player: player)
                } else {
                    // Bare surface — no transport chrome. Developers overlay
                    // their own Element UI and drive playback via the facade.
                    MediaPlayerBareSurface(player: player)
                }
            } else {
                Color.black
            }
        }
        .onAppear {
            model.configure(src: src, autoplay: autoplay, loop: loop, muted: muted)
        }
        .onChange(of: src) { newSrc in
            model.configure(src: newSrc, autoplay: autoplay, loop: loop, muted: muted)
        }
    }
}

/// Holds the AVPlayer for one `video_player` node across recompositions.
/// Re-configures only when the source actually changes.
private final class MediaPlayerSurfaceModel: ObservableObject {
    @Published var player: AVPlayer?

    private var configuredSource: String = ""

    func configure(src: String, autoplay: Bool, loop: Bool, muted: Bool) {
        guard !src.isEmpty, src != configuredSource else { return }

        configuredSource = src
        player = MediaPlayerManager.shared.preparePlayer(
            source: src,
            loop: loop,
            muted: muted,
            autoplay: autoplay
        )
    }
}

/// Bare AVPlayerLayer-backed surface for `controls=false`. Using the layer
/// directly (rather than AVKit's VideoPlayer with hidden chrome) guarantees
/// no system controls, gestures, or status overlays intercept touches meant
/// for the developer's own overlaid Element UI.
private struct MediaPlayerBareSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> MediaPlayerLayerView {
        let view = MediaPlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: MediaPlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

/// UIView whose backing layer is an AVPlayerLayer, so the video always
/// tracks the view's bounds without manual layout.
final class MediaPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
