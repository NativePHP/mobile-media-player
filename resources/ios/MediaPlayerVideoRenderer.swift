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
/// mostly on screen": inside a scroll view the surface measures how much
/// of it is inside the scroll viewport, plays at half or more, pauses
/// below that, and rewinds only once it is fully off screen — a feed pager
/// needs no coordination, and nothing in core mediates. Outside a scroll
/// view the surface counts as visible.
///
/// Visibility is measured from geometry BEFORE the surface does anything:
/// a freshly pre-rendered neighbour that assumed it was visible would
/// adopt the shared player slot and pause the page actually being
/// watched, then pause itself once it learned better — leaving the feed
/// frozen on a poster frame.
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
        let poster = p.getString("poster")

        ZStack {
            Color.black

            // Poster permanently underneath. The layer above is transparent
            // until it holds a frame (and again whenever it is detached), so
            // the still shows instead of black without any swap logic.
            if !poster.isEmpty, let url = MediaPlayerManager.resolveURL(poster) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: fit == 2 || fit == 3 ? .fill : .fit)
                } placeholder: {
                    Color.black
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .accessibilityHidden(true)
            }

            if let player = model.player {
                if controls {
                    // AVKit's VideoPlayer measures nothing, so a transparent,
                    // touch-transparent probe the same size reports visibility
                    // for it — otherwise the surface is never adopted and
                    // autoplay, looping, events and the facade all go dead.
                    VideoPlayer(player: player)
                        .overlay(
                            MediaPlayerVisibilityProbe(onVisibleFraction: { fraction in model.setVisibleFraction(fraction) })
                                .allowsHitTesting(false)
                        )
                } else {
                    // Bare surface — no transport chrome. Developers overlay
                    // their own Element UI and drive playback via the facade.
                    // The layer only gets the player while the surface is at
                    // least partly on screen. A player buffers fine without
                    // a layer; attaching one creates a video pipeline, and
                    // doing that for an off-screen neighbour blanks the page
                    // the user is watching for a frame.
                    MediaPlayerBareSurface(
                        player: model.attached ? player : nil,
                        gravity: Self.gravity(for: fit),
                        onReadyForDisplay: { ready in model.layerReady(ready) },
                        onVisibleFraction: { fraction in model.setVisibleFraction(fraction) }
                    )
                }
            }
        }
        .task(id: "\(src)|\(autoplay)|\(loop)|\(muted)|\(controls)|\(poster.isEmpty)") {
            // Gate the first play() on the layer holding a frame only when
            // there is a poster to reveal from; AVKit's VideoPlayer never
            // reports readiness, so it is never gated.
            model.sync(src: src, autoplay: autoplay, loop: loop, muted: muted, gated: !controls && !poster.isEmpty)
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
    /// Whether the player is attached to the on-screen layer (partly
    /// visible or more). Off-screen surfaces keep buffering without one.
    @Published var attached = false

    private var configuredSource: String = ""
    private var autoplay = false
    private var loop = false
    /// Fraction of the surface inside its scroll viewport. Unknown until
    /// the first layout — nothing plays before it is measured.
    private var visibleFraction: Double?
    private var playing = false
    /// Bare surface with a poster: the poster is covered by the layer, so
    /// play() waits for the layer to hold frame 0 — otherwise the still
    /// would hide a running clip and the reveal would cut mid-motion.
    private var gated = false
    /// Live `isReadyForDisplay` of the attached layer (false while detached).
    private var layerLive = false
    /// adopt() ran with play held back; start on the next ready edge.
    private var playWhenReady = false
    private var readyFallback: DispatchWorkItem?

    func sync(src: String, autoplay: Bool, loop: Bool, muted: Bool, gated: Bool) {
        guard !src.isEmpty else { return }

        self.autoplay = autoplay
        self.loop = loop
        self.gated = gated

        if player == nil || src != configuredSource {
            if let old = player {
                MediaPlayerManager.shared.release(player: old)
            }
            configuredSource = src
            playing = false
            playWhenReady = false
            readyFallback?.cancel()
            player = makePlayer(src: src)
        }

        player?.isMuted = muted
        apply()
    }

    func setVisibleFraction(_ fraction: Double) {
        let was = visibleFraction
        visibleFraction = fraction
        let onScreen = fraction >= Self.attachAt
        if attached != onScreen {
            attached = onScreen
        }
        // A neighbour crossing the threshold adopts the shared slot and the
        // manager pauses this player — not this model. Notice, so this
        // surface knows it is no longer playing and can come back.
        if playing, let player, !MediaPlayerManager.shared.isAdopted(player) {
            playing = false
            playWhenReady = false
            readyFallback?.cancel()
        }
        // Act on a change of state, not on every layout tick — except to
        // reclaim: this surface is still (or again) the one mostly on
        // screen and the slot is free, because the neighbour that took it
        // dropped back below the crossover without this one ever leaving.
        let wasShown = (was ?? 0) >= Self.playAt
        let wasHidden = (was ?? 0) < Self.pauseBelow
        let wasGone = was == nil || was == 0
        let transition = wasShown != (fraction >= Self.playAt) || wasHidden != (fraction < Self.pauseBelow) || wasGone != (fraction == 0)
        let reclaim = !playing && fraction >= Self.playAt && MediaPlayerManager.shared.isIdle
        if transition || reclaim {
            apply()
        }
    }

    /// The hand-off happens at the crossover, like Instagram's feed: the
    /// incoming page starts as soon as it is ~45% on screen, and that is the
    /// moment the outgoing page (now ~55% and shrinking) pauses. One
    /// threshold for both directions, so a drag that wobbles never has two
    /// pages playing or none.
    static let playAt = 0.45
    static let pauseBelow = 0.45
    static let attachAt = 0.01

    /// The attached layer's readiness edge. On the rising edge, start a
    /// playback that was held back waiting for frame 0.
    func layerReady(_ ready: Bool) {
        layerLive = ready
        guard ready, playWhenReady else { return }
        playWhenReady = false
        readyFallback?.cancel()
        startHeldPlayback()
    }

    private func startHeldPlayback() {
        guard let player, playing, MediaPlayerManager.shared.isAdopted(player) else { return }
        MediaPlayerManager.shared.resume()
    }

    /// Half or more on screen → adopt (the facade drives this surface) and
    /// honour autoplay — but with a poster to reveal from, hold play() until
    /// the layer holds a frame, so the reveal always lands on a paused
    /// frame 0 and never on a clip already in motion. Less than half → let
    /// go and pause where it is. Fully off screen → rewind, so it starts
    /// clean when it scrolls back in and the rewind is never seen mid-swipe.
    private func apply() {
        guard let player, let fraction = visibleFraction else { return }

        if fraction >= Self.playAt {
            if !playing {
                playing = true
                // The page being watched may buffer as far as it likes; a
                // neighbour only holds a short lead so several of them
                // don't starve it on a slow connection.
                player.currentItem?.preferredForwardBufferDuration = 0
                let holdPlay = autoplay && gated && !layerLive
                MediaPlayerManager.shared.adopt(player: player, source: configuredSource, loop: loop, autoplay: autoplay && !holdPlay)
                if holdPlay {
                    playWhenReady = true
                    // A layer that never reports (failed decode, audio-only)
                    // must not leave the page silent: start regardless after
                    // a second.
                    let fallback = DispatchWorkItem { [weak self] in
                        guard let self, self.playWhenReady else { return }
                        self.playWhenReady = false
                        self.startHeldPlayback()
                    }
                    readyFallback = fallback
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: fallback)
                }
            }
        } else if fraction < Self.pauseBelow {
            if playing {
                playing = false
                playWhenReady = false
                readyFallback?.cancel()
                MediaPlayerManager.shared.release(player: player)
                player.pause()
            }
            if fraction == 0 {
                player.seek(to: .zero)
            }
        }
    }

    private func makePlayer(src: String) -> AVPlayer? {
        guard let url = MediaPlayerManager.resolveURL(src) else { return nil }

        let item = AVPlayerItem(url: url)
        // A short lead: enough to start instantly when the surface scrolls
        // in, small enough that four buffering neighbours don't starve the
        // page being watched. Lifted to "as much as you like" on adoption.
        item.preferredForwardBufferDuration = 1.5

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        return player
    }

    func surfaceGone() {
        guard let player else { return }
        playing = false
        playWhenReady = false
        readyFallback?.cancel()
        visibleFraction = nil
        attached = false
        MediaPlayerManager.shared.release(player: player)
        player.pause()
    }
}

