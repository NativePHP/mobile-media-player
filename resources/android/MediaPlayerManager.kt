package com.nativephp.plugins.media_player

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.fragment.app.FragmentActivity
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import com.nativephp.mobile.utils.NativeActionCoordinator
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference

/**
 * MediaPlayerManager owns the shared playback state used by the headless
 * `MediaPlayer.*` bridge functions and by the `video_player` element
 * renderer. Only one source plays at a time:
 *
 * - Headless playback runs through a Media3 ExoPlayer, published to the
 *   system through a MediaSession. That session is what puts playback on
 *   the lock screen, in the notification shade and on headphone / Bluetooth
 *   controls, and [MediaPlaybackService] keeps it alive in the background.
 * - Element playback (a Media3 Player owned by the `video_player`
 *   renderer) is "adopted" via [adoptElementPlayback], so facade calls
 *   (pause / resume / seek / volume / status) drive the on-screen surface
 *   too. Inside a paged container several surfaces coexist; only the one
 *   on the visible page is adopted at a time. Element playback gets no
 *   media session: a muted feed video does not belong on the lock screen.
 *
 * All methods must be called on the main thread — ExoPlayer and
 * MediaSession only answer on the looper they were created on.
 *
 * Fires "NativePHP\MediaPlayer\Events\PlaybackEnded" / "...\PlaybackError" /
 * "...\RemoteCommand" through NativeActionCoordinator.dispatchEvent — the
 * same event-dispatch mechanism the microphone plugin uses for
 * MicrophoneRecorded.
 */
object MediaPlayerManager {

    private const val TAG = "MediaPlayerManager"

    private const val PLAYBACK_ENDED_EVENT = "NativePHP\\MediaPlayer\\Events\\PlaybackEnded"
    private const val PLAYBACK_ERROR_EVENT = "NativePHP\\MediaPlayer\\Events\\PlaybackError"
    private const val REMOTE_COMMAND_EVENT = "NativePHP\\MediaPlayer\\Events\\RemoteCommand"

    private const val SESSION_ID = "nativephp-media-player"

    private var headlessPlayer: ExoPlayer? = null

    /**
     * The session that publishes [headlessPlayer] to the system. It wraps the
     * player in a [RemoteCommandPlayer], so only commands that come from
     * outside the app (lock screen, notification, headphones) go through
     * the wrapper and are reported to PHP; facade calls drive the player
     * directly and are not echoed back.
     */
    private var session: MediaSession? = null

    // Element playback adopted from the video_player renderer. Weak ref —
    // the Compose surface owns the player lifecycle, not us.
    private var elementPlayer: WeakReference<Player>? = null

    private var activityRef: WeakReference<FragmentActivity>? = null

    @Volatile
    var source: String? = null
        private set

    @Volatile
    private var state: String = "idle"

    // Bumped whenever the shared slot changes hands (adopted, released,
    // stopped). Surfaces observe it so one that lost the slot to a
    // neighbour can take it back the moment the neighbour lets go,
    // without waiting for its own geometry to change.
    private val _adoptions = MutableStateFlow(0)
    val adoptions: StateFlow<Int> = _adoptions.asStateFlow()

    // The slot is empty because PHP asked (`stop()`), not because a
    // surface let go. Surfaces must not quietly resume after that; a
    // threshold crossing (or `play()`) starts things again.
    @Volatile
    private var stoppedByFacade = false

    // How fast playback goes, 1.0 being normal speed. Kept across play() calls until changed.
    @Volatile
    private var rate: Float = 1f

    // MARK: - Playback control

    /**
     * Start (or replace) headless playback of a file path or URL, from
     * [position] seconds in, at [rate] (1.0 = normal speed).
     *
     * [title], [artist] and [artwork] populate the system's media controls —
     * the lock screen and the notification shade. [artwork] may be a remote
     * URL or a local file path; Media3 loads it in the background, so
     * playback never waits on it.
     *
     * Returns false when the player could not be created.
     */
    fun play(
        activity: FragmentActivity,
        sourceToPlay: String,
        loop: Boolean,
        volume: Float,
        rate: Float = 1f,
        position: Double = 0.0,
        title: String? = null,
        artist: String? = null,
        artwork: String? = null
    ): Boolean {
        release()

        activityRef = WeakReference(activity)

        val context = activity.applicationContext
        val clamped = volume.coerceIn(0f, 1f)
        this.rate = rate.coerceIn(0.25f, 4f)

        return try {
            val player = ExoPlayer.Builder(context)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                        .build(),
                    // Pause for a phone call or another app's audio, as a
                    // media app is expected to.
                    true
                )
                // Pause when headphones are unplugged rather than blare
                // through the speaker.
                .setHandleAudioBecomingNoisy(true)
                // Keep the CPU and Wi-Fi awake for a stream while the screen
                // is off.
                .setWakeMode(C.WAKE_MODE_NETWORK)
                .build()

            val item = MediaItem.Builder()
                .setUri(resolveUri(sourceToPlay))
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle(title ?: "Live stream")
                        .setArtist(artist)
                        .setArtworkUri(artwork?.takeIf { it.isNotEmpty() }?.let { resolveUri(it) })
                        .build()
                )
                .build()

