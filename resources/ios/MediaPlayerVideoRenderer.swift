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
/// Outside a paged container the surface adopts the shared
/// `MediaPlayerManager` player for its source, so the PHP `MediaPlayer`
/// facade drives on-screen playback and PlaybackEnded / PlaybackError fire
/// for element playback too.
///
/// Inside one (mobile-ui's `reel`) `\.reelPageActive` is non-nil and the
/// surface owns its own `AVPlayer`: the visible page's player is adopted by
/// the manager and plays, while pre-rendered neighbours stay loaded but
/// paused at the start so a swipe lands on video that starts instantly.
struct MediaPlayerVideoRenderer: View {
    let node: NativeUINode

    @Environment(\.reelPageActive) private var pageActive: Bool?
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
        .task(id: "\(src)|\(String(describing: pageActive))|\(autoplay)|\(loop)|\(muted)") {
            model.sync(src: src, pageActive: pageActive, autoplay: autoplay, loop: loop, muted: muted)
        }
        .onDisappear {
            model.surfaceGone()
        }
    }
}

/// Holds the AVPlayer for one `video_player` node across re-renders.
private final class MediaPlayerSurfaceModel: ObservableObject {
    @Published var player: AVPlayer?

    private var configuredSource: String = ""
    /// Player this surface owns while inside a paged container.
    private var ownPlayer: AVPlayer?

    func sync(src: String, pageActive: Bool?, autoplay: Bool, loop: Bool, muted: Bool) {
        guard !src.isEmpty else { return }

        guard let active = pageActive else {
            syncShared(src: src, autoplay: autoplay, loop: loop, muted: muted)
            return
        }

        syncPaged(src: src, active: active, autoplay: autoplay, loop: loop, muted: muted)
    }

    /// Not in a pager: the shared manager player, re-configured only when
    /// the source changes.
    private func syncShared(src: String, autoplay: Bool, loop: Bool, muted: Bool) {
        if let own = ownPlayer {
            MediaPlayerManager.shared.release(player: own)
            ownPlayer = nil
        }

        guard src != configuredSource else { return }

        configuredSource = src
        player = MediaPlayerManager.shared.preparePlayer(
            source: src,
            loop: loop,
            muted: muted,
            autoplay: autoplay
        )
    }

    /// In a pager: own player, loaded as soon as the page is pre-rendered.
    /// Only the settled page's player is adopted (and plays).
    private func syncPaged(src: String, active: Bool, autoplay: Bool, loop: Bool, muted: Bool) {
        if ownPlayer == nil || src != configuredSource {
            if let old = ownPlayer {
                MediaPlayerManager.shared.release(player: old)
            }
            configuredSource = src
            ownPlayer = makeOwnPlayer(src: src)
            player = ownPlayer
        }

        guard let own = ownPlayer else { return }
        own.isMuted = muted

        if active {
            MediaPlayerManager.shared.adopt(player: own, source: src, loop: loop, autoplay: autoplay)
        } else {
            MediaPlayerManager.shared.release(player: own)
            own.pause()
            own.seek(to: .zero)
        }
    }

    private func makeOwnPlayer(src: String) -> AVPlayer? {
        guard let url = MediaPlayerManager.resolveURL(src) else { return nil }

        let item = AVPlayerItem(url: url)
        // Enough to start instantly on swipe without buffering the whole clip
        // for a page that may never be reached.
        item.preferredForwardBufferDuration = 3

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        return player
    }

    func surfaceGone() {
        guard let own = ownPlayer else { return }
        MediaPlayerManager.shared.release(player: own)
        own.pause()
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