/// Bare AVPlayerLayer-backed surface for `controls=false`. Using the layer
/// directly (rather than AVKit's VideoPlayer with hidden chrome) guarantees
/// no system controls, gestures, or status overlays intercept touches meant
/// for the developer's own overlaid Element UI.
private struct MediaPlayerBareSurface: UIViewRepresentable {
    let player: AVPlayer?
    let gravity: AVLayerVideoGravity
    var onReadyForDisplay: ((Bool) -> Void)? = nil
    var onVisibleFraction: ((Double) -> Void)? = nil

    func makeUIView(context: Context) -> MediaPlayerLayerView {
        let view = MediaPlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        view.backgroundColor = .clear
        // Cover / fill overflow the frame; keep the crop inside it.
        view.clipsToBounds = true
        view.onReadyForDisplay = onReadyForDisplay
        view.onVisibleFraction = onVisibleFraction
        return view
    }

    func updateUIView(_ uiView: MediaPlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
        uiView.onReadyForDisplay = onReadyForDisplay
        uiView.onVisibleFraction = onVisibleFraction
    }
}

/// Transparent view that only measures. Overlaid on AVKit's `VideoPlayer`
/// (the `controls=true` surface) so both variants feed the same
/// visibility state machine.
private struct MediaPlayerVisibilityProbe: UIViewRepresentable {
    var onVisibleFraction: ((Double) -> Void)? = nil