            // With no start position, a live stream starts at its live edge
            // (the default position); passing 0 would start at the oldest
            // segment still in the playlist.
            if (position > 0) {
                player.setMediaItem(item, (position * 1000).toLong())
            } else {
                player.setMediaItem(item)
            }

            player.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            player.volume = clamped
            player.setPlaybackSpeed(this.rate)
            player.addListener(HeadlessListener(sourceToPlay))
            player.prepare()
            player.playWhenReady = true

            headlessPlayer = player
            source = sourceToPlay
            state = "playing"
            stoppedByFacade = false

            startSession(context, player)

            _adoptions.update { it + 1 }

            Log.d(TAG, "🎬 Playing $sourceToPlay (loop=$loop, volume=$clamped, rate=${this.rate}, position=$position)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to start playback: ${e.message}", e)
            releaseHeadless()
            onPlaybackError(sourceToPlay, e.message ?: "Failed to start playback")
            false
        }
    }

    fun pause() {
        if (state != "playing") {
            return
        }

        try {
            activePlayer()?.pause()
            state = "paused"
        } catch (e: Exception) {
            Log.e(TAG, "❌ pause failed: ${e.message}")
        }
    }

    fun resume() {
        try {
            val player = activePlayer() ?: return
            if (state == "ended") {
                player.seekTo(0)
            }
            player.play()
            state = "playing"
        } catch (e: Exception) {
            Log.e(TAG, "❌ resume failed: ${e.message}")
        }
    }

    fun stop() {
        release()
        state = "idle"
        stoppedByFacade = true
    }

    fun seek(seconds: Double) {
        val ms = (seconds * 1000).toLong().coerceAtLeast(0L)

        try {
            activePlayer()?.seekTo(ms)
            if (state == "ended") {
                state = "paused"
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ seek failed: ${e.message}")
        }
    }

    fun setVolume(volume: Float) {
        try {
            activePlayer()?.volume = volume.coerceIn(0f, 1f)
        } catch (e: Exception) {
            Log.e(TAG, "❌ setVolume failed: ${e.message}")
        }
    }

    /**
     * Change how fast playback goes (1.0 = normal speed). A paused player
     * stays paused and keeps the speed for when it resumes.
     */
    fun setRate(rate: Float) {
        this.rate = rate.coerceIn(0.25f, 4f)

        try {
            activePlayer()?.setPlaybackSpeed(this.rate)
        } catch (e: Exception) {
            Log.e(TAG, "❌ setRate failed: ${e.message}")
        }
    }

    fun getStatus(): Map<String, Any> {
        var position = 0.0
        var duration = 0.0

        try {
            activePlayer()?.let {
                position = it.currentPosition.coerceAtLeast(0L) / 1000.0
                val known = it.duration
                duration = if (known == C.TIME_UNSET) 0.0 else known.coerceAtLeast(0L) / 1000.0
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ getStatus failed: ${e.message}")
        }

        return mapOf(
            "state" to state,
            "position" to position,
            "duration" to duration,
            "source" to (source ?: "")
        )
    }

    /** The adopted surface if there is one, otherwise headless playback. */
    private fun activePlayer(): Player? = elementPlayer?.get() ?: headlessPlayer

    // MARK: - Media session

    /** The session [MediaPlaybackService] hosts, or null when nothing plays headlessly. */
    fun currentSession(): MediaSession? = session

    private fun startSession(context: Context, player: ExoPlayer) {
        val builder = MediaSession.Builder(context, RemoteCommandPlayer(player))
            .setId(SESSION_ID)

        // Tapping the notification brings the app back.
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            launch.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            builder.setSessionActivity(
                PendingIntent.getActivity(
                    context,
                    0,
                    launch,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
        }

        val newSession = builder.build()
        session = newSession

        MediaPlaybackService.attach(context, newSession)
    }

    private fun releaseSession() {
        val current = session ?: return
        session = null

        val context = activityRef?.get()?.applicationContext
        MediaPlaybackService.detach(context, current)
        current.release()
    }

    /**
     * Media3 hands commands from outside the app to the session's player.
     * Wrapping the real player lets us tell those apart from facade calls,
     * keep [state] in step and report them to PHP. As on iOS, the command
     * has already been applied by the time PHP hears of it.
     */
    private class RemoteCommandPlayer(player: ExoPlayer) : ForwardingPlayer(player) {

        override fun play() {
            // A live buffer goes stale while paused. Rejoin the live edge
            // instead of resuming behind it.
            if (isCurrentMediaItemLive) {
                seekToDefaultPosition()
            }
            super.play()
            state = "playing"
            dispatchRemoteCommand("play")
        }

        override fun pause() {
            super.pause()
            state = "paused"
            dispatchRemoteCommand("pause")
        }

        override fun stop() {
            dispatchRemoteCommand("stop")
            // Releasing the session from inside its own callback is not
            // safe, so let the call return first.
            Handler(Looper.getMainLooper()).post { MediaPlayerManager.stop() }
        }
    }

    /** Keeps [state] in step with headless playback and reports its outcome. */
    private class HeadlessListener(private val listenedSource: String) : Player.Listener {

        override fun onPlaybackStateChanged(playbackState: Int) {
            // Looping playback (REPEAT_MODE_ONE) never reaches STATE_ENDED.
            if (playbackState == Player.STATE_ENDED) {
                onPlaybackEnded(listenedSource)
            }
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            // Headphones unplugged, or another app took audio focus: the
            // player paused on its own, so nothing told the manager.
            if (!playWhenReady && state == "playing" && (
                    reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY ||
                        reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS
                    )
            ) {
                state = "paused"
                dispatchRemoteCommand("pause")
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            onPlaybackError(listenedSource, error.message ?: "Playback failed")
        }
    }

    // MARK: - Element (video_player renderer) adoption

    /**
     * Adopt an on-screen player as the shared playback, replacing any
     * headless playback (and any previously adopted surface, which is
     * paused first). Called by VideoPlayerRenderer once the surface is the
     * one that should be playing, so the PHP facade keeps controlling
     * on-screen playback and events fire for element playback too.
     */
    fun adoptElementPlayback(
        player: Player,
        sourceToPlay: String,
        activity: FragmentActivity?,
        playing: Boolean
    ) {
        releaseHeadless()

        val previous = elementPlayer?.get()
        if (previous != null && previous !== player) {
            try {
                previous.pause()
            } catch (e: Exception) {
                // Ignore — the surface may already be released
            }
        }

        elementPlayer = WeakReference(player)
        if (activity != null) {
            activityRef = WeakReference(activity)
        }
        source = sourceToPlay
        state = if (playing) "playing" else "paused"
        stoppedByFacade = false
        _adoptions.update { it + 1 }

        Log.d(TAG, "🎬 Adopted element playback for $sourceToPlay (playing=$playing)")
    }

    /** True when [player] is the surface the facade currently drives. */
    fun isAdopted(player: Player): Boolean = elementPlayer?.get() === player

    /**
     * True when a surface still mostly on screen may take the shared slot
     * without crossing a threshold: nothing holds it (no adopted surface,
     * no headless playback) and it was not emptied by an explicit [stop].
     */
    fun isReclaimable(): Boolean =
        elementPlayer?.get() == null && headlessPlayer == null && !stoppedByFacade

    /**
     * Drop the adoption of [player] if it holds it — the surface left the
     * visible page or is being disposed. Other surfaces are untouched.
     */
    fun releaseElementPlayback(player: Player) {
        if (!isAdopted(player)) {
            return
        }
        elementPlayer = null
        source = null
        state = "idle"
        _adoptions.update { it + 1 }
    }

    /**
     * Completion callback for element playback (not fired while looping —
     * the renderer sets isLooping on the underlying MediaPlayer).
     */
    fun onElementCompleted(completedSource: String) {
        state = "ended"
        onPlaybackEnded(completedSource)
    }

    fun onElementError(errorSource: String, message: String) {
        onPlaybackError(errorSource, message)
    }

    // MARK: - Helpers

    /**
     * Resolve a source string (http(s)/content URL or bare file path) to a Uri.
     */
    fun resolveUri(source: String): Uri {
        return if (source.startsWith("/")) {
            Uri.fromFile(File(source))
        } else {
            Uri.parse(source)
        }
    }

    /**
     * Tear down headless playback: the session first (which takes the
     * notification and lock screen controls away), then the player.
     */
    private fun releaseHeadless() {
        releaseSession()

        headlessPlayer?.release()
        headlessPlayer = null
    }

    private fun release() {
        releaseHeadless()

        // Element playback isn't owned by the manager — pause the surface
        // and drop the adoption instead of tearing the player down.
        try {
            elementPlayer?.get()?.pause()
        } catch (e: Exception) {
            // Ignore
        }
        elementPlayer = null
        source = null
        _adoptions.update { it + 1 }
    }

    // MARK: - Event dispatch

    private fun onPlaybackEnded(endedSource: String) {
        state = "ended"

        val payload = JSONObject().apply {
            put("source", endedSource)
        }

        Log.d(TAG, "📤 Dispatching PlaybackEnded with source=$endedSource")
        dispatchEvent(PLAYBACK_ENDED_EVENT, payload)
    }

    private fun onPlaybackError(errorSource: String, message: String) {
        state = "error"

        val payload = JSONObject().apply {
            put("source", errorSource)
            put("message", message)
        }

        Log.d(TAG, "📤 Dispatching PlaybackError with source=$errorSource, message=$message")
        dispatchEvent(PLAYBACK_ERROR_EVENT, payload)
    }

    private fun dispatchRemoteCommand(command: String) {
        val payload = JSONObject().apply {
            put("command", command)
            put("source", source ?: "")
        }

        Log.d(TAG, "📤 Dispatching RemoteCommand $command")
        dispatchEvent(REMOTE_COMMAND_EVENT, payload)
    }

    private fun dispatchEvent(event: String, payload: JSONObject) {
        val activity = activityRef?.get() ?: return

        Handler(Looper.getMainLooper()).post {
            NativeActionCoordinator.dispatchEvent(activity, event, payload.toString())
        }
    }
}
