import AVFoundation
import Foundation

/// MediaPlayerManager owns the shared AVPlayer used by the headless
/// `MediaPlayer.*` bridge functions and by the `video_player` element
/// renderer. Only one source plays at a time: starting a new source (from
/// PHP or from an element surface) replaces the current one, so facade
/// calls (pause / resume / seek / volume / status) always drive whatever
/// is currently playing.
///
/// Fires "NativePHP\MediaPlayer\Events\PlaybackEnded" / "...\PlaybackError"
/// through `LaravelBridge.shared.send` — the same event-dispatch mechanism
/// the microphone plugin uses for MicrophoneRecorded.
final class MediaPlayerManager: NSObject {
    static let shared = MediaPlayerManager()

    private(set) var player: AVPlayer?
    private(set) var source: String?
    private(set) var state: String = "idle"

    private var shouldLoop = false
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    private override init() {
        super.init()
    }

    // MARK: - Playback control

    /// Start (or replace) playback. Returns false when the source can't be
    /// resolved to a URL or the player can't be created.
    @discardableResult
    func play(source: String, loop: Bool, volume: Float) -> Bool {
        guard let player = preparePlayer(source: source, loop: loop, muted: false, autoplay: true) else {
            return false
        }

        player.volume = max(0, min(1, volume))

        return true
    }

    /// Create the shared player for a source without necessarily starting it.
    /// Used by both `play()` and the `video_player` element renderer — the
    /// renderer adopts the returned player as its surface's player so the PHP
    /// facade keeps controlling on-screen playback.
    ///
    /// If the shared player already holds this source it is returned as-is
    /// (so multiple renders of the same element don't restart playback).
    func preparePlayer(source: String, loop: Bool, muted: Bool, autoplay: Bool) -> AVPlayer? {
        if let existing = player, self.source == source {
            existing.isMuted = muted
            return existing
        }

        guard let url = Self.resolveURL(source) else {
            print("🎬 MediaPlayer: could not resolve source \(source)")
            dispatchError(source: source, message: "Could not resolve source URL")
            return nil
        }

        teardown()
        configureAudioSession()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted

        self.player = player
        self.source = source
        self.shouldLoop = loop

        observe(item: item)

        if autoplay {
            player.play()
            state = "playing"
        } else {
            state = "paused"
        }

        return player
    }

    func pause() {
        guard let player = player, state == "playing" else { return }
        player.pause()
        state = "paused"
    }

    func resume() {
        guard let player = player else { return }
        if state == "ended" {
            player.seek(to: .zero)
        }
        player.play()
        state = "playing"
    }

    func stop() {
        teardown()
        state = "idle"
    }

    func seek(to seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if state == "ended" {
            state = "paused"
        }
    }

    func setVolume(_ volume: Float) {
        player?.volume = max(0, min(1, volume))
    }

    func getStatus() -> [String: Any] {
        var position = 0.0
        var duration = 0.0

        if let player = player {
            let current = player.currentTime().seconds
            if current.isFinite {
                position = current
            }
            if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite {
                duration = itemDuration
            }
        }

        return [
            "state": state,
            "position": position,
            "duration": duration,
            "source": source ?? "",
        ]
    }

    // MARK: - Helpers

    /// Set the playback audio session category before playing (mirrors the
    /// microphone plugin's use of AVAudioSession.sharedInstance()).
    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("🎬 MediaPlayer: failed to configure audio session: \(error.localizedDescription)")
        }
    }

    /// Resolve a source string (http(s) URL, file:// URL, or bare file path)
    /// to a playable URL.
    static func resolveURL(_ source: String) -> URL? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("file://") {
            return URL(string: source)
        }

        if source.hasPrefix("/") {
            return URL(fileURLWithPath: source)
        }

        return URL(string: source)
    }

    // MARK: - Observation & events

    private func observe(item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleEnded()
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.handleError(message: error?.localizedDescription ?? "Playback failed")
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                self?.handleError(message: item.error?.localizedDescription ?? "Failed to load media")
            }
        }
    }

    private func handleEnded() {
        if shouldLoop {
            player?.seek(to: .zero)
            player?.play()
            return
        }

        state = "ended"

        let payload: [String: Any] = ["source": source ?? ""]
        print("📤 Dispatching PlaybackEnded with source=\(source ?? "nil")")
        LaravelBridge.shared.send?("NativePHP\\MediaPlayer\\Events\\PlaybackEnded", payload)
    }

    private func handleError(message: String) {
        state = "error"
        dispatchError(source: source ?? "", message: message)
    }

    private func dispatchError(source: String, message: String) {
        let payload: [String: Any] = [
            "source": source,
            "message": message,
        ]
        print("📤 Dispatching PlaybackError with source=\(source), message=\(message)")
        LaravelBridge.shared.send?("NativePHP\\MediaPlayer\\Events\\PlaybackError", payload)
    }

    private func teardown() {
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failObserver = failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
        endObserver = nil
        failObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        source = nil
        shouldLoop = false
    }
}