    func makeUIView(context: Context) -> MediaPlayerVisibilityView {
        let view = MediaPlayerVisibilityView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onVisibleFraction = onVisibleFraction
        return view
    }

    func updateUIView(_ uiView: MediaPlayerVisibilityView, context: Context) {
        uiView.onVisibleFraction = onVisibleFraction
    }
}

/// UIView that reports how much of itself is actually visible: inside the
/// window AND inside every clipping ancestor (a pager or scroll view
/// smaller than the screen clips its neighbours, and a clipped-away
/// neighbour must not count as on screen, adopt playback and pause the
/// page really being watched). Measured on a light timer in window
/// coordinates: SwiftUI's geometry only re-evaluates on layout passes and
/// its scroll-visibility callbacks proved unreliable across re-renders,
/// while a UIView's position in the window is always exact, scrolling
/// included.
class MediaPlayerVisibilityView: UIView {
    var onVisibleFraction: ((Double) -> Void)?

    private var visibilityTimer: Timer?
    private var lastFraction: Double = -1

    override func didMoveToWindow() {
        super.didMoveToWindow()
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        guard window != nil else {
            report(0)
            return
        }
        // `.common` so it keeps firing while the scroll view is tracking.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.measure()
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
        measure()
    }

    private func measure() {
        guard let window, bounds.width > 0, bounds.height > 0 else {
            report(0)
            return
        }
        let inWindow = convert(bounds, to: window)

        // The region anything can be seen in: the window, narrowed by every
        // ancestor that clips its subviews (UIScrollView always does).
        var container = window.bounds
        var ancestor = superview
        while let view = ancestor, !container.isNull {
            if view.clipsToBounds || view.layer.masksToBounds {
                container = container.intersection(view.convert(view.bounds, to: window))
            }
            ancestor = view.superview
        }

        let shown = container.isNull ? CGRect.null : inWindow.intersection(container)
        // Against the smaller of the view and the container: a cover-fitted
        // surface is wider than the screen, and "fully on screen" must
        // still read as 1.
        let reference = container.isNull
            ? 0
            : min(inWindow.width * inWindow.height, container.width * container.height)
        let fraction = shown.isNull || reference <= 0 ? 0 : Double((shown.width * shown.height) / reference)
        report(min(1, max(0, fraction)))
    }

    private func report(_ fraction: Double) {
        // Quantise so steady scrolling doesn't spam the model; the state
        // machine only cares about a few thresholds anyway.
        let q = (fraction * 100).rounded() / 100
        guard q != lastFraction else { return }
        lastFraction = q
        onVisibleFraction?(q)
    }

    deinit {
        visibilityTimer?.invalidate()
    }
}

/// UIView whose backing layer is an AVPlayerLayer, so the video always
/// tracks the view's bounds without manual layout. Reports the layer's
/// `isReadyForDisplay` so a poster can be dropped exactly when the first
/// frame is drawable, and inherits the visibility measurement.
final class MediaPlayerLayerView: MediaPlayerVisibilityView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var onReadyForDisplay: ((Bool) -> Void)?

    private var readyObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { self?.onReadyForDisplay?(ready) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
