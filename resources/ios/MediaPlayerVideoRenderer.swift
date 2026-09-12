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
/// Each surface owns its `AVPlayer`, loaded as soon as the surface exists so
/// a page that scrolls in starts instantly. `autoplay` means "play while
/// mostly on screen": inside a scroll view the surface pauses (and rewinds)
/// when it drops below half visible and plays again when it comes back —
/// a feed pager needs no coordination, and nothing in core mediates.
/// Outside a scroll view the visibility hook never fires and the surface
/// counts as visible.
///
/// The playing surface is adopted by `MediaPlayerManager`, so the PHP
/// `MediaPlayer` facade drives on-screen playback and PlaybackEnded /
/// PlaybackError fire for element playback too.
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
        // 1 contain (default), 2 cover, 3 fill — the Image `fit` contract.
        let fit = p.getInt("fit", default: 1)

        Group {
            if let player = model.player {
                if controls {
                    VideoPlayer(player: player)
                } else {
                    // Bare surface — no transport chrome. Developers overlay
                    // their own Element UI and drive playback via the facade.
                    MediaPlayerBareSurface(player: player, gravity: Self.gravity(for: fit))
                }
            } else {
                Color.black
            }
        }
        .task(id: "\(src)|\(autoplay)|\(loop)|\(muted)") {
            model.sync(src: src, autoplay: autoplay, loop: loop, muted: muted)
        }
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            model.setVisible(visible)
        }
        .onDisappear {
            model.surfaceGone()
        }
    }
}

extension MediaPlayerVideoRenderer {
    static func gravity(for fit: Int) -> AVLayerVideoGravity {
        switch fit {
        case 2: return .resizeAspectFill
        case 3: return .resize
        default: return .resizeAspect
        }
    }
}

/// Holds the AVPlayer for one `video_player` node across re-renders.
private final class MediaPlayerSurfaceModel: ObservableObject {
    @Published var player: AVPlayer?

    private var configuredSource: String = ""
    private var autoplay = false
    private var loop = false
    /// Visible until a scroll view says otherwise.
    private var visible = true

    func sync(src: String, autoplay: Bool, loop: Bool, muted: Bool) {
        guard !src.isEmpty else { return }

        self.autoplay = autoplay
        self.loop = loop

        if player == nil || src != configuredSource {
            if let old = player {
                MediaPlayerManager.shared.release(player: old)
            }
            configuredSource = src
            player = makePlayer(src: src)
        }

        player?.isMuted = muted
        apply()
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        apply()
    }

    /// Visible → adopt (the facade drives this surface) and honour autoplay.
    /// Hidden → let go, pause, rewind so it starts clean when it returns.
    private func apply() {
        guard let player else { return }

        if visible {
            MediaPlayerManager.shared.adopt(player: player, source: configuredSource, loop: loop, autoplay: autoplay)
        } else {
            MediaPlayerManager.shared.release(player: player)
            player.pause()
            player.seek(to: .zero)
        }
    }

    private func makePlayer(src: String) -> AVPlayer? {
        guard let url = MediaPlayerManager.resolveURL(src) else { return nil }

        let item = AVPlayerItem(url: url)
        // Enough to start instantly when the surface scrolls in, without
        // buffering the whole clip for a page that may never be reached.
        item.preferredForwardBufferDuration = 3

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        return player
    }

    func surfaceGone() {
        guard let player else { return }
        MediaPlayerManager.shared.release(player: player)
        player.pause()
    }
}

/// Bare AVPlayerLayer-backed surface for `controls=false`. Using the layer
/// directly (rather than AVKit's VideoPlayer with hidden chrome) guarantees
/// no system controls, gestures, or status overlays intercept touches meant
/// for the developer's own overlaid Element UI.
private struct MediaPlayerBareSurface: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> MediaPlayerLayerView {
        let view = MediaPlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        view.backgroundColor = .black
        // Cover / fill overflow the frame; keep the crop inside it.
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: MediaPlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
    }
}

/// UIView whose backing layer is an AVPlayerLayer, so the video always
/// tracks the view's bounds without manual layout.
final class MediaPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
