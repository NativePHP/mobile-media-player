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

    /// Posted on the main thread whenever the shared slot changes hands —
    /// adopted, released, stopped, replaced. Surfaces reassess on it, so
    /// one that lost the slot to a neighbour can take it back the moment
    /// the neighbour lets go, even if its own geometry never changes again.
    static let slotDidChange = Notification.Name("NativePHP.MediaPlayer.slotDidChange")

    private(set) var player: AVPlayer?
    private(set) var source: String?
    private(set) var state: String = "idle"

    private var shouldLoop = false
    /// How fast playback goes, 1.0 being normal speed. Kept across `play()`
    /// calls until changed.
    private var rate: Float = 1
    /// False while `player` belongs to a `video_player` surface (adopted via
    /// `adopt(player:)`): teardown then pauses and lets go instead of
    /// stripping the surface's item.
    private var ownsPlayer = true
    /// The slot is empty because PHP asked (`stop()`), not because a
    /// surface let go. Surfaces must not quietly resume after that; a
    /// threshold crossing (or `play()`) starts things again.
    private var stoppedByFacade = false
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
    private var lastStartTimeout: Double = 0

    // Start checks: AVPlayer never fails some sources, it just waits on them
    // forever. These turn that silence into a PlaybackError.
    private var startWatchdog: DispatchWorkItem?
    private var timeControlObservation: NSKeyValueObservation?
    private var streamTypeProbe: StreamTypeProbe?

    private override init() {
        super.init()
    }

    // MARK: - Playback control

    /// Start (or replace) playback, from `position` seconds in (or where the
    /// same source already is, when 0), at `rate` (1.0 = normal speed).
    /// Returns false when the source can't be resolved to a URL or the player
    /// can't be created.
    @discardableResult
    func play(
        source: String,
        loop: Bool,
        volume: Float,
        rate: Float = 1,
        position: Double = 0,
        title: String? = nil,
        artist: String? = nil,
        artwork: String? = nil,
        startTimeout: Double = 0
    ) -> Bool {
        // Stash metadata before preparing, so the first now-playing publish
        // already carries it.
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingArtwork = nil

        lastSource = source
        lastLoop = loop
        lastVolume = max(0, min(1, volume))
        lastStartTimeout = max(0, startTimeout)

        guard let player = preparePlayer(source: source, loop: loop, muted: false, autoplay: false) else {
            return false
        }

        player.volume = max(0, min(1, volume))
        self.rate = Self.clamped(rate)
        player.defaultRate = self.rate

        if position > 0 || state == "ended" {
            player.seek(to: CMTime(seconds: max(0, position), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }

        activateForPlayback()
        player.play()
        state = "playing"

        registerRemoteCommands()
        updateNowPlayingInfo()
        loadArtwork(from: artwork)

        armStartChecks(player: player, source: source)

        return true
    }

    /// Change how fast playback goes (1.0 = normal speed). A paused player
    /// stays paused and picks the speed up when it resumes.
    func setRate(_ rate: Float) {
        self.rate = Self.clamped(rate)

        guard let player = player else { return }

        player.defaultRate = self.rate

        if state == "playing" {
            player.rate = self.rate
        }

        updateNowPlayingInfo()
    }

    private static func clamped(_ rate: Float) -> Float {
        max(0.25, min(4, rate))
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
        self.ownsPlayer = true
        self.stoppedByFacade = false

        observe(item: item)

        if autoplay {
            player.play()
            state = "playing"
        } else {
            state = "paused"
        }

        notifySlotChanged()

        return player
    }

    /// Adopt a surface-owned player (a `video_player` inside a paged
    /// container) as the shared playback. Any previous playback is paused
    /// and released; the facade then drives this player until another one
    /// is adopted or `release(player:)` drops it.
    func adopt(player: AVPlayer, source: String, loop: Bool, autoplay: Bool) {
        if self.player === player {
            shouldLoop = loop
            if autoplay, state != "playing" {
                player.play()
                state = "playing"
            }
            return
        }

        teardown()
        configureAudioSession()
        clearNowPlaying()

        self.player = player
        self.source = source
        self.shouldLoop = loop
        self.ownsPlayer = false
        self.stoppedByFacade = false

        if let item = player.currentItem {
            observe(item: item)
        }

        if autoplay {
            player.play()
            state = "playing"
        } else {
            state = "paused"
        }

        notifySlotChanged()
    }

    /// True when `player` is the surface the facade currently drives.
    func isAdopted(_ player: AVPlayer) -> Bool {
        self.player === player
    }

    /// True when a surface still mostly on screen may take the shared
    /// slot without crossing a threshold: nothing holds it (no adopted
    /// surface, no headless playback) and it was not emptied by an
    /// explicit `stop()`.
    var isReclaimable: Bool {
        player == nil && !stoppedByFacade
    }

    /// Drop `player` if it is the adopted one — its page left the screen
    /// or its surface is going away. Other players are untouched.
    func release(player: AVPlayer) {
        guard isAdopted(player) else { return }
        teardown()
        state = "idle"
        notifySlotChanged()
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
        stoppedByFacade = true
        notifySlotChanged()
        updateNowPlayingInfo()
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        // Clearing nowPlayingInfo alone is not enough to dismiss the lock
        // screen card — iOS keeps showing a stale one, with dead transport
        // buttons, until the audio session is released. Deactivating also
        // hands the Now Playing slot back to whatever was playing before us.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("🎬 MediaPlayer: failed to deactivate audio session: \(error.localizedDescription)")
        }

        // The session is no longer active, so the next surface adoption must
        // set it up again rather than trust the once-per-process flag.
        audioSessionConfigured = false
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

    private func notifySlotChanged() {
        NotificationCenter.default.post(name: Self.slotDidChange, object: self)
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
        // Report the real speed, so the lock screen's progress bar keeps
        // pace when playback runs faster or slower than normal.
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == "playing" ? Double(rate) : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)

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

    /// Forget the headless track's metadata and take its card off the lock
    /// screen. Used when a `video_player` surface takes the shared slot: the
    /// card would otherwise keep showing the track that was replaced.
    private func clearNowPlaying() {
        artworkTask?.cancel()
        artworkTask = nil
        nowPlayingTitle = nil
        nowPlayingArtist = nil
        nowPlayingArtwork = nil
        lastSource = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
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

        // The user stopped playback, so a video_player surface must not
        // quietly take the empty slot and start playing.
        stoppedByFacade = true
        notifySlotChanged()

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
            rate: rate,
            title: nowPlayingTitle,
            artist: nowPlayingArtist,
            startTimeout: lastStartTimeout
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
    private var audioSessionConfigured = false

    func configureAudioSession() {
        // Once per process: re-activating the session on every adoption
        // (each page of a feed) is a visible hitch for the player already
        // rendering.
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("🎬 MediaPlayer: failed to configure audio session: \(error.localizedDescription)")
        }
    }

    /// Headless playback can follow anything that changed the audio session,
    /// such as a recording, which leaves it inactive (and on older
    /// microphone plugins, playing out of the earpiece), so it puts the
    /// session back to playback each time it starts.
    private func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()

        do {
            if session.category != .playback {
                try session.setCategory(.playback, mode: .moviePlayback)
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("🎬 MediaPlayer: failed to activate audio session: \(error.localizedDescription)")
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

    // MARK: - Start checks

    /// Stream types AVPlayer accepts but never starts. AVFoundation reports
    /// Ogg as playable (`isPlayableExtendedMIMEType` says yes), yet an Ogg
    /// stream (an Icecast Ogg FLAC station, for one) sits loading forever on
    /// a device, with no error and no item failure.
    private static let unplayableStreamTypes: Set<String> = [
        "application/ogg",
        "audio/ogg",
        "audio/opus",
        "audio/webm",
        "video/webm",
    ]

    /// Watch a freshly started headless source for the two silent failures:
    /// a stream type AVPlayer cannot start (checked against the response's
    /// Content-Type, alongside playback so a good stream never waits), and,
    /// when a start timeout is set, no sound at all within it.
    private func armStartChecks(player: AVPlayer, source: String) {
        // play() may restart the source already held, without a teardown.
        disarmStartChecks()
        streamTypeProbe?.cancel()
        streamTypeProbe = nil

        if let url = Self.resolveURL(source), url.scheme == "http" || url.scheme == "https" {
            streamTypeProbe = StreamTypeProbe(url: url) { [weak self] mimeType in
                guard let self = self, self.source == source, let mimeType = mimeType else { return }

                if Self.unplayableStreamTypes.contains(mimeType) {
                    self.failStart(source: source, message: "This device cannot play \(mimeType) streams.")
                }
            }
        }

        guard lastStartTimeout > 0 else { return }

        let seconds = lastStartTimeout

        // Sound has started once the player's clock runs; a later stall is
        // rebuffering, not a failed start, so the watchdog stands down.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            if player.timeControlStatus == .playing {
                DispatchQueue.main.async { self?.disarmStartChecks() }
            }
        }

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.source == source, self.state == "playing" else { return }
            self.failStart(source: source, message: "No sound after \(Self.formatSeconds(seconds)) seconds.")
        }
        startWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: watchdog)
    }

    private func disarmStartChecks() {
        startWatchdog?.cancel()
        startWatchdog = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
    }

    /// Give up on a source that will never play: release it as `stop()`
    /// would, but leave the state at "error" and say why.
    private func failStart(source: String, message: String) {
        teardown()
        state = "error"
        notifySlotChanged()
        updateNowPlayingInfo()
        releaseAudioSession()
        dispatchError(source: source, message: message)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(seconds)
    }

    private func teardown() {
        disarmStartChecks()
        streamTypeProbe?.cancel()
        streamTypeProbe = nil

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
        if ownsPlayer {
            player?.replaceCurrentItem(with: nil)
        }
        player = nil
        source = nil
        shouldLoop = false
        ownsPlayer = true
    }
}

/// Reads the Content-Type a server sends for a URL and hangs up: a live
/// stream never ends, so only the response headers are fetched.
private final class StreamTypeProbe: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var completion: ((String?) -> Void)?

    init(url: URL, completion: @escaping (String?) -> Void) {
        self.completion = completion
        super.init()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        session.dataTask(with: url).resume()
    }

    func cancel() {
        completion = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.cancel)
        finish(response.mimeType?.lowercased())
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Unreachable or refused: say nothing, the start timeout covers it.
        finish(nil)
    }

    private func finish(_ mimeType: String?) {
        let completion = self.completion
        cancel()
        completion?(mimeType)
    }
}
