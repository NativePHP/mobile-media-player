package com.nativephp.plugins.media_player

import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.fragment.app.FragmentActivity
import com.nativephp.mobile.bridge.BridgeFunction
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Functions related to media playback operations
 * Namespace: "MediaPlayer.*"
 */
object MediaPlayerFunctions {

    /**
     * Start or replace playback of a file path or URL on the shared player
     * Parameters:
     *   - source: string - File path or URL to play
     *   - loop: (optional) boolean - Restart playback when the item ends (default: false)
     *   - volume: (optional) float - Playback volume 0.0 - 1.0 (default: 1.0)
     * Returns:
     *   - success: boolean - True if playback started
     * Events:
     *   - Fires "NativePHP\MediaPlayer\Events\PlaybackEnded" when playback finishes
     *   - Fires "NativePHP\MediaPlayer\Events\PlaybackError" on failure
     */
    class Play(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val source = parameters["source"] as? String
            if (source.isNullOrEmpty()) {
                return mapOf("success" to false)
            }

            val loop = parameters["loop"] as? Boolean ?: false
            val volume = (parameters["volume"] as? Number)?.toFloat() ?: 1.0f

            var success = false
            val latch = CountDownLatch(1)

            // MediaPlayer setup must run on the main thread
            Handler(Looper.getMainLooper()).post {
                try {
                    success = MediaPlayerManager.play(activity, source, loop, volume)
                } catch (e: Exception) {
                    // Silent failure
                }
                latch.countDown()
            }

            latch.await(2, TimeUnit.SECONDS)

            return mapOf("success" to success)
        }
    }

    /**
     * Pause the current playback
     */
    class Pause(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            Handler(Looper.getMainLooper()).post {
                try {
                    MediaPlayerManager.pause()
                } catch (e: Exception) {
                    // Silent failure
                }
            }

            return emptyMap()
        }
    }

    /**
     * Resume paused playback
     */
    class Resume(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            Handler(Looper.getMainLooper()).post {
                try {
                    MediaPlayerManager.resume()
                } catch (e: Exception) {
                    // Silent failure
                }
            }

            return emptyMap()
        }
    }

    /**
     * Stop playback and release the shared player
     */
    class Stop(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            Handler(Looper.getMainLooper()).post {
                try {
                    MediaPlayerManager.stop()
                } catch (e: Exception) {
                    // Silent failure
                }
            }

            return emptyMap()
        }
    }

    /**
     * Seek to a position in seconds
     * Parameters:
     *   - seconds: float - Position to seek to
     */
    class Seek(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val seconds = (parameters["seconds"] as? Number)?.toDouble() ?: 0.0

            Handler(Looper.getMainLooper()).post {
                try {
                    MediaPlayerManager.seek(seconds)
                } catch (e: Exception) {
                    // Silent failure
                }
            }

            return emptyMap()
        }
    }

    /**
     * Set playback volume
     * Parameters:
     *   - volume: float - Volume 0.0 - 1.0
     */
    class SetVolume(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val volume = (parameters["volume"] as? Number)?.toFloat() ?: 1.0f

            Handler(Looper.getMainLooper()).post {
                try {
                    MediaPlayerManager.setVolume(volume)
                } catch (e: Exception) {
                    // Silent failure
                }
            }

            return emptyMap()
        }
    }

    /**
     * Get current playback status (synchronous)
     * Returns:
     *   - state: string - "idle", "playing", "paused", "ended" or "error"
     *   - position: float - Current position in seconds
     *   - duration: float - Item duration in seconds
     *   - source: string - Currently loaded source ("" when idle)
     */
    class GetStatus(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            return MediaPlayerManager.getStatus()
        }
    }

    /**
     * Present a full-screen playback activity for a file path or URL.
     * The user dismisses it natively (back gesture / playback end).
     * Parameters:
     *   - source: string - File path or URL to play
     * Returns:
     *   - success: boolean - True if the player activity was launched
     */
    class Present(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val source = parameters["source"] as? String
            if (source.isNullOrEmpty()) {
                return mapOf("success" to false)
            }

            Handler(Looper.getMainLooper()).post {
                try {
                    // Don't fight the shared player for audio focus.
                    MediaPlayerManager.stop()

                    val intent = Intent(activity, FullscreenPlayerActivity::class.java).apply {
                        putExtra(FullscreenPlayerActivity.EXTRA_SOURCE, source)
                    }
                    activity.startActivity(intent)
                } catch (e: Exception) {
                    // Silent failure
                }
            }

            return mapOf("success" to true)
        }
    }
}
