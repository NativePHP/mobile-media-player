package com.nativephp.plugins.media_player

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.fragment.app.FragmentActivity
import androidx.media3.common.C
import androidx.media3.common.Player
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
 * - Headless playback runs through a plain android.media.MediaPlayer
 *   (no ExoPlayer/Media3 dependency).
 * - Element playback (a Media3 Player owned by the `video_player`
 *   renderer) is "adopted" via [adoptElementPlayback], so facade calls
 *   (pause / resume / seek / volume / status) drive the on-screen surface
 *   too. Inside a paged container several surfaces coexist; only the one
 *   on the visible page is adopted at a time.
 *
 * Fires "NativePHP\MediaPlayer\Events\PlaybackEnded" / "...\PlaybackError"
 * through NativeActionCoordinator.dispatchEvent — the same event-dispatch
 * mechanism the microphone plugin uses for MicrophoneRecorded.
 */
object MediaPlayerManager {

    private const val TAG = "MediaPlayerManager"

    private const val PLAYBACK_ENDED_EVENT = "NativePHP\\MediaPlayer\\Events\\PlaybackEnded"
    private const val PLAYBACK_ERROR_EVENT = "NativePHP\\MediaPlayer\\Events\\PlaybackError"

    private var headlessPlayer: MediaPlayer? = null

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

    // MARK: - Playback control

    /**
     * Start (or replace) headless playback of a file path or URL.
     * Returns false when the player could not be created / prepared.
     */
    fun play(activity: FragmentActivity, sourceToPlay: String, loop: Boolean, volume: Float): Boolean {
        release()

        activityRef = WeakReference(activity)

        val clamped = volume.coerceIn(0f, 1f)
        val player = MediaPlayer()

        return try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .build()
            )
            setDataSource(player, activity, sourceToPlay)
            player.isLooping = loop
            player.setVolume(clamped, clamped)
            player.setOnPreparedListener { it.start() }
            player.setOnCompletionListener { onPlaybackEnded(sourceToPlay) }
            player.setOnErrorListener { _, what, extra ->
                onPlaybackError(sourceToPlay, "MediaPlayer error what=$what extra=$extra")
                true
            }
            player.prepareAsync()

            headlessPlayer = player
            source = sourceToPlay
            state = "playing"

            Log.d(TAG, "🎬 Playing $sourceToPlay (loop=$loop, volume=$clamped)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to start playback: ${e.message}", e)
            player.release()
            onPlaybackError(sourceToPlay, e.message ?: "Failed to start playback")
            false
        }
    }

    fun pause() {
        if (state != "playing") {
            return
        }

        try {
            elementPlayer?.get()?.pause() ?: headlessPlayer?.pause()
            state = "paused"
        } catch (e: Exception) {
            Log.e(TAG, "❌ pause failed: ${e.message}")
        }
    }

    fun resume() {
        try {
            val element = elementPlayer?.get()
            if (element != null) {
                if (state == "ended") {
                    element.seekTo(0)
                }
                element.play()
            } else {
                val player = headlessPlayer ?: return
                if (state == "ended") {
                    player.seekTo(0)
                }
                player.start()
            }
            state = "playing"
        } catch (e: Exception) {
            Log.e(TAG, "❌ resume failed: ${e.message}")
        }
    }

    fun stop() {
        release()
        state = "idle"
    }

    fun seek(seconds: Double) {
        val ms = (seconds * 1000).toInt().coerceAtLeast(0)

        try {
            elementPlayer?.get()?.seekTo(ms.toLong()) ?: headlessPlayer?.seekTo(ms)
            if (state == "ended") {
                state = "paused"
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ seek failed: ${e.message}")
        }
    }

    fun setVolume(volume: Float) {
        val clamped = volume.coerceIn(0f, 1f)

        try {
            val element = elementPlayer?.get()
            if (element != null) {
                element.volume = clamped
            } else {
                headlessPlayer?.setVolume(clamped, clamped)
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ setVolume failed: ${e.message}")
        }
    }

    fun getStatus(): Map<String, Any> {
        var position = 0.0
        var duration = 0.0

        try {
            val element = elementPlayer?.get()
            if (element != null) {
                position = element.currentPosition.coerceAtLeast(0L) / 1000.0
                val known = element.duration
                duration = if (known == C.TIME_UNSET) 0.0 else known.coerceAtLeast(0L) / 1000.0
            } else {
                headlessPlayer?.let {
                    position = it.currentPosition / 1000.0
                    duration = it.duration.coerceAtLeast(0) / 1000.0
                }
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
        _adoptions.update { it + 1 }

        Log.d(TAG, "🎬 Adopted element playback for $sourceToPlay (playing=$playing)")
    }

    /** True when [player] is the surface the facade currently drives. */
    fun isAdopted(player: Player): Boolean = elementPlayer?.get() === player

    /**
     * True when nothing holds the shared slot — no adopted surface and no
     * headless playback — so a surface still mostly on screen may take it.
     */
    fun isIdle(): Boolean = elementPlayer?.get() == null && headlessPlayer == null

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

    private fun setDataSource(player: MediaPlayer, context: Context, source: String) {
        if (source.startsWith("/")) {
            player.setDataSource(source)
        } else {
            player.setDataSource(context, Uri.parse(source))
        }
    }

    private fun releaseHeadless() {
        try {
            headlessPlayer?.stop()
        } catch (e: Exception) {
            // Ignore — player may not have started yet
        }
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

    private fun dispatchEvent(event: String, payload: JSONObject) {
        val activity = activityRef?.get() ?: return

        Handler(Looper.getMainLooper()).post {
            NativeActionCoordinator.dispatchEvent(activity, event, payload.toString())
        }
    }
}
