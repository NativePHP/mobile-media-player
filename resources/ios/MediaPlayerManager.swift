import AVFoundation
import Foundation
import MediaPlayer
import UIKit

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

    // Now Playing metadata for the lock screen / Control Center.
    private var nowPlayingTitle: String?
    private var nowPlayingArtist: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var artworkTask: URLSessionDataTask?
    private var remoteCommandsRegistered = false

    /// Survives teardown() so the lock screen can start playback again after a
    /// stop. `source` is nil'd by teardown; this is not.
    private var lastSource: String?
    private var lastLoop = false
    private var lastVolume: Float = 1.0

    private override init() {
        super.init()
    }

    // MARK: - Playback control

    /// Start (or replace) playback. Returns false when the source can't be
    /// resolved to a URL or the player can't be created.
    @discardableResult
    func play(
        source: String,
        loop: Bool,
        volume: Float,
        title: String? = nil,
        artist: String? = nil,
        artwork: String? = nil
    ) -> Bool {
        // Stash metadata before preparing, so the first now-playing publish
        // already carries it.
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingArtwork = nil

        lastSource = source
        lastLoop = loop
        lastVolume = max(0, min(1, volume))

        guard let player = preparePlayer(source: source, loop: loop, muted: false, autoplay: true) else {
            return false
        }

        player.volume = max(0, min(1, volume))

        registerRemoteCommands()
        updateNowPlayingInfo()
        loadArtwork(from: artwork)

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
        updateNowPlayingInfo()
    }

    func resume() {
        guard let player = player else { return }
        if state == "ended" {
            player.seek(to: .zero)
        }
        player.play()
        state = "playing"
        updateNowPlayingInfo()
    }

    func stop() {
        teardown()
        state = "idle"
        updateNowPlayingInfo()

        // Clearing nowPlayingInfo alone is not enough to dismiss the lock
        // screen card — iOS keeps showing a stale one, with dead transport
        // buttons, until the audio session is released. Deactivating also
        // hands the Now Playing slot back to whatever was playing before us.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("🎬 MediaPlayer: failed to deactivate audio session: \(error.localizedDescription)")
        }
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

    // MARK: - Now Playing

    /// Publish the current playback state to the system so it appears on the
    /// lock screen, in Control Center and in the Dynamic Island.
    ///
    /// A live stream is flagged with MPNowPlayingInfoPropertyIsLiveStream,
    /// which is what makes iOS render a "LIVE" badge with no scrubber.
    func updateNowPlayingInfo() {
        guard state != "idle" else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        var info: [String: Any] = [:]

        info[MPMediaItemPropertyTitle] = nowPlayingTitle ?? "Live stream"
        if let artist = nowPlayingArtist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let duration = player?.currentItem?.duration.seconds
        let isLive = !(duration?.isFinite ?? false)

        info[MPNowPlayingInfoPropertyIsLiveStream] = isLive

        // Positional keys are published for live content too, as zeroes: the
        // LIVE badge comes from the IsLiveStream flag, not from their absence,
        // and supplying them keeps the dictionary well-formed for the system's
        // other Now Playing surfaces. AVPlayer reports a non-finite time
        // before the first sample is ready, hence the isFinite guard.
        let elapsed = player?.currentTime().seconds ?? 0

        info[MPMediaItemPropertyPlaybackDuration] = isLive ? 0 : (duration ?? 0)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed.isFinite ? elapsed : 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == "playing" ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // State the playback state outright rather than leaving the system to
        // infer it from the audio session alone.
        MPNowPlayingInfoCenter.default().playbackState = state == "playing" ? .playing : .paused

    }

    /// Fetch remote artwork off the main thread, then republish. Local paths
    /// are loaded directly.
    private func loadArtwork(from source: String?) {
        artworkTask?.cancel()
        artworkTask = nil

        guard let source = source, !source.isEmpty, let url = Self.resolveURL(source) else {
            return
        }

        if url.isFileURL {
            if let image = UIImage(contentsOfFile: url.path) {
                setArtwork(image)
            }
            return
        }

        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { self?.setArtwork(image) }
        }
        artworkTask?.resume()
    }

    private func setArtwork(_ image: UIImage) {
        nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        updateNowPlayingInfo()
    }

    // MARK: - Remote commands

    /// Wire the lock screen / Control Center / Dynamic Island transport
    /// buttons. Each handler drives the player natively for instant feedback
    /// *and* notifies PHP so the in-app UI reconciles.
    ///
    /// Registered lazily on first play: registering at launch would claim the
    /// now-playing slot before there is anything to play.
    private func registerRemoteCommands() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true

        let centre = MPRemoteCommandCenter.shared()

        centre.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .noSuchContent }
            guard self.startFromRemote() else { return .noSuchContent }
            self.updateNowPlayingInfo()
            self.dispatchRemoteCommand("play")
            return .success
        }

        centre.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.player != nil else { return .noSuchContent }
            self.pause()
            self.updateNowPlayingInfo()
            self.dispatchRemoteCommand("pause")
            return .success
        }

        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .noSuchContent }

            if self.state == "playing" {
                // Live content has no useful paused state — halt it the same
                // way the stop button does, so both routes behave alike.
                let isLive = !(self.player?.currentItem?.duration.seconds.isFinite ?? false)

                if isLive {
                    self.haltForRemote()
                    self.dispatchRemoteCommand("stop")
                } else {
                    self.pause()
                    self.updateNowPlayingInfo()
                    self.dispatchRemoteCommand("pause")
                }

                return .success
            }

            guard self.startFromRemote() else { return .noSuchContent }
            self.updateNowPlayingInfo()
            self.dispatchRemoteCommand("play")
            return .success
        }

        centre.stopCommand.addTarget { [weak self] _ in
            guard let self = self else { return .noSuchContent }
            self.haltForRemote()
            self.dispatchRemoteCommand("stop")
            return .success
        }

        // Deliberately left disabled: we want to observe whether iOS offers
        // skip affordances for live content when they are not enabled.
        centre.nextTrackCommand.isEnabled = false
        centre.previousTrackCommand.isEnabled = false
        centre.changePlaybackPositionCommand.isEnabled = false

    }

    /// Handle the lock screen's stop button.
    ///
    /// Because a live stream is published with MPNowPlayingInfoPropertyIsLiveStream,
    /// iOS renders a stop button rather than pause/play — pausing live content
    /// is meaningless, so there is no pause command to receive. Treat that stop
    /// as "halt, but stay resumable":
    ///
    ///   - tear the player down, because a live buffer is stale the moment it
    ///     stops and resuming it would leave us behind the live edge;
    ///   - keep the Now Playing card, in the paused state, so the user still
    ///     has something to press to come back;
    ///   - keep the audio session active, since deactivating it hands the Now
    ///     Playing slot to whatever played before us and the card disappears.
    ///
    /// `stop()` remains the hard stop for a PHP-initiated MediaPlayer::stop().
    private func haltForRemote() {
        teardown()

        // Not "idle": that is the state updateNowPlayingInfo() treats as
        // "clear the card entirely".
        state = "paused"

        updateNowPlayingInfo()
    }

    /// Start playback in response to a remote (lock screen / Control Center /
    /// Dynamic Island) play press, from whatever state we are in.
    ///
    /// The player may be paused *or* fully torn down: `stop()` releases it, so
    /// there is nothing to resume. Falling back to `lastSource` lets the lock
    /// screen restart a stopped stream instead of silently doing nothing.
    ///
    /// Returns false only when we have never been given a source to play.
    @discardableResult
    private func startFromRemote() -> Bool {
        if player != nil {
            resumeOrRejoinLive()
            return true
        }

        guard let source = lastSource else {
            return false
        }

        return play(
            source: source,
            loop: lastLoop,
            volume: lastVolume,
            title: nowPlayingTitle,
            artist: nowPlayingArtist
        )
    }

    /// Resume on-demand media; jump to the live edge for a live stream.
    ///
    /// AVPlayer resumes a paused item from its stalled buffer. For on-demand
    /// media that is right; for a live stream the buffer is stale the moment
    /// you pause, so a plain resume plays nothing or leaves you behind live.
    ///
    /// We deliberately do NOT tear the player down and rebuild it: while the
    /// app is backgrounded, the `audio` background mode only keeps us alive so
    /// long as audio is actually playing. A teardown creates a silent gap, and
    /// iOS can suspend us inside it before the replacement player starts.
    /// Seeking the existing item to the end of its seekable range rejoins live
    /// without ever dropping the audio session.
    private func resumeOrRejoinLive() {
        guard let player = player, let item = player.currentItem else {
            return
        }

        let duration = item.duration.seconds
        let isLive = !duration.isFinite

        guard isLive else {
            resume()
            return
        }

        guard let liveRange = item.seekableTimeRanges.last?.timeRangeValue else {
            // No seekable range yet (buffer fully drained). Nothing sensible
            // to seek to, so just start the existing item and let AVFoundation
            // refill from the playlist.
            player.play()
            state = "playing"
            return
        }

        let liveEdge = CMTimeRangeGetEnd(liveRange)
        player.seek(to: liveEdge, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            player.play()
            self?.state = "playing"
            self?.updateNowPlayingInfo()
        }

        state = "playing"
    }

    private func dispatchRemoteCommand(_ command: String) {
        let payload: [String: Any] = ["command": command, "source": source ?? ""]
        print("📤 Dispatching RemoteCommand \(command)")
        LaravelBridge.shared.send?("NativePHP\\MediaPlayer\\Events\\RemoteCommand", payload)
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
        updateNowPlayingInfo()

        let payload: [String: Any] = ["source": source ?? ""]
        print("📤 Dispatching PlaybackEnded with source=\(source ?? "nil")")
        LaravelBridge.shared.send?("NativePHP\\MediaPlayer\\Events\\PlaybackEnded", payload)
    }

    private func handleError(message: String) {
        state = "error"
        updateNowPlayingInfo()
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
